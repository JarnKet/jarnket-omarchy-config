"""Turn Calendar API events into the flat records the clock panel reads.

Pure functions: no I/O, and no clock reads (callers pass dates in).
Times are converted to the machine's local zone, and every event lists
the local days it touches ("YYYY-MM-DD", the clock's own day keys), so
the QML side only has to bucket.
"""

import datetime as dt
import hashlib

SKIPPED_TYPES = ("workingLocation",)


# ------------------------------------------------------------------ months

def parse_month(ym):
    """'2026-10' -> (2026, 10); ValueError otherwise."""
    year, month = ym.split("-")
    y, m = int(year), int(month)
    if len(year) != 4 or not 1 <= m <= 12:
        raise ValueError("month must look like 2026-10")
    return y, m


def month_key(year, month):
    return "%04d-%02d" % (year, month)


def shift_month(ym, delta):
    y, m = parse_month(ym)
    index = y * 12 + (m - 1) + delta
    return month_key(index // 12, index % 12 + 1)


def default_months(today):
    """The window a plain sync keeps fresh: last month, this month, the next two."""
    this = month_key(today.year, today.month)
    return [shift_month(this, d) for d in (-1, 0, 1, 2)]


def local_midnight(day):
    """Aware local datetime at the start of `day` (naive datetimes are local to astimezone)."""
    return dt.datetime.combine(day, dt.time()).astimezone()


def month_bounds(ym):
    y, m = parse_month(ym)
    first = dt.date(y, m, 1)
    ny, nm = parse_month(shift_month(ym, 1))
    return local_midnight(first), local_midnight(dt.date(ny, nm, 1))


def span_bounds(months):
    """[start of the earliest month, start of the month after the latest)."""
    months = sorted(months)
    return month_bounds(months[0])[0], month_bounds(months[-1])[1]


# ------------------------------------------------------------------ events

def parse_when(when):
    """(aware local datetime, is_all_day) from an event's start/end object."""
    if not isinstance(when, dict):
        raise ValueError("missing start/end")
    if when.get("dateTime"):
        moment = dt.datetime.fromisoformat(when["dateTime"])
        if moment.tzinfo is None and when.get("timeZone"):
            from zoneinfo import ZoneInfo
            moment = moment.replace(tzinfo=ZoneInfo(when["timeZone"]))
        return moment.astimezone(), False
    if when.get("date"):
        return local_midnight(dt.date.fromisoformat(when["date"])), True
    raise ValueError("start/end has neither date nor dateTime")


def touched_days(start, end, all_day):
    """Local dates an event covers. An all-day end is exclusive; so is a timed
    end at midnight (a 22:00-00:00 event does not touch the next day)."""
    first = start.date()
    if end <= start:
        return [first]
    last = (end - dt.timedelta(days=1)).date() if all_day else (end - dt.timedelta(microseconds=1)).date()
    if last < first:
        last = first
    out, day = [], first
    while day <= last:
        out.append(day.isoformat())
        day += dt.timedelta(days=1)
    return out


def event_key(account, calendar_id, event_id, start_ms):
    """Stable per occurrence; includes the start so a moved event earns a new reminder."""
    raw = "\x1f".join((account, calendar_id, event_id, str(start_ms)))
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:16]


def meet_url(ev):
    if isinstance(ev.get("hangoutLink"), str) and ev["hangoutLink"].startswith("https://"):
        return ev["hangoutLink"]
    conf = ev.get("conferenceData")
    points = conf.get("entryPoints") if isinstance(conf, dict) else None
    for p in points if isinstance(points, list) else []:
        if isinstance(p, dict) and p.get("entryPointType") == "video" and str(p.get("uri", "")).startswith("https://"):
            return p["uri"]
    return ""


def declined(ev):
    for a in ev.get("attendees") or []:
        if isinstance(a, dict) and a.get("self") and a.get("responseStatus") == "declined":
            return True
    return False


def to_ms(moment):
    return int(moment.timestamp() * 1000)


def normalize(ev, calendar, account, hide_declined=True):
    """One API event -> record, or None when the clock should not show it."""
    if not isinstance(ev, dict) or ev.get("status") == "cancelled" or not ev.get("id"):
        return None
    if ev.get("eventType") in SKIPPED_TYPES:
        return None
    if hide_declined and declined(ev):
        return None
    try:
        start, all_day = parse_when(ev.get("start"))
        end, _ = parse_when(ev.get("end") or ev.get("start"))
    except (ValueError, KeyError):
        return None
    start_ms = to_ms(start)
    title = str(ev.get("summary") or "").strip() or "(No title)"
    link = ev.get("htmlLink") if str(ev.get("htmlLink", "")).startswith("https://") else ""
    return {
        "key": event_key(account, calendar["id"], ev["id"], start_ms),
        "uid": str(ev.get("iCalUID") or ev["id"]),
        "account": account,
        "calendarId": calendar["id"],
        "calendar": calendar.get("name", ""),
        "color": calendar.get("color", ""),
        "title": title,
        "location": str(ev.get("location") or "").strip(),
        "allDay": all_day,
        "start": start_ms,
        "end": to_ms(end),
        "days": touched_days(start, end, all_day),
        "link": link,
        "meet": meet_url(ev),
    }


def sort_key(r):
    return (0 if r["allDay"] else 1, r["start"], r["title"].lower())


def dedupe(records):
    """One invite seen through two accounts (or two calendars) shows once; the
    first copy wins and remembers where else it appeared."""
    seen, out = {}, []
    for r in records:
        ident = (r["uid"], r["start"])
        first = seen.get(ident)
        if first is None:
            seen[ident] = r
            out.append(r)
        elif r["account"] != first["account"]:
            also = first.setdefault("alsoIn", [])
            if r["account"] not in also:
                also.append(r["account"])
    return out


def for_month(records, ym):
    """Records touching `ym`, with `days` trimmed to that month (a year-long
    all-day event must not put 365 keys into every month file)."""
    prefix = ym + "-"
    out = []
    for r in records:
        days = [d for d in r["days"] if d.startswith(prefix)]
        if days:
            out.append(dict(r, days=days))
    out.sort(key=sort_key)
    return out
