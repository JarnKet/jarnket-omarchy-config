"""Where things live: XDG dirs, config, state files, the one-job lock.

Nothing here may write inside the plugin directory. The Omarchy shell
watches ~/.config/omarchy/plugins recursively and reloads every plugin
on any change there, which would kill a running clean job.
"""

import contextlib
import fcntl
import json
import os
import tempfile

DEFAULT_CONFIG = {
    # Paths never offered for cleanup and refused by Explore's "Move to Trash".
    "keep": [
        "~/.config/Claude/vm_bundles",
        "~/.config/Claude/claude-code",
        "~/.config/Claude/claude-code-vm",
        "~/.config/Claude/claude-code-sessions",
    ],
    "projectRoots": ["~/Projects", "~/Work"],
    "projectIdleDays": 14,
    "downloadsDays": 30,
    "journalMax": "200M",
    "pacmanKeep": 1,
    "coredumpAgeDays": 7,
}

JOURNAL_CHOICES = ("100M", "200M", "500M")
COREDUMP_AGE_CHOICES = (0, 3, 7, 14)


class Busy(Exception):
    """Another clean job holds the lock."""


def home():
    return os.environ.get("HOME") or os.path.expanduser("~")


def _xdg(name, default_rel):
    value = os.environ.get(name, "")
    return value if os.path.isabs(value) else os.path.join(home(), default_rel)


def cache_dir():
    return _xdg("XDG_CACHE_HOME", ".cache")


def config_dir():
    return _xdg("XDG_CONFIG_HOME", ".config")


def data_dir():
    return _xdg("XDG_DATA_HOME", ".local/share")


def state_dir():
    return os.path.join(_xdg("XDG_STATE_HOME", ".local/state"), "diskkeeper")


def runtime_dir():
    base = os.environ.get("XDG_RUNTIME_DIR", "")
    if not os.path.isabs(base):
        base = os.path.join(tempfile.gettempdir(), "diskkeeper-%d" % os.getuid())
    return os.path.join(base, "diskkeeper")


def config_path():
    return os.path.join(config_dir(), "diskkeeper", "config.json")


def state_file(name):
    return os.path.join(state_dir(), name)


def jobs_dir():
    return os.path.join(state_dir(), "jobs")


def expand(path):
    """Expand a leading ~ against $HOME (not the passwd entry, so tests can fake HOME)."""
    if path == "~":
        return home()
    if path.startswith("~/"):
        return os.path.join(home(), path[2:])
    return path


def contract(path):
    h = home().rstrip("/")
    if path == h:
        return "~"
    if path.startswith(h + "/"):
        return "~/" + path[len(h) + 1:]
    return path


def download_dir():
    """XDG_DOWNLOAD_DIR from user-dirs.dirs, falling back to ~/Downloads."""
    try:
        with open(os.path.join(config_dir(), "user-dirs.dirs"), encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("XDG_DOWNLOAD_DIR="):
                    value = line.split("=", 1)[1].strip().strip('"')
                    value = value.replace("$HOME", home())
                    if os.path.isabs(value) and value.rstrip("/") != home().rstrip("/"):
                        return value
    except OSError:
        pass
    return os.path.join(home(), "Downloads")


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def atomic_write_json(path, data):
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=1)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def append_jsonl(path, record):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def _clamp_choice(value, choices, fallback):
    return value if value in choices else fallback


def _clamp_int(value, low, high, fallback):
    if isinstance(value, bool) or not isinstance(value, int):
        return fallback
    return max(low, min(high, value))


def load_config():
    raw = read_json(config_path(), {})
    if not isinstance(raw, dict):
        raw = {}
    cfg = dict(DEFAULT_CONFIG)
    keep = raw.get("keep")
    if isinstance(keep, list):
        cfg["keep"] = [k for k in keep if isinstance(k, str) and k.strip()]
    roots = raw.get("projectRoots")
    if isinstance(roots, list):
        cfg["projectRoots"] = [r for r in roots if isinstance(r, str) and r.strip()]
    cfg["projectIdleDays"] = _clamp_int(raw.get("projectIdleDays"), 0, 3650, DEFAULT_CONFIG["projectIdleDays"])
    cfg["downloadsDays"] = _clamp_int(raw.get("downloadsDays"), 1, 3650, DEFAULT_CONFIG["downloadsDays"])
    cfg["pacmanKeep"] = _clamp_choice(raw.get("pacmanKeep"), (1, 2), DEFAULT_CONFIG["pacmanKeep"])
    cfg["journalMax"] = _clamp_choice(raw.get("journalMax"), JOURNAL_CHOICES, DEFAULT_CONFIG["journalMax"])
    cfg["coredumpAgeDays"] = _clamp_choice(raw.get("coredumpAgeDays"), COREDUMP_AGE_CHOICES, DEFAULT_CONFIG["coredumpAgeDays"])
    return cfg


def save_config(cfg):
    atomic_write_json(config_path(), cfg)


def keep_paths(cfg):
    out = []
    for entry in cfg.get("keep", []):
        p = os.path.normpath(expand(entry))
        if os.path.isabs(p):
            out.append(p)
    return out


def is_kept(abs_path, keep):
    """True if abs_path is a kept path, inside one, or contains one."""
    p = abs_path.rstrip("/")
    for k in keep:
        if p == k or p.startswith(k + "/") or k.startswith(p + "/"):
            return True
    return False


@contextlib.contextmanager
def op_lock():
    directory = runtime_dir()
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd = os.open(os.path.join(directory, "op.lock"), os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Busy() from None
        yield
    finally:
        os.close(fd)


def lock_is_held():
    path = os.path.join(runtime_dir(), "op.lock")
    try:
        fd = os.open(path, os.O_RDWR | os.O_CLOEXEC)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    finally:
        os.close(fd)
    return False
