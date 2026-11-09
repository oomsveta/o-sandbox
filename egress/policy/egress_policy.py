"""
The egress policy, from policy.toml next to this file. Shared by the HTTPS
proxy (../https-proxy/filter.py) and the git relay (../git-relay/relay.py).

policy.toml is re-read whenever it changes. While it's missing or invalid,
everything is denied.
"""

import logging
import re
import tomllib
from pathlib import Path
from typing import NamedTuple

POLICY_FILE = Path(__file__).with_name("policy.toml")
HTTP_METHODS = {"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"}
REPO = re.compile(r"[a-z0-9][a-z0-9_.-]*/[a-z0-9_.-]+")  # "owner/name", lowercase

log = logging.getLogger("egress.policy")


class HostRule(NamedTuple):
    host: str  # "example.com", or ".example.com" for it and its subdomains
    methods: frozenset | None  # None: any method
    path: str  # path prefix

    def matches_host(self, host):
        if self.host.startswith("."):
            return host == self.host[1:] or host.endswith(self.host)
        return host == self.host


class Policy(NamedTuple):
    hosts: tuple = ()  # HostRules
    fetch: frozenset = frozenset()  # repos git may fetch from
    push: frozenset = frozenset()  # repos git may push to (and fetch from)
    push_refs: re.Pattern = re.compile(r"(?!)")  # refs a push may update
    push_allow_delete: bool = False

    def host_known(self, host):
        """Whether any rule is about `host`."""
        return any(rule.matches_host(host) for rule in self.hosts)

    def host_allows(self, host, method, path):
        return any(
            rule.matches_host(host)
            and (rule.methods is None or method in rule.methods)
            and path.startswith(rule.path)
            for rule in self.hosts
        )

    def git_denial(self, service, repo):
        """Why git `service` may not run on `repo`, or None if it may."""
        if service == "git-upload-pack":
            if repo not in self.fetch | self.push:
                return f"fetching from {repo} is not allowed (git.fetch)"
        elif service == "git-receive-pack":
            if repo not in self.push:
                return f"pushing to {repo} is not allowed (git.push)"
        else:
            return f"git service {service!r} is not allowed"
        return None

    def push_denials(self, updates):
        """Why a push's ref updates, [(new object id, ref)], may not happen."""
        denials = []
        for new, ref in updates:
            if not self.push_refs.fullmatch(ref):
                denials.append(f"{ref} does not match git.push_refs")
            elif set(new) == {"0"} and not self.push_allow_delete:
                denials.append(f"deleting {ref} is not allowed (git.push_allow_delete)")
        return denials


DENY_ALL = Policy()


def repo_name(path):
    """ "/Owner/Name.git" -> "owner/name", or None if `path` isn't a repo's."""
    repo = path.strip("/").lower().removesuffix(".git")
    return repo if REPO.fullmatch(repo) and ".." not in repo else None


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------
# Values of the wrong type make parse() raise some exception or other (e.g.
# AttributeError: 'int' object has no attribute 'lower'). Only the mistakes
# that wouldn't are checked explicitly.


def parse(text):
    """The Policy in `text`, policy.toml's content. Raises if it's invalid."""
    data = tomllib.loads(text)
    _check_keys(data, {"allow", "git"}, "policy.toml")
    git = data.get("git", {})
    _check_keys(git, {"fetch", "push", "push_refs", "push_allow_delete"}, "[git]")
    allow_delete = git.get("push_allow_delete", False)
    if not isinstance(allow_delete, bool):  # "false" would be truthy
        raise ValueError("git.push_allow_delete must be true or false")
    return Policy(
        hosts=tuple(_host_rule(rule) for rule in data.get("allow", [])),
        fetch=_repos(git.get("fetch", [])),
        push=_repos(git.get("push", [])),
        push_refs=re.compile(git.get("push_refs", r"(?!)")),
        push_allow_delete=allow_delete,
    )


def _check_keys(table, allowed, where):
    # Catches typos, which would otherwise be silently ignored.
    if unknown := set(table) - allowed:
        raise ValueError(f"{where}: unknown key(s) {', '.join(sorted(unknown))}")


def _host_rule(rule):
    host = rule["host"].lower()
    _check_keys(rule, {"host", "methods", "path"}, f"allow rule for {host!r}")
    if not host.strip("."):
        raise ValueError("allow rule with an empty host")
    if rule["methods"] == "*":
        methods = None
    else:
        methods = frozenset(method.upper() for method in rule["methods"])
        if unknown := methods - HTTP_METHODS:
            raise ValueError(f"allow rule for {host!r}: unknown method(s) {', '.join(unknown)}")
    path = rule.get("path", "/")
    if not path.startswith("/"):
        raise ValueError(f"allow rule for {host!r}: path must start with /")
    return HostRule(host, methods, path)


def _repos(repos):
    repos = frozenset(repo.lower() for repo in repos)
    if invalid := [repo for repo in repos if not REPO.fullmatch(repo)]:
        raise ValueError(f'not "owner/name" repos: {", ".join(invalid)}')
    return repos


_loaded = (None, DENY_ALL)  # (policy.toml's mtime, its Policy)


def current():
    """The Policy in policy.toml, re-read whenever the file changes."""
    global _loaded
    try:
        mtime = POLICY_FILE.stat().st_mtime_ns
    except OSError as e:
        log.error("%s, denying everything", e)
        return DENY_ALL
    if mtime != _loaded[0]:
        try:
            policy = parse(POLICY_FILE.read_text())
            log.info("loaded %s", POLICY_FILE)
        except Exception as e:
            log.error("invalid %s, denying everything: %s", POLICY_FILE, e)
            policy = DENY_ALL
        _loaded = (mtime, policy)
    return _loaded[1]
