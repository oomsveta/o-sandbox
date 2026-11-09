#!/usr/bin/env sh
# Warns if the host's SSH agent, which VS Code forwards into the dev container
# whatever we do (as /tmp/vscode-ssh-auth-*.sock), holds keys: anything in
# the container could then use them. The host's agent should stay empty (see
# "SSH" in the README).
#
# Run when VS Code attaches (postAttachCommand) and in every new terminal.
# Exits 1 if it found keys.

keys=""
for sock in /tmp/vscode-ssh-auth-*.sock; do
    [ -S "$sock" ] || continue
    # ssh-add -l: 0 when the agent has keys, 1 when it has none, 2 when it
    # can't be reached (sockets of past VS Code sessions).
    if found=$(SSH_AUTH_SOCK=$sock timeout 2 ssh-add -l 2>/dev/null); then
        keys="$keys$found
"
    fi
done
[ -z "$keys" ] && exit 0

red=$(printf '\033[1;31m') reset=$(printf '\033[0m')
cat >&2 <<EOF
${red}WARNING: the host's SSH agent holds keys, and VS Code forwards it into this
container: anything running here can use them.${reset}
${keys}
Empty it on the host (ssh-add -D) and keep keys out of it: see "SSH" in
.devcontainer/README.md.
EOF
exit 1
