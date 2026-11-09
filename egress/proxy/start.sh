#!/usr/bin/env sh

set -eu

# Custom entrypoint for the egress proxy container. Runs as root only long
# enough to set up the shared directory, then delegates to the base image's
# built-in script (docker-entrypoint.sh), which drops root privileges and
# launches the proxy.

# Shared with the dev container (read-only there): CA certificate and log.
install -d -o mitmproxy -g mitmproxy -m 755 /srv/egress

exec docker-entrypoint.sh mitmdump \
    --listen-port 8080 \
    --set connection_strategy=lazy \
    --set flow_detail=0 \
    --scripts /addons/policy.py
