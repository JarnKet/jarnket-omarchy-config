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


# Hibernation. Linux writes the image into the same swapfile every time and
# swapon clears it after resume, so images never pile up. What can go stale
# is a whole setup: a swapfile nobody switches on, or resume settings left in
# the boot entry after the swapfile is gone.
PROC_SWAPS = "/proc/swaps"
FSTAB = "/etc/fstab"
SWAPFILES = {"swapfile": "/swap/swapfile", "root-swapfile": "/swapfile"}
RESUME_CONF = "/etc/limine-entry-tool.d/resume.conf"
RESUME_HOOK = "/etc/mkinitcpio.conf.d/omarchy_resume.conf"
RUNNING_RESUME_OFFSET = "/sys/power/resume_offset"
RESUME_FIX = ("sudo rm %s %s && omarchy-hibernation-setup" % (RESUME_CONF, RESUME_HOOK))


def active_swaps(path=None):
    """Swap paths the kernel uses now. /proc/swaps escapes spaces as \\040."""
    out = []
    try:
        with open(path or PROC_SWAPS, encoding="utf-8", errors="replace") as fh:
            next(fh, None)
            for line in fh:
                fields = line.split()
                if fields:
                    out.append(fields[0].replace("\\040", " "))
    except OSError:
        pass
    return out


def fstab_swaps(path=None):
    """First fields of the swap lines in fstab."""
    out = []
    try:
        with open(path or FSTAB, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                fields = line.split("#", 1)[0].split()
                if len(fields) >= 3 and fields[2] == "swap":
                    out.append(fields[0].replace("\\040", " "))
    except OSError:
        pass
    return out


def resume_offset(path):
    """resume_offset=N from a boot drop-in, or the bare number in /sys/power/resume_offset."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return None
    m = re.search(r"resume_offset=([0-9]+)", text) or re.fullmatch(r"\s*([0-9]+)\s*", text)
    return int(m.group(1)) if m else None


def hibernate_delay(ctx):
    r = ctx.run(["systemd-analyze", "cat-config", "systemd/sleep.conf"], timeout=15, env={"LC_ALL": "C"})
    found = re.findall(r"^HibernateDelaySec=(\S+)", r.stdout, re.M)
    return found[-1] if found else None


class Hibernation(RootCategory):
    id = "hibernation"
    title = "Hibernation"
    description = ("The swapfile that holds memory while the laptop hibernates. Each hibernate reuses it, so old images "
                   "never pile up; only leftovers of an earlier setup are offered.")
    itemized = True
    estimate_kind = "du"

    def state(self, ctx):
        if "hibernation" in ctx.memo:
            return ctx.memo["hibernation"]
        active = active_swaps()
        fstab = fstab_swaps()
        files = {}
        for key, path in SWAPFILES.items():
            try:
                st = os.lstat(path)
            except OSError:
                continue
            if stat.S_ISREG(st.st_mode):
                files[key] = (path, st)
        resume = [p for p in (RESUME_CONF, RESUME_HOOK) if os.path.lexists(p)]
        disk_swap = [p for p in active + fstab if not p.startswith("/dev/zram")]
        st = {"active": active, "fstab": fstab, "files": files, "resume": resume, "diskSwap": disk_swap,
              "on": bool(resume) and any(path in active for path, _ in files.values()),
              "delay": hibernate_delay(ctx) if resume else None}
        ctx.memo["hibernation"] = st
        return st

    def available(self, ctx):
        s = self.state(ctx)
        return bool(s["files"] or s["resume"])

    def note(self, ctx):
        s = self.state(ctx)
        if s["on"]:
            return "On: closing the lid sleeps, then hibernates" + (" after %s" % s["delay"] if s["delay"] else "")
        if not s["diskSwap"]:
            return "Off. These are left over from an earlier setup."
        return None

    def estimate(self, ctx):
        s = self.state(ctx)
        items = []

        def add(key, label, detail, size=0, blocked=None, mtime=0):
            items.append({"key": key, "label": label, "detail": detail, "bytes": size, "mtime": mtime, "id": None,
                          "actionable": blocked is None, "blocked": blocked, "selected": blocked is None})

        for key, (path, st) in s["files"].items():
            size = st.st_blocks * 512
            if path in s["active"]:
                why = "Needed to hibernate. To turn hibernation off: omarchy-hibernation-remove" if s["resume"] \
                    else "Used as swap only; there are no resume settings, so nothing hibernates into it"
                add(key, "Hibernation swapfile", path, size, registry.blocked("in-use", "%s · %s" % (path, why)),
                    int(st.st_mtime))
            elif path in s["fstab"]:
                add(key, "Swapfile switched off", path, size,
                    registry.blocked("inactive", "%s is in /etc/fstab but not switched on: sudo swapon -a" % path),
                    int(st.st_mtime))
            else:
                add(key, "Unused swapfile", "%s · not in /etc/fstab and not switched on" % path, size,
                    mtime=int(st.st_mtime))

        if s["resume"] and not s["diskSwap"]:
            add("resume", "Old resume settings",
                "The boot entry still looks for a hibernation image. Removing them rebuilds the boot image (about a minute)")
        elif s["on"]:
            used = [(p, st) for p, st in s["files"].values() if p in s["active"]]
            conf_mtime = os.lstat(RESUME_CONF).st_mtime if os.path.exists(RESUME_CONF) else None
            # The swapfile's ctime is when it was made: hibernation and swapping
            # write around the VFS. Resume settings older than it point elsewhere.
            if conf_mtime is not None and any(st.st_ctime > conf_mtime + 5 for _, st in used):
                add("resume-stale", "Resume settings out of date", "",
                    blocked=registry.blocked("stale", "Older than the swapfile, so a hibernated session would not come "
                                                      "back. Fix: " + RESUME_FIX))
            else:
                configured = resume_offset(RESUME_CONF)
                running = resume_offset(RUNNING_RESUME_OFFSET)
                if configured is not None and configured != running:
                    add("reboot", "Restart needed", "",
                        blocked=registry.blocked("reboot", "Resume settings changed since this boot. Restart before "
                                                           "relying on hibernation"))
        return sum(i["bytes"] for i in items if i["actionable"]), items

    def token(self, ctx, keys):
        if keys is None:
            keys = [i["key"] for i in self.estimate(ctx)[1] if i["actionable"]]
        picked = [k for k in ("swapfile", "root-swapfile", "resume") if k in set(keys)]
        return "hibernation:remove=" + ",".join(picked) if picked else None
