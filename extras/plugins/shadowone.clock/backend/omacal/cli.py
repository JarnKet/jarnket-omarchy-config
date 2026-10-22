"""omacal command line. Every command prints JSON with --json, text otherwise.

Exit codes: 0 ok, 2 usage, 3 busy, 4 partial failure, 5 sign-in failed, 6 not configured, 7 offline.
"""

import argparse
import datetime as dt
import json
import os
import shutil
import sys
import time

from . import SCHEMA, VERSION, normalize, notify, oauth, paths, sync

EXIT_OK, EXIT_USAGE, EXIT_BUSY, EXIT_PARTIAL, EXIT_AUTH, EXIT_SETUP, EXIT_OFFLINE = 0, 2, 3, 4, 5, 6, 7

SETUP_STEPS = """\
Omarchy Calendar signs in with a Google OAuth client from your own Google Cloud
project (free, one time, about 5 minutes). In the browser, signed in with any of
your Google accounts:

 1. Create a project named "Omarchy Calendar":
    https://console.cloud.google.com/projectcreate
 2. Enable the Google Calendar API in it:
    https://console.cloud.google.com/apis/library/calendar-json.googleapis.com
 3. Branding: app name "Omarchy Calendar", your email as support and developer contact.
    Audience: External.
    https://console.cloud.google.com/auth/branding
 4. Data access: Add or remove scopes, then tick .../auth/calendar.readonly.
    https://console.cloud.google.com/auth/scopes
 5. Clients: Create client, type "Desktop app", then Download JSON.
    https://console.cloud.google.com/auth/clients
 6. Audience: Publish app, so the status is "In production". While it is in
    "Testing", Google signs every account out after 7 days.
    https://console.cloud.google.com/auth/audience
 7. omacal setup ~/Downloads/client_secret_XXXX.json

When you sign in, Google says "Google hasn't verified this app". That is expected:
the app is yours. Click Advanced, then "Go to Omarchy Calendar (unsafe)".
"""


def emit(args, data, text=None):
    data = dict(data)
    data.setdefault("schema", SCHEMA)
    if args.json or text is None:
        sys.stdout.write(json.dumps(data, ensure_ascii=False) + "\n")
    else:
        sys.stdout.write(text.rstrip("\n") + "\n")
    sys.stdout.flush()


def now_ms():
    return int(time.time() * 1000)


# ------------------------------------------------------------------ setup

def cmd_setup(args):
    if not args.client_json:
        configured = os.path.exists(paths.client_path())
        emit(args, {"kind": "setup", "configured": configured, "steps": SETUP_STEPS},
             SETUP_STEPS + ("\nAlready set up: " + paths.client_path() if configured else ""))
        return EXIT_OK
    src = os.path.expanduser(args.client_json)
    data = paths.read_json(src)
    try:
        client = oauth.validate_client(data)
    except oauth.OAuthError as exc:
        emit(args, {"kind": "setup", "ok": False, "error": str(exc)}, "Not saved: %s" % exc)
        return EXIT_USAGE
    paths.atomic_write_json(paths.client_path(), data)
    os.chmod(paths.client_path(), 0o600)
    paths.update_status(lambda s: s.update(configured=True, error=""))
    emit(args, {"kind": "setup", "ok": True, "project": client["project_id"]},
         "Saved %s (project %s). Next: omacal add" % (paths.client_path(), client["project_id"] or "?"))
    return EXIT_OK


# ------------------------------------------------------------------ accounts

def _set_result(ok, message):
    def mutate(s):
        s["pending"] = None
        s["lastResult"] = {"ok": ok, "message": message, "at": now_ms()}
    paths.update_status(mutate)


def cmd_add(args):
    try:
        client = oauth.load_client()
    except oauth.OAuthError as exc:
        emit(args, {"kind": "add", "ok": False, "error": str(exc)}, str(exc))
        return EXIT_SETUP
    paths.update_status(lambda s: s.update(pending={"since": now_ms(), "hint": args.login_hint or ""}))
    try:
        email, refresh = oauth.authorize(client, login_hint=args.login_hint)
        oauth.store_token(email, refresh)
    except oauth.OAuthError as exc:
        _set_result(False, str(exc))
        emit(args, {"kind": "add", "ok": False, "error": str(exc)}, "Not added: %s" % exc)
        return EXIT_AUTH
    except KeyboardInterrupt:
        _set_result(False, "Sign-in cancelled.")
        return 130
    accounts = paths.load_accounts()
    if not any(a["email"] == email for a in accounts):
        accounts.append({"email": email, "addedAt": now_ms()})
        paths.save_accounts(accounts)
    _set_result(True, "Connected " + email)
    result = sync.run(hide_declined=not args.show_declined)
    emit(args, {"kind": "add", "ok": True, "email": email, "sync": result},
         "Connected %s. %s" % (email, _sync_text(result)))
    return EXIT_OK


def _purge_account(email):
    try:
        names = os.listdir(paths.months_dir())
    except OSError:
        return
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(paths.months_dir(), name)
        data = paths.read_json(path, {}) or {}
        events = data.get("events") or []
        kept = [e for e in events if isinstance(e, dict) and e.get("account") != email]
        if len(kept) != len(events):
            data["events"] = kept
            paths.atomic_write_json(path, data)


def cmd_remove(args):
    email = args.email.lower()
    accounts = paths.load_accounts()
    if not any(a["email"] == email for a in accounts):
        emit(args, {"kind": "remove", "ok": False, "error": "unknown account"}, "No such account: " + email)
        return EXIT_USAGE
    revoked = False
    try:
        token = oauth.lookup_token(email)
        if token:
            revoked = oauth.revoke(token)
        oauth.clear_token(email)
    except oauth.KeyringError:
        pass
    paths.save_accounts([a for a in accounts if a["email"] != email])
    _purge_account(email)

    def mutate(s):
        s["accounts"] = [a for a in s.get("accounts") or [] if isinstance(a, dict) and a.get("email") != email]
        s["lastResult"] = {"ok": True, "message": "Removed " + email, "at": now_ms()}
    paths.update_status(mutate)
    # Events this account shared with another one were stored once, under the
    # removed account; a sync brings the other account's copy back.
    if paths.load_accounts():
        sync.run(hide_declined=not args.show_declined)
    emit(args, {"kind": "remove", "ok": True, "email": email, "revoked": revoked},
         "Removed %s%s" % (email, "" if revoked else " (Google did not confirm the revoke; "
                           "check myaccount.google.com/permissions)"))
    return EXIT_OK


def cmd_accounts(args):
    status = paths.read_status()
    states = {a.get("email"): a for a in status.get("accounts") or [] if isinstance(a, dict)}
    rows = []
    for a in paths.load_accounts():
        st = states.get(a["email"]) or {}
        rows.append({"email": a["email"], "state": st.get("state", "new"), "error": st.get("error", ""),
                     "calendars": st.get("calendars", 0), "syncedAt": st.get("syncedAt", 0)})
    text = "\n".join("%-40s %-12s %s" % (r["email"], r["state"], r["error"]) for r in rows) or "No accounts. Run: omacal add"
    emit(args, {"kind": "accounts", "configured": os.path.exists(paths.client_path()), "accounts": rows}, text)
    return EXIT_OK


# ------------------------------------------------------------------ sync / list / notify

def _sync_text(r):
    if r.get("skipped"):
        return "Up to date (%s)." % r["skipped"]
    if not r.get("configured", True):
        return r.get("error", "")
    parts = ["%s: %s" % (a["email"], a["state"] if a["state"] != "ok" else "%d calendars" % a["calendars"])
             for a in r.get("accounts", [])]
    return "Synced %s (%d events). %s" % (", ".join(r.get("months", [])), r.get("events", 0), "; ".join(parts))


def cmd_sync(args):
    months = None
    if args.month:
        try:
            months = [normalize.month_key(*normalize.parse_month(m)) for m in args.month]
        except ValueError as exc:
            emit(args, {"kind": "sync", "ok": False, "error": str(exc)}, str(exc))
            return EXIT_USAGE
    result = sync.run(months=months, max_age_s=args.max_age * 60, hide_declined=not args.show_declined)
    emit(args, result, _sync_text(result))
    if not result.get("configured", True):
        return EXIT_SETUP
    if result.get("skipped") == "busy":
        return EXIT_BUSY
    states = [a["state"] for a in result.get("accounts", [])]
    if states and all(s == "offline" for s in states):
        return EXIT_OFFLINE
    return EXIT_OK if result.get("ok") else EXIT_PARTIAL


def cmd_list(args):
    today = dt.date.today()
    days = [(today + dt.timedelta(days=i)).isoformat() for i in range(max(1, args.days))]
    months = sorted({d[:7] for d in days})
    by_day = {d: [] for d in days}
    seen = set()
    for ym in months:
        for ev in (paths.read_json(paths.month_path(ym), {}) or {}).get("events") or []:
            for d in ev.get("days") or []:
                if d in by_day and (d, ev.get("key")) not in seen:
                    seen.add((d, ev.get("key")))
                    by_day[d].append(ev)
    lines = []
    for d in days:
        evs = sorted(by_day[d], key=normalize.sort_key)
        lines.append(dt.date.fromisoformat(d).strftime("%a %d %b"))
        if not evs:
            lines.append("  -")
        for ev in evs:
            when = "all day    " if ev["allDay"] else "%s-%s" % (notify.hhmm(ev["start"]), notify.hhmm(ev["end"]))
            lines.append("  %s  %s  (%s)" % (when, ev["title"], ev["account"]))
    emit(args, {"kind": "list", "days": {d: by_day[d] for d in days}}, "\n".join(lines))
    return EXIT_OK


def cmd_notify(args):
    result = notify.notify(args.key)
    emit(args, result, "sent" if result["sent"] else "not sent: " + result["reason"])
    return EXIT_OK


def cmd_status(args):
    status = paths.read_status()
    status["configured"] = os.path.exists(paths.client_path())
    status["keyring"] = bool(shutil.which("secret-tool"))
    last = status.get("lastSync")
    text = "configured: %s, accounts: %d, last sync: %s" % (
        "yes" if status["configured"] else "no (omacal setup)", len(paths.load_accounts()),
        time.strftime("%Y-%m-%d %H:%M", time.localtime(last / 1000)) if last else "never")
    emit(args, dict(status, kind="status"), text)
    return EXIT_OK


def build_parser():
    p = argparse.ArgumentParser(prog="omacal", description="Google Calendar for the Omarchy clock (read-only).")
    p.add_argument("--version", action="version", version="omacal " + VERSION)
    sub = p.add_subparsers(dest="cmd", required=True)

    def add(name, func, help_):
        sp = sub.add_parser(name, help=help_)
        sp.add_argument("--json", action="store_true", help="machine-readable output")
        sp.set_defaults(func=func)
        return sp

    sp = add("setup", cmd_setup, "show the one-time Google setup, or save the downloaded client JSON")
    sp.add_argument("client_json", nargs="?", help="client_secret_*.json of a Desktop app OAuth client")
    sp = add("add", cmd_add, "sign in to one more Google account in the browser")
    sp.add_argument("--login-hint", help="pre-select this account (used by 'Sign in again')")
    sp.add_argument("--show-declined", action="store_true", help="keep events you declined")
    sp = add("remove", cmd_remove, "sign an account out: revoke at Google, forget its token and events")
    sp.add_argument("email")
    sp.add_argument("--show-declined", action="store_true", help="keep events you declined")
    add("accounts", cmd_accounts, "connected accounts and their state")
    sp = add("sync", cmd_sync, "fetch events (last month to two months ahead by default)")
    sp.add_argument("--month", action="append", help="YYYY-MM instead of the default window (repeatable)")
    sp.add_argument("--max-age", type=int, default=0, help="do nothing if the cache is younger than this many minutes")
    sp.add_argument("--show-declined", action="store_true", help="keep events you declined")
    sp = add("list", cmd_list, "agenda from the cache")
    sp.add_argument("--days", type=int, default=7)
    sp = add("notify", cmd_notify, "send the reminder for one event, once")
    sp.add_argument("key")
    add("status", cmd_status, "setup and sync state")
    return p


def main(argv):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        return 130
