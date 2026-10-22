"""Google sign-in for a desktop app: loopback redirect + PKCE, tokens in the keyring.

Flow (RFC 8252): listen on 127.0.0.1 on a random port, open the consent
page in the browser, take exactly one redirect back, check `state`,
exchange the code (with the PKCE verifier) for tokens. Google's Desktop
clients still want client_secret on the token call even though it is not
secret in an installed app.

Only the refresh token is kept, in the Secret Service keyring via
secret-tool. Access tokens live for one process.
"""

import base64
import hashlib
import http.server
import json
import secrets
import subprocess
import sys
import time
import urllib.parse

from . import net, paths

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
REVOKE_URL = "https://oauth2.googleapis.com/revoke"
CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar.readonly"
SCOPES = ("openid", "email", CALENDAR_SCOPE)

KEYRING_APP = "omacal"
KEYRING_TIMEOUT_S = 30
SIGNIN_TIMEOUT_S = 300


class OAuthError(Exception):
    """Sign-in failed; the message is meant for the user."""


class NotConfigured(OAuthError):
    pass


class ReauthNeeded(OAuthError):
    """The refresh token is gone, revoked or expired: sign in again."""


class KeyringError(OAuthError):
    pass


# ------------------------------------------------------------------ client

def validate_client(data):
    """The `installed` block of a Desktop-app client JSON, or OAuthError saying what is wrong."""
    if not isinstance(data, dict):
        raise OAuthError("That file is not a Google OAuth client JSON.")
    if "web" in data and "installed" not in data:
        raise OAuthError("This is a Web application client. Create a client of type "
                         "\"Desktop app\" instead; only that type allows the 127.0.0.1 redirect.")
    block = data.get("installed")
    if not isinstance(block, dict):
        raise OAuthError("No \"installed\" section: download the JSON of a \"Desktop app\" client.")
    cid, secret = block.get("client_id"), block.get("client_secret")
    if not isinstance(cid, str) or not cid.endswith(".apps.googleusercontent.com"):
        raise OAuthError("client_id is missing or does not look like a Google client id.")
    if not isinstance(secret, str) or not secret:
        raise OAuthError("client_secret is missing from the JSON.")
    return {"client_id": cid, "client_secret": secret, "project_id": str(block.get("project_id") or "")}


def load_client():
    data = paths.read_json(paths.client_path())
    if data is None:
        raise NotConfigured("No Google client yet: run `omacal setup` for the steps.")
    return validate_client(data)


# ------------------------------------------------------------------ PKCE + URL

def _b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def challenge_for(verifier):
    return _b64url(hashlib.sha256(verifier.encode("ascii")).digest())


def pkce_pair():
    verifier = _b64url(secrets.token_bytes(48))  # 64 chars, inside RFC 7636's 43..128
    return verifier, challenge_for(verifier)


def build_auth_url(client_id, redirect_uri, challenge, state, login_hint=None):
    params = {
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": " ".join(SCOPES),
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
        "access_type": "offline",
        # consent: always hand out a refresh token; select_account: the whole
        # point is adding a *different* account than the browser's current one.
        "prompt": "consent select_account",
    }
    if login_hint:
        params["login_hint"] = login_hint
    return AUTH_URL + "?" + urllib.parse.urlencode(params)


# ------------------------------------------------------------------ loopback

PAGE = """<!doctype html><meta charset="utf-8"><title>Omarchy Calendar</title>
<style>body{background:#000;color:#fff;font:16px/1.5 monospace;display:grid;place-items:center;height:100vh;margin:0}
main{max-width:34em;padding:2em;border:1px solid #333}h1{font-size:18px;margin:0 0 .5em}p{color:#aaa;margin:0}</style>
<main><h1>%s</h1><p>%s</p></main>"""


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 (http.server's name)
        parts = urllib.parse.urlsplit(self.path)
        if parts.path != "/":
            self.send_error(404)
            return
        params = dict(urllib.parse.parse_qsl(parts.query))
        if "code" not in params and "error" not in params:
            self.send_error(400)
            return
        srv = self.server
        if srv.result is None:
            srv.result = params
        ok = "code" in params and params.get("state") == srv.expected_state
        title = "Signed in" if ok else "Sign-in did not finish"
        text = ("You can close this tab. The account shows up in the clock's calendar in a moment."
                if ok else "Close this tab and try Add Google account again.")
        body = (PAGE % (title, text)).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class CallbackServer:
    """Listens on 127.0.0.1:<random> for the single redirect back from Google."""

    def __init__(self, expected_state):
        self.httpd = http.server.HTTPServer(("127.0.0.1", 0), _Handler)
        self.httpd.expected_state = expected_state
        self.httpd.result = None
        self.httpd.timeout = 0.5

    @property
    def redirect_uri(self):
        return "http://127.0.0.1:%d/" % self.httpd.server_address[1]

    def wait(self, timeout):
        deadline = time.monotonic() + timeout
        try:
            while self.httpd.result is None and time.monotonic() < deadline:
                self.httpd.handle_request()
        finally:
            self.httpd.server_close()
        if self.httpd.result is None:
            raise OAuthError("Timed out waiting for the browser sign-in.")
        return self.httpd.result


def parse_callback(params, expected_state):
    if params.get("state") != expected_state:
        raise OAuthError("The sign-in reply did not match this request (state mismatch). Try again.")
    if "error" in params:
        if params["error"] == "access_denied":
            raise OAuthError("Sign-in was cancelled in the browser.")
        raise OAuthError("Google refused the sign-in: %s" % params["error"])
    code = params.get("code")
    if not code:
        raise OAuthError("Google sent no authorization code.")
    return code


# ------------------------------------------------------------------ tokens

def _token_call(form):
    try:
        return net.request_json(TOKEN_URL, form=form)
    except net.HttpError as exc:
        code = net.error_code(exc.body)
        if code in ("invalid_grant", "unauthorized_client"):
            raise ReauthNeeded("Google no longer accepts this sign-in (%s)." % code) from None
        if code == "invalid_client":
            raise OAuthError("Google does not know this OAuth client. Check client.json (`omacal setup`).") from None
        raise OAuthError("Token request failed: %s" % (net.describe(exc.body) or exc)) from None


def exchange_code(client, code, verifier, redirect_uri):
    return _token_call({
        "client_id": client["client_id"],
        "client_secret": client["client_secret"],
        "code": code,
        "code_verifier": verifier,
        "grant_type": "authorization_code",
        "redirect_uri": redirect_uri,
    })


def refresh_access_token(client, refresh_token):
    data = _token_call({
        "client_id": client["client_id"],
        "client_secret": client["client_secret"],
        "refresh_token": refresh_token,
        "grant_type": "refresh_token",
    })
    token = data.get("access_token")
    if not token:
        raise OAuthError("Google returned no access token.")
    return token


def check_scopes(token):
    granted = str(token.get("scope") or "").split()
    if CALENDAR_SCOPE not in granted:
        raise OAuthError("Calendar access was not granted. On Google's consent page, leave "
                         "\"See your calendars\" ticked.")


def email_from_id_token(id_token):
    """The `email` claim. The token came straight from Google's token endpoint
    over TLS, so decoding without a signature check is the documented shortcut."""
    try:
        payload = id_token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError, AttributeError):
        raise OAuthError("Could not read the account email from Google's reply.") from None
    email = claims.get("email")
    if not isinstance(email, str) or "@" not in email:
        raise OAuthError("Google's reply carried no email address.")
    return email.lower()


def revoke(refresh_token):
    """Best effort: True when Google confirmed, False otherwise (offline, already revoked)."""
    try:
        net.request_json(REVOKE_URL, form={"token": refresh_token})
        return True
    except (net.HttpError, net.Offline):
        return False


def open_in_browser(url):
    sys.stderr.write("Opening Google sign-in in your browser. If nothing opens, visit:\n%s\n" % url)
    sys.stderr.flush()
    try:
        subprocess.Popen(["xdg-open", url], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def authorize(client, login_hint=None, opener=open_in_browser, timeout=SIGNIN_TIMEOUT_S):
    """Run the whole browser flow; returns (email, refresh_token)."""
    verifier, challenge = pkce_pair()
    state = secrets.token_urlsafe(24)
    server = CallbackServer(state)
    redirect_uri = server.redirect_uri
    opener(build_auth_url(client["client_id"], redirect_uri, challenge, state, login_hint))
    code = parse_callback(server.wait(timeout), state)
    try:
        token = exchange_code(client, code, verifier, redirect_uri)
    except ReauthNeeded as exc:  # a fresh code being refused is not a re-auth case
        raise OAuthError(str(exc)) from None
    check_scopes(token)
    email = email_from_id_token(token.get("id_token", ""))
    refresh = token.get("refresh_token")
    if not refresh:
        raise OAuthError("Google sent no refresh token. Remove the app at "
                         "myaccount.google.com/permissions and add the account again.")
    return email, refresh


# ------------------------------------------------------------------ keyring

def _secret_tool(args, stdin_text=None):
    try:
        return subprocess.run(["secret-tool"] + args, input=stdin_text if stdin_text is not None else "",
                              capture_output=True, text=True, timeout=KEYRING_TIMEOUT_S, check=False)
    except FileNotFoundError:
        raise KeyringError("secret-tool is missing (package libsecret).") from None
    except subprocess.TimeoutExpired:
        # A locked keyring waits on an unlock prompt that may never show.
        raise KeyringError("The keyring did not answer. Is it locked?") from None


def store_token(email, refresh_token):
    r = _secret_tool(["store", "--label", "Omarchy Calendar: " + email,
                      "app", KEYRING_APP, "account", email], refresh_token)
    if r.returncode != 0:
        raise KeyringError("Could not save to the keyring: " + (r.stderr.strip() or "secret-tool failed"))


def lookup_token(email):
    r = _secret_tool(["lookup", "app", KEYRING_APP, "account", email])
    value = r.stdout.strip()
    return value if r.returncode == 0 and value else None


def clear_token(email):
    _secret_tool(["clear", "app", KEYRING_APP, "account", email])
