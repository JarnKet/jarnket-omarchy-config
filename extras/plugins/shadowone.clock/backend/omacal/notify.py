"""Event reminders. The clock decides *when* (on its minute tick); this decides
*whether*: one notification per event occurrence, however many monitors (and
so clock widgets) ask, and across shell restarts."""

import datetime as dt
import subprocess
import time

from . import normalize, paths

GLYPH = "\U000f00f0"  # nf-md-calendar_clock
FORGET_AFTER_MS = 3 * 86400 * 1000


def find_event(key, today):
    this = normalize.month_key(today.year, today.month)
    for ym in (this, normalize.shift_month(this, 1)):
        for ev in (paths.read_json(paths.month_path(ym), {}) or {}).get("events") or []:
            if isinstance(ev, dict) and ev.get("key") == key:
                return ev
    return None


def hhmm(ms):
    return time.strftime("%H:%M", time.localtime(ms / 1000))


def message(ev, now):
    minutes = max(0, round((ev["start"] - now) / 60000))
    when = "now" if minutes == 0 else "in %d min" % minutes
    lines = ["%s – %s · %s" % (hhmm(ev["start"]), hhmm(ev["end"]), when)]
    if ev.get("location"):
        lines.append(ev["location"])
    if ev.get("meet"):
        lines.append(ev["meet"])
    return ev.get("title") or "(No title)", "\n".join(lines)


def send(headline, body):
    argv = ["omarchy-notification-send", "--app-name", "Calendar", "-g", GLYPH, headline, body]
    try:
        r = subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0


def notify(key, now=None, today=None):
    now = now if now is not None else int(time.time() * 1000)
    today = today or dt.date.today()
    with paths.lock("notify"):
        state = paths.read_json(paths.notified_path(), {}) or {}
        sent = {k: v for k, v in (state.get("sent") or {}).items()
                if isinstance(v, int) and now - v < FORGET_AFTER_MS}
        if key in sent:
            return {"kind": "notify", "sent": False, "reason": "already"}
        ev = find_event(key, today)
        if ev is None:
            return {"kind": "notify", "sent": False, "reason": "unknown"}
        if ev.get("allDay") or int(ev.get("start") or 0) <= now:
            return {"kind": "notify", "sent": False, "reason": "started"}
        headline, body = message(ev, now)
        ok = send(headline, body)
        if ok:
            sent[key] = now
        paths.atomic_write_json(paths.notified_path(), {"sent": sent})
        return {"kind": "notify", "sent": ok, "reason": "" if ok else "notification failed"}
