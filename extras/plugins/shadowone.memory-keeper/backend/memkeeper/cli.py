"""memkeeper: the command line behind the bar widget and the timer."""

import argparse
import json
import sys

from . import actions, sessions
from . import state as st

EXIT_OK, EXIT_USAGE, EXIT_BUSY, EXIT_FAILED = 0, 2, 3, 4


def _show(data, as_json, text):
    print(json.dumps(data, ensure_ascii=False) if as_json else text)


def _result(data, as_json, text):
    _show(data, as_json, text if data.get("ok") else "failed: " + str(data.get("error")))
    return EXIT_OK if data.get("ok") else EXIT_FAILED


def _tick_text(t):
    lines = ["level %s, auto %s, stop after %.0f h idle" % (t["level"], "on" if t["auto"] else "off", t["limitSeconds"] / 3600)]
    for s in t["sessions"]:
        lines.append("  %-34s %-8s awake idle %5.1f h, clock %5.1f h  %s" % (
            s["name"][:34], s["status"], s["awakeIdleSeconds"] / 3600, s["wallIdleSeconds"] / 3600,
            "DUE" if s["due"] else (s["block"] or "not yet")))
    lines.extend("  stopped %s" % r["name"] if r["ok"] else "  could not stop %s: %s" % (r["name"], r["error"]) for r in t["stopped"])
    if t["reclaim"]:
        lines.append("  reclaimed cold cache: asked %s" % actions.human(t["reclaim"]["askedBytes"]))
    return "\n".join(lines)


def _config_set(key, value):
    cfg = st.load_config()
    if key == "auto":
        if value not in ("true", "false"):
            return "auto takes true or false"
        cfg["auto"] = value == "true"
    elif key in st.NUMBERS:
        try:
            cfg[key] = float(value) if "." in value else int(value)
        except ValueError:
            return "%s takes a number" % key
    else:
        return "unknown setting: %s" % key
    st.save_config(cfg)
    return None


def _set_keep(sid, on):
    cfg = st.load_config()
    keep = [k for k in cfg["keep"] if k != sid]
    if on:
        keep.append(sid)
    cfg["keep"] = keep
    st.save_config(cfg)


def parser():
    p = argparse.ArgumentParser(prog="memkeeper", description="Keep memory healthy: stop Claude sessions left idle, ease memory pressure.")
    sub = p.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("tick", help="what the timer runs: stop what is due, reclaim under pressure")
    t.add_argument("--dry-run", action="store_true", help="say what would happen, change nothing")
    t.add_argument("--json", action="store_true")
    sub.add_parser("scan", help="everything the panel shows").add_argument("--json", action="store_true")
    s = sub.add_parser("stop", help="stop one Claude session")
    s.add_argument("session")
    s.add_argument("--json", action="store_true")
    sub.add_parser("stop-idle", help="stop every session idle for an hour that may safely stop").add_argument("--json", action="store_true")
    r = sub.add_parser("resume", help="bring a stopped session back")
    r.add_argument("session")
    r.add_argument("--json", action="store_true")
    k = sub.add_parser("keep", help="never stop this session automatically")
    k.add_argument("session")
    k.add_argument("--off", action="store_true")
    sub.add_parser("reclaim", help="drop cold file cache of the user's apps").add_argument("--json", action="store_true")
    l = sub.add_parser("stop-process", help="stop a process from the leftovers list")
    l.add_argument("pid", type=int)
    l.add_argument("start", type=int)
    l.add_argument("--json", action="store_true")
    c = sub.add_parser("config", help="show or change settings")
    c.add_argument("action", nargs="?", choices=["set"])
    c.add_argument("key", nargs="?")
    c.add_argument("value", nargs="?")
    return p


def main(argv):
    args = parser().parse_args(argv)
    env = st.Env()
    if args.cmd == "scan":
        data = actions.scan(env)
        _show(data, args.json, json.dumps(data, ensure_ascii=False, indent=1))
        return EXIT_OK
    if args.cmd == "config":
        if args.action == "set":
            if args.key is None or args.value is None:
                print("usage: memkeeper config set KEY VALUE", file=sys.stderr)
                return EXIT_USAGE
            problem = _config_set(args.key, args.value)
            if problem:
                print(problem, file=sys.stderr)
                return EXIT_USAGE
        print(json.dumps(st.load_config(), indent=1))
        return EXIT_OK
    if args.cmd in ("stop", "resume", "keep") and not sessions.UUID_RE.match(args.session):
        print("not a session id: %s" % args.session, file=sys.stderr)
        return EXIT_USAGE
    if args.cmd == "keep":
        _set_keep(args.session, not args.off)
        return EXIT_OK
    if args.cmd == "resume":
        data = actions.resume(env, args.session)
        return _result(data, args.json, "resumed %s" % data.get("name"))
    if args.cmd == "reclaim":
        data = actions.do_reclaim(env, actions.MANUAL_RECLAIM_BYTES, "manual")
        return _result(data, args.json, "asked %s, free %s -> %s, swap %s -> %s" % (
            actions.human(data["askedBytes"]), actions.human(data["freeBefore"]), actions.human(data["freeAfter"]),
            actions.human(data["swapBefore"]), actions.human(data["swapAfter"])))
    if args.cmd == "stop-process":
        data = actions.stop_leftover(env, args.pid, args.start)
        return _result(data, args.json, "stopped")
    with st.op_lock() as got:
        if not got:
            print("another memkeeper job is running", file=sys.stderr)
            return EXIT_BUSY
        if args.cmd == "tick":
            data = actions.tick(env, args.dry_run)
            _show(data, args.json, _tick_text(data))
            return EXIT_OK
        if args.cmd == "stop":
            data = actions.stop_manual(env, args.session)
            return _result(data, args.json, "stopped %s" % data.get("name"))
        data = actions.stop_idle_now(env)
        _show({"ok": all(r["ok"] for r in data), "results": data}, args.json, "stopped %d" % sum(r["ok"] for r in data))
        return EXIT_OK if all(r["ok"] for r in data) else EXIT_FAILED
    return EXIT_USAGE
