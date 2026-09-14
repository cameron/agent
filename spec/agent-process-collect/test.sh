#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
collector="$repo_root/agent-process-collect/agent-process-collect"
indexer="$repo_root/agent-process-collect/agent_process_index.py"
tmp="$(mktemp -d)"
archive_root="$(mktemp -d)"
cleanup_archive_root="${TMPDIR:-/tmp}/rm4agent-$UID/agent-process-collect-$RANDOM-$BASHPID"
trap 'RM4AGENT_ROOT="$cleanup_archive_root" rm4agent -r "$tmp" "$archive_root" >/dev/null' EXIT

data_root="$tmp/log"
fake_bin="$tmp/bin"
fixture="$tmp/audit.log"
rotated_fixture="$tmp/rotated-audit.log"
mkdir -p \
  "$data_root/pacct/archive" \
  "$data_root/audit/archive" \
  "$data_root/index/archive" \
  "$fake_bin"

cat > "$fixture" <<'EOF'
node=forge type=USER msg=audit(1700000000.123:42): pid=400 uid=1000 auid=1000 ses=7 msg='agent_process_launch schema=1 boot_id=11111111-2222-3333-4444-555555555555 root_pid=400 ruid=1000 rgid=100 original_auid=1000 audit_auid=4294967294 label=labeled host_hex=666f726765 cwd_hex=2f7573722f6c6f63616c2f7372632f62656e6368' exe="/run/wrappers/bin/agent-process-label" hostname=forge addr=? terminal=? res=success
node=forge type=SYSCALL msg=audit(1700000000.124:43): arch=c000003e syscall=59 success=yes exit=0 ppid=399 pid=400 auid=4294967294 exe="/usr/local/bin/agent" key="agent_exec"
node=forge type=PROCTITLE msg=audit(1700000000.124:43): proctitle=6167656e74002d2d6e6f2d75706461746500636c61756465002d2d6d6f64656c006f70757300
node=forge type=USER msg=audit(1700000100.000:44): pid=500 uid=1001 auid=1001 ses=8 msg='agent_process_launch schema=1 boot_id=11111111-2222-3333-4444-555555555555 root_pid=500 ruid=1001 rgid=100 original_auid=1001 audit_auid=4294967294 label=degraded host_hex=666f726765 cwd_hex=2f746d702f6465677261646564' exe="/run/wrappers/bin/agent-process-label" hostname=forge addr=? terminal=? res=failed
node=forge type=SYSCALL msg=audit(1700000101.000:45): arch=c000003e syscall=59 success=yes exit=0 ppid=499 pid=500 auid=1001 key="unrelated"
node=forge type=PROCTITLE msg=audit(1700000101.000:45): proctitle=6167656e7400636f64657800
node=forge type=SYSCALL msg=audit(1700000102.000:46): arch=c000003e syscall=59 success=yes exit=0 ppid=500 pid=501 auid=4294967294 exe=2F6E69782F73746F72652F6578616D706C652D6769742F62696E2F676974 key="agent_exec"
node=forge type=PROCTITLE msg=audit(1700000102.000:46): proctitle=6769740073746174757300
EOF

cat > "$rotated_fixture" <<'EOF'
node=forge type=SYSCALL msg=audit(1700000103.000:47): arch=c000003e syscall=59 success=yes exit=0 ppid=500 pid=502 auid=4294967294 exe="/nix/store/example-catchup/bin/catchup" key="agent_exec"
node=forge type=PROCTITLE msg=audit(1700000103.000:47): proctitle=6361746368757000
EOF

cat > "$fake_bin/lastcomm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --pid && "$2" == --file ]]
input=$3
shift 3
printf '%s\n' "$*" >> "$FAKE_LASTCOMM_LOG"
cat "$input"
EOF

cat > "$fake_bin/sa" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -i && "$2" == --other-acct-file && "$3" == /dev/stdin ]]
input=$3
shift 3
printf 'option=%s\n' "$@"
cat "$input"
EOF

cat > "$fake_bin/ausearch" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --input && "$3" == --key && "$4" == agent_exec ]]
input=$2
shift 4
[[ "$#" == 1 && "$1" == --raw ]]
cat "$input"
EOF

cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == is-active && "$2" == --quiet ]]
exit 0
EOF

cat > "$fake_bin/accton" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_ACCTON_LOG"
EOF

cat > "$fake_bin/getcap" <<'EOF'
#!/usr/bin/env bash
printf '%s cap_audit_write,cap_audit_control=ep\n' "$1"
EOF

cat > "$fake_bin/agent-process-label" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$fake_bin/auditctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  -s)
    printf '%s\n' 'enabled 1' 'lost 0'
    ;;
  -l)
    printf '%s\n' '-a always,exit -S execve -F auid=4294967294 -F key=agent_exec'
    ;;
  '--signal rotate')
    mv "$FAKE_DATA_ROOT/audit/current" "$FAKE_DATA_ROOT/audit/current.1"
    : > "$FAKE_DATA_ROOT/audit/current"
    chmod 0600 "$FAKE_DATA_ROOT/audit/current"
    ;;
  *)
    exit 2
    ;;
esac
EOF

cat > "$fake_bin/rotating-indexer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == build && ! -e "$FAKE_DATA_ROOT/index/rotation-injected" ]]; then
  : > "$FAKE_DATA_ROOT/index/rotation-injected"
  cp "$ROTATED_FIXTURE" "$FAKE_DATA_ROOT/audit/current.99"
  chmod 0600 "$FAKE_DATA_ROOT/audit/current.99"
fi
exec "$REAL_INDEXER" "$@"
EOF
chmod +x "$fake_bin"/*

printf '%s\n' archived-pacct > "$data_root/pacct/archive/first.pacct"
printf '%s\n' current-pacct > "$data_root/pacct/current"
cp "$fixture" "$data_root/audit/current"
chmod 0600 "$data_root/pacct/current" "$data_root/audit/current"

run_collector() {
  AGENT_PROCESS_COLLECT_ALLOW_NON_ROOT=1 \
    AGENT_PROCESS_COLLECT_ROOT="$data_root" \
    AGENT_PROCESS_COLLECT_NOW="2023-11-14T22:15:00Z" \
    AGENT_PROCESS_COLLECT_INDEXER="${AGENT_PROCESS_COLLECT_INDEXER_OVERRIDE:-$indexer}" \
    AGENT_PROCESS_COLLECT_REPORT_TIMEOUT_SECONDS="${AGENT_PROCESS_COLLECT_REPORT_TIMEOUT_SECONDS_OVERRIDE:-60}" \
    AGENT_PROCESS_COLLECT_ACCTON="$fake_bin/accton" \
    AGENT_PROCESS_COLLECT_LASTCOMM="$fake_bin/lastcomm" \
    AGENT_PROCESS_COLLECT_SA="$fake_bin/sa" \
    AGENT_PROCESS_COLLECT_AUDITCTL="$fake_bin/auditctl" \
    AGENT_PROCESS_COLLECT_AUSEARCH="$fake_bin/ausearch" \
    AGENT_PROCESS_COLLECT_GETCAP="$fake_bin/getcap" \
    AGENT_PROCESS_COLLECT_SYSTEMCTL="$fake_bin/systemctl" \
    AGENT_PROCESS_COLLECT_RM4AGENT=rm4agent \
    RM4AGENT_ROOT="$archive_root" \
    FAKE_ACCTON_LOG="$tmp/accton.log" \
    FAKE_LASTCOMM_LOG="$tmp/lastcomm.log" \
    FAKE_DATA_ROOT="$data_root" \
    REAL_INDEXER="$indexer" \
    ROTATED_FIXTURE="$rotated_fixture" \
    AGENT_PROCESS_LABELER="$fake_bin/agent-process-label" \
    "$collector" "$@"
}

AGENT_PROCESS_COLLECT_INDEXER_OVERRIDE="$fake_bin/rotating-indexer"
run_collector index-bootstrap
"$indexer" validate --database "$data_root/index/process.sqlite3"
printf '\n' | "$indexer" ingest "$data_root/index/process.sqlite3"

lastcomm_output="$(run_collector lastcomm --days 2 -- --user cam)"
expected='current-pacct
archived-pacct'
[[ "$lastcomm_output" == "$expected" ]]
[[ "$(wc -l < "$tmp/lastcomm.log")" == 2 ]]
[[ "$(<"$tmp/lastcomm.log")" == *'--user cam'* ]]

sa_output="$(run_collector sa --days=2 -- -n)"
expected='option=-n
archived-pacct
current-pacct'
[[ "$sa_output" == "$expected" ]]
if run_collector sa -- -s > "$tmp/sa-write.stdout" 2> "$tmp/sa-write.stderr"; then
  printf '%s\n' 'sa merge option unexpectedly succeeded' >&2
  exit 1
fi
[[ ! -s "$tmp/sa-write.stdout" ]]
[[ "$(<"$tmp/sa-write.stderr")" == *'summary-file options are managed'* ]]

run_collector execs --days 2 -- --raw > "$tmp/execs.out"
cp "$fixture" "$tmp/expected-execs.out"
cat "$rotated_fixture" >> "$tmp/expected-execs.out"
cmp "$tmp/expected-execs.out" "$tmp/execs.out"

run_collector sessions --json > "$tmp/collector-sessions.jsonl"
jq -e -s '
  length == 2
  and .[0].schema_version == 1
  and .[0].host == "forge"
  and .[0].root_pid == 400
  and .[0].uid == 1000
  and .[0].label_status == "labeled"
  and .[0].cwd == "/usr/local/src/bench"
  and .[0].harness == "claude"
  and .[0].launcher_argv == ["agent", "--no-update", "claude", "--model", "opus"]
  and .[1].root_pid == 500
  and .[1].label_status == "degraded"
  and .[1].harness == null
  and .[1].launcher_argv == null
' \
  "$tmp/collector-sessions.jsonl" >/dev/null

run_collector sessions --json --since 2023-11-14T22:14:00Z \
  > "$tmp/recent-sessions.jsonl"
jq -e -s 'length == 1 and .[0].root_pid == 500' \
  "$tmp/recent-sessions.jsonl" >/dev/null

chmod 000 "$data_root/audit/current"
run_collector sessions --json > "$tmp/index-only-sessions.jsonl"
run_collector report --days 2 > "$tmp/index-only-report.md"
chmod 0600 "$data_root/audit/current"
cmp "$tmp/collector-sessions.jsonl" "$tmp/index-only-sessions.jsonl"
[[ "$(<"$tmp/index-only-report.md")" == *'- Agent launches: 2'* ]]

status_output="$(run_collector status)"
[[ "$status_output" == *'process-accounting: active'* ]]
[[ "$status_output" == *'auditd: active'* ]]
[[ "$status_output" == *'audit-lost-events: 0'* ]]
[[ "$status_output" == *'agent-exec-rules: loaded'* ]]
[[ "$status_output" == *'agent-labeler: ready'* ]]
[[ "$status_output" == *'index: ready'* ]]
[[ "$status_output" == *'indexer: active'* ]]
[[ "$status_output" == *'degraded-launches-retained: 1'* ]]

report_output="$(run_collector report --days 2)"
[[ "$report_output" == *'- Collection health: healthy'* ]]
[[ "$report_output" == *'- Agent launches: 2'* ]]
[[ "$report_output" == *'- Labeled launches: 1'* ]]
[[ "$report_output" == *'- Degraded launches: 1'* ]]
[[ "$report_output" == *'- Agent-tree exec attempts: 3'* ]]
[[ "$report_output" == *'- Exec summary granularity: UTC day'* ]]
[[ "$report_output" == *'- Harnesses: claude=1, unresolved=1'* ]]
[[ "$report_output" == *'  - `agent`: 1'* ]]
[[ "$report_output" == *'  - `git`: 1'* ]]
[[ "$report_output" == *'  - `catchup`: 1'* ]]
[[ "$report_output" != *'--model'* ]]
[[ "$report_output" != *'opus'* ]]

printf '%s\n' stale-pacct > "$data_root/pacct/archive/stale.pacct"
printf '%s\n' stale-audit > "$data_root/audit/archive/stale.log"
touch -d '31 days ago' \
  "$data_root/pacct/archive/stale.pacct" \
  "$data_root/audit/archive/stale.log"

run_collector rotate
[[ -f "$data_root/pacct/current" && ! -s "$data_root/pacct/current" ]]
[[ -f "$data_root/audit/current" && ! -s "$data_root/audit/current" ]]
[[ ! -e "$data_root/pacct/archive/stale.pacct" ]]
[[ ! -e "$data_root/audit/archive/stale.log" ]]
[[ "$(<"$tmp/accton.log")" == "$data_root/pacct/current" ]]

found_pacct=false
for record in "$data_root/pacct/archive"/*.pacct; do
  if [[ "$(<"$record")" == current-pacct ]]; then
    found_pacct=true
  fi
done
"$found_pacct"

found_audit=false
for record in "$data_root/audit/archive"/*.log; do
  if cmp -s "$fixture" "$record"; then
    found_audit=true
  fi
done
"$found_audit"

[[ "$(stat -c '%a' "$data_root/pacct/current")" == 600 ]]
[[ "$(stat -c '%a' "$data_root/audit/current")" == 600 ]]

large_fixture="$tmp/large-audit.log"
large_database="$tmp/large-index.sqlite3"
: > "$large_fixture"
for serial in $(seq 1 20000); do
  printf 'node=forge type=SYSCALL msg=audit(1700000200.%03d:%d): arch=c000003e syscall=59 success=yes exit=0 ppid=1 pid=%d auid=4294967294 exe="/nix/store/example-coreutils/bin/coreutils" key="agent_exec"\n' \
    "$((serial % 1000))" "$((serial + 100))" "$serial" \
    >> "$large_fixture"
done
"$indexer" build --database "$large_database" \
  --now 2023-11-14T22:15:00Z "$large_fixture"
large_report=$("$indexer" report --database "$large_database" \
  --days 2 --now 2023-11-14T22:15:00Z)
[[ "$large_report" == *'- Agent-tree exec attempts: 20000'* ]]
[[ "$large_report" == *'  - `coreutils`: 20000'* ]]
[[ "$(stat -c '%s' "$large_database")" -lt "$(stat -c '%s' "$large_fixture")" ]]

slow_indexer="$fake_bin/slow-indexer"
cat > "$slow_indexer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  status)
    printf '%s\n' 'index: ready' 'indexer: active'
    ;;
  report)
    sleep 3
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod 0755 "$slow_indexer"
set +e
timeout_report=$(
  AGENT_PROCESS_COLLECT_INDEXER_OVERRIDE="$slow_indexer" \
    AGENT_PROCESS_COLLECT_REPORT_TIMEOUT_SECONDS_OVERRIDE=1 \
    run_collector report --days 2
)
timeout_status=$?
set -e
[[ $timeout_status -eq 1 ]]
[[ "$timeout_report" == *'- Collection health: needs-attention'* ]]
[[ "$timeout_report" == *'- Report error: compact index query timed out after 1 seconds'* ]]

printf '%s\n' 'PASS: agent process collection and compact reporting'
