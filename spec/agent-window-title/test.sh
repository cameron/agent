#!/usr/bin/env bash

set -euo pipefail

trap 'printf "FAIL: line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
agent="$repo_root/bin/agent"
tmp="$(mktemp -d)"
trap 'rm4agent -r "$tmp" >/dev/null 2>&1 || true' EXIT

mkdir -p "$tmp/bin" "$tmp/work"

real_jq="$(command -v jq)"
real_wc="$(command -v wc)"

cat > "$tmp/bin/jq" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in
    *.jsonl)
      printf 'jq read whole transcript: %s\n' "$argument" >> "$TRANSCRIPT_READ_VIOLATIONS"
      break
      ;;
  esac
done
exec "$REAL_JQ" "$@"
EOF

cat > "$tmp/bin/wc" <<'EOF'
#!/usr/bin/env bash
input="$(readlink "/proc/$$/fd/0" 2>/dev/null || true)"
case "$input" in
  *.jsonl)
    printf 'wc streamed whole transcript: %s\n' "$input" >> "$TRANSCRIPT_READ_VIOLATIONS"
    ;;
esac
exec "$REAL_WC" "$@"
EOF

cat > "$tmp/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  display-message)
    format="${*: -1}"
    case "$format" in
      '#S') printf '%s\n' "${TMUX_TEST_SESSION:-agent}" ;;
      '#{pane_id}') printf '%%9\n' ;;
      '#{window_id}') printf '@4\n' ;;
      '#{session_id}'|'#{session_id}:#{session_created}') printf '\$7\n' ;;
      *) printf '%%9\n' ;;
    esac
    ;;
  show-options)
    printf '%s\n' "${TMUX_TEST_MODE:-}"
    ;;
  show-environment)
    [[ "$*" != *' -v '* ]] || exit 2
    case "${*: -1}" in
      TMUX_PROJECT)
        [[ -n "${TMUX_TEST_PROJECT:-}" ]] || exit 1
        printf 'TMUX_PROJECT=%s\n' "$TMUX_TEST_PROJECT"
        ;;
      TMUX_WORKSPACE)
        [[ -n "${TMUX_WORKSPACE:-}" ]] || exit 1
        printf 'TMUX_WORKSPACE=%s\n' "$TMUX_WORKSPACE"
        ;;
      *) exit 1 ;;
    esac
    ;;
  rename-window)
    printf '%s\n' "$*" >> "$TMUX_TEST_LOG"
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat > "$tmp/bin/tmux.retitle" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_RETITLE_LOG"
EOF

cat > "$tmp/bin/content2title" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CONTENT2TITLE_ARGS_LOG"
printf '%s\n' "${*: -1}" >> "$TITLE_INPUT_LOG"
printf '%s\n' "${TITLE_OUTPUT:-parser tests}"
exit "${CONTENT2TITLE_STATUS:-0}"
EOF

cat > "$tmp/bin/matrix-agent-tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "${MATRIX_BRIDGE_FAIL:-0}" == 1 ]]; then
  printf 'bridge unavailable\n' >&2
  exit 1
fi
case "${1:-}" in
  start) printf '%s\n' "$@" > "${MATRIX_BRIDGE_LOG}.register" ;;
  attach) printf '%s\n' "$@" > "$MATRIX_BRIDGE_LOG" ;;
esac
EOF

cat > "$tmp/bin/tmux.workspace-resume" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKSPACE_RESUME_LOG"
EOF

cat > "$tmp/bin/pi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$tmp/bin/"*

wait_for_file() {
  local path="$1" attempt
  for attempt in {1..500}; do
    [[ -e "$path" ]] && return 0
    sleep 0.02
  done
  return 1
}

wait_for_exit() {
  local pid="$1" attempt
  for attempt in {1..500}; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.02
  done
  return 1
}

run_case() {
  local harness="$1"
  local output="${2:-parser tests}"
  local project="${3:-}"
  local mode="${4:-}"
  local generator_status="${5:-0}"
  local competing_codex="${6:-0}"
  local stale_transcript="${7:-0}"
  local existing_sidecar="${8:-0}"
  local request="${9:-please fix the parser tests and matrix bridge}"
  local title_provider="${10:-}"
  local title_model="${11:-}"
  local partial_record="${12:-0}"
  local case_dir="$tmp/$harness-$RANDOM"
  local session_subdir session_file stale_file ready runtime_dir
  local watcher_pid agent_pid other_pid= expected_session_id=

  [[ "$harness" == claude ]] && session_subdir=projects || session_subdir=sessions
  mkdir -p "$case_dir/$session_subdir" "$case_dir/runtime"
  session_file="$case_dir/$session_subdir/session.jsonl"
  ready="$case_dir/ready"
  runtime_dir="$case_dir/runtime"

  write_session_header() {
    local target="$1"
    local session_id="$2"
    case "$harness" in
      codex)
        printf '{"type":"session_meta","payload":{"session_id":"%s","id":"%s","cwd":"%s"}}\n' \
          "$session_id" "$session_id" "$tmp/work" >> "$target"
        ;;
      claude)
        printf '{"type":"system","sessionId":"%s","cwd":"%s"}\n' \
          "$session_id" "$tmp/work" >> "$target"
        ;;
      pi)
        printf '{"type":"session","id":"%s","cwd":"%s"}\n' \
          "$session_id" "$tmp/work" >> "$target"
        ;;
    esac
  }

  if [[ "$existing_sidecar" == 1 ]]; then
    expected_session_id=test-session
    write_session_header "$session_file" "$expected_session_id"
    printf '%s\n' 'saved parser title' > "${session_file}.title"
  fi
  if [[ "$stale_transcript" == 1 ]]; then
    stale_file="$case_dir/$session_subdir/stale.jsonl"
    write_session_header "$stale_file" stale-session
    printf '%s\n' 'unrelated saved title' > "${stale_file}.title"
  fi

  if [[ "$competing_codex" == 1 && "$harness" == codex ]]; then
    mkdir -p "$case_dir/thread-writer-locks"
    bash -c 'exec 9>"$1"; sleep 300' _ \
      "$case_dir/thread-writer-locks/test-session.lock" &
  else
    sleep 300 &
  fi
  agent_pid=$!
  PATH="$tmp/bin:$PATH" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    CODEX_HOME="$case_dir" \
    CLAUDE_CONFIG_DIR="$case_dir" \
    PI_CODING_AGENT_DIR="$case_dir" \
    CONTENT2TITLE_BIN="$tmp/bin/content2title" \
    AGENT_TITLE_POLL_SECONDS=0.02 \
    AGENT_TITLE_PROVIDER="$title_provider" \
    AGENT_TITLE_MODEL="$title_model" \
    TITLE_OUTPUT="$output" \
    CONTENT2TITLE_STATUS="$generator_status" \
    CONTENT2TITLE_ARGS_LOG="$case_dir/content2title-args.log" \
    TITLE_INPUT_LOG="$case_dir/model-input.log" \
    TMUX_TEST_SESSION=agent \
    TMUX_TEST_PROJECT="$project" \
    TMUX_TEST_MODE="$mode" \
    TMUX_TEST_LOG="$case_dir/tmux.log" \
    TMUX_RETITLE_LOG="$case_dir/retitle.log" \
    TMUX_WORKSPACE="$tmp/work" \
    WORKSPACE_RESUME_LOG="$case_dir/resume.log" \
    MATRIX_BRIDGE_LOG="$case_dir/matrix.log" \
    REAL_JQ="$real_jq" \
    REAL_WC="$real_wc" \
    TRANSCRIPT_READ_VIOLATIONS="$case_dir/full-transcript-read.log" \
    "$agent" __title-watch "$ready" "$harness" %9 "$tmp/work" "$agent_pid" world-standby \
      "$expected_session_id" &
  watcher_pid=$!
  wait_for_file "$ready"

  if [[ "$competing_codex" == 1 ]]; then
    sleep 300 &
    other_pid=$!
    printf 'codex\t%s\t%s\t9999-01-01T00:00:00.000000Z\t%%8\tagent\n' \
      "$tmp/work" "$other_pid" \
      > "$runtime_dir/agent-window-titles-$UID/registrations/newer-watcher"
  fi

  if [[ "$stale_transcript" == 1 ]]; then
    case "$harness" in
      codex)
        printf '{"type":"event_msg","payload":{"type":"user_message","message":"resume unrelated work"}}\n' \
          >> "$stale_file"
        ;;
      claude)
        printf '{"type":"user","sessionId":"stale-session","cwd":"%s","message":{"role":"user","content":"resume unrelated work"}}\n' \
          "$tmp/work" >> "$stale_file"
        ;;
      pi)
        printf '{"type":"message","message":{"role":"user","content":"resume unrelated work"}}\n' \
          >> "$stale_file"
        ;;
    esac
    sleep 0.1
    [[ ! -e "$case_dir/tmux.log" ]]
    [[ ! -e "$case_dir/model-input.log" ]]
  fi

  if [[ "$existing_sidecar" != 1 ]]; then
    write_session_header "$session_file" test-session
  fi

  sleep 0.1
  [[ ! -e "$case_dir/model-input.log" ]]

  if [[ "$existing_sidecar" != 1 ]]; then
    local user_record split previous_size attempt
    user_record="$(
    case "$harness" in
      codex)
        printf '{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"%s"}]}}}\n' "$request"
        ;;
      claude)
        printf '{"type":"user","sessionId":"test-session","cwd":"WORK","isSidechain":false,"message":{"role":"user","content":"%s"}}\n' "$request"
        ;;
      pi)
        printf '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"%s"}]}}\n' \
          "$request"
        ;;
    esac
    )"
    if [[ "$partial_record" == 1 ]]; then
      split=$((${#user_record} / 2))
      previous_size="$(stat -c %s "$case_dir/resume.log")"
      printf '%s' "${user_record:0:split}" >> "$session_file"
      # The workspace recorder acknowledges that the watcher saw the append.
      for attempt in {1..500}; do
        [[ "$(stat -c %s "$case_dir/resume.log")" == "$previous_size" ]] || break
        sleep 0.02
      done
      [[ "$(stat -c %s "$case_dir/resume.log")" != "$previous_size" ]]
      [[ ! -e "$case_dir/model-input.log" ]]
      printf '%s\n' "${user_record:split}" >> "$session_file"
    else
      printf '%s\n' "$user_record" >> "$session_file"
    fi
  fi

  wait_for_exit "$watcher_pid"
  wait "$watcher_pid"
  if [[ -e "$case_dir/full-transcript-read.log" ]]; then
    cat "$case_dir/full-transcript-read.log" >&2
    return 1
  fi
  kill "$agent_pid" 2>/dev/null || true
  wait "$agent_pid" 2>/dev/null || true
  if [[ -n "$other_pid" ]]; then
    kill "$other_pid" 2>/dev/null || true
    wait "$other_pid" 2>/dev/null || true
  fi
  printf '%s\n' "$case_dir"
}

for harness in codex claude pi; do
  case_dir="$(run_case "$harness")"
  [[ "$(<"$case_dir/model-input.log")" == 'please fix the parser tests and matrix bridge' ]]
  [[ "$(<"$case_dir/content2title-args.log")" == '--provider codex --model gpt-5.6-luna --kind query --existing-title agent -- please fix the parser tests and matrix bridge' ]]
  [[ "$(<"$case_dir/tmux.log")" == 'rename-window -t %9 -- parser tests' ]]
  [[ "$(<"$case_dir/retitle.log")" == '--auto --session %9 -- parser tests' ]]
  if [[ "$harness" == claude ]]; then
    title_file="$case_dir/projects/session.jsonl.title"
  else
    title_file="$case_dir/sessions/session.jsonl.title"
  fi
  [[ "$(<"$title_file")" == 'parser tests' ]]
  grep -Fq -- "--harness $harness" "$case_dir/resume.log"
  grep -Fxq -- 'attach' "$case_dir/matrix.log"
done

# Matrix lifecycle registration is optional. A failed relay must leave its
# diagnostic in the per-pane log without writing a blocking error screen to
# the harness terminal.
matrix_failure_runtime="$tmp/matrix-failure-runtime"
mkdir -p "$matrix_failure_runtime"
matrix_failure_output="$(
  PATH="$tmp/bin:$PATH" \
    XDG_RUNTIME_DIR="$matrix_failure_runtime" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_PROCESS_LABELER= \
    AGENT_COMPOSE=0 \
    AGENT_MATRIX_TMUX_ENABLE=1 \
    MATRIX_BRIDGE_FAIL=1 \
    MATRIX_BRIDGE_LOG="$tmp/matrix-failure" \
    TMUX=/tmp/fake-tmux,1,0 \
    TMUX_PANE=%9 \
    script -qec "'$agent' pi" /dev/null
)"
[[ "$matrix_failure_output" != *'Matrix lifecycle registration failed'* ]]
grep -Fqx 'bridge unavailable' \
  "$matrix_failure_runtime/agent-window-titles-$UID/9.matrix-register.log"

# A repository prefix is passed only when the session has explicit repository
# scope. The shared title remains unchanged for the window.
case_dir="$(run_case codex 'parser tests' tmux-workspace-tools)"
[[ "$(<"$case_dir/retitle.log")" == '--auto --session %9 --repo tmux-workspace-tools -- parser tests' ]]
[[ "$(<"$case_dir/tmux.log")" == 'rename-window -t %9 -- parser tests' ]]

# The agent title specification can select a different provider and model.
case_dir="$(run_case pi 'local titles' '' '' 0 0 0 0 \
  'name titles with the local model' pi titles/test-model)"
[[ "$(<"$case_dir/content2title-args.log")" == '--provider pi --model titles/test-model --kind query --existing-title agent -- name titles with the local model' ]]

# A title-generation failure is not retried by the watcher.
case_dir="$(run_case claude unused '' '' 1 0 0 0 \
  'diagnose watcher timeout')"
[[ "$(wc -l < "$case_dir/model-input.log")" -eq 1 ]]
[[ ! -e "$case_dir/tmux.log" ]]
[[ ! -e "$case_dir/retitle.log" ]]
[[ ! -e "$case_dir/projects/session.jsonl.title" ]]

# A manual window title stays unchanged. Session naming is independent and
# still receives the generated intent.
case_dir="$(run_case codex 'parser tests' '' manual)"
[[ ! -e "$case_dir/tmux.log" ]]
[[ "$(<"$case_dir/retitle.log")" == '--auto --session %9 -- parser tests' ]]

# A known resumed session ID applies its saved title without another model
# request or a new transcript write, including when it existed before the watcher.
for harness in codex claude pi; do
  case_dir="$(run_case "$harness" unused '' '' 0 0 0 1)"
  [[ ! -e "$case_dir/model-input.log" ]]
  [[ "$(<"$case_dir/tmux.log")" == 'rename-window -t %9 -- saved parser title' ]]
  [[ "$(<"$case_dir/retitle.log")" == '--auto --session %9 -- saved parser title' ]]
done

# A first request split across writes must still be titled exactly once.
for harness in codex claude pi; do
  case_dir="$(run_case "$harness" 'split request' '' '' 0 0 0 0 \
    'please title this split request' '' '' 1)"
  [[ "$(<"$case_dir/model-input.log")" == 'please title this split request' ]]
done

# Codex's open native writer lock identifies the exact session even when
# another watcher has registered for the same harness and working directory.
case_dir="$(run_case codex 'parser ownership' '' '' 0 1)"
[[ "$(<"$case_dir/tmux.log")" == 'rename-window -t %9 -- parser ownership' ]]

# A transcript and saved sidecar that existed before this launch remain owned
# by their original session even when that transcript receives a new turn.
for harness in codex claude pi; do
  case_dir="$(run_case "$harness" 'fresh ownership' '' '' 0 0 1 0 \
    'title only the newly launched session')"
  [[ "$(<"$case_dir/tmux.log")" == 'rename-window -t %9 -- fresh ownership' ]]
  [[ "$(<"$case_dir/model-input.log")" == 'title only the newly launched session' ]]
  if [[ "$harness" == claude ]]; then
    stale_title="$case_dir/projects/stale.jsonl.title"
  else
    stale_title="$case_dir/sessions/stale.jsonl.title"
  fi
  [[ "$(<"$stale_title")" == 'unrelated saved title' ]]
done

printf 'PASS: first agent messages get one shared content title for window and session\n'
