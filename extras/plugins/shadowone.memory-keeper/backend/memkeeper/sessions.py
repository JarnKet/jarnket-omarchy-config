"""Claude Code sessions: which exist, how long they have idled, which may stop.

The source of truth is ~/.claude/sessions/<pid>.json. statusUpdatedAt moves when
a turn starts or ends. The transcript's mtime does not mean the same: idle
sessions keep appending bookkeeping (bridge-session, autoreact ledger) to it.
"""

import glob
import json
import os
import re

from . import state as st

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
# Stdio MCP servers are started by Claude and end with it: that is not work.
MCP_RE = re.compile(r"(?:^|[\s/@_-])mcp(?:[\s/@_.-]|$)", re.I)
# Claude's Bash tool wraps every command in `source ~/.claude/shell-snapshots/...`.
BASH_TOOL = ".claude/shell-snapshots/"
SHELL_COMMS = {"bash", "sh", "zsh", "fish", "dash"}


def load(env, table):
    out = []
    for path in glob.glob(os.path.join(env.sessions_dir, "*.json")):
        try:
            with open(path, encoding="utf-8") as fh:
                d = json.load(fh)
            pid = int(d["pid"])
            start = int(d["procStart"])
        except (OSError, ValueError, KeyError, TypeError):
            continue
        p = table.get(pid)
        sid = d.get("sessionId")
        # A file whose pid now belongs to another program is a leftover.
        if not p or p.start != start or not isinstance(sid, str) or not UUID_RE.match(sid):
            continue
        out.append({
            "pid": pid,
            "procStart": start,
            "sessionId": sid,
            "name": str(d.get("name") or sid[:8]),
            "cwd": str(d.get("cwd") or ""),
            "status": str(d.get("status") or "unknown"),
            "waitingFor": d.get("waitingFor"),
            "kind": str(d.get("kind") or ""),
            "statusUpdatedAt": d.get("statusUpdatedAt"),
            "terminal": table.environ(pid, "HC_TERMINAL_ID"),
        })
    return out


def running_work(table, pid):
    """What the session runs besides MCP servers. Unknown children count too."""
    work = []
    for child in table.children(pid):
        text = child.text
        if BASH_TOOL in text:
            names = [d.comm for d in table.descendants(child.pid) if d.comm not in SHELL_COMMS]
            work.extend(names or ["shell command"])
        elif not MCP_RE.search(text):
            work.append(child.comm)
    seen = []
    for name in work:
        if name not in seen:
            seen.append(name)
    return seen


def update_idle(saved, sessions, mono, wall):
    """Track since when (in awake time) each idle session has been idle.

    A status change seen now happened at most one tick gap ago, while awake. A
    session first seen with an old stamp starts at zero: its age in awake time
    cannot be known, and nothing should stop right after installing or rebooting.
    """
    saved = saved if isinstance(saved, dict) else {}
    last = saved.get("lastTickMono")
    tracked = saved.get("sessions") if isinstance(saved.get("sessions"), dict) else {}
    # Monotonic time restarts at boot, and sessions do not survive a reboot.
    if not isinstance(last, (int, float)) or last > mono:
        last, tracked = mono, {}
    gap = mono - last
    now = {}
    for s in sessions:
        if s["status"] != "idle":
            continue
        stamp = s["statusUpdatedAt"]
        old = tracked.get(s["sessionId"])
        if old and old.get("stamp") == stamp:
            now[s["sessionId"]] = old
            continue
        ago = max(0.0, wall - stamp / 1000.0) if isinstance(stamp, (int, float)) else 0.0
        now[s["sessionId"]] = {"stamp": stamp, "since": mono - min(ago, gap)}
    return {"lastTickMono": mono, "sessions": now}


def awake_idle(idle_state, session, mono):
    entry = (idle_state.get("sessions") or {}).get(session["sessionId"])
    return max(0.0, mono - entry["since"]) if entry else 0.0


def wall_idle(session, wall):
    stamp = session["statusUpdatedAt"]
    return max(0.0, wall - stamp / 1000.0) if isinstance(stamp, (int, float)) else 0.0


def terminal_info(env, terminal):
    code, out = env.run(["hc", "get", terminal, "--json"])
    if code != 0:
        return None
    try:
        d = json.loads(out)
    except ValueError:
        return None
    return d if isinstance(d, dict) else None


def visible_tab(env):
    """The Herdr tab on screen: the selected tab of the active space."""
    view = st.read_json(env.view_file, {})
    if not isinstance(view, dict) or not isinstance(view.get("spaces"), dict):
        return None
    return view["spaces"].get(view.get("active"))


def block_reason(env, table, session, keep):
    """Why this session may not be stopped automatically, or None. The checks
    that cost a process come last, so most ticks start none."""
    if session["status"] != "idle":
        return session["status"]
    if session["kind"] != "interactive":
        return "not-interactive"
    if session["sessionId"] in keep:
        return "keep"
    if running_work(table, session["pid"]):
        return "running-work"
    if not session["terminal"]:
        return "not-herdr"
    info = terminal_info(env, session["terminal"])
    # The foreground can be a wrapper: `bash -c 'claude --resume ...; exec bash'`.
    if not info or not table.is_self_or_ancestor((info.get("foreground") or {}).get("pid"), session["pid"]):
        return "terminal-unknown"
    tab = (info.get("labels") or {}).get("herdr.tab")
    if tab is not None and tab == visible_tab(env):
        return "on-screen"
    return None


def input_text(screen):
    """Text in Claude's input box: what sits between the last two rule lines.

    Plain text cannot tell an unsent draft from a grey prompt suggestion, so
    the caller keeps it either way instead of guessing.
    """
    lines = screen.splitlines()
    rules = [i for i, line in enumerate(lines) if line.count("─") >= 20 and not line.replace("─", "").strip()]
    if len(rules) < 2:
        return ""
    body = "\n".join(line.strip() for line in lines[rules[-2] + 1:rules[-1]]).strip()
    if body.startswith(("❯", ">")):
        body = body[1:].strip()
    return body[:2000]


def read_input(env, terminal):
    if not terminal:
        return ""
    code, out = env.run(["hc", "read", terminal, "--json"])
    if code != 0:
        return ""
    try:
        return input_text(str(json.loads(out).get("text") or ""))
    except (ValueError, AttributeError):
        return ""
