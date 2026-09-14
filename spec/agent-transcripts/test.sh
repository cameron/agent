#!/usr/bin/env bash

# Exercise agent-transcripts against hand-built Codex, Claude, and Pi
# transcript fixtures: harness sniffing, event normalization, man and file
# read extraction, result-size linking, token usage, turn numbering, the
# reports, and incremental reindexing.

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tool="$repo_root/agent-transcripts/agent_transcripts.py"
tmp="$(mktemp -d)"
archive_root="${TMPDIR:-/tmp}/rm4agent-$UID"
trap 'RM4AGENT_ROOT="$archive_root" rm4agent -r "$tmp" >/dev/null 2>&1 || true' EXIT
trap 'printf "FAIL: line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

db="$tmp/index.sqlite"
sessions_root="$tmp/sessions"
mkdir -p "$sessions_root/codex" "$sessions_root/claude" "$sessions_root/pi"

run() {
  "$repo_root/bin/agent" transcripts --db "$db" "$@"
}

python3 "$repo_root/agent-transcripts/test_readers.py" "$tool"

# Canonical entry does not inspect instruction files or require a harness.
mkdir -p "$tmp/broken-instructions"
printf 'broken template' > "$tmp/broken-instructions/AGENTS.md.tmpl"
AGENTSPATH="$tmp/broken-instructions" AGENT_TEMPLATE_BIN="$tmp/missing-renderer" \
  "$repo_root/bin/agent" transcripts --help > "$tmp/help"
[[ "$(head -n 1 "$tmp/help")" == 'usage: agent transcripts '* ]] || fail 'canonical help is missing'

# --- Codex fixture: exec-command JS calls, man read with section, token
# counts, and a fallback user message from item_completed.
cat > "$sessions_root/codex/rollout-a.jsonl" <<'EOF'
{"timestamp":"2026-08-01T10:00:00.000Z","type":"session_meta","payload":{"session_id":"codex-1","id":"codex-1","cwd":"/srv/src/bench/.worktrees/agent-x","originator":"codex-tui"}}
{"timestamp":"2026-08-01T10:00:01.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"fix the router"}]}}}
{"timestamp":"2026-08-01T10:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1","input":"const r = await tools.exec_command({\"cmd\":\"man lab-reference router && cat /srv/notes.txt; man -s lab-guide writing-lab-tests 'vfind(lab-reference)'\",\"workdir\":\"/srv\"});"}}
{"timestamp":"2026-08-01T10:00:03.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":[{"type":"input_text","text":"0123456789"}]}}
{"timestamp":"2026-08-01T10:00:04.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"c2","arguments":"{\"cmd\":\"man -k router\"}"}}
{"timestamp":"2026-08-01T10:00:05.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c2","output":[{"type":"input_text","text":"listing"}]}}
{"timestamp":"2026-08-01T10:00:06.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":5,"output_tokens":20}}}}
{"timestamp":"2026-08-01T10:00:07.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Finished Codex plan."}]}}
{"timestamp":"2026-08-01T10:00:08.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c3","input":"const r = await tools.exec_command({cmd:\"kanban step advance 'Plan ready'\",workdir:\"/srv/src\"});"}}
EOF

# --- Claude fixture: Bash and Read tools, tool_result sizes, per-message
# usage recorded once per message id, meta user rows skipped.
cat > "$sessions_root/claude/session-b.jsonl" <<'EOF'
{"type":"user","sessionId":"claude-1","cwd":"/srv/src/agent","timestamp":"2026-08-02T09:00:00.000Z","message":{"role":"user","content":"audit the router page"}}
{"type":"assistant","sessionId":"claude-1","timestamp":"2026-08-02T09:00:01.000Z","message":{"id":"m1","model":"claude-fable-5","role":"assistant","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50,"output_tokens":30},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"man lab-reference router"}}]}}
{"type":"assistant","sessionId":"claude-1","timestamp":"2026-08-02T09:00:01.500Z","message":{"id":"m1","model":"claude-fable-5","role":"assistant","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50,"output_tokens":30},"content":[{"type":"text","text":"I read the page."}]}}
{"type":"user","sessionId":"claude-1","timestamp":"2026-08-02T09:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ROUTER MANUAL PAGE TEXT"}]}}
{"type":"assistant","sessionId":"claude-1","timestamp":"2026-08-02T09:00:03.000Z","message":{"id":"m2","model":"claude-fable-5","role":"assistant","usage":{"input_tokens":20,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0,"output_tokens":40},"content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/srv/src/agent/README.md"}}]}}
{"type":"user","sessionId":"claude-1","timestamp":"2026-08-02T09:00:04.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"readme body"}]}]}}
{"type":"user","sessionId":"claude-1","isMeta":true,"timestamp":"2026-08-02T09:00:05.000Z","message":{"role":"user","content":"meta noise"}}
{"type":"user","sessionId":"claude-1","timestamp":"2026-08-02T09:00:06.000Z","message":{"role":"user","content":"now check the network page"}}
{"type":"assistant","sessionId":"claude-1","timestamp":"2026-08-02T09:00:07.000Z","message":{"id":"m3","model":"claude-fable-5","role":"assistant","usage":{"input_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":0,"output_tokens":10},"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"man lab-network"}}]}}
{"type":"assistant","sessionId":"claude-1","timestamp":"2026-08-02T09:00:08.000Z","message":{"id":"m4","model":"claude-fable-5","role":"assistant","content":[{"type":"text","text":"Finished Claude review."},{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"kanban step revise 'Needs a test'"}}]}}
EOF

# --- Pi fixture: bash and read tool calls with toolResult linking.
cat > "$sessions_root/pi/session-c.jsonl" <<'EOF'
{"type":"session","version":3,"id":"pi-1","timestamp":"2026-08-03T08:00:00.000Z","cwd":"/srv/src/bench"}
{"type":"model_change","id":"mc","parentId":null,"timestamp":"2026-08-03T08:00:00.100Z","provider":"zai","modelId":"glm-5.2"}
{"type":"message","id":"u1","timestamp":"2026-08-03T08:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"what does the router page say"}]}}
{"type":"message","id":"a1","timestamp":"2026-08-03T08:00:02.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"p1","name":"bash","arguments":{"command":"man lab-reference router"}}]}}
{"type":"message","id":"r1","timestamp":"2026-08-03T08:00:03.000Z","message":{"role":"toolResult","toolCallId":"p1","toolName":"bash","content":[{"type":"text","text":"router page"}],"isError":false}}
{"type":"message","id":"a2","timestamp":"2026-08-03T08:00:04.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"p2","name":"read","arguments":{"path":"/srv/src/bench/README.md"}}]}}
{"type":"message","id":"r2","timestamp":"2026-08-03T08:00:05.000Z","message":{"role":"toolResult","toolCallId":"p2","toolName":"read","content":[{"type":"text","text":"bench readme"}],"isError":false}}
{"type":"message","id":"a3","timestamp":"2026-08-03T08:00:06.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Finished Pi deliverable."},{"type":"toolCall","id":"p3","name":"bash","arguments":{"command":"kanban step advance 'Built it'"}}]}}
EOF

# --- Index the fixtures.
output="$(run index --session-dir "$sessions_root")"
[[ "$output" == "parsed 3 skipped 0 removed 0 indexed 3" ]] \
  || fail "first index: $output"

# --- Sessions: harness sniffing, worktree repo normalization, turn counts.
sessions="$(run sessions)"
printf '%s\n' "$sessions" | grep -q $'rollout-a.jsonl\tcodex\tcodex-1\t/srv/src/bench\t' \
  || fail "codex session row missing worktree-normalized repo: $sessions"
printf '%s\n' "$sessions" | grep -q $'session-b.jsonl\tclaude\tclaude-1\t/srv/src/agent\t/srv/src/agent\tclaude-fable-5' \
  || fail "claude session row wrong: $sessions"
printf '%s\n' "$sessions" | grep -q $'session-c.jsonl\tpi\tpi-1\t/srv/src/bench\t/srv/src/bench\tglm-5.2' \
  || fail "pi session row wrong: $sessions"

# --- Man reads: three sessions read router; lookup mode is not a read.
man_report="$(run report man)"
printf '%s\n' "$man_report" | grep -q $'^router\t3\t3\t' \
  || fail "router man count wrong: $man_report"
printf '%s\n' "$man_report" | grep -q $'^lab-network\t1\t1\t' \
  || fail "lab-network man count wrong: $man_report"
printf '%s\n' "$man_report" | grep -q $'^writing-lab-tests\t1\t1\t' \
  || fail "-s section page missing: $man_report"
printf '%s\n' "$man_report" | grep -q $'^vfind\t1\t1\t' \
  || fail "page(section) form missing: $man_report"
[[ "$(printf '%s\n' "$man_report" | tail -n +2 | wc -l)" == 4 ]] \
  || fail "unexpected man pages (lookup counted as read?): $man_report"

# --- Section capture: -s and the page(section) suffix both set name.
codex_man="$(run events --kind man_read --session codex-1 --json)"
printf '%s\n' "$codex_man" \
  | grep -q '"name": "lab-guide", "detail": "writing-lab-tests"' \
  || fail "-s section not captured: $codex_man"
printf '%s\n' "$codex_man" \
  | grep -q '"name": "lab-reference", "detail": "vfind"' \
  || fail "page(section) suffix not captured: $codex_man"

# --- The claude man_read carries its tool_result size and section name.
claude_man="$(run events --kind man_read --session claude-1 --json)"
printf '%s\n' "$claude_man" | grep -q '"name": "lab-reference"' \
  || fail "claude man_read section missing: $claude_man"
printf '%s\n' "$claude_man" | grep -q '"chars": 23' \
  || fail "claude man_read chars not linked: $claude_man"

# --- File reads from shell cat, Claude Read, and Pi read.
file_reads="$(run events --kind file_read)"
for path in /srv/notes.txt /srv/src/agent/README.md /srv/src/bench/README.md; do
  printf '%s\n' "$file_reads" | grep -q "$path" \
    || fail "file_read missing $path: $file_reads"
done

# --- Turn numbering: the second claude prompt is turn 2, its man read too.
printf '%s\n' "$(run events --kind man_read --session claude-1)" \
  | grep -q $'\t2\t.*lab-network' \
  || fail "lab-network read not in turn 2"

# --- Early reads at turn 1 include router in every repo.
early="$(run report early-reads --turns 1)"
printf '%s\n' "$early" | grep -q $'/srv/src/agent\tman_read\trouter\t1\t1\t1.0' \
  || fail "early-reads missing claude router row: $early"

# --- Co-reads: router and lab-network pair once.
co="$(run report co-reads)"
printf '%s\n' "$co" | grep -q $'lab-network\trouter\t1' \
  || fail "co-reads pair wrong: $co"

# --- Usage: claude sums three distinct message ids, once each; codex sums
# token_count events; pi has no token data but keeps read chars.
usage="$(run report usage)"
printf '%s\n' "$usage" | grep -q $'^claude\t1\t35\t3100\t50\t80\t' \
  || fail "claude usage wrong: $usage"
printf '%s\n' "$usage" | grep -q $'^codex\t1\t100\t60\t5\t20\t' \
  || fail "codex usage wrong: $usage"
printf '%s\n' "$usage" | grep -q $'^pi\t1\t0\t0\t0\t0\t' \
  || fail "pi usage wrong: $usage"

# --- Incremental: an unchanged tree parses nothing.
output="$(run index --session-dir "$sessions_root")"
[[ "$output" == "parsed 0 skipped 0 removed 0 indexed 3" ]] \
  || fail "unchanged reindex reparsed: $output"

# --- Tail is a bounded, live-file query. It returns normalized conversation
# items instead of imposing turn semantics on its callers. These records are
# appended after indexing to prove that tail does not read stale SQLite events.
cat >>"$sessions_root/codex/rollout-a.jsonl" <<'EOF'
{"timestamp":"2026-08-01T10:00:09.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Live Codex question."}]}}
{"timestamp":"2026-08-01T10:00:10.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"c4","arguments":"{\"cmd\":\"kanban step escalate 'Need an answer'\"}"}}
EOF
codex_tail="$(run tail -n 2 codex:codex-1 \
  --session-dir "$sessions_root" --json)"
[[ "$(wc -l <<<"$codex_tail")" == 2 ]] ||
  fail "codex tail did not honor -n: $codex_tail"
[[ "$(jq -r '.kind + "|" + .detail' <<<"$codex_tail")" == \
   $'assistant|Live Codex question.\ntool|kanban step escalate '\''Need an answer'\''' ]] ||
  fail "codex tail items are wrong: $codex_tail"

claude_tail="$(run tail -n 2 claude-1 \
  --session-dir "$sessions_root" --json)"
[[ "$(jq -r '.kind + "|" + .detail' <<<"$claude_tail")" == \
   $'assistant|Finished Claude review.\ntool|kanban step revise '\''Needs a test'\''' ]] ||
  fail "claude tail items are wrong: $claude_tail"

pi_tail="$(run tail -n 1 pi:pi-1 --session-dir "$sessions_root" --json)"
[[ "$(jq -r '.kind + "|" + .detail' <<<"$pi_tail")" == \
   "tool|kanban step advance 'Built it'" ]] ||
  fail "pi tail item is wrong: $pi_tail"

if run tail -n 2 codex:missing --session-dir "$sessions_root" \
    >"$tmp/missing.out" 2>"$tmp/missing.err"; then
  fail 'tail accepted a missing session'
fi
grep -Fq 'session not found: codex:missing' "$tmp/missing.err" ||
  fail 'tail did not explain a missing session'

# Tail can resolve a live session before indexing, preserving long responses
# across reverse-reader chunks and ignoring an incomplete final record.
live_root="$tmp/live"
mkdir -p "$live_root"
python3 - "$live_root/rollout-live-1.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as stream:
    for payload in [
        {"type": "session_meta", "payload": {"id": "live-1"}},
        {"type": "response_item", "payload": {
            "type": "message", "role": "assistant", "content": [
                {"type": "output_text", "text": "計画" * 40000}]}},
        {"type": "response_item", "payload": {
            "type": "function_call", "name": "exec_command",
            "arguments": json.dumps({"cmd": "kanban step advance 'Ready'"})}},
    ]:
        stream.write(json.dumps(payload, ensure_ascii=False) + "\n")
    stream.write('{"unfinished":')
PY
python3 "$tool" --db "$tmp/absent.sqlite" tail -n 2 codex:live-1 \
  --session-dir "$live_root" --json >"$tmp/live-tail.jsonl"
jq -se 'length == 2 and .[0].kind == "assistant" and
  (.[0].detail | length) == 80000 and .[1].kind == "tool"' \
  "$tmp/live-tail.jsonl" >/dev/null || fail 'live tail lost response text'
[[ ! -e "$tmp/absent.sqlite" ]] || fail 'tail created an index'
if run tail -n 0 codex:codex-1 --session-dir "$sessions_root" \
    >"$tmp/invalid.out" 2>"$tmp/invalid.err"; then
  fail 'tail accepted a nonpositive item count'
fi

# --- Changed files are reparsed and replace their rows.
cat >> "$sessions_root/pi/session-c.jsonl" <<'EOF'
{"type":"message","id":"u2","timestamp":"2026-08-03T08:00:06.000Z","message":{"role":"user","content":[{"type":"text","text":"thanks"}]}}
EOF
touch -d '2026-08-03 09:00:00' "$sessions_root/pi/session-c.jsonl"
output="$(run index --session-dir "$sessions_root")"
[[ "$output" == "parsed 2 skipped 0 removed 0 indexed 3" ]] \
  || fail "changed reindex: $output"
run sessions | grep -q $'session-c.jsonl\tpi\t.*\t2\t\t$' \
  || fail "pi turn count did not update after reindex"

# --- A removed file leaves the index.
rm4agent "$sessions_root/pi/session-c.jsonl" >/dev/null
output="$(run index --session-dir "$sessions_root")"
[[ "$output" == "parsed 0 skipped 0 removed 1 indexed 2" ]] \
  || fail "removed file not dropped: $output"
run sessions | grep -q 'session-c' && fail "deleted session still listed"

# --- An unrecognized JSONL file is skipped, not fatal.
printf '{"unrelated":true}\n' > "$sessions_root/claude/noise.jsonl"
output="$(run index --session-dir "$sessions_root")"
[[ "$output" == "parsed 0 skipped 1 removed 0 indexed 3" ]] \
  || fail "unrecognized file handling: $output"

# --- Title sidecars written by the window titler land in the index, and a
# sidecar change alone is picked up without a transcript change.
printf 'router audit\n' > "$sessions_root/claude/session-b.jsonl.title"
touch -d '2026-08-06 10:00:00' "$sessions_root/claude/session-b.jsonl"
touch -d '2026-08-05 10:00:00' "$sessions_root/codex/rollout-a.jsonl"

# A session whose only user message is command boilerplate has nothing to
# annotate from.
cat > "$sessions_root/claude/session-d.jsonl" <<'EOF'
{"type":"user","sessionId":"claude-2","cwd":"/srv/src/agent","timestamp":"2026-08-04T09:00:00.000Z","message":{"role":"user","content":"<command-name>/clear</command-name>"}}
EOF
touch -d '2026-08-04 09:00:00' "$sessions_root/claude/session-d.jsonl"

run index --session-dir "$sessions_root" --quiet
run sessions | grep -q $'session-b.jsonl\t.*\trouter audit\t$' \
  || fail "title sidecar not ingested: $(run sessions)"

printf 'better title\n' > "$sessions_root/claude/session-b.jsonl.title"
run index --session-dir "$sessions_root" --quiet
run sessions | grep -q $'\tbetter title\t$' \
  || fail "sidecar-only change not ingested"
printf 'router audit\n' > "$sessions_root/claude/session-b.jsonl.title"
run index --session-dir "$sessions_root" --quiet

# --- Annotate: a stub generator fills the gaps. The claude session keeps
# its watcher title and only gains a description; the codex session gains
# both; the boilerplate-only session is skipped.
cat > "$tmp/annotator" <<'EOF'
#!/usr/bin/env bash
message="$(cat)"
printf 'stub title\n'
printf 'Describes: %s.\n' "$message"
EOF
chmod +x "$tmp/annotator"

annotate_output="$(run annotate --generator "$tmp/annotator" --quiet)"
[[ "$annotate_output" == "annotated 2 failed 0 skipped 1" ]] \
  || fail "annotate summary wrong: $annotate_output"

[[ "$(cat "$sessions_root/codex/rollout-a.jsonl.title")" == "stub title" ]] \
  || fail "codex title sidecar not written"
[[ "$(cat "$sessions_root/codex/rollout-a.jsonl.desc")" == "Describes: fix the router." ]] \
  || fail "codex desc sidecar not written"
[[ "$(cat "$sessions_root/claude/session-b.jsonl.title")" == "router audit" ]] \
  || fail "existing watcher title was overwritten"
[[ "$(cat "$sessions_root/claude/session-b.jsonl.desc")" == "Describes: audit the router page." ]] \
  || fail "claude desc sidecar not written"
[[ ! -e "$sessions_root/claude/session-d.jsonl.title" ]] \
  || fail "boilerplate session was annotated"

run sessions | grep -q $'\trouter audit\tDescribes: audit the router page.$' \
  || fail "annotate did not update the claude session row"

# --- A second annotate run has nothing left to do.
annotate_output="$(run annotate --generator "$tmp/annotator" --quiet)"
[[ "$annotate_output" == "annotated 0 failed 0 skipped 1" ]] \
  || fail "annotate is not idempotent: $annotate_output"

# --- Recent: newest first by file mtime, with per-harness resume commands.
recent="$(run recent)"
[[ "$(printf '%s\n' "$recent" | sed -n 2p)" == *session-b.jsonl* ]] \
  || fail "recent order wrong: $recent"
[[ "$(printf '%s\n' "$recent" | sed -n 3p)" == *rollout-a.jsonl* ]] \
  || fail "recent order wrong: $recent"
printf '%s\n' "$recent" | grep -q $'\tcodex resume codex-1$' \
  || fail "codex resume command missing: $recent"
printf '%s\n' "$recent" | grep -q $'\tclaude --resume claude-1$' \
  || fail "claude resume command missing: $recent"

# --- Recent filters by repository and honors the limit.
filtered="$(run recent --repo /srv/src/bench)"
printf '%s\n' "$filtered" | grep -q rollout-a \
  || fail "repo filter dropped the codex session: $filtered"
printf '%s\n' "$filtered" | grep -q session-b \
  && fail "repo filter kept a foreign session: $filtered"
[[ "$(run recent --limit 1 | tail -n +2 | wc -l)" == 1 ]] \
  || fail "recent limit not honored"

run recent --json | head -n 1 | grep -q '"resume": "claude --resume claude-1"' \
  || fail "recent json resume field wrong"

# --- Read commands open the index read-only: they work on a
# write-protected database and never create a missing one.
chmod a-w "$db"
run recent >/dev/null || fail "recent failed on a write-protected database"
run sessions >/dev/null || fail "sessions failed on a write-protected database"
run report usage >/dev/null || fail "report failed on a write-protected database"
run events --kind man_read >/dev/null \
  || fail "events failed on a write-protected database"
chmod u+w "$db"

if python3 "$tool" --db "$tmp/absent/index.sqlite" recent \
    >/dev/null 2>"$tmp/absent.err"; then
  fail "recent succeeded without an index"
fi
grep -q "no index at" "$tmp/absent.err" \
  || fail "missing-index error not reported: $(cat "$tmp/absent.err")"
[[ ! -e "$tmp/absent/index.sqlite" ]] \
  || fail "a read command created the database"

# --- A locked database fails within the bounded timeout with an
# actionable message instead of blocking and then raising a bare
# OperationalError.
cat > "$tmp/locker.py" <<'EOF'
import sqlite3
import sys
import time

connection = sqlite3.connect(sys.argv[1])
connection.execute("BEGIN EXCLUSIVE")
open(sys.argv[2], "w").close()
time.sleep(30)
EOF
python3 "$tmp/locker.py" "$db" "$tmp/lock-held" &
locker=$!
for _ in $(seq 100); do
  [[ -e "$tmp/lock-held" ]] && break
  sleep 0.1
done
[[ -e "$tmp/lock-held" ]] || fail "the locker never acquired the database"

lock_start=$SECONDS
locked_status=0
AGENT_TRANSCRIPTS_DB_TIMEOUT=1 python3 "$tool" --db "$db" recent \
  >/dev/null 2>"$tmp/locked.err" || locked_status=$?
lock_elapsed=$((SECONDS - lock_start))
kill "$locker" 2>/dev/null || true
wait "$locker" 2>/dev/null || true
[[ "$locked_status" -ne 0 ]] || fail "recent succeeded on a locked database"
grep -q "locked" "$tmp/locked.err" \
  || fail "lock error not reported: $(cat "$tmp/locked.err")"
grep -q "another process holds the database" "$tmp/locked.err" \
  || fail "lock error lacks guidance: $(cat "$tmp/locked.err")"
((lock_elapsed <= 10)) \
  || fail "lock failure was not bounded: ${lock_elapsed}s"

printf 'agent-transcripts spec OK\n'
