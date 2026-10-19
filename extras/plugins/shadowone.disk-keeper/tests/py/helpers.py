"""Shared fixture: a throwaway $HOME with XDG dirs pointing inside it."""

import os
import shutil
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "backend"))
sys.dont_write_bytecode = True

ENV_KEYS = ("HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR", "PATH")


class FakeHome(unittest.TestCase):
    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in ENV_KEYS}
        self.tmp = tempfile.mkdtemp(prefix="diskkeeper-test-")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        os.environ["HOME"] = self.home
        os.environ["XDG_CACHE_HOME"] = os.path.join(self.home, ".cache")
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.home, ".config")
        os.environ["XDG_DATA_HOME"] = os.path.join(self.home, ".local", "share")
        os.environ["XDG_STATE_HOME"] = os.path.join(self.home, ".local", "state")
        os.environ["XDG_RUNTIME_DIR"] = os.path.join(self.tmp, "run")
        os.makedirs(os.environ["XDG_RUNTIME_DIR"])

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        for root, dirs, _files in os.walk(self.tmp):
            for d in dirs:
                p = os.path.join(root, d)
                if not os.path.islink(p):
                    os.chmod(p, 0o700)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def h(self, *parts):
        return os.path.join(self.home, *parts)

    def make(self, rel, content=b"x" * 4096):
        path = self.h(rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(content)
        return path

    def fake_tool(self, name, script):
        """Put an executable `name` first on PATH; it appends its argv to <tmp>/<name>.log."""
        bindir = os.path.join(self.tmp, "bin")
        os.makedirs(bindir, exist_ok=True)
        path = os.path.join(bindir, name)
        log = os.path.join(self.tmp, name + ".log")
        with open(path, "w") as fh:
            fh.write("#!/bin/bash\necho \"$*\" >> %s\n%s\n" % (log, script))
        os.chmod(path, 0o755)
        if not os.environ["PATH"].startswith(bindir):
            os.environ["PATH"] = bindir + ":" + os.environ["PATH"]
        return log

    def calls(self, name):
        try:
            with open(os.path.join(self.tmp, name + ".log")) as fh:
                return [l.rstrip("\n") for l in fh]
        except OSError:
            return []
