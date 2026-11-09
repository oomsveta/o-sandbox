"""
The git relay's forced command (see sshd_config): every SSH connection from
the dev container runs this, whatever command it asked for.

The dev container's git@github.com: remotes point here. This reads the git
command asked for (SSH_ORIGINAL_COMMAND), checks it against policy.toml, and
runs it at GitHub over SSH, with the key start.sh set up, which nothing
outside this container can read. A push's ref updates are checked before
anything reaches GitHub.

Decisions are logged to /srv/git-relay-shared/relay.log
(/etc/git-relay/relay.log in the dev container). Anything written to stderr
is shown by git in the dev container.
"""

import logging
import os
import re
import shlex
import subprocess
import sys

sys.path.insert(0, "/policy")  # ../policy/
import egress_policy

LOG_FILE = "/srv/git-relay-shared/relay.log"
GITHUB_KEY = "/run/git-relay/github_key"  # set up by start.sh
# A push's ref updates take a few hundred bytes each: refuse more than this.
MAX_UPDATES_SIZE = 1 << 20
GIT_PROTOCOL = re.compile(r"[A-Za-z0-9=:._-]{1,64}")  # as sent by git: "version=2"

# Runs a command at GitHub. -F /dev/null: no ssh_config, only these options.
SSH_TO_GITHUB = [
    "ssh", "-F", "/dev/null",
    "-o", "BatchMode=yes",
    "-o", "UserKnownHostsFile=/etc/ssh/github_known_hosts",
    "-o", "GlobalKnownHostsFile=/dev/null",
    "-o", "StrictHostKeyChecking=yes",
    "-o", "UpdateHostKeys=no",
    "-i", GITHUB_KEY,
    "-o", "IdentitiesOnly=yes",
    "-o", "IdentityAgent=none",
    "-o", "ForwardAgent=no",
    "-o", "ClearAllForwardings=yes",
]  # fmt: skip
SSH_ENV = {"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", "/")}

log = logging.getLogger("egress.relay")


def refuse(reason):
    log.warning("DENY  %s: %s", os.environ.get("SSH_ORIGINAL_COMMAND", ""), reason)
    print(f"git-relay: {reason}\nPolicy: .devcontainer/egress/policy/policy.toml", file=sys.stderr)
    return 1


def read_exact(fd, size):
    data = b""
    while len(data) < size and (chunk := os.read(fd, size - len(data))):
        data += chunk
    if len(data) < size:
        raise ValueError("unexpected end of input")
    return data


def read_ref_updates(fd):
    """Reads the ref updates at the start of a push, from the client.

    They are pkt-lines: a 4-digit hex length (itself included), then
    "<old object id> <new object id> <ref>", with "\\0<capabilities>" after
    the first one, and a flush packet ("0000") after the last one. The pack
    follows. Returns (the raw bytes read, [(new object id, ref)]). Raises
    ValueError on anything unexpected.
    """
    raw, updates = b"", []
    while len(raw) < MAX_UPDATES_SIZE:
        header = read_exact(fd, 4)
        raw += header
        size = int(header, 16)
        if size == 0:
            return raw, updates
        if size < 4:
            raise ValueError("bad pkt-line length")
        line = read_exact(fd, size - 4)
        raw += line
        line = line.split(b"\0", 1)[0].rstrip(b"\n").decode()
        if not line.startswith("shallow "):  # sent first by shallow clones
            _old, new, ref = line.split(" ", 2)
            updates.append((new, ref))
    raise ValueError("too many ref updates")


def push(policy, repo, command):
    # GitHub's output goes straight to the client: GitHub first advertises its
    # refs, and only then does the client send its ref updates, then the pack.
    github = subprocess.Popen(command, stdin=subprocess.PIPE, env=SSH_ENV)
    try:
        try:
            raw, updates = read_ref_updates(0)
            denials = policy.push_denials(updates)
        except ValueError as e:
            denials = [f"unparseable push ({e})"]
        if denials:
            github.kill()
            github.wait()
            return refuse("; ".join(denials))
        log.info("ALLOW push to %s: %s", repo, ", ".join(ref for _, ref in updates) or "nothing")

        github.stdin.write(raw)
        while chunk := os.read(0, 1 << 16):
            github.stdin.write(chunk)
        github.stdin.close()
    except BrokenPipeError:
        pass  # GitHub hung up: its own messages and exit status tell the client why
    except BaseException:
        github.kill()
        raise
    return github.wait()


def main():
    try:
        service, path = shlex.split(os.environ.get("SSH_ORIGINAL_COMMAND", ""))
    except ValueError:
        return refuse("only git fetch and push are supported")
    repo = egress_policy.repo_name(path)
    if repo is None:
        return refuse(f"{path!r} is not a GitHub repo path")
    policy = egress_policy.current()
    if reason := policy.git_denial(service, repo):
        return refuse(reason)
    if not os.path.exists(GITHUB_KEY):
        return refuse("the relay has no usable GitHub key, see its logs")

    command = SSH_TO_GITHUB.copy()
    protocol = os.environ.get("GIT_PROTOCOL", "")
    if GIT_PROTOCOL.fullmatch(protocol):
        command += ["-o", f"SetEnv=GIT_PROTOCOL={protocol}"]
    # `repo` matched egress_policy.REPO, so it needs no further quoting.
    command += ["git@github.com", f"{service} '{repo}.git'"]

    if service == "git-upload-pack":
        log.info("ALLOW fetch from %s", repo)
        os.execve("/usr/bin/ssh", command, SSH_ENV)
    return push(policy, repo, command)


if __name__ == "__main__":
    logging.basicConfig(filename=LOG_FILE, format="%(asctime)s %(message)s", level=logging.INFO)
    # The policy logs each time it's loaded, which here is every connection.
    logging.getLogger("egress.policy").setLevel(logging.WARNING)
    try:
        sys.exit(main())
    except Exception:
        log.exception("relay error")
        sys.exit("git-relay: internal error, see /etc/git-relay/relay.log")
