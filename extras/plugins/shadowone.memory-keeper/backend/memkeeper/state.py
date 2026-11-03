"""Where things live: XDG dirs, config, state files, the one-job lock, and the
outside world (clocks, signals, programs) behind one object tests can replace.

Nothing here may write inside the plugin directory. The Omarchy shell watches
~/.config/omarchy/plugins recursively and reloads every plugin on any change.
"""

import contextlib
import fcntl
import json
import os
import signal
import subprocess
import time

UUID_LEN = 36

# key: (default, min, max). The panel edits these through `memkeeper config set`.
NUMBERS = {
    "idleHours": (12, 1, 168),
    "warnIdleHours": (3, 1, 168),
    "criticalIdleHours": (1, 1, 168),
    "warnAvailablePercent": (20, 2, 60),
    "criticalAvailablePercent": (10, 1, 50),
    "warnSwapPercent": (70, 10, 95),
    "criticalSwapPercent": (85, 10, 99),
    "criticalPsiFull": (20, 1, 90),
    "reclaimPsiSome": (5, 1, 90),
}


def home():
    return os.environ.get("HOME") or os.path.expanduser("~")


def _xdg(name, fallback):
    return os.environ.get(name) or os.path.join(home(), fallback)


def state_dir():
    path = os.path.join(_xdg("XDG_STATE_HOME", ".local/state"), "memory-keeper")
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


def state_file(name):
    return os.path.join(state_dir(), name)


def config_path():
    return os.path.join(_xdg("XDG_CONFIG_HOME", ".config"), "memory-keeper", "config.json")


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    """Atomic, so the panel and the timer never read half a file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp-%d" % (path, os.getpid())
    try:
        with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def append_history(entry):
    with open(state_file("history.jsonl"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry, ensure_ascii=False) + "\n")


def read_history():
    out = []
    try:
        with open(state_file("history.jsonl"), encoding="utf-8") as fh:
            for line in fh:
                with contextlib.suppress(ValueError):
                    out.append(json.loads(line))
    except OSError:
        pass
    return out


def clamp_config(raw):
    raw = raw if isinstance(raw, dict) else {}
    cfg = {"auto": raw.get("auto") is not False}
    for key, (default, low, high) in NUMBERS.items():
        value = raw.get(key, default)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            value = default
        cfg[key] = max(low, min(high, value))
    # A worse level must never wait longer or trigger later than a milder one.
    cfg["warnIdleHours"] = min(cfg["warnIdleHours"], cfg["idleHours"])
    cfg["criticalIdleHours"] = min(cfg["criticalIdleHours"], cfg["warnIdleHours"])
    cfg["criticalAvailablePercent"] = min(cfg["criticalAvailablePercent"], cfg["warnAvailablePercent"])
    cfg["criticalSwapPercent"] = max(cfg["criticalSwapPercent"], cfg["warnSwapPercent"])
    keep = raw.get("keep")
    cfg["keep"] = [k for k in keep if isinstance(k, str) and len(k) == UUID_LEN] if isinstance(keep, list) else []
    return cfg


def load_config():
    return clamp_config(read_json(config_path(), {}))


def save_config(cfg):
    write_json(config_path(), clamp_config(cfg))


@contextlib.contextmanager
def op_lock(wait_seconds=15):
    """One tick or stop at a time. Yields False when another one holds it."""
    run_dir = os.environ.get("XDG_RUNTIME_DIR") or state_dir()
    path = os.path.join(run_dir, "memory-keeper.lock")
    with open(path, "w") as fh:
        deadline = time.monotonic() + wait_seconds
        while True:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    yield False
                    return
                time.sleep(0.2)
        yield True


class Env:
    """The outside world. Tests replace the fields they care about."""

    proc = "/proc"

    def __init__(self):
        self.uid = os.getuid()
        self.app_slice = "/sys/fs/cgroup/user.slice/user-%d.slice/user@%d.service/app.slice" % (self.uid, self.uid)
        self.view_file = os.path.join(_xdg("XDG_CONFIG_HOME", ".config"), "herdr-app", "view.json")
        self.sessions_dir = os.path.join(home(), ".claude", "sessions")

    def wall(self):
        return time.time()

    def mono(self):
        # Stops while the laptop sleeps, unlike the wall clock and CLOCK_BOOTTIME.
        return time.clock_gettime(time.CLOCK_MONOTONIC)

    def uptime(self):
        with open(os.path.join(self.proc, "uptime")) as fh:
            return float(fh.read().split()[0])

    def ticks_per_second(self):
        return os.sysconf("SC_CLK_TCK")

    def sleep(self, seconds):
        time.sleep(seconds)

    def terminate(self, pid):
        os.kill(pid, signal.SIGTERM)

    def run(self, argv, timeout=8):
        """(exit code, stdout). A missing or hanging program is just a failure.

        HC_* is dropped: run from inside a Herdr terminal, `hc send` would put a
        <hc from="..."> tag in front of the text it types.
        """
        clean = {k: v for k, v in os.environ.items() if not k.startswith("HC_")}
        try:
            r = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               encoding="utf-8", errors="replace", timeout=timeout, check=False, env=clean)
        except (OSError, subprocess.SubprocessError):
            return 1, ""
        return r.returncode, r.stdout
