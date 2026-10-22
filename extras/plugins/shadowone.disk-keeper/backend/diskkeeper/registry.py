"""The cleanup categories.

A category never trusts a path from the UI. clean() recomputes the
category's candidates and only acts on keys found in that fresh set, so a
key is a name, never an address.
"""

import contextlib
import fnmatch
import os
import re
import stat
import subprocess
import threading
import time

from . import fsops, paths, procs

GROUPS = [
    ("dev", "Developer caches", "Rebuilt automatically"),
    ("app", "App caches", "The app must be closed"),
    ("tools", "Downloaded tools", "Downloaded again when needed"),
    ("system", "System", "Asks for your fingerprint or password"),
    ("docker", "Docker", "Space may return only after snapshots rotate"),
    ("review", "Review first", "Personal files: check before removing"),
]


class Candidate:
    __slots__ = ("key", "path", "label", "detail", "st", "actionable", "in_use_check", "extra")

    def __init__(self, key, path, label=None, detail="", st=None, in_use_check=False, extra=None):
        self.key = key
        self.path = path
        self.label = label if label is not None else fsops.display_name(key)
        self.detail = detail
        self.st = st if st is not None else fsops.lstat(path)
        self.actionable = fsops.round_trips(key)
        self.in_use_check = in_use_check
        self.extra = extra or {}


class Context:
    def __init__(self, cfg, job="scan", dry_run=False, proc_root="/proc"):
        self.cfg = cfg
        self.keep = paths.keep_paths(cfg)
        self.job = job
        self.dry_run = dry_run
        self._proc_root = proc_root
        self._procs = None
        self._lock = threading.Lock()
        self.memo = {}

    @property
    def procs(self):
        # Categories scan in parallel threads; build the /proc table only once.
        with self._lock:
            if self._procs is None:
                self._procs = procs.ProcTable(self._proc_root)
            return self._procs

    def run(self, argv, timeout=120, env=None):
        """Run a tool with cwd=$HOME (mise shims pick versions by directory)."""
        full_env = dict(os.environ)
        if env:
            full_env.update(env)
        try:
            return subprocess.run(
                argv, cwd=paths.home(), env=full_env, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                errors="replace", timeout=timeout, check=False,
            )
        except FileNotFoundError:
            return subprocess.CompletedProcess(argv, 127, "", "%s: not found" % argv[0])
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(argv, 124, "", "%s: timed out" % argv[0])


def blocked(reason, detail=""):
    return {"reason": reason, "detail": detail}


def result(target, status, reason=None, detail="", bytes_=None):
    out = {"target": target, "status": status}
    if reason:
        out["reason"] = reason
    if detail:
        out["detail"] = detail
    if bytes_ is not None:
        out["estimateBytes"] = bytes_
    return out


class Category:
    id = ""
    group = "dev"
    title = ""
    description = ""
    risk = "regenerates"          # regenerates | redownload | app-closed | data
    frees_when = "now"            # now | after-snapshots | after-empty-trash | async
    privilege = "user"            # user | docker | root
    itemized = False              # items can be picked one by one
    confirm = "normal"            # normal | extra
    default_selected = True
    estimate_kind = "du"          # du | tool | unknown
    app = None                    # key into procs.APPS that must not be running
    in_use_check = False          # per-item /proc scan before deleting
    hidden_when_empty = True

    def available(self, ctx):
        return True

    def roots(self, ctx):
        return []

    def candidates(self, ctx):
        return []

    def category_blocked(self, ctx):
        if self.app:
            p = procs.app_running(ctx.procs, self.app)
            if p:
                return blocked("app-running", "Close %s first (%s)" % (procs.APP_NAMES[self.app], p.describe()))
        return None

    def item_blocked(self, ctx, cand):
        if not cand.actionable:
            return blocked("bad-name", "Name is not valid UTF-8")
        if paths.is_kept(cand.path, ctx.keep):
            return blocked("kept", "On your keep list")
        if self.in_use_check or cand.in_use_check:
            p = ctx.procs.using(cand.path)
            if p:
                return blocked("in-use", "Used by %s" % p.describe())
        return None

    def note(self, ctx):
        return None

    def describe(self):
        return {
            "id": self.id, "group": self.group, "title": self.title, "description": self.description,
            "risk": self.risk, "freesWhen": self.frees_when, "privilege": self.privilege,
            "itemized": self.itemized, "confirm": self.confirm, "defaultSelected": self.default_selected,
            "estimateKind": self.estimate_kind, "hiddenWhenEmpty": self.hidden_when_empty,
        }

    def scan(self, ctx):
        out = self.describe()
        if not self.available(ctx):
            out.update(available=False, bytes=0, items=[], blocked=None, note=None)
            return out
        cands = self.candidates(ctx)
        sizes = fsops.du([c.path for c in cands]) if self.estimate_kind == "du" else {}
        cat_block = self.category_blocked(ctx)
        items = []
        total = 0
        for c in cands:
            size = c.extra.get("bytes", sizes.get(c.path, 0))
            ib = self.item_blocked(ctx, c)
            items.append({
                "key": c.key, "label": c.label, "detail": c.detail, "bytes": size,
                "mtime": int(c.st.st_mtime) if c.st else 0, "id": fsops.identity(c.st),
                "actionable": c.actionable and ib is None, "blocked": ib,
                "selected": self.default_selected and ib is None and cat_block is None and c.extra.get("selected", True),
            })
            if ib is None:
                total += size
        items.sort(key=lambda i: -i["bytes"])
        out.update(available=True, bytes=total, items=items, blocked=cat_block, note=self.note(ctx))
        return out

    def clean(self, ctx, keys, scan_items):
        """Delete the selected keys (all candidates when keys is None)."""
        cat_block = self.category_blocked(ctx)
        fresh = {c.key: c for c in self.candidates(ctx)}
        wanted = list(fresh) if keys is None else keys
        if cat_block:
            skipped = [result(self.target(k), "skipped", cat_block["reason"], cat_block["detail"]) for k in wanted]
            return skipped if self.itemized else self.merge(skipped)
        for root in self.roots(ctx):
            fsops.sweep_tombstones(root)
        results = []
        for key in wanted:
            target = self.target(key)
            known = scan_items.get(key, {})
            cand = fresh.get(key)
            if cand is None:
                results.append(result(target, "skipped", "not-a-candidate"))
                continue
            ib = self.item_blocked(ctx, cand)
            if ib:
                results.append(result(target, "skipped", ib["reason"], ib["detail"]))
                continue
            try:
                self.delete(ctx, cand, known.get("id"))
                results.append(result(target, "done", bytes_=known.get("bytes")))
            except fsops.Unsafe as exc:
                results.append(result(target, "skipped", exc.reason, exc.detail))
            except OSError as exc:
                results.append(result(target, "failed", "os-error", "%s: %s" % (cand.label, exc.strerror)))
        return results if self.itemized else self.merge(results)

    def merge(self, results):
        """One result for a category that is cleaned as a whole."""
        if not results:
            return [result(self.id, "done", detail="nothing to remove")]
        done = [r for r in results if r["status"] == "done"]
        failed = [r for r in results if r["status"] == "failed"]
        others = [r for r in results if r["status"] != "done"]
        status = "failed" if failed and not done else ("done" if done else "skipped")
        merged = result(self.id, status, others[0].get("reason") if others else None,
                        "; ".join(dict.fromkeys(r.get("detail", "") for r in others if r.get("detail"))))
        if done and others:
            merged["partial"] = True
        return [merged]

    def delete(self, ctx, cand, expect):
        fsops.delete_entry(cand.path, ctx.job, expect=expect, dry_run=ctx.dry_run)

    def target(self, key):
        return "%s:%s" % (self.id, key) if self.itemized else self.id


class DirChildren(Category):
    """Every entry inside one directory."""

    exclude = ()
    dirs_only = False
    keep_newest = 0
    name_filter = None

    def root(self, ctx):
        raise NotImplementedError

    def roots(self, ctx):
        return [self.root(ctx)]

    def available(self, ctx):
        st = fsops.lstat(self.root(ctx))
        return st is not None and stat.S_ISDIR(st.st_mode)

    def candidate_detail(self, ctx, name, st):
        return ""

    def candidates(self, ctx):
        root = self.root(ctx)
        children = []
        for name, st in fsops.list_children(root):
            if name in self.exclude:
                continue
            if self.dirs_only and not stat.S_ISDIR(st.st_mode):
                continue
            if self.name_filter and not self.name_filter(ctx, name):
                continue
            children.append((name, st))
        if self.keep_newest:
            children.sort(key=lambda c: c[1].st_mtime, reverse=True)
            children = children[self.keep_newest:]
        return [Candidate(name, os.path.join(root, name), detail=self.candidate_detail(ctx, name, st), st=st)
                for name, st in children]


def _match_component(pattern, name):
    return any(fnmatch.fnmatchcase(name, alt) for alt in pattern.split("|"))


class Allowlist(Category):
    """Specific subfolders, given as per-component glob patterns ("a|b" = alternatives)."""

    patterns = ()

    def base(self, ctx):
        raise NotImplementedError

    def available(self, ctx):
        st = fsops.lstat(self.base(ctx))
        return st is not None and stat.S_ISDIR(st.st_mode)

    def roots(self, ctx):
        found = set()
        for c in self.candidates(ctx):
            found.add(os.path.dirname(c.path))
        return sorted(found)

    def candidates(self, ctx):
        base = self.base(ctx)
        out = []
        for pattern in self.patterns:
            level = [(base, "")]
            for i, comp in enumerate(pattern):
                last = i == len(pattern) - 1
                nxt = []
                for abs_dir, rel in level:
                    for name, st in fsops.list_children(abs_dir):
                        if not _match_component(comp, name):
                            continue
                        if not stat.S_ISDIR(st.st_mode) and not last:
                            continue
                        nxt.append((os.path.join(abs_dir, name), (rel + "/" + name).lstrip("/")))
                level = nxt
            for abs_path, rel in level:
                out.append(Candidate(rel, abs_path, label=fsops.display_name(rel)))
        return out


# ---------------------------------------------------------------- developer

class YayBuilds(DirChildren):
    id = "yay-builds"
    title = "AUR build folders (yay)"
    description = "Sources and build files left after installing AUR packages. yay downloads them again on the next update."
    itemized = True
    dirs_only = True
    exclude = ("vcs.json", "completion.cache")
    app = "aur"
    in_use_check = True

    def root(self, ctx):
        return os.path.join(paths.cache_dir(), "yay")

    def category_blocked(self, ctx):
        if os.path.exists("/var/lib/pacman/db.lck"):
            return blocked("app-running", "pacman is busy (database locked)")
        return super().category_blocked(ctx)


def pnpm_store_root():
    return os.path.join(paths.data_dir(), "pnpm", "store")


def pnpm_current_store(ctx):
    if "pnpm-store" not in ctx.memo:
        name = ""
        r = ctx.run(["pnpm", "store", "path"], timeout=20)
        if r.returncode == 0 and r.stdout.strip():
            name = os.path.basename(r.stdout.strip().rstrip("/"))
        if not re.fullmatch(r"v\d+", name):
            versions = [n for n, _ in fsops.list_children(pnpm_store_root()) if re.fullmatch(r"v\d+", n)]
            name = max(versions, key=lambda v: int(v[1:])) if versions else ""
        ctx.memo["pnpm-store"] = name
    return ctx.memo["pnpm-store"]


def pnpm_referenced_stores(ctx):
    """{store version: [project dirs]} named by node_modules/.modules.yaml under the project roots or pnpm globals."""
    if "pnpm-refs" in ctx.memo:
        return ctx.memo["pnpm-refs"]
    refs = {}
    roots = [paths.expand(r) for r in ctx.cfg.get("projectRoots", [])]
    roots.append(os.path.join(paths.data_dir(), "pnpm", "global"))
    for root in roots:
        if not os.path.isdir(root):
            continue
        base_depth = root.rstrip("/").count("/")
        for dirpath, dirs, _files in os.walk(root, followlinks=False):
            if dirpath.count("/") - base_depth > 7:
                dirs[:] = []
                continue
            if "node_modules" in dirs:
                yaml = os.path.join(dirpath, "node_modules", ".modules.yaml")
                with contextlib.suppress(OSError):
                    with open(yaml, encoding="utf-8", errors="replace") as fh:
                        for line in fh:
                            m = re.match(r"""\s*"?storeDir"?:\s*['"]?(.+?)['"]?,?\s*$""", line)
                            if m:
                                refs.setdefault(os.path.basename(m.group(1).rstrip("/")), []).append(dirpath)
                                break
            dirs[:] = [d for d in dirs if d not in ("node_modules", ".git")]
    ctx.memo["pnpm-refs"] = refs
    return refs


class PnpmOldStores(DirChildren):
    id = "pnpm-old-stores"
    title = "Old pnpm stores"
    description = "Package stores left by older pnpm versions. No project points at them any more."
    itemized = True
    dirs_only = True
    app = "pnpm"

    def root(self, ctx):
        return pnpm_store_root()

    def name_filter(self, ctx, name):
        if not re.fullmatch(r"v\d+", name):
            return False
        current = pnpm_current_store(ctx)
        return bool(current) and name != current and name not in pnpm_referenced_stores(ctx)

    def note(self, ctx):
        current = pnpm_current_store(ctx)
        used = {v: dirs for v, dirs in pnpm_referenced_stores(ctx).items()
                if v != current and os.path.isdir(os.path.join(pnpm_store_root(), v))}
        if not used:
            return None
        count = len({d for dirs in used.values() for d in dirs})
        return "%s still used by %d project%s. Remove their node_modules in Projects first." % (
            ", ".join(sorted(used, key=lambda v: int(v[1:]))), count, "" if count == 1 else "s")


class PnpmPrune(Category):
    id = "pnpm-prune"
    title = "Unused packages in the pnpm store"
    description = "Runs `pnpm store prune`: removes packages no project links to. Size is only known afterwards."
    estimate_kind = "unknown"
    app = "pnpm"
    hidden_when_empty = False

    def available(self, ctx):
        return bool(pnpm_current_store(ctx)) and os.path.isdir(os.path.join(pnpm_store_root(), pnpm_current_store(ctx)))

    def note(self, ctx):
        return "Current store: %s" % pnpm_current_store(ctx)

    def scan(self, ctx):
        out = super().scan(ctx)
        out["items"] = []
        return out

    def candidates(self, ctx):
        return [Candidate("store", os.path.join(pnpm_store_root(), pnpm_current_store(ctx)), extra={"bytes": 0})]

    def clean(self, ctx, keys, scan_items):
        cat_block = self.category_blocked(ctx)
        if cat_block:
            return [result(self.id, "skipped", cat_block["reason"], cat_block["detail"])]
        if ctx.dry_run:
            return [result(self.id, "done", detail="dry run")]
        r = ctx.run(["pnpm", "store", "prune"], timeout=900)
        if r.returncode != 0:
            return [result(self.id, "failed", "tool-error", (r.stderr or r.stdout).strip()[-300:])]
        return [result(self.id, "done", detail=r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "")]


class PnpmCache(DirChildren):
    id = "pnpm-cache"
    title = "pnpm metadata cache"
    description = "Cached package metadata from the registry. pnpm fetches it again as needed."
    app = "pnpm"

    def root(self, ctx):
        return os.path.join(paths.cache_dir(), "pnpm")


class NpmCache(Category):
    id = "npm-cache"
    title = "npm cache"
    description = "Downloaded package tarballs (`npm cache clean --force` does the same)."
    app = "npm"

    def roots(self, ctx):
        return [os.path.join(paths.home(), ".npm")]

    def candidates(self, ctx):
        path = os.path.join(paths.home(), ".npm", "_cacache")
        return [Candidate("_cacache", path)] if fsops.lstat(path) else []


class Npx(DirChildren):
    id = "npx"
    title = "npx packages"
    description = "Packages that `npx` / `npm exec` downloaded to run once. Ones in use are kept."
    itemized = True
    dirs_only = True
    in_use_check = True

    def root(self, ctx):
        return os.path.join(paths.home(), ".npm", "_npx")

    def candidate_detail(self, ctx, name, st):
        data = paths.read_json(os.path.join(self.root(ctx), name, "package.json"), {})
        deps = data.get("dependencies") if isinstance(data, dict) else None
        if isinstance(deps, dict) and deps:
            return ", ".join("%s@%s" % (k, v) for k, v in list(deps.items())[:3])
        return ""

    def candidates(self, ctx):
        cands = super().candidates(ctx)
        for c in cands:
            if c.detail:
                c.label = c.detail
                c.detail = c.key
        return cands


class MiseTools(Category):
    id = "mise-tools"
    title = "Old mise tool versions"
    description = "Installed tool versions that no mise config asks for any more."
    itemized = True
    estimate_kind = "tool"

    _line = re.compile(r"^mise (\S+@\S+) is prunable: (.*)$")
    _remove = re.compile(r"^mise (\S+@\S+) \[dryrun\]\s+remove (.*)$")

    def available(self, ctx):
        return os.path.isdir(os.path.join(paths.data_dir(), "mise", "installs"))

    def _prunable(self, ctx):
        if "mise" not in ctx.memo:
            found = {}
            r = ctx.run(["mise", "prune", "--tools", "--dry-run"], timeout=60, env={"NO_COLOR": "1"})
            text = (r.stdout or "") + "\n" + (r.stderr or "")
            for line in text.splitlines():
                line = line.strip()
                m = self._line.match(line)
                if m:
                    found.setdefault(m.group(1), {"reason": m.group(2), "paths": []})
                    continue
                m = self._remove.match(line)
                if m and m.group(1) in found:
                    for p in m.group(2).split(", "):
                        p = paths.expand(p.strip())
                        if os.path.isabs(p) and p.startswith(paths.home() + "/"):
                            found[m.group(1)]["paths"].append(p)
            ctx.memo["mise"] = found
        return ctx.memo["mise"]

    def candidates(self, ctx):
        out = []
        prunable = self._prunable(ctx)
        sizes = fsops.du([p for info in prunable.values() for p in info["paths"]])
        for tool, info in sorted(prunable.items()):
            size = sum(sizes.get(p, 0) for p in info["paths"])
            install = info["paths"][0] if info["paths"] else paths.home()
            out.append(Candidate(tool, install, detail=info["reason"], extra={"bytes": size}))
        return out

    def item_blocked(self, ctx, cand):
        # mise checks running processes itself; paths are mise's own install dirs.
        if not re.fullmatch(r"[A-Za-z0-9._:/+-]+@[A-Za-z0-9._+-]+", cand.key):
            return blocked("bad-name", "Unexpected tool name")
        return None

    def delete(self, ctx, cand, expect):
        if ctx.dry_run:
            return
        r = ctx.run(["mise", "uninstall", cand.key], timeout=300, env={"MISE_YES": "1", "NO_COLOR": "1"})
        if r.returncode != 0:
            raise OSError(r.returncode, (r.stderr or r.stdout).strip()[-200:] or "mise uninstall failed")


class MiseCache(DirChildren):
    id = "mise-cache"
    title = "mise download cache"
    description = "Downloaded archives and metadata (`mise cache clear` does the same)."

    def root(self, ctx):
        return os.path.join(paths.cache_dir(), "mise")


class BunCache(DirChildren):
    id = "bun-cache"
    title = "bun package cache"
    description = "Packages bun downloaded (`bun pm cache rm` does the same). Hardlinked files free less."
    app = "bun"

    def root(self, ctx):
        return os.path.join(paths.cache_dir(), ".bun", "install", "cache")


class SmallDevCaches(Allowlist):
    id = "dev-misc"
    title = "Other developer caches"
    description = "pip, node-gyp, TypeScript, Go build, yarn, deno, Electron and debug-symbol caches."
    itemized = True
    patterns = (("pip|node-gyp|typescript|go-build|yarn|deno|electron|electron-builder|debuginfod_client|bun",),)
    in_use_check = True

    def base(self, ctx):
        return paths.cache_dir()


class Thumbnails(DirChildren):
    id = "thumbnails"
    title = "Thumbnails"
    description = "Image previews made by file managers. They are recreated when you open a folder."

    def root(self, ctx):
        return os.path.join(paths.cache_dir(), "thumbnails")


class CrashDumps(DirChildren):
    id = "crash-dumps"
    title = "Shell crash reports"
    description = "Crash logs from quickshell (the Omarchy shell). The newest one is kept for debugging."
    keep_newest = 1

    def root(self, ctx):
        return os.path.join(paths.cache_dir(), "quickshell", "crashes")


# ---------------------------------------------------------------- app caches

class BraveCache(Allowlist):
    id = "brave-cache"
    group = "app"
    title = "Brave cache"
    description = "Cached web pages and scripts. Site data, logins and tabs are not touched."
    risk = "app-closed"
    app = "brave"
    patterns = (("*", "Default|Profile *", "Cache|Code Cache|GPUCache"),)

    def base(self, ctx):
        return os.path.join(paths.cache_dir(), "BraveSoftware")


class JetBrainsCache(Allowlist):
    id = "jetbrains-cache"
    group = "app"
    title = "IntelliJ caches"
    description = "Indexes, caches and logs. Local History, settings and plugins are kept."
    risk = "app-closed"
    app = "intellij"
    patterns = (("*", "index|caches|log|jcef_cache"),)

    def base(self, ctx):
        return os.path.join(paths.cache_dir(), "JetBrains")


class VSCodeCache(Allowlist):
    id = "vscode-cache"
    group = "app"
    title = "VS Code cache"
    description = "Browser caches, compiled code and logs. Settings, extensions and backups are kept."
    risk = "app-closed"
    app = "vscode"
    patterns = (("Cache|Code Cache|CachedData|CachedExtensionVSIXs|GPUCache|DawnGraphiteCache|DawnWebGPUCache|logs",),)

    def base(self, ctx):
        return os.path.join(paths.config_dir(), "Code")


class ClaudeDesktopCache(Allowlist):
    id = "claude-desktop-cache"
    group = "app"
    title = "Claude Desktop cache"
    description = "Browser caches of the desktop app. Conversations and the Cowork VM are kept."
    risk = "app-closed"
    app = "claude-desktop"
    patterns = (("Cache|Code Cache|GPUCache|DawnGraphiteCache|DawnWebGPUCache",),)

    def base(self, ctx):
        return os.path.join(paths.config_dir(), "Claude")


# ---------------------------------------------------------------- tools

class DownloadedTools(Category):
    id = "downloaded-tools"
    group = "tools"
    title = "Downloaded tools"
    description = "Browsers and binaries that test and build tools download. They are fetched again on next use."
    risk = "redownload"
    itemized = True
    default_selected = False
    in_use_check = True

    simple = ("dotslash", "ffmpeg-static-nodejs", "mongodb-binaries", "winetricks", "puppeteer", "Cypress",
              "hyperframes/chrome")

    def roots(self, ctx):
        return [paths.cache_dir(), os.path.join(paths.cache_dir(), "ms-playwright"),
                os.path.join(paths.cache_dir(), "hyperframes")]

    def candidates(self, ctx):
        cache = paths.cache_dir()
        out = []
        for rel in self.simple:
            p = os.path.join(cache, rel)
            st = fsops.lstat(p)
            if st and stat.S_ISDIR(st.st_mode):
                out.append(Candidate(rel, p, st=st))
        # Playwright: offer every browser revision except the newest of each kind.
        pw = os.path.join(cache, "ms-playwright")
        newest = {}
        revs = []
        for name, st in fsops.list_children(pw):
            m = re.fullmatch(r"(.+)-(\d+)", name)
            if m and stat.S_ISDIR(st.st_mode):
                revs.append((m.group(1), int(m.group(2)), name, st))
                newest[m.group(1)] = max(newest.get(m.group(1), 0), int(m.group(2)))
        for kind, rev, name, st in revs:
            if rev < newest[kind]:
                out.append(Candidate("ms-playwright/" + name, os.path.join(pw, name), detail="older Playwright browser", st=st))
        return out


# ---------------------------------------------------------------- review

def trash_dir():
    return os.path.join(paths.data_dir(), "Trash")


class Trash(Category):
    id = "trash"
    group = "review"
    title = "Trash"
    description = "Files you already moved to the Trash. Removing them here is permanent."
    risk = "data"
    itemized = True
    default_selected = False

    def roots(self, ctx):
        return [os.path.join(trash_dir(), "files")]

    def candidates(self, ctx):
        files = os.path.join(trash_dir(), "files")
        info_dir = os.path.join(trash_dir(), "info")
        out = []
        for name, st in fsops.list_children(files):
            detail = ""
            with contextlib.suppress(OSError):
                with open(os.path.join(info_dir, name + ".trashinfo"), encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if line.startswith("Path="):
                            from urllib.parse import unquote
                            detail = paths.contract(unquote(line[5:].strip()))
                        elif line.startswith("DeletionDate="):
                            detail = (detail + " · trashed " + line.split("=", 1)[1].strip()[:10]).strip(" ·")
            out.append(Candidate(name, os.path.join(files, name), detail=detail, st=st))
        return out

    def delete(self, ctx, cand, expect):
        fsops.delete_entry(cand.path, ctx.job, expect=expect, dry_run=ctx.dry_run)
        if not ctx.dry_run:
            info = os.path.join(trash_dir(), "info", cand.key + ".trashinfo")
            with contextlib.suppress(OSError, fsops.Unsafe):
                fsops.delete_entry(info, ctx.job)


class DownloadsOld(Category):
    id = "downloads-old"
    group = "review"
    title = "Old downloads"
    description = "Files in Downloads you have not touched for a while. They go to the Trash, not straight away."
    risk = "data"
    frees_when = "after-empty-trash"
    itemized = True
    default_selected = False
    in_use_check = True

    def available(self, ctx):
        return os.path.isdir(paths.download_dir())

    def note(self, ctx):
        return "Older than %d days" % ctx.cfg["downloadsDays"]

    def roots(self, ctx):
        return []

    def candidates(self, ctx):
        root = paths.download_dir()
        cutoff = time.time() - ctx.cfg["downloadsDays"] * 86400
        out = []
        for name, st in fsops.list_children(root):
            if name.endswith((".part", ".crdownload", ".download")) or name.startswith("."):
                continue
            p = os.path.join(root, name)
            newest = fsops.newest_mtime(p)
            if newest and newest < cutoff:
                days = int((time.time() - newest) // 86400)
                out.append(Candidate(name, p, detail="untouched %d days" % days, st=st))
        return out

    def delete(self, ctx, cand, expect):
        st = fsops.lstat(cand.path)
        if st is None:
            raise fsops.Unsafe("gone")
        if expect and fsops.identity(st) != list(expect):
            raise fsops.Unsafe("changed-since-scan")
        if ctx.dry_run:
            return
        r = ctx.run(["gio", "trash", "--", cand.path], timeout=120)
        if r.returncode != 0:
            raise OSError(r.returncode, (r.stderr or "gio trash failed").strip())


def all_categories():
    from . import docker, rootcats
    return [
        YayBuilds(), PnpmOldStores(), PnpmPrune(), PnpmCache(), NpmCache(), Npx(), MiseTools(), MiseCache(),
        BunCache(), SmallDevCaches(), Thumbnails(), CrashDumps(),
        BraveCache(), JetBrainsCache(), VSCodeCache(), ClaudeDesktopCache(),
        DownloadedTools(),
        rootcats.PacmanCache(), rootcats.Journal(), rootcats.Coredumps(), rootcats.Snapshots(),
        rootcats.Hibernation(),
        docker.BuildCache(), docker.DanglingImages(), docker.UnusedImages(), docker.DanglingVolumes(),
        DownloadsOld(), Trash(),
    ]


def by_id():
    return {c.id: c for c in all_categories()}
