> [!WARNING]
> Work In Progress

## Limit disk access

Only volumes defined in docker-compose.yml are mounted. These are still the actual files from my computer.

TODO: do something about git hooks

## Limit Internet access

The dev container is on an internal Docker network with no route to the Internet. It can only reach two other containers, which enforce my policy, `egress-proxy/egress-policy.toml`. Changes to that file apply right away, no restart needed.

- `proxy` (egress-proxy/): an HTTPS proxy (mitmproxy) that decrypts every request and only lets through the allowed hosts and methods. Git over HTTPS is fetch-only, without credentials.
- `git-relay` (git-relay/): an SSH server that the container's `git@github.com:` remotes are redirected to. It only lets through fetches from and pushes to the allowed repos, and pushes to the allowed branches, then relays them to GitHub using my laptop's SSH agent. Claude never sees the key or any GitHub credentials.

Decision logs, readable from inside the container:

- `/etc/egress-proxy/egress.log` for HTTPS
- `/etc/git-relay/relay.log` for git

## Setup

- The SSH agent on the laptop must have my GitHub key loaded (`ssh-add -l`). The git relay gets it from OrbStack / Docker Desktop at `/run/host-services/ssh-auth.sock`.
- In VS Code's user settings: `"dev.containers.gitCredentialHelperConfigLocation": "none"`, so the Mac's git credentials aren't passed to the container.
