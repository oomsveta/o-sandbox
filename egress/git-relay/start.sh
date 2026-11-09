#!/usr/bin/env sh
# Entrypoint of the git relay container, as root: sets up the keys and the
# log, then runs the SSH server.
set -eu

KEYS=/srv/git-relay-keys      # volume private to this container
SHARED=/srv/git-relay-shared  # volume read-only in the dev container, at /etc/git-relay
DEV_UID=1000                  # the dev container's user (see ../../Dockerfile)

# Generates the passphrase-less SSH key $1 (and $1.pub) with comment $2,
# unless it exists.
keygen() {
    [ -f "$1" ] || ssh-keygen -q -t ed25519 -N '' -C "$2" -f "$1"
}

# The relay's host key, that the dev container checks (known_hosts below).
keygen "$KEYS/ssh_host_ed25519_key" git-relay

# The key the dev container logs in with. It only lets it run relay.py, so
# anything in the dev container may use it. ssh wants it to be its user's.
chmod 755 "$SHARED"
keygen "$SHARED/client_key" dev-container
chown "$DEV_UID" "$SHARED/client_key"
echo "restrict $(cat "$SHARED/client_key.pub")" > /etc/ssh/git_authorized_keys

# The decision log, written by relay.py as the git user. Started over past 1 MB.
LOG=$SHARED/relay.log
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 1000000 ]; then
    mv "$LOG" "$LOG.1"
fi
touch "$LOG"
chown git:git "$LOG"

# The key relay.py authenticates to GitHub with: the host's if one is mounted
# (GIT_RELAY_SSH_KEY, see docker-compose.yml), otherwise the relay's own.
# Copied out of any volume, readable by relay.py's user (git) only. Only its
# public key leaves this container.
if grep -q "PRIVATE KEY" /run/secrets/github_key; then
    echo "Using the host's SSH key (GIT_RELAY_SSH_KEY)" >&2
    key=/run/secrets/github_key
else
    mkdir -p "$KEYS/github"
    keygen "$KEYS/github/id_ed25519" "o-sandbox git relay"
    key=$KEYS/github/id_ed25519
fi
install -d -o git -g git -m 700 /run/git-relay
install -o git -g git -m 600 "$key" /run/git-relay/github_key
# -P '': fails, rather than prompting, if the key has a passphrase.
if ssh-keygen -y -P '' -f /run/git-relay/github_key > "$SHARED/github_key.pub"; then
    echo "GitHub key of the git relay, to add to your GitHub account: $(cat "$SHARED/github_key.pub")" >&2
else
    rm /run/git-relay/github_key "$SHARED/github_key.pub"
    echo "error: the host's SSH key (GIT_RELAY_SSH_KEY) has a passphrase, which" \
        "the git relay can't type: git over SSH won't work. See the README." >&2
fi

# Written last, atomically: the dev container waits for it (healthcheck in
# docker-compose.yml).
echo "git-relay $(cut -d' ' -f1,2 "$KEYS/ssh_host_ed25519_key.pub")" > "$SHARED/known_hosts.tmp"
mv "$SHARED/known_hosts.tmp" "$SHARED/known_hosts"

mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
