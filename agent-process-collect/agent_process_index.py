#!/usr/bin/env python3

import argparse
import collections
import datetime as dt
import json
import os
import re
import select
import sqlite3
import sys
import syslog
import time


SCHEMA_VERSION = 1
MARKER_RE = re.compile(
    r"msg='?agent_process_launch (?P<fields>.*?)(?:'(?= (?:exe|hostname|addr|terminal|res)=)|$)"
)
FIELD_RE = re.compile(
    r"(?:^| )(?P<name>[A-Za-z0-9_]+)="
    r"(?P<value>\"(?:[^\"\\]|\\.)*\"|'[^']*'|\S+)"
)


def parse_fields(text):
    result = {}
    for match in FIELD_RE.finditer(text):
        value = match.group("value")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        result[match.group("name")] = value
    return result


def decode_hex(value):
    try:
        return bytes.fromhex(value).decode("utf-8", "replace")
    except (TypeError, ValueError):
        return ""


def decode_proctitle(value):
    try:
        return [
            item.decode("utf-8", "replace")
            for item in bytes.fromhex(value).split(b"\0")
            if item
        ]
    except (TypeError, ValueError):
        return []


def field_value(text, name):
    marker = f" {name}="
    start = text.find(marker)
    if start < 0:
        if not text.startswith(f"{name}="):
            return None
        start = len(name) + 1
    else:
        start += len(marker)
    if start >= len(text):
        return ""
    quote = text[start] if text[start] in "\"'" else None
    if quote is not None:
        end = text.find(quote, start + 1)
        return text[start + 1 : end if end >= 0 else len(text)]
    end = text.find(" ", start)
    return text[start : end if end >= 0 else len(text)]


def parse_event_line(raw_line):
    line = raw_line.rstrip("\n")
    message_marker = " msg=audit("
    message_start = line.find(message_marker)
    if message_start < 0:
        return None
    body_start = line.find("): ", message_start + len(message_marker))
    if body_start < 0:
        return None
    prefix = line[:message_start]
    header = line[message_start + len(message_marker) : body_start]
    try:
        timestamp, serial = header.rsplit(":", 1)
        seconds, separator, millis = timestamp.partition(".")
        epoch = int(seconds)
        if separator:
            epoch += int(millis[:3].ljust(3, "0")) / 1000
    except ValueError:
        return None
    record_type = field_value(prefix, "type")
    if record_type is None:
        return None
    return {
        "key": (seconds, millis if separator else "0", serial, field_value(prefix, "node") or ""),
        "epoch": epoch,
        "node": field_value(prefix, "node"),
        "type": record_type,
        "body": line[body_start + 3 :],
    }


def parse_time(value):
    if value is None:
        return None
    if value.lower() == "now":
        return time.time()
    normalized = value.replace("Z", "+00:00")
    parsed = dt.datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.timestamp()


def format_time(epoch):
    return (
        dt.datetime.fromtimestamp(epoch, dt.timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def harness_from_argv(argv):
    index = 1
    while index < len(argv):
        value = argv[index]
        if value in ("--no-update", "--here", "--no-worktree"):
            index += 1
        elif value == "--role" and index + 1 < len(argv):
            index += 2
        elif value.startswith("--role="):
            index += 1
        else:
            break
    if index < len(argv) and argv[index] in ("codex", "claude", "pi"):
        return argv[index]
    return "codex"


def executable_name(executable):
    decoded = decode_hex(executable)
    if decoded.startswith("/"):
        executable = decoded
    name = os.path.basename(executable) or "unknown"
    name = re.sub(r"[^A-Za-z0-9._+:-]", "_", name)
    return name[:80] or "unknown"


class EventAssembler:
    def __init__(self):
        self.current_key = None
        self.current = None

    def push(self, raw_line):
        is_marker = "agent_process_launch " in raw_line
        is_agent_syscall = (
            "type=SYSCALL " in raw_line
            and ('key="agent_exec"' in raw_line or "key=agent_exec" in raw_line)
        )
        is_proctitle = "type=PROCTITLE " in raw_line
        if not (is_marker or is_agent_syscall or is_proctitle):
            return None
        parsed = parse_event_line(raw_line)
        if parsed is None:
            return None
        key = parsed["key"]
        completed = None
        if self.current_key is not None and key != self.current_key:
            completed = self.current
            self.current = None
        if self.current is None:
            self.current = {
                "epoch": parsed["epoch"],
                "node": parsed["node"],
                "records": [],
            }
            self.current_key = key
        self.current["records"].append((parsed["type"], parsed["body"]))
        if (is_marker or is_proctitle) and completed is None:
            completed = self.current
            self.current = None
            self.current_key = None
        return completed

    def finish(self):
        completed = self.current
        self.current = None
        self.current_key = None
        return completed


class ProcessIndex:
    def __init__(self, path, *, journal_mode="WAL"):
        self.path = path
        self.connection = sqlite3.connect(path, timeout=30)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA busy_timeout = 30000")
        self.connection.execute(f"PRAGMA journal_mode = {journal_mode}")
        self.connection.execute("PRAGMA synchronous = NORMAL")
        self.connection.execute("PRAGMA foreign_keys = ON")
        self.pending_sessions = collections.defaultdict(list)
        self.exec_counts = collections.Counter()
        self.pending_events = 0
        self.last_flush = time.monotonic()
        self.coverage_start = None
        self.coverage_end = None
        self._create_schema()

    def _create_schema(self):
        self.connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS metadata (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sessions (
              id INTEGER PRIMARY KEY,
              schema_version INTEGER NOT NULL,
              host TEXT NOT NULL,
              boot_id TEXT NOT NULL,
              started_epoch REAL NOT NULL,
              started_at TEXT NOT NULL,
              root_pid INTEGER NOT NULL,
              uid INTEGER NOT NULL,
              gid INTEGER NOT NULL,
              original_auid INTEGER NOT NULL,
              audit_auid INTEGER NOT NULL,
              label_status TEXT NOT NULL,
              cwd TEXT NOT NULL,
              harness TEXT,
              launcher_argv_json TEXT,
              UNIQUE(host, boot_id, root_pid, started_at)
            );
            CREATE INDEX IF NOT EXISTS sessions_started_epoch
              ON sessions(started_epoch);
            CREATE TABLE IF NOT EXISTS exec_daily (
              day TEXT NOT NULL,
              executable TEXT NOT NULL,
              attempts INTEGER NOT NULL,
              PRIMARY KEY(day, executable)
            );
            """
        )
        self.connection.execute(
            "INSERT INTO metadata(key, value) VALUES('schema_version', ?) "
            "ON CONFLICT(key) DO NOTHING",
            (str(SCHEMA_VERSION),),
        )
        schema = self.connection.execute(
            "SELECT value FROM metadata WHERE key = 'schema_version'"
        ).fetchone()
        if schema is None or int(schema[0]) != SCHEMA_VERSION:
            raise RuntimeError("unsupported process index schema")
        self.connection.commit()

    def load_recent_pending_sessions(self, reference_epoch):
        rows = self.connection.execute(
            "SELECT id, root_pid, started_epoch FROM sessions "
            "WHERE launcher_argv_json IS NULL AND label_status = 'labeled' "
            "AND started_epoch >= ?",
            (reference_epoch - 10,),
        )
        for row in rows:
            self.pending_sessions[row["root_pid"]].append(
                (row["id"], row["started_epoch"])
            )

    def _record_coverage(self, epoch):
        if self.coverage_start is None or epoch < self.coverage_start:
            self.coverage_start = epoch
        if self.coverage_end is None or epoch > self.coverage_end:
            self.coverage_end = epoch

    def process_event(self, event):
        if event is None:
            return
        marker = None
        syscall_body = None
        proctitle = None
        for record_type, body in event["records"]:
            if record_type == "USER":
                match = MARKER_RE.search(body)
                if match is not None:
                    marker = parse_fields(match.group("fields"))
            elif record_type == "SYSCALL":
                syscall_body = body
            elif record_type == "PROCTITLE":
                _prefix, _separator, value = body.partition("proctitle=")
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                proctitle = value or None

        if marker is not None:
            self._record_session(event, marker)
        if syscall_body is not None:
            self._record_exec(event, syscall_body, proctitle)

    def _record_session(self, event, values):
        try:
            root_pid = int(values["root_pid"])
        except (KeyError, ValueError):
            return
        epoch = event["epoch"]
        host = decode_hex(values.get("host_hex", "")) or event["node"] or "unknown"
        session_values = (
            int(values.get("schema", "1")),
            host,
            values.get("boot_id", "unknown"),
            epoch,
            format_time(epoch),
            root_pid,
            int(values.get("ruid", "-1")),
            int(values.get("rgid", "-1")),
            int(values.get("original_auid", "4294967295")),
            int(values.get("audit_auid", "4294967295")),
            values.get("label", "degraded"),
            decode_hex(values.get("cwd_hex", "")),
        )
        cursor = self.connection.execute(
            """
            INSERT INTO sessions(
              schema_version, host, boot_id, started_epoch, started_at,
              root_pid, uid, gid, original_auid, audit_auid, label_status, cwd
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(host, boot_id, root_pid, started_at) DO NOTHING
            """,
            session_values,
        )
        if cursor.rowcount == 1:
            session_id = cursor.lastrowid
        else:
            row = self.connection.execute(
                "SELECT id FROM sessions WHERE host = ? AND boot_id = ? "
                "AND root_pid = ? AND started_at = ?",
                (host, values.get("boot_id", "unknown"), root_pid, format_time(epoch)),
            ).fetchone()
            if row is None:
                return
            session_id = row["id"]
        if values.get("label", "degraded") == "labeled":
            self.pending_sessions[root_pid].append((session_id, epoch))
        self.pending_events += 1
        self._record_coverage(epoch)

    def _record_exec(self, event, syscall_body, proctitle):
        epoch = event["epoch"]
        day = dt.datetime.fromtimestamp(epoch, dt.timezone.utc).date().isoformat()
        executable = field_value(syscall_body, "exe") or "unknown"
        self.exec_counts[(day, executable_name(executable))] += 1
        self.pending_events += 1
        self._record_coverage(epoch)

        if proctitle is None:
            return
        pid_value = field_value(syscall_body, "pid")
        if pid_value is None:
            return
        try:
            pid = int(pid_value)
        except ValueError:
            return
        candidates = self.pending_sessions.get(pid, [])
        for index in range(len(candidates) - 1, -1, -1):
            session_id, started_epoch = candidates[index]
            if epoch < started_epoch or epoch - started_epoch > 10:
                continue
            argv = decode_proctitle(proctitle)
            self.connection.execute(
                "UPDATE sessions SET harness = ?, launcher_argv_json = ? WHERE id = ?",
                (harness_from_argv(argv), json.dumps(argv, separators=(",", ":")), session_id),
            )
            del candidates[index]
            break
        if not candidates:
            self.pending_sessions.pop(pid, None)

    def flush(self, *, heartbeat_epoch=None, force=False):
        elapsed = time.monotonic() - self.last_flush
        if not force and self.pending_events < 10000 and elapsed < 1:
            return
        if self.exec_counts:
            self.connection.executemany(
                """
                INSERT INTO exec_daily(day, executable, attempts) VALUES(?, ?, ?)
                ON CONFLICT(day, executable) DO UPDATE SET
                  attempts = attempts + excluded.attempts
                """,
                ((day, executable, count) for (day, executable), count in self.exec_counts.items()),
            )
            self.exec_counts.clear()
        if self.coverage_start is not None:
            self._update_coverage_metadata()
        if heartbeat_epoch is not None:
            self._set_metadata("indexer_heartbeat_epoch", str(heartbeat_epoch))
            self._set_metadata("indexer_pid", str(os.getpid()))
        self.connection.commit()
        self.pending_events = 0
        self.last_flush = time.monotonic()

    def _set_metadata(self, key, value):
        self.connection.execute(
            "INSERT INTO metadata(key, value) VALUES(?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )

    def _update_coverage_metadata(self):
        for key, value, reducer in (
            ("coverage_start_epoch", self.coverage_start, min),
            ("coverage_end_epoch", self.coverage_end, max),
        ):
            row = self.connection.execute(
                "SELECT value FROM metadata WHERE key = ?", (key,)
            ).fetchone()
            if row is not None:
                value = reducer(value, float(row[0]))
            self._set_metadata(key, str(value))

    def close(self, *, heartbeat_epoch=None):
        self.flush(heartbeat_epoch=heartbeat_epoch, force=True)
        self.connection.close()


def open_read_only(database):
    uri = "file:" + os.path.abspath(database) + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=30)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA busy_timeout = 30000")
    schema = connection.execute(
        "SELECT value FROM metadata WHERE key = 'schema_version'"
    ).fetchone()
    if schema is None or int(schema[0]) != SCHEMA_VERSION:
        connection.close()
        raise RuntimeError("unsupported process index schema")
    return connection


def build_index(args):
    os.umask(0o077)
    index = ProcessIndex(args.database, journal_mode="DELETE")
    index.load_recent_pending_sessions(parse_time(args.now))
    assembler = EventAssembler()
    try:
        for path in args.inputs:
            with open(path, "r", encoding="utf-8", errors="replace") as stream:
                for line in stream:
                    index.process_event(assembler.push(line))
                    index.flush()
        index.process_event(assembler.finish())
        index._set_metadata("bootstrap_complete", "1")
        index.close()
    except BaseException:
        index.connection.close()
        raise
    os.chmod(args.database, 0o600)


def ingest_stream(args):
    os.umask(0o077)
    now = time.time()
    syslog.openlog("agent-process-index", syslog.LOG_PID, syslog.LOG_AUTHPRIV)
    syslog.syslog(syslog.LOG_INFO, "Audit dispatcher indexer started")
    index = ProcessIndex(args.database, journal_mode="WAL")
    index.load_recent_pending_sessions(now)
    index._set_metadata("indexer_started_epoch", str(now))
    index.flush(heartbeat_epoch=now, force=True)
    assembler = EventAssembler()
    try:
        while True:
            ready, _writable, _errors = select.select([sys.stdin], [], [], 15)
            if not ready:
                index.flush(heartbeat_epoch=time.time(), force=True)
                continue
            line = sys.stdin.readline()
            if line == "":
                break
            index.process_event(assembler.push(line))
            index.flush(heartbeat_epoch=time.time())
        index.process_event(assembler.finish())
        index.close(heartbeat_epoch=time.time())
        syslog.syslog(syslog.LOG_WARNING, "Audit dispatcher input closed")
    except BaseException:
        index.connection.close()
        raise


def validate_index(args):
    connection = open_read_only(args.database)
    complete = connection.execute(
        "SELECT value FROM metadata WHERE key = 'bootstrap_complete'"
    ).fetchone()
    connection.close()
    if complete is None or complete[0] != "1":
        raise RuntimeError("process index bootstrap is incomplete")


def status_index(args):
    try:
        connection = open_read_only(args.database)
    except (OSError, RuntimeError, sqlite3.Error) as error:
        print("index: unavailable")
        print(f"index-error: {error}")
        return 1
    now = parse_time(args.now)
    metadata = {
        row["key"]: row["value"]
        for row in connection.execute("SELECT key, value FROM metadata")
    }
    sessions = connection.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
    degraded = connection.execute(
        "SELECT COUNT(*) FROM sessions WHERE label_status = 'degraded'"
    ).fetchone()[0]
    exec_attempts = connection.execute(
        "SELECT COALESCE(SUM(attempts), 0) FROM exec_daily"
    ).fetchone()[0]
    heartbeat = float(metadata.get("indexer_heartbeat_epoch", "0"))
    heartbeat_age = max(0, int(now - heartbeat)) if heartbeat else -1
    active = heartbeat_age >= 0 and heartbeat_age <= args.max_heartbeat_age
    print("index: ready")
    print(f"indexer: {'active' if active else 'stale'}")
    print(f"indexer-heartbeat-age-seconds: {heartbeat_age}")
    print(f"indexed-sessions: {sessions}")
    print(f"indexed-exec-attempts: {exec_attempts}")
    print(f"degraded-launches-retained: {degraded}")
    if "coverage_start_epoch" in metadata:
        print(f"index-coverage-start: {format_time(float(metadata['coverage_start_epoch']))}")
    if "coverage_end_epoch" in metadata:
        print(f"index-coverage-end: {format_time(float(metadata['coverage_end_epoch']))}")
    connection.close()
    return 0 if active else 1


def report_index(args):
    now = parse_time(args.now)
    since = now - args.days * 86400
    since_day = dt.datetime.fromtimestamp(since, dt.timezone.utc).date().isoformat()
    until_day = dt.datetime.fromtimestamp(now, dt.timezone.utc).date().isoformat()
    connection = open_read_only(args.database)
    session_rows = connection.execute(
        "SELECT label_status, COALESCE(harness, 'unresolved') AS harness "
        "FROM sessions WHERE started_epoch >= ? AND started_epoch <= ?",
        (since, now),
    ).fetchall()
    labels = collections.Counter(row["label_status"] for row in session_rows)
    harnesses = collections.Counter(row["harness"] for row in session_rows)
    exec_attempts = connection.execute(
        "SELECT COALESCE(SUM(attempts), 0) FROM exec_daily "
        "WHERE day >= ? AND day <= ?",
        (since_day, until_day),
    ).fetchone()[0]
    executables = connection.execute(
        "SELECT executable, SUM(attempts) AS attempts FROM exec_daily "
        "WHERE day >= ? AND day <= ? GROUP BY executable "
        "ORDER BY attempts DESC, executable LIMIT 10",
        (since_day, until_day),
    ).fetchall()
    connection.close()

    print(f"- Agent launches: {len(session_rows)}")
    print(f"- Labeled launches: {labels['labeled']}")
    print(f"- Degraded launches: {labels['degraded']}")
    print(f"- Agent-tree exec attempts: {exec_attempts}")
    print("- Exec summary granularity: UTC day")
    if harnesses:
        harness_text = ", ".join(
            f"{name}={count}" for name, count in sorted(harnesses.items())
        )
    else:
        harness_text = "none"
    print(f"- Harnesses: {harness_text}")
    print("- Top executables:")
    if executables:
        for row in executables:
            print(f"  - `{row['executable']}`: {row['attempts']}")
    else:
        print("  - none")


def sessions_index(args):
    since = parse_time(args.since)
    until = parse_time(args.until)
    conditions = []
    parameters = []
    if since is not None:
        conditions.append("started_epoch >= ?")
        parameters.append(since)
    if until is not None:
        conditions.append("started_epoch <= ?")
        parameters.append(until)
    where = " WHERE " + " AND ".join(conditions) if conditions else ""
    connection = open_read_only(args.database)
    rows = connection.execute(
        "SELECT * FROM sessions" + where + " ORDER BY started_epoch", parameters
    )
    for row in rows:
        record = {
            "schema_version": row["schema_version"],
            "host": row["host"],
            "boot_id": row["boot_id"],
            "started_at": row["started_at"],
            "root_pid": row["root_pid"],
            "uid": row["uid"],
            "gid": row["gid"],
            "original_auid": row["original_auid"],
            "audit_auid": row["audit_auid"],
            "label_status": row["label_status"],
            "cwd": row["cwd"],
            "harness": row["harness"],
            "launcher_argv": (
                json.loads(row["launcher_argv_json"])
                if row["launcher_argv_json"] is not None
                else None
            ),
        }
        if args.as_json:
            print(json.dumps(record, separators=(",", ":"), sort_keys=True))
        else:
            print(
                f"{record['started_at']} {record['host']} pid={record['root_pid']} "
                f"uid={record['uid']} label={record['label_status']} "
                f"harness={record['harness'] or 'unresolved'} cwd={record['cwd']}"
            )
    connection.close()


def prune_index(args):
    now = parse_time(args.now)
    cutoff_epoch = now - args.days * 86400
    cutoff_day = dt.datetime.fromtimestamp(cutoff_epoch, dt.timezone.utc).date().isoformat()
    connection = sqlite3.connect(args.database, timeout=30)
    connection.execute("PRAGMA busy_timeout = 30000")
    connection.execute("DELETE FROM sessions WHERE started_epoch < ?", (cutoff_epoch,))
    connection.execute("DELETE FROM exec_daily WHERE day < ?", (cutoff_day,))
    connection.commit()
    connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    connection.close()


def positive_integer(value):
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def main():
    parser = argparse.ArgumentParser(description="maintain the compact agent process index")
    subparsers = parser.add_subparsers(dest="command", required=True)

    build = subparsers.add_parser("build")
    build.add_argument("--database", required=True)
    build.add_argument("--now", default="now")
    build.add_argument("inputs", nargs="*")
    build.set_defaults(function=build_index)

    ingest = subparsers.add_parser("ingest")
    ingest.add_argument("database")
    ingest.set_defaults(function=ingest_stream)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--database", required=True)
    validate.set_defaults(function=validate_index)

    status = subparsers.add_parser("status")
    status.add_argument("--database", required=True)
    status.add_argument("--now", default="now")
    status.add_argument("--max-heartbeat-age", type=positive_integer, default=120)
    status.set_defaults(function=status_index)

    report = subparsers.add_parser("report")
    report.add_argument("--database", required=True)
    report.add_argument("--days", type=positive_integer, required=True)
    report.add_argument("--now", default="now")
    report.set_defaults(function=report_index)

    sessions = subparsers.add_parser("sessions")
    sessions.add_argument("--database", required=True)
    sessions.add_argument("--json", action="store_true", dest="as_json")
    sessions.add_argument("--since")
    sessions.add_argument("--until")
    sessions.set_defaults(function=sessions_index)

    prune = subparsers.add_parser("prune")
    prune.add_argument("--database", required=True)
    prune.add_argument("--days", type=positive_integer, required=True)
    prune.add_argument("--now", default="now")
    prune.set_defaults(function=prune_index)

    args = parser.parse_args()
    try:
        result = args.function(args)
    except (OSError, RuntimeError, sqlite3.Error, ValueError) as error:
        message = f"agent-process-index: {error}"
        print(message, file=sys.stderr)
        syslog.openlog("agent-process-index", syslog.LOG_PID, syslog.LOG_AUTHPRIV)
        syslog.syslog(syslog.LOG_ERR, message)
        return 1
    return result or 0


if __name__ == "__main__":
    raise SystemExit(main())
