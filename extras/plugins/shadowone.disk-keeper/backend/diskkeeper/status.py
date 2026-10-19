"""Free space, warning level and the low-space notification."""

import contextlib
import fcntl
import os
import re
import subprocess
import time

from . import paths

GIB = 1024 ** 3
RANK = {"ok": 0, "warn": 1, "critical": 2}
RENOTIFY_CRITICAL_S = 6 * 3600
PANEL_ID = "shadowone.disk-keeper"


def statvfs(path="/"):
    st = os.statvfs(path)
    return st.f_blocks * st.f_frsize, st.f_bavail * st.f_frsize


def fstype(path="/"):
    found = ""
    try:
        with open("/proc/self/mounts", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 3 and parts[1] == path:
                    found = parts[2]
    except OSError:
        pass
    return found


def parse_btrfs_usage(text):
    out = {}
    m = re.search(r"Device unallocated:\s+(\d+)", text)
    if m:
        out["unallocatedBytes"] = int(m.group(1))
    m = re.search(r"Free \(estimated\):\s+(\d+)\s+\(min: (\d+)\)", text)
    if m:
        out["freeEstimatedBytes"] = int(m.group(1))
        out["freeMinBytes"] = int(m.group(2))
    m = re.search(r"^Metadata,\S+:\s+Size:(\d+),\s+Used:(\d+)", text, re.M)
    if m:
        out["metadataTotalBytes"] = int(m.group(1))
        out["metadataUsedBytes"] = int(m.group(2))
    return out


def btrfs_usage(path="/"):
    try:
        r = subprocess.run(["btrfs", "filesystem", "usage", "-b", path], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return parse_btrfs_usage(r.stdout) if r.returncode == 0 else None


def compute_level(free, total, warn_gb, critical_gb, previous="ok", btrfs=None):
    """(level, reason). Recovering to a better level needs a margin so it does not flap."""
    warn = warn_gb * GIB
    critical = critical_gb * GIB
    margin = max(GIB, 0.02 * total)
    if free < critical:
        level = "critical"
    elif free < warn:
        level = "warn"
    else:
        level = "ok"
    if RANK.get(previous, 0) > RANK[level]:
        threshold = critical if previous == "critical" else warn
        if free < threshold + margin:
            level = previous
    reason = "free"
    if btrfs and level == "ok":
        unalloc = btrfs.get("unallocatedBytes")
        mt, mu = btrfs.get("metadataTotalBytes"), btrfs.get("metadataUsedBytes")
        if unalloc is not None and unalloc < 2 * GIB and mt and mu and mu / mt > 0.85:
            level, reason = "warn", "btrfs-metadata"
    return level, reason


def human(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%.0f %s" if unit in ("B", "KB") else "%.1f %s") % (n, unit)
        n /= 1024
    return "%d B" % n


def send_notification(level, free, previous_id):
    urgency = "critical" if level == "critical" else "normal"
    headline = "Disk almost full" if level == "critical" else "Disk space is getting low"
    body = "%s free on /. Click the disk icon in the bar to clean up." % human(free)
    argv = ["omarchy-notification-send", "--app-name", "Disk Keeper", "-u", urgency, "-g", "\U000f02ca", "-p"]
    if previous_id:
        argv += ["-r", str(previous_id)]
    argv += [headline, body, "--exec", "omarchy-shell", "shell", "toggle", PANEL_ID]
    try:
        r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    try:
        return int(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return 0 if r.returncode == 0 else None


def decide_notification(level, state, now):
    """(send?, new_state) given the remembered notification state."""
    notified = state.get("notifiedLevel", "ok")
    at = state.get("notifiedAt", 0)
    new = dict(state)
    send = False
    if RANK[level] > RANK.get(notified, 0):
        send = True
    elif level == "critical" and now - at > RENOTIFY_CRITICAL_S:
        send = True
    elif RANK[level] < RANK.get(notified, 0):
        new["notifiedLevel"] = level
    if send:
        new["notifiedLevel"] = level
        new["notifiedAt"] = now
    return send, new


def status(warn_gb, critical_gb, notify=False):
    # One bar per monitor means one poller per monitor; the lock makes the
    # read-decide-write of notify.json atomic so only one of them notifies.
    with notify_lock():
        return _status(warn_gb, critical_gb, notify)


@contextlib.contextmanager
def notify_lock():
    directory = paths.runtime_dir()
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd = os.open(os.path.join(directory, "notify.lock"), os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def _status(warn_gb, critical_gb, notify):
    total, free = statvfs("/")
    fs = fstype("/")
    btrfs = btrfs_usage("/") if fs == "btrfs" else None
    state_path = paths.state_file("notify.json")
    state = paths.read_json(state_path, {}) or {}
    level, reason = compute_level(free, total, warn_gb, critical_gb, state.get("level", "ok"), btrfs)
    now = int(time.time())
    notification = {"sent": False}
    new_state = dict(state)
    new_state["level"] = level
    if notify:
        send, new_state = decide_notification(level, new_state, now)
        new_state["level"] = level
        if send:
            nid = send_notification(level, free, state.get("id"))
            notification = {"sent": nid is not None, "id": nid}
            if nid:
                new_state["id"] = nid
    if new_state != state:
        paths.atomic_write_json(state_path, new_state)
    scan = paths.read_json(paths.state_file("scan.json"), {}) or {}
    return {
        "kind": "status", "ts": now, "mount": "/", "fsType": fs, "totalBytes": total, "freeBytes": free,
        "usedBytes": total - free, "level": level, "levelReason": reason,
        "warnBytes": int(warn_gb * GIB), "criticalBytes": int(critical_gb * GIB), "btrfs": btrfs,
        "notification": notification,
        "lastScan": {"ts": scan.get("ts", 0), "reclaimableBytes": scan.get("reclaimableBytes", 0)} if scan else None,
    }
