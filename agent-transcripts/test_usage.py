"""Exercise the numeric export through its real command interface."""
import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest

TOOL = sys.argv.pop(1)


class Usage(unittest.TestCase):
    def test_export_migration_incremental_and_accounting(self):
        with tempfile.TemporaryDirectory() as root:
            path = pathlib.Path(root)
            logs = path / "logs"
            logs.mkdir()
            db = path / "index.sqlite"

            def run(*args):
                return subprocess.check_output([sys.executable, TOOL, "--db", str(db), *args], text=True)

            def write(name, rows):
                (logs / name).write_text("\n".join(json.dumps(row) for row in rows) + "\n")

            def token(at, model, total, output=5):
                return [{"type": "turn_context", "payload": {"model": model}},
                        {"type": "event_msg", "timestamp": at, "payload": {
                            "type": "token_count", "info": {
                                "total_token_usage": {"input_tokens": total},
                                "last_token_usage": {"input_tokens": 10, "cached_input_tokens": 3,
                                                     "output_tokens": output, "reasoning_output_tokens": 2}}}}]

            rows = [{"type": "session_meta", "payload": {"id": "codex-one", "cwd": "/srv/src/bench"}}]
            rows += token("2026-09-01T00:00:00Z", "first", 10)
            rows += token("2026-09-01T00:00:01Z", "first", 10)
            rows += token("2026-09-01T01:00:00Z", "second", 20)
            write("codex.jsonl", rows)
            claude = {"type": "assistant", "sessionId": "claude-one", "timestamp": "2026-09-01T00:00:00Z",
                      "message": {"id": "message-one", "model": "claude", "content": [], "usage": {
                          "input_tokens": 10, "cache_read_input_tokens": 30,
                          "cache_creation_input_tokens": 20, "output_tokens": 5}}}
            write("claude.jsonl", [claude, claude])
            write("pi.jsonl", [{"type": "session", "id": "pi-one", "cwd": "/srv/src/bench"},
                               {"type": "message", "id": "pi-message", "timestamp": "2026-09-01T00:00:00Z",
                                "message": {"role": "assistant", "model": "pi-model", "content": [],
                                            "usage": {"input": 10, "cacheRead": 20, "cacheWrite": 3, "output": 4}}}])
            run("index", "--session-dir", str(logs))
            result = json.loads(run("export-usage"))
            sessions = {row["harness"]: row for row in result["sessions"]}
            self.assertEqual([r["model"] for r in sessions["codex"]["records"]], ["first", "second"])
            self.assertEqual(sessions["claude"]["records"][0]["input_tokens"], 60)
            self.assertEqual(len(sessions["claude"]["records"]), 1)
            self.assertEqual(sessions["pi"]["records"][0]["input_tokens"], 33)
            self.assertNotIn("content", json.dumps(result))
            self.assertNotIn(str(logs), json.dumps(result))
            before = db.stat().st_mtime_ns
            self.assertEqual(json.loads(run("export-usage", "--after", str(result["revision"]),
                                           "--index-id", result["index_id"]))["sessions"], [])
            self.assertEqual(before, db.stat().st_mtime_ns)
            rows += token("2026-09-01T02:00:00Z", "third", 30)
            write("codex.jsonl", rows)
            run("index", "--session-dir", str(logs))
            delta = json.loads(run("export-usage", "--after", str(result["revision"]), "--index-id", result["index_id"]))
            self.assertEqual(len(delta["sessions"]), 1)
            self.assertEqual(len(delta["sessions"][0]["records"]), 3)
            # A partial tail must not remove preceding requests.
            with (logs / "codex.jsonl").open("a") as stream:
                stream.write('{"incomplete":')
            run("index", "--session-dir", str(logs))
            self.assertEqual(len(json.loads(run("export-usage"))["sessions"][1]["records"]), 3)
            with sqlite3.connect(db) as conn:
                conn.execute("UPDATE meta SET value='2' WHERE key='schema_version'")
                conn.execute("DELETE FROM events WHERE kind='usage'")
            run("index", "--session-dir", str(logs))
            self.assertEqual(sum(len(s["records"]) for s in json.loads(run("export-usage"))["sessions"]), 5)
            self.assertEqual(len(json.loads(run("export-usage", "--after", "999", "--index-id", "replaced"))["sessions"]), 3)
            run("index", "--usage-only", "--session-dir", str(logs))
            with sqlite3.connect(db) as conn:
                self.assertEqual(conn.execute("SELECT count(*) FROM events WHERE kind!='usage'").fetchone()[0], 0)
            self.assertEqual(sum(len(s["records"]) for s in json.loads(run("export-usage"))["sessions"]), 5)
            with sqlite3.connect(db) as conn:
                conn.execute("UPDATE events SET ts=NULL WHERE model='third'")
            invalid = json.loads(run("export-usage"))
            self.assertEqual(sum(len(s["records"]) for s in invalid["sessions"]), 4)
            self.assertEqual(sum(s["invalid_records"] for s in invalid["sessions"]), 1)


if __name__ == "__main__":
    unittest.main()
