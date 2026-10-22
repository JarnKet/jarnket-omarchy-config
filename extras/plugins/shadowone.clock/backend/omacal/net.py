"""The one HTTP helper: JSON in, JSON out, errors sorted into offline vs. HTTP."""

import json
import socket
import urllib.error
import urllib.parse
import urllib.request

from . import VERSION

USER_AGENT = "omacal/" + VERSION


class Offline(Exception):
    """No route to Google (DNS, connect, TLS or timeout)."""


class HttpError(Exception):
    def __init__(self, status, body):
        self.status = status
        self.body = body if isinstance(body, dict) else {}
        super().__init__("HTTP %d: %s" % (status, describe(self.body) or body))


def describe(body):
    """Pull a human message out of either Google error shape."""
    if not isinstance(body, dict):
        return ""
    err = body.get("error")
    if isinstance(err, dict):  # Calendar API: {"error": {"code", "message", "errors": [...]}}
        return str(err.get("message") or "")
    if isinstance(err, str):  # OAuth endpoints: {"error": "invalid_grant", "error_description": ...}
        return (err + ": " + str(body.get("error_description") or "")).rstrip(": ")
    return ""


def error_code(body):
    """'invalid_grant', 'accessNotConfigured', ... or ''."""
    if not isinstance(body, dict):
        return ""
    err = body.get("error")
    if isinstance(err, str):
        return err
    if isinstance(err, dict):
        details = err.get("errors")
        if isinstance(details, list) and details and isinstance(details[0], dict):
            return str(details[0].get("reason") or "")
        return str(err.get("status") or "")
    return ""


def request_json(url, form=None, headers=None, timeout=20):
    """GET (or POST a urlencoded `form`) and return the parsed JSON body."""
    data = urllib.parse.urlencode(form).encode() if form is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET")
    req.add_header("User-Agent", USER_AGENT)
    req.add_header("Accept", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        with exc:
            raw = exc.read()
        try:
            body = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            body = raw.decode("utf-8", "replace")[:300]
        raise HttpError(exc.code, body) from None
    except (urllib.error.URLError, socket.timeout, TimeoutError, ConnectionError) as exc:
        raise Offline(str(getattr(exc, "reason", exc))) from None
    if not raw:
        return {}
    try:
        return json.loads(raw.decode("utf-8"))
    except ValueError:
        raise HttpError(200, "response was not JSON") from None
