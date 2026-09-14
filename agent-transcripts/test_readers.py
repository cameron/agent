"""Behavior shared by indexed audits, live tails, and session observation."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("agent_transcripts", sys.argv.pop(1))
transcripts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transcripts)


class Readers(unittest.TestCase):
    def test_user_text_agrees_between_index_and_live_readers(self):
        message = "Read the router guide.\nThen check the config."
        fixtures = {
            "codex": [
                {"type": "session_meta", "payload": {"id": "one", "cwd": "/project"}},
                {"type": "event_msg", "payload": {"type": "user_message", "message": message}},
                {"type": "response_item", "payload": {"type": "message", "role": "user",
                    "content": [{"type": "input_text", "text": message}]}},
            ],
            "claude": [
                {"type": "system", "sessionId": "one", "cwd": "/project"},
                {"type": "user", "sessionId": "one", "message": {"content": [{"type": "text", "text": message}]}},
            ],
            "pi": [
                {"type": "session", "id": "one", "cwd": "/project"},
                {"type": "message", "message": {"role": "user", "content": message}},
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session.jsonl"
            for harness, records in fixtures.items():
                with self.subTest(harness=harness):
                    path.write_text("\n".join(map(json.dumps, records)) + "\n")
                    session = transcripts.parse_file(path)
                    self.assertEqual(transcripts.transcript_metadata(path), (harness, "one", "/project"))
                    self.assertEqual([event["detail"] for event in session.events if event["kind"] == "user"], [message])
                    self.assertEqual(transcripts.tail_items(path, harness, 1)[0]["detail"], message)
                    self.assertEqual(transcripts.user_text(harness, records[1]), message)

    def test_claude_metadata_and_tool_results_are_not_user_prompts(self):
        for flag in ["isMeta", "isSidechain", "toolUseResult"]:
            record = {"type": "user", "sessionId": "one", flag: True,
                      "message": {"content": "not a user request"}}
            self.assertEqual(transcripts.user_text("claude", record), "")
            self.assertEqual(transcripts.claude_tail_items([record]), [])
            session = transcripts.Session("session.jsonl", "claude")
            transcripts.parse_claude(session, [record])
            self.assertEqual(session.turn, 0)
        tool_result = {"type": "user", "sessionId": "one", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "call", "content": "file content"}]}}
        session = transcripts.Session("session.jsonl", "claude")
        transcripts.parse_claude(session, [tool_result])
        self.assertEqual(session.chars_by_call["call"], len("file content"))
        self.assertEqual(session.turn, 0)

    def test_partial_append_preserves_utf8_and_does_not_repeat_records(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session.jsonl"
            header = b'{"type":"session","id":"one","cwd":"/project"}\n'
            record = json.dumps({"type": "message", "message": {
                "role": "user", "content": "Check caf\u00e9 settings"}}, ensure_ascii=False).encode() + b"\n"
            cut = record.index(b"\xc3") + 1
            path.write_bytes(header + record[:cut])
            rows, offset = transcripts.appended_records(path, 0)
            self.assertEqual(len(rows), 1)
            self.assertEqual(offset, len(header))
            with path.open("ab") as stream:
                stream.write(record[cut:])
            rows, offset = transcripts.appended_records(path, offset)
            self.assertEqual(transcripts.user_text("pi", rows[0]), "Check caf\u00e9 settings")
            self.assertEqual(transcripts.appended_records(path, offset), ([], offset))

    def test_invalid_records_do_not_hide_following_messages(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session.jsonl"
            path.write_bytes(b'not json\n[]\n\xff\n{"type":"message","message":{"role":"user","content":"hello"}}\n')
            rows, offset = transcripts.appended_records(path, 0)
            self.assertEqual(len(rows), 1)
            self.assertEqual(offset, path.stat().st_size)
            self.assertEqual(transcripts.user_text("pi", rows[0]), "hello")

    def test_prompt_filter_matches_annotation_and_live_selection(self):
        self.assertEqual(transcripts.eligible_prompt("  Check\n the router.  "), "Check the router.")
        for text in ["", " \n ", "<environment_context>metadata", "<command-name>/status", "<SYSTEM-REMINDER>metadata"]:
            self.assertIsNone(transcripts.eligible_prompt(text))


if __name__ == "__main__":
    unittest.main()
