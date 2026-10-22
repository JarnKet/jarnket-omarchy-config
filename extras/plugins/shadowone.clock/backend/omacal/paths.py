"""Where things live: XDG dirs, the client/accounts files, the cache, locks.

Nothing here may write inside the plugin directory. The Omarchy shell
watches ~/.config/omarchy/plugins recursively and reloads every plugin
on any change there.

Secrets never touch these files: refresh tokens live in the keyring
(see oauth.py). client.json holds the OAuth client of the user's own
Google Cloud project, which Google treats as public for desktop apps,
but it is still kept 0600 and out of any repo.
"""

import contextlib
import fcntl
import json
import os
import tempfile


class Busy(Exception):
    """Another process holds the lock."""


def home():
    return os.environ.get("HOME") or os.path.expanduser("~")


def _xdg(name, default_rel):
    value = os.environ.get(name, "")
    return value if os.path.isabs(value) else os.path.join(home(), default_rel)


def config_dir():
    return os.path.join(_xdg("XDG_CONFIG_HOME", ".config"), "omacal")


def state_dir():
    return os.path.join(_xdg("XDG_STATE_HOME", ".local/state"), "omacal")


def runtime_dir():
    base = os.environ.get("XDG_RUNTIME_DIR", "")
    if not os.path.isabs(base):
        base = os.path.join(tempfile.gettempdir(), "omacal-%d" % os.getuid())
    return os.path.join(base, "omacal")


def client_path():
    return os.path.join(config_dir(), "client.json")


def accounts_path():
    return os.path.join(config_dir(), "accounts.json")


def status_path():
    return os.path.join(state_dir(), "status.json")


def notified_path():
    return os.path.join(state_dir(), "notified.json")


def months_dir():
    return os.path.join(state_dir(), "months")


def month_path(ym):
    return os.path.join(months_dir(), ym + ".json")


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def atomic_write_json(path, data):
    """Write via a temp file + rename, so the QML FileView never reads half a file.

    mkstemp creates the file 0600, and new directories are 0700.
    """
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


@contextlib.contextmanager
def lock(name, blocking=True):
    """An flock in the runtime dir. Non-blocking raises Busy when it is held."""
    directory = runtime_dir()
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd = os.open(os.path.join(directory, name + ".lock"), os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            raise Busy() from None
        yield
    finally:
        os.close(fd)


# ------------------------------------------------------------------ accounts

def load_accounts():
    """[{"email", "addedAt"}] in the order they were added."""
    raw = read_json(accounts_path(), {})
    items = raw.get("accounts") if isinstance(raw, dict) else None
    out = []
    for item in items if isinstance(items, list) else []:
        if isinstance(item, dict) and isinstance(item.get("email"), str) and item["email"]:
            out.append({"email": item["email"], "addedAt": item.get("addedAt", 0)})
    return out


def save_accounts(accounts):
    atomic_write_json(accounts_path(), {"accounts": accounts})


# ------------------------------------------------------------------ status

def read_status():
    data = read_json(status_path(), {})
    return data if isinstance(data, dict) else {}


def update_status(mutate):
    """Read-modify-write status.json under a lock; `mutate(dict)` edits in place."""
    with lock("status"):
        data = read_status()
        mutate(data)
        data["kind"] = "status"
        data["schema"] = 1
        atomic_write_json(status_path(), data)
        return data
