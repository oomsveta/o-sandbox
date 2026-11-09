> [!WARNING]
> 🏗️ Work In Progress

> [!WARNING]
> Mostly vibe-coded slop ahead

This is my sandboxed setup for Odoo development with Claude Code inside VS Code devcontainers.

## Layout

```
.devcontainer/
├── devcontainer.json    VS Code entry point
├── docker-compose.yml   the services: dev container, database, and egress/
├── Dockerfile           dev container image, built from the files below
├── odoo/                odoo.conf, seed-repos.sh (sets up the repos in the container)
├── claude/              Claude Code managed settings
├── dotfiles/            shell and editor config
└── egress/              network sandbox: the only ways out of the dev container
    ├── policy/          what's allowed (policy.toml) and its parser, shared by:
    ├── proxy/           mitmproxy addon enforcing it for HTTPS
    └── git-relay/       SSH server enforcing it for git, with its own GitHub key
```

The database (`db`) uses the stock pgvector image.

## Goals

### Filesystem Isolation

Claude Code (or any other malicious program running in the container) can't access anything on my computer beyond what's explicitly bind-mounted into the container (see `volumes` in [docker-compose.yml](./docker-compose.yml)).

#### Git repositories

The container works in its own clones of the Odoo repos, in a Docker volume, and never writes to the repos on the host.

**Why:** git runs commands from a repo's config and hooks. A container that could write to a host repo could make the host run anything the next time git touches it, e.g. via `core.fsmonitor` (run by every `git status`, so as soon as a shell prompt or editor opens the folder) or a hook (Odoo's repos point `core.hooksPath` inside the working tree). That would escape the sandbox, with the host's SSH keys, credentials and unrestricted Internet access.

**How:** the project folder (the parent of `.devcontainer/`) is mounted read-only at `/host`. On container creation, [seed-repos.sh](./odoo/seed-repos.sh) sets up each repo in its `REPOS` that isn't in `/odoo` yet:

- If the host has it: a clone that *borrows* the host's objects through [git alternates](https://git-scm.com/docs/gitrepository-layout#Documentation/gitrepository-layout.txt-objectsinfoalternates), like `git clone --shared`. It takes seconds, copies no history, and gets the host's branches, tags, remotes and checked-out branch, but not its other git config (hooks, aliases…) or uncommitted changes. New objects go to the container's volume.
- Otherwise: a partial clone (`--filter=blob:none`) from GitHub through the git relay, with the other remotes from `REPOS`. Override with `SEED_CLONE_ARGS` (e.g. `"--depth=1"`) in `containerEnv` in [devcontainer.json](./devcontainer.json).

Then [Odoo's JS tooling](https://github.com/odoo/odoo/tree/master/addons/web/tooling) is enabled in community and enterprise, like `addons/web/tooling/enable.sh`: lint-on-commit hooks, ESLint config and `npm install`. These hooks live in the container's clone, so they only run there.

**Tradeoffs:**

- **The checkouts are separate**, like on two machines. Container changes reach the host by pushing (through the git relay) and fetching. Host commits can be fetched instantly from the mount: `git fetch /host/community my-branch:my-branch`.
- **The clones depend on the host's objects.** If the host deletes a branch and git's GC prunes its commits (by default two weeks later) while a container branch is built on them, that branch breaks (`fatal: bad object`). Long-lived branches (`master`, `19.0`…) are safe. `git repack -a -d` in a container repo removes the dependency, at ~3 GB each for community and enterprise.
- **Working trees aren't shared**: each checkout takes ~1 GB for community and enterprise, and the host's untracked files (builds, `node_modules`…) aren't in the container.
- **The container can read the whole project folder**, not just each repo's `.git`, because Docker would create missing mount sources on the host as empty folders. Don't keep secrets in it.
- **`seed-repos` only sets up missing repos** (and only enables the JS tooling in those). A failed repo is removed and retried on the next container creation or `seed-repos` run. To start a repo over from the host's state: `rm -rf /odoo/community && seed-repos`.

### Network Isolation

#### HTTPS

All outbound HTTPS requests go through [mitmproxy](https://www.mitmproxy.org/), which enforces the strict whitelist defined in [`policy.toml`](./egress/policy/policy.toml).

> [!TIP]
> Claude Code doesn't need the container to have unrestricted Internet access to do web searches; these are handled directly on Anthropic's end. Meaning, I only need to whitelist Anthropic's domains.

> [!NOTE]
> Git over HTTPS is fetch-only, without credentials.

#### SSH

Outbound SSH connections to `git@github.com` are redirected to the `git-relay` container. It only allows fetches and pushes for the allowed repositories, and pushes only to the allowed branches, as defined in [policy.toml](./egress/policy/policy.toml).

The relay authenticates to GitHub with an SSH key that nothing outside the `git-relay` container can read: the dev container only gets its public key (`/etc/git-relay/github_key.pub`). By default, it's the relay's own key, generated on its first start in its own Docker volume, which is never mounted anywhere else.

To use the host's own key instead, set `GIT_RELAY_SSH_KEY` to its absolute path, e.g. in `.devcontainer/.env` (gitignored):

```
GIT_RELAY_SSH_KEY=/Users/wil/.ssh/id_ed25519
```

It's mounted, read-only, into the `git-relay` container only. It must not have a passphrase, as the relay has no way to type it: if it does, the relay says so in its logs and git over SSH doesn't work. It must not be in the project folder either, which the dev container can read (`/host`).

**Tradeoffs:**

- **The key has no passphrase**: the relay's own sits unencrypted in a Docker volume, the host's in its file. Anyone with access to the Docker daemon on the host can read it.
- **GitHub can't restrict an account's SSH key to some repos**: the key can do whatever my GitHub account can. Only the relay's policy narrows it down.
- **The relay's own key is the safer choice**: it can be revoked on its own if the relay is ever compromised, and it only exists for GitHub. The host's key is typically also used elsewhere (other servers, commit signing), and revoking it means replacing it everywhere.

##### The host's SSH agent must stay empty

VS Code's Dev Containers extension forwards the host's SSH agent into the dev container, as `/tmp/vscode-ssh-auth-*.sock`, and there's no setting to turn that off. [devcontainer.json](./devcontainer.json) blanks `SSH_AUTH_SOCK`, but that only hides the socket: anything in the container can still find it and have the agent sign with the host's keys, e.g. to log in to GitHub as me, or to sign commits.

So the host's agent holds no keys. Git on the host uses its key file directly, with the passphrase from the macOS Keychain, instead of going through the agent:

```
# ~/.ssh/config on the host
Host github.com
    IdentityFile ~/.ssh/id_ed25519
    UseKeychain yes
    AddKeysToAgent no
```

then `ssh-add -D` to empty the agent, and nothing that refills it at login (e.g. `ssh-add --apple-load-keychain` in a shell rc). `check-ssh-agent` warns, loudly, whenever VS Code attaches and in every new terminal, if the forwarded agent holds keys.

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

- Clone this repo as `.devcontainer/` in a project folder, next to the Odoo repos (see [Git repositories](#git-repositories)):
  ```
  odoo/
  ├── .devcontainer/   ← this repo
  ├── community/
  ├── enterprise/
  └── rsfu/
  ```
  and open `odoo/` in VS Code. The repos are optional: the container clones those the host doesn't have from GitHub (which takes longer). Those it does have must be regular clones (with a `.git` folder, not a `git worktree`). The repos and their remotes are listed in `REPOS` at the top of [seed-repos.sh](./odoo/seed-repos.sh).
- Add the git relay's GitHub key to your GitHub account (Settings → SSH and GPG keys), and authorize it for SSO for organizations that require it (e.g. odoo). Its public key is printed in the relay's logs on start, and readable in the dev container: `cat /etc/git-relay/github_key.pub`. Until then, git over SSH fails with `Permission denied (publickey)`. Or use your own key (see [SSH](#ssh)).
- Keep the host's SSH agent empty (see [The host's SSH agent must stay empty](#the-hosts-ssh-agent-must-stay-empty)).
- In VS Code's user settings: `"dev.containers.gitCredentialHelperConfigLocation": "none"` so that the host's git credentials aren't passed to the container.

## 🏗️ TODO

1. Write a TODO list
2. ???
3. Profit.
