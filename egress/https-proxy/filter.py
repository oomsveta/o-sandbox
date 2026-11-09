"""
The HTTPS proxy's filter: a mitmproxy addon, run by start.sh.

The dev container's network has no route out: this proxy and the git relay
are its only ways out. The dev container trusts this proxy's CA, so every
HTTPS request is decrypted and checked against policy.toml. Anything not
allowed gets a 403. Every decision is logged to /srv/egress/egress.log
(/etc/https-proxy/egress.log in the dev container).

Git over HTTPS is fetch-only and never authenticated: pushes, and fetches
from private repos, go over SSH through the git relay.
"""

import functools
import importlib
import logging.handlers
import re
import shutil
import sys
from pathlib import Path

from mitmproxy import ctx, http, tcp

sys.path.insert(0, "/policy")  # ../policy/
import egress_policy

# mitmdump reloads this file when it changes, but not the modules it
# imports: reload egress_policy along with it.
importlib.reload(egress_policy)

STATE_DIR = Path("/srv/egress")  # /etc/https-proxy in the dev container
# Git's smart HTTP endpoints, e.g. /odoo/odoo.git/info/refs
GIT_PATH = re.compile(
    r"/(?P<repo>[^/]+/[^/]+?)(?:\.git)?/(?P<endpoint>info/refs|git-upload-pack|git-receive-pack)"
)

log = logging.getLogger("egress")


def _normalize(host):
    return host.lower().rstrip(".")


def _deny(flow, reason):
    req = flow.request
    target = f"{req.host}:{req.port}" if req.method == "CONNECT" else req.pretty_url
    log.warning("DENY  %s %s: %s", req.method, target, reason)
    flow.response = http.Response.make(
        403,
        f"Blocked by the dev container's HTTPS proxy: {reason}\n"
        "Policy: .devcontainer/egress/policy/policy.toml\n",
        {"Content-Type": "text/plain"},
    )


def _fail_closed(hook):
    """mitmproxy lets a request through when a hook raises: deny it instead."""

    @functools.wraps(hook)
    def wrapper(self, flow):
        try:
            hook(self, flow)
        except Exception as e:
            log.exception("error in %s", hook.__name__)
            _deny(flow, f"internal error ({type(e).__name__})")

    return wrapper


def _denial(flow):
    """Why `flow`'s request may not go through, or None if it may."""
    req = flow.request
    host = _normalize(req.host)
    if req.scheme != "https" or req.port != 443:
        return "only HTTPS on port 443 is allowed"
    # Against domain fronting: the TLS SNI and the Host header must both name
    # the host we connect to.
    if _normalize(flow.client_conn.sni or "") != host:
        return "TLS SNI does not match the target host"
    if _normalize(re.sub(r":\d+$", "", req.host_header or "")) != host:
        return "Host header does not match the target host"

    policy = egress_policy.current()
    path = req.path.split("?", 1)[0]
    if host == "github.com" and (git := GIT_PATH.fullmatch(path)):
        return _git_denial(req, policy, git["repo"], git["endpoint"])
    if not policy.host_allows(host, req.method, path):
        return f"{req.method} to {host} is not allowed (policy.toml)"
    return None


def _git_denial(req, policy, repo_path, endpoint):
    # A fetch is GET info/refs?service=git-upload-pack, then POST git-upload-pack.
    if endpoint == "info/refs":
        service, method = req.query.get("service", "git-upload-pack"), "GET"
    else:
        service, method = endpoint, "POST"
    if req.method != method:
        return f"unexpected {req.method} for git {endpoint}"
    if service == "git-receive-pack":
        return "push over SSH (git@github.com:...), not HTTPS"
    repo = egress_policy.repo_name(repo_path)
    if repo is None:
        return f"{repo_path!r} is not a repo path"
    return policy.git_denial(service, repo)


class HttpsFilter:
    def load(self, loader):
        if not log.handlers:  # this file is re-run on reload, the logger isn't
            handler = logging.handlers.RotatingFileHandler(
                STATE_DIR / "egress.log", maxBytes=1_000_000, backupCount=2
            )
            handler.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
            log.addHandler(handler)
            log.setLevel(logging.INFO)
        egress_policy.current()  # logs the policy's errors right away, if any

    def running(self):
        # Publish the CA certificate (not its key) for the dev container,
        # atomically: it waits for it (healthcheck in docker-compose.yml).
        tmp = STATE_DIR / "ca.crt.tmp"
        shutil.copyfile(Path(ctx.options.confdir).expanduser() / "mitmproxy-ca-cert.pem", tmp)
        tmp.replace(STATE_DIR / "ca.crt")
        log.info("HTTPS proxy ready")

    @_fail_closed
    def http_connect(self, flow: http.HTTPFlow):
        # Refuse tunnels to hosts no rule is about, before any TLS.
        host = _normalize(flow.request.host)
        if flow.request.port != 443:
            _deny(flow, "only port 443 is allowed")
        # github.com stays reachable for git fetches even if it isn't listed.
        elif host != "github.com" and not egress_policy.current().host_known(host):
            _deny(flow, "host is not in the allowlist")

    def tcp_start(self, flow: tcp.TCPFlow):
        # Non-HTTP traffic inside an allowed tunnel: never.
        log.warning("DENY  raw TCP to %s", flow.server_conn.address)
        flow.kill()

    @_fail_closed
    def request(self, flow: http.HTTPFlow):
        # Nothing authenticates to GitHub over HTTPS: the dev container has no
        # credentials for it, and this keeps it that way.
        if _normalize(flow.request.host) == "github.com":
            flow.request.headers.pop("Authorization", None)
        if reason := _denial(flow):
            _deny(flow, reason)
        else:
            log.info("ALLOW %s %s", flow.request.method, flow.request.pretty_url)


addons = [HttpsFilter()]
