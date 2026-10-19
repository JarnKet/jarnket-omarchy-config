import contextlib
import importlib.machinery
import importlib.util
import io
import os
import unittest

from helpers import ROOT


def load_helper():
    path = os.path.join(ROOT, "root", "diskkeeper-root")
    loader = importlib.machinery.SourceFileLoader("diskkeeper_root", path)
    spec = importlib.util.spec_from_loader("diskkeeper_root", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


helper = load_helper()


class Tokens(unittest.TestCase):
    def ok(self, *tokens):
        return [verb for verb, _ in helper.validate_tokens(list(tokens))]

    def bad(self, *tokens):
        with self.assertRaises(helper.UsageError):
            helper.validate_tokens(list(tokens))

    def test_valid(self):
        self.assertEqual(self.ok("pacman-cache:keep=1", "journal:max=200M", "coredumps:age=7d"),
                         ["pacman-cache", "journal", "coredumps"])
        self.assertEqual(self.ok("snapshots-delete:ids=3,4,10"), ["snapshots-delete"])
        self.assertEqual(self.ok("snapshots-list"), ["snapshots-list"])

    def test_invalid(self):
        self.bad()
        self.bad("pacman-cache:keep=0")
        self.bad("pacman-cache:keep=1;rm -rf /")
        self.bad("journal:max=1M")
        self.bad("journal:max=200M", "journal:max=500M")
        self.bad("coredumps:age=5d")
        self.bad("snapshots-delete:ids=")
        self.bad("snapshots-delete:ids=1,../2")
        self.bad("snapshots-delete:ids=" + ",".join(str(i) for i in range(1, 30)))
        self.bad("snapshots-list", "journal:max=200M")
        self.bad("rm:/etc")
        self.bad(*["journal:max=200M"] * 6)

    def test_protected_snapshots(self):
        snaps = [
            {"number": 0, "default": False, "active": False},
            {"number": 3, "default": False, "active": False},
            {"number": 4, "default": True, "active": True},
            {"number": 7, "default": False, "active": False},
        ]
        self.assertEqual(helper.protected_numbers(snaps), {0, 4, 7})

    def test_refuses_without_root(self):
        if os.geteuid() == 0:
            self.skipTest("running as root")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(helper.main(["--json", "journal:max=200M"]), 2)


if __name__ == "__main__":
    unittest.main()
