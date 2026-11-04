"""
Egress policy shared by the HTTPS proxy (policy.py, a mitmproxy addon) and
the git relay (../git-relay/relay.py). Standard library only.

The policy lives in egress-policy.toml next to this file. It is re-read
whenever it changes; if it becomes invalid, the last valid version stays in
effect, and if it is missing (or was never valid), everything is denied.
"""

import logging
import re
import tomllib
from pathlib import Path
from typing import NamedTuple

POLICY_FILE = Path(__file__).with_name("egress-policy.toml")

HTTP_METHODS = frozenset({"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"})
REPO = re.compile(r"[a-z0-9][a-z0-9_.-]*/[a-z0-9_.-]+")
GIT_SERVICES = ("git-upload-pack", "git-receive-pack")

# A child of the "egress" logger that policy.py and relay.py log to.
log = logging.getLogger("egress.policy")


class HostRule(NamedTuple):
    host: str  # "example.com", or ".example.com" for it and its subdomains
    methods: frozenset | None  # None: any method
    path_prefix: str

    def matches_host(self, host):
        if self.host.startswith("."):
            return host == self.host[1:] or host.endswith(self.host)
        return host == self.host


class GitPolicy(NamedTuple):
    fetch: frozenset
    push: frozenset
    push_refs: re.Pattern
    push_allow_delete: bool


class Policy(NamedTuple):
    hosts: tuple
    git: GitPolicy


DENY_ALL = Policy((), GitPolicy(frozenset(), frozenset(), re.compile(r"(?!)"), False))


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------


def _names(keys):
    return ", ".join(sorted(keys))


def _parse_hosts(entries):
    if not isinstance(entries, list):
        raise TypeError("`allow` must be a list")
    rules = []
    for number, entry in enumerate(entries, 1):
        where = f"allow rule {number}"
        if not isinstance(entry, dict):
            raise TypeError(f"{where}: expected {{ host = ..., methods = ... }}")
        where += f" ({entry.get('host', 'no host')})"
        if unknown := set(entry) - {"host", "methods", "path"}:
            raise ValueError(f"{where}: unknown key(s) {_names(unknown)}")

        host = entry.get("host")
        if not isinstance(host, str) or not host.strip("."):
            raise ValueError(f"{where}: `host` must be a non-empty string")

        methods = entry.get("methods")
        if methods == "*":
            methods = None
        elif isinstance(methods, list) and methods and all(isinstance(m, str) for m in methods):
            methods = frozenset(m.upper() for m in methods)
            if unknown := methods - HTTP_METHODS:
                raise ValueError(f"{where}: unknown method(s) {_names(unknown)}")
        else:
            raise ValueError(f'{where}: `methods` must be "*" or a non-empty list of methods')

        path = entry.get("path", "/")
        if not isinstance(path, str) or not path.startswith("/"):
            raise ValueError(f"{where}: `path` must start with /")

        rules.append(HostRule(host.lower(), methods, path))
    return tuple(rules)


def _parse_repos(git, key):
    repos = git.get(key, [])
    if not isinstance(repos, list):
        raise TypeError(f"git.{key} must be a list")
    result = set()
    for repo in repos:
        if not isinstance(repo, str) or not REPO.fullmatch(repo.lower()):
            raise ValueError(f'git.{key}: {repo!r} is not an "owner/name" repo')
        result.add(repo.lower())
    return frozenset(result)


def _parse_git(git):
    if not isinstance(git, dict):
        raise TypeError("[git] must be a table")
    if unknown := set(git) - {"fetch", "push", "push_refs", "push_allow_delete"}:
        raise ValueError(f"[git]: unknown key(s) {_names(unknown)}")

    push_refs = git.get("push_refs", "(?!)")
    if not isinstance(push_refs, str):
        raise TypeError("git.push_refs must be a string")
    try:
        push_refs = re.compile(push_refs)
    except re.error as e:
        raise ValueError(f"git.push_refs is not a valid regex ({e})") from None

    allow_delete = git.get("push_allow_delete", False)
    if not isinstance(allow_delete, bool):
        raise TypeError("git.push_allow_delete must be true or false")

    return GitPolicy(_parse_repos(git, "fetch"), _parse_repos(git, "push"), push_refs, allow_delete)


def parse(text):
    """Parse egress-policy.toml.

    Raises ValueError, or TypeError for a value of the wrong type.
    """
    data = tomllib.loads(text)  # TOMLDecodeError is a ValueError
    if unknown := set(data) - {"allow", "git"}:
        raise ValueError(f"unknown top-level key(s): {_names(unknown)}")
    return Policy(_parse_hosts(data.get("allow", [])), _parse_git(data.get("git", {})))


_cache = {"mtime": None, "policy": DENY_ALL}


def current():
    """The policy from egress-policy.toml, re-read whenever the file changes."""
    try:
        mtime = POLICY_FILE.stat().st_mtime_ns
    except OSError as e:
        log.error("cannot read %s (%s), denying everything", POLICY_FILE, e)
        return DENY_ALL
    if mtime != _cache["mtime"]:
        _cache["mtime"] = mtime
        try:
            _cache["policy"] = policy = parse(POLICY_FILE.read_text())
            log.info(
                "loaded %s: %d host rules, %d fetch / %d push repos",
                POLICY_FILE.name,
                len(policy.hosts),
                len(policy.git.fetch),
                len(policy.git.push),
            )
        except (OSError, ValueError, TypeError) as e:
            log.error("%s: %s; keeping the previous policy", POLICY_FILE.name, e)
    return _cache["policy"]


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------


def host_known(policy, host):
    return any(r.matches_host(host) for r in policy.hosts)


def host_allows(policy, host, method, path):
    return any(
        r.matches_host(host)
        and (r.methods is None or method in r.methods)
        and path.startswith(r.path_prefix)
        for r in policy.hosts
    )


def normalize_repo(path):
    """ "/Owner/Name.git" -> "owner/name", or None if it isn't a repo path."""
    repo = path.strip("/").lower()
    repo = repo.removesuffix(".git")
    if REPO.fullmatch(repo) and ".." not in repo:
        return repo
    return None


def git_denial(policy, service, repo):
    """Why `service` (git-upload-pack or git-receive-pack) may not run on
    `repo`, or None if it may."""
    if service == "git-upload-pack":
        if repo not in policy.git.fetch | policy.git.push:
            return f"fetching from {repo} is not allowed (git.fetch)"
    elif service == "git-receive-pack":
        if repo not in policy.git.push:
            return f"pushing to {repo} is not allowed (git.push)"
    else:
        return f"git service {service!r} is not allowed"
    return None


def receive_pack_commands(data):
    """Ref updates at the start of a git-receive-pack request.

    The client sends pkt-lines "<old-oid> <new-oid> <ref>", the first one
    followed by "\\0<capabilities>", terminated by a flush packet "0000".
    The packfile follows. Raises ValueError on anything unexpected.
    """
    commands = []
    i = 0
    while i + 4 <= len(data):
        size = int(data[i : i + 4], 16)
        if size == 0:
            return commands
        if size < 4 or i + size > len(data):
            raise ValueError("bad pkt-line length")
        line = data[i + 4 : i + size].split(b"\0", 1)[0].rstrip(b"\n").decode()
        i += size
        if line.startswith("shallow "):
            continue
        old, new, ref = line.split(" ", 2)
        commands.append((old, new, ref))
    raise ValueError("no flush packet")


def push_problems(policy, data):
    """Reasons to refuse the ref updates at the start of `data` (empty if none)."""
    try:
        commands = receive_pack_commands(data)
    except ValueError as e:
        return [f"unparseable push request ({e})"]
    problems = []
    for _old, new, ref in commands:
        if not policy.git.push_refs.fullmatch(ref):
            problems.append(f"{ref} does not match git.push_refs")
        elif set(new) == {"0"} and not policy.git.push_allow_delete:
            problems.append(f"deleting {ref} is not allowed (git.push_allow_delete)")
    return problems
