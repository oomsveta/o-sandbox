> [!WARNING]
> 🏗️ Work In Progress

> [!WARNING]
> Mostly vibe-coded slop ahead

This is my sandboxed setup for Odoo development with Claude Code inside VS Code devcontainers.

## Goals

### Filesystem Isolation

Claude Code (or any other malicious program running in the container) can't access anything on my computer beyond what's explicitly bind-mounted into the container (see `volumes` in [docker-compose.yml](./docker-compose.yml)).

### Network Isolation

#### HTTPS

All outbound HTTPS requests go through [mitmproxy](https://www.mitmproxy.org/), which enforces the strict whitelist defined in [`egress-policy.toml`](./egress-proxy/egress-policy.toml).

> [!TIP]
> Claude Code doesn't need the container to have unrestricted Internet access to do web searches; these are handled directly on Anthropic's end. Meaning, I only need to whitelist Anthropic's domains.

> [!NOTE]
> Git over HTTPS is fetch-only, without credentials.

#### SSH

Outbound SSH connections to `git@github.com` are redirected to the `git-relay` container. It only allows fetches and pushes for the allowed repositories, and pushes only to the allowed branches, as defined in [egress-policy.toml](./egress-proxy/egress-policy.toml).

The SSH key is never exposed to Claude Code or anything outside the `git-relay` container.

#### Known gap: exfiltration through Anthropic's API

The whole of `.anthropic.com` is allowed, for any method, because Claude Code needs it. Anything running in the container can therefore send data to the Anthropic API with *someone else's* API key (e.g. upload it with the Files API, or simply put it in a prompt), and that someone can then read it back. The proxy can't tell such requests apart from Claude Code's own without inspecting the API key, which it doesn't do.

#### Logs

Logs of allow/deny decisions, readable from inside the container:

- `/etc/egress-proxy/egress.log` for HTTPS
- `/etc/git-relay/relay.log` for git (SSH)

## Requirements

- VSCode with the Dev Containers extension (ms-vscode-remote.remote-containers). <sup><sub>Unfortunately, support for devcontainers isn't good enough (yet?) in VSCodium 🥲</sub></sup>
- A running Docker daemon

## Setup

- Clone this repo as `.devcontainer/` in a project folder, next to the Odoo repos that get mounted into the container:
  ```
  odoo/
  ├── .devcontainer/   ← this repo
  ├── community/
  ├── enterprise/
  └── rsfu/
  ```
  and open `odoo/` in VS Code.
- The SSH agent on the host must have the GitHub key loaded (`ssh-add -l`). The git relay reaches the agent through through the socket that OrbStack / Docker Desktop exposes at `/run/host-services/ssh-auth.sock`.
- In VS Code's user settings: `"dev.containers.gitCredentialHelperConfigLocation": "none"` so that the host's git credentials aren't passed to the container.

## 🏗️ TODO

1. Prevent code execution through git hooks
2. Write a TODO list
3. ???
4. Profit.
