"""What Memory Keeper does: the timer's tick, the panel's scan, and the actions.

Things this file must never do: drop_caches, swapoff, a forced kill, or send a
key or text to a running Claude. Stopping is one SIGTERM to a process checked a
moment earlier; everything else about a session stays on disk for --resume.
"""

import json
import os
import re
import shlex

from . import meminfo, sessions
from . import state as st
from .procs import Table, alive

GIB = 1024 ** 3
AUTO_RECLAIM_BYTES = 1 * GIB
MANUAL_RECLAIM_BYTES = 4 * GIB
STOP_WAIT_SECONDS = 10
STOPPED_KEEP_SECONDS = 14 * 24 * 3600
STOPPED_MAX = 30
NOTIFY_CRITICAL_EVERY = 6 * 3600
LEFTOVER_MIN_AGE = 3600
MANUAL_MIN_IDLE = 3600
PANEL_ID = "shadowone.memory-keeper"

DEV_COMM = re.compile(r"^(node|npm|npx|pnpm|yarn|bun|deno|workerd|wrangler|vite|next-server|next|esbuild|tsx|nodemon"
                      r"|turbo|webpack|agent-browser)([ -]|$)")
NOT_LEFTOVER = ("/.config/omarchy/plugins/", "/usr/share/omarchy/", "/.local/share/herdr")
APP_NAMES = {"brave": "Brave", "claude": "Claude Code", "quickshell": "Omarchy shell",
             "claude-desktop": "Claude Desktop", "chrome": "Chrome", "Hyprland": "Hyprland",
             "herdr-app": "Herdr", "herdr-core": "Herdr", "workerd": "Node", "esbuild": "Node"}
SHELL_APP = "Omarchy shell"


# ------------------------------------------------------------ stopped list

def _stopped_path():
    return st.state_file("stopped.json")


def read_stopped():
    data = st.read_json(_stopped_path(), [])
    return data if isinstance(data, list) else []


def current_stopped(live_ids, now):
    """Entries still worth showing: not running again, and not too old."""
    return [e for e in read_stopped() if isinstance(e, dict) and e.get("sessionId") not in live_ids
            and now - e.get("stoppedAt", 0) < STOPPED_KEEP_SECONDS]


# ------------------------------------------------------------ stop

def stop_session(env, table, session, reason):
    pid, start, sid = session["pid"], session["procStart"], session["sessionId"]
    bytes_held = table.tree_bytes(pid)
    children = [(p.pid, p.start, p.comm) for p in table.descendants(pid)]
    info = sessions.terminal_info(env, session["terminal"]) if session["terminal"] else None
    entry = {
        "sessionId": sid, "name": session["name"], "cwd": session["cwd"], "terminal": session["terminal"],
        "space": ((info or {}).get("labels") or {}).get("herdr.space"), "where": ((info or {}).get("labels") or {}).get("where"),
        "stoppedAt": env.wall(), "freedBytes": bytes_held, "reason": reason,
        "inputText": sessions.read_input(env, session["terminal"]),
    }
    # Saved first: a shell reload can end this process while it waits below, and
    # an entry for a session that turns out alive is dropped by current_stopped.
    others = [e for e in read_stopped() if isinstance(e, dict) and e.get("sessionId") != sid]
    st.write_json(_stopped_path(), (others + [entry])[-STOPPED_MAX:])
    try:
        env.terminate(pid)
    except ProcessLookupError:
        pass
    except OSError as e:
        _forget_stopped(sid)
        return {"ok": False, "sessionId": sid, "name": session["name"], "error": e.strerror or "signal failed"}
    for _ in range(STOP_WAIT_SECONDS * 4):
        if not alive(env.proc, pid, start):
            break
        env.sleep(0.25)
    else:
        _forget_stopped(sid)
        st.append_history({"at": env.wall(), "event": "stop-failed", "sessionId": sid, "name": session["name"], "reason": reason})
        return {"ok": False, "sessionId": sid, "name": session["name"], "error": "still running after %d s" % STOP_WAIT_SECONDS}
    left = [comm for child_pid, child_start, comm in children if alive(env.proc, child_pid, child_start)]
    st.append_history({"at": env.wall(), "event": "stopped", "sessionId": sid, "name": session["name"], "reason": reason,
                       "freedBytes": bytes_held, "childrenLeft": left})
    return {"ok": True, "sessionId": sid, "name": session["name"], "freedBytes": bytes_held, "childrenLeft": left}


def _forget_stopped(sid):
    st.write_json(_stopped_path(), [e for e in read_stopped() if isinstance(e, dict) and e.get("sessionId") != sid])


def stop_manual(env, sid):
    """The panel's Stop: the person chose this one, so only `busy` refuses."""
    table = Table(env.proc)
    for s in sessions.load(env, table):
        if s["sessionId"] == sid:
            if s["status"] == "busy":
                return {"ok": False, "sessionId": sid, "name": s["name"], "error": "it is working right now"}
            return stop_session(env, table, s, "manual")
    return {"ok": False, "sessionId": sid, "error": "not running"}


def stop_idle_now(env):
    """The panel's Stop idle now: the same safety checks as the timer, but by
    the clock, because the person is here and just read the list."""
    table = Table(env.proc)
    keep = st.load_config()["keep"]
    results = []
    for s in sessions.load(env, table):
        if sessions.wall_idle(s, env.wall()) >= MANUAL_MIN_IDLE and not sessions.block_reason(env, table, s, keep):
            results.append(stop_session(env, table, s, "stop-idle-now"))
    return results


# ------------------------------------------------------------ resume

def resume(env, sid):
    if not sessions.UUID_RE.match(sid):
        return {"ok": False, "error": "not a session id"}
    table = Table(env.proc)
    live = {s["sessionId"]: s for s in sessions.load(env, table)}
    if sid in live:
        if live[sid]["terminal"]:
            env.run(["herdr-app", "do", "agent.focus", "--terminal", live[sid]["terminal"]])
        return {"ok": True, "already": True, "name": live[sid]["name"]}
    entry = next((e for e in read_stopped() if isinstance(e, dict) and e.get("sessionId") == sid), None)
    if not entry:
        return {"ok": False, "error": "this session is not on the stopped list"}
    cwd = entry.get("cwd") or st.home()
    if not os.path.isdir(cwd):
        return {"ok": False, "error": "its folder is gone: " + cwd}
    command = "cd %s && claude --resume %s" % (shlex.quote(cwd), sid)
    terminal = entry.get("terminal")
    info = sessions.terminal_info(env, terminal) if terminal else None
    foreground = (info or {}).get("foreground") or {}
    if info and info.get("state") == "live" and foreground.get("name") in sessions.SHELL_COMMS:
        # Text goes to a shell prompt only, never into a running program.
        if env.run(["hc", "send", terminal, command])[0] == 0:
            env.run(["herdr-app", "do", "agent.focus", "--terminal", terminal])
            return {"ok": True, "name": entry.get("name"), "where": "same tab"}
    argv = ["bash", "-ic", "claude --resume %s; exec bash" % sid]
    new_tab = ["herdr-app", "do", "tab.new", "--name", str(entry.get("name") or sid[:8]), "--folder", cwd, "--argv", json.dumps(argv)]
    if entry.get("space") and env.run(new_tab + ["--space", entry["space"]])[0] == 0:
        return {"ok": True, "name": entry.get("name"), "where": "new tab"}
    if env.run(new_tab)[0] == 0:
        return {"ok": True, "name": entry.get("name"), "where": "new tab"}
    return {"ok": False, "error": "Herdr did not open it", "command": command}


# ------------------------------------------------------------ leftovers

def _cwd_of(env, pid):
    try:
        return os.readlink(os.path.join(env.proc, str(pid), "cwd"))
    except OSError:
        return ""


def leftovers(env, table):
    """Dev tools that outlived the terminal that started them: no tty, adopted
    by init or the user's systemd, not one of its services. Listed, not touched:
    a server may still be wanted, so only the person can stop one."""
    user_systemd = {p.pid for p in table.procs.values() if p.comm == "systemd" and p.uid == env.uid and p.ppid == 1}
    uptime = env.uptime()
    hz = env.ticks_per_second()
    out = []
    for p in table.procs.values():
        if p.uid != env.uid or p.tty != 0 or not (p.ppid == 1 or p.ppid in user_systemd):
            continue
        if not DEV_COMM.match(p.comm) or any(x in p.text for x in NOT_LEFTOVER):
            continue
        leaf = table.cgroup_leaf(p.pid)
        if leaf.endswith(".service") and not leaf.startswith("hc-hold-"):
            continue
        age = uptime - p.start / hz
        if age < LEFTOVER_MIN_AGE:
            continue
        out.append({"pid": p.pid, "start": p.start, "label": p.comm, "cwd": _cwd_of(env, p.pid),
                    "ageSeconds": age, "bytes": table.tree_bytes(p.pid)})
    return sorted(out, key=lambda e: -e["bytes"])


def stop_leftover(env, pid, start):
    table = Table(env.proc)
    # Only what the list would show right now: the panel cannot name other processes.
    if not any(e["pid"] == pid and e["start"] == start for e in leftovers(env, table)):
        return {"ok": False, "error": "no longer a leftover"}
    held = table.tree_bytes(pid)
    env.terminate(pid)
    for _ in range(STOP_WAIT_SECONDS * 4):
        if not alive(env.proc, pid, start):
            st.append_history({"at": env.wall(), "event": "leftover-stopped", "label": table.get(pid).comm, "freedBytes": held})
            return {"ok": True, "freedBytes": held}
        env.sleep(0.25)
    return {"ok": False, "error": "still running after %d s" % STOP_WAIT_SECONDS}


# ------------------------------------------------------------ reclaim

def do_reclaim(env, max_bytes, reason):
    before = meminfo.read(env.proc)
    asked, error = meminfo.reclaim(env.app_slice, max_bytes)
    after = meminfo.read(env.proc)
    result = {"ok": error is None, "askedBytes": asked, "error": error,
              "freeBefore": before["freeBytes"], "freeAfter": after["freeBytes"],
              "swapBefore": before["swapUsedBytes"], "swapAfter": after["swapUsedBytes"]}
    if asked:
        st.append_history(dict(result, at=env.wall(), event="reclaim", reason=reason))
    return result


# ------------------------------------------------------------ notifications

def human(n):
    if n >= GIB:
        return "%.1f GB" % (n / GIB)
    return "%d MB" % round(n / (1024 ** 2))


def notify(env, urgency, title, body):
    env.run(["omarchy-notification-send", "--app-name", "Memory Keeper", "-u", urgency, "-g", "\U000f035b",
             title, body, "--exec", "omarchy-shell", "shell", "toggle", PANEL_ID])


def notify_after_tick(env, stopped, level, now, dry_run):
    if dry_run:
        return
    done = [r for r in stopped if r["ok"]]
    if done:
        freed = sum(r["freedBytes"] for r in done)
        one = len(done) == 1
        notify(env, "normal", "Stopped %s idle Claude session%s" % ("an" if one else len(done), "" if one else "s"),
               "Freed about %s. Click to see them or resume." % human(freed))
    path = st.state_file("notify.json")
    saved = st.read_json(path, {})
    saved = saved if isinstance(saved, dict) else {}
    if level == "critical" and now - saved.get("criticalAt", 0) >= NOTIFY_CRITICAL_EVERY:
        notify(env, "critical", "Memory is running out", "Click to see what is using it.")
        st.write_json(path, {"criticalAt": now})


# ------------------------------------------------------------ tick

def tick(env, dry_run=False):
    cfg = st.load_config()
    table = Table(env.proc)
    mem = meminfo.read(env.proc)
    level, reasons = meminfo.level(mem, cfg)
    found = sessions.load(env, table)
    mono, wall = env.mono(), env.wall()
    idle = sessions.update_idle(st.read_json(st.state_file("idle.json"), {}), found, mono, wall)
    if not dry_run:
        st.write_json(st.state_file("idle.json"), idle)
    limit = meminfo.idle_limit_seconds(level, cfg)
    report, stopped = [], []
    for s in found:
        awake = sessions.awake_idle(idle, s, mono)
        past_limit = s["status"] == "idle" and awake >= limit
        # block_reason can start a process; a normal tick asks only when it matters.
        block = sessions.block_reason(env, table, s, cfg["keep"]) if past_limit or dry_run else None
        due = cfg["auto"] and past_limit and block is None
        report.append({"sessionId": s["sessionId"], "name": s["name"], "status": s["status"], "awakeIdleSeconds": awake,
                       "wallIdleSeconds": sessions.wall_idle(s, wall), "block": block, "due": due})
        if due and not dry_run:
            stopped.append(stop_session(env, table, s, "idle-" + level))
    reclaimed = None
    if stopped:
        mem = meminfo.read(env.proc)
        level, reasons = meminfo.level(mem, cfg)
    if cfg["auto"] and meminfo.should_reclaim(level, mem, cfg) and not dry_run:
        reclaimed = do_reclaim(env, AUTO_RECLAIM_BYTES, "pressure-" + level)
    notify_after_tick(env, stopped, level, wall, dry_run)
    return {"kind": "tick", "dryRun": dry_run, "auto": cfg["auto"], "level": level, "reasons": reasons, "limitSeconds": limit,
            "sessions": report, "stopped": stopped, "reclaim": reclaimed}


# ------------------------------------------------------------ scan

def _app_name(comm):
    if comm in APP_NAMES:
        return APP_NAMES[comm]
    if re.match(r"^(node|npm|npx|pnpm)([ -]|$)", comm):
        return "Node"
    return comm


def app_usage(env, table):
    usage = {}
    for p in table.procs.values():
        if p.uid == env.uid:
            name = _app_name(p.comm)
            usage[name] = usage.get(name, 0) + table.bytes_of(p.pid)
    return usage


def scan(env):
    cfg = st.load_config()
    table = Table(env.proc)
    mem = meminfo.read(env.proc)
    level, reasons = meminfo.level(mem, cfg)
    limit = meminfo.idle_limit_seconds(level, cfg)
    found = sessions.load(env, table)
    mono, wall = env.mono(), env.wall()
    idle = st.read_json(st.state_file("idle.json"), {})
    idle = idle if isinstance(idle, dict) else {}
    rows = []
    for s in found:
        awake = sessions.awake_idle(idle, s, mono)
        block = sessions.block_reason(env, table, s, cfg["keep"])
        rows.append({
            "sessionId": s["sessionId"], "name": s["name"], "cwd": s["cwd"], "status": s["status"],
            "waitingFor": s["waitingFor"], "terminal": s["terminal"], "bytes": table.tree_bytes(s["pid"]),
            "wallIdleSeconds": sessions.wall_idle(s, wall), "awakeIdleSeconds": awake,
            "stopsInSeconds": max(0.0, limit - awake) if cfg["auto"] and block is None else None,
            "block": block, "work": sessions.running_work(table, s["pid"]), "keep": s["sessionId"] in cfg["keep"],
        })
    rows.sort(key=lambda r: -r["wallIdleSeconds"])
    usage = app_usage(env, table)
    apps = [{"name": k, "bytes": v} for k, v in sorted(usage.items(), key=lambda kv: -kv[1])[:6]]
    month_ago = wall - 30 * 24 * 3600
    recent = [h for h in st.read_history() if isinstance(h, dict) and h.get("at", 0) >= month_ago and h.get("event") == "stopped"]
    live_ids = {s["sessionId"] for s in found}
    return {
        "kind": "scan", "ts": wall, "config": cfg, "mem": mem, "level": level, "reasons": reasons, "limitSeconds": limit,
        "sessions": rows, "stopped": sorted(current_stopped(live_ids, wall), key=lambda e: -e.get("stoppedAt", 0)),
        "apps": apps, "shellBytes": usage.get(SHELL_APP, 0), "leftovers": leftovers(env, table),
        "stoppedThisMonth": len(recent), "freedThisMonth": sum(h.get("freedBytes", 0) for h in recent),
    }
