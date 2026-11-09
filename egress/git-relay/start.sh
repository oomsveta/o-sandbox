#!/usr/bin/env sh

set -eu

# Entrypoint of the git relay container (runs as root): prepares the keys
# and the log, then runs the SSH server.

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

# The key relay.py authenticates to GitHub with, readable by the git user
# (that relay.py runs as) only, outside of any volume: the host's own key if
# one is mounted (GIT_RELAY_SSH_KEY, see docker-compose.yml), otherwise the
# relay's own, generated once and kept in this container's volume. Either way,
# it never leaves this container: only its public key does.
HOST_KEY=/run/secrets/github_key
ACTIVE_KEY=/run/git-relay/github_key  # see relay.py
install -d -o git -g git -m 700 /run/git-relay
rm -f "$ACTIVE_KEY" "$SHARED/github_key.pub"
if grep -q "PRIVATE KEY" "$HOST_KEY" 2>/dev/null; then
    install -o git -g git -m 600 "$HOST_KEY" "$ACTIVE_KEY"
    # -P '': fails instead of prompting if the key has a passphrase.
    if public_key=$(ssh-keygen -y -P '' -f "$ACTIVE_KEY" 2>/dev/null); then
        echo "Using the host's SSH key (GIT_RELAY_SSH_KEY): $public_key" >&2
    else
        rm -f "$ACTIVE_KEY"
        public_key=""
        echo "error: the host's SSH key (GIT_RELAY_SSH_KEY) has a passphrase, which" \
            "the git relay can't type: git over SSH won't work. See the README." >&2
    fi
else
    install -d -o git -g git -m 700 "$KEYS/github"
    if [ ! -f "$KEYS/github/id_ed25519" ]; then
        ssh-keygen -q -t ed25519 -N '' -C "o-sandbox git relay" -f "$KEYS/github/id_ed25519"
    fi
    install -o git -g git -m 600 "$KEYS/github/id_ed25519" "$ACTIVE_KEY"
    public_key=$(cat "$KEYS/github/id_ed25519.pub")
    echo "GitHub key of the git relay, to add to your GitHub account: $public_key" >&2
fi
# Readable in the dev container at /etc/git-relay/github_key.pub.
if [ -n "$public_key" ]; then
    echo "$public_key" > "$SHARED/github_key.pub"
    chmod 644 "$SHARED/github_key.pub"
fi

# Written last: the dev container waits for it (see the healthcheck).
echo "git-relay $(cut -d' ' -f1,2 "$KEYS/ssh_host_ed25519_key.pub")" > "$SHARED/known_hosts.tmp"
chmod 644 "$SHARED/known_hosts.tmp"
mv "$SHARED/known_hosts.tmp" "$SHARED/known_hosts"

mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
