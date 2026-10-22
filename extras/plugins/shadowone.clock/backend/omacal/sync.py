"""Fetch every account's ticked calendars and write one cache file per month.

months/YYYY-MM.json  {"kind": "month", "month", "syncedAt", "events": [...]}
status.json          accounts and their state, last sync, pending sign-in

An account that fails (offline, needs sign-in again) keeps its previously
cached events, so a flaky network never blanks the calendar.
"""

import concurrent.futures
import datetime as dt
import os
import time

from . import google, net, normalize, oauth, paths

KEEP_MONTHS = 12  # cache files further than this from today are deleted


def now_ms():
    return int(time.time() * 1000)


def _fresh(months, max_age_s, accounts, now):
    status = paths.read_status()
    known = sorted(a.get("email") for a in status.get("accounts") or [] if isinstance(a, dict))
    if known != sorted(a["email"] for a in accounts):
        return False
    for ym in months:
        data = paths.read_json(paths.month_path(ym), {}) or {}
        if now - int(data.get("syncedAt") or 0) > max_age_s * 1000:
            return False
    return True


def _fetch_account(client, email, months, hide_declined):
    """{"email", "state", "error", "calendars", "records"} for one account."""
    result = {"email": email, "state": "ok", "error": "", "calendars": 0, "records": []}
    try:
        refresh = oauth.lookup_token(email)
        if not refresh:
            raise oauth.ReauthNeeded("Not signed in on this computer.")
        access = oauth.refresh_access_token(client, refresh)
        cals = google.calendars(access)
        start, end = normalize.span_bounds(months)
        lo, hi = start.isoformat(), end.isoformat()

        def one(cal):
            try:
                return cal, google.events(access, cal["id"], lo, hi), None
            except net.HttpError as exc:
                if exc.status in (403, 404):  # shared calendar gone or no longer readable
                    return cal, [], None
                return cal, None, exc

        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            for cal, items, err in pool.map(one, cals):
                if err is not None:
                    raise err
                for ev in items:
                    rec = normalize.normalize(ev, cal, email, hide_declined)
                    if rec:
                        result["records"].append(rec)
        result["calendars"] = len(cals)
    except oauth.ReauthNeeded as exc:
        result.update(state="needsReauth", error=str(exc))
    except net.Offline:
        result.update(state="offline", error="Offline")
    except net.HttpError as exc:
        code = net.error_code(exc.body)
        if code in ("accessNotConfigured", "SERVICE_DISABLED"):
            msg = "Turn on Google Calendar API in your Cloud project."
        elif exc.status == 401:
            result.update(state="needsReauth", error="Google rejected the sign-in.")
            return result
        else:
            msg = net.describe(exc.body) or str(exc)
        result.update(state="error", error=msg)
    except (oauth.OAuthError, ValueError) as exc:
        result.update(state="error", error=str(exc))
    return result


def _write_months(months, results, now):
    failed = {r["email"] for r in results if r["state"] != "ok"}
    fresh = normalize.dedupe(sorted((rec for r in results for rec in r["records"]), key=normalize.sort_key))
    for ym in months:
        previous = paths.read_json(paths.month_path(ym), {}) or {}
        kept = [e for e in previous.get("events") or [] if isinstance(e, dict) and e.get("account") in failed]
        events = normalize.dedupe(normalize.for_month(fresh, ym) + kept)
        events.sort(key=normalize.sort_key)
        paths.atomic_write_json(paths.month_path(ym), {
            "kind": "month", "schema": 1, "month": ym, "syncedAt": now, "events": events,
        })


def _prune(today):
    this = normalize.month_key(today.year, today.month)
    keep = {normalize.shift_month(this, d) for d in range(-KEEP_MONTHS, KEEP_MONTHS + 1)}
    try:
        names = os.listdir(paths.months_dir())
    except OSError:
        return
    for name in names:
        if name.endswith(".json") and name[:-5] not in keep:
            try:
                os.unlink(os.path.join(paths.months_dir(), name))
            except OSError:
                pass


def run(months=None, max_age_s=0, hide_declined=True, today=None):
    today = today or dt.date.today()
    months = sorted(set(months or normalize.default_months(today)))
    try:
        client = oauth.load_client()
    except oauth.OAuthError as exc:
        paths.update_status(lambda s: s.update(configured=False, error=str(exc)))
        return {"kind": "sync", "ok": False, "configured": False, "error": str(exc)}

    accounts = paths.load_accounts()
    now = now_ms()
    try:
        with paths.lock("sync", blocking=False):
            if max_age_s > 0 and _fresh(months, max_age_s, accounts, now):
                return {"kind": "sync", "ok": True, "skipped": "fresh", "months": months}
            if accounts:
                with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                    results = list(pool.map(lambda a: _fetch_account(client, a["email"], months, hide_declined), accounts))
            else:
                results = []
            _write_months(months, results, now)
            _prune(today)
    except paths.Busy:
        return {"kind": "sync", "ok": True, "skipped": "busy", "months": months}

    any_ok = any(r["state"] == "ok" for r in results)
    offline = bool(results) and all(r["state"] == "offline" for r in results)

    def mutate(s):
        old = {a.get("email"): a for a in s.get("accounts") or [] if isinstance(a, dict)}
        s["configured"] = True
        s["error"] = ""
        s["lastAttempt"] = now
        s["online"] = not offline
        if any_ok or not results:
            s["lastSync"] = now
        s["accounts"] = []
        for r in results:
            prev = old.get(r["email"]) or {}
            s["accounts"].append({
                "email": r["email"],
                "state": r["state"],
                "error": r["error"],
                "calendars": r["calendars"] if r["state"] == "ok" else prev.get("calendars", 0),
                "syncedAt": now if r["state"] == "ok" else prev.get("syncedAt", 0),
            })

    paths.update_status(mutate)
    return {
        "kind": "sync",
        "ok": all(r["state"] == "ok" for r in results),
        "months": months,
        "accounts": [{k: r[k] for k in ("email", "state", "error", "calendars")} for r in results],
        "events": sum(len(r["records"]) for r in results),
    }
