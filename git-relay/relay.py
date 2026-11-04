"""
Forced command of the git relay's SSH server (see sshd_config): every SSH
connection from the dev container runs this script, whatever it asked for.

The dev container's git@github.com: remotes point here instead of GitHub.
This script reads the git command that was asked for (SSH_ORIGINAL_COMMAND),
checks it against egress-policy.toml, and runs it at GitHub over SSH,
authenticating with the Mac's SSH agent. For a push, it first reads the ref
updates the client sends and refuses the push, before any data reaches
GitHub, if one of them isn't allowed.

Decisions are logged to /srv/git-relay-shared/relay.log, which the dev
container can read at /etc/git-relay/relay.log. Anything written to stderr
is shown to the git user in the dev container.
"""

import logging
import os
import re
import shlex
import subprocess
import sys

sys.path.insert(0, "/policy")
import egress_policy

LOG_FILE = "/srv/git-relay-shared/relay.log"
AGENT_SOCK = "/run/git-relay/agent.sock"
GITHUB_KNOWN_HOSTS = "/etc/ssh/github_known_hosts"
# Ref updates are a few hundred bytes each; anything bigger is refused.
MAX_COMMANDS_SIZE = 1 << 20
# GIT_PROTOCOL as sent by git, e.g. "version=2".
GIT_PROTOCOL = re.compile(r"[A-Za-z0-9=:._-]{1,64}")

log = logging.getLogger("egress.relay")


def setup_log():
    logging.getLogger("egress").propagate = False
    log.setLevel(logging.INFO)
    # The policy logs every (re)load, i.e. every connection here: only
    # keep its errors.
    logging.getLogger("egress.policy").setLevel(logging.WARNING)
    try:
        handler = logging.FileHandler(LOG_FILE)
    except OSError:
        handler = logging.NullHandler()  # never fall back to stderr
    handler.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
    logging.getLogger("egress").addHandler(handler)


def refuse(reason):
    log.warning("DENY  %s: %s", os.environ.get("SSH_ORIGINAL_COMMAND", ""), reason)
    sys.stderr.write(
        f"git-relay: {reason}\nPolicy: .devcontainer/egress-proxy/egress-policy.toml\n"
    )
    return 1


def upstream_command(service, repo):
    """The command that runs `service` on `repo` at GitHub."""
    command = [
        "ssh",
        "-F", "/dev/null",  # ignore ssh_config files
        "-o", "BatchMode=yes",
        "-o", f"UserKnownHostsFile={GITHUB_KNOWN_HOSTS}",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UpdateHostKeys=no",
        "-o", "ForwardAgent=no",
        "-o", "ClearAllForwardings=yes",
    ]  # fmt: skip
    protocol = os.environ.get("GIT_PROTOCOL", "")
    if GIT_PROTOCOL.fullmatch(protocol):
        command += ["-o", f"SetEnv=GIT_PROTOCOL={protocol}"]
    # `repo` matched egress_policy.REPO, so it needs no further quoting.
    return [*command, "git@github.com", f"{service} '{repo}.git'"]


def upstream_env():
    return {
        "PATH": "/usr/bin:/bin",
        "HOME": os.environ.get("HOME", "/"),
        "SSH_AUTH_SOCK": AGENT_SOCK,
    }


def read_exact(fd, size):
    data = bytearray()
    while len(data) < size:
        chunk = os.read(fd, size - len(data))
        if not chunk:
            break
        data += chunk
    return bytes(data)


def read_commands(fd):
    """The pkt-lines the client sends up to the first flush packet, as raw
    bytes. Stops early at EOF, on garbage, or past MAX_COMMANDS_SIZE: what
    was read then fails to parse, and the push is refused."""
    data = bytearray()
    while len(data) < MAX_COMMANDS_SIZE:
        header = read_exact(fd, 4)
        data += header
        try:
            size = int(header, 16)
        except ValueError:
            break
        if size < 4:  # flush (0) or invalid
            break
        data += read_exact(fd, size - 4)
    return bytes(data)


def relay_push(policy, repo, argv):
    # GitHub's output goes straight to the client: it first advertises its
    # refs, and only then does the client send its ref updates.
    upstream = subprocess.Popen(argv, stdin=subprocess.PIPE, env=upstream_env())
    try:
        commands = read_commands(0)
        if problems := egress_policy.push_problems(policy, commands):
            upstream.kill()
            upstream.wait()
            return refuse("; ".join(problems))
        refs = [ref for _, _, ref in egress_policy.receive_pack_commands(commands)]
        log.info("ALLOW push to %s: %s", repo, ", ".join(refs) or "nothing")

        upstream.stdin.write(commands)
        while chunk := os.read(0, 1 << 16):
            upstream.stdin.write(chunk)
        upstream.stdin.close()
    except BrokenPipeError:
        pass  # GitHub hung up; its exit status tells the client why
    except BaseException:
        upstream.kill()
        raise
    return upstream.wait()


def main():
    setup_log()
    try:
        service, path = shlex.split(os.environ.get("SSH_ORIGINAL_COMMAND", ""))
    except ValueError:
        return refuse("only git fetch and push are supported")
    repo = egress_policy.normalize_repo(path)
    if repo is None:
        return refuse(f"{path!r} is not a GitHub repo path")

    policy = egress_policy.current()
    if reason := egress_policy.git_denial(policy, service, repo):
        return refuse(reason)

    argv = upstream_command(service, repo)
    if service == "git-upload-pack":
        log.info("ALLOW fetch from %s", repo)
        os.execvpe(argv[0], argv, upstream_env())
    return relay_push(policy, repo, argv)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        log.exception("relay error")
        sys.stderr.write("git-relay: internal error, see /etc/git-relay/relay.log\n")
        sys.exit(1)
