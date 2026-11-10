#!/usr/bin/env bash

# Makes the skills Odoo ships in community/skills/ available to Claude Code,
# which only discovers skills in .claude/skills/ folders: links each one into
# ~/.claude/skills/.
#
# Links from the host checkout (the read-only /host mount), so the skills
# don't depend on the branch checked out in /odoo/community; they follow the
# host's branch instead.
#
# Run when the container starts (postStartCommand), to pick up added skills
# and drop removed ones. Never fails: without skills, Claude Code still works.

set -uo pipefail

src=/host/community/skills
dest="$HOME/.claude/skills"

mkdir --parents "$dest"

# Drop the links of the previous run, including those to removed skills.
find "$dest" -maxdepth 1 -type l -lname "$src/*" -delete

if [ ! -d "$src" ]; then
    echo "link-skills: no $src, no Odoo skills for Claude Code" >&2
    exit 0
fi

for dir in "$src"/*/; do
    [ -f "${dir}SKILL.md" ] || continue
    ln --symbolic --force --no-dereference "${dir%/}" "$dest/" || true
done
