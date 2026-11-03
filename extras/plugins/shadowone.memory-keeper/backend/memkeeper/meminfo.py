"""How much memory is left, and how worried to be about it."""

import errno
import os

LEVELS = ("ok", "warn", "critical")


def read(proc="/proc"):
    fields = {}
    with open(os.path.join(proc, "meminfo")) as fh:
        for line in fh:
            name, _, rest = line.partition(":")
            parts = rest.split()
            if parts and parts[0].isdigit():
                fields[name] = int(parts[0]) * 1024
    mem = {
        "totalBytes": fields.get("MemTotal", 0),
        "availableBytes": fields.get("MemAvailable", 0),
        "freeBytes": fields.get("MemFree", 0),
        "cachedBytes": fields.get("Cached", 0),
        "swapTotalBytes": fields.get("SwapTotal", 0),
        "swapUsedBytes": max(0, fields.get("SwapTotal", 0) - fields.get("SwapFree", 0)),
        "psiSome": 0.0,
        "psiFull": 0.0,
    }
    try:
        with open(os.path.join(proc, "pressure", "memory")) as fh:
            for line in fh:
                kind, _, rest = line.partition(" ")
                for item in rest.split():
                    if item.startswith("avg60=") and kind in ("some", "full"):
                        mem["psi" + kind.capitalize()] = float(item[6:])
    except (OSError, ValueError):
        pass
    return mem


def percent(part, whole):
    return part * 100.0 / whole if whole > 0 else 0.0


def level(mem, cfg):
    """(level, reasons). Any one reason is enough."""
    available = percent(mem["availableBytes"], mem["totalBytes"])
    swap = percent(mem["swapUsedBytes"], mem["swapTotalBytes"])
    critical, warn = [], []
    if available < cfg["criticalAvailablePercent"]:
        critical.append("low-available")
    elif available < cfg["warnAvailablePercent"]:
        warn.append("low-available")
    if swap > cfg["criticalSwapPercent"]:
        critical.append("high-swap")
    elif swap > cfg["warnSwapPercent"]:
        warn.append("high-swap")
    if mem["psiFull"] > cfg["criticalPsiFull"]:
        critical.append("stalling")
    if critical:
        return "critical", critical
    if warn:
        return "warn", warn
    return "ok", []


def idle_limit_seconds(lvl, cfg):
    key = {"ok": "idleHours", "warn": "warnIdleHours", "critical": "criticalIdleHours"}[lvl]
    return cfg[key] * 3600


def should_reclaim(lvl, mem, cfg):
    """Cold cache only costs a re-read later, but it is not free either: only
    when memory is actually tight, never just because the number looks big."""
    return lvl == "critical" or (lvl == "warn" and mem["psiSome"] >= cfg["reclaimPsiSome"])


def inactive_file_bytes(app_slice):
    try:
        with open(os.path.join(app_slice, "memory.stat")) as fh:
            for line in fh:
                if line.startswith("inactive_file "):
                    return int(line.split()[1])
    except (OSError, ValueError):
        pass
    return 0


def reclaim(app_slice, max_bytes, chunk=256 * 1024 * 1024):
    """Ask the kernel to drop cold file cache of the user's apps.

    swappiness=0 keeps it from pushing app memory to swap to reach the target.
    At most half the cold cache goes, in small steps so one write stays short.
    The kernel answers EAGAIN when it could not reclaim the whole step; there is
    no retry, nothing more is cold enough. Returns (bytes asked for, error).
    """
    want = min(max_bytes, inactive_file_bytes(app_slice) // 2)
    done = 0
    try:
        fd = os.open(os.path.join(app_slice, "memory.reclaim"), os.O_WRONLY)
    except OSError as e:
        return 0, e.strerror or "cannot open memory.reclaim"
    try:
        while done < want:
            step = min(chunk, want - done)
            try:
                os.write(fd, ("%d swappiness=0" % step).encode())
            except OSError as e:
                if e.errno == errno.EAGAIN:
                    break
                return done, e.strerror or "memory.reclaim failed"
            done += step
    finally:
        os.close(fd)
    return done, None
