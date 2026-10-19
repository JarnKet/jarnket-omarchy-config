"""Build output and dependency folders inside project directories.

Names alone are not proof: on this machine `src/lib/build/` and a `dist/`
are committed to git. Inside a repository a folder qualifies only when git
says it is ignored and tracks no file below it. Outside git only names that
are always generated qualify, and only next to a project marker file.
"""

import contextlib
import os
import stat
import subprocess
import time

from . import fsops, paths, registry

GENERATED = {"node_modules", ".next", ".turbo", ".svelte-kit", ".nuxt", ".vite", ".parcel-cache",
             "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".angular", ".expo"}
NEEDS_GIT = {"build", "dist", "out", "target", "coverage", ".output"}
MARKERS = ("package.json", "pyproject.toml", "setup.py", "requirements.txt", "Cargo.toml", "go.mod",
           "pom.xml", "build.gradle", "build.gradle.kts", "composer.json", "Gemfile", "deno.json")
MAX_DEPTH = 7


def _git(top, args, stdin=None, timeout=60):
    try:
        return subprocess.run(["git", "-C", top] + args, input=stdin, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return subprocess.CompletedProcess(args, 1, b"", b"")


def _find_candidates(root):
    """(dirpath, name, lstat) for every candidate folder under root, not descending into them."""
    found = []
    stack = [(root, 0)]
    while stack:
        current, depth = stack.pop()
        for name, st in fsops.list_children(current):
            if not stat.S_ISDIR(st.st_mode):
                continue
            if name in GENERATED or name in NEEDS_GIT:
                found.append((current, name, st))
                continue
            if name.startswith(".") or depth >= MAX_DEPTH:
                continue
            stack.append((os.path.join(current, name), depth + 1))
    return found


def _repo_top(path, boundary, cache):
    """Nearest ancestor of path (up to boundary) that has a .git entry."""
    trail = []
    cur = path
    while True:
        if cur in cache:
            top = cache[cur]
            break
        if os.path.lexists(os.path.join(cur, ".git")):
            top = cur
            break
        trail.append(cur)
        if cur == boundary or len(cur) <= len(boundary):
            top = None
            break
        cur = os.path.dirname(cur)
    for t in trail:
        cache[t] = top
    cache[cur] = top
    return top


def _git_verdicts(top, rels):
    """{rel: None | reason} for candidate folders relative to the repo top."""
    out = {}
    payload = b"".join(os.fsencode(r) + b"/\0" for r in rels)
    r = _git(top, ["check-ignore", "-z", "--stdin"], stdin=payload)
    ignored = {os.fsdecode(p).rstrip("/") for p in r.stdout.split(b"\0") if p}
    tracked = set()
    if rels:
        r = _git(top, ["ls-files", "-z", "--"] + list(rels))
        for p in r.stdout.split(b"\0"):
            if not p:
                continue
            path = os.fsdecode(p)
            for rel in rels:
                if path == rel or path.startswith(rel + "/"):
                    tracked.add(rel)
    for rel in rels:
        if rel in tracked:
            out[rel] = "tracked-by-git"
        elif rel not in ignored:
            out[rel] = "not-ignored-by-git"
        else:
            out[rel] = None
    return out


def _last_touched(project_dir, skip, top):
    newest = 0
    for name, st in fsops.list_children(project_dir):
        if name in skip or name == ".git":
            continue
        newest = max(newest, st.st_mtime)
    if top:
        r = _git(top, ["log", "-1", "--format=%ct"], timeout=20)
        with contextlib.suppress(ValueError):
            newest = max(newest, int(r.stdout.strip() or 0))
    return int(newest)


def collect(ctx, exclusive=False):
    memo_key = "projects-%s" % exclusive
    if memo_key not in ctx.memo:
        ctx.memo[memo_key] = _collect(ctx, exclusive)
    return ctx.memo[memo_key]


def _collect(ctx, exclusive):
    roots = []
    for r in ctx.cfg.get("projectRoots", []):
        p = os.path.normpath(paths.expand(r))
        if p.startswith(paths.home() + "/") and os.path.isdir(p) and not os.path.islink(p):
            roots.append(p)
    repo_cache = {}
    projects = {}
    for root in roots:
        for parent, name, st in _find_candidates(root):
            path = os.path.join(parent, name)
            top = _repo_top(parent, root, repo_cache)
            project_dir = top or parent
            proj = projects.setdefault(project_dir, {"dir": project_dir, "root": root, "top": top, "cands": []})
            proj["cands"].append((path, name, st))
    now = time.time()
    idle_days = ctx.cfg.get("projectIdleDays", 14)
    out = []
    all_paths = [c[0] for p in projects.values() for c in p["cands"]]
    sizes = fsops.du(all_paths, timeout=300)
    excl = fsops.btrfs_exclusive(all_paths) if exclusive else {}
    for proj in projects.values():
        top = proj["top"]
        verdicts = {}
        if top:
            rels = [os.path.relpath(c[0], top) for c in proj["cands"]]
            verdicts = _git_verdicts(top, rels)
        running = ctx.procs.using(proj["dir"])
        last = _last_touched(proj["dir"], {c[1] for c in proj["cands"]}, top)
        idle = last and (now - last) > idle_days * 86400
        items = []
        for path, name, st in proj["cands"]:
            reason = None
            if top:
                reason = verdicts.get(os.path.relpath(path, top), "not-ignored-by-git")
            elif name in NEEDS_GIT:
                reason = "no-git-proof"
            elif not any(os.path.lexists(os.path.join(os.path.dirname(path), m)) for m in MARKERS):
                reason = "no-project-marker"
            if reason is None and paths.is_kept(path, ctx.keep):
                reason = "kept"
            if reason is None and not fsops.round_trips(path):
                reason = "bad-name"
            key = fsops.home_rel(path)
            items.append({
                "key": key, "label": os.path.relpath(path, proj["dir"]), "kind": name,
                "bytes": sizes.get(path, 0), "exclusiveBytes": excl.get(path),
                "id": fsops.identity(st), "eligible": reason is None, "reason": reason,
                "selected": reason is None and bool(idle) and running is None,
            })
        items.sort(key=lambda i: -i["bytes"])
        out.append({
            "path": paths.contract(proj["dir"]), "label": os.path.relpath(proj["dir"], proj["root"]),
            "root": paths.contract(proj["root"]), "repo": top is not None, "lastTouched": last,
            "running": running.describe() if running else None,
            "bytes": sum(i["bytes"] for i in items if i["eligible"]), "items": items,
        })
    out.sort(key=lambda p: -p["bytes"])
    return {"roots": [paths.contract(r) for r in roots], "projects": out,
            "bytes": sum(p["bytes"] for p in out), "exclusive": exclusive}


class ProjectsCategory(registry.Category):
    id = "projects"
    group = "projects"
    title = "Project build folders"
    itemized = True

    def candidates(self, ctx):
        data = collect(ctx)
        out = []
        for proj in data["projects"]:
            for item in proj["items"]:
                if item["eligible"]:
                    out.append(registry.Candidate(item["key"], os.path.join(paths.home(), item["key"]),
                                                  label=item["label"]))
        return out

    def roots(self, ctx):
        return sorted({os.path.dirname(c.path) for c in self.candidates(ctx)})

    def item_blocked(self, ctx, cand):
        p = ctx.procs.using(cand.path)
        if p:
            return registry.blocked("in-use", "Used by %s" % p.describe())
        return None
