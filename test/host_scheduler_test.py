import datetime as dt
import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch

SOURCE = pathlib.Path(__file__).resolve().parents[1] / "assets/host/scheduler.py"
spec = importlib.util.spec_from_file_location("scheduler", SOURCE)
scheduler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scheduler)


class SchedulerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dazzle-schedules-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.store = scheduler.Store(self.root / "a")
        self.addCleanup(self.store.close)
        self.now = dt.datetime(2026, 9, 13, 12, tzinfo=dt.timezone.utc).timestamp()
        self.job = dict(id="job1", revision=0, title="Daily review", directory=str(self.root), agent="codex",
                        model="", prompt="Review changes", repeat="daily", date="", time="13:00", timezone="UTC", timeout=60)

    def save(self, job=None):
        with patch.object(scheduler.shutil, "which", return_value="/bin/agent"):
            return self.store.save(job or self.job, self.now)

    def test_roundtrip_revision_and_owner_isolation(self):
        self.save()
        self.assertEqual(self.store.dispatch("list", {})["items"][0]["title"], "Daily review")
        with self.assertRaisesRegex(ValueError, "changed"):
            self.save()
        other = scheduler.Store(self.root / "b")
        self.addCleanup(other.close)
        self.assertEqual(other.dispatch("list", {})["items"], [])

    def test_disable_retains_jobs_history_and_deduplicates_runs(self):
        self.save()
        run, fresh = self.store.claim("job1", "manual:request1", self.now)
        self.assertTrue(fresh)
        self.assertEqual(self.store.claim("job1", "manual:request1", self.now), (run, False))
        self.store.dispatch("pause_scope", {})
        with self.assertRaisesRegex(ValueError, "paused"):
            self.store.claim("job1", "manual:request2", self.now)
        self.assertEqual(len(self.store.dispatch("history", {})["items"]), 1)
        self.assertEqual(len(self.store.dispatch("list", {})["items"]), 1)
        self.store.dispatch("resume_scope", {})
        self.assertTrue(self.store.claim("job1", "manual:request2", self.now)[1])

    def test_missed_occurrence_is_recorded_not_launched(self):
        self.save()
        due = self.store.dispatch("list", {})["items"][0]["next_due"]
        _, fresh = self.store.claim("job1", str(int(due)), due + 400, automatic=True)
        self.assertFalse(fresh)
        self.assertEqual(self.store.dispatch("history", {})["items"][0]["status"], "missed")
        self.assertGreater(self.store.dispatch("list", {})["items"][0]["next_due"], due)

    def test_dst_gap_skips_nonexistent_daily_time(self):
        job = {**self.job, "timezone": "America/New_York", "time": "02:30"}
        before = dt.datetime(2026, 3, 8, 5, tzinfo=dt.timezone.utc).timestamp()
        due = scheduler.next_due(job, before)
        self.assertEqual(dt.datetime.fromtimestamp(due, dt.timezone.utc), dt.datetime(2026, 3, 9, 6, 30, tzinfo=dt.timezone.utc))

    def test_invalid_input_cannot_be_a_command(self):
        for changes in [{"agent": "codex; touch /tmp/no"}, {"time": "29:00"}, {"timezone": "../../etc/passwd"}, {"timeout": -1}]:
            with self.assertRaises(ValueError):
                self.save({**self.job, **changes})

    def test_future_schema_is_not_reset(self):
        root = self.root / "future"
        future = scheduler.Store(root)
        future.db.execute("PRAGMA user_version=99")
        future.close()
        with self.assertRaisesRegex(ValueError, "Unsupported"):
            scheduler.Store(root)

    def test_agent_worker_uses_prompt_unchanged_and_bounds_output(self):
        self.save()
        run_id, _ = self.store.claim("job1", "manual:worker", self.now)
        original = scheduler.subprocess.Popen
        def process(command, **kwargs):
            self.assertEqual(command, ["codex", "exec", "--json", "-"])
            self.assertEqual(kwargs["stdin"].read(), b"Review changes")
            kwargs["stdin"].seek(0)
            return original([scheduler.sys.executable, "-c", "print('x' * 100000)"], **kwargs)
        with patch.object(scheduler.subprocess, "Popen", side_effect=process):
            scheduler.worker(self.store.root, run_id)
        output = self.store.dispatch("output", {"id": run_id})
        self.assertEqual(output["status"], "completed")
        self.assertEqual(output["bytes"], scheduler.MAX_OUTPUT)

    def test_disable_cancels_queued_worker_without_starting_agent(self):
        self.save()
        run_id, _ = self.store.claim("job1", "manual:queued", self.now)
        self.store.dispatch("pause_scope", {})
        with patch.object(scheduler.subprocess, "Popen") as process:
            scheduler.worker(self.store.root, run_id)
            process.assert_not_called()
        self.assertEqual(self.store.dispatch("output", {"id": run_id})["status"], "canceled")
        self.assertEqual(len(self.store.dispatch("list", {})["items"]), 1)

    def test_failed_systemd_launch_is_durable_and_never_replayed(self):
        self.save()
        run_id, _ = self.store.claim("job1", "manual:failed", self.now)
        with patch.object(scheduler.subprocess, "run", side_effect=scheduler.subprocess.CalledProcessError(1, "systemd-run")):
            with self.assertRaises(scheduler.subprocess.SubprocessError):
                scheduler.launch(self.store, run_id)
        self.assertEqual(self.store.dispatch("output", {"id": run_id})["status"], "failed")
        self.assertEqual(self.store.claim("job1", "manual:failed", self.now), (run_id, False))

    def test_timer_recovery_retains_interrupted_runs(self):
        self.save()
        run_id, _ = self.store.claim("job1", "manual:interrupted", self.now - 300)
        self.store.dispatch("pause_scope", {})
        with patch.object(scheduler.time, "time", return_value=self.now):
            scheduler.tick(self.store.root)
        self.assertEqual(self.store.dispatch("output", {"id": run_id})["status"], "interrupted")

    def test_invalid_utf8_output_remains_wire_bounded(self):
        self.save()
        run_id, _ = self.store.claim("job1", "manual:invalid", self.now)
        scheduler.atomic_write(self.store.root / (run_id + ".log"), b"\xff" * scheduler.MAX_OUTPUT)
        output = self.store.dispatch("output", {"id": run_id})
        self.assertLessEqual(len(output["text"].encode()), scheduler.MAX_OUTPUT)

    def test_setup_writes_only_scoped_runner_and_valid_systemd_units(self):
        root = self.root / 'state/dazzle/scheduler' / ('a' * 64)
        config = self.root / 'config'
        capability = dict(supported=True, agents=['codex'], timezone='UTC', api_version=1)
        with patch.object(scheduler, 'probe', return_value=capability), \
                patch.dict(scheduler.os.environ, {'XDG_CONFIG_HOME': str(config)}), \
                patch.object(scheduler.subprocess, 'run') as execute:
            result = scheduler.setup(root, SOURCE.read_text())
        self.assertTrue(result['timer_active'])
        self.assertEqual((root / 'runner.py').read_bytes(), SOURCE.read_bytes())
        self.assertEqual(execute.call_count, 2)
        self.assertEqual(execute.call_args.args[0], ['systemctl', '--user', 'enable', '--now', 'dazzle-schedule-' + root.name + '.timer'])
        files = sorted((config / 'systemd/user').iterdir())
        self.assertEqual(len(files), 2)
        if scheduler.shutil.which('systemd-analyze'):
            runtime = self.root / 'runtime'
            runtime.mkdir(mode=0o700)
            environment = {**scheduler.os.environ, 'XDG_RUNTIME_DIR': str(runtime)}
            verified = scheduler.subprocess.run(['systemd-analyze', '--user', '--man=no', 'verify', *map(str, files)], capture_output=True, text=True, env=environment)
            self.assertEqual(verified.returncode, 0, verified.stderr)


if __name__ == "__main__":
    unittest.main()
