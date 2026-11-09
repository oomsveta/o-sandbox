"""
HTTPS egress proxy for the Odoo dev container: a mitmproxy addon, loaded by
mitmdump (see start.sh).

The dev container sits on an `internal` Docker network with no route to the
internet; this proxy and the git relay are its only ways out. The container
trusts our CA, so every HTTPS request is decrypted and checked against
policy.toml (via egress_policy.py). Anything not allowed gets a 403.

Git over HTTPS is fetch-only and never authenticated: pushes, and fetches
from private repos, go over SSH through the git relay.

Every decision is logged to /srv/egress/egress.log, which the dev container
can read at /etc/egress-proxy/egress.log.
"""

import functools
import importlib
import logging
import logging.handlers
import os
import re
import shutil
import sys
from pathlib import Path

# Shared with the git relay (egress/policy/, mounted at /policy).
sys.path.insert(0, "/policy")
import egress_policy
from mitmproxy import ctx, http, tcp

# mitmdump reloads this file when it changes, but not the modules it
# imports: pick up changes to egress_policy.py too.
importlib.reload(egress_policy)

STATE_DIR = Path(os.environ.get("EGRESS_STATE_DIR", "/srv/egress"))

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
        "Policy: .devcontainer/egress/policy/policy.toml\n",
        {"Content-Type": "text/plain"},
    )


def _fail_closed(hook):
    """mitmproxy lets a request through when a hook raises: deny it instead."""

    @functools.wraps(hook)
    def wrapper(self, flow):
        try:
            return hook(self, flow)
        except Exception as e:
            log.exception("error in %s", hook.__name__)
            _deny(flow, f"internal error ({type(e).__name__})")
            return None

    return wrapper


class EgressPolicy:
    def load(self, loader):
        _setup_file_log()
        egress_policy.current()  # log the policy (or its errors) right away

    def running(self):
        # Publish the CA certificate (not its key) for the dev container.
        src = Path(ctx.options.confdir).expanduser() / "mitmproxy-ca-cert.pem"
        tmp = STATE_DIR / "ca.crt.tmp"
        shutil.copyfile(src, tmp)
        tmp.replace(STATE_DIR / "ca.crt")
        log.info("egress proxy ready")

    @_fail_closed
    def http_connect(self, flow: http.HTTPFlow):
        host = _normalize(flow.request.host)
        if flow.request.port != 443:
            _deny(flow, "only port 443 is allowed")
        # github.com stays reachable for git fetches even if it isn't listed.
        elif host != "github.com" and not egress_policy.host_known(egress_policy.current(), host):
            _deny(flow, "host is not in the allowlist")

    def tcp_start(self, flow: tcp.TCPFlow):
        # Non-HTTP traffic inside an allowed CONNECT tunnel: never.
        log.warning("DENY  raw TCP to %s", flow.server_conn.address)
        flow.kill()

    @_fail_closed
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

        policy = egress_policy.current()
        path = req.path.split("?", 1)[0]
        if host == "github.com":
            # Nothing authenticates to GitHub over HTTPS: the dev container
            # has no credentials, and this keeps it that way.
            req.headers.pop("Authorization", None)
            if match := GIT_PATH.match(path):
                return self._git(flow, policy, match["repo"], match["endpoint"])

        if egress_policy.host_allows(policy, host, req.method, path):
            return _allow(flow)
        _deny(flow, f"{req.method} to {host} is not allowed (policy.toml)")

    def _git(self, flow, policy, repo_path, endpoint):
        req = flow.request
        if endpoint == "info/refs":
            service = req.query.get("service", "git-upload-pack")
            expected_method = "GET"
        else:
            service = endpoint
            expected_method = "POST"
        if req.method != expected_method:
            return _deny(flow, f"unexpected {req.method} for git {endpoint}")
        if service == "git-receive-pack":
            return _deny(flow, "push over SSH (git@github.com:...), not HTTPS")

        repo = egress_policy.normalize_repo(repo_path)
        if repo is None:
            return _deny(flow, f"{repo_path!r} is not a repo path")
        if reason := egress_policy.git_denial(policy, service, repo):
            return _deny(flow, reason)
        _allow(flow, service)


addons = [EgressPolicy()]
