"""diskkeeper command line. Every command prints JSON with --json, text otherwise.

Exit codes: 0 ok, 2 usage, 3 busy, 4 partial failure, 5 auth cancelled, 6 helper missing/outdated.
"""

import argparse
import concurrent.futures
import json
import os
import re
import secrets
import subprocess
import sys
import time

from . import SCHEMA, VERSION, explore, fsops, paths, projects, registry, roothelper, status

EXIT_OK, EXIT_USAGE, EXIT_BUSY, EXIT_PARTIAL, EXIT_AUTH, EXIT_HELPER = 0, 2, 3, 4, 5, 6


def emit(args, data, text=None):
    data = dict(data)
    data.setdefault("schema", SCHEMA)
    if args.json or text is None:
        sys.stdout.write(json.dumps(data, ensure_ascii=False) + "\n")
    else:
        sys.stdout.write(text.rstrip("\n") + "\n")
    sys.stdout.flush()


# ------------------------------------------------------------------ status

def cmd_status(args):
    data = status.status(args.warn_gb, args.critical_gb, notify=args.notify)
    text = "%s free of %s on / (%s)" % (status.human(data["freeBytes"]), status.human(data["totalBytes"]), data["level"])
    emit(args, data, text)
    return EXIT_OK


# ------------------------------------------------------------------ scan

def run_scan(cfg, only=None):
    ctx = registry.Context(cfg)
    cats = [c for c in registry.all_categories() if not only or c.id in only]
    started = time.time()
    ctx.procs  # snapshot /proc before any helper process starts
    results = {}
    errors = []

    def one(cat):
        try:
            return cat.id, cat.scan(ctx), None
        except Exception as exc:  # one broken category must not hide the others
            return cat.id, None, "%s: %s" % (type(exc).__name__, exc)

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for cid, data, err in pool.map(one, cats):
            if err:
                errors.append({"category": cid, "message": err})
            else:
                results[cid] = data
    ordered = [results[c.id] for c in cats if c.id in results]
    helper = roothelper.status()
    for cat in ordered:
        if cat["privilege"] == "root" and cat.get("available") and (not helper["installed"] or not helper["upToDate"]):
            cat["blocked"] = registry.blocked("helper-missing" if not helper["installed"] else "helper-outdated",
                                              "Run once in a terminal: " + helper["setupCommand"])
    reclaimable = 0
    for cat in ordered:
        if not cat.get("available") or cat.get("blocked") or not cat.get("defaultSelected"):
            continue
        if cat["itemized"]:
            reclaimable += sum(i["bytes"] for i in cat["items"] if i.get("selected"))
        else:
            reclaimable += cat.get("bytes", 0)
    data = {
        "kind": "scan", "version": VERSION, "ts": int(time.time()), "durationMs": int((time.time() - started) * 1000),
        "groups": [{"id": g, "title": t, "subtitle": s} for g, t, s in registry.GROUPS],
        "helper": helper, "categories": ordered, "errors": errors, "reclaimableBytes": reclaimable,
        "info": scan_info(),
    }
    return data


def scan_info():
    """Large things that are deliberately not offered, shown for context."""
    out = []
    candidates = [
        (os.path.join(paths.cache_dir(), "tracker3"), "Search index (GNOME localsearch); deleting forces a full re-index"),
        (os.path.join(paths.home(), ".claude", "projects"), "Claude Code transcripts; set cleanupPeriodDays to trim"),
    ]
    present = [(p, n) for p, n in candidates if os.path.isdir(p)]
    sizes = fsops.du([p for p, _ in present])
    for p, note in present:
        out.append({"path": paths.contract(p), "bytes": sizes.get(p, 0), "note": note})
    return out


def cmd_scan(args):
    cfg = paths.load_config()
    cached = paths.read_json(paths.state_file("scan.json"))
    if args.max_age and isinstance(cached, dict) and not cached.get("stale") \
            and time.time() - cached.get("ts", 0) < args.max_age:
        data = cached
    else:
        data = run_scan(cfg, set(args.only.split(",")) if args.only else None)
        if not args.only:
            paths.atomic_write_json(paths.state_file("scan.json"), data)
    emit(args, data, format_scan(data))
    return EXIT_OK


def format_scan(data):
    lines = []
    groups = {g["id"]: g["title"] for g in data["groups"]}
    current = None
    for cat in data["categories"]:
        if not cat.get("available") or (cat.get("hiddenWhenEmpty") and not cat.get("bytes") and not cat.get("items")):
            continue
        if cat["group"] != current:
            current = cat["group"]
            lines.append("\n%s" % groups.get(current, current).upper())
        size = "?" if cat["estimateKind"] == "unknown" else status.human(cat.get("bytes", 0))
        flag = " [%s]" % cat["blocked"]["detail"] if cat.get("blocked") else ""
        lines.append("  %-10s %-38s %s%s" % (size, cat["title"], cat["id"], flag))
    lines.append("\nDefault selection frees about %s. Clean with: diskkeeper clean <id>..." %
                 status.human(data.get("reclaimableBytes", 0)))
    return "\n".join(lines)


# ------------------------------------------------------------------ clean

TARGET_RE = re.compile(r"([a-z0-9-]+)(?::(.+))?", re.S)


def parse_targets(raw):
    """[(category, [keys] | None)] preserving order; keys None means the whole category."""
    order = []
    keys = {}
    for t in raw:
        m = TARGET_RE.fullmatch(t)
        if not m:
            raise ValueError("bad target: %r" % t[:80])
        cat, key = m.group(1), m.group(2)
        if cat not in keys:
            order.append(cat)
            keys[cat] = []
        if key is None:
            keys[cat] = None
        elif keys[cat] is not None:
            keys[cat].append(key)
    return [(c, keys[c]) for c in order]


class Job:
    def __init__(self, job_id, dry_run, targets):
        self.data = {"kind": "clean", "job": job_id, "pid": os.getpid(), "dryRun": dry_run, "state": "running",
                     "started": int(time.time()), "targets": targets, "results": [], "current": None}

    def save(self):
        paths.atomic_write_json(os.path.join(paths.jobs_dir(), "current.json"), self.data)


def cmd_clean(args):
    job_id = args.job or time.strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(2)
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,48}", job_id):
        emit(args, {"kind": "clean", "state": "error", "error": "bad job id"})
        return EXIT_USAGE
    try:
        plan = parse_targets(args.targets)
    except ValueError as exc:
        emit(args, {"kind": "clean", "job": job_id, "state": "error", "error": str(exc)})
        return EXIT_USAGE
    cats = registry.by_id()
    cats["projects"] = projects.ProjectsCategory()
    unknown = [c for c, _ in plan if c not in cats]
    if unknown:
        emit(args, {"kind": "clean", "job": job_id, "state": "error", "error": "unknown category: " + ", ".join(unknown)})
        return EXIT_USAGE
    try:
        with paths.op_lock():
            return run_clean(args, job_id, plan, cats)
    except paths.Busy:
        emit(args, {"kind": "clean", "job": job_id, "state": "busy", "error": "another clean job is running"})
        return EXIT_BUSY


def run_clean(args, job_id, plan, cats):
    cfg = paths.load_config()
    ctx = registry.Context(cfg, job=job_id, dry_run=args.dry_run)
    job = Job(job_id, args.dry_run, args.targets)
    job.save()
    _, free_before = status.statvfs("/")
    cached = paths.read_json(paths.state_file("scan.json"), {}) or {}
    scan_items = {c["id"]: {i["key"]: i for i in c.get("items", [])} for c in cached.get("categories", [])}
    if "projects" in [c for c, _ in plan]:
        pcache = paths.read_json(paths.state_file("projects.json"), {}) or {}
        scan_items["projects"] = {i["key"]: i for p in pcache.get("projects", []) for i in p["items"]}
    estimates = {cid: (c.get("bytes") or 0) for cid, c in ((c["id"], c) for c in cached.get("categories", []))}

    results = []
    auth = None
    # Root work first, in one pkexec call, so the fingerprint prompt appears right away.
    root_plan = [(c, k) for c, k in plan if cats[c].privilege == "root"]
    if root_plan:
        tokens, owners = [], []
        for cid, keys in root_plan:
            token = cats[cid].token(ctx, keys)
            if token:
                tokens.append(token)
                owners.append(cid)
            else:
                results.append(registry.result(cid, "skipped", "nothing-selected"))
        if tokens:
            job.data["current"] = "system (waiting for authentication)"
            job.save()
            res = roothelper.run(tokens, dry_run=args.dry_run)
            auth = res["auth"]
            by_token = {v.get("token"): v for v in res["verbs"]}
            for cid, token in zip(owners, tokens):
                v = by_token.get(token)
                if res["auth"] != "ok":
                    results.append(registry.result(cid, "skipped", "auth-" + res["auth"], res["message"]))
                elif v is None:
                    results.append(registry.result(cid, "failed", "helper-error", res["message"]))
                else:
                    r = registry.result(cid, "done" if v.get("ok") else "failed", None if v.get("ok") else "helper-error",
                                        v.get("message", ""), v.get("freedBytes", estimates.get(cid)))
                    results.append(r)
            job.data["results"] = results
            job.save()

    for cid, keys in plan:
        cat = cats[cid]
        if cat.privilege == "root":
            continue
        job.data["current"] = cat.title
        job.save()
        try:
            res = cat.clean(ctx, keys, scan_items.get(cid, {}))
        except Exception as exc:
            res = [registry.result(cid, "failed", "error", "%s: %s" % (type(exc).__name__, exc))]
        if not cat.itemized:
            for r in res:
                if r.get("status") == "done" and r.get("estimateBytes") is None:
                    r["estimateBytes"] = estimates.get(cid)
        results.extend(res)
        job.data["results"] = results
        job.save()

    with_suppress_sync()
    _, free_after = status.statvfs("/")
    done = [r for r in results if r["status"] == "done"]
    notes = []
    done_cats = {r["target"].split(":", 1)[0] for r in done}
    if done_cats & {"docker-build-cache", "docker-dangling-images", "docker-unused-images", "docker-volumes", "coredumps"}:
        notes.append("Docker and system crash dumps live in the snapshotted system volume; some space returns only after old snapshots are removed.")
    if "downloads-old" in done_cats:
        notes.append("Downloads went to the Trash. Empty the Trash to get that space back.")
    if "snapshots" in done_cats:
        notes.append("Snapshot space is released in the background over the next minutes.")
    job.data.update({
        "state": "done", "finished": int(time.time()), "current": None, "results": results,
        "freeBefore": free_before, "freeAfter": free_after,
        "measuredFreedBytes": 0 if args.dry_run else max(0, free_after - free_before),
        "estimateBytes": sum(r.get("estimateBytes") or 0 for r in done), "auth": auth, "notes": notes,
    })
    job.save()
    paths.atomic_write_json(os.path.join(paths.jobs_dir(), job_id + ".json"), job.data)
    prune_jobs()
    if not args.dry_run:
        paths.append_jsonl(paths.state_file("history.jsonl"), {
            "ts": job.data["finished"], "job": job_id, "measuredFreedBytes": job.data["measuredFreedBytes"],
            "estimateBytes": job.data["estimateBytes"],
            "done": [r["target"] for r in done],
            "skipped": [[r["target"], r.get("reason")] for r in results if r["status"] == "skipped"],
            "failed": [[r["target"], r.get("detail", "")] for r in results if r["status"] == "failed"],
        })
        mark_scan_stale()
    emit(args, job.data, format_clean(job.data))
    if any(r["status"] == "failed" for r in results):
        return EXIT_PARTIAL
    if auth in ("missing", "outdated") and len(done) == 0:
        return EXIT_HELPER
    if auth == "cancelled" and len(done) == 0:
        return EXIT_AUTH
    return EXIT_OK


def with_suppress_sync():
    """Commit the btrfs transaction so freed extents show up in statvfs."""
    try:
        subprocess.run(["sync", "-f", paths.home(), "/"], timeout=60, check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        pass


def mark_scan_stale():
    path = paths.state_file("scan.json")
    data = paths.read_json(path)
    if isinstance(data, dict):
        data["stale"] = True
        paths.atomic_write_json(path, data)


def prune_jobs(keep=20):
    try:
        files = sorted(f for f in os.listdir(paths.jobs_dir()) if f.endswith(".json") and f != "current.json")
    except OSError:
        return
    for f in files[:-keep]:
        try:
            os.unlink(os.path.join(paths.jobs_dir(), f))
        except OSError:
            pass


def format_clean(data):
    lines = []
    for r in data["results"]:
        extra = r.get("reason") or ""
        if r.get("detail"):
            extra = (extra + ": " if extra else "") + r["detail"]
        lines.append("  %-8s %s%s" % (r["status"], r["target"], "  (" + extra + ")" if extra else ""))
    if data.get("dryRun"):
        lines.append("Dry run: nothing was deleted. Estimated %s." % status.human(data.get("estimateBytes", 0)))
    else:
        lines.append("Freed %s (estimated %s)." % (status.human(data.get("measuredFreedBytes", 0)),
                                                  status.human(data.get("estimateBytes", 0))))
    lines.extend(data.get("notes") or [])
    return "\n".join(lines)


# ------------------------------------------------------------------ others

def cmd_projects(args):
    cfg = paths.load_config()
    ctx = registry.Context(cfg)
    data = projects.collect(ctx, exclusive=args.exclusive)
    data.update(kind="projects", ts=int(time.time()), idleDays=cfg["projectIdleDays"])
    paths.atomic_write_json(paths.state_file("projects.json"), data)
    lines = []
    for p in data["projects"]:
        lines.append("%s  %s%s" % (status.human(p["bytes"]), p["path"], "  [running]" if p["running"] else ""))
        for i in p["items"]:
            lines.append("    %-9s %s%s" % (status.human(i["bytes"]), i["label"], "" if i["eligible"] else "  (" + i["reason"] + ")"))
    emit(args, data, "\n".join(lines))
    return EXIT_OK


def cmd_explore(args):
    data = explore.explore(paths.load_config(), args.path or "", args.limit)
    data["kind"] = "explore"
    if "error" in data:
        emit(args, data)
        return EXIT_USAGE
    lines = ["%s  %s" % (status.human(data["total"]), data["display"])]
    for c in data["children"]:
        lines.append("  %-10s %s%s" % (status.human(c["bytes"]), c["name"], "/" if c["type"] == "dir" else ""))
    emit(args, data, "\n".join(lines))
    return EXIT_OK


def cmd_trash(args):
    cfg = paths.load_config()
    results = explore.trash(cfg, args.rels, registry.Context(cfg))
    emit(args, {"kind": "trash", "results": results, "freedNow": 0},
         "\n".join("%s %s %s" % (r["status"], r["rel"], r.get("reason", "")) for r in results))
    return EXIT_PARTIAL if any(r["status"] == "failed" for r in results) else EXIT_OK


def cmd_keep(args):
    ok, info = explore.keep_change(paths.load_config(), args.action, args.rel)
    emit(args, {"kind": "keep", "ok": ok, "entry": info if ok else None, "error": None if ok else info},
         info)
    return EXIT_OK if ok else EXIT_USAGE


def cmd_snapshots(args):
    res = roothelper.run(["snapshots-list"])
    snaps = []
    if res["auth"] == "ok" and res["verbs"]:
        snaps = res["verbs"][0].get("snapshots") or []
    data = {"kind": "snapshots", "auth": res["auth"], "ok": res["ok"], "message": res["message"], "snapshots": snaps}
    lines = ["%4d  %-6s %-20s %s%s" % (s["number"], s["type"], s["date"], s["description"],
                                        "  [kept]" if s.get("protected") else "") for s in snaps]
    emit(args, data, "\n".join(lines) or res["message"])
    if res["auth"] == "cancelled":
        return EXIT_AUTH
    if res["auth"] in ("missing", "outdated"):
        return EXIT_HELPER
    return EXIT_OK if res["ok"] else EXIT_PARTIAL


def cmd_history(args):
    entries = []
    try:
        with open(paths.state_file("history.jsonl"), encoding="utf-8") as fh:
            for line in fh:
                try:
                    entries.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        pass
    entries = entries[-args.limit:][::-1]
    month_start = time.mktime(time.localtime()[:2] + (1, 0, 0, 0, 0, 0, -1))
    month = sum(e.get("measuredFreedBytes", 0) for e in entries if e.get("ts", 0) >= month_start)
    lines = ["%s  freed %s  (%d done)" % (time.strftime("%Y-%m-%d %H:%M", time.localtime(e["ts"])),
                                          status.human(e.get("measuredFreedBytes", 0)), len(e.get("done", [])))
             for e in entries]
    emit(args, {"kind": "history", "entries": entries, "monthFreedBytes": month}, "\n".join(lines) or "No cleanups yet.")
    return EXIT_OK


def cmd_job(args):
    data = paths.read_json(os.path.join(paths.jobs_dir(), "current.json"), {}) or {}
    data = dict(data, kind="job", active=paths.lock_is_held())
    if data.get("state") == "running" and not data["active"]:
        data["state"] = "interrupted"
    emit(args, data, "%s %s" % (data.get("job", "-"), data.get("state", "none")))
    return EXIT_OK


def cmd_root_status(args):
    st = roothelper.status()
    emit(args, dict(st, kind="root-status"),
         "installed" if st["installed"] and st["upToDate"] else ("outdated: " if st["installed"] else "missing: ") + st["setupCommand"])
    return EXIT_OK


def build_parser():
    p = argparse.ArgumentParser(prog="diskkeeper", description="Keep the disk from filling up.")
    p.add_argument("--version", action="version", version="diskkeeper " + VERSION)
    sub = p.add_subparsers(dest="cmd", required=True)

    def add(name, func, help_):
        sp = sub.add_parser(name, help=help_)
        sp.add_argument("--json", action="store_true", help="machine-readable output")
        sp.set_defaults(func=func)
        return sp

    sp = add("status", cmd_status, "free space and warning level")
    sp.add_argument("--notify", action="store_true", help="send a desktop notification when the level gets worse")
    sp.add_argument("--warn-gb", type=float, default=20)
    sp.add_argument("--critical-gb", type=float, default=10)
    sp = add("scan", cmd_scan, "measure every cleanup category")
    sp.add_argument("--max-age", type=int, default=0, help="reuse a cached scan younger than this many seconds")
    sp.add_argument("--only", help="comma-separated category ids (not cached)")
    sp = add("clean", cmd_clean, "clean categories or single items (category or category:key)")
    sp.add_argument("--job", help="job id (default: generated)")
    sp.add_argument("--dry-run", action="store_true", help="show what would be removed")
    sp.add_argument("targets", nargs="+")
    sp = add("projects", cmd_projects, "build and dependency folders in project directories")
    sp.add_argument("--exclusive", action="store_true", help="also measure btrfs exclusive size (slow)")
    sp = add("explore", cmd_explore, "largest entries of a folder in $HOME")
    sp.add_argument("--path", default="", help="folder relative to $HOME")
    sp.add_argument("--limit", type=int, default=200)
    sp = add("trash", cmd_trash, "move entries (relative to $HOME) to the Trash")
    sp.add_argument("rels", nargs="+")
    sp = add("keep", cmd_keep, "add or remove a path (relative to $HOME) on the keep list")
    sp.add_argument("action", choices=["add", "remove"])
    sp.add_argument("rel")
    add("snapshots", cmd_snapshots, "list system snapshots (asks for authentication)")
    sp = add("history", cmd_history, "past cleanups")
    sp.add_argument("--limit", type=int, default=20)
    add("root-status", cmd_root_status, "is the root helper installed and current?")
    add("job", cmd_job, "state of the latest clean job")
    return p


def main(argv):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        return 130
