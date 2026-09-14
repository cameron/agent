#!/usr/bin/env python3
"""Session lifecycle helpers behind agent resume and the title watcher."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

import agent_transcripts as transcripts


def run(args, **kwargs):
    try:
        return subprocess.run(args, text=True, **kwargs)
    except OSError:
        return None


def capture(args):
    result = run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return result.stdout.strip() if result and result.returncode == 0 else ""


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False


def select_session(rows, reference):
    harness, native = transcripts.split_session_reference(reference)
    if ":" in reference and reference.split(":", 1)[0] not in transcripts.PARSERS:
        raise ValueError("unsupported harness prefix '%s'." % reference.split(":", 1)[0])
    if native is None or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", native):
        raise ValueError("invalid native session ID '%s'." % reference.split(":")[-1])
    matches = {}
    for row in sorted(rows, key=lambda row: (
            not bool(row.get("cwd")), row.get("started_at") or "", row.get("path") or "")):
        if row.get("session_id") != native or (harness and row.get("harness") != harness):
            continue
        path = row.get("path") or ""
        if row.get("harness") == "claude" and "/subagents/" in path:
            continue
        if row.get("harness") == "codex" and path and not path.endswith(native + ".jsonl"):
            continue
        matches.setdefault(row["harness"], row)
    if not matches:
        raise ValueError("no indexed session has native ID '%s'." % reference)
    if len(matches) > 1:
        raise ValueError("native ID '%s' is ambiguous; use HARNESS:ID." % reference)
    return next(iter(matches.values()))


def resume(args):
    class ResumeParser(argparse.ArgumentParser):
        def error(self, message):
            self.print_usage(sys.stderr)
            self.exit(2)

    parser = ResumeParser(
        prog="agent resume", usage="agent resume [ID|HARNESS:ID] | agent resume [--all] [--list] [--limit N]")
    parser.add_argument("--agent", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--transcripts", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--role", action="append", default=[], help=argparse.SUPPRESS)
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--limit", type=int)
    parser.add_argument("session", nargs="?")
    options = parser.parse_args(args)
    if options.session and (options.all or options.list or options.limit is not None):
        parser.error("a session ID cannot be combined with picker options")
    if options.limit is not None and options.limit < 0:
        parser.error("--limit must be nonnegative")
    if not shutil.which(options.transcripts):
        raise ValueError("%s is not available." % options.transcripts)
    # A failed refresh can still leave an index suitable for resuming work.
    run([options.transcripts, "index", "--quiet"])
    if options.session:
        result = run([options.transcripts, "sessions", "--json"], stdout=subprocess.PIPE)
        if not result or result.returncode:
            return 1
        selected = select_session(list(transcripts.json_records(result.stdout.splitlines())), options.session)
    else:
        recent = [options.transcripts, "recent", "--limit", str(options.limit if options.limit is not None else 30)]
        if not options.all:
            repo = capture(["git", "rev-parse", "--show-toplevel"]) or os.getcwd()
            recent += ["--repo", repo]
        if options.list or not shutil.which("fzf") or not (sys.stdin.isatty() and sys.stdout.isatty()):
            result = run(recent)
            return result.returncode if result else 1
        result = run(recent + ["--json"], stdout=subprocess.PIPE)
        if not result or result.returncode:
            return 1
        rows = list(transcripts.json_records(result.stdout.splitlines()))
        if not rows:
            raise ValueError("no indexed sessions matched; try --all.")
        # Send only display text and an ordinal through fzf. Paths and IDs
        # stay in the original objects, so tabs and backslashes survive.
        lines = []
        for index, row in enumerate(rows):
            display = [str(index), (row.get("last_active") or "")[:16], row.get("harness"),
                       row.get("title") or "-", row.get("description") or "-", row.get("repo")]
            lines.append("\t".join(" ".join(str(value or "").split()) for value in display))
        choice = run(["fzf", "--delimiter", "\t", "--with-nth", "2..", "--no-multi",
                      "--height", "80%", "--reverse", "--prompt", "resume> "],
                     input="\n".join(lines) + "\n", stdout=subprocess.PIPE)
        if not choice or choice.returncode:
            return 1
        selected = rows[int(choice.stdout.split("\t", 1)[0])]
    harness = selected.get("harness")
    session_id = selected.get("session_id")
    if not session_id:
        raise ValueError("the chosen session has no native session ID.")
    if harness not in transcripts.RESUME_COMMANDS:
        raise ValueError("unsupported harness '%s'." % harness)
    cwd = selected.get("cwd") or ""
    if os.path.isdir(cwd):
        os.chdir(cwd)
    else:
        print("agent resume: session directory is gone; staying in %s" % os.getcwd(), file=sys.stderr)
    argv = [options.agent]
    for role in options.role:
        argv += ["--role", role]
    argv += [harness, {"codex": "resume", "claude": "--resume", "pi": "--session"}[harness], session_id]
    os.execv(options.agent, argv)


def codex_writer_id(pid):
    pending, seen = [pid], set()
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        process = Path("/proc") / str(pid)
        try:
            for fd in (process / "fd").iterdir():
                try:
                    target = Path(os.readlink(fd))
                except OSError:
                    continue
                if target.parent.name == "thread-writer-locks" and target.suffix == ".lock":
                    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", target.stem):
                        return target.stem
            pending.extend(int(child) for child in (process / "task" / str(pid) / "children").read_text().split())
        except OSError:
            continue
    return ""


class TitleWatcher:
    def __init__(self, options):
        self.options = options
        self.pane = options.pane
        self.session_name = options.session_name
        self.expected = options.session_id
        self.root = Path(transcripts.session_roots(options.harness, archived=False)[0])
        self.state = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / ("agent-window-titles-%s" % os.getuid())
        self.registrations = self.state / "registrations"
        self.registrations.mkdir(parents=True, exist_ok=True)
        self.state.chmod(0o700)
        self.registrations.chmod(0o700)
        self.registration = self.registrations / str(os.getpid())
        self.registration.write_text("\t".join([options.harness, options.cwd, str(options.pid),
                                               str(time.time()), self.pane, self.session_name]) + "\n")
        self.log_path = self.state / (self.pane.lstrip("%") + ".log")
        self.log_path.write_text("")

    def log(self, message):
        with self.log_path.open("a") as stream:
            stream.write(time.strftime("%Y-%m-%dT%H:%M:%S%z ") + message + "\n")

    def tmux(self, *args):
        return capture(["tmux", *args])

    def environment(self, name):
        entry = self.tmux("show-environment", "-t", self.pane, name)
        return entry[len(name) + 1:] if entry.startswith(name + "=") else ""

    def refresh_name(self):
        self.session_name = self.tmux("display-message", "-p", "-t", self.pane, "#S") or self.session_name

    def call_logged(self, args, path=None):
        with (path or self.log_path).open("a") as stream:
            result = run(args, stdin=subprocess.DEVNULL, stdout=stream, stderr=stream)
        return bool(result and result.returncode == 0)

    def apply_title(self, title):
        mode = self.tmux("show-options", "-wqv", "-t", self.pane, "@agent_title_mode")
        if mode != "manual":
            if not self.call_logged(["tmux", "rename-window", "-t", self.pane, "--", title]):
                return False
            self.log("renamed window: " + title)
        else:
            self.log("manual override; tmux title unchanged")
        retitle = os.environ.get("TMUX_RETITLE_BIN") or shutil.which("tmux.retitle")
        if retitle:
            args = [retitle, "--auto", "--session", self.pane]
            project = self.environment("TMUX_PROJECT")
            if project:
                args += ["--repo", project]
            self.call_logged(args + ["--", title])
            self.refresh_name()
        return True

    def existing_title(self, path):
        title = transcripts.sidecar_line(str(path) + ".title")
        return bool(title and len(title) <= 40 and self.apply_title(title))

    def record_workspace(self, path):
        recorder = shutil.which("tmux.workspace-resume")
        workspace = self.environment("TMUX_WORKSPACE") or os.environ.get("TMUX_WORKSPACE")
        if recorder and workspace and os.path.isdir(workspace):
            self.refresh_name()
            self.call_logged([recorder, "record-agent", "--workspace", workspace, "--session", self.session_name,
                              "--pane", self.pane, "--harness", self.options.harness,
                              "--session-file", str(path), "--cwd", self.options.cwd])

    def attach_matrix(self, path):
        bridge = shutil.which("matrix-agent-tmux")
        if bridge:
            self.call_logged([bridge, "attach", "--pid", str(self.options.pid), "--harness", self.options.harness,
                              "--session-file", str(path)], self.state / (self.pane.lstrip("%") + ".matrix.log"))

    def generate(self, path, message):
        generator = os.environ.get("CONTENT2TITLE_BIN") or shutil.which("content2title")
        if not generator:
            self.log("shared title generator unavailable")
            return
        self.refresh_name()
        provider = os.environ.get("AGENT_TITLE_PROVIDER") or "codex"
        model = os.environ.get("AGENT_TITLE_MODEL") or ("gpt-5.6-luna" if provider == "codex" else "")
        args = [generator, "--provider", provider]
        if model:
            args += ["--model", model]
        result = run(args + ["--kind", "query", "--existing-title", self.session_name, "--", message], stdout=subprocess.PIPE)
        if not result or result.returncode or not result.stdout.strip():
            self.log("shared title generation failed")
            return
        title = result.stdout.strip()
        transcripts.write_sidecar(str(path) + ".title", title)
        self.apply_title(title)

    def unambiguous(self):
        matches = 0
        for path in self.registrations.iterdir():
            try:
                row = path.read_text().split("\t")
            except OSError:
                continue
            if len(row) >= 3 and row[:2] == [self.options.harness, self.options.cwd] and alive(row[2]):
                matches += 1
        return matches == 1

    def files(self):
        for directory, _, names in os.walk(self.root):
            for name in names:
                if name.endswith(".jsonl"):
                    yield Path(directory) / name

    def watch(self):
        sizes = {}
        for path in self.files():
            try:
                sizes[path] = path.stat().st_size
            except OSError:
                pass
        baseline = set(sizes)
        offsets = dict(sizes)
        metadata = {}
        ambiguous = set()
        selected = None
        Path(self.options.ready).touch()
        self.log("watching %s in session %s" % (self.options.harness, self.session_name))
        interval = float(os.environ.get("AGENT_TITLE_POLL_SECONDS") or "1")
        while alive(self.options.pid) and self.tmux("display-message", "-p", "-t", self.pane, "#{pane_id}"):
            if not self.expected and self.options.harness == "codex":
                self.expected = codex_writer_id(self.options.pid)
            for path in [selected] if selected else self.files():
                try:
                    if not self.expected and (path in baseline or path in ambiguous):
                        continue
                    size = path.stat().st_size
                    if not selected:
                        if path not in metadata or not all(metadata[path]):
                            metadata[path] = transcripts.transcript_metadata(path)
                        harness, session_id, cwd = metadata[path]
                        if harness != self.options.harness:
                            continue
                        if self.expected:
                            if session_id != self.expected:
                                continue
                        elif cwd != self.options.cwd:
                            continue
                        elif not self.unambiguous():
                            ambiguous.add(path)
                            self.log("refused ambiguous transcript: " + str(path))
                            continue
                        selected = path
                        self.record_workspace(path)
                        if self.existing_title(path):
                            self.record_workspace(path)
                            self.attach_matrix(path)
                            return
                    if size == sizes.get(path):
                        continue
                    offset = offsets.get(path, 0)
                    if size < offset:
                        offset = 0
                    records, offsets[path] = transcripts.appended_records(path, offset)
                    sizes[path] = size
                    self.record_workspace(path)
                    for record in records:
                        message = transcripts.eligible_prompt(transcripts.user_text(self.options.harness, record))
                        if message:
                            self.attach_matrix(path)
                            self.generate(path, message)
                            self.record_workspace(path)
                            return
                except OSError as error:
                    self.log(str(error))
            time.sleep(interval)


def main(argv):
    if argv and argv[0] == "resume":
        try:
            return resume(argv[1:]) or 0
        except (ValueError, OSError) as error:
            print("agent resume: " + str(error), file=sys.stderr)
            return 1
    parser = argparse.ArgumentParser(prog="agent __title-watch")
    parser.add_argument("ready")
    parser.add_argument("harness", choices=transcripts.PARSERS)
    parser.add_argument("pane")
    parser.add_argument("cwd")
    parser.add_argument("pid", type=int)
    parser.add_argument("session_name")
    parser.add_argument("session_id", nargs="?", default="")
    watcher = TitleWatcher(parser.parse_args(argv))
    try:
        watcher.watch()
    finally:
        watcher.registration.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
