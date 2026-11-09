#!/usr/bin/env bash
# Sets up the dev container's own clones of the Odoo repos (see "Git
# repositories" in the README).
#
# For each repo in REPOS below, if /odoo/<name> (in a Docker volume) isn't set up
# yet:
#
# - If the host has the repo (the project folder is mounted read-only at
#   /host), creates /odoo/<name> as a clone that *borrows* the host's objects
#   through git alternates, the same as `git clone --shared`: nothing is
#   downloaded and the history isn't copied. The clone gets the host's
#   branches, remote-tracking branches, tags, remotes and checked-out branch,
#   but none of the host's other git config (hooks included) and none of its
#   uncommitted changes. Shallow and partial (--filter) clones stay shallow
#   and partial.
# - Otherwise, clones it from GitHub (through the git relay) with
#   $SEED_CLONE_ARGS, and adds the other remotes.
#
# Then, if community or enterprise was just set up, enables Odoo's JS tooling
# in them (addons/web/tooling/enable.sh): its git hooks, which lint staged
# JS/CSS files, and the npm packages they need.
#
# Repos that are already set up are left alone, so this is safe to re-run.
# A repo that fails is cleaned up (and retried on the next run); the others
# are still set up.

set -uo pipefail

# The repos: name (folder in the project folder and in /odoo), then remotes
# as name=url. The first remote is the one cloned from when the host doesn't
# have the repo; the others are only added.
REPOS=(
    "community   origin=git@github.com:odoo/odoo.git        dev=git@github.com:odoo-dev/odoo.git"
    "enterprise  origin=git@github.com:odoo/enterprise.git  dev=git@github.com:odoo-dev/enterprise.git"
    "rsfu        origin=git@github.com:odoo/o-sfu.git"
)

FROM=${SEED_FROM:-/host}
TO=${SEED_TO:-/odoo}
# Full history, but file contents only for what gets checked out; the rest is
# downloaded when needed. `--depth=1` would be faster still, at the cost of
# the history.
read -ra CLONE_ARGS <<< "${SEED_CLONE_ARGS:---filter=blob:none}"

# Sets up $2 from the host repo $1. Exits non-zero on failure (run in a
# subshell, so that `set -e` applies).
seed() (
    set -e
    src=$1 dst=$2

    git init --quiet --object-format="$(git --git-dir="$src" rev-parse --show-object-format)" "$dst"
    echo "$src/objects" > "$dst/.git/objects/info/alternates"
    # Shallow clone: where its history stops.
    if [ -f "$src/shallow" ]; then
        cp "$src/shallow" "$dst/.git/shallow"
    fi
    # Partial clone: lets git fetch the missing objects when they're needed.
    if promisor=$(git --git-dir="$src" config extensions.partialClone); then
        git -C "$dst" config core.repositoryFormatVersion 1
        git -C "$dst" config extensions.partialClone "$promisor"
    fi

    # Refs: written directly, as the objects are already there. (A `git fetch`
    # from $src would also work, but it checks the connectivity of the whole
    # history, which takes minutes.) Symbolic refs such as
    # refs/remotes/origin/HEAD are skipped.
    git --git-dir="$src" for-each-ref \
        --format='%(if)%(symref)%(then)%(else)create %(refname) %(objectname)%(end)' \
        refs/heads refs/remotes refs/tags \
        | sed '/^$/d' \
        | git -C "$dst" update-ref --stdin

    # Remotes and upstream branches, so that fetch/push/pull behave as on the
    # host. Nothing else from the host's config is copied.
    while IFS= read -r -d '' entry; do
        git -C "$dst" config --add "${entry%%$'\n'*}" "${entry#*$'\n'}"
    done < <(git --git-dir="$src" config --null --get-regexp '^(remote|branch)\.' || true)

    # Check out what the host has checked out.
    if branch=$(git --git-dir="$src" symbolic-ref --quiet HEAD); then
        git -C "$dst" symbolic-ref HEAD "$branch"
    else
        git -C "$dst" update-ref --no-deref HEAD "$(git --git-dir="$src" rev-parse HEAD)"
    fi
    git -C "$dst" reset --hard --quiet
)

# Clones $1 from GitHub, with the remotes $2... (name=url): the first one is
# cloned from, the others are added.
clone() (
    set -e
    dst=$1
    shift
    first=$1
    git clone "${CLONE_ARGS[@]}" --origin "${first%%=*}" "${first#*=}" "$dst"
    shift
    for remote in "$@"; do
        git -C "$dst" remote add "${remote%%=*}" "${remote#*=}"
    done
)

failed=0
seeded=()
shopt -s dotglob
for entry in "${REPOS[@]}"; do
    read -r name remotes <<< "$entry"
    read -ra remotes <<< "$remotes"
    src=$FROM/$name/.git
    dst=$TO/$name

    if [ -e "$dst/.git" ]; then
        echo "$name: already set up"
        continue
    fi
    mkdir -p "$dst"
    if [ -n "$(ls -A "$dst")" ]; then
        echo "$name: $dst is not empty but isn't a git repo: skipping" >&2
        failed=1
        continue
    fi

    # seed and clone aren't run as `if seed ...`: bash ignores `set -e` in an
    # if condition, even in a subshell, so they'd carry on after a failure.
    # --git-dir: never treat the host repo as a working tree.
    if [ -d "$src" ] && git --git-dir="$src" rev-parse --verify --quiet HEAD > /dev/null; then
        echo "$name: setting up from the host's repo"
        seed "$src" "$dst"
    else
        echo "$name: not on the host (no repo at ${src#"$FROM"/}), cloning ${remotes[0]#*=}"
        clone "$dst" "${remotes[@]}"
    fi
    if [ $? -eq 0 ]; then
        echo "$name: checked out $(git -C "$dst" rev-parse --abbrev-ref HEAD)"
        seeded+=("$name")
    else
        echo "$name: setup failed, cleaning up (it will be retried next time)" >&2
        rm -rf "${dst:?}"/*
        failed=1
    fi
done

# Odoo's JS tooling. enable.sh asks whether to set up enterprise too, and
# where it is; it runs `npm install` in community and copies the result to
# enterprise.
community=$TO/community
enterprise=$TO/enterprise
if [[ " ${seeded[*]} " =~ " "(community|enterprise)" " ]] \
    && [ -x "$community/addons/web/tooling/enable.sh" ]; then
    echo "Enabling Odoo's JS tooling (git hooks and npm packages)"
    if [ -d "$enterprise/.git" ]; then
        answers=$'y\n../enterprise\n'
    else
        answers=$'n\n'
    fi
    # No `npm audit` (the egress proxy blocks it anyway) nor funding ads.
    if ! (cd "$community" \
        && npm_config_audit=false npm_config_fund=false \
            addons/web/tooling/enable.sh <<< "$answers"); then
        echo "Enabling the JS tooling failed: run addons/web/tooling/enable.sh in $community" >&2
        failed=1
    fi
fi

exit $failed
