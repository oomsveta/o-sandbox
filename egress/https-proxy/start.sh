#!/usr/bin/env sh

# Entrypoint of the HTTPS proxy container, as root: creates the directory
# shared with the dev container (CA certificate and log, read-only there),
# then hands over to the image's own entrypoint, which drops root and runs
# mitmdump with filter.py as an addon.
set -eu

install -d -o mitmproxy -g mitmproxy -m 755 /srv/egress

exec docker-entrypoint.sh mitmdump \
    --listen-port 8080 \
    --set connection_strategy=lazy \
    --set flow_detail=0 \
    --scripts /https-proxy/filter.py
