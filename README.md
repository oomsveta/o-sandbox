# Odoo + Claude Code sandbox

> [!WARNING]
> 🏗️ Work In Progress

> [!WARNING]
> Mostly vibe-coded slop ahead

This repository contains my sandboxed setup for Odoo development with Claude Code inside VS Code dev containers.

It is written for my own use, but it shouldn't be too hard to adapt to someone else's environment. Feel free to reuse it or to take inspiration from it!

## Threat model

I treat everything running in the dev container as potentially hostile: unaligned Claude Code going rogue, the weekly npm supply-chain attack, or even odoo-bin used as an RCE vector (unlikely, as we write great software at Odoo), or anything else really.

✅😎 **Trusted:** the host, the Docker daemon, the `https-proxy` and `git-relay` containers, and [policy.toml](./egress/policy/policy.toml), which the dev container can read but not write.

❌👺 **Untrusted:** the dev container and everything in it, including root (`dev` has passwordless `sudo`, so the boundary is Docker, not Unix users).

Whatever runs in the dev container:

- can't write anything on the host, and can only read the project folder (`/host`, read-only);
- can only reach the HTTPS hosts and methods allowed by the policy;
- can only fetch from and push to the repos and branches allowed by the policy;
- never sees the GitHub SSH key or the proxy's CA private key.

It can still damage what's inside the sandbox, like the container's clones, the database or Claude's config. It can also push to the branches the policy allows, and send data out through the Anthropic API. See [Limitations & known gaps](#limitations--known-gaps).

**Example:** Claude Code reads a web page that tells it to send `~/.ssh/id_ed25519` to `attacker.example.com`, and to push a backdoor to `odoo/odoo` `master`.

- There's no `~/.ssh` from the host in the container, and the relay's key isn't readable from it.
- The request to `attacker.example.com` is refused by the proxy and logged in `/etc/https-proxy/egress.log`.
- The push to `master` is refused by the relay, unless the policy allows it, and logged in `/etc/git-relay/relay.log`.
- Claude Code also asks before any `git push`.

## Requirements

- VS Code with the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension. <sup><sub>Unfortunately, support for dev containers isn't good enough (yet?) in VSCodium 🥲</sub></sup>
- A running Docker daemon with Docker Compose, e.g. Docker Desktop or OrbStack.

## Setup

1. Clone this repo as `.devcontainer/` in a project folder, next to the Odoo repos:
   ```
   odoo/
   ├── .devcontainer/   ← this repo
   ├── community/
   ├── enterprise/
   └── rsfu/
   ```
   The repos are optional, but they must be regular clones, not `git worktree`s. See [Git repositories](#git-repositories).
2. Empty the host's SSH agent. See [below](#emptying-the-hosts-ssh-agent).
3. In VS Code's user settings, set `"dev.containers.gitCredentialHelperConfigLocation": "none"` and `"dev.containers.copyGitConfig": false`, so neither the host's git credentials nor its `~/.gitconfig` are passed to the container.
4. Put your git identity in [dotfiles/gitconfig](./dotfiles/gitconfig). See [Git config](#git-config).
5. Open `odoo/` in VS Code and run **Dev Containers: Reopen in Container**. The first start builds the image, sets up the repos and installs Odoo's Python dependencies.
6. Add the relay's public key to your GitHub account (Settings → SSH and GPG keys). Get it with `cat /etc/git-relay/github_key.pub` in the dev container. To use your own key instead, see [Git relay (SSH)](#git-relay-ssh).

### Emptying the host's SSH agent

VS Code's Dev Containers extension always forwards the host's SSH agent into the dev container, as `/tmp/vscode-ssh-auth-*.sock`, and no setting turns that off. [devcontainer.json](./devcontainer.json) blanks `SSH_AUTH_SOCK`, but that only hides the socket. Anything in the container can still find it and have the agent sign with the host's keys, e.g. to log in to GitHub as you or to sign commits.

So the host's agent must hold no keys. Git on the host uses its key file directly instead, with the passphrase from the macOS Keychain:

```
# ~/.ssh/config on the host
Host github.com
    IdentityFile ~/.ssh/id_ed25519
    UseKeychain yes
    AddKeysToAgent no
```

Then run `ssh-add -D` to empty the agent, and remove anything that refills it at login (e.g. `ssh-add --apple-load-keychain` in a shell rc file). On a host other than macOS, drop `UseKeychain`: ssh then asks for the passphrase each time.

[`check-ssh-agent`](./dotfiles/check-ssh-agent.sh) checks this every time VS Code attaches and in every new terminal, and warns loudly if the forwarded agent holds keys.

## Daily use

### Running Odoo

TODO
<!-- odoo-bin, ODOO_RC, ports 8069/8072, admin_passwd -->

### Running tests

TODO

### Debugging

TODO

### Claude Code

TODO
<!-- Login and its persistence, updates (autoupdater disabled → rebuild) -->

## Configuration

TODO

| Setting | Where | Purpose |
|---|---|---|
| | | |

## Changing the egress policy

TODO
<!-- Blocked → check logs → edit policy.toml on the host → retry. One HTTPS and one git example. -->

## Data & persistence

TODO
<!-- Volumes and what each holds; what survives a rebuild; resetting safely.
     Warning: unpushed work lives in the `src` volume. -->

## How it works

The dev container is attached only to the `internal` Docker network, which has no route to the outside world. The `https-proxy` and `git-relay` containers are also attached to the `egress` network: they are its only ways out, and both enforce [policy.toml](./egress/policy/policy.toml).

### Filesystem isolation

The only host folder mounted in the dev container is the project folder (the parent of `.devcontainer/`), read-only, at `/host`. Everything else the container writes goes to Docker volumes (see [Data & persistence](#data--persistence)).

#### Git repositories

The container works in its own clones of the Odoo repos, in the `src` volume mounted at `/odoo`, and never writes to the repos on the host.

**Why:** git runs commands from a repo's config and hooks. A container that could write to a host repo could make the host run anything the next time git touches it, e.g. through `core.fsmonitor` (run by every `git status`, so as soon as a shell prompt or an editor opens the folder) or a hook (Odoo's repos point `core.hooksPath` inside the working tree). That would escape the sandbox, with the host's SSH keys, credentials and unrestricted Internet access.

**How:** when the container is created, [seed-repos.sh](./odoo/seed-repos.sh) sets up each repo of its `REPOS` list that isn't in `/odoo` yet:

- If the host has it: a clone that *borrows* the host's objects through [git alternates](https://git-scm.com/docs/gitrepository-layout#Documentation/gitrepository-layout.txt-objectsinfoalternates), like `git clone --shared`. It takes seconds, copies no history, and gets the host's branches, tags, remotes and checked-out branch, but not its other git config (hooks, aliases…) or its uncommitted changes. New objects go to the container's volume.
- Otherwise: a partial clone (`--filter=blob:none`) from GitHub through the git relay, with the other remotes from `REPOS`.

Then it enables [Odoo's JS tooling](https://github.com/odoo/odoo/tree/master/addons/web/tooling) in community and enterprise, like `addons/web/tooling/enable.sh` does: lint-on-commit hooks, ESLint config and `npm install`. These hooks live in the container's clones, so they only run there.

**Tradeoffs:**

- **The checkouts are separate**, as if on two machines. Container changes reach the host by pushing (through the git relay) and fetching. Host commits can be fetched instantly from the mount: `git fetch /host/community my-branch:my-branch`.
- **The clones depend on the host's objects.** If the host deletes a branch and git's garbage collection prunes its commits (by default two weeks later) while a container branch is built on them, that branch breaks (`fatal: bad object`). Long-lived branches (`master`, `19.0`…) are safe. `git repack -a -d` in a container repo removes the dependency, at a cost of about 3 GB each for community and enterprise.
- **Working trees aren't shared:** each checkout takes about 1 GB for community and enterprise, and the host's untracked files (builds, `node_modules`…) aren't in the container.
- **`seed-repos` only sets up missing repos**, and only enables the JS tooling in those. A repo that fails is removed and retried on the next container creation or `seed-repos` run. To start a repo over from the host's state: `rm -rf /odoo/community && seed-repos`.

### HTTPS proxy

All outbound HTTPS requests go through [mitmproxy](https://www.mitmproxy.org/), set as `HTTPS_PROXY` in the dev container. It decrypts each request and checks its host, method and path against the `allow` rules of the policy ([filter.py](./egress/https-proxy/filter.py)). The dev container trusts the proxy's CA certificate. The CA's private key stays in the proxy's own volume.

Edits to the policy apply on the next request, with no restart. While the policy is invalid, everything is refused.

Git over HTTPS (`https://github.com/…` remotes) goes through the proxy too, without credentials: it can only fetch public repos, and never push.

> [!TIP]
> Claude Code doesn't need unrestricted Internet access to search the web: searches run on Anthropic's end. Allowing Anthropic's domains is enough.

### Git relay (SSH)

In the dev container, `git@github.com:` remotes are rewritten (with git's `url.<base>.insteadOf`) to point to the `git-relay` container. It's an SSH server that checks each fetch and push against the `[git]` section of the policy ([relay.py](./egress/git-relay/relay.py)), then relays it to GitHub:

- fetches only from the repos in `fetch` or `push`;
- pushes only to the repos in `push`, and only to the refs matching `push_refs`;
- deletes refs only if `push_allow_delete` is set.

The relay authenticates to GitHub with an SSH key that nothing outside the `git-relay` container can read. The dev container only gets its public key, at `/etc/git-relay/github_key.pub`. By default, it's the relay's own key, generated on its first start in its own Docker volume, which is never mounted anywhere else.

To use the host's own key instead, set `GIT_RELAY_SSH_KEY` to its absolute path, e.g. in `.devcontainer/.env` (gitignored):

```
GIT_RELAY_SSH_KEY=/Users/you/.ssh/id_ed25519
```

> [!NOTE]
> Make sure you provide a path without the "tilde expansion" (no `~/`).

It's mounted, read-only, into the `git-relay` container only. It must not have a passphrase, as the relay can't type it (it says so in its logs). It must not be in the project folder either, which the dev container can read through `/host`.

The relay's own key is the safer choice: it only exists for GitHub, and it can be revoked on its own if the relay is ever compromised. The host's key is typically also used elsewhere (other servers, commit signing), and revoking it means replacing it everywhere.

### Git config

VS Code copies the host's `~/.gitconfig` into the dev container by default. Setup step 3 turns that off (`dev.containers.copyGitConfig`): it would bring in settings meant for the host, e.g. credential helpers, commit signing through the SSH agent, or paths that only exist there.

Instead, the image gets [dotfiles/gitconfig](./dotfiles/gitconfig) as `~/.gitconfig`, with my git identity and settings. Edit it to use yours, then rebuild the container.

`git config --global` works, but its changes are lost when the container is rebuilt. Put the ones to keep in `dotfiles/gitconfig`.

### Claude Code settings

[managed-settings.json](./claude/managed-settings.json) is installed as Claude Code's managed settings, which take precedence over user and project settings:

- Claude Code asks for confirmation before any `git push`.
- Bypass permissions mode (`--dangerously-skip-permissions`) is disabled.

Claude Code's auto-updater is also disabled, since Claude Code is installed in a root-owned folder. Rebuild the container to update it.

## Limitations & known gaps

- VS Code forwards the host's SSH agent into the dev container, and this can't be disabled. The sandbox relies on the agent staying empty (see [Emptying the host's SSH agent](#emptying-the-hosts-ssh-agent)).
- All of .anthropic.com is whitelisted, for any method, because Claude Code needs it. This means an attacker could technically exfiltrate data through Anthropic's API using their own API key.
- The dev container can read the whole project folder through `/host`, not just each repo's `.git`. Don't keep secrets in it.
- The GitHub SSH key has no passphrase: the relay's own sits unencrypted in a Docker volume, the host's in its file. Anyone with access to the host's Docker daemon can read it.
- GitHub can't restrict an SSH key to some repos: the key can do anything my GitHub account can. Only the relay's policy narrows it down.
- The relay can't tell force pushes from regular ones: a force push to a branch matching `push_refs` is allowed. Use GitHub branch protection if that matters.
- Claude Code's managed settings are a safeguard, not a boundary: with `sudo`, anything in the container can change them.

## Troubleshooting

TODO

## Verifying the sandbox

TODO
