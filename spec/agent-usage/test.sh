#!/usr/bin/env bash

set -euo pipefail
trap 'printf "FAIL: line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
usage="$repo_root/bin/agent-usage"
agent="$repo_root/bin/agent"
tmp="$(mktemp -d)"
archive_root="${TMPDIR:-/tmp}/rm4agent-$UID/agent-usage-spec-$RANDOM-$BASHPID"
trap 'RM4AGENT_ROOT="$archive_root" rm4agent -r "$tmp" >/dev/null' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

home="$tmp/home"
claude_config="$home/.claude"
codex_home="$home/.codex"
cache_home="$home/.cache"
fake_bin="$tmp/bin"
mkdir -p "$claude_config" "$codex_home/sessions/2026/09/01" "$fake_bin"
export AGENT_USAGE_NOW=1788220800 # 2026-09-01T00:00:00Z

# Claude owns the config cache and its credentials. The fixture returns the
# same zero-model-turn JSON result as the native /usage command.
response="$tmp/claude-response.json"
cat >"$response" <<'EOF'
{"limits":[
  {"kind":"session","percent":29.4,"scope":null,"is_active":false,"resets_at":"2026-09-01T05:00:00Z"},
  {"kind":"weekly_all","percent":30.4,"scope":null,"is_active":false,"resets_at":"2026-09-08T00:00:00.000000+00:00"},
  {"kind":"weekly_scoped","percent":69.6,"scope":{"model":{"display_name":"Fable"}},"is_active":false,"resets_at":"2026-09-04T06:30:00+00:00"}
]}
EOF
cp "$response" "$tmp/claude-response-valid.json"
cat >"$fake_bin/claude" <<'EOF'
#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
args=sys.argv[1:]
assert args[args.index('-p')+1] == '/usage'
assert args[args.index('--max-turns')+1] == '0'
assert args[args.index('--tools')+1] == ''
assert args[args.index('--setting-sources')+1] == ''
assert args[args.index('--mcp-config')+1] == '{"mcpServers":{}}'
assert json.loads(args[args.index('--settings')+1])['disableAllHooks'] is True
with open(os.environ['CLAUDE_CALLS'], 'a') as f: f.write(json.dumps(args)+'\n')
if os.environ.get('CLAUDE_STATUS', '0') != '0':
    print('{"is_error":true,"num_turns":0}')
    sys.exit(1)
utilization=json.loads(Path(os.environ['CLAUDE_RESPONSE']).read_text())
config=Path(os.environ['CLAUDE_CONFIG_DIR'])/'.claude.json'
config.write_text(json.dumps({
    'oauthAccount': {'accountUuid':'fixture'},
    'cachedUsageUtilization': {'accountUuid':'fixture', 'fetchedAtMs':time.time()*1000,
                              'utilization':utilization}}))
print('{"is_error":false,"num_turns":0,"total_cost_usd":0}')
EOF
chmod +x "$fake_bin/claude"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected direct HTTP request\n' >>"$CLAUDE_CALLS"
exit 99
EOF
chmod +x "$fake_bin/curl"

session_file="$codex_home/sessions/2026/09/01/rollout.jsonl"
cat >"$session_file" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":39.6,"resets_at":1788229800},"secondary":{"used_percent":95,"resets_at":1}}}}
{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex_bengalfox","primary":{"used_percent":95},"secondary":null}}}
{"type":"event_msg","payload":{"type":"token_count"
EOF
calls="$tmp/claude-calls"
run_usage() {
  env HOME="$home" CLAUDE_CONFIG_DIR="$claude_config" CODEX_HOME="$codex_home" \
    XDG_CACHE_HOME="$cache_home" CLAUDE_CALLS="$calls" CLAUDE_RESPONSE="$response" \
    CLAUDE_STATUS="${CLAUDE_STATUS:-0}" PATH="$fake_bin:$PATH" "$usage" "$@"
}
cache_file="$cache_home/agent/usage-claude.json"
state_file="$cache_home/agent/usage-claude-state.json"
expected='fable: 70% (3d6h) claude: 30% (7d) codex: 40% (2h30m)'

# Cold concurrent readers must make exactly one native request.
for index in {1..8}; do
  run_usage >"$tmp/concurrent-$index.stdout" 2>"$tmp/concurrent-$index.stderr" &
done
wait
for index in {1..8}; do
  [[ "$(cat "$tmp/concurrent-$index.stdout")" == "$expected" ]] || fail 'concurrent output changed'
  [[ ! -s "$tmp/concurrent-$index.stderr" ]] || fail 'concurrent read emitted an error'
done
[[ "$(wc -l <"$calls")" -eq 1 ]] || fail 'concurrent readers made duplicate requests'
[[ "$(stat -c %a "$cache_file")" == 600 ]] || fail 'cache is not private'
[[ "$(stat -c %a "$state_file")" == 600 ]] || fail 'state is not private'
[[ "$(CLAUDE_STATUS=1 run_usage)" == "$expected" ]] || fail 'fresh cache changed'
[[ "$(wc -l <"$calls")" -eq 1 ]] || fail 'fresh cache started Claude'

age_cache() {
  touch -d '20 minutes ago' "$cache_file"
  python3 - "$claude_config/.claude.json" <<'PYTHON'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); j=json.loads(p.read_text())
j['cachedUsageUtilization']['fetchedAtMs']=1
p.write_text(json.dumps(j))
PYTHON
}
allow_retry() {
  python3 - "$state_file" <<'PYTHON'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); j=json.loads(p.read_text()); j['retry_after']=0
p.write_text(json.dumps(j))
PYTHON
}
age_cache
[[ "$(CLAUDE_STATUS=1 run_usage)" == "$expected" ]] || fail 'failed refresh lost valid data'
[[ "$(wc -l <"$calls")" -eq 2 ]] || fail 'stale cache did not refresh once'
cp "$state_file" "$tmp/failure-state"
[[ "$(CLAUDE_STATUS=1 AGENT_USAGE_CACHE_SECONDS=0 run_usage)" == "$expected" ]] || fail 'backoff lost data'
[[ "$(wc -l <"$calls")" -eq 2 ]] || fail 'backoff made another request'
cmp "$state_file" "$tmp/failure-state" || fail 'reading extended the backoff'
run_usage --diagnose >"$tmp/diagnostic"
jq -e '.state.last_error == "claude-usage-failed" and .state.failures == 1' "$tmp/diagnostic" >/dev/null
[[ "$(wc -l <"$calls")" -eq 2 ]] || fail 'diagnostics made a request'

# After reset, failed providers stay visible without presenting old numbers.
out="$(CLAUDE_STATUS=1 AGENT_USAGE_NOW=1789257600 run_usage)"
[[ "$out" == 'fable: unavailable claude: unavailable' ]] || fail "expired values vanished: $out"
allow_retry
[[ "$(run_usage)" == "$expected" ]] || fail 'recovery did not restore both limits'
[[ "$(wc -l <"$calls")" -eq 3 ]] || fail 'recovery did not make one request'

# An invalid native cache preserves old data; a valid empty response clears it.
age_cache
printf '{"limits":{}}\n' >"$response"
[[ "$(run_usage)" == "$expected" ]] || fail 'malformed cache lost prior data'
allow_retry
printf '{"limits":[]}\n' >"$response"
[[ "$(run_usage)" == 'codex: 40% (2h30m)' ]] || fail 'empty limits did not clear old data'
jq -e '. == []' "$cache_file" >/dev/null

# A changed native snapshot becomes visible without a new subprocess.
python3 - "$claude_config/.claude.json" "$tmp/claude-response-valid.json" <<'PYTHON'
import json,sys,time
from pathlib import Path
p=Path(sys.argv[1]); j=json.loads(p.read_text())
j['cachedUsageUtilization']['fetchedAtMs']=time.time()*1000
j['cachedUsageUtilization']['utilization']=json.loads(Path(sys.argv[2]).read_text())
p.write_text(json.dumps(j))
PYTHON
before_calls=$(wc -l <"$calls")
[[ "$(run_usage)" == "$expected" ]] || fail 'new native snapshot was ignored'
[[ "$(wc -l <"$calls")" -eq "$before_calls" ]] || fail 'new native snapshot started Claude'

# The public subcommand finds the source-tree sibling and returns before the
# process labeler can re-exec the launcher.
cat >"$tmp/process-labeler" <<EOF
#!/usr/bin/env bash
touch '$tmp/process-labeler-ran'
exit 99
EOF
chmod +x "$tmp/process-labeler"
output="$(
  env \
    HOME="$home" CLAUDE_CONFIG_DIR="$tmp/missing-claude" \
    CODEX_HOME="$codex_home" XDG_CACHE_HOME="$tmp/agent-cache" \
    AGENT_PROCESS_LABELER="$tmp/process-labeler" PATH="$fake_bin:$PATH" \
    "$agent" usage
)"
[[ "$output" == 'codex: 40% (2h30m)' ]] || fail 'agent usage did not find its helper'
[[ ! -e "$tmp/process-labeler-ran" ]] || fail 'agent usage ran the process labeler'

set +e
run_usage extra >"$tmp/argument.stdout" 2>"$tmp/argument.stderr"
status=$?
set -e
[[ "$status" -eq 2 && ! -s "$tmp/argument.stdout" ]] ||
  fail 'unexpected arguments did not return status 2'
grep -Fqx 'usage: agent usage [--diagnose]' "$tmp/argument.stderr" ||
  fail 'unexpected arguments did not print usage'

# Total unavailability is explicit, while missing Claude data alone is not an
# error when Codex data is present.
set +e
env \
  HOME="$tmp/empty-home" CLAUDE_CONFIG_DIR="$tmp/empty-claude" \
  CODEX_HOME="$tmp/empty-codex" XDG_CACHE_HOME="$tmp/empty-cache" \
  PATH="$fake_bin:$PATH" \
  "$usage" >"$tmp/empty.stdout" 2>"$tmp/empty.stderr"
status=$?
set -e
[[ "$status" -eq 1 && ! -s "$tmp/empty.stdout" ]] ||
  fail 'total unavailability did not fail cleanly'
grep -Fqx 'agent usage: no session-limit usage is available.' "$tmp/empty.stderr" ||
  fail 'total unavailability diagnostic changed'

# The newest Codex snapshot governs availability. Expired windows are omitted
# and do not allow an older active snapshot in the same file to reappear.
expired_home="$tmp/expired-codex"
mkdir -p "$expired_home/sessions"
cat >"$expired_home/sessions/expired.jsonl" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":88,"resets_at":4102444800},"secondary":null}}}
{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":12,"resets_at":1},"secondary":{"used_percent":99,"resets_at":1}}}}
EOF
set +e
env \
  HOME="$tmp/empty-home" CLAUDE_CONFIG_DIR="$tmp/empty-claude" \
  CODEX_HOME="$expired_home" XDG_CACHE_HOME="$tmp/expired-cache" \
  PATH="$fake_bin:$PATH" \
  "$usage" >"$tmp/expired.stdout" 2>"$tmp/expired.stderr"
status=$?
set -e
[[ "$status" -eq 1 && ! -s "$tmp/expired.stdout" ]] ||
  fail 'expired Codex windows were reported'

# Files outside the recent discovery horizon cannot revive old snapshots.
historical_home="$tmp/historical-codex"
mkdir -p "$historical_home/sessions"
cat >"$historical_home/sessions/old.jsonl" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":87,"resets_at":4102444800},"secondary":null}}}
EOF
touch -d '9 days ago' "$historical_home/sessions/old.jsonl"
set +e
env \
  HOME="$tmp/empty-home" CLAUDE_CONFIG_DIR="$tmp/empty-claude" \
  CODEX_HOME="$historical_home" XDG_CACHE_HOME="$tmp/historical-cache" \
  PATH="$fake_bin:$PATH" \
  "$usage" >"$tmp/historical.stdout" 2>"$tmp/historical.stderr"
status=$?
set -e
[[ "$status" -eq 1 && ! -s "$tmp/historical.stdout" ]] ||
  fail 'Codex discovery included an old-only file'

# Only the 32 newest files are considered.
bounded_home="$tmp/bounded-codex"
mkdir -p "$bounded_home/sessions"
cat >"$bounded_home/sessions/old-valid.jsonl" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":88,"resets_at":4102444800},"secondary":null}}}
EOF
touch -d '40 seconds ago' "$bounded_home/sessions/old-valid.jsonl"
for index in $(seq 1 32); do
  printf '{}\n' >"$bounded_home/sessions/new-$index.jsonl"
  touch -d "$index seconds ago" "$bounded_home/sessions/new-$index.jsonl"
done
set +e
env \
  HOME="$tmp/empty-home" CLAUDE_CONFIG_DIR="$tmp/empty-claude" \
  CODEX_HOME="$bounded_home" XDG_CACHE_HOME="$tmp/bounded-cache" \
  PATH="$fake_bin:$PATH" \
  "$usage" >"$tmp/bounded.stdout" 2>"$tmp/bounded.stderr"
status=$?
set -e
[[ "$status" -eq 1 && ! -s "$tmp/bounded.stdout" ]] ||
  fail 'Codex file-count bound was not enforced'

# The two-MiB tail bound prevents an old snapshot before one giant line from
# forcing the parser to consume an unbounded transcript.
bytes_home="$tmp/bytes-codex"
mkdir -p "$bytes_home/sessions"
cat >"$bytes_home/sessions/large.jsonl" <<'EOF'
{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":77,"resets_at":4102444800},"secondary":null}}}
EOF
dd if=/dev/zero bs=1048576 count=3 2>/dev/null | tr '\0' x \
  >>"$bytes_home/sessions/large.jsonl"
printf '\n' >>"$bytes_home/sessions/large.jsonl"
set +e
env \
  HOME="$tmp/empty-home" CLAUDE_CONFIG_DIR="$tmp/empty-claude" \
  CODEX_HOME="$bytes_home" XDG_CACHE_HOME="$tmp/bytes-cache" \
  PATH="$fake_bin:$PATH" \
  "$usage" >"$tmp/bytes.stdout" 2>"$tmp/bytes.stderr"
status=$?
set -e
[[ "$status" -eq 1 && ! -s "$tmp/bytes.stdout" ]] ||
  fail 'Codex byte bound was not enforced'

echo 'PASS: agent usage'
