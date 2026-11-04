"""
Egress policy for the Odoo dev container, loaded by mitmdump (see start.sh).

The dev container sits on an `internal` Docker network with no route to the
internet; this proxy is its only way out. The container trusts our CA, so
every HTTPS request is decrypted and checked against allowed-hosts.toml.
Anything not explicitly allowed gets a 403.

GitHub gets special treatment: git traffic is only allowed to the repos
listed below, and the proxy adds the GitHub token itself, so the dev
container never sees it.

mitmdump reloads this file when it changes, and allowed-hosts.toml is
re-read when it changes; no restart needed.
Every decision is logged to /srv/egress/egress.log, which the dev container
can read at /etc/egress-proxy/egress.log.
"""

import base64
import logging
import logging.handlers
import os
import re
import shutil
import tomllib
from pathlib import Path
from typing import NamedTuple

from mitmproxy import ctx, http, tcp

# ---------------------------------------------------------------------------
# Policy (allowed hosts: see allowed-hosts.toml)
# ---------------------------------------------------------------------------

# Repos ("owner/name", lowercase) git may fetch from, and push to.
# The GitHub token is added to every git request to these repos.
GIT_FETCH = {
    "odoo/odoo",
    "odoo/enterprise",
    "odoo-dev/odoo",
    "odoo-dev/enterprise",
}
GIT_PUSH = {
    "odoo-dev/odoo",
    "odoo-dev/enterprise",
}
# Refs a push may update (full match). Odoo dev branches end with the
# author's trigram, e.g. refs/heads/master-fix-foo-wil.
GIT_PUSH_REFS = re.compile(r"refs/heads/[\w./-]+-wil")
# Whether a push may delete refs (that still match GIT_PUSH_REFS).
# The proxy cannot tell a force push from a regular one; use GitHub branch
# protection if that matters.
GIT_PUSH_ALLOW_DELETE = False

# ---------------------------------------------------------------------------
# Implementation
# ---------------------------------------------------------------------------

HOSTS_FILE = Path(__file__).with_name("allowed-hosts.toml")
STATE_DIR = Path(os.environ.get("EGRESS_STATE_DIR", "/srv/egress"))
TOKEN_FILE = Path(os.environ.get("GITHUB_TOKEN_FILE", "/home/mitmproxy/github-token"))

GIT_PATH = re.compile(
    r"^/(?P<repo>[^/]+/[^/]+?)(?:\.git)?/(?P<endpoint>info/refs|git-upload-pack|git-receive-pack)$"
)

log = logging.getLogger("egress")


def _setup_file_log():
    # The module is re-executed on hot reload, but the logger is shared.
    if any(getattr(h, "egress_file", False) for h in log.handlers):
        return
    STATE_DIR.mkdir(exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(
        STATE_DIR / "egress.log", maxBytes=1_000_000, backupCount=2
    )
    handler.egress_file = True
    handler.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
    log.addHandler(handler)
    log.setLevel(logging.INFO)


def _normalize(host):
    return host.lower().rstrip(".")


HTTP_METHODS = {"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"}


class Rule(NamedTuple):
    host: str  # "example.com", or ".example.com" for it and its subdomains
    methods: frozenset | None  # None: any method
    path_prefix: str

    def matches_host(self, host):
        if self.host.startswith("."):
            return host == self.host[1:] or host.endswith(self.host)
        return host == self.host


def parse_hosts(text):
    """Parse allowed-hosts.toml.

    Raises ValueError, or TypeError for a value of the wrong type.
    """
    data = tomllib.loads(text)  # TOMLDecodeError is a ValueError
    if unknown := set(data) - {"allow"}:
        raise ValueError(f"unknown top-level key(s): {', '.join(sorted(unknown))}")
    entries = data.get("allow", [])
    if not isinstance(entries, list):
        raise TypeError("`allow` must be a list")

    rules = []
    for number, entry in enumerate(entries, 1):
        where = f"rule {number}"
        if not isinstance(entry, dict):
            raise TypeError(f"{where}: expected {{ host = ..., methods = ... }}")
        where += f" ({entry.get('host', 'no host')})"
        if unknown := set(entry) - {"host", "methods", "path"}:
            raise ValueError(f"{where}: unknown key(s) {', '.join(sorted(unknown))}")

        host = entry.get("host")
        if not isinstance(host, str) or not host.strip("."):
            raise ValueError(f"{where}: `host` must be a non-empty string")

        methods = entry.get("methods")
        if methods == "*":
            methods = None
        elif isinstance(methods, list) and methods and all(isinstance(m, str) for m in methods):
            methods = frozenset(m.upper() for m in methods)
            if unknown := methods - HTTP_METHODS:
                raise ValueError(f"{where}: unknown method(s) {', '.join(sorted(unknown))}")
        else:
            raise ValueError(f'{where}: `methods` must be "*" or a non-empty list of methods')

        path = entry.get("path", "/")
        if not isinstance(path, str) or not path.startswith("/"):
            raise ValueError(f"{where}: `path` must start with /")

        rules.append(Rule(host.lower(), methods, path))
    return rules


_hosts_cache = {"mtime": None, "rules": []}


def _rules():
    """Rules from allowed-hosts.toml, re-read whenever the file changes.

    If the file becomes invalid, the last valid rules stay in effect; if it
    is missing, nothing is allowed.
    """
    try:
        mtime = HOSTS_FILE.stat().st_mtime_ns
    except OSError as e:
        log.error("cannot read %s (%s), denying everything", HOSTS_FILE, e)
        return []
    if mtime != _hosts_cache["mtime"]:
        _hosts_cache["mtime"] = mtime
        try:
            _hosts_cache["rules"] = parse_hosts(HOSTS_FILE.read_text())
            log.info("loaded %d rules from %s", len(_hosts_cache["rules"]), HOSTS_FILE.name)
        except (OSError, ValueError, TypeError) as e:
            log.error("%s: %s; keeping the previous rules", HOSTS_FILE.name, e)
    return _hosts_cache["rules"]


def _host_known(host):
    # github.com is always reachable for git; GIT_FETCH/GIT_PUSH apply.
    return host == "github.com" or any(r.matches_host(host) for r in _rules())


def _host_allows(host, method, path):
    return any(
        r.matches_host(host)
        and (r.methods is None or method in r.methods)
        and path.startswith(r.path_prefix)
        for r in _rules()
    )


def _url(flow):
    req = flow.request
    if req.method == "CONNECT":
        return f"{req.host}:{req.port}"
    return req.pretty_url


def _allow(flow, note=""):
    log.info("ALLOW %s %s%s", flow.request.method, _url(flow), f" ({note})" if note else "")


def _deny(flow, reason):
    log.warning("DENY  %s %s: %s", flow.request.method, _url(flow), reason)
    flow.response = http.Response.make(
        403,
        f"Blocked by the dev container's egress proxy: {reason}\n"
        "Policy: .devcontainer/egress-proxy/policy.py\n",
        {"Content-Type": "text/plain"},
    )


def _github_token():
    try:
        return TOKEN_FILE.read_text().strip() or None
    except OSError:
        return None


def receive_pack_commands(body):
    """Ref updates at the start of a git-receive-pack request.

    The body starts with pkt-lines "<old-oid> <new-oid> <ref>", the first
    one followed by "\\0<capabilities>", terminated by a flush packet
    "0000". The packfile follows. Raises ValueError on anything unexpected.
    """
    commands = []
    i = 0
    while i + 4 <= len(body):
        size = int(body[i : i + 4], 16)
        if size == 0:
            return commands
        if size < 4 or i + size > len(body):
            raise ValueError("bad pkt-line length")
        line = body[i + 4 : i + size].split(b"\0", 1)[0].rstrip(b"\n").decode()
        i += size
        if line.startswith("shallow "):
            continue
        old, new, ref = line.split(" ", 2)
        commands.append((old, new, ref))
    raise ValueError("no flush packet")


def push_problems(body):
    try:
        commands = receive_pack_commands(body)
    except ValueError as e:
        return [f"unparseable push request ({e})"]
    problems = []
    for _old, new, ref in commands:
        if not GIT_PUSH_REFS.fullmatch(ref):
            problems.append(f"{ref} does not match GIT_PUSH_REFS")
        elif set(new) == {"0"} and not GIT_PUSH_ALLOW_DELETE:
            problems.append(f"deleting {ref} is not allowed")
    return problems


class EgressPolicy:
    def load(self, loader):
        _setup_file_log()

    def running(self):
        # Publish the CA certificate (not its key) for the dev container.
        src = Path(ctx.options.confdir).expanduser() / "mitmproxy-ca-cert.pem"
        tmp = STATE_DIR / "ca.crt.tmp"
        shutil.copyfile(src, tmp)
        tmp.replace(STATE_DIR / "ca.crt")
        log.info("egress proxy ready, GitHub token %s", "loaded" if _github_token() else "MISSING")

    def http_connect(self, flow: http.HTTPFlow):
        host = _normalize(flow.request.host)
        if flow.request.port != 443:
            _deny(flow, "only port 443 is allowed")
        elif not _host_known(host):
            _deny(flow, "host is not in the allowlist")

    def tcp_start(self, flow: tcp.TCPFlow):
        # Non-HTTP traffic inside an allowed CONNECT tunnel: never.
        log.warning("DENY  raw TCP to %s", flow.server_conn.address)
        flow.kill()

    def request(self, flow: http.HTTPFlow):
        req = flow.request
        host = _normalize(req.host)

        if req.scheme != "https" or req.port != 443:
            return _deny(flow, "only HTTPS on port 443 is allowed")
        # Domain fronting: the TLS SNI and the Host header must both name
        # the host we actually connect to.
        if _normalize(flow.client_conn.sni or "") != host:
            return _deny(flow, "TLS SNI does not match the target host")
        if _normalize(re.sub(r":\d+$", "", req.host_header or "")) != host:
            return _deny(flow, "Host header does not match the target host")

        if host == "github.com":
            # Only the proxy authenticates to GitHub.
            req.headers.pop("Authorization", None)
            match = GIT_PATH.match(req.path.split("?", 1)[0])
            if match:
                return self._git(flow, match["repo"].lower(), match["endpoint"])

        if _host_allows(host, req.method, req.path.split("?", 1)[0]):
            return _allow(flow)
        _deny(flow, f"{req.method} to {host} is not allowed (allowed-hosts.toml)")

    def _git(self, flow, repo, endpoint):
        req = flow.request
        if endpoint == "info/refs":
            service = req.query.get("service", "git-upload-pack")
            expected_method = "GET"
        else:
            service = endpoint
            expected_method = "POST"
        if req.method != expected_method:
            return _deny(flow, f"unexpected {req.method} for git {endpoint}")

        if service == "git-upload-pack":
            if repo not in GIT_FETCH | GIT_PUSH:
                return _deny(flow, f"git fetch from {repo} is not allowed (GIT_FETCH)")
        elif service == "git-receive-pack":
            if repo not in GIT_PUSH:
                return _deny(flow, f"git push to {repo} is not allowed (GIT_PUSH)")
        else:
            return _deny(flow, f"unknown git service {service!r}")

        note = service
        if endpoint == "git-receive-pack":
            try:
                body = req.content or b""
            except ValueError:
                return _deny(flow, "undecodable push request body")
            problems = push_problems(body)
            if problems:
                return _deny(flow, "; ".join(problems))
            refs = [ref for _, _, ref in receive_pack_commands(body)]
            note = f"push {', '.join(refs) or '(probe)'}"

        token = _github_token()
        if token:
            creds = base64.b64encode(f"x-access-token:{token}".encode()).decode()
            req.headers["Authorization"] = f"Basic {creds}"
        _allow(flow, note)


addons = [EgressPolicy()]
