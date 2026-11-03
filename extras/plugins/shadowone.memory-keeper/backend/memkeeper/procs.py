"""One pass over /proc: who runs what, and how much memory it really holds."""

import contextlib
import os


class Proc:
    __slots__ = ("pid", "ppid", "comm", "state", "tty", "start", "uid", "cmdline")

    def __init__(self, root, pid):
        base = os.path.join(root, str(pid))
        self.pid = pid
        with open(os.path.join(base, "stat"), encoding="utf-8", errors="replace") as fh:
            stat = fh.read()
        # "pid (comm) state ppid ..."; comm may contain spaces and parens.
        self.comm = stat[stat.index("(") + 1:stat.rindex(")")]
        tail = stat[stat.rindex(")") + 2:].split()
        self.state = tail[0]
        self.ppid = int(tail[1])
        self.tty = int(tail[4])
        self.start = int(tail[19])
        self.uid = os.stat(base).st_uid
        with open(os.path.join(base, "cmdline"), "rb") as fh:
            self.cmdline = [os.fsdecode(a) for a in fh.read().split(b"\0") if a]

    @property
    def text(self):
        return " ".join(self.cmdline)


class Table:
    """Reads one process at a time until something needs the whole picture, so
    a quiet timer tick costs a few file reads instead of walking all of /proc."""

    def __init__(self, root="/proc"):
        self.root = root
        self._all = None
        self._kids = None
        self._one = {}

    @property
    def procs(self):
        if self._all is None:
            self._all = {}
            for name in os.listdir(self.root):
                if name.isdigit():
                    with contextlib.suppress(OSError, ValueError, IndexError):
                        self._all[int(name)] = Proc(self.root, int(name))
        return self._all

    def get(self, pid):
        if self._all is not None:
            return self._all.get(pid)
        if pid not in self._one:
            self._one[pid] = None
            with contextlib.suppress(OSError, ValueError, IndexError):
                self._one[pid] = Proc(self.root, pid)
        return self._one[pid]

    def children(self, pid):
        if self._kids is None:
            self._kids = {}
            for p in self.procs.values():
                self._kids.setdefault(p.ppid, []).append(p)
        return self._kids.get(pid, [])

    def descendants(self, pid):
        out, todo = [], list(self.children(pid))
        while todo:
            p = todo.pop()
            out.append(p)
            todo.extend(self.children(p.pid))
        return out

    def is_self_or_ancestor(self, candidate, pid):
        while pid in self.procs:
            if pid == candidate:
                return True
            pid = self.procs[pid].ppid
        return False

    def environ(self, pid, name):
        with contextlib.suppress(OSError):
            with open(os.path.join(self.root, str(pid), "environ"), "rb") as fh:
                prefix = name.encode() + b"="
                for item in fh.read().split(b"\0"):
                    if item.startswith(prefix):
                        return os.fsdecode(item[len(prefix):])
        return None

    def cgroup_leaf(self, pid):
        with contextlib.suppress(OSError):
            with open(os.path.join(self.root, str(pid), "cgroup"), encoding="utf-8", errors="replace") as fh:
                return fh.read().strip().rsplit("/", 1)[-1]
        return ""

    def bytes_of(self, pid):
        """PSS + swap: shared pages counted once, RSS would count them per process."""
        total = 0
        with contextlib.suppress(OSError, ValueError, IndexError):
            with open(os.path.join(self.root, str(pid), "smaps_rollup")) as fh:
                for line in fh:
                    if line.startswith(("Pss:", "SwapPss:")):
                        total += int(line.split()[1]) * 1024
        return total

    def tree_bytes(self, pid):
        return self.bytes_of(pid) + sum(self.bytes_of(p.pid) for p in self.descendants(pid))


def alive(root, pid, start):
    """True while this exact process (not a reused pid) still runs."""
    try:
        p = Proc(root, pid)
    except (OSError, ValueError, IndexError):
        return False
    return p.start == start and p.state not in ("Z", "X")
