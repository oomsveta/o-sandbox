#!/usr/bin/env bash
# Sets up the dev container's own clones of the Odoo repos, in /odoo (see
# "Git repositories" in the README):
#
# - from the host's repo, in /host, if it has it: see borrow() below;
# - otherwise, from GitHub (through the git relay).
#
# Then enables Odoo's JS tooling in community and enterprise.
#
# Safe to re-run: repos already set up are left alone, and a repo that fails
# is removed so that the next run retries it.

set -uo pipefail

# The repos: name (folder in /host and /odoo), then remotes as name=url.
# When the host doesn't have the repo, it's cloned from the first remote.
REPOS=(
    "community   origin=git@github.com:odoo/odoo.git        dev=git@github.com:odoo-dev/odoo.git"
    "enterprise  origin=git@github.com:odoo/enterprise.git  dev=git@github.com:odoo-dev/enterprise.git"
    "rsfu        origin=git@github.com:odoo/o-sfu.git"
)
# Clones from GitHub get the full history, but only the file contents that
# get checked out; the rest is downloaded when needed.
read -ra CLONE_ARGS <<< "${SEED_CLONE_ARGS:---filter=blob:none}"

# Creates repo $2 from the host's $1 (a .git folder), like `git clone --shared`:
# it reads its objects from $1 (git alternates) instead of copying them. But
# unlike a clone, it gets $1's branches, remotes, upstreams and checked-out
# branch, as if it were $1 itself. Nothing else from $1's config is copied
# (no hooks...), nor its uncommitted changes.
borrow() (
    set -e
    src=$1 dst=$2
    git init --quiet --object-format="$(git --git-dir="$src" rev-parse --show-object-format)" "$dst"
    echo "$src/objects" > "$dst/.git/objects/info/alternates"
    # Shallow and partial clones stay so.
    if [ -f "$src/shallow" ]; then
        cp "$src/shallow" "$dst/.git/shallow"
    fi
    if promisor=$(git --git-dir="$src" config extensions.partialClone); then
        git -C "$dst" config core.repositoryFormatVersion 1
        git -C "$dst" config extensions.partialClone "$promisor"
    fi
    # Refs, except symbolic ones (refs/remotes/origin/HEAD). Written directly,
    # as `git fetch` would check the whole history's connectivity: minutes.
    git --git-dir="$src" for-each-ref \
        --format='%(if)%(symref)%(then)%(else)create %(refname) %(objectname)%(end)' \
        refs/heads refs/remotes refs/tags \
        | sed '/^$/d' \
        | git -C "$dst" update-ref --stdin
    # Remotes and upstreams: remote.* and branch.* config entries.
    while IFS= read -r -d '' entry; do  # "key\nvalue"
        git -C "$dst" config --add "${entry%%$'\n'*}" "${entry#*$'\n'}"
    done < <(git --git-dir="$src" config --null --get-regexp '^(remote|branch)\.' || true)
    # The checked-out branch (or commit), then its files.
    cp "$src/HEAD" "$dst/.git/HEAD"
    git -C "$dst" reset --hard --quiet
)

# Clones repo $1 from GitHub, with the remotes $2... (name=url). It's cloned
# from the first one, the others are added.
clone() (
    set -e
    dst=$1 first=$2
    shift 2
    git clone "${CLONE_ARGS[@]}" --origin "${first%%=*}" "${first#*=}" "$dst"
    for remote; do
        git -C "$dst" remote add "${remote%%=*}" "${remote#*=}"
    done
)

failed=0
js_tooling=
for entry in "${REPOS[@]}"; do
    read -r name remotes <<< "$entry"
    read -ra remotes <<< "$remotes"
    src=/host/$name/.git
    dst=/odoo/$name

    if [ -e "$dst/.git" ]; then
        echo "$name: already set up"
        continue
    fi
    if [ -n "$(ls -A "$dst" 2> /dev/null)" ]; then
        echo "$name: $dst isn't empty but isn't a git repo: skipping" >&2
        failed=1
        continue
    fi

    # --git-dir: never treat the host's repo as a working tree.
    # Not `if borrow ...`: bash ignores `set -e` in an if condition, even in a
    # subshell, so borrow and clone would carry on after a failure.
    if [ -d "$src" ] && git --git-dir="$src" rev-parse --verify --quiet HEAD > /dev/null; then
        echo "$name: setting up from the host's repo"
        borrow "$src" "$dst"
    else
        echo "$name: not on the host, cloning ${remotes[0]#*=}"
        clone "$dst" "${remotes[@]}"
    fi
    if [ $? -eq 0 ]; then
        echo "$name: checked out $(git -C "$dst" rev-parse --abbrev-ref HEAD)"
        if [ "$name" = community ] || [ "$name" = enterprise ]; then
            js_tooling=1
        fi
    else
        echo "$name: setup failed, removed (it will be retried next time)" >&2
        rm -rf "$dst"
        failed=1
    fi
done

# Odoo's JS tooling (addons/web/tooling/): git hooks that lint staged JS/CSS
# files, and the npm packages they need. enable.sh asks whether to set up
# enterprise too, and where it is.
if [ -n "$js_tooling" ] && [ -x /odoo/community/addons/web/tooling/enable.sh ]; then
    echo "Enabling Odoo's JS tooling (git hooks and npm packages)"
    if [ -d /odoo/enterprise/.git ]; then
        answers=$'y\n../enterprise\n'
    else
        answers=$'n\n'
    fi
    # No `npm audit` (the HTTPS proxy blocks it anyway) nor funding ads.
    if ! (cd /odoo/community \
        && npm_config_audit=false npm_config_fund=false \
            addons/web/tooling/enable.sh <<< "$answers"); then
        echo "Enabling the JS tooling failed: run addons/web/tooling/enable.sh in /odoo/community" >&2
        failed=1
    fi
fi

exit $failed
