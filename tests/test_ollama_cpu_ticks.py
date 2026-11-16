"""Ollama's CPU share is read from /proc in-process, never by forking.

burnbar-local-status used to measure it with a `sh -c` loop that ran `cat` once
per entry in /proc to read each name: about 1,140 forks on a busy desktop, twice
a run, every five seconds. Measured on gus (2026-11-16) one call cost 4.5 CPU-
seconds and 4.8 s of wall clock, which is past the call's own 4 s timeout, so the
reading was lost as well as expensive. It now walks /proc in Python.
"""
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_local_scripts import ROOT, load_script


def stat_line(pid, comm, utime, stime):
    """A /proc/<pid>/stat line: utime and stime are fields 14 and 15."""
    fields = ["S", "1", "1", "1", "0", "-1", "4194560", "100", "0", "0", "0",
              str(utime), str(stime)]
    return "%d (%s) %s 0 0 20 0 1 0 1000 0 0\n" % (pid, comm, " ".join(fields))


class OllamaCpuTicksTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.status = load_script(ROOT / "bin/burnbar-local-status", "cpu_ticks_status")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.proc = Path(self.tmp.name)

    def add(self, pid, comm, utime=0, stime=0, with_stat=True):
        d = self.proc / str(pid)
        d.mkdir()
        (d / "comm").write_text(comm + "\n")
        if with_stat:
            (d / "stat").write_text(stat_line(pid, comm, utime, stime))

    def test_only_processes_named_ollama_count_and_user_plus_system_is_summed(self):
        self.add(100, "ollama", utime=40, stime=2)
        self.add(101, "ollama", utime=10, stime=8)
        self.add(102, "bash", utime=9999, stime=9999)
        (self.proc / "self").mkdir()           # not a pid
        (self.proc / "stat").write_text("not a directory of ticks\n")
        self.assertEqual(self.status.ollama_ticks(str(self.proc)), 60)

    def test_a_process_that_exits_mid_read_is_skipped_not_fatal(self):
        self.add(100, "ollama", utime=5, stime=5)
        self.add(101, "ollama", with_stat=False)   # comm readable, stat already gone
        self.assertEqual(self.status.ollama_ticks(str(self.proc)), 10)

    def test_a_truncated_stat_line_counts_nothing(self):
        self.add(100, "ollama")
        (self.proc / "100" / "stat").write_text("100 (ollama) S 1 2\n")
        self.assertEqual(self.status.ollama_ticks(str(self.proc)), 0)

    def test_a_missing_proc_is_zero(self):
        self.assertEqual(self.status.ollama_ticks(str(self.proc / "nope")), 0)

    def test_all_cpu_ticks_sums_user_through_softirq_only(self):
        f = self.proc / "stat"
        f.write_text("cpu  10 20 30 40 50 60 70 80 90 100\ncpu0 1 1 1 1 1 1 1 1 1 1\n")
        # user nice system idle iowait irq softirq = the first seven; steal and
        # guest are left out, as the shell version left them out.
        self.assertEqual(self.status.all_cpu_ticks(str(f)), 10 + 20 + 30 + 40 + 50 + 60 + 70)

    def test_all_cpu_ticks_survives_a_missing_or_garbled_file(self):
        self.assertEqual(self.status.all_cpu_ticks(str(self.proc / "nope")), 0)
        f = self.proc / "stat"
        f.write_text("cpu  a b c\n")
        self.assertEqual(self.status.all_cpu_ticks(str(f)), 0)

    def share(self, mine, everyone):
        """local_ollama_cpu() with the two samples faked: (mine, everyone) before and after."""
        with mock.patch.object(self.status, "ollama_ticks", side_effect=[mine[0], mine[1]]), \
             mock.patch.object(self.status, "all_cpu_ticks", side_effect=[everyone[0], everyone[1]]), \
             mock.patch.object(self.status.time, "sleep"):
            return self.status.local_ollama_cpu()

    def test_the_share_is_ollama_ticks_over_all_ticks(self):
        self.assertEqual(self.share((100, 130), (1000, 1120)), 25.0)      # 30 of 120

    def test_it_never_reads_over_100_or_below_0(self):
        self.assertEqual(self.share((0, 500), (0, 100)), 100.0)
        self.assertEqual(self.share((500, 100), (0, 100)), 0.0)            # a process exited mid-sample

    def test_no_elapsed_ticks_is_zero_not_a_division_error(self):
        self.assertEqual(self.share((5, 5), (900, 900)), 0.0)

    def test_it_does_not_fork(self):
        """The whole point: no subprocess of any kind to measure one process."""
        with mock.patch.object(self.status.subprocess, "run", side_effect=AssertionError("forked")), \
             mock.patch.object(self.status.subprocess, "Popen", side_effect=AssertionError("forked")), \
             mock.patch.object(self.status.time, "sleep"):
            value = self.status.local_ollama_cpu()
        self.assertGreaterEqual(value, 0.0)
        self.assertLessEqual(value, 100.0)


if __name__ == "__main__":
    unittest.main()
