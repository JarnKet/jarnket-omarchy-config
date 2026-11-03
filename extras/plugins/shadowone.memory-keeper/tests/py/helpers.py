"""Shared fixture: a throwaway $HOME, a fake /proc and a scripted outside world."""

import json
import os
import shutil
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "backend"))
sys.dont_write_bytecode = True

from memkeeper import state as st  # noqa: E402

ENV_KEYS = ("HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR")
GIB = 1024 ** 3


def uuid(n):
    return "%08d-0000-4000-8000-000000000000" % n


class FakeEnv(st.Env):
    def __init__(self, tmp):
        super().__init__()
        self.proc = os.path.join(tmp, "proc")
        self.app_slice = os.path.join(tmp, "app.slice")
        self.view_file = os.path.join(tmp, "view.json")
        self.sessions_dir = os.path.join(tmp, "sessions")
        os.makedirs(self.proc)
        os.makedirs(self.app_slice)
        os.makedirs(self.sessions_dir)
        self.now_wall = 1_800_000_000.0
        self.now_mono = 100_000.0
        self.terminals = {}
        self.screens = {}
        self.calls = []
        self.signals = []
        self.ignores_term = set()
        self.run_fails = set()

    def wall(self):
        return self.now_wall

    def mono(self):
        return self.now_mono

    def uptime(self):
        return 500_000.0

    def ticks_per_second(self):
        return 100

    def sleep(self, seconds):
        self.now_wall += seconds
        self.now_mono += seconds

    def terminate(self, pid):
        self.signals.append(pid)
        if pid not in self.ignores_term:
            shutil.rmtree(os.path.join(self.proc, str(pid)))

    def run(self, argv, timeout=8):
        self.calls.append(argv)
        if argv[:2] == ["hc", "get"]:
            info = self.terminals.get(argv[2])
            return (0, json.dumps(info)) if info else (1, "")
        if argv[:2] == ["hc", "read"]:
            return 0, json.dumps({"text": self.screens.get(argv[2], "")})
        if argv[0] in self.run_fails or tuple(argv[:3]) in self.run_fails:
            return 1, ""
        return 0, ""

    # -------- building the fake machine

    def add_proc(self, pid, ppid=1, comm="x", cmdline=("x",), start=1000, tty=0, state="S", environ=None,
                 pss_kb=0, swap_kb=0, cgroup="0::/app.slice/app.scope"):
        base = os.path.join(self.proc, str(pid))
        os.makedirs(base)
        tail = [state, str(ppid), "0", "0", str(tty)] + ["0"] * 14 + [str(start)] + ["0"] * 10
        with open(os.path.join(base, "stat"), "w") as fh:
            fh.write("%d (%s) %s\n" % (pid, comm, " ".join(tail)))
        with open(os.path.join(base, "cmdline"), "wb") as fh:
            fh.write(b"\0".join(a.encode() for a in cmdline) + b"\0")
        with open(os.path.join(base, "environ"), "wb") as fh:
            fh.write(b"\0".join(("%s=%s" % kv).encode() for kv in (environ or {}).items()))
        with open(os.path.join(base, "smaps_rollup"), "w") as fh:
            fh.write("Rss: 1 kB\nPss: %d kB\nSwapPss: %d kB\n" % (pss_kb, swap_kb))
        with open(os.path.join(base, "cgroup"), "w") as fh:
            fh.write(cgroup + "\n")

    def add_session(self, pid, n, status="idle", idle_seconds=0, kind="interactive", terminal=None, name=None, tab="tb-other",
                    pss_kb=100_000, swap_kb=0, start=1000):
        terminal = terminal if terminal is not None else "t%d" % n
        environ = {"HC_TERMINAL_ID": terminal} if terminal else {}
        self.add_proc(pid, comm="claude", cmdline=("claude",), start=start, tty=5, environ=environ, pss_kb=pss_kb, swap_kb=swap_kb)
        d = {"pid": pid, "procStart": str(start), "sessionId": uuid(n), "name": name or "s%d" % n, "cwd": self.sessions_dir,
             "status": status, "kind": kind, "statusUpdatedAt": (self.now_wall - idle_seconds) * 1000}
        with open(os.path.join(self.sessions_dir, "%d.json" % pid), "w") as fh:
            json.dump(d, fh)
        if terminal:
            self.terminals[terminal] = {"state": "live", "foreground": {"pid": pid, "name": "claude"},
                                        "labels": {"herdr.tab": tab, "herdr.space": "sp1", "where": "Space / tab"}}
        return uuid(n)

    def write_meminfo(self, total=30 * GIB, available=15 * GIB, free=5 * GIB, swap_total=30 * GIB, swap_used=GIB, psi_some=0.0, psi_full=0.0):
        with open(os.path.join(self.proc, "meminfo"), "w") as fh:
            fh.write("MemTotal: %d kB\nMemFree: %d kB\nMemAvailable: %d kB\nCached: %d kB\nSwapTotal: %d kB\nSwapFree: %d kB\n" % (
                total // 1024, free // 1024, available // 1024, GIB // 1024, swap_total // 1024, (swap_total - swap_used) // 1024))
        os.makedirs(os.path.join(self.proc, "pressure"), exist_ok=True)
        with open(os.path.join(self.proc, "pressure", "memory"), "w") as fh:
            fh.write("some avg10=0 avg60=%.2f avg300=0 total=0\nfull avg10=0 avg60=%.2f avg300=0 total=0\n" % (psi_some, psi_full))


class Case(unittest.TestCase):
    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in ENV_KEYS}
        self.tmp = tempfile.mkdtemp(prefix="memkeeper-test-")
        home = os.path.join(self.tmp, "home")
        run = os.path.join(self.tmp, "run")
        os.makedirs(home)
        os.makedirs(run)
        os.environ["HOME"] = home
        os.environ["XDG_CONFIG_HOME"] = os.path.join(home, ".config")
        os.environ["XDG_STATE_HOME"] = os.path.join(home, ".local", "state")
        os.environ["XDG_RUNTIME_DIR"] = run
        self.env = FakeEnv(self.tmp)
        self.env.write_meminfo()

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp)
