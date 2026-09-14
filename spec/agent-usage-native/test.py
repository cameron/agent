import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

root = Path(sys.argv.pop())
loader = importlib.machinery.SourceFileLoader("usage_claude", str(root / "libexec/agent/usage-claude"))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
NOW = 1789286400
LIMITS = {"limits": [
    {"kind": "weekly_all", "percent": 30, "scope": None,
     "resets_at": "2026-09-20T05:00:00Z", "is_active": False},
    {"kind": "weekly_scoped", "percent": 70, "scope": {"model": {"display_name": "Fable"}},
     "resets_at": "2026-09-20T05:00:00+00:00", "is_active": False},
]}


class NativeUsage(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        patch = mock.patch.dict(os.environ, {
            "XDG_CACHE_HOME": str(self.base / "cache"), "CLAUDE_CONFIG_DIR": str(self.base / "claude"),
        })
        patch.start()
        self.addCleanup(patch.stop)
        self.collector = module.Collector(900, NOW)
        self.collector.wall = NOW
        self.collector.config.parent.mkdir()

    def native(self, account="one", snapshot_account=None, fetched=NOW):
        module.write_json(self.collector.config, {
            "oauthAccount": {"accountUuid": account},
            "cachedUsageUtilization": {"accountUuid": snapshot_account or account,
                                       "fetchedAtMs": fetched * 1000, "utilization": LIMITS},
        })

    def test_fresh_native_snapshot_needs_no_cli_or_credentials(self):
        self.native()
        credentials = self.collector.config.parent / ".credentials.json"
        credentials.write_text("not even JSON: only Claude may read this")
        with mock.patch.object(self.collector, "fetch") as fetch:
            self.assertEqual({item["label"] for item in self.collector.collect()}, {"claude", "fable"})
            fetch.assert_not_called()
        self.assertEqual(credentials.read_text(), "not even JSON: only Claude may read this")

    def test_account_switch_and_logout_drop_old_values(self):
        self.native()
        self.collector.collect()
        for account in ("two", None):
            self.native(account=account, snapshot_account="one")
            with mock.patch.object(self.collector, "fetch", side_effect=ValueError("claude-usage-failed")):
                self.assertEqual(self.collector.collect(), [])
            self.assertEqual(module.read_json(self.collector.cache), [])

    def test_failure_backoff_grows_and_readers_do_not_extend_it(self):
        with mock.patch.object(self.collector, "fetch", side_effect=ValueError("claude-timeout")) as fetch:
            for expected_delay in (900, 1800, 3600, 3600):
                self.collector.collect()
                state = module.read_json(self.collector.state_path)
                self.assertEqual(state["retry_after"], self.collector.wall + expected_delay)
                before = fetch.call_count
                self.collector.collect()
                self.collector.diagnose()
                self.assertEqual(fetch.call_count, before)
                self.assertEqual(module.read_json(self.collector.state_path), state)
                self.collector.wall = state["retry_after"] + 1
        self.native(fetched=self.collector.wall)
        with mock.patch.object(self.collector, "fetch") as fetch:
            self.assertEqual(len(self.collector.collect()), 2)
            fetch.assert_not_called()
        self.assertIsNone(module.read_json(self.collector.state_path)["last_error"])

    def test_zero_turn_success_requires_a_fresh_native_snapshot(self):
        self.native(fetched=1)
        with mock.patch.object(self.collector, "fetch"):
            self.assertEqual(self.collector.collect(), [])
        self.assertEqual(module.read_json(self.collector.state_path)["last_error"], "stale-native-usage")

    def test_corrupt_cache_is_repaired_from_native_data(self):
        self.native()
        self.collector.collect()
        self.collector.cache.write_text("{partial")
        with mock.patch.object(self.collector, "fetch") as fetch:
            self.assertEqual(len(self.collector.collect()), 2)
            fetch.assert_not_called()

    def test_cli_failures_are_bounded_and_diagnostic(self):
        self.collector.root.mkdir(parents=True)
        for error, message in ((FileNotFoundError(), "claude-not-found"),
                               (subprocess.TimeoutExpired("claude", 30), "claude-timeout")):
            with mock.patch.object(subprocess, "run", side_effect=error):
                with self.assertRaisesRegex(ValueError, message):
                    self.collector.fetch()
        result = subprocess.CompletedProcess([], 0, json.dumps({"is_error": False, "num_turns": 1}))
        with mock.patch.object(subprocess, "run", return_value=result):
            with self.assertRaisesRegex(ValueError, "claude-usage-failed"):
                self.collector.fetch()


unittest.main()
