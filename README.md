> [!WARNING]
> Work In Progress

## Limit disk access

Only volumes defined in docker-compose.yml are mounted. These are still the actual files from my computer.

TODO: do something about git commit hooks

## Limit Internet access

Any request to the Internet goes through an egress proxy that enforces my policy. It also allows me to insert my github credentials into the request headers without ever exposing them to Claude.

All authenticated Github traffic has to go through HTTPS. Maybe I'll change it later. It'll require writing a custom SSH proxy.

The whitelist of allowed hosts can be found and modified in egress-proxy/allowed-host.toml
