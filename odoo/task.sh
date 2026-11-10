#!/usr/bin/env bash
# Tasks: isolated workspaces, so that several Claude Code sessions (or humans)
# can work on different things at once (see "Parallel tasks" in the README).
#
# A task is a folder in /odoo/tasks with everything that would otherwise be
# shared, and collide:
#
#   /odoo/tasks/<name>/
#   ├── community/   git worktree of /odoo/community, on the task's branch
#   ├── enterprise/  git worktree of /odoo/enterprise, on the same branch
#   ├── odoo.conf    these checkouts' addons, database <name>, its own ports
#   ├── CLAUDE.md    tells Claude Code all of the above
#   └── .claude/settings.local.json   ODOO_RC for sessions started here
#
# The worktrees share the main clones' objects and refs, so a task only costs
# its files (about 2 GB). Community and enterprise stay side by side, as
# enterprise's JS tooling hooks are in ../community.
#
# Usage: task new <name> [<base>] [--branch <branch>] [--fetch]
#        task rm <name> [--force]
#        task list
#        task path <name>
#        task hook-create | task hook-remove  (Claude Code hooks, JSON on stdin)

set -euo pipefail

TASKS=/odoo/tasks
MAIN=/odoo
REPOS=(community enterprise)
# Task N's ports are the main ones + 100*N: 8169/8172, 8269/8272...
BASE_HTTP_PORT=8069
BASE_GEVENT_PORT=8072
# Branches are <base>-<name>-<trigram>, the suffix the git relay lets us push.
TRIGRAM=${TASK_TRIGRAM:-$(git config user.email | cut -d@ -f1)}
DEFAULT_BASE=${TASK_BASE:-master}
# Untracked files of Odoo's JS tooling, copied from the main checkouts (see
# addons/web/tooling/enable.sh): without them the pre-commit hook fails.
TOOLING_FILES=(.eslintignore .eslint-ignore .eslintrc.json eslint.config.cjs
               jsconfig.json package.json package-lock.json node_modules)

die() { echo "task: $*" >&2; exit 1; }
log() { echo "$*" >&2; }  # stdout is for results (paths), see hook-create

valid_name() {
    [[ $1 =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] \
        || die "invalid name '$1': lowercase letters, digits, - and _ only"
}

repos_present() {
    local repo
    for repo in "${REPOS[@]}"; do
        if [ -d "$MAIN/$repo/.git" ]; then
            echo "$repo"
        fi
    done
}

# conf_get <odoo.conf> <key>
conf_get() { sed -n "s/^$2[[:space:]]*=[[:space:]]*//p" "$1"; }

# The lowest slot (port offset) that no task uses.
free_slot() {
    local slot=1
    while grep -qsx "; task slot = $slot" "$TASKS"/*/odoo.conf; do
        slot=$((slot + 1))
    done
    echo "$slot"
}

# Claude Code keeps auto-memory per project folder. Points the task's at the
# main /odoo one, so that what Claude learnt there also applies in tasks.
share_memory() {
    local project="$HOME/.claude/projects/${1//[^a-zA-Z0-9]/-}"
    local main="$HOME/.claude/projects/-odoo/memory"
    mkdir -p "$project" "$main"
    if [ ! -e "$project/memory" ]; then
        ln -s "$main" "$project/memory"
    fi
}

cmd_new() {
    local name= base=$DEFAULT_BASE branch= fetch=
    while [ $# -gt 0 ]; do
        case $1 in
            --branch) branch=${2:?--branch needs a value}; shift ;;
            --fetch) fetch=1 ;;
            -*) die "unknown option $1" ;;
            *) if [ -z "$name" ]; then name=$1; else base=$1; fi ;;
        esac
        shift
    done
    [ -n "$name" ] || die "usage: task new <name> [<base>] [--branch <branch>] [--fetch]"
    valid_name "$name"
    branch=${branch:-$base-$name-$TRIGRAM}
    local dir=$TASKS/$name
    [ ! -e "$dir" ] || die "$dir already exists"

    mkdir -p "$TASKS"
    # Two tasks created at once mustn't get the same slot.
    exec 9> "$TASKS/.lock"
    flock 9

    local repos
    mapfile -t repos < <(repos_present)
    [ ${#repos[@]} -gt 0 ] || die "no repo in $MAIN"

    mkdir "$dir"
    # From now on, a failure removes what was created: worktrees and folder,
    # but not branches or the database, which may have existed before.
    trap 'if [ -z "${created:-}" ]; then log "task: failed, cleaning up"; undo_new "$dir"; fi' EXIT

    local repo
    for repo in "${repos[@]}"; do
        add_worktree "$MAIN/$repo" "$dir/$repo" "$branch" "$base" "$fetch"
        copy_tooling "$MAIN/$repo" "$dir/$repo"
    done

    local slot addons=()
    slot=$(free_slot)
    if [ -d "$dir/community" ]; then
        addons+=("$dir/community/addons" "$dir/community/odoo/addons")
    fi
    if [ -d "$dir/enterprise" ]; then
        addons+=("$dir/enterprise")
    fi
    install_requirements "$dir/community/requirements.txt"
    write_conf "$dir" "$name" "$slot" "$(IFS=,; echo "${addons[*]}")"
    write_claude_files "$dir" "$name" "$branch" "$slot"
    share_memory "$dir"
    created=1

    if psql -lqtA | cut -d'|' -f1 | grep -qx "$name"; then
        log "Note: database '$name' already exists, the task will use it as is."
    fi
    log "Task $name: branch $branch, database $name," \
        "http://localhost:$((BASE_HTTP_PORT + 100 * slot))"
    log "  cd $dir && claude"
    echo "$dir"
}

# All tasks share one virtualenv, set up for the branch community was on when
# the container was created. Branches can need other packages: installs a
# task's requirements, unless this exact file was installed before.
install_requirements() {
    local file=$1 stamps=${VIRTUAL_ENV:-/opt/venv}/.installed-requirements hash
    [ -f "$file" ] || return 0
    hash=$(sha256sum < "$file" | cut -d' ' -f1)
    if grep -qsx "$hash" "$stamps"; then
        return 0
    fi
    log "Installing Python requirements for this branch"
    pip install --quiet --disable-pip-version-check -r "$file" >&2
    echo "$hash" >> "$stamps"
}

undo_new() {
    local dir=$1 repo
    for repo in "${REPOS[@]}"; do
        if [ -e "$dir/$repo" ]; then
            git -C "$MAIN/$repo" worktree remove --force "$dir/$repo" 2> /dev/null || true
        fi
        git -C "$MAIN/$repo" worktree prune 2> /dev/null || true
    done
    rm -rf "$dir"
}

# copy_tooling <main checkout> <worktree>
# Some of these files aren't gitignored (e.g. eslint.config.cjs in community):
# they're excluded in the repo's info/exclude, shared by all its worktrees, so
# that they don't count as changes (see remove_task).
copy_tooling() {
    local main=$1 wt=$2 file exclude
    exclude=$(git -C "$main" rev-parse --path-format=absolute --git-common-dir)/info/exclude
    for file in "${TOOLING_FILES[@]}"; do
        [ -e "$main/$file" ] || continue
        if [ ! -e "$wt/$file" ]; then
            cp -a --reflink=auto "$main/$file" "$wt/"
        fi
        if ! git -C "$wt" check-ignore -q "$file" \
            && [ -z "$(git -C "$wt" ls-files -- "$file")" ]; then
            mkdir -p "$(dirname "$exclude")"
            echo "/$file" >> "$exclude"
        fi
    done
}

# add_worktree <main repo> <path> <branch> <base> <fetch>
# Checks out <branch> if the repo has it, locally or on the dev remote;
# otherwise creates it from origin/<base> (or <base>).
add_worktree() {
    local repo=$1 path=$2 branch=$3 base=$4 fetch=$5
    local git=(git -C "$repo")
    if [ -n "$fetch" ]; then
        log "$(basename "$repo"): fetching origin $base"
        "${git[@]}" fetch --quiet origin "$base" >&2
    fi
    log "$(basename "$repo"): worktree on $branch"
    if "${git[@]}" rev-parse --verify --quiet "refs/heads/$branch" > /dev/null; then
        "${git[@]}" worktree add --quiet "$path" "$branch" >&2
    elif "${git[@]}" rev-parse --verify --quiet "refs/remotes/dev/$branch" > /dev/null; then
        "${git[@]}" worktree add --quiet --track -b "$branch" "$path" "dev/$branch" >&2
    else
        local start=origin/$base
        if ! "${git[@]}" rev-parse --verify --quiet "$start^{commit}" > /dev/null; then
            start=$base
            "${git[@]}" rev-parse --verify --quiet "$start^{commit}" > /dev/null \
                || die "$(basename "$repo") has neither origin/$base nor $base"
        fi
        "${git[@]}" worktree add --quiet --no-track -b "$branch" "$path" "$start" >&2
    fi
    # Pushes go to the dev remote (the only one the relay lets us push to).
    if "${git[@]}" remote get-url dev > /dev/null 2>&1; then
        "${git[@]}" config "branch.$branch.pushRemote" dev
    fi
}

# write_conf <dir> <name> <slot> <addons_path>
# The main config ($ODOO_RC), with this task's addons, database and ports.
write_conf() {
    local dir=$1 name=$2 slot=$3 addons=$4
    {
        grep -Ev '^[[:space:]]*(addons_path|db_name|dbfilter|http_port|gevent_port)[[:space:]]*=' \
            /etc/odoo/odoo.conf
        echo
        echo "; Task $name (port offset, read by the task script, not by Odoo):"
        echo "; task slot = $slot"
        echo "addons_path = $addons"
        echo "db_name = $name"
        echo "dbfilter = ^$name\$"
        echo "http_port = $((BASE_HTTP_PORT + 100 * slot))"
        echo "gevent_port = $((BASE_GEVENT_PORT + 100 * slot))"
    } > "$dir/odoo.conf"
}

write_claude_files() {
    local dir=$1 name=$2 branch=$3 slot=$4
    local http=$((BASE_HTTP_PORT + 100 * slot)) gevent=$((BASE_GEVENT_PORT + 100 * slot))
    mkdir -p "$dir/.claude"
    cat > "$dir/.claude/settings.local.json" << EOF
{
  "env": {
    "ODOO_RC": "$dir/odoo.conf"
  }
}
EOF
    cat > "$dir/CLAUDE.md" << EOF
# Task: $name

This folder is an isolated task workspace (created by \`task new\`). Other
agents work in parallel in other folders of $TASKS, on other branches,
databases and ports. Stay in this folder.

- Code: \`$dir/community\` and \`$dir/enterprise\` (git worktrees),
  both on branch \`$branch\`. Never edit, check out or commit in the main
  checkouts \`$MAIN/community\` or \`$MAIN/enterprise\`, nor in other tasks.
- Config: \`$dir/odoo.conf\` (addons of this task's checkouts only).
- Database: \`$name\`. Filestore: \`~/.local/share/Odoo/filestore/$name\`.
  If you need a scratch database, name it \`${name}_<something>\` and drop it
  when done.
- Ports: HTTP $http, gevent $gevent. Never use 8069/8072 (the main instance).

## Running Odoo

Always run Odoo with \`obin\` (not \`./odoo-bin\`): from anywhere in this
folder, it runs this task's odoo-bin with this task's config.

    obin -i sale --stop-after-init               # install
    obin -u sale --test-tags /sale --stop-after-init   # tests
    obin                                         # server on port $http

Pushes go to the \`dev\` remote; Claude Code asks before any push.
EOF
}

# remove_task <name> [force]
# Refuses (unless forced) if a checkout has uncommitted changes or commits
# that aren't on any remote. Deletes the branch, unless it holds such commits.
remove_task() {
    local name=$1 force=${2:-}
    local dir=$TASKS/$name
    [ -d "$dir" ] || die "no task $name"

    local repo problems=()
    for repo in "${REPOS[@]}"; do
        local wt=$dir/$repo
        git -C "$wt" rev-parse --is-inside-work-tree > /dev/null 2>&1 || continue
        if [ -n "$(git -C "$wt" status --porcelain)" ]; then
            problems+=("$repo: uncommitted changes")
        fi
        if [ -n "$(git -C "$wt" rev-list -1 HEAD --not --remotes)" ]; then
            problems+=("$repo: unpushed commits on $(git -C "$wt" branch --show-current)")
        fi
    done
    if [ ${#problems[@]} -gt 0 ] && [ -z "$force" ]; then
        printf '  %s\n' "${problems[@]}" >&2
        die "task $name has unsaved work: push it, or task rm --force $name"
    fi

    for repo in "${REPOS[@]}"; do
        local wt=$dir/$repo
        [ -e "$wt" ] || continue
        local branch unpushed=
        branch=$(git -C "$wt" branch --show-current 2> /dev/null || true)
        if [ -n "$branch" ] \
            && [ -n "$(git -C "$wt" rev-list -1 "$branch" --not --remotes 2> /dev/null)" ]; then
            unpushed=1
        fi
        git -C "$MAIN/$repo" worktree remove --force "$wt" 2> /dev/null || rm -rf "$wt"
        if [ -n "$branch" ] && [ -z "$unpushed" ]; then
            git -C "$MAIN/$repo" branch --quiet -D "$branch" 2> /dev/null || true
        elif [ -n "$branch" ]; then
            log "$repo: kept branch $branch (unpushed commits)"
        fi
        git -C "$MAIN/$repo" worktree prune
    done

    dropdb --if-exists "$name" 2> /dev/null \
        || log "Couldn't drop database $name (in use?): dropdb $name"
    rm -rf "$HOME/.local/share/Odoo/filestore/$name" \
        "$HOME/.claude/projects/${dir//[^a-zA-Z0-9]/-}/memory"
    rm -rf "$dir"
    log "Removed task $name"
}

cmd_rm() {
    local name= force=
    for arg; do
        case $arg in
            --force|-f) force=1 ;;
            *) name=$arg ;;
        esac
    done
    [ -n "$name" ] || die "usage: task rm <name> [--force]"
    valid_name "$name"
    remove_task "$name" "$force"
}

cmd_list() {
    local dir
    printf '%-24s %-40s %-6s %s\n' TASK BRANCH PORT STATUS
    for dir in "$TASKS"/*/; do
        [ -f "$dir/odoo.conf" ] || continue
        local name branch status=clean wt
        name=$(basename "$dir")
        branch=$(git -C "$dir/community" branch --show-current 2> /dev/null \
            || git -C "$dir/enterprise" branch --show-current 2> /dev/null || echo '?')
        for wt in "$dir"community "$dir"enterprise; do
            [ -d "$wt" ] || continue
            if [ -n "$(git -C "$wt" status --porcelain 2> /dev/null)" ]; then
                status="changes"
            elif [ "$status" = clean ] \
                && [ -n "$(git -C "$wt" rev-list -1 HEAD --not --remotes 2> /dev/null)" ]; then
                status="unpushed"
            fi
        done
        printf '%-24s %-40s %-6s %s\n' "$name" "$branch" \
            "$(conf_get "$dir/odoo.conf" http_port)" "$status"
    done
}

# Claude Code's WorktreeCreate hook: `claude --worktree <name>`, EnterWorktree
# and subagents with isolation: "worktree" create a task. Gets {"name": ...}
# on stdin; prints the task's folder as the last line of stdout.
cmd_hook_create() {
    local name
    name=$(jq -r .name)
    # Claude Code's names may contain characters a database name shouldn't.
    name=$(echo "$name" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n-' '-' | cut -c1-40)
    cmd_new "$name"
}

# Claude Code's WorktreeRemove hook: gets {"worktree_path": ...} on stdin.
# Fails, keeping the task, if it has unsaved work.
cmd_hook_remove() {
    local path
    path=$(jq -r .worktree_path)
    case $path in
        "$TASKS"/*) remove_task "$(basename "$path")" ;;
        *) die "not a task: $path" ;;
    esac
}

case ${1:-} in
    new) shift; cmd_new "$@" ;;
    rm) shift; cmd_rm "$@" ;;
    list|ls) cmd_list ;;
    path) valid_name "${2:-}"; echo "$TASKS/$2" ;;
    hook-create) cmd_hook_create ;;
    hook-remove) cmd_hook_remove ;;
    *) sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2; exit 1 ;;
esac
