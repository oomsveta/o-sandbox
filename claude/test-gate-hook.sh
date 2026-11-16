#!/usr/bin/env bash

# Claude Code PreToolUse hook, called before a command.

# Detects whether the command runs Odoo tests. If it does, calls test-gate,
# which waits until enough memory is available. If it still isn't after
# test-gate's timeout, blocks the command.

if ! cmd=$(jq --raw-output '.tool_input.command // ""'); then
    echo "test-gate-hook: can't read the command from the hook input;" \
        "the command runs without the memory check." >&2
    exit 1
fi

if grep --quiet --extended-regexp -- '--test-(enable|tags|file)' <<< "$cmd"; then
    # exit code 2 blocks the command and sends stderr to Claude
    # https://code.claude.com/docs/en/hooks#exit-code-2
    test-gate || exit 2
fi
exit 0
