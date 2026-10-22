"""Google Calendar API v3, the two read calls the clock needs."""

import urllib.parse

from . import net

API = "https://www.googleapis.com/calendar/v3"

CALENDAR_FIELDS = "items(id,summary,summaryOverride,backgroundColor,selected,hidden,deleted,primary),nextPageToken"
EVENT_FIELDS = ("items(id,iCalUID,status,summary,location,start,end,htmlLink,hangoutLink,"
                "conferenceData(entryPoints(entryPointType,uri)),attendees(self,responseStatus),eventType),"
                "nextPageToken")
MAX_PAGES = 20


def _get(access_token, path, params):
    url = API + path + "?" + urllib.parse.urlencode(params)
    return net.request_json(url, headers={"Authorization": "Bearer " + access_token})


def _paged(access_token, path, params):
    items, page = [], None
    for _ in range(MAX_PAGES):
        query = dict(params)
        if page:
            query["pageToken"] = page
        data = _get(access_token, path, query)
        items.extend(i for i in data.get("items") or [] if isinstance(i, dict))
        page = data.get("nextPageToken")
        if not page:
            break
    return items


def calendars(access_token):
    """The calendars ticked in Google Calendar's own sidebar: [{"id", "name", "color", "primary"}]."""
    out = []
    for c in _paged(access_token, "/users/me/calendarList", {"fields": CALENDAR_FIELDS, "maxResults": 250}):
        if not c.get("selected") or c.get("hidden") or c.get("deleted") or not c.get("id"):
            continue
        out.append({
            "id": c["id"],
            "name": c.get("summaryOverride") or c.get("summary") or c["id"],
            "color": c.get("backgroundColor") or "",
            "primary": bool(c.get("primary")),
        })
    return out


def events(access_token, calendar_id, time_min, time_max):
    """Every instance (recurrences expanded) overlapping [time_min, time_max)."""
    path = "/calendars/" + urllib.parse.quote(calendar_id, safe="") + "/events"
    return _paged(access_token, path, {
        "singleEvents": "true",
        "orderBy": "startTime",
        "timeMin": time_min,
        "timeMax": time_max,
        "maxResults": 2500,
        "fields": EVENT_FIELDS,
    })
