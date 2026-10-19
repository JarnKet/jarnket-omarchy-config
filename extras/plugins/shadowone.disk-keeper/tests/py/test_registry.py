import os
import subprocess
import unittest

from helpers import FakeHome

from diskkeeper import paths, registry


def ctx(job="t1", dry_run=False):
    return registry.Context(paths.load_config(), job=job, dry_run=dry_run)


class YayBuilds(FakeHome):
    def setUp(self):
        super().setUp()
        self.make(".cache/yay/foo-git/src/file")
        self.make(".cache/yay/bar-bin/file")
        self.make(".cache/yay/vcs.json", b"{}")
        self.make(".cache/yay/completion.cache", b"")

    def test_keeps_vcs_and_completion(self):
        data = registry.YayBuilds().scan(ctx())
        self.assertEqual(sorted(i["key"] for i in data["items"]), ["bar-bin", "foo-git"])

    def test_clean_only_known_keys(self):
        res = registry.YayBuilds().clean(ctx(), ["foo-git", "../../etc", "vcs.json"], {})
        status = {r["target"]: r["status"] for r in res}
        self.assertEqual(status["yay-builds:foo-git"], "done")
        self.assertEqual(status["yay-builds:../../etc"], "skipped")
        self.assertEqual(status["yay-builds:vcs.json"], "skipped")
        self.assertTrue(os.path.exists(self.h(".cache/yay/vcs.json")))
        self.assertTrue(os.path.exists(self.h(".cache/yay/bar-bin")))
        self.assertFalse(os.path.exists(self.h(".cache/yay/foo-git")))

    def test_in_use_item_is_skipped(self):
        # Detached (reparented away from us): our own children are deliberately ignored.
        out = subprocess.run(["bash", "-c", "sleep 30 >/dev/null 2>&1 & echo $!"], cwd=self.h(".cache/yay/bar-bin"),
                             stdout=subprocess.PIPE, text=True, check=True)
        pid = int(out.stdout.strip())
        try:
            res = registry.YayBuilds().clean(ctx(), ["bar-bin"], {})
        finally:
            os.kill(pid, 9)
        self.assertEqual(res[0]["reason"], "in-use")
        self.assertTrue(os.path.exists(self.h(".cache/yay/bar-bin")))

    def test_identity_from_scan_is_checked(self):
        scan = registry.YayBuilds().scan(ctx())
        items = {i["key"]: i for i in scan["items"]}
        os.rename(self.h(".cache/yay/bar-bin"), self.h(".cache/yay/moved"))
        os.makedirs(self.h(".cache/yay/bar-bin"))
        res = registry.YayBuilds().clean(ctx(), ["bar-bin"], items)
        self.assertEqual(res[0]["reason"], "changed-since-scan")


class KeepList(FakeHome):
    def test_kept_paths_are_blocked(self):
        self.make(".config/Claude/vm_bundles/big")
        self.make(".config/Claude/Cache/x")
        data = registry.ClaudeDesktopCache().scan(ctx())
        self.assertEqual([i["key"] for i in data["items"]], ["Cache"])
        cfg = paths.load_config()
        cfg["keep"].append("~/.config/Claude/Cache")
        paths.save_config(cfg)
        data = registry.ClaudeDesktopCache().scan(ctx())
        self.assertEqual(data["items"][0]["blocked"]["reason"], "kept")
        self.assertEqual(data["bytes"], 0)


class Allowlist(FakeHome):
    def test_jetbrains_keeps_local_history(self):
        for d in ("index", "caches", "log", "LocalHistory", "fileHistory", "plugins"):
            self.make(".cache/JetBrains/IntelliJIdea2026.2/%s/f" % d)
        res = registry.JetBrainsCache().clean(ctx(), None, {})
        self.assertEqual(res[0]["status"], "done")
        left = sorted(os.listdir(self.h(".cache/JetBrains/IntelliJIdea2026.2")))
        self.assertEqual(left, ["LocalHistory", "fileHistory", "plugins"])

    def test_brave_only_cache_dirs(self):
        self.make(".cache/BraveSoftware/Brave-Origin/Default/Cache/f")
        self.make(".cache/BraveSoftware/Brave-Origin/Default/Code Cache/f")
        self.make(".cache/BraveSoftware/Brave-Origin/Default/Other/f")
        self.make(".cache/BraveSoftware/Brave-Origin/System Profile/Cache/f")
        keys = sorted(c.key for c in registry.BraveCache().candidates(ctx()))
        self.assertEqual(keys, ["Brave-Origin/Default/Cache", "Brave-Origin/Default/Code Cache"])


class Pnpm(FakeHome):
    def setUp(self):
        super().setUp()
        for v in ("v3", "v10", "v11"):
            self.make(".local/share/pnpm/store/%s/files/f" % v)
        self.fake_tool("pnpm", 'echo "%s"' % self.h(".local/share/pnpm/store/v11"))

    def test_old_unreferenced_stores_only(self):
        self.make("Projects/app/node_modules/.modules.yaml",
                  ('{\n  "storeDir": "%s",\n}\n' % self.h(".local/share/pnpm/store/v10")).encode())
        data = registry.PnpmOldStores().scan(ctx())
        self.assertEqual([i["key"] for i in data["items"]], ["v3"])
        self.assertIn("v10 still used by 1 project", data["note"])


class TrashAndDownloads(FakeHome):
    def test_trash_item_removes_info_too(self):
        self.make(".local/share/Trash/files/report.pdf")
        self.make(".local/share/Trash/info/report.pdf.trashinfo",
                  b"[Trash Info]\nPath=/home/x/report.pdf\nDeletionDate=2026-10-01T10:00:00\n")
        data = registry.Trash().scan(ctx())
        self.assertIn("2026-10-01", data["items"][0]["detail"])
        registry.Trash().clean(ctx(), ["report.pdf"], {})
        self.assertEqual(os.listdir(self.h(".local/share/Trash/files")), [])
        self.assertEqual(os.listdir(self.h(".local/share/Trash/info")), [])

    def test_downloads_age_counts_ctime(self):
        # An archive extracted today keeps its old mtimes; its ctime is new, so it is not "old".
        old = self.make("Downloads/extracted/file")
        os.utime(old, (1, 1))
        os.utime(self.h("Downloads/extracted"), (1, 1))
        self.assertEqual(registry.DownloadsOld().scan(ctx())["items"], [])

    def test_downloads_go_to_trash_not_deleted(self):
        path = self.make("Downloads/old.zip")
        self.fake_tool("gio", "exit 0")
        cand = registry.Candidate("old.zip", path)
        registry.DownloadsOld().delete(ctx(), cand, None)
        self.assertEqual(self.calls("gio"), ["trash -- " + path])
        self.assertTrue(os.path.exists(path))


if __name__ == "__main__":
    unittest.main()
