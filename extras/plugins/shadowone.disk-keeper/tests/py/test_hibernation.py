import os
import time
import unittest

from helpers import FakeHome
from test_root_helper import helper

from diskkeeper import paths, registry, rootcats

PAGE = os.sysconf("SC_PAGE_SIZE")


def swap_bytes(sig=b"SWAPSPACE2"):
    return b"\0" * (PAGE - 10) + sig + b"\0" * PAGE


class Scan(FakeHome):
    def setUp(self):
        super().setUp()
        self.saved = {k: getattr(rootcats, k) for k in
                      ("PROC_SWAPS", "FSTAB", "SWAPFILES", "RESUME_CONF", "RESUME_HOOK", "RUNNING_RESUME_OFFSET")}
        self.swapfile = os.path.join(self.tmp, "swap", "swapfile")
        os.makedirs(os.path.dirname(self.swapfile))
        with open(self.swapfile, "wb") as fh:
            fh.write(swap_bytes())
        rootcats.SWAPFILES = {"swapfile": self.swapfile, "root-swapfile": os.path.join(self.tmp, "swapfile")}
        rootcats.PROC_SWAPS = self.write("proc-swaps", "Filename Type Size Used Priority\n"
                                                        "/dev/zram0 partition 100 0 100\n")
        rootcats.FSTAB = self.write("fstab", "UUID=1 / btrfs subvol=@ 0 0\n")
        rootcats.RESUME_CONF = os.path.join(self.tmp, "resume.conf")
        rootcats.RESUME_HOOK = os.path.join(self.tmp, "omarchy_resume.conf")
        rootcats.RUNNING_RESUME_OFFSET = self.write("running-offset", "0\n")
        self.fake_tool("systemd-analyze", 'echo "[Sleep]"; echo "HibernateDelaySec=3h"')

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(rootcats, k, v)
        super().tearDown()

    def write(self, name, text):
        path = os.path.join(self.tmp, name)
        with open(path, "w") as fh:
            fh.write(text)
        return path

    def hibernation_on(self, offset=123):
        self.write("proc-swaps", "Filename Type Size Used Priority\n/dev/zram0 partition 100 0 100\n"
                                 "%s file 16 0 0\n" % self.swapfile)
        self.write("fstab", "%s none swap defaults,pri=0 0 0\n" % self.swapfile)
        self.write("resume.conf", 'KERNEL_CMDLINE[default]+=" resume=/dev/mapper/root resume_offset=%d"\n' % offset)
        self.write("omarchy_resume.conf", "HOOKS+=(resume)\n")

    def scan(self):
        return rootcats.Hibernation().scan(registry.Context(paths.load_config()))

    def items(self, data):
        return {i["key"]: i for i in data["items"]}

    def test_active_swapfile_is_shown_but_never_offered(self):
        self.hibernation_on()
        self.write("running-offset", "123\n")
        data = self.scan()
        items = self.items(data)
        self.assertEqual(list(items), ["swapfile"])
        self.assertFalse(items["swapfile"]["actionable"])
        self.assertEqual(items["swapfile"]["blocked"]["reason"], "in-use")
        self.assertEqual(data["bytes"], 0)
        self.assertIn("after 3h", data["note"])
        self.assertIsNone(rootcats.Hibernation().token(registry.Context(paths.load_config()), None))

    def test_restart_needed_until_the_boot_entry_is_in_use(self):
        self.hibernation_on(offset=123)
        self.assertEqual(self.items(self.scan())["reboot"]["blocked"]["reason"], "reboot")

    def test_resume_settings_older_than_the_swapfile(self):
        self.hibernation_on()
        old = time.time() - 3600
        os.utime(rootcats.RESUME_CONF, (old, old))
        items = self.items(self.scan())
        self.assertEqual(items["resume-stale"]["blocked"]["reason"], "stale")
        self.assertNotIn("reboot", items)

    def test_leftovers_are_offered(self):
        self.write("resume.conf", 'KERNEL_CMDLINE[default]+=" resume=/dev/mapper/root resume_offset=5"\n')
        data = self.scan()
        items = self.items(data)
        self.assertTrue(items["swapfile"]["actionable"])
        self.assertTrue(items["swapfile"]["selected"])
        self.assertTrue(items["resume"]["actionable"])
        self.assertEqual(data["bytes"], items["swapfile"]["bytes"])
        self.assertIn("left over", data["note"])
        ctx = registry.Context(paths.load_config())
        self.assertEqual(rootcats.Hibernation().token(ctx, None), "hibernation:remove=swapfile,resume")
        self.assertEqual(rootcats.Hibernation().token(ctx, ["resume", "../etc", "swapfile"]),
                         "hibernation:remove=swapfile,resume")

    def test_swapfile_in_fstab_but_off_is_not_offered(self):
        self.write("fstab", "%s none swap defaults 0 0\n" % self.swapfile)
        item = self.items(self.scan())["swapfile"]
        self.assertFalse(item["actionable"])
        self.assertEqual(item["blocked"]["reason"], "inactive")

    def test_resume_settings_stay_while_disk_swap_is_configured(self):
        os.unlink(self.swapfile)
        self.write("fstab", "UUID=abc none swap defaults 0 0\n")
        self.write("resume.conf", 'KERNEL_CMDLINE[default]+=" resume=UUID=abc"\n')
        self.assertNotIn("resume", self.items(self.scan()))

    def test_hidden_without_swapfile_or_settings(self):
        os.unlink(self.swapfile)
        self.assertFalse(self.scan()["available"])

    def test_in_registry(self):
        self.assertIn("hibernation", registry.by_id())


class Helper(FakeHome):
    def test_tokens(self):
        self.assertEqual([v for v, _ in helper.validate_tokens(["hibernation:remove=swapfile,resume"])],
                         ["hibernation"])
        helper.validate_tokens(["hibernation:remove=root-swapfile"])
        for bad in ("hibernation:remove=", "hibernation:remove=/swap/swapfile", "hibernation:remove=swapfile;rm",
                    "hibernation:remove=swapfile,resume,swapfile,resume", "hibernation"):
            with self.assertRaises(helper.UsageError):
                helper.validate_tokens([bad])

    def test_signature(self):
        fd = os.open(self.tmp, os.O_RDONLY | os.O_DIRECTORY)
        try:
            for name, content, want in (("swap", swap_bytes(), "swap"), ("image", swap_bytes(b"S1SUSPEND\0"), "image"),
                                        ("data", b"x" * PAGE * 2, None), ("short", b"SWAPSPACE2", None)):
                with open(os.path.join(self.tmp, name), "wb") as fh:
                    fh.write(content)
                self.assertEqual(helper.swap_signature(fd, name), want, name)
        finally:
            os.close(fd)

    def test_swap_lines(self):
        proc = os.path.join(self.tmp, "swaps")
        with open(proc, "w") as fh:
            fh.write("Filename Type Size Used Priority\n/dev/zram0 partition 1 0 100\n/my\\040swap file 1 0 0\n")
        self.assertEqual(helper.read_swap_lines(proc, 1, header=True), ["/dev/zram0", "/my swap"])
        fstab = os.path.join(self.tmp, "fstab")
        with open(fstab, "w") as fh:
            fh.write("# /swap/old none swap\nUUID=1 / btrfs x 0 0\n/swap/swapfile none swap pri=0 0 0\n")
        self.assertEqual(helper.read_swap_lines(fstab, 2, "swap"), ["/swap/swapfile"])

    def test_refusals(self):
        path = os.path.join(self.tmp, "swapfile")
        with open(path, "wb") as fh:
            fh.write(swap_bytes())
        self.assertIn("switched on", helper.remove_swapfile(path, [path], [], True)[1])
        self.assertIn("fstab", helper.remove_swapfile(path, [], [path], True)[1])
        self.assertIn("already gone", helper.remove_swapfile(path + "-missing", [], [], True)[1])
        if os.geteuid() != 0:
            self.assertIn("root-owned", helper.remove_swapfile(path, [], [], False)[1])
        self.assertTrue(os.path.exists(path))
        ok, msg = helper.remove_resume_settings(["/dev/zram0", "/swap/swapfile"], [], True)
        self.assertFalse(ok)
        self.assertIn("/swap/swapfile", msg)
        ok, _ = helper.remove_resume_settings(["/dev/zram0"], [], True)
        self.assertTrue(ok)


if __name__ == "__main__":
    unittest.main()
