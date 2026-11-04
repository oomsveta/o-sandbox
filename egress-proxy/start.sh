#!/usr/env/bin sh

set -eu

# Custom entrypoint for the egress proxy container. Runs as root only long
# enough to set up the token and shared directory, then delegates to the base
# image's built-in script (docker-entrypoint.sh), which drops root privileges
# and launches the proxy.

# Shared with the dev container (read-only there): CA certificate and log.

install -d -o mitmproxy -g mitmproxy -m 755 /srv/egress

# The mounted secret inherits the host machine's file ownership, making it
# unreadable to non-root users. Copy it with strict private permissions (600) so
# only the unprivileged mitmproxy user can access it.
if [ -s /run/secrets/github_token ]; then
    install -o mitmproxy -g mitmproxy -m 600 /run/secrets/github_token /home/mitmproxy/github-token
else
    echo "warning: no GitHub token, git will only reach public repos" >&2
fi

exec docker-entrypoint.sh mitmdump \
    --listen-port 8080 \
    --set connection_strategy=lazy \
    --set flow_detail=0 \
    --scripts /addons/policy.py
