"""One pass over /proc to answer "is anything using this path?" and "is app X running?"."""

import contextlib
import os


class Proc:
    __slots__ = ("pid", "ppid", "comm", "exe", "cwd", "cmdline", "_paths", "_root")

    def __init__(self, root, pid):
        self._root = root
        self.pid = pid
        base = os.path.join(root, str(pid))
        # /proc/PID/stat: "pid (comm) state ppid ..."; comm may contain spaces and parens.
        tail = _read(os.path.join(base, "stat")).rpartition(")")[2].split()
        self.ppid = int(tail[1]) if len(tail) > 1 and tail[1].isdigit() else 0
        self.comm = _read(os.path.join(base, "comm")).strip()
        self.exe = _readlink(os.path.join(base, "exe"))
        self.cwd = _readlink(os.path.join(base, "cwd"))
        raw = _read(os.path.join(base, "cmdline"), binary=True)
        self.cmdline = [os.fsdecode(a) for a in raw.split(b"\0") if a]
        self._paths = None

    def open_paths(self):
        """Paths of open fds and mapped files; read lazily because it is the slow part."""
        if self._paths is None:
            found = set()
            base = os.path.join(self._root, str(self.pid))
            with contextlib.suppress(OSError):
                fd_dir = os.path.join(base, "fd")
                for fd in os.listdir(fd_dir):
                    target = _readlink(os.path.join(fd_dir, fd))
                    if target.startswith("/"):
                        found.add(target)
            with contextlib.suppress(OSError):
                with open(os.path.join(base, "maps"), "rb") as fh:
                    for line in fh:
                        idx = line.find(b" /")
                        if idx != -1:
                            found.add(os.fsdecode(line[idx + 1:].rstrip(b"\n")).replace(" (deleted)", ""))
            self._paths = found
        return self._paths

    def describe(self):
        return "%s (pid %d)" % (self.comm or os.path.basename(self.exe) or "process", self.pid)


def _read(path, binary=False):
    try:
        with open(path, "rb" if binary else "r", errors=None if binary else "replace") as fh:
            return fh.read()
    except OSError:
        return b"" if binary else ""


def _readlink(path):
    try:
        return os.readlink(path)
    except OSError:
        return ""


def _under(path, prefix):
    return path == prefix or path.startswith(prefix + "/")


class ProcTable:
    def __init__(self, root="/proc", me=None):
        self.root = root
        me = os.getpid() if me is None else me
        uid = os.getuid()
        found = []
        with contextlib.suppress(OSError):
            for name in os.listdir(root):
                if not name.isdigit():
                    continue
                with contextlib.suppress(OSError):
                    if os.stat(os.path.join(root, name)).st_uid != uid:
                        continue
                    found.append(Proc(root, int(name)))
        # Leave out this process and everything it spawned (du, git, pnpm...),
        # or a scan would find its own helpers "using" the folders it measures.
        children = {}
        for p in found:
            children.setdefault(p.ppid, []).append(p.pid)
        ours = set()
        stack = [me]
        while stack:
            pid = stack.pop()
            if pid in ours:
                continue
            ours.add(pid)
            stack.extend(children.get(pid, []))
        self.procs = [p for p in found if p.pid not in ours]

    def using(self, abs_path):
        """First process whose cwd, executable, arguments, open files or maps are under abs_path."""
        prefix = os.path.normpath(abs_path)
        for p in self.procs:
            if _under(p.cwd, prefix) or _under(p.exe, prefix):
                return p
            if any(_under(arg, prefix) for arg in p.cmdline if arg.startswith("/")):
                return p
        for p in self.procs:
            if any(_under(path, prefix) for path in p.open_paths()):
                return p
        return None

    def running(self, comms=(), exe_prefixes=(), arg_basenames=(), arg_contains=()):
        """First process matching any of the given traits."""
        for p in self.procs:
            if p.comm in comms:
                return p
            if p.exe and any(p.exe.startswith(pre) for pre in exe_prefixes):
                return p
            if arg_basenames and p.cmdline[:2] and any(os.path.basename(a) in arg_basenames for a in p.cmdline[:2]):
                return p
            if arg_contains and any(any(s in a for s in arg_contains) for a in p.cmdline[:3]):
                return p
        return None


# Traits of the applications whose caches must not be removed while they run.
APPS = {
    # pacman itself is caught by its db.lck; a read-only `pacman -Q` from a bar widget must not block.
    "aur": {"comms": ("yay", "paru", "makepkg")},
    "pnpm": {"comms": ("pnpm",), "arg_basenames": ("pnpm", "pnpm.cjs", "pnpm.mjs", "pnpx")},
    "npm": {"comms": ("npm",), "arg_basenames": ("npm", "npm-cli.js", "npx", "npx-cli.js")},
    "bun": {"comms": ("bun",)},
    "brave": {"exe_prefixes": ("/opt/brave", "/usr/lib/brave", "/usr/lib/brave-browser"), "comms": ("brave",)},
    "intellij": {"exe_prefixes": ("/opt/intellij-idea",), "arg_contains": ("com.intellij.idea.Main",)},
    "vscode": {"exe_prefixes": ("/usr/share/code/", "/opt/visual-studio-code/", "/usr/lib/code/"), "comms": ("code",)},
    "claude-desktop": {"exe_prefixes": ("/usr/lib/claude-desktop/",)},
}

APP_NAMES = {
    "aur": "yay",
    "pnpm": "pnpm",
    "npm": "npm",
    "bun": "bun",
    "brave": "Brave",
    "intellij": "IntelliJ IDEA",
    "vscode": "VS Code",
    "claude-desktop": "Claude Desktop",
}


def app_running(table, app):
    return table.running(**APPS[app])
