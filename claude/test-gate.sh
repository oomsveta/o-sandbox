#!/usr/bin/env bash

# Waits until there's enough free memory to start an Odoo test run, so that
# parallel agents don't start more test runs than fit in memory.
# Usage: test-gate && odoo-bin ... --test-tags ...
# Claude Code calls it before test runs on its own (test-gate-hook).
#
# One run starts at a time: the first to get the lock waits for the memory,
# then keeps the lock for TEST_GATE_HOLD seconds after it exits, while the run
# starts up and its memory use grows, so that the next one measures with it.
#
# Exits 1 if there still isn't enough memory after TEST_GATE_MAX_WAIT seconds.

set -uo pipefail

min_mb=${TEST_GATE_MIN_MB:-2048}
max_wait=${TEST_GATE_MAX_WAIT:-840}  # 840 seconds = 14 minutes
hold=${TEST_GATE_HOLD:-45}
lock=/tmp/test-gate.lock

# limit as set by mem_limit in docker-compose.yml
if ! memory_limit=$(cat /sys/fs/cgroup/memory.max); then
    echo "test-gate: can't read the container's memory limit; is this" \
        "running in the devcontainer, with cgroup v2?" >&2
    exit 1
fi

container_headroom_mb() {
    local used cache
    if [ "$memory_limit" = 'max' ]; then
        return
    fi
    used=$(cat /sys/fs/cgroup/memory.current)
    cache=$(awk '/^inactive_file / { print $2 }' /sys/fs/cgroup/memory.stat)
    echo $(( (memory_limit - used + cache) / (1024 * 1024) ))
}

# Checks how much memory is available for a test run.
# Two limits apply, and the lower one wins:
# - free memory in the VM that runs the containers
# - headroom left under this container's "mem_limit" in docker-compose.yml
#   (only if one is set)
available_mb() {
    local vm container
    vm=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
    container=$(container_headroom_mb)
    if [ -n "$container" ] && (( container < vm )); then
        echo "$container"
    else
        echo "$vm"
    fi
}

exec 9>> "$lock"
if ! flock --wait "$max_wait" 9; then
    echo "test-gate: another test run has been waiting for memory for ${max_wait}s." \
        "Retry later, or stop other test runs." >&2
    exit 1
fi

said=
until (( (available = $(available_mb)) >= min_mb )); do
    if (( SECONDS >= max_wait )); then
        echo "test-gate: only ${available} MB of memory available after ${max_wait}s," \
            "a test run needs ${min_mb} MB. Retry later, or stop other test runs." >&2
        exit 1
    fi
    if [ -z "$said" ]; then
        echo "test-gate: ${available} MB of memory available, waiting for ${min_mb} MB..." >&2
        said=1
    fi
    sleep 5
done

# Pass the lock to a background sleep for $hold seconds, to leave odoo-bin
# time to start and claim its memory before the next queued test run checks
# how much is available.
setsid sleep "$hold" < /dev/null > /dev/null 2>&1 &
exit 0
