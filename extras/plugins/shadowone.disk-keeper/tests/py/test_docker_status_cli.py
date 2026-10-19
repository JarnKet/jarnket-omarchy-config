import json
import unittest

from helpers import FakeHome

from diskkeeper import cli, docker, paths, registry, status

GIB = 1024 ** 3

DF_V = {
    "Images": [
        {"Repository": "<none>", "Tag": "<none>", "Containers": "0", "Size": "100MB", "UniqueSize": "100MB"},
        {"Repository": "app", "Tag": "1", "Containers": "1", "Size": "1GB", "UniqueSize": "900MB"},
        {"Repository": "old", "Tag": "2", "Containers": "0", "Size": "2GB", "UniqueSize": "1.5GB"},
    ],
    "Volumes": [
        {"Name": "pgdata_attached", "Links": "1", "Size": "500MB", "Labels": ""},
        {"Name": "6f4fc1d052eff3ae1da12c3050d336c8e369dace", "Links": "0", "Size": "48.96MB",
         "Labels": "com.docker.volume.anonymous="},
    ],
    "Containers": [], "BuildCache": [],
}


class DockerParsing(unittest.TestCase):
    def test_parse_size(self):
        self.assertEqual(docker.parse_size("2.231GB"), 2231000000)
        self.assertEqual(docker.parse_size("33.85MB"), 33850000)
        self.assertEqual(docker.parse_size("1.2kB"), 1200)
        self.assertEqual(docker.parse_size("0B"), 0)
        self.assertEqual(docker.parse_size("N/A"), 0)


class DockerNeverPrunesVolumesOrContainers(FakeHome):
    def setUp(self):
        super().setUp()
        self.fake_tool("docker", r'''
case "$*" in
  "system df -v --format json") echo '%s' ;;
  "system df --format json") echo '{"Type":"Build Cache","Reclaimable":"1.5GB"}' ;;
  volume\ inspect*) echo '{"Name":"6f4fc1d052eff3ae1da12c3050d336c8e369dace","CreatedAt":"2026-09-30T10:00:00Z"}' ;;
esac
exit 0''' % json.dumps(DF_V))

    def ctx(self):
        return registry.Context(paths.load_config(), job="t")

    def test_estimates(self):
        c = self.ctx()
        self.assertEqual(docker.DanglingImages().scan(c)["bytes"], 100000000)
        self.assertEqual(docker.UnusedImages().scan(c)["bytes"], 1500000000)
        self.assertEqual(docker.BuildCache().scan(c)["bytes"], 1500000000)
        vols = docker.DanglingVolumes().scan(c)["items"]
        self.assertEqual([v["key"] for v in vols], ["6f4fc1d052eff3ae1da12c3050d336c8e369dace"])
        self.assertIn("2026-09-30", vols[0]["detail"])

    def test_volume_clean_is_by_name_only(self):
        c = self.ctx()
        res = docker.DanglingVolumes().clean(c, ["6f4fc1d052eff3ae1da12c3050d336c8e369dace", "pgdata_attached"], {})
        self.assertEqual([r["status"] for r in res], ["done", "skipped"])
        docker.DanglingVolumes().clean(c, None, {})  # no selection must remove nothing
        calls = self.calls("docker")
        self.assertIn("volume rm -- 6f4fc1d052eff3ae1da12c3050d336c8e369dace", calls)
        self.assertFalse(any("prune" in call and ("volume" in call or "container" in call) for call in calls))
        self.assertFalse(any("pgdata_attached" in call and "rm" in call for call in calls))

    def test_no_category_ever_prunes_containers(self):
        for cat in registry.all_categories():
            self.assertNotIn("container", " ".join(getattr(cat, "command", ())))


class Levels(unittest.TestCase):
    total = 129 * GIB

    def test_thresholds(self):
        self.assertEqual(status.compute_level(30 * GIB, self.total, 20, 10)[0], "ok")
        self.assertEqual(status.compute_level(15 * GIB, self.total, 20, 10)[0], "warn")
        self.assertEqual(status.compute_level(5 * GIB, self.total, 20, 10)[0], "critical")

    def test_hysteresis(self):
        # Just above the warn line after being low: stay at warn until a margin (2% ≈ 2.6 GiB) is gained.
        self.assertEqual(status.compute_level(21 * GIB, self.total, 20, 10, "warn")[0], "warn")
        self.assertEqual(status.compute_level(23 * GIB, self.total, 20, 10, "warn")[0], "ok")
        self.assertEqual(status.compute_level(11 * GIB, self.total, 20, 10, "critical")[0], "critical")

    def test_btrfs_metadata_pressure(self):
        btrfs = {"unallocatedBytes": GIB, "metadataTotalBytes": 100, "metadataUsedBytes": 90}
        self.assertEqual(status.compute_level(30 * GIB, self.total, 20, 10, "ok", btrfs), ("warn", "btrfs-metadata"))

    def test_notification_rules(self):
        send, st = status.decide_notification("warn", {}, 1000)
        self.assertTrue(send)
        send, st = status.decide_notification("warn", st, 2000)
        self.assertFalse(send)
        send, st = status.decide_notification("critical", st, 3000)
        self.assertTrue(send)
        send, st = status.decide_notification("critical", st, 3000 + 3600)
        self.assertFalse(send)
        send, st = status.decide_notification("critical", st, 3000 + 7 * 3600)
        self.assertTrue(send)
        send, st = status.decide_notification("ok", st, 50000)
        self.assertFalse(send)
        send, _ = status.decide_notification("warn", st, 50001)
        self.assertTrue(send)

    def test_parse_btrfs_usage(self):
        text = ("Overall:\n    Device size:\t\t 137918152704\n    Device unallocated:\t\t  17633902592\n"
                "    Free (estimated):\t\t  27157504000\t(min: 18340552704)\n\n"
                "Data,single: Size:109531709440, Used:99999\n\nMetadata,DUP: Size:5368709120, Used:4226220032 (78.72%)\n")
        out = status.parse_btrfs_usage(text)
        self.assertEqual(out["unallocatedBytes"], 17633902592)
        self.assertEqual(out["freeMinBytes"], 18340552704)
        self.assertEqual(out["metadataUsedBytes"], 4226220032)


class Targets(unittest.TestCase):
    def test_parse_targets(self):
        plan = cli.parse_targets(["yay-builds:a", "thumbnails", "yay-builds:b", "trash", "trash:x"])
        self.assertEqual(plan, [("yay-builds", ["a", "b"]), ("thumbnails", None), ("trash", None)])
        self.assertEqual(cli.parse_targets(["projects:Projects/a b/node_modules"]),
                         [("projects", ["Projects/a b/node_modules"])])
        with self.assertRaises(ValueError):
            cli.parse_targets(["../x"])


class Lock(FakeHome):
    def test_second_job_is_busy(self):
        with paths.op_lock():
            self.assertTrue(paths.lock_is_held())
            with self.assertRaises(paths.Busy):
                with paths.op_lock():
                    pass
        self.assertFalse(paths.lock_is_held())


if __name__ == "__main__":
    unittest.main()
