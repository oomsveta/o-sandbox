#!/usr/bin/env sh

set -eu

# Entrypoint of the git relay container (runs as root): prepares the keys,
# the log and the SSH agent socket, then runs the SSH server.

KEYS=/srv/git-relay-keys      # private to this container
SHARED=/srv/git-relay-shared  # read-only in the dev container, at /etc/git-relay
DEV_UID=${DEV_UID:-1000}

# This relay's host key: generated once, kept in a volume.
if [ ! -f "$KEYS/ssh_host_ed25519_key" ]; then
    ssh-keygen -q -t ed25519 -N '' -C git-relay -f "$KEYS/ssh_host_ed25519_key"
fi

# The key the dev container logs in with. It only grants running relay.py,
# so anything in the dev container may read it. It must belong to the dev
# user for ssh to accept it.
chmod 755 "$SHARED"
if [ ! -f "$SHARED/client_key" ]; then
    ssh-keygen -q -t ed25519 -N '' -C dev-container -f "$SHARED/client_key"
fi
chown "$DEV_UID" "$SHARED/client_key"
chmod 600 "$SHARED/client_key"
echo "restrict $(cat "$SHARED/client_key.pub")" > /etc/ssh/git_authorized_keys
chmod 644 /etc/ssh/git_authorized_keys

# Decision log, written by relay.py as the git user. Start over past 1 MB.
if [ -f "$SHARED/relay.log" ] && [ "$(stat -c %s "$SHARED/relay.log")" -gt 1000000 ]; then
    mv "$SHARED/relay.log" "$SHARED/relay.log.1"
fi
touch "$SHARED/relay.log"
chown git:git "$SHARED/relay.log"
chmod 644 "$SHARED/relay.log"

# The Mac's SSH agent, re-exposed for the git user only.
HOST_AGENT=/run/host-services/ssh-auth.sock
install -d -o git -g git -m 700 /run/git-relay
if [ -S "$HOST_AGENT" ]; then
    socat "UNIX-LISTEN:/run/git-relay/agent.sock,fork,user=git,group=git,mode=600" \
        "UNIX-CONNECT:$HOST_AGENT" &
else
    echo "warning: no SSH agent at $HOST_AGENT, git can't authenticate to GitHub" >&2
fi

# Written last: the dev container waits for it (see the healthcheck).
echo "git-relay $(cut -d' ' -f1,2 "$KEYS/ssh_host_ed25519_key.pub")" > "$SHARED/known_hosts.tmp"
chmod 644 "$SHARED/known_hosts.tmp"
mv "$SHARED/known_hosts.tmp" "$SHARED/known_hosts"

mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
