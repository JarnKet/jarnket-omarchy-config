import json
import os
import unittest

from helpers import GIB, Case, uuid

from memkeeper import actions, meminfo, sessions
from memkeeper import state as st
from memkeeper.procs import Table

HOUR = 3600


def read_file(path):
    with open(path) as fh:
        return fh.read()


def write_file(path, text):
    with open(path, "w") as fh:
        fh.write(text)


class Rules(Case):
    def first_tick_then_wait(self, hours):
        """The first tick starts every clock at zero, then awake time passes."""
        first = actions.tick(self.env)
        self.assertEqual(first["stopped"], [])
        self.env.now_wall += hours * HOUR
        self.env.now_mono += hours * HOUR
        return actions.tick(self.env)

    def test_nothing_stops_on_the_first_tick_however_old(self):
        self.env.add_session(10, 1, idle_seconds=100 * HOUR)
        result = actions.tick(self.env)
        self.assertEqual(result["stopped"], [])
        self.assertEqual(self.env.signals, [])

    def test_stops_after_the_limit_in_awake_time(self):
        self.env.add_session(10, 1, idle_seconds=HOUR)
        self.assertEqual(self.first_tick_then_wait(11)["stopped"], [])
        self.env.now_wall += 2 * HOUR
        self.env.now_mono += 2 * HOUR
        result = actions.tick(self.env)
        self.assertEqual([r["sessionId"] for r in result["stopped"]], [uuid(1)])
        self.assertEqual(self.env.signals, [10])

    def test_time_asleep_does_not_count(self):
        self.env.add_session(10, 1, idle_seconds=HOUR)
        actions.tick(self.env)
        self.env.now_wall += 40 * HOUR  # the lid was closed: wall moves, monotonic does not
        self.assertEqual(actions.tick(self.env)["stopped"], [])
        self.assertEqual(self.env.signals, [])

    def test_a_new_turn_restarts_the_clock(self):
        self.env.add_session(10, 1, idle_seconds=HOUR)
        actions.tick(self.env)
        self.env.now_wall += 11 * HOUR
        self.env.now_mono += 11 * HOUR
        actions.tick(self.env)
        path = os.path.join(self.env.sessions_dir, "10.json")
        d = json.loads(read_file(path))
        d["statusUpdatedAt"] = (self.env.now_wall - 60) * 1000
        write_file(path, json.dumps(d))
        actions.tick(self.env)
        self.env.now_wall += 2 * HOUR
        self.env.now_mono += 2 * HOUR
        self.assertEqual(actions.tick(self.env)["stopped"], [])

    def test_guards(self):
        self.env.add_session(10, 1, status="busy")
        self.env.add_session(11, 2, status="waiting")
        self.env.add_session(12, 3, kind="sdk")
        self.env.add_session(13, 4, terminal="")
        self.env.add_session(14, 5)  # keep
        self.env.add_session(15, 6)  # background work
        self.env.add_proc(151, ppid=15, comm="bash", cmdline=("bash", "-c", "source /h/.claude/shell-snapshots/x.sh && pnpm dev"))
        self.env.add_proc(152, ppid=151, comm="pnpm", cmdline=("pnpm", "dev"))
        self.env.add_session(16, 7)  # unknown child
        self.env.add_proc(161, ppid=16, comm="mystery", cmdline=("mystery",))
        self.env.add_session(17, 8, tab="tb-visible")
        self.env.add_session(18, 9)  # terminal runs something else
        self.env.terminals["t9"]["foreground"]["pid"] = 999
        self.env.add_session(19, 10)  # only an MCP server beside it: stops
        self.env.add_proc(191, ppid=19, comm="npm exec foo", cmdline=("npm", "exec", "foo-mcp"))
        write_file(self.env.view_file, json.dumps({"active": "sp1", "spaces": {"sp1": "tb-visible"}}))
        st.save_config({"keep": [uuid(5)]})
        result = self.first_tick_then_wait(13)
        self.assertEqual([r["sessionId"] for r in result["stopped"]], [uuid(10)])
        self.assertEqual(self.env.signals, [19])
        blocks = {s["name"]: s["block"] for s in result["sessions"]}
        self.assertEqual(blocks["s1"], None)  # busy is not past the limit, so not even asked
        table = Table(self.env.proc)
        by_name = {s["name"]: s for s in sessions.load(self.env, table)}
        reason = lambda n: sessions.block_reason(self.env, table, by_name[n], [uuid(5)])
        self.assertEqual(reason("s1"), "busy")
        self.assertEqual(reason("s2"), "waiting")
        self.assertEqual(reason("s3"), "not-interactive")
        self.assertEqual(reason("s4"), "not-herdr")
        self.assertEqual(reason("s5"), "keep")
        self.assertEqual(reason("s6"), "running-work")
        self.assertEqual(reason("s7"), "running-work")
        self.assertEqual(reason("s8"), "on-screen")
        self.assertEqual(reason("s9"), "terminal-unknown")

    def test_wrapper_shell_in_the_foreground_is_fine(self):
        self.env.add_proc(50, comm="bash", cmdline=("bash", "-c", "claude --resume x; exec bash"))
        self.env.add_session(10, 1)
        os.unlink(os.path.join(self.env.proc, "10", "stat"))
        tail = ["S", "50", "0", "0", "5"] + ["0"] * 14 + ["1000"] + ["0"] * 10
        write_file(os.path.join(self.env.proc, "10", "stat"), "10 (claude) %s\n" % " ".join(tail))
        self.env.terminals["t1"]["foreground"]["pid"] = 50
        table = Table(self.env.proc)
        s = sessions.load(self.env, table)[0]
        self.assertIsNone(sessions.block_reason(self.env, table, s, []))

    def test_reused_pid_is_ignored(self):
        self.env.add_session(10, 1)
        d = json.loads(read_file(os.path.join(self.env.sessions_dir, "10.json")))
        d["procStart"] = "2222"
        write_file(os.path.join(self.env.sessions_dir, "10.json"), json.dumps(d))
        self.assertEqual(sessions.load(self.env, Table(self.env.proc)), [])

    def test_auto_off_stops_nothing(self):
        st.save_config({"auto": False})
        self.env.add_session(10, 1)
        self.assertEqual(self.first_tick_then_wait(50)["stopped"], [])

    def test_dry_run_changes_nothing(self):
        self.env.add_session(10, 1)
        actions.tick(self.env)
        self.env.now_wall += 13 * HOUR
        self.env.now_mono += 13 * HOUR
        result = actions.tick(self.env, dry_run=True)
        self.assertTrue(result["sessions"][0]["due"])
        self.assertEqual(self.env.signals, [])
        self.assertEqual(self.env.calls.count(["hc", "read", "t1", "--json"]), 0)

    def test_a_quiet_tick_starts_no_process(self):
        self.env.add_session(10, 1)
        actions.tick(self.env)
        self.assertEqual(self.env.calls, [])

    def test_pressure_shortens_the_limit(self):
        self.env.add_session(10, 1)
        actions.tick(self.env)
        self.env.now_mono += 4 * HOUR
        self.env.now_wall += 4 * HOUR
        self.assertEqual(actions.tick(self.env)["stopped"], [])
        self.env.write_meminfo(available=5 * GIB)  # under 20%
        self.assertEqual(len(actions.tick(self.env)["stopped"]), 1)

    def test_critical_uses_the_shortest_limit_and_warns(self):
        self.env.add_session(10, 1)
        actions.tick(self.env)
        self.env.now_mono += 1.1 * HOUR
        self.env.now_wall += 1.1 * HOUR
        self.env.write_meminfo(available=2 * GIB)
        self.assertEqual(len(actions.tick(self.env)["stopped"]), 1)
        sent = [c for c in self.env.calls if c[0] == "omarchy-notification-send"]
        self.assertEqual(len(sent), 2)
        self.assertIn("Stopped an idle Claude session", sent[0])
        self.assertIn("Memory is running out", sent[1])
        self.env.calls.clear()
        actions.tick(self.env)  # no repeat within six hours
        self.assertEqual([c for c in self.env.calls if c[0] == "omarchy-notification-send"], [])


class Stop(Case):
    def test_saves_the_input_box_and_sends_one_term(self):
        sid = self.env.add_session(10, 1, pss_kb=200_000, swap_kb=56_000)
        rule = "─" * 40
        self.env.screens["t1"] = "\n".join(["old output", rule, "❯ ກວດ", rule, "  auto mode on"])
        table = Table(self.env.proc)
        r = actions.stop_session(self.env, table, sessions.load(self.env, table)[0], "manual")
        self.assertTrue(r["ok"])
        self.assertEqual(self.env.signals, [10])
        self.assertEqual(r["freedBytes"], 256_000 * 1024)
        entry = actions.read_stopped()[0]
        self.assertEqual(entry["sessionId"], sid)
        self.assertEqual(entry["inputText"], "ກວດ")
        self.assertEqual(entry["space"], "sp1")
        self.assertEqual(st.read_history()[0]["event"], "stopped")
        # Nothing was typed into Claude.
        self.assertFalse([c for c in self.env.calls if c[:2] in (["hc", "send"], ["hc", "keys"], ["hc", "kill"])])

    def test_a_session_that_ignores_term_is_reported_not_forced(self):
        self.env.add_session(10, 1)
        self.env.ignores_term.add(10)
        table = Table(self.env.proc)
        r = actions.stop_session(self.env, table, sessions.load(self.env, table)[0], "manual")
        self.assertFalse(r["ok"])
        self.assertEqual(self.env.signals, [10])
        self.assertEqual(actions.read_stopped(), [])

    def test_manual_refuses_busy_but_allows_waiting(self):
        self.env.add_session(10, 1, status="busy")
        self.env.add_session(11, 2, status="waiting")
        self.assertFalse(actions.stop_manual(self.env, uuid(1))["ok"])
        self.assertTrue(actions.stop_manual(self.env, uuid(2))["ok"])
        self.assertEqual(self.env.signals, [11])

    def test_stop_idle_now_goes_by_the_clock_with_the_same_guards(self):
        self.env.add_session(10, 1, idle_seconds=2 * HOUR)
        self.env.add_session(11, 2, idle_seconds=60)
        self.env.add_session(12, 3, idle_seconds=2 * HOUR, status="waiting")
        results = actions.stop_idle_now(self.env)
        self.assertEqual([r["sessionId"] for r in results], [uuid(1)])

    def test_input_box_parsing(self):
        rule = "─" * 30
        self.assertEqual(sessions.input_text("\n".join([rule, "❯ ", rule, "footer"])), "")
        self.assertEqual(sessions.input_text("\n".join([rule, "❯ one", "  two", rule, "footer"])), "one\ntwo")
        self.assertEqual(sessions.input_text("no box here"), "")


class Resume(Case):
    def stopped(self, **extra):
        entry = {"sessionId": uuid(1), "name": "s1", "cwd": self.tmp, "terminal": "t1", "space": "sp1", "stoppedAt": self.env.now_wall}
        entry.update(extra)
        st.write_json(actions._stopped_path(), [entry])

    def test_same_tab_when_a_shell_waits_there(self):
        self.stopped()
        self.env.terminals["t1"] = {"state": "live", "foreground": {"name": "bash", "pid": 5}}
        r = actions.resume(self.env, uuid(1))
        self.assertEqual(r["where"], "same tab")
        sent = [c for c in self.env.calls if c[:2] == ["hc", "send"]][0]
        self.assertEqual(sent[2], "t1")
        self.assertTrue(sent[3].endswith("&& claude --resume " + uuid(1)))

    def test_never_types_into_a_running_program(self):
        self.stopped()
        self.env.terminals["t1"] = {"state": "live", "foreground": {"name": "vim", "pid": 5}}
        r = actions.resume(self.env, uuid(1))
        self.assertEqual(r["where"], "new tab")
        self.assertFalse([c for c in self.env.calls if c[:2] == ["hc", "send"]])

    def test_new_tab_falls_back_when_the_space_is_gone(self):
        self.stopped(terminal=None)
        self.env.run_fails.add(("herdr-app", "do", "tab.new"))
        r = actions.resume(self.env, uuid(1))
        self.assertFalse(r["ok"])
        self.assertIn(uuid(1), r["command"])

    def test_a_live_session_is_only_focused(self):
        self.env.add_session(10, 1)
        r = actions.resume(self.env, uuid(1))
        self.assertTrue(r["already"])
        self.assertIn(["herdr-app", "do", "agent.focus", "--terminal", "t1"], self.env.calls)

    def test_resumed_sessions_leave_the_list(self):
        self.stopped()
        self.assertEqual(len(actions.current_stopped(set(), self.env.now_wall)), 1)
        self.assertEqual(actions.current_stopped({uuid(1)}, self.env.now_wall), [])
        self.assertEqual(actions.current_stopped(set(), self.env.now_wall + 15 * 24 * HOUR), [])


class Memory(Case):
    def cfg(self, **kw):
        return st.clamp_config(kw)

    def test_levels(self):
        mem = meminfo.read(self.env.proc)
        self.assertEqual(meminfo.level(mem, self.cfg()), ("ok", []))
        self.env.write_meminfo(available=5 * GIB)
        self.assertEqual(meminfo.level(meminfo.read(self.env.proc), self.cfg())[0], "warn")
        self.env.write_meminfo(available=2 * GIB)
        self.assertEqual(meminfo.level(meminfo.read(self.env.proc), self.cfg())[0], "critical")
        self.env.write_meminfo(swap_used=22 * GIB)
        self.assertEqual(meminfo.level(meminfo.read(self.env.proc), self.cfg())[0], "warn")
        self.env.write_meminfo(swap_used=27 * GIB)
        self.assertEqual(meminfo.level(meminfo.read(self.env.proc), self.cfg())[0], "critical")
        self.env.write_meminfo(psi_full=30)
        self.assertEqual(meminfo.level(meminfo.read(self.env.proc), self.cfg()), ("critical", ["stalling"]))

    def test_no_swap_is_not_a_division_by_zero(self):
        self.env.write_meminfo(swap_total=0, swap_used=0)
        self.assertEqual(meminfo.level(meminfo.read(self.env.proc), self.cfg())[0], "ok")

    def test_config_is_clamped_and_consistent(self):
        cfg = st.clamp_config({"idleHours": 2, "warnIdleHours": 9, "criticalIdleHours": 50, "criticalAvailablePercent": 40, "auto": "x", "keep": ["bad", uuid(1)]})
        self.assertEqual((cfg["warnIdleHours"], cfg["criticalIdleHours"]), (2, 2))
        self.assertEqual(cfg["criticalAvailablePercent"], 20)
        self.assertTrue(cfg["auto"])
        self.assertEqual(cfg["keep"], [uuid(1)])

    def _slice(self, inactive):
        write_file(os.path.join(self.env.app_slice, "memory.stat"), "anon 5\ninactive_file %d\n" % inactive)
        write_file(os.path.join(self.env.app_slice, "memory.reclaim"), "")

    def test_reclaim_is_file_only_and_takes_at_most_half(self):
        self._slice(GIB)
        asked, error = meminfo.reclaim(self.env.app_slice, 4 * GIB)
        self.assertIsNone(error)
        self.assertEqual(asked, GIB // 2)
        text = read_file(os.path.join(self.env.app_slice, "memory.reclaim"))
        self.assertIn("swappiness=0", text)

    def test_reclaim_respects_the_cap(self):
        self._slice(20 * GIB)
        self.assertEqual(meminfo.reclaim(self.env.app_slice, GIB)[0], GIB)

    def test_reclaim_without_the_file_is_an_error_not_a_crash(self):
        self.assertEqual(meminfo.reclaim(self.env.app_slice, GIB)[0], 0)
        self.assertIsNotNone(meminfo.reclaim(self.env.app_slice, GIB)[1])

    def test_warn_alone_does_not_reclaim_stalls_do(self):
        cfg = self.cfg()
        self.assertFalse(meminfo.should_reclaim("ok", {"psiSome": 50}, cfg))
        self.assertFalse(meminfo.should_reclaim("warn", {"psiSome": 1}, cfg))
        self.assertTrue(meminfo.should_reclaim("warn", {"psiSome": 6}, cfg))
        self.assertTrue(meminfo.should_reclaim("critical", {"psiSome": 0}, cfg))


class Leftovers(Case):
    def add(self, pid, comm="npm exec wrangl", ppid=1, tty=0, start=100, cgroup="0::/app.slice/hc-hold-1.service", text=None):
        self.env.add_proc(pid, ppid=ppid, comm=comm, cmdline=text or (comm,), tty=tty, start=start, cgroup=cgroup, pss_kb=1000)

    def test_only_old_adopted_dev_tools_outside_services(self):
        self.add(20)
        self.add(21, comm="node-MainThread", tty=5)  # has a terminal
        self.add(22, comm="node-MainThread", ppid=99)  # has a parent
        self.add(23, comm="brave")  # not a dev tool
        self.add(24, start=500_000 * 100)  # too young
        self.add(25, cgroup="0::/app.slice/barcode-bridge.service")  # the user's service
        self.add(26, text=("python3", "/h/.config/omarchy/plugins/x/serve"), comm="node")  # a plugin's helper
        self.add(27, comm="nextcloud")  # only looks like `next`
        got = actions.leftovers(self.env, Table(self.env.proc))
        self.assertEqual([e["pid"] for e in got], [20])

    def test_stop_refuses_anything_not_on_the_list(self):
        self.add(20)
        self.add(23, comm="brave")
        self.assertFalse(actions.stop_leftover(self.env, 23, 100)["ok"])
        self.assertFalse(actions.stop_leftover(self.env, 20, 999)["ok"])
        self.assertEqual(self.env.signals, [])
        self.assertTrue(actions.stop_leftover(self.env, 20, 100)["ok"])
        self.assertEqual(self.env.signals, [20])


class Scan(Case):
    def test_scan_shape(self):
        self.env.add_session(10, 1, idle_seconds=5 * HOUR, pss_kb=2048)
        self.env.add_session(11, 2, status="busy")
        d = actions.scan(self.env)
        self.assertEqual(d["kind"], "scan")
        self.assertEqual([s["name"] for s in d["sessions"]], ["s1", "s2"])
        self.assertAlmostEqual(d["sessions"][0]["wallIdleSeconds"], 5 * HOUR)
        self.assertEqual(d["sessions"][0]["bytes"], 2048 * 1024)
        self.assertEqual(d["sessions"][1]["block"], "busy")
        self.assertEqual(d["sessions"][1]["stopsInSeconds"], None)
        self.assertEqual(d["apps"][0]["name"], "Claude Code")
        json.dumps(d)


class Forbidden(unittest.TestCase):
    def test_the_code_never_does_these(self):
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "backend", "memkeeper")
        for name in os.listdir(root):
            if not name.endswith(".py"):
                continue
            src = read_file(os.path.join(root, name))
            body = "\n".join(line for line in src.splitlines() if not line.lstrip().startswith("#"))
            code = body.split('"""', 2)[-1] if body.lstrip().startswith('"""') else body
            for word in ("drop_caches", "SIGKILL", "swapoff", '"keys"', '"kill"', "sudo", "pkexec"):
                self.assertNotIn(word, code, name)


if __name__ == "__main__":
    unittest.main()
