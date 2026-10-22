# Clock & Google Calendar (`shadowone.clock`)

Omarchy's bar clock and calendar popup (cloned from `omarchy.clock` with
`omarchy plugin clone`), plus Google Calendar:

- dots under days with events, in each calendar's Google colour
- click a day to list its events (today's by default); click an event to open
  it in Google Calendar, or the camera button to join its Meet/Zoom call
- any number of Google accounts, every calendar ticked in Google's own sidebar
- reminders a set time before timed events (default 10 min), through the normal
  notification daemon, so Do Not Disturb still applies
- read-only: the only Google scope is `calendar.readonly`

Keys in the popup (besides the clock's own): `r` sync now, `a` show or hide accounts.

## One-time Google setup

Google only lets an app sign in with an OAuth client, and a personal desktop
tool has to bring its own. It is free and takes about 5 minutes; `omacal setup`
prints the same steps with links.

1. <https://console.cloud.google.com/projectcreate>: create a project, e.g. "Omarchy Calendar".
2. <https://console.cloud.google.com/apis/library/calendar-json.googleapis.com>: **Enable**.
3. <https://console.cloud.google.com/auth/branding>: app name and your email; Audience **External**.
4. <https://console.cloud.google.com/auth/scopes>: add `.../auth/calendar.readonly`.
5. <https://console.cloud.google.com/auth/clients>: **Create client**, type **Desktop app**, **Download JSON**.
6. <https://console.cloud.google.com/auth/audience>: **Publish app**, so the status is *In production*.
   In *Testing*, Google signs every account out after 7 days.
7. `omacal setup ~/Downloads/client_secret_XXXX.json`

Then press **Add Google account** in the popup (or run `omacal add`) once for
each account. Sign-in shows "Google hasn't verified this app". That is
expected for your own app: click **Advanced**, then **Go to Omarchy Calendar (unsafe)**.

## Where things live

| What | Where |
| --- | --- |
| OAuth client (yours, 0600) | `~/.config/omacal/client.json` |
| Account list (emails only) | `~/.config/omacal/accounts.json` |
| Refresh tokens | GNOME Keyring, `secret-tool search app omacal` |
| Event cache, one file per month | `~/.local/state/omacal/months/YYYY-MM.json` |
| Sync state | `~/.local/state/omacal/status.json` |

None of these live in the plugin folder or in this repo. Keep them out of any
public dotfiles repo too.

## CLI

```
omacal setup [client.json]     steps, or save the client
omacal add [--login-hint EMAIL] browser sign-in for one more account
omacal remove EMAIL            revoke at Google, forget token and cached events
omacal accounts | status       state
omacal sync [--month YYYY-MM] [--max-age MIN]
omacal list [--days N]         agenda in the terminal
```

## How it works

`Events.qml` (hosted by the bar widget, so reminders run while the popup is
closed) starts `omacal sync` every *Sync every* minutes. `--max-age` makes it a
no-op when the clock on another monitor just did the same. omacal refreshes
each account's access token, lists the calendars that account has ticked, and
fetches last month through two months ahead in one request per calendar. Each
month goes to its own file, which the QML watches. Months further out are
fetched when the popup first shows them. An account that fails (offline,
signed out) keeps its cached events.

Reminders ride on the clock label's existing once-a-minute tick, so they add no
timers. `omacal notify` sends each event's reminder once, no matter how many
monitors ask.

## Development

```
python3 -IB -m unittest discover -s tests/py -t tests/py
node tests/js/events-model.test.js && node tests/js/wiring.test.js
./deploy.sh        # then `omarchy restart shell` if a QML file was added
```

The first commit is the unmodified `omarchy.clock` from Omarchy 4.0.6. After an
Omarchy update, see what changed upstream with
`git diff --no-index <(git show 17088eb:Panel.qml) /usr/share/omarchy/shell/plugins/panels/clock/Panel.qml`
(same for BarWidget.qml and Model.js), then port what matters.

**Undo**: `omarchy plugin disable shadowone.clock` brings back the built-in
clock. Also set `bar.centerAnchor` in `~/.config/omarchy/shell.json` back to
`omarchy.clock`. Run `omacal remove EMAIL` for each account first to revoke access.
