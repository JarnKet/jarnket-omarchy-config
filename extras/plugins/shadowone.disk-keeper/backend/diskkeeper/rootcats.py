"""System categories. Sizes are read without root; cleaning goes through the root helper.

Each category turns into one token for diskkeeper-root; the CLI batches all
tokens of a job into a single pkexec call, so one fingerprint covers them.
"""

import os
import re
import stat
import time

from . import registry

COREDUMP_DIR = "/var/lib/systemd/coredump"

_UNITS = {"B": 1, "K": 1024, "KIB": 1024, "M": 1024 ** 2, "MIB": 1024 ** 2,
          "G": 1024 ** 3, "GIB": 1024 ** 3, "T": 1024 ** 4, "TIB": 1024 ** 4}


def parse_binary_size(text):
    """'2.1 GiB', '466.2M', '7.55 MiB', '200M' to bytes."""
    m = re.match(r"\s*([0-9.]+)\s*([A-Za-z]*)", text or "")
    if not m:
        return 0
    unit = (m.group(2) or "B").upper()
    try:
        return int(float(m.group(1)) * _UNITS.get(unit, 1))
    except ValueError:
        return 0


class RootCategory(registry.Category):
    group = "system"
    privilege = "root"
    estimate_kind = "tool"

    def token(self, ctx, keys):
        raise NotImplementedError

    def estimate(self, ctx):
        return 0, []

    def scan(self, ctx):
        out = self.describe()
        if not self.available(ctx):
            out.update(available=False, bytes=0, items=[], blocked=None, note=None)
            return out
        size, items = self.estimate(ctx)
        out.update(available=True, bytes=size, items=items, blocked=None, note=self.note(ctx),
                   rootToken=self.token(ctx, None))
        return out

    def clean(self, ctx, keys, scan_items):
        raise RuntimeError("root categories are cleaned by the CLI through the helper")


class PacmanCache(RootCategory):
    id = "pacman-cache"
    title = "Old package versions"
    description = "Package files pacman keeps for downgrades. The newest version of each package stays."

    def available(self, ctx):
        return os.path.isdir("/var/cache/pacman/pkg")

    def note(self, ctx):
        return "Keeps %d version%s per package" % (ctx.cfg["pacmanKeep"], "" if ctx.cfg["pacmanKeep"] == 1 else "s")

    def token(self, ctx, keys):
        return "pacman-cache:keep=%d" % ctx.cfg["pacmanKeep"]

    def category_blocked(self, ctx):
        if os.path.exists("/var/lib/pacman/db.lck"):
            return registry.blocked("app-running", "pacman is busy (database locked)")
        return None

    def estimate(self, ctx):
        total = 0
        for args in (["-d", "-k%d" % ctx.cfg["pacmanKeep"]], ["-d", "-u", "-k0"]):
            r = ctx.run(["paccache"] + args, timeout=60, env={"LC_ALL": "C"})
            m = re.search(r"disk space saved:\s*([0-9.]+\s*\w+)", r.stdout + r.stderr)
            if m:
                total += parse_binary_size(m.group(1))
        return total, []

    def scan(self, ctx):
        out = super().scan(ctx)
        out["blocked"] = self.category_blocked(ctx)
        return out


class Journal(RootCategory):
    id = "journal"
    title = "System journal"
    description = "Old system logs beyond the size limit. Recent logs stay readable with journalctl."

    def note(self, ctx):
        return "Shrinks logs to %s" % ctx.cfg["journalMax"]

    def token(self, ctx, keys):
        return "journal:max=%s" % ctx.cfg["journalMax"]

    def estimate(self, ctx):
        r = ctx.run(["journalctl", "--disk-usage"], timeout=30, env={"LC_ALL": "C"})
        m = re.search(r"take up\s+([0-9.]+\s*\w+)", r.stdout + r.stderr)
        used = parse_binary_size(m.group(1)) if m else 0
        return max(0, used - parse_binary_size(ctx.cfg["journalMax"])), []


class Coredumps(RootCategory):
    id = "coredumps"
    title = "Crash dumps (system)"
    description = "Memory dumps of crashed programs, used to debug crashes. systemd removes them after 2 weeks anyway."
    default_selected = False
    frees_when = "after-snapshots"

    def available(self, ctx):
        return os.path.isdir(COREDUMP_DIR)

    def note(self, ctx):
        age = ctx.cfg["coredumpAgeDays"]
        return "Older than %d days" % age if age else "All of them"

    def token(self, ctx, keys):
        return "coredumps:age=%dd" % ctx.cfg["coredumpAgeDays"]

    def estimate(self, ctx):
        cutoff = time.time() - ctx.cfg["coredumpAgeDays"] * 86400
        total = 0
        items = []
        try:
            entries = list(os.scandir(COREDUMP_DIR))
        except OSError:
            return 0, []
        for e in entries:
            if not e.name.startswith("core.") or e.name.startswith(".#"):
                continue
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            if not stat.S_ISREG(st.st_mode) or st.st_mtime > cutoff:
                continue
            size = st.st_blocks * 512
            total += size
            parts = e.name.split(".")
            prog = parts[1] if len(parts) > 1 else e.name
            items.append({"key": e.name, "label": prog, "detail": time.strftime("%Y-%m-%d", time.localtime(st.st_mtime)),
                          "bytes": size, "mtime": int(st.st_mtime), "id": None, "actionable": False,
                          "blocked": None, "selected": False})
        items.sort(key=lambda i: -i["bytes"])
        return total, items


class Snapshots(RootCategory):
    id = "snapshots"
    title = "System snapshots"
    description = "Snapper snapshots of the system. Deleting old ones returns space held by deleted files. The newest is always kept."
    itemized = True
    default_selected = False
    estimate_kind = "unknown"
    frees_when = "async"
    hidden_when_empty = False

    def available(self, ctx):
        return os.path.exists("/etc/snapper/configs/root")

    def note(self, ctx):
        return "Listing needs your fingerprint"

    def token(self, ctx, keys):
        if not keys:
            return None
        return "snapshots-delete:ids=" + ",".join(keys)
