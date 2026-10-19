import os
import unittest

from helpers import FakeHome

from diskkeeper import fsops


class ValidRel(unittest.TestCase):
    def test_accepts_plain_relative_paths(self):
        self.assertTrue(fsops.valid_rel("a"))
        self.assertTrue(fsops.valid_rel("a/b c/ດີ"))

    def test_rejects_escapes(self):
        for bad in ("", "/etc", "..", "a/../b", "a//b", "a/./b", "a/", "a\x00b", None, 3):
            self.assertFalse(fsops.valid_rel(bad), bad)

    def test_single_component(self):
        self.assertTrue(fsops.valid_rel("foo-git", single=True))
        self.assertFalse(fsops.valid_rel("a/b", single=True))


class DeleteEntry(FakeHome):
    def test_deletes_tree_and_file(self):
        self.make(".cache/x/a/b/file")
        self.make(".cache/y")
        fsops.delete_entry(self.h(".cache/x"), "t1")
        fsops.delete_entry(self.h(".cache/y"), "t1")
        self.assertEqual(os.listdir(self.h(".cache")), [])

    def test_refuses_symlink_in_parent_chain(self):
        outside = os.path.join(self.tmp, "outside")
        os.makedirs(os.path.join(outside, "victim"))
        os.makedirs(self.h(".cache"))
        os.symlink(outside, self.h(".cache/link"))
        with self.assertRaises(fsops.Unsafe):
            fsops.delete_entry(self.h(".cache/link/victim"), "t1")
        self.assertTrue(os.path.isdir(os.path.join(outside, "victim")))

    def test_symlink_target_is_removed_as_link_only(self):
        outside = os.path.join(self.tmp, "outside")
        os.makedirs(outside)
        self.make("keepme", b"data")
        os.makedirs(self.h(".cache"))
        os.symlink(outside, self.h(".cache/link"))
        fsops.delete_entry(self.h(".cache/link"), "t1")
        self.assertTrue(os.path.isdir(outside))
        self.assertFalse(os.path.lexists(self.h(".cache/link")))

    def test_identity_mismatch_is_skipped(self):
        self.make(".cache/x/file")
        expect = fsops.identity(fsops.lstat(self.h(".cache/x")))
        os.rename(self.h(".cache/x"), self.h(".cache/old"))
        self.make(".cache/x/other")
        with self.assertRaises(fsops.Unsafe) as cm:
            fsops.delete_entry(self.h(".cache/x"), "t1", expect=expect)
        self.assertEqual(cm.exception.reason, "changed-since-scan")
        self.assertTrue(os.path.exists(self.h(".cache/x/other")))

    def test_read_only_tree(self):
        self.make(".cache/yay/pkg/src/deep/file")
        for d in ("src/deep", "src", ""):
            os.chmod(self.h(".cache/yay/pkg", d), 0o555)
        fsops.delete_entry(self.h(".cache/yay/pkg"), "t1")
        self.assertFalse(os.path.lexists(self.h(".cache/yay/pkg")))

    def test_outside_home_refused(self):
        with self.assertRaises(fsops.Unsafe):
            fsops.delete_entry(os.path.join(self.tmp, "x"), "t1")
        with self.assertRaises(fsops.Unsafe):
            fsops.delete_entry(self.home, "t1")

    def test_dry_run_keeps_everything(self):
        self.make(".cache/x/file")
        fsops.delete_entry(self.h(".cache/x"), "t1", dry_run=True)
        self.assertTrue(os.path.exists(self.h(".cache/x/file")))

    def test_sweep_tombstones_and_listing_hides_them(self):
        self.make(".cache/.pkg.diskkeeper-del-old/file")
        self.make(".cache/real")
        self.assertEqual([n for n, _ in fsops.list_children(self.h(".cache"))], ["real"])
        self.assertEqual(fsops.sweep_tombstones(self.h(".cache")), 1)
        self.assertEqual(sorted(os.listdir(self.h(".cache"))), ["real"])

    def test_non_utf8_names(self):
        os.makedirs(self.h(".cache"))
        bad = os.fsdecode(b"bad\xff")
        open(self.h(".cache", bad), "w").close()
        self.assertFalse(fsops.round_trips(bad))
        self.assertIn("�", fsops.display_name(bad))

    def test_du_sizes(self):
        self.make(".cache/a/f", b"x" * 100000)
        sizes = fsops.du([self.h(".cache/a")])
        self.assertGreaterEqual(sizes[self.h(".cache/a")], 100000)


if __name__ == "__main__":
    unittest.main()
