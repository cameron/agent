#!/usr/bin/env python3
"""Normalize Codex, Claude, and Pi session JSONL files into one SQLite index."""

import argparse
import ast
import datetime
import json
import os
import re
import shlex
import sqlite3
import subprocess
import sys
import time
import urllib.parse
import hashlib
import uuid
import itertools
import tempfile

SCHEMA_VERSION = 4


def db_timeout():
    """Seconds a connection waits for a busy database before failing."""
    try:
        return float(os.environ.get("AGENT_TRANSCRIPTS_DB_TIMEOUT", "5"))
    except ValueError:
        return 5.0


MAN_LOOKUP_FLAGS = {"-k", "-f", "-K", "-w", "-W", "--apropos", "--whatis",
                    "--where", "--path", "--location", "--global-apropos"}
SECTION_RE = re.compile(r"^([0-9][a-zA-Z]*|lab-[a-z-]+|man[a-z-]*)$")
WRAPPERS = {"sudo", "command", "exec", "nice", "time", "builtin"}
FILE_READERS = {"cat", "head", "tail", "less", "more", "bat", "batcat"}
REDIRECT_RE = re.compile(r"^\d*(>>?|<<?|&>>?)")
SEGMENT_RE = re.compile(r"&&|\|\||[;\n]|(?<![|&])\|(?![|&])")


def default_db_path():
    override = os.environ.get("AGENT_TRANSCRIPTS_DB")
    if override:
        return override
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser(
        "~/.local/state")
    return os.path.join(state, "agent-transcripts", "index.sqlite")


def session_roots(harness=None, archived=True):
    home = os.path.expanduser("~")
    roots = {
        "codex": (os.environ.get("CODEX_HOME") or os.path.join(home, ".codex"),
                  ["sessions", "archived_sessions"] if archived else ["sessions"]),
        "claude": (os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude"),
                   ["projects"]),
        "pi": (os.environ.get("PI_CODING_AGENT_DIR") or os.path.join(home, ".pi", "agent"),
               ["sessions"]),
    }
    return [os.path.join(base, suffix)
            for name, (base, suffixes) in roots.items()
            if harness is None or name == harness for suffix in suffixes]


def default_roots():
    return session_roots()


def repo_of(cwd):
    if not cwd:
        return None
    parts = cwd.rstrip("/").split("/")
    for marker in (".worktrees", ".worktree"):
        if marker in parts:
            return "/".join(parts[:parts.index(marker)])
    return cwd.rstrip("/") or "/"


class Session:
    def __init__(self, path, harness):
        self.path = path
        self.harness = harness
        self.session_id = None
        self.cwd = None
        self.model = None
        self.started_at = None
        self.turn = 0
        self.events = []
        self.chars_by_call = {}

    def note_time(self, ts):
        if ts and not self.started_at:
            self.started_at = ts

    def note_metadata(self, record):
        session_id, cwd = record_metadata(self.harness, record)
        self.session_id = session_id or self.session_id
        self.cwd = self.cwd or cwd

    def add(self, kind, ts=None, name=None, detail=None, chars=None,
            call_id=None, tokens=None, usage_id=None):
        tokens = tokens or {}
        event = {
            "turn": self.turn, "ts": ts, "kind": kind, "name": name,
            "detail": detail, "chars": chars, "call_id": call_id,
            "input_tokens": tokens.get("input"),
            "cached_tokens": tokens.get("cached"),
            "cache_write_tokens": tokens.get("cache_write"),
            "output_tokens": tokens.get("output"),
            "reasoning_tokens": tokens.get("reasoning"),
            "model": self.model,
            "usage_id": usage_id,
        }
        self.events.append(event)
        return event

    def add_command(self, command, ts=None, name=None, call_id=None):
        self.add("tool", ts=ts, name=name, detail=command[:2000],
                 call_id=call_id)
        for kind, section, target in scan_command(command):
            self.add(kind, ts=ts, name=section, detail=target,
                     call_id=call_id)

    def finish(self):
        for event in self.events:
            call_id = event.pop("call_id")
            if call_id is not None and event["chars"] is None:
                event["chars"] = self.chars_by_call.get(call_id)


def scan_command(command):
    """Yield (kind, section, target) reads found in a shell command string."""
    results = []
    for segment in SEGMENT_RE.split(command or ""):
        try:
            tokens = shlex.split(segment, comments=False, posix=True)
        except ValueError:
            tokens = segment.split()
        while tokens and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]):
            tokens = tokens[1:]
        while tokens and os.path.basename(tokens[0]) in WRAPPERS:
            tokens = tokens[1:]
        if tokens and os.path.basename(tokens[0]) == "env":
            tokens = tokens[1:]
            while tokens and (tokens[0].startswith("-")
                              or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=",
                                          tokens[0])):
                tokens = tokens[1:]
        if not tokens:
            continue
        program = os.path.basename(tokens[0])
        args = tokens[1:]
        if program == "man":
            results.extend(scan_man(args))
        elif program in FILE_READERS:
            results.extend(scan_reader(args))
    return results


def scan_man(args):
    if any(arg in MAN_LOOKUP_FLAGS for arg in args):
        return []
    positional = []
    section = None
    pending_section = False
    skip_value = False
    for arg in args:
        if pending_section:
            section = arg
            pending_section = False
            continue
        if skip_value:
            skip_value = False
            continue
        if REDIRECT_RE.match(arg):
            break
        if arg.startswith("--section=") or arg.startswith("--sections="):
            section = arg.split("=", 1)[1]
            continue
        if arg.startswith("-S") and len(arg) > 2:
            section = arg[2:]
            continue
        if arg.startswith("-"):
            if arg in ("-s", "-S", "--section", "--sections"):
                pending_section = True
            elif arg in ("-M", "-L", "-P", "-p", "-e", "-m", "-C", "-r"):
                skip_value = True
            continue
        positional.append(arg)
    if not positional:
        return []
    if (section is None and len(positional) > 1
            and (SECTION_RE.match(positional[0]) or len(positional[0]) <= 2)):
        section = positional[0]
        positional = positional[1:]
    reads = []
    for page in positional:
        page_section = section
        suffix = re.fullmatch(r"(.+)\(([^()]+)\)", page)
        if suffix:
            page, page_section = suffix.group(1), suffix.group(2)
        reads.append(("man_read", page_section, page))
    return reads


def scan_reader(args):
    results = []
    skip_value = False
    for arg in args:
        if skip_value:
            skip_value = False
            continue
        if REDIRECT_RE.match(arg):
            break
        if arg.startswith("-"):
            if arg in ("-n", "-c"):
                skip_value = True
            continue
        if re.fullmatch(r"[0-9]+", arg) or arg == "-":
            continue
        results.append(("file_read", None, arg))
    return results


def json_records(lines):
    for line in lines:
        try:
            record = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        if isinstance(record, dict):
            yield record


def iter_jsonl(path):
    with open(path, "r", errors="replace") as handle:
        yield from json_records(handle)


def appended_records(path, offset):
    """Read complete appended records, keeping a partial final line for next time."""
    with open(path, "rb") as handle:
        handle.seek(offset)
        data = handle.read()
    complete = data.rfind(b"\n") + 1
    return list(json_records(data[:complete].splitlines())), offset + complete


def iter_jsonl_reverse(path, chunk_size=64 * 1024):
    """Read complete JSONL records from newest to oldest."""
    with open(path, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        position = handle.tell()
        pending = b""
        while position > 0:
            size = min(chunk_size, position)
            position -= size
            handle.seek(position)
            pending = handle.read(size) + pending
            lines = pending.split(b"\n")
            pending = lines[0]
            for line in reversed(lines[1:]):
                line = line.strip()
                if not line:
                    continue
                yield from json_records([line])
        pending = pending.strip()
        if pending:
            yield from json_records([pending])


def record_harness(record):
    kind = record.get("type")
    if kind in ("session_meta", "turn_context", "response_item",
                "event_msg"):
        return "codex"
    if kind == "session" and "cwd" in record:
        return "pi"
    if kind in ("message", "model_change", "thinking_level_change"):
        return "pi"
    if "parentUuid" in record or "sessionId" in record:
        return "claude"
    if kind in ("summary", "file-history-snapshot"):
        return "claude"
    return None


def sniff_harness(path):
    for record in iter_jsonl(path):
        harness = record_harness(record)
        if harness:
            return harness
    return None


def content_chars(content):
    if isinstance(content, str):
        return len(content)
    total = 0
    if isinstance(content, list):
        for item in content:
            if isinstance(item, dict):
                total += len(item.get("text") or "")
    return total


def content_text(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    return "\n".join(
        item.get("text") or "" for item in content
        if isinstance(item, dict)
        and item.get("type") in ("text", "input_text", "output_text")
        and item.get("text")
    )


def record_metadata(harness, record):
    """The native identity and working directory, shared by live readers and indexing."""
    if harness == "codex" and record.get("type") == "session_meta":
        payload = record.get("payload") or {}
        if isinstance(payload, dict):
            return payload.get("session_id") or payload.get("id"), payload.get("cwd")
    if harness == "claude":
        return record.get("sessionId"), record.get("cwd")
    if harness == "pi" and record.get("type") == "session":
        return record.get("id"), record.get("cwd")
    return None, None


def transcript_metadata(path):
    """Read only the small header, even when the transcript is large or incomplete."""
    harness = session_id = cwd = None
    with open(path, "rb") as handle:
        for record in json_records(itertools.islice(handle, 32)):
            harness = harness or record_harness(record)
            native, directory = record_metadata(harness, record)
            session_id = session_id or native
            cwd = cwd or directory
            if harness and session_id and cwd:
                break
    return harness, session_id, cwd


def user_text(harness, record):
    """Return user text, excluding harness metadata and tool results."""
    kind = record.get("type")
    if harness == "codex":
        payload = record.get("payload") or {}
        if not isinstance(payload, dict):
            return ""
        if kind == "event_msg":
            if payload.get("type") == "user_message":
                return payload.get("message") or ""
            item = payload.get("item") or {}
            if not isinstance(item, dict):
                return ""
            if payload.get("type") == "item_completed" and item.get("type") == "UserMessage":
                return content_text(item.get("content"))
        if kind == "response_item" and payload.get("type") == "message" and payload.get("role") == "user":
            return content_text(payload.get("content"))
    elif harness == "claude" and kind == "user":
        if not (record.get("isMeta") or record.get("isSidechain") or "toolUseResult" in record):
            message = record.get("message") or {}
            if isinstance(message, dict):
                return content_text(message.get("content"))
    elif harness == "pi" and kind == "message":
        message = record.get("message") or {}
        if isinstance(message, dict) and message.get("role") == "user":
            return content_text(message.get("content"))
    return ""


BOILERPLATE_PREFIXES = ("<command-", "<environment_context>",
                        "<local-command-", "<system-reminder>")


def eligible_prompt(text):
    text = " ".join(text.split())
    return text if text and not text.lower().startswith(BOILERPLATE_PREFIXES) else None


EXEC_CALL_RE = re.compile(r"tools\.exec_command\(")
COMMAND_PROPERTY_RE = re.compile(
    r'''["']?(?:cmd|command)["']?\s*:\s*(["'])''')


def javascript_command(text, start):
    property_match = COMMAND_PROPERTY_RE.search(text, start)
    if not property_match:
        return None
    quote = property_match.group(1)
    begin = property_match.end() - 1
    escaped = False
    for index in range(begin + 1, len(text)):
        character = text[index]
        if escaped:
            escaped = False
            continue
        if character == "\\":
            escaped = True
            continue
        if character != quote:
            continue
        literal = text[begin:index + 1]
        try:
            return json.loads(literal) if quote == '"' else ast.literal_eval(literal)
        except (json.JSONDecodeError, SyntaxError, ValueError):
            return None
    return None


def codex_commands(name, payload):
    if name in ("exec", "run"):
        text = payload.get("input") or ""
        commands = [
            command for match in EXEC_CALL_RE.finditer(text)
            if (command := javascript_command(text, match.end()))
        ]
        return commands or [text[:2000]]
    try:
        arguments = json.loads(payload.get("arguments") or "{}")
    except json.JSONDecodeError:
        return []
    command = arguments.get("cmd") or arguments.get("command")
    if isinstance(command, list):
        command = " ".join(str(part) for part in command)
    return [command] if command else []


def parse_codex(session, records):
    user_items = []
    saw_user_event = False
    last_signature = None
    usage_number = 0
    for record in records:
        payload = record.get("payload")
        if not isinstance(payload, dict):
            continue
        ts = record.get("timestamp")
        session.note_time(ts)
        kind = record.get("type")
        ptype = payload.get("type")
        if kind == "session_meta":
            session.note_metadata(record)
        elif kind == "turn_context":
            session.cwd = payload.get("cwd") or session.cwd
            session.model = payload.get("model") or session.model
        elif kind == "event_msg" and ptype == "user_message":
            saw_user_event = True
            session.turn += 1
            session.add("user", ts=ts,
                        detail=user_text("codex", record)[:500])
        elif kind == "event_msg" and ptype == "item_completed":
            item = payload.get("item") or {}
            if item.get("type") == "UserMessage":
                text = user_text("codex", record)
                user_items.append((ts, text, len(session.events)))
        elif kind == "event_msg" and ptype == "token_count":
            info = payload.get("info") or {}
            usage = info.get("last_token_usage") or {}
            total = info.get("total_token_usage")
            signature = json.dumps(total, sort_keys=True) if isinstance(total, dict) else None
            if signature is not None and signature == last_signature:
                continue
            last_signature = signature
            if usage:
                usage_number += 1
                session.add("usage", ts=ts, tokens={
                    "input": usage.get("input_tokens"),
                    "cached": usage.get("cached_input_tokens"),
                    "cache_write": usage.get("cache_write_input_tokens"),
                    "output": usage.get("output_tokens"),
                    "reasoning": usage.get("reasoning_output_tokens"),
                }, usage_id="codex:%s" % usage_number)
        elif kind == "response_item" and ptype in ("function_call",
                                                   "custom_tool_call"):
            name = payload.get("name")
            for command in codex_commands(name, payload):
                session.add_command(command, ts=ts, name=name,
                                    call_id=payload.get("call_id"))
        elif kind == "response_item" and ptype in ("function_call_output",
                                                   "custom_tool_call_output"):
            call_id = payload.get("call_id")
            if call_id:
                session.chars_by_call[call_id] = content_chars(
                    payload.get("output"))
    if not saw_user_event:
        for offset, (ts, text, position) in enumerate(user_items):
            session.add("user", ts=ts, detail=text[:500])
            session.events.insert(position + offset, session.events.pop())
        renumber_turns(session)


def renumber_turns(session):
    turn = 0
    for event in session.events:
        if event["kind"] == "user":
            turn += 1
        event["turn"] = turn


def parse_claude(session, records):
    seen_usage_ids = set()
    for record in records:
        ts = record.get("timestamp")
        session.note_time(ts)
        session.note_metadata(record)
        kind = record.get("type")
        message = record.get("message")
        if not isinstance(message, dict):
            continue
        content = message.get("content")
        if kind == "user":
            for item in content if isinstance(content, list) else []:
                if isinstance(item, dict) and item.get("type") == "tool_result" and item.get("tool_use_id"):
                    session.chars_by_call[item["tool_use_id"]] = content_chars(item.get("content"))
            text = user_text("claude", record)
            if text:
                session.turn += 1
                session.add("user", ts=ts, detail=text[:500])
        elif kind == "assistant":
            session.model = message.get("model") or session.model
            usage = message.get("usage") or {}
            message_id = message.get("id")
            if usage and message_id and message_id not in seen_usage_ids:
                seen_usage_ids.add(message_id)
                session.add("usage", ts=ts, tokens={
                    "input": usage.get("input_tokens"),
                    "cached": usage.get("cache_read_input_tokens"),
                    "cache_write": usage.get("cache_creation_input_tokens"),
                    "output": usage.get("output_tokens"),
                }, usage_id=message_id)
            if not isinstance(content, list):
                continue
            for item in content:
                if not isinstance(item, dict) or item.get(
                        "type") != "tool_use":
                    continue
                name = item.get("name") or ""
                arguments = item.get("input") or {}
                call_id = item.get("id")
                command = arguments.get("command")
                path = arguments.get("file_path") or arguments.get("path")
                if name == "Bash" and isinstance(command, str):
                    session.add_command(command, ts=ts, name=name,
                                        call_id=call_id)
                elif name in ("Read", "NotebookEdit") and path:
                    session.add("tool", ts=ts, name=name, detail=path,
                                call_id=call_id)
                    if name == "Read":
                        session.add("file_read", ts=ts, detail=path,
                                    call_id=call_id)
                else:
                    detail = json.dumps(arguments)[:500] if arguments else None
                    session.add("tool", ts=ts, name=name, detail=detail,
                                call_id=call_id)


def parse_pi(session, records):
    for record in records:
        ts = record.get("timestamp")
        session.note_time(ts)
        kind = record.get("type")
        if kind == "session":
            session.note_metadata(record)
            continue
        if kind == "model_change":
            session.model = record.get("modelId") or session.model
            continue
        if kind != "message":
            continue
        message = record.get("message")
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        content = message.get("content")
        if role == "user":
            text = user_text("pi", record)
            if text:
                session.turn += 1
                session.add("user", ts=ts, detail=text[:500])
        elif role == "toolResult":
            call_id = message.get("toolCallId")
            if call_id:
                session.chars_by_call[call_id] = content_chars(content)
        elif role == "assistant" and isinstance(content, list):
            session.model = message.get("model") or session.model
            usage = message.get("usage")
            if isinstance(usage, dict) and any(key in usage for key in ("input", "output")):
                session.add("usage", ts=ts, usage_id=record.get("id"), tokens={
                    "input": usage.get("input"),
                    "cached": usage.get("cacheRead"),
                    "cache_write": usage.get("cacheWrite"),
                    "output": usage.get("output"),
                })
            for item in content:
                if not isinstance(item, dict) or item.get(
                        "type") != "toolCall":
                    continue
                name = item.get("name") or ""
                arguments = item.get("arguments") or {}
                call_id = item.get("id")
                command = arguments.get("command")
                path = arguments.get("path") or arguments.get("file_path")
                if name == "bash" and isinstance(command, str):
                    session.add_command(command, ts=ts, name=name,
                                        call_id=call_id)
                elif name == "read" and path:
                    session.add("tool", ts=ts, name=name, detail=path,
                                call_id=call_id)
                    session.add("file_read", ts=ts, detail=path,
                                call_id=call_id)
                else:
                    detail = json.dumps(arguments)[:500] if arguments else None
                    session.add("tool", ts=ts, name=name, detail=detail,
                                call_id=call_id)


PARSERS = {"codex": parse_codex, "claude": parse_claude, "pi": parse_pi}


def transcript_item(kind, ts=None, name=None, detail=None):
    return {"timestamp": ts or "", "kind": kind, "name": name or "",
            "detail": detail or ""}


def codex_tail_items(records):
    items = []
    for record in records:
        payload = record.get("payload")
        if not isinstance(payload, dict) or record.get("type") != "response_item":
            continue
        timestamp = record.get("timestamp")
        kind = payload.get("type")
        if kind == "message" and payload.get("role") in ("user", "assistant"):
            detail = (user_text("codex", record) if payload["role"] == "user"
                      else content_text(payload.get("content")))
            if detail.strip():
                items.append(transcript_item(
                    payload["role"], timestamp, detail=detail))
        elif kind in ("function_call", "custom_tool_call"):
            commands = codex_commands(payload.get("name"), payload)
            for command in commands:
                if command and command.strip():
                    items.append(transcript_item(
                        "tool", timestamp, payload.get("name"), command))
    return items


def claude_tail_items(records):
    items = []
    for record in records:
        message = record.get("message")
        if not isinstance(message, dict):
            continue
        kind = record.get("type")
        content = message.get("content")
        timestamp = record.get("timestamp")
        if kind == "user":
            detail = user_text("claude", record)
            if detail.strip():
                items.append(transcript_item("user", timestamp, detail=detail))
        elif kind == "assistant" and isinstance(content, list):
            for part in content:
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "text" and (part.get("text") or "").strip():
                    items.append(transcript_item(
                        "assistant", timestamp, detail=part["text"]))
                elif part.get("type") == "tool_use":
                    name = part.get("name") or ""
                    arguments = part.get("input") or {}
                    detail = arguments.get("command")
                    if not detail:
                        detail = json.dumps(arguments, ensure_ascii=False)
                    items.append(transcript_item(
                        "tool", timestamp, name, detail))
    return items


def pi_tail_items(records):
    items = []
    for record in records:
        if record.get("type") != "message":
            continue
        message = record.get("message")
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        content = message.get("content")
        timestamp = record.get("timestamp")
        if role == "user":
            detail = user_text("pi", record)
            if detail.strip():
                items.append(transcript_item("user", timestamp, detail=detail))
        elif role == "assistant" and isinstance(content, list):
            for part in content:
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "text" and (part.get("text") or "").strip():
                    items.append(transcript_item(
                        "assistant", timestamp, detail=part["text"]))
                elif part.get("type") == "toolCall":
                    name = part.get("name") or ""
                    arguments = part.get("arguments") or {}
                    detail = arguments.get("command")
                    if not detail:
                        detail = json.dumps(arguments, ensure_ascii=False)
                    items.append(transcript_item(
                        "tool", timestamp, name, detail))
    return items


TAIL_PARSERS = {
    "codex": codex_tail_items,
    "claude": claude_tail_items,
    "pi": pi_tail_items,
}


def parse_file(path):
    harness = sniff_harness(path)
    if harness is None:
        return None
    session = Session(path, harness)
    PARSERS[harness](session, iter_jsonl(path))
    session.finish()
    return session


def open_db(db_path):
    os.makedirs(os.path.dirname(db_path) or ".", exist_ok=True)
    connection = sqlite3.connect(db_path, timeout=db_timeout())
    connection.executescript("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS files(
            path TEXT PRIMARY KEY, mtime REAL, size INTEGER);
        CREATE TABLE IF NOT EXISTS sessions(
            path TEXT PRIMARY KEY, harness TEXT, session_id TEXT,
            cwd TEXT, repo TEXT, model TEXT, started_at TEXT);
        CREATE TABLE IF NOT EXISTS events(
            path TEXT, seq INTEGER, turn INTEGER, ts TEXT, kind TEXT,
            name TEXT, detail TEXT, chars INTEGER,
            input_tokens INTEGER, cached_tokens INTEGER,
            cache_write_tokens INTEGER, output_tokens INTEGER,
            PRIMARY KEY(path, seq));
        CREATE INDEX IF NOT EXISTS events_kind ON events(kind, detail);
    """)
    for column in ("title", "description"):
        try:
            connection.execute(
                "ALTER TABLE sessions ADD COLUMN %s TEXT" % column)
        except sqlite3.OperationalError:
            pass
    for column in ("model TEXT", "usage_id TEXT", "reasoning_tokens INTEGER"):
        if column.split()[0] not in {row[1] for row in connection.execute("PRAGMA table_info(events)")}:
            connection.execute("ALTER TABLE events ADD COLUMN " + column)
    if "revision" not in {row[1] for row in connection.execute("PRAGMA table_info(files)")}:
        connection.execute("ALTER TABLE files ADD COLUMN revision INTEGER DEFAULT 0")
    previous = connection.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
    if not previous or previous[0] != str(SCHEMA_VERSION):
        # A parser change must refresh unchanged files as well.
        connection.execute("UPDATE files SET mtime=NULL")
    connection.execute("INSERT OR IGNORE INTO meta VALUES('index_id', ?)", (str(uuid.uuid4()),))
    connection.execute("INSERT OR IGNORE INTO meta VALUES('revision', '0')")
    connection.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)",
        (str(SCHEMA_VERSION),))
    return connection


def open_db_readonly(db_path):
    """Open the index for a read command without writing schema metadata."""
    if not os.path.exists(db_path):
        raise SystemExit(
            "agent-transcripts: no index at %s "
            "(run 'agent-transcripts index' first)" % db_path)
    uri = "file:%s?mode=ro" % urllib.parse.quote(db_path)
    return sqlite3.connect(uri, uri=True, timeout=db_timeout())


def store_session(connection, session, mtime, size, revision=0):
    connection.execute("DELETE FROM events WHERE path = ?", (session.path,))
    connection.execute("DELETE FROM sessions WHERE path = ?", (session.path,))
    connection.execute(
        """INSERT INTO sessions(path, harness, session_id, cwd, repo, model,
           started_at) VALUES(?, ?, ?, ?, ?, ?, ?)""",
        (session.path, session.harness, session.session_id, session.cwd,
         repo_of(session.cwd), session.model, session.started_at))
    connection.executemany(
        """INSERT INTO events(path,seq,turn,ts,kind,name,detail,chars,
           input_tokens,cached_tokens,cache_write_tokens,output_tokens,
           model,usage_id,reasoning_tokens) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        [(session.path, seq, e["turn"], e["ts"], e["kind"], e["name"],
          e["detail"], e["chars"], e["input_tokens"], e["cached_tokens"],
          e["cache_write_tokens"], e["output_tokens"], e["model"],
          e["usage_id"], e["reasoning_tokens"])
         for seq, e in enumerate(session.events)])
    connection.execute(
        "INSERT OR REPLACE INTO files(path, mtime, size, revision) VALUES(?, ?, ?, ?)",
        (session.path, mtime, size, revision))


def sidecar_line(path):
    """Return the first line of a sidecar file, or None when absent."""
    try:
        with open(path, "r", errors="replace") as handle:
            line = handle.readline().strip()
    except OSError:
        return None
    return line or None


def sync_sidecars(connection, paths):
    """Copy .title and .desc sidecar content into the sessions rows."""
    for path in paths:
        title = sidecar_line(path + ".title")
        description = sidecar_line(path + ".desc")
        connection.execute(
            """UPDATE sessions SET title = ?, description = ?
               WHERE path = ?
                 AND (coalesce(title, '') != coalesce(?, '')
                      OR coalesce(description, '') != coalesce(?, ''))""",
            (title, description, path, title, description))


def command_index(options):
    connection = open_db(options.db)
    mode = "usage" if options.usage_only else "full"
    previous_mode = connection.execute("SELECT value FROM meta WHERE key='index_mode'").fetchone()
    if previous_mode and previous_mode[0] != mode:
        connection.execute("UPDATE files SET mtime=NULL")
    connection.execute("INSERT OR REPLACE INTO meta VALUES('index_mode', ?)", (mode,))
    revision = int(connection.execute("SELECT value FROM meta WHERE key='revision'").fetchone()[0]) + 1
    roots = options.session_dir or default_roots()
    known = dict(
        (path, (mtime, size)) for path, mtime, size in
        connection.execute("SELECT path, mtime, size FROM files"))
    seen = set()
    parsed = 0
    skipped = 0
    for root in roots:
        if not os.path.isdir(root):
            continue
        for directory, _, names in os.walk(root):
            for name in sorted(names):
                if not name.endswith(".jsonl"):
                    continue
                path = os.path.join(directory, name)
                try:
                    stat = os.stat(path)
                except OSError:
                    continue
                seen.add(path)
                if known.get(path) == (stat.st_mtime, stat.st_size):
                    continue
                session = parse_file(path)
                if session is None:
                    skipped += 1
                    continue
                if options.usage_only:
                    session.events = [event for event in session.events if event["kind"] == "usage"]
                store_session(connection, session, stat.st_mtime,
                              stat.st_size, revision)
                parsed += 1
    if not options.usage_only:
        sync_sidecars(connection, seen)
    removed = 0
    for path in known:
        if path not in seen and any(
                path.startswith(root.rstrip("/") + "/") for root in roots):
            connection.execute("DELETE FROM events WHERE path = ?", (path,))
            connection.execute("DELETE FROM sessions WHERE path = ?", (path,))
            connection.execute("DELETE FROM files WHERE path = ?", (path,))
            removed += 1
    connection.execute("UPDATE meta SET value=? WHERE key='revision'", (str(revision),))
    connection.commit()
    if not options.quiet:
        print(f"parsed {parsed} skipped {skipped} removed {removed} "
              f"indexed {len(seen)}")


def command_export_usage(options):
    """Numeric session snapshots; readers can resume with the returned cursor."""
    connection = open_db_readonly(options.db)
    connection.row_factory = sqlite3.Row
    connection.execute("BEGIN")
    meta = dict(connection.execute("SELECT key,value FROM meta"))
    if meta.get("schema_version") != str(SCHEMA_VERSION):
        raise sqlite3.OperationalError("no such column: usage export requires reindexing")
    after = options.after if options.index_id == meta["index_id"] else 0
    sessions = []
    for row in connection.execute("""
        SELECT s.path,s.harness,s.session_id,s.repo,f.size,f.mtime,f.revision
        FROM sessions s JOIN files f USING(path) WHERE f.revision > ? ORDER BY s.path
    """, (after,)):
        values = []
        invalid = 0
        for event in connection.execute("""
            SELECT seq,ts,model,usage_id,input_tokens,cached_tokens,
                   cache_write_tokens,output_tokens,reasoning_tokens
            FROM events WHERE path=? AND kind='usage' ORDER BY seq
        """, (row["path"],)):
            try:
                at = datetime.datetime.fromisoformat(event["ts"].replace("Z", "+00:00"))
                if at.tzinfo is None:
                    raise ValueError("usage timestamp has no UTC offset")
            except (AttributeError, TypeError, ValueError):
                invalid += 1
                continue
            fields = [event[name] for name in (
                "input_tokens", "cached_tokens", "cache_write_tokens", "output_tokens", "reasoning_tokens")]
            if any(value is not None and (not isinstance(value, int) or value < 0) for value in fields):
                invalid += 1
                continue
            incoming, cached, written, outgoing, reasoning = [value or 0 for value in fields]
            if row["harness"] in ("claude", "pi"):
                incoming += cached + written
            if cached + written > incoming or reasoning > outgoing:
                invalid += 1
                continue
            values.append({
                "id": event["usage_id"] or "event:%s" % event["seq"],
                "timestamp": event["ts"], "model": event["model"] or "unknown",
                "input_tokens": incoming, "cached_input_tokens": cached,
                "cache_write_input_tokens": written, "output_tokens": outgoing,
                "reasoning_output_tokens": reasoning,
            })
        # Paths identify copies but need not leave the source host.
        copy_id = hashlib.sha256(row["path"].encode()).hexdigest()
        sessions.append({
            "copy_id": copy_id,
            "session_id": row["session_id"] or "file:" + copy_id,
            "harness": row["harness"], "repository": row["repo"],
            "file_size": row["size"], "revision": row["revision"],
            "invalid_records": invalid, "records": values,
        })
    print(json.dumps({"schema_version": 1, "index_id": meta["index_id"],
                      "revision": int(meta["revision"]), "sessions": sessions}, separators=(",", ":")))
    connection.close()


def emit(rows, header, as_json):
    if as_json:
        for row in rows:
            print(json.dumps(dict(zip(header, row))))
        return
    print("\t".join(header))
    for row in rows:
        print("\t".join("" if value is None else str(value) for value in row))


def command_sessions(options):
    connection = open_db_readonly(options.db)
    rows = connection.execute("""
        SELECT s.path, s.harness, s.session_id, s.repo, s.cwd, s.model,
               s.started_at,
               (SELECT count(*) FROM events e
                WHERE e.path = s.path AND e.kind = 'user') AS turns,
               s.title, s.description
        FROM sessions s ORDER BY s.started_at
    """).fetchall()
    emit(rows, ["path", "harness", "session_id", "repo", "cwd", "model",
                "started_at", "turns", "title", "description"], options.json)


RESUME_COMMANDS = {
    "codex": "codex resume {id}",
    "claude": "claude --resume {id}",
    "pi": "pi --session {id}",
}


def command_recent(options):
    connection = open_db_readonly(options.db)
    conditions = []
    parameters = []
    if options.repo:
        conditions.append("s.repo = ?")
        parameters.append(options.repo.rstrip("/") or "/")
    query = """
        SELECT s.path, s.harness, s.session_id, s.repo, s.cwd, f.mtime,
               s.started_at,
               (SELECT count(*) FROM events e
                WHERE e.path = s.path AND e.kind = 'user') AS turns,
               s.title, s.description
        FROM sessions s LEFT JOIN files f ON f.path = s.path
    """
    if conditions:
        query += " WHERE " + " AND ".join(conditions)
    query += " ORDER BY coalesce(f.mtime, 0) DESC LIMIT ?"
    parameters.append(options.limit)
    rows = []
    for (path, harness, session_id, repo, cwd, mtime, started_at, turns,
         title, description) in connection.execute(query, parameters):
        last_active = started_at
        if mtime:
            last_active = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                        time.gmtime(mtime))
        resume = None
        if session_id and harness in RESUME_COMMANDS:
            resume = RESUME_COMMANDS[harness].format(id=session_id)
        rows.append((path, harness, session_id, repo, cwd, last_active,
                     turns, title, description, resume))
    emit(rows, ["path", "harness", "session_id", "repo", "cwd",
                "last_active", "turns", "title", "description", "resume"],
         options.json)


def split_session_reference(reference):
    harness = None
    native = reference
    if ":" in reference:
        prefix, value = reference.split(":", 1)
        if prefix in TAIL_PARSERS:
            harness = prefix
            native = value
    if not re.fullmatch(r"[A-Za-z0-9._-]+", native):
        return None, None
    return harness, native


def identify_transcript(path):
    harness, session_id, _ = transcript_metadata(path)
    return harness, session_id


def transcript_for_session(reference, roots, db_path):
    wanted_harness, native = split_session_reference(reference)
    if native is None:
        return None, "invalid session reference"
    candidate_paths = []
    if os.path.exists(db_path):
        try:
            connection = open_db_readonly(db_path)
            query = "SELECT path, harness FROM sessions WHERE session_id = ?"
            for path, harness in connection.execute(query, (native,)):
                if not wanted_harness or harness == wanted_harness:
                    candidate_paths.append(path)
            connection.close()
        except sqlite3.Error:
            pass
    seen_paths = set(candidate_paths)
    matches = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for directory, _, names in os.walk(root):
            for name in names:
                if not name.endswith(".jsonl") or native not in name:
                    continue
                path = os.path.join(directory, name)
                if path not in seen_paths:
                    candidate_paths.append(path)
                    seen_paths.add(path)
    for path in candidate_paths:
        if not os.path.isfile(path):
            continue
        harness, session_id = identify_transcript(path)
        if harness is None or session_id != native:
            continue
        if wanted_harness and harness != wanted_harness:
            continue
        session = Session(path, harness)
        session.session_id = session_id
        matches.append(session)
    if not matches:
        return None, f"session not found: {reference}"
    if len(matches) > 1:
        return None, f"session is ambiguous: {reference}"
    return matches[0], None


def tail_items(path, harness, limit):
    newest = []
    for record in iter_jsonl_reverse(path):
        items = TAIL_PARSERS[harness]([record])
        for item in reversed(items):
            newest.append(item)
            if len(newest) == limit:
                return list(reversed(newest))
    return list(reversed(newest))


def command_tail(options):
    if options.lines < 1:
        print("agent-transcripts tail: -n must be positive", file=sys.stderr)
        return 2
    session, error = transcript_for_session(
        options.session, options.session_dir or default_roots(), options.db)
    if error:
        print(f"agent-transcripts tail: {error}", file=sys.stderr)
        return 1
    items = tail_items(session.path, session.harness, options.lines)
    for item in items:
        item = {"harness": session.harness,
                "session_id": session.session_id, **item}
        if options.json:
            print(json.dumps(item, ensure_ascii=False))
        else:
            label = item["kind"]
            if item["name"]:
                label += f" {item['name']}"
            print(f"[{label} · {item['timestamp']}]")
            print(item["detail"].rstrip())
    return 0


TITLE_WORD = r"[A-Za-z0-9_+./#-]+"
TITLE_RE = re.compile(r"^%s( %s){0,2}$" % (TITLE_WORD, TITLE_WORD))

ANNOTATE_PROMPT = (
    "You describe coding-agent sessions from the first user request. "
    "Reply with exactly two lines and nothing else. "
    "Line 1: a title of at most 3 words that names the subject of the "
    "request. "
    "Line 2: one sentence of at most 25 words that says what the user "
    "asked for.")


def first_prompt(connection, path):
    """Return the first real user message of a session, or None."""
    for (detail,) in connection.execute(
            "SELECT detail FROM events WHERE path = ? AND kind = 'user' "
            "ORDER BY seq", (path,)):
        text = eligible_prompt(detail or "")
        if text:
            return text
    return None


def annotation_lines(message, generator, timeout):
    """Run the generator on a user message; return (title, description)."""
    message = message[:800]
    if generator:
        completed = subprocess.run(
            ["bash", "-c", generator], input=message, capture_output=True,
            text=True, timeout=timeout)
    else:
        argv = ["pi", "--model",
                os.environ.get("AGENT_TRANSCRIPTS_ANNOTATE_MODEL",
                               "titles/gemma-4-26b-a4b-q4-cpu"),
                "--offline", "--print", "--no-session", "--no-tools",
                "--no-extensions", "--no-skills", "--no-prompt-templates",
                "--no-context-files", "--thinking", "off",
                "--system-prompt", ANNOTATE_PROMPT, message]
        completed = subprocess.run(
            argv, stdin=subprocess.DEVNULL, capture_output=True, text=True,
            timeout=timeout)
    if completed.returncode != 0:
        return None, None
    lines = [line.strip().strip('`"') for line in completed.stdout.splitlines()
             if line.strip()]
    title = lines[0] if lines else None
    description = " ".join(lines[1].split()) if len(lines) > 1 else None
    return title, description


def valid_title(title):
    return bool(title and len(title) <= 40 and TITLE_RE.match(title))


def valid_description(description):
    return bool(description and len(description) <= 240)


def write_sidecar(path, line):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", prefix=os.path.basename(path) + ".tmp.",
                                         dir=os.path.dirname(path) or ".", delete=False) as handle:
            temporary = handle.name
            handle.write(line + "\n")
        os.replace(temporary, path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def command_annotate(options):
    connection = open_db(options.db)
    generator = options.generator or os.environ.get(
        "AGENT_TRANSCRIPTS_ANNOTATOR")
    rows = connection.execute("""
        SELECT path, title, description, started_at FROM sessions
        ORDER BY started_at DESC
    """).fetchall()
    annotated = failed = skipped = 0
    for path, title, description, started_at in rows:
        if options.since and (started_at or "") < options.since:
            continue
        need_title = options.force or not title
        need_description = options.force or not description
        if not (need_title or need_description):
            continue
        if not os.path.exists(path):
            skipped += 1
            continue
        message = first_prompt(connection, path)
        if not message:
            skipped += 1
            continue
        if options.limit and annotated + failed >= options.limit:
            break
        try:
            new_title, new_description = annotation_lines(
                message, generator, options.timeout)
        except (subprocess.TimeoutExpired, OSError):
            failed += 1
            continue
        wrote = False
        if need_title and valid_title(new_title):
            write_sidecar(path + ".title", new_title)
            title = new_title
            wrote = True
        if need_description and valid_description(new_description):
            write_sidecar(path + ".desc", new_description)
            description = new_description
            wrote = True
        if not wrote:
            failed += 1
            continue
        connection.execute(
            "UPDATE sessions SET title = ?, description = ? WHERE path = ?",
            (title, description, path))
        connection.commit()
        annotated += 1
        if not options.quiet:
            print("%s\t%s\t%s" % (path, title or "", description or ""))
    print("annotated %d failed %d skipped %d" % (annotated, failed, skipped))


def command_events(options):
    connection = open_db_readonly(options.db)
    query = """
        SELECT e.path, s.harness, e.seq, e.turn, e.ts, e.kind, e.name,
               e.detail, e.chars, e.input_tokens, e.cached_tokens,
               e.cache_write_tokens, e.output_tokens
        FROM events e JOIN sessions s ON s.path = e.path
    """
    conditions = []
    parameters = []
    if options.kind:
        conditions.append(
            "e.kind IN (%s)" % ",".join("?" for _ in options.kind))
        parameters.extend(options.kind)
    if options.session:
        conditions.append("(e.path LIKE ? OR s.session_id = ?)")
        parameters.extend([f"%{options.session}%", options.session])
    if conditions:
        query += " WHERE " + " AND ".join(conditions)
    query += " ORDER BY e.path, e.seq"
    rows = connection.execute(query, parameters).fetchall()
    emit(rows, ["path", "harness", "seq", "turn", "ts", "kind", "name",
                "detail", "chars", "input_tokens", "cached_tokens",
                "cache_write_tokens", "output_tokens"], options.json)


def report_man(connection, options):
    rows = connection.execute("""
        SELECT detail AS page, count(*) AS reads,
               count(DISTINCT path) AS sessions, sum(chars) AS chars
        FROM events WHERE kind = 'man_read'
        GROUP BY detail HAVING reads >= ?
        ORDER BY reads DESC, page
    """, (options.min,)).fetchall()
    emit(rows, ["page", "reads", "sessions", "chars"], options.json)


def report_co_reads(connection, options):
    rows = connection.execute("""
        WITH pages AS (
            SELECT DISTINCT path, detail FROM events WHERE kind = 'man_read')
        SELECT a.detail AS page_a, b.detail AS page_b,
               count(*) AS sessions
        FROM pages a JOIN pages b
            ON a.path = b.path AND a.detail < b.detail
        GROUP BY a.detail, b.detail HAVING sessions >= ?
        ORDER BY sessions DESC, page_a, page_b
    """, (options.min,)).fetchall()
    emit(rows, ["page_a", "page_b", "sessions"], options.json)


def report_early_reads(connection, options):
    rows = connection.execute("""
        WITH totals AS (
            SELECT repo, count(*) AS total FROM sessions GROUP BY repo),
        early AS (
            SELECT DISTINCT s.repo, e.kind, e.detail, e.path
            FROM events e JOIN sessions s ON s.path = e.path
            WHERE e.kind IN ('man_read', 'file_read') AND e.turn <= ?)
        SELECT early.repo, early.kind, early.detail,
               count(*) AS sessions, totals.total,
               round(1.0 * count(*) / totals.total, 2) AS fraction
        FROM early JOIN totals ON totals.repo = early.repo
        GROUP BY early.repo, early.kind, early.detail
        HAVING sessions >= ?
        ORDER BY early.repo, sessions DESC, early.detail
    """, (options.turns, options.min)).fetchall()
    emit(rows, ["repo", "kind", "detail", "sessions", "total", "fraction"],
         options.json)


def report_usage(connection, options):
    rows = connection.execute("""
        WITH per_session AS (
            SELECT path,
                   sum(CASE WHEN kind = 'usage'
                       THEN coalesce(input_tokens, 0) ELSE 0 END) AS input,
                   sum(CASE WHEN kind = 'usage'
                       THEN coalesce(cached_tokens, 0) ELSE 0 END) AS cached,
                   sum(CASE WHEN kind = 'usage'
                       THEN coalesce(cache_write_tokens, 0) ELSE 0
                       END) AS cache_write,
                   sum(CASE WHEN kind = 'usage'
                       THEN coalesce(output_tokens, 0) ELSE 0 END) AS output,
                   sum(CASE WHEN kind IN ('man_read', 'file_read')
                       THEN coalesce(chars, 0) ELSE 0 END) AS read_chars
            FROM events GROUP BY path)
        SELECT s.harness, count(*) AS sessions,
               sum(p.input) AS input_tokens,
               sum(p.cached) AS cached_tokens,
               sum(p.cache_write) AS cache_write_tokens,
               sum(p.output) AS output_tokens,
               sum(p.read_chars) AS read_chars
        FROM sessions s LEFT JOIN per_session p ON p.path = s.path
        GROUP BY s.harness ORDER BY s.harness
    """).fetchall()
    emit(rows, ["harness", "sessions", "input_tokens", "cached_tokens",
                "cache_write_tokens", "output_tokens", "read_chars"],
         options.json)


REPORTS = {
    "man": report_man,
    "co-reads": report_co_reads,
    "early-reads": report_early_reads,
    "usage": report_usage,
}


def command_report(options):
    connection = open_db_readonly(options.db)
    REPORTS[options.report](connection, options)


def main(argv):
    parser = argparse.ArgumentParser(
        prog=os.environ.get("AGENT_TRANSCRIPTS_PROG", "agent-transcripts"),
        description="Index agent session transcripts and query the result.")
    parser.add_argument("--db", default=default_db_path(),
                        help="SQLite index path")
    commands = parser.add_subparsers(dest="command", required=True)

    index = commands.add_parser("index", help="scan session files")
    index.add_argument("--session-dir", action="append",
                       help="scan DIR instead of the default roots")
    index.add_argument("--quiet", action="store_true")
    index.add_argument("--usage-only", action="store_true", help="store usage without conversation or tool events; use a separate --db")
    index.set_defaults(handler=command_index)

    usage = commands.add_parser("export-usage", help="export numeric usage snapshots as JSON")
    usage.add_argument("--after", type=int, default=0, help="previous export revision")
    usage.add_argument("--index-id", default="", help="previous export index identity")
    usage.set_defaults(handler=command_export_usage)

    sessions = commands.add_parser("sessions", help="list indexed sessions")
    sessions.add_argument("--json", action="store_true")
    sessions.set_defaults(handler=command_sessions)

    recent = commands.add_parser(
        "recent", help="list sessions by last activity, with resume commands")
    recent.add_argument("--limit", type=int, default=20,
                        help="maximum rows to list")
    recent.add_argument("--repo", help="only sessions of this repository")
    recent.add_argument("--json", action="store_true")
    recent.set_defaults(handler=command_recent)

    tail = commands.add_parser(
        "tail", help="print the last normalized transcript items")
    tail.add_argument("-n", "--lines", type=int, default=20,
                      help="number of normalized items to print")
    tail.add_argument("session", help="HARNESS:SESSION-ID or SESSION-ID")
    tail.add_argument("--session-dir", action="append",
                      help="search DIR instead of the default roots")
    tail.add_argument("--json", action="store_true")
    tail.set_defaults(handler=command_tail)

    annotate = commands.add_parser(
        "annotate", help="generate missing session titles and descriptions")
    annotate.add_argument("--limit", type=int, default=0,
                          help="stop after this many generation attempts")
    annotate.add_argument("--since",
                          help="only sessions started at or after this time")
    annotate.add_argument("--force", action="store_true",
                          help="regenerate existing titles and descriptions")
    annotate.add_argument("--generator",
                          help="shell command: message on stdin, two lines "
                               "out (title, description)")
    annotate.add_argument("--timeout", type=int, default=int(
        os.environ.get("AGENT_TITLE_TIMEOUT_SECONDS", "90")),
        help="seconds allowed per generation")
    annotate.add_argument("--quiet", action="store_true")
    annotate.set_defaults(handler=command_annotate)

    events = commands.add_parser("events", help="dump normalized events")
    events.add_argument("--kind", action="append")
    events.add_argument("--session")
    events.add_argument("--json", action="store_true")
    events.set_defaults(handler=command_events)

    report = commands.add_parser("report", help="run a canned analysis")
    report.add_argument("report", choices=sorted(REPORTS))
    report.add_argument("--min", type=int, default=1,
                        help="minimum count to include a row")
    report.add_argument("--turns", type=int, default=2,
                        help="early-reads: last turn that counts as early")
    report.add_argument("--json", action="store_true")
    report.set_defaults(handler=command_report)

    options = parser.parse_args(argv)
    try:
        result = options.handler(options)
    except sqlite3.OperationalError as error:
        message = str(error)
        hint = ""
        if "locked" in message or "busy" in message:
            hint = (" — another process holds the database; gave up after "
                    "%gs (AGENT_TRANSCRIPTS_DB_TIMEOUT). Retry when the "
                    "running index or annotate finishes." % db_timeout())
        elif "no such table" in message or "no such column" in message:
            hint = " — run 'agent-transcripts index' to build the index."
        print("agent-transcripts: %s: %s%s" % (options.db, message, hint),
              file=sys.stderr)
        return 1
    return result or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
