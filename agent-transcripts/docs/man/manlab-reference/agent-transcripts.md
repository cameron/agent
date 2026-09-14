# audit agent transcripts through one SQLite index

## SYNOPSIS

`agent transcripts [--db PATH] index [--session-dir DIR ...] [--quiet]`

`agent transcripts [--db PATH] export-usage [--after REVISION] [--index-id ID]`

`agent transcripts [--db PATH] sessions [--json]`

`agent transcripts [--db PATH] recent [--limit N] [--repo PATH] [--json]`

`agent transcripts [--db PATH] tail [-n N] SESSION [--session-dir DIR ...]
[--json]`

`agent transcripts [--db PATH] annotate [--limit N] [--since TIME] [--force]
[--generator CMD] [--timeout SECONDS] [--quiet]`

`agent transcripts [--db PATH] events [--kind KIND ...] [--session MATCH]
[--json]`

`agent transcripts [--db PATH] report man|co-reads|early-reads|usage
[--min N] [--turns N] [--json]`

## DESCRIPTION

`agent transcripts` is the transcript interface bundled with `agent`.
It runs without starting a harness or reading agent instructions. The standalone
`agent-transcripts` command remains available for existing callers. Both use
the same Python implementation and database.

The live title watcher and `agent resume` use shared readers for the same
formats. The index stores selected audit events, not a complete conversation:
user excerpts are limited to 500 characters, commands to 2,000, and assistant
prose and full tool results are not stored. `tail` reads the original log.

`agent transcripts` parses the session JSONL files that Codex, Claude, and Pi
write, and normalizes them into one SQLite index. Each harness has a
different transcript schema. The index gives every audit one common event
stream, so an audit is a query, not a new parser.

The index holds one `sessions` row for each transcript file and one `events`
row for each normalized event. The event kinds are:

- `user` —— a real user message. The message count gives the turn number.
- `tool` —— a tool call, with the command or the primary argument.
- `man_read` —— a manual page read, found in shell commands. The `name`
  column holds the section when the command gave one.
- `file_read` —— a file read, from a native read tool or from a shell reader
  such as `cat`, `head`, or `tail`.
- `usage` —— token counts for one model request: input, cached, cache-write,
  and output. Pi usage is included when the transcript records it.

A `man_read` or `file_read` event copies the character count of its tool
result when the transcript records the result. For a compound command the
count is an approximation: it covers the full command output.

Lookup commands do not count as reads. `man -k`, `man -f`, `man -w`,
`apropos`, and `whatis` produce no `man_read` event.

Only `index` and `annotate` write to the index. The read commands
(`sessions`, `recent`, `events`, `report`, `export-usage`) open it read-only, so a read
never touches schema metadata, and they fail with a clear error when the
index does not exist yet. Every connection waits at most
`AGENT_TRANSCRIPTS_DB_TIMEOUT` seconds (default 5) for a busy database
and then reports which process class holds the lock instead of blocking
indefinitely.

## COMMANDS

`index`

: Scan the session roots and update the index. The scan is incremental: a
file with an unchanged size and modification time is not read again. A
changed file replaces its old rows. A deleted file leaves the index. The
default roots are the Codex, Claude, and Pi session directories (see FILES).
`--session-dir DIR` replaces the default roots; repeat it for more roots.
The harness of each file comes from the file content, not from its location.
Parser upgrades reindex unchanged files. Archived Codex sessions are included.
`--usage-only` stores numeric usage and session metadata without conversation,
tool events, or sidecar titles. Use a separate `--db` for this mode. Switching
modes reindexes files. Lab throughput uses this separate numeric index so its
collector can run on hosts whose interactive audit tool is an older version.

`export-usage`

: Write a version 1 JSON document containing numeric usage snapshots. Each
snapshot has a hashed copy ID, native session ID, harness, repository, file size,
revision, invalid-record count, and request records. Requests contain an ID,
timestamp, model, input, cached input, cache-write input, output, and reasoning
output. No prompts, responses, titles, tool arguments, or transcript paths leave
the source. Input includes cache; output includes reasoning. This normalization
does not change the raw token fields returned by the older audit reports.

Repeated Codex cumulative totals and repeated Claude message IDs count once.
Pi usage is read when present. The model is recorded for each request.
`--after REVISION --index-id ID` returns only changed file snapshots. Save the
returned revision only after importing the document. A changed index identity
automatically returns a full export. Deleting a source log removes it from the
audit index; downstream historical stores keep their previously imported usage.

`sessions`

: List the indexed sessions with harness, repository, working directory,
model, start time, turn count, title, and description. The repository is the
session working directory with any `.worktrees/NAME` suffix removed, so
worktree sessions group under their repository. The title and description
come from the sidecar files (see FILES); `index` reads the sidecars on every
run, so a title written after a transcript stopped changing still lands.

`recent`

: List sessions with the newest first, by transcript file modification time.
Each row carries the working directory, turn count, title, description, and
the native resume command for its harness: `codex resume ID`,
`claude --resume ID`, or `pi --session ID`. `--limit N` caps the list
(default 20); `--repo PATH` keeps one repository. This is the data source
for `agent resume` (see agent(lab-reference)).

`tail`

: Read the live transcript file for `SESSION` and print its last normalized
conversation items. `SESSION` can be `HARNESS:NATIVE-ID` or a native ID that
identifies one indexed session. Items are `user`, `assistant`, or `tool`;
tool items include the tool name and primary command or arguments. `-n N`
sets the item limit (default 20). `--json` emits one JSON object per item for
callers that need to select a response relative to a tool call. This command
does not assign turn semantics and does not require the SQLite copy to be
current; the index is used only to locate a transcript whose file name does
not contain its session ID. `--session-dir DIR` replaces the default search
roots and can be repeated.

`annotate`

: Generate the missing titles and descriptions. For each session without a
title or a description, the command sends the first real user message to a
generator and writes the results to the sidecar files and to the index. A
title that the interactive window titler already wrote is kept. Sessions
whose only user messages are command boilerplate are skipped. The default
generator is one `pi` call to the local title model
(`titles/gemma-4-26b-a4b-q4-cpu`, override with
`AGENT_TRANSCRIPTS_ANNOTATE_MODEL`); it must reply with two lines, a title
of at most 3 words and one sentence. `--generator CMD` (or
`AGENT_TRANSCRIPTS_ANNOTATOR`) replaces it with a shell command that reads
the message on stdin and prints the same two lines. `--limit N` stops after
N generation attempts, `--since TIME` skips sessions started before TIME,
`--force` regenerates existing annotations, and `--timeout SECONDS` bounds
each generation (default 90, or `AGENT_TITLE_TIMEOUT_SECONDS`). The summary
line reports `annotated`, `failed`, and `skipped` counts.

`events`

: Print normalized events. `--kind` filters by event kind; repeat it for
more kinds. `--session` matches a path substring or an exact session ID.

`report man`

: Count manual-page reads: reads, distinct sessions, and result characters
per page.

`report co-reads`

: Count session co-occurrence for each pair of manual pages. Two pages read
in the same session make one pair count. This validates prefix-bundle
groupings.

`report early-reads`

: For each repository, list the pages and files read at or before turn
`--turns` (default 2), with the fraction of the repository's sessions that
read them. A high fraction marks content to inject at agent start.

`report usage`

: Sum token counts and reference-read characters per harness. The
`read_chars` column estimates the transcript bytes spent on `man_read` and
`file_read` results —— the addressable prefix-cache volume.

All reports accept `--min N` to drop rows below N and `--json` for JSON
Lines output. The default table output is tab-separated with a header row.

## OPTIONS

`--db PATH`

: Use this SQLite file. The default is
`${XDG_STATE_HOME:-~/.local/state}/agent-transcripts/index.sqlite`, or
`AGENT_TRANSCRIPTS_DB` when that variable is set.

## FILES

The default session roots are
`${CODEX_HOME:-~/.codex}/sessions`,
`${CLAUDE_CONFIG_DIR:-~/.claude}/projects`, and
`${PI_CODING_AGENT_DIR:-~/.pi/agent}/sessions`.
A missing root is ignored. A file that no parser recognizes is counted as
skipped and does not stop the scan.

Two sidecar files can stand beside a transcript `FILE.jsonl`:

- `FILE.jsonl.title` —— a short title, one line. The interactive window
  titler in agent(lab-reference) writes it for live tmux sessions;
  `annotate` writes it for the rest.
- `FILE.jsonl.desc` —— a one-sentence description, one line. Only
  `annotate` writes it.

The sidecars are the source of truth; the index copies them on every
`index` run.

## EXAMPLES

Build the index, then show bundle candidates for one repository:

    agent transcripts index
    agent transcripts report early-reads --turns 2 --min 5

Inspect the last four items in one live Codex session:

    agent transcripts tail -n 4 codex:01ABCDEF

Show which pages travel together:

    agent transcripts report co-reads --min 10

Give every transcript of the last week a title and a description, then list
the newest sessions with their resume commands:

    agent transcripts index --quiet
    agent transcripts annotate --since 2026-08-19
    agent transcripts recent --limit 10

Ad-hoc analysis in SQL:

    sqlite3 ~/.local/state/agent-transcripts/index.sqlite \
      "SELECT detail, count(*) FROM events
       WHERE kind = 'file_read' GROUP BY 1 ORDER BY 2 DESC LIMIT 20"

## SEE ALSO

man-usage-audit(lab-reference), agent-process-collect(lab-reference),
agent(lab-reference)
