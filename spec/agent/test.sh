#!/usr/bin/env bash

set -euo pipefail

bench_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
agent="$bench_root/bin/agent"
tmp="$(mktemp -d)"
archive_root="$(mktemp -d)"
cleanup_archive_root="${TMPDIR:-/tmp}/rm4agent-$UID/agent-spec-$RANDOM-$BASHPID"
trap 'RM4AGENT_ROOT="$cleanup_archive_root" rm4agent -r "$tmp" "$archive_root" >/dev/null' EXIT
# The launcher injects checkout instructions in any Git repository; run the
# spec from the temporary directory so bare invocations stay repo-free.
cd "$tmp"
export AGENT_MATRIX_TMUX_ENABLE=0
# An inherited labeler re-execs the deployed agent from PATH. This test must
# run the checked-out script.
export AGENT_PROCESS_LABELER=

mkdir -p \
  "$tmp/etc/AGENTS.md.d" \
  "$tmp/home/.agent/AGENTS.md.d" \
  "$tmp/repo/sub"

printf '%s\n' system > "$tmp/etc/AGENTS.md"
printf '%s\n' system-20 > "$tmp/etc/AGENTS.md.d/20-second"
printf '%s\n' system-10 > "$tmp/etc/AGENTS.md.d/10-first"
printf '%s\n' mobile-system > "$tmp/etc/AGENTS.md.d/role-mobile.md"
printf '%s\n' home > "$tmp/home/.agent/AGENTS.md"
printf '%s\n' home-10 > "$tmp/home/.agent/AGENTS.md.d/10-first"
printf '%s\n' root > "$tmp/repo/AGENTS.md"
mkdir -p "$tmp/repo/AGENTS.md.d"
printf '%s\n' mobile-root > "$tmp/repo/AGENTS.md.d/role-mobile.md"
printf '%s\n' pwd > "$tmp/repo/sub/AGENTS.md"
git -C "$tmp/repo" init -q

output="$(
  cd "$tmp/repo/sub"
  HOME="$tmp/home" \
    AGENTSPATH="$tmp/etc:~/.agent:\$gitroot:." \
    "$agent" --print-instructions
)"

expected='system

system-10

system-20

home

home-10

root

pwd'

[[ "$output" == "$expected" ]]

output="$(
  cd "$tmp/repo/sub"
  HOME="$tmp/home" \
    AGENTSPATH="$tmp/etc:~/.agent:\$gitroot:." \
    "$agent" --role mobile --print-instructions
)"

expected='system

system-10

system-20

home

home-10

root

pwd

mobile-system

mobile-root'

[[ "$output" == "$expected" ]]

if AGENTSPATH="$tmp/etc" "$agent" --role missing --print-instructions \
  >"$tmp/missing-role.stdout" 2>"$tmp/missing-role.stderr"; then
  echo "unknown role unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -s "$tmp/missing-role.stdout" ]]
grep -Fqx "agent: unknown role 'missing'." "$tmp/missing-role.stderr"

if AGENTSPATH="$tmp/etc" "$agent" --role '../mobile' --print-instructions \
  >"$tmp/invalid-role.stdout" 2>"$tmp/invalid-role.stderr"; then
  echo "invalid role unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -s "$tmp/invalid-role.stdout" ]]
grep -Fqx "agent: invalid role name '../mobile'." "$tmp/invalid-role.stderr"

output="$(
  cd "$tmp/repo"
  AGENTSPATH='$gitroot:.' \
    "$agent" --print-instructions
)"

[[ "$output" == root ]]

mkdir -p "$tmp/empty"
printf '%s\n' local > "$tmp/empty/AGENTS.md"
output="$(
  cd "$tmp/empty"
  HOME="$tmp/missing-home" \
    AGENTSPATH="$tmp/missing-system:~/.agent:\$gitroot:." \
    "$agent" --print-instructions
)"

[[ "$output" == local ]]

mkdir -p "$tmp/permissions/AGENTS.md.d"
printf '%s\n' disabled > "$tmp/permissions/AGENTS.md"
printf '%s\n' enabled > "$tmp/permissions/AGENTS.md.d/10-enabled"
chmod 000 "$tmp/permissions/AGENTS.md"

output="$(
  AGENTSPATH="$tmp/permissions" \
    "$agent" --print-instructions 2>"$tmp/permissions.stderr"
)"

[[ "$output" == enabled ]]
[[ ! -s "$tmp/permissions.stderr" ]]

# Instruction files named .md.tmpl are rendered by agent.template before they
# join the prompt. A stub renderer stands in for the real one here; the
# renderer's own behaviour is spec/agent-template.
mkdir -p "$tmp/renderer-bin" "$tmp/templates/AGENTS.md.d"
cat > "$tmp/renderer-bin/agent.template" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
file="${!#}"
printf '%s\n' "$@" > "$RENDER_LOG.$(basename "$file")"
printf 'rendered %s\n' "$(basename "$file")"
EOF
chmod +x "$tmp/renderer-bin/agent.template"

printf '%s\n' plain-main > "$tmp/templates/AGENTS.md"
printf '%s\n' fragment-plain > "$tmp/templates/AGENTS.md.d/10-plain.md"
printf '%s\n' fragment-source > "$tmp/templates/AGENTS.md.d/20-generated.md.tmpl"
printf '%s\n' role-source > "$tmp/templates/AGENTS.md.d/role-tmpl.md.tmpl"

output="$(
  cd "$tmp/repo"
  PATH="$tmp/renderer-bin:$PATH" \
    RENDER_LOG="$tmp/render" \
    AGENT_WORKTREE_MODE=here \
    AGENTSPATH="$tmp/templates" \
    "$agent" claude --print-instructions
)"

expected='plain-main

fragment-plain

rendered 20-generated.md.tmpl'

[[ "$output" == "$expected" ]]

# A plain .md file never reaches the renderer.
[[ ! -e "$tmp/render.10-plain.md" ]]

# The launcher supplies the facts a template cannot state for itself.
grep -Fqx -- "harness=claude" "$tmp/render.20-generated.md.tmpl"
grep -Fqx -- "gitroot=$tmp/repo" "$tmp/render.20-generated.md.tmpl"
grep -Fqx -- "launch_dir=$tmp/repo" "$tmp/render.20-generated.md.tmpl"
grep -Fqx -- "roles=" "$tmp/render.20-generated.md.tmpl"

# A templated role file loads only when the role is selected, and it carries
# the selected roles as a fact.
output="$(
  cd "$tmp/repo"
  PATH="$tmp/renderer-bin:$PATH" \
    RENDER_LOG="$tmp/roled" \
    AGENT_WORKTREE_MODE=here \
    AGENTSPATH="$tmp/templates" \
    "$agent" --role tmpl pi --print-instructions
)"

expected='plain-main

fragment-plain

rendered 20-generated.md.tmpl

rendered role-tmpl.md.tmpl'

[[ "$output" == "$expected" ]]
grep -Fqx -- "roles=tmpl" "$tmp/roled.role-tmpl.md.tmpl"

# An unreadable template stays silently disabled, as a plain file does.
mkdir -p "$tmp/template-permissions"
printf '%s\n' hidden > "$tmp/template-permissions/AGENTS.md.tmpl"
chmod 000 "$tmp/template-permissions/AGENTS.md.tmpl"

output="$(
  PATH="$tmp/renderer-bin:$PATH" \
    RENDER_LOG="$tmp/unreadable" \
    AGENTSPATH="$tmp/template-permissions:$tmp/empty" \
    "$agent" --print-instructions 2>"$tmp/template-permissions.stderr"
)"

[[ "$output" == local ]]
[[ ! -s "$tmp/template-permissions.stderr" ]]

# A renderer that fails stops the launcher. A damaged prompt prefix must not
# reach a harness.
mkdir -p "$tmp/failing-bin" "$tmp/failing"
cat > "$tmp/failing-bin/agent.template" <<'EOF'
#!/usr/bin/env bash
echo "agent.template: broken.md.tmpl: unexpected EOF" >&2
exit 1
EOF
chmod +x "$tmp/failing-bin/agent.template"
printf '%s\n' broken > "$tmp/failing/AGENTS.md.tmpl"

if PATH="$tmp/failing-bin:$PATH" AGENTSPATH="$tmp/failing" \
  "$agent" --print-instructions \
  >"$tmp/failing.stdout" 2>"$tmp/failing.stderr"; then
  echo "a failing renderer unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -s "$tmp/failing.stdout" ]]
grep -Fq "unexpected EOF" "$tmp/failing.stderr"

# A template with no renderer available is an error that names the file, not a
# silently dropped instruction.
if AGENT_TEMPLATE_BIN="$tmp/absent-renderer" AGENTSPATH="$tmp/failing" \
  "$agent" --print-instructions \
  >"$tmp/no-renderer.stdout" 2>"$tmp/no-renderer.stderr"; then
  echo "a missing renderer unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -s "$tmp/no-renderer.stdout" ]]
grep -Fq "$tmp/failing/AGENTS.md.tmpl" "$tmp/no-renderer.stderr"
grep -Fq "$tmp/absent-renderer" "$tmp/no-renderer.stderr"

# AGENT_TEMPLATE_BIN also selects a renderer that is not on PATH.
output="$(
  cd "$tmp/repo"
  AGENT_TEMPLATE_BIN="$tmp/renderer-bin/agent.template" \
    RENDER_LOG="$tmp/selected" \
    AGENT_WORKTREE_MODE=here \
    AGENTSPATH="$tmp/failing" \
    "$agent" --print-instructions
)"

[[ "$output" == "rendered AGENTS.md.tmpl" ]]

# One instruction file may exist as Markdown or as a template, not both.
mkdir -p "$tmp/collision"
printf '%s\n' markdown > "$tmp/collision/AGENTS.md"
printf '%s\n' template > "$tmp/collision/AGENTS.md.tmpl"

if PATH="$tmp/renderer-bin:$PATH" AGENTSPATH="$tmp/collision" \
  "$agent" --print-instructions \
  >"$tmp/collision.stdout" 2>"$tmp/collision.stderr"; then
  echo "a Markdown and template collision unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -s "$tmp/collision.stdout" ]]
grep -Fq "$tmp/collision/AGENTS.md" "$tmp/collision.stderr"

# The built-in default AGENTSPATH must name the same home directory that
# home/agents.nix creates. The two spellings drifted apart before.
mkdir -p "$tmp/default-home/.agent" "$tmp/default-cwd"
printf '%s\n' default-home-slot > "$tmp/default-home/.agent/AGENTS.md"
output="$(
  cd "$tmp/default-cwd"
  env -u AGENTSPATH HOME="$tmp/default-home" "$agent" --print-instructions
)"

grep -Fqx default-home-slot <<<"$output"

mkdir -p "$tmp/bin" "$tmp/pi-instructions"
printf '%s\n' pi-system > "$tmp/pi-instructions/AGENTS.md"
cat > "$tmp/bin/pi" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${AGENT_TEST_SHELL_LOG:-}" ]]; then
  printf 'pi\t%s\t%s\n' "$SHELL" "${AGENT_HARNESS:-unset}" >> "$AGENT_TEST_SHELL_LOG"
fi
if [[ "${AGENT_TEST_HARNESH_BRIDGE:-}" == 1 ]]; then
  bridge_arguments=" $* "
  if [[ "$bridge_arguments" != *" --mode json "* ||
        "$bridge_arguments" != *" --model local/ollama-test-model "* ]]; then
    echo "Pi bridge arguments are incomplete: $*" >&2
    exit 70
  fi
  session_id=pi-native
  previous=
  for argument in "$@"; do
    if [[ "$previous" == --session ]]; then
      session_id="$argument"
    fi
    previous="$argument"
  done
  printf 'pi\n' >> "$AGENT_TEST_HARNESH_LOG"
  printf '{"type":"session","version":3,"id":"%s","timestamp":"2026-08-13T00:00:00Z","cwd":"/tmp"}\n' "$session_id"
  jq -cn --arg response "${AGENT_TEST_HARNESH_RESPONSE}" '{
    type: "message_end",
    message: {role: "assistant", content: [{type: "text", text: $response}]}
  }'
  exit 0
fi
if [[ "${1:-}" == "--list-models" ]]; then
  cat <<'MODELS'
provider  model               context  max-out  thinking  images
local     bonsai-8b-q1        32.8K    4.1K     no        no
local     qwen3.6-27b         32.8K    4.1K     no        no
local     qwen3.6-27b-q5      32.8K    4.1K     no        no
local     qwen3.6-35b-a3b     1.0K     128      no        no
MODELS
  exit 0
fi
printf '<%s>\n' "$@"
EOF

cat > "$tmp/bin/local-ai-bench" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--pi-model" && "${2:-}" == "q365d" ]]; then
  printf '%s\n' qwen3.6-35b-a3b
  exit 0
fi
printf 'Unknown configuration key: %s\n' "${2:-}" >&2
exit 1
EOF

cat > "$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${AGENT_TEST_SHELL_LOG:-}" ]]; then
  printf 'claude\t%s\t%s\n' "$SHELL" "${AGENT_HARNESS:-unset}" >> "$AGENT_TEST_SHELL_LOG"
fi
if [[ "${AGENT_TEST_HARNESH_BRIDGE:-}" == 1 ]]; then
  bridge_arguments=" $* "
  if [[ "$bridge_arguments" != *" --print "* ||
        "$bridge_arguments" != *" --output-format json "* ||
        "$bridge_arguments" != *" --json-schema "* ]]; then
    echo "Claude bridge arguments are incomplete: $*" >&2
    exit 70
  fi
  session_id=claude-native
  previous=
  for argument in "$@"; do
    if [[ "$previous" == --resume ]]; then
      session_id="$argument"
    fi
    previous="$argument"
  done
  printf 'claude\n' >> "$AGENT_TEST_HARNESH_LOG"
  jq -cn \
    --arg session_id "$session_id" \
    --argjson response "$AGENT_TEST_HARNESH_RESPONSE" \
    '{type: "result", session_id: $session_id, structured_output: $response}'
  exit 0
fi
printf '<%s>\n' "$@"
EOF

cat > "$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${AGENT_TEST_SHELL_LOG:-}" ]]; then
  printf 'codex\t%s\t%s\n' "$SHELL" "${AGENT_HARNESS:-unset}" >> "$AGENT_TEST_SHELL_LOG"
fi
if [[ " $* " == *" app-server "* ]]; then
  if [[ -n "${CODEX_TEST_APP_SERVER_ARGS_LOG:-}" ]]; then
    printf '<%s>\n' "$@" >> "$CODEX_TEST_APP_SERVER_ARGS_LOG"
  fi
  while IFS= read -r request; do
    if [[ -n "${CODEX_TEST_LOG:-}" ]]; then
      printf '%s\n' "$request" >> "$CODEX_TEST_LOG"
    fi
    case "$request" in
      *'"id":0'*)
        printf '%s\n' '{"id":0,"result":{"userAgent":"test"}}'
        ;;
      *'"method":"config/read"'*)
        if [[ -n "${CODEX_TEST_CONFIG_RESPONSE:-}" ]]; then
          printf '%s\n' "$CODEX_TEST_CONFIG_RESPONSE"
        else
          printf '%s\n' '{"id":1,"result":{"config":{"tui":null},"origins":{},"layers":[]}}'
        fi
        exit 0
        ;;
      *'"method":"config/value/write"'*)
        printf '%s\n' '{"id":1,"result":{"status":"ok","version":"test","filePath":"/tmp/config.toml","overriddenMetadata":null}}'
        exit 0
        ;;
    esac
  done
  exit 0
fi
if [[ "${AGENT_TEST_HARNESH_BRIDGE:-}" == 1 ]]; then
  bridge_arguments=" $* "
  if [[ "$bridge_arguments" != *" exec "* ||
        "$bridge_arguments" != *" --json "* ||
        "$bridge_arguments" != *" --output-schema "* ||
        "$bridge_arguments" != *" --output-last-message "* ]]; then
    echo "Codex bridge arguments are incomplete: $*" >&2
    exit 70
  fi
  response_file=
  session_id=codex-native
  previous=
  for argument in "$@"; do
    if [[ "$previous" == --output-last-message ]]; then
      response_file="$argument"
    fi
    if [[ "$argument" == codex-native ]]; then
      session_id="$argument"
    fi
    previous="$argument"
  done
  printf 'codex\n' >> "$AGENT_TEST_HARNESH_LOG"
  printf '%s\n' "$AGENT_TEST_HARNESH_RESPONSE" > "$response_file"
  printf '{"type":"thread.started","thread_id":"%s"}\n' "$session_id"
  exit 0
fi
printf '<%s>\n' "$@"
EOF

chmod +x \
  "$tmp/bin/pi" \
  "$tmp/bin/local-ai-bench" \
  "$tmp/bin/claude" \
  "$tmp/bin/codex"

# Exercise native argv with no network calls. Model values stay one argument,
# and explicit flags replace the environment default instead of duplicating it.
model_launch() {
  env PATH="$tmp/bin:$PATH" AGENT_ENV_PATH="$tmp/missing-env" \
    AGENTSPATH="$tmp/missing-instructions" AGENT_CODEX_AUTO_TRUST_ROOT= \
    AGENT_MODEL='model with spaces' AGENT_CODEX_FLAGS= AGENT_CLAUDE_FLAGS= \
    AGENT_PI_FLAGS= "$@"
}
for harness in codex claude pi; do
  case "$harness" in
    codex) model_args=(exec hello) ;;
    *) model_args=(--print hello) ;;
  esac
  output="$(model_launch "$agent" "$harness" "${model_args[@]}")"
  [[ "$output" == $'<--model>\n<model with spaces>\n'* ]]
  output="$(model_launch "$agent" "$harness" --model explicit "${model_args[@]}")"
  [[ "$output" != *'<model with spaces>'* && "$output" == *$'<--model>\n<explicit>'* ]]
  output="$(model_launch "$agent" "$harness" --model=explicit "${model_args[@]}")"
  [[ "$output" != *'<model with spaces>'* && "$output" == *'<--model=explicit>'* ]]
  flags_name="AGENT_${harness^^}_FLAGS"
  output="$(model_launch "$flags_name=--model from-flags" "$agent" "$harness" "${model_args[@]}")"
  [[ "$output" != *'<model with spaces>'* && "$output" == *$'<--model>\n<from-flags>'* ]]
done
for model_option in '-c model="config"' '--config=model="config"' '-mmodel-short' '-m model-short'; do
  read -r -a model_args <<<"$model_option"
  output="$(model_launch "$agent" codex "${model_args[@]}" exec hello)"
  [[ "$output" != *'<model with spaces>'* ]]
done
output="$(model_launch 'AGENT_CODEX_FLAGS=-c model="env-config"' "$agent" codex exec hello)"
[[ "$output" != *'<model with spaces>'* && "$output" == *'<model="env-config">'* ]]
output="$(model_launch "$agent" codex resume native-id)"
[[ "$output" == $'<--model>\n<model with spaces>\n'* && "$output" == *$'<resume>\n<native-id>'* ]]
output="$(model_launch AGENT_MODEL= "$agent" claude --print hello)"
[[ "$output" != *'<--model>'* ]]

# Orchestrators select only through AGENT_*; role instructions and native
# arguments remain separate. Unrelated application settings have no effect.
for harness in codex claude pi; do
  case "$harness" in
    codex) model_args=(resume native-id) ;;
    claude) model_args=(--resume native-id --print hello) ;;
    pi) model_args=(--session native-id --print hello) ;;
  esac
  output="$(model_launch AGENT_BIN="$harness" AGENTSPATH="$tmp/etc" \
    KANBAN_AUTHOR_BIN=unsupported KANBAN_AUTHOR_MODEL=wrong-model \
    AGENT_TRANSCRIPTS_BIN="$tmp/no-indexer" AGENT_TEST_SHELL_LOG="$tmp/native-harness.log" \
    "$agent" --role mobile -- "${model_args[@]}")"
  [[ "$output" == $'<--model>\n<model with spaces>\n'* &&
     "$output" == *'<native-id>'* && "$output" == *'mobile-system'* &&
     "$output" != *'<-->'* && "$output" != *'<wrong-model>'* ]]
  IFS=$'\t' read -r native_harness native_shell resolved_harness < <(tail -n 1 "$tmp/native-harness.log")
  [[ "$native_harness" == "$harness" && "$resolved_harness" == "$harness" ]]
done
# A native prompt that equals a harness name cannot select that harness.
output="$(model_launch AGENT_BIN=claude AGENT_TEST_SHELL_LOG="$tmp/native-harness.log" \
  "$agent" -- codex)"
[[ "$output" == *'<codex>'* ]]
IFS=$'\t' read -r native_harness native_shell resolved_harness < <(tail -n 1 "$tmp/native-harness.log")
[[ "$native_harness" == claude && "$resolved_harness" == claude ]]

shell_log="$tmp/harness-shells.log"
for harness in codex claude pi; do
  SHELL=/not/bash \
    AGENT_TEST_SHELL_LOG="$shell_log" \
    AGENT_ENV_PATH="$tmp/missing-env" \
    AGENT_CODEX_AUTO_TRUST_ROOT= \
    PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    "$agent" "$harness" --version >/dev/null
done

# Each harness runs with SHELL set to bash, and with AGENT_HARNESS naming the
# harness that this invocation resolved to.
expected_bash="$(command -v bash)"
expected="codex	$expected_bash	codex
claude	$expected_bash	claude
pi	$expected_bash	pi"
[[ "$(<"$shell_log")" == "$expected" ]]

harnesh_log="$tmp/harnesh-harnesses.log"
harnesh_response='{"kind":"answer","answer":"bridge ok","command":""}'
for harness in codex pi claude; do
  output="$(
    printf '%s' 'Harnesh prompt' |
      AGENT_BIN="$harness" \
      AGENT_TEST_HARNESH_BRIDGE=1 \
      AGENT_TEST_HARNESH_LOG="$harnesh_log" \
      AGENT_TEST_HARNESH_RESPONSE="$harnesh_response" \
      AGENT_ENV_PATH="$tmp/missing-env" \
      AGENT_CODEX_AUTO_TRUST_ROOT= \
      AGENT_PI_FLAGS='--model local/ollama-test-model' \
      PATH="$tmp/bin:$PATH" \
      AGENTSPATH="$tmp/missing-instructions" \
      "$agent" --here --harnesh-turn
  )"
  jq -e \
    --arg harness "$harness" \
    --arg session_id "$harness:$harness-native" \
    '.harness == $harness and .session_id == $session_id and
     .kind == "answer" and .answer == "bridge ok" and .command == ""' \
    >/dev/null <<<"$output"

  resumed="$(
    printf '%s' 'Harnesh follow-up' |
      AGENT_BIN=codex \
      AGENT_TEST_HARNESH_BRIDGE=1 \
      AGENT_TEST_HARNESH_LOG="$harnesh_log" \
      AGENT_TEST_HARNESH_RESPONSE="$harnesh_response" \
      AGENT_ENV_PATH="$tmp/missing-env" \
      AGENT_CODEX_AUTO_TRUST_ROOT= \
      AGENT_PI_FLAGS='--model local/ollama-test-model' \
      PATH="$tmp/bin:$PATH" \
      AGENTSPATH="$tmp/missing-instructions" \
      "$agent" --here --harnesh-turn --session "$harness:$harness-native"
  )"
  jq -e --arg session_id "$harness:$harness-native" \
    '.session_id == $session_id and .answer == "bridge ok"' \
    >/dev/null <<<"$resumed"
done

expected='codex
codex
pi
pi
claude
claude'
[[ "$(<"$harnesh_log")" == "$expected" ]]

if printf '%s' prompt |
  AGENT_BIN=pi \
    AGENT_TEST_HARNESH_BRIDGE=1 \
    AGENT_TEST_HARNESH_LOG="$harnesh_log" \
    AGENT_TEST_HARNESH_RESPONSE='not-json' \
    AGENT_PI_FLAGS='--model local/ollama-test-model' \
    PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    "$agent" --here --harnesh-turn \
    >"$tmp/harnesh-invalid.stdout" 2>"$tmp/harnesh-invalid.stderr"; then
  echo 'invalid Pi Harnesh response unexpectedly succeeded' >&2
  exit 1
fi
[[ ! -s "$tmp/harnesh-invalid.stdout" ]]
grep -Fqx 'agent: Pi returned invalid Harnesh JSON.' \
  "$tmp/harnesh-invalid.stderr"

cat > "$tmp/bin/agent-process-label" <<'EOF'
#!/usr/bin/env bash
printf '<%s>\n' "$@" > "$AGENT_TEST_LABEL_LOG"
export AGENT_PROCESS_LABEL_PID=$$
export AGENT_PROCESS_LABEL_STATUS=labeled
exec "$AGENT_TEST_AGENT" "$@"
EOF
chmod +x "$tmp/bin/agent-process-label"

label_log="$tmp/agent-process-label.log"
label_output="$(
  AGENT_PROCESS_LABELER="$tmp/bin/agent-process-label" \
    AGENT_TEST_AGENT="$agent" \
    AGENT_TEST_LABEL_LOG="$label_log" \
    AGENT_ENV_PATH="$tmp/missing-env" \
    PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    "$agent" --no-update pi --print label-test
)"
expected='<--no-context-files>
<--print>
<label-test>'
[[ "$label_output" == "$expected" ]]
expected='<--no-update>
<pi>
<--print>
<label-test>'
[[ "$(<"$label_log")" == "$expected" ]]

: > "$label_log"
AGENT_PROCESS_LABELER="$tmp/bin/agent-process-label" \
  AGENT_TEST_AGENT="$agent" \
  AGENT_TEST_LABEL_LOG="$label_log" \
  AGENT_PROCESS_LABEL_PID=1 \
  AGENT_ENV_PATH="$tmp/missing-env" \
  PATH="$tmp/bin:$PATH" \
  AGENTSPATH="$tmp/missing-instructions" \
  "$agent" pi --print stale-label >/dev/null
[[ -s "$label_log" ]]

: > "$label_log"
AGENT_PROCESS_LABELER="$tmp/bin/agent-process-label" \
  AGENT_TEST_AGENT="$agent" \
  AGENT_TEST_LABEL_LOG="$label_log" \
  AGENTSPATH="$tmp/etc" \
  "$agent" --print-instructions >/dev/null
[[ ! -s "$label_log" ]]

mkdir -p "$tmp/worktree-bin" "$tmp/worktree-source/sub"
cat > "$tmp/worktree-bin/pi" <<'EOF'
#!/usr/bin/env bash
printf 'PWD=%s\n' "$PWD"
printf 'WORKTREE=%s\n' "${AGENT_WORKTREE-}"
printf 'BRANCH=%s\n' "${AGENT_WORKTREE_BRANCH-}"
printf 'PARENT=%s\n' "${AGENT_PARENT_WORKTREE-}"
printf 'PARENT_BRANCH=%s\n' "${AGENT_PARENT_BRANCH-}"
printf 'PARENT_UPSTREAM=%s\n' "${AGENT_PARENT_UPSTREAM-}"
printf 'PARENT_PUSH=%s\n' "${AGENT_PARENT_PUSH-}"
printf 'AUTHOR_NAME=%s\n' "${GIT_AUTHOR_NAME-}"
printf 'AUTHOR_EMAIL=%s\n' "${GIT_AUTHOR_EMAIL-}"
if [[ -n "${AGENT_WORKTREE-}" ]]; then
  state="$(git -C "$AGENT_WORKTREE" rev-parse --git-path agent-worktree-state)"
  if flock -n "$state" true; then
    printf 'WORKTREE_LOCK=available\n'
  else
    printf 'WORKTREE_LOCK=held\n'
  fi
fi
printf 'ARG=<%s>\n' "$@"
EOF
chmod +x "$tmp/worktree-bin/pi"

git -C "$tmp/worktree-source" init -q -b main
git -C "$tmp/worktree-source" config user.name 'Agent Test'
git -C "$tmp/worktree-source" config user.email agent@example.invalid
printf '%s\n' committed > "$tmp/worktree-source/tracked"
printf '%s\n' subdirectory > "$tmp/worktree-source/sub/tracked-sub"
git -C "$tmp/worktree-source" add tracked sub/tracked-sub
git -C "$tmp/worktree-source" commit -qm initial
git init -q --bare "$tmp/worktree-remote.git"
git -C "$tmp/worktree-source" remote add origin "$tmp/worktree-remote.git"
git -C "$tmp/worktree-source" push -qu origin main
printf '%s\n' uncommitted > "$tmp/worktree-source/tracked"

# The launcher runs every invocation in place: no worktree, no branch, no
# lock. It sets a session author identity in any Git checkout and injects
# the development and git.deploy instructions.
worktree_output="$({
  cd "$tmp/worktree-source/sub"
  PATH="$tmp/worktree-bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    "$agent" pi --print hello
} 2>"$tmp/worktree.stderr")"

grep -Fqx "PWD=$tmp/worktree-source/sub" <<<"$worktree_output"
grep -Fqx 'WORKTREE=' <<<"$worktree_output"
grep -Fqx 'PARENT=' <<<"$worktree_output"
author_name="$(sed -n 's/^AUTHOR_NAME=//p' <<<"$worktree_output")"
[[ "$author_name" =~ ^pi\ [0-9]{8}-[0-9]{6}-[0-9]+$ ]]
identity_slug="${author_name#pi }"
grep -Fqx "AUTHOR_EMAIL=pi.$identity_slug@agents.example.invalid" \
  <<<"$worktree_output"
grep -Fq 'Before changing tracked files, work on a non-deployment feature branch.' \
  <<<"$worktree_output"
grep -Fq "Run git.deploy -m 'MESSAGE' once, only after all requested work in the current development cycle is complete" \
  <<<"$worktree_output"
! grep -Fq 'When a complete unit of work is ready' <<<"$worktree_output"
[[ ! -d "$tmp/worktree-source/.worktrees" ]]
[[ "$(git -C "$tmp/worktree-source" status --short)" == ' M tracked' ]]

# The retired worktree flags stay accepted, run in place, and clear stale
# managed-worktree context from the environment.
for here_flag in --here --no-worktree; do
  here_output="$(
    cd "$tmp/worktree-source/sub"
    AGENT_WORKTREE=/stale/worktree \
      AGENT_WORKTREE_BRANCH=agent/stale \
      AGENT_PARENT_WORKTREE=/stale/parent \
      AGENT_PARENT_BRANCH=stale \
      AGENT_PARENT_UPSTREAM=origin/stale \
      AGENT_PARENT_PUSH=origin/stale \
      PATH="$tmp/worktree-bin:$PATH" \
      AGENTSPATH="$tmp/missing-instructions" \
      "$agent" "$here_flag" pi --print hello
  )"
  grep -Fqx "PWD=$tmp/worktree-source/sub" <<<"$here_output"
  grep -Fqx 'WORKTREE=' <<<"$here_output"
done

# Outside a Git checkout there is no session identity and no deployment
# instruction.
outside_output="$(
  cd "$tmp"
  PATH="$tmp/worktree-bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL \
    "$agent" pi --print hello
)"
grep -Fqx 'AUTHOR_NAME=' <<<"$outside_output"
! grep -Fq 'git.deploy' <<<"$outside_output"

# Codex trusts the project root when it sits under the auto-trust root.
mkdir -p "$tmp/worktree-codex-home/.codex"
: > "$tmp/worktree-codex-home/.codex/config.toml"
: > "$tmp/worktree-codex.log"
(
  cd "$tmp/worktree-source/sub"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CODEX_FLAGS= \
    AGENT_CODEX_AUTO_TRUST_ROOT="$tmp" \
    AGENT_ENV_PATH="$tmp/missing-env" \
    CODEX_TEST_LOG="$tmp/worktree-codex.log" \
    HOME="$tmp/worktree-codex-home" \
    "$agent" codex exec hello
) >"$tmp/worktree-codex.stdout" 2>"$tmp/worktree-codex.stderr"

expected_key_path="projects.\"$tmp/worktree-source\".trust_level"
[[ "$(
  jq -r 'select(.id == 1) | .params.keyPath' "$tmp/worktree-codex.log"
)" == "$expected_key_path" ]]

cat > "$tmp/bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == display-message ]]; then
  if [[ "${*: -1}" == '#S' ]]; then
    printf '%s\n' "$*" >> "$TMUX_TEST_LOG"
    printf '%s\n' bench
  else
    printf '%%9\n'
  fi
else
  printf '%s\n' "$*" >> "$TMUX_TEST_LOG"
fi
EOF

chmod +x "$tmp/bin/tmux"
: > "$tmp/tmux.log"

script -q -e /dev/null -- \
  env \
    PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/pi-instructions" \
    PI_CODING_AGENT_DIR="$tmp/empty-pi" \
    XDG_RUNTIME_DIR="$tmp/runtime" \
    AGENT_COMPOSE=0 \
    TMUX=test \
    TMUX_PANE=%9 \
    TMUX_TEST_LOG="$tmp/tmux.log" \
    "$agent" pi >/dev/null

expected='set-option -wq -t %9 @agent_title_mode auto
rename-window -t %9 -- agent
display-message -p -t %9 #S'

[[ "$(cat "$tmp/tmux.log")" == "$expected" ]]

: > "$tmp/tmux.log"

PATH="$tmp/bin:$PATH" \
  AGENTSPATH="$tmp/pi-instructions" \
  AGENT_BIN=pi \
  PI_CODING_AGENT_DIR="$tmp/empty-pi" \
  TMUX=test \
  TMUX_PANE=%9 \
  TMUX_TEST_LOG="$tmp/tmux.log" \
  "$agent" >/dev/null

[[ ! -s "$tmp/tmux.log" ]]

# Pi loads the packaged name-composition extension only for durable interactive
# sessions. Print/JSON and --no-session launches remain untouched.
run_pi_tty() {
  script -q -e /dev/null -- \
    env \
      PATH="$tmp/bin:$PATH" \
      AGENTSPATH="$tmp/pi-instructions" \
      AGENT_PI_FLAGS="${PI_TTY_FLAGS:-}" \
      AGENT_SHARE_DIR="$bench_root/share/agent" \
      "$agent" pi "$@" |
    tr -d '\r'
}

pi_tty_output="$(run_pi_tty)"
grep -Fqx '<--extension>' <<<"$pi_tty_output"
grep -Fqx "<$bench_root/share/agent/pi/session-id-name.ts>" \
  <<<"$pi_tty_output"

pi_tty_output="$(run_pi_tty --no-session)"
! grep -Fq '<--extension>' <<<"$pi_tty_output"
pi_tty_output="$(run_pi_tty --mode json)"
! grep -Fq '<--extension>' <<<"$pi_tty_output"

pi_parent_id='018f0000-0000-7000-8000-000000000001'
pi_current_id='018f0000-0000-7000-8000-000000000002'
printf '{"type":"session","version":3,"id":"%s","timestamp":"2026-08-31T00:00:00Z","cwd":"/tmp"}\n' \
  "$pi_parent_id" > "$tmp/pi-parent.jsonl"
PI_EXTENSION="$bench_root/share/agent/pi/session-id-name.ts" \
PI_PARENT_FILE="$tmp/pi-parent.jsonl" \
PI_PARENT_ID="$pi_parent_id" \
PI_CURRENT_ID="$pi_current_id" \
  node --experimental-strip-types --input-type=module <<'EOF'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

const extension = await import(pathToFileURL(process.env.PI_EXTENSION).href);

function start(currentName, currentId, reason = "startup", previousSessionFile) {
  let handler;
  const writes = [];
  const pi = {
    on(_event, registered) { handler = registered; },
    getSessionName() { return currentName; },
    setSessionName(name) { writes.push(name); },
  };
  extension.default(pi);
  handler(
    { reason, previousSessionFile },
    { sessionManager: {
      getSessionId: () => currentId,
      getHeader: () => previousSessionFile ? { parentSession: previousSessionFile } : null,
    } },
  );
  return writes;
}

const oldId = process.env.PI_PARENT_ID;
const newId = process.env.PI_CURRENT_ID;
const parentFile = process.env.PI_PARENT_FILE;
assert.equal(extension.readSessionId(parentFile), oldId);
assert.deepEqual(start(undefined, oldId), [oldId]);
assert.deepEqual(start("release", oldId), [`release · ${oldId}`]);
assert.deepEqual(start(`release · ${oldId}`, oldId, "reload"), []);
assert.deepEqual(start(`release · ${oldId}`, oldId, "resume"), []);
assert.deepEqual(
  start(`release · ${oldId}`, newId, "fork", parentFile),
  [`release · ${newId}`],
);
assert.deepEqual(
  start(`release · ${oldId}`, newId, "startup", parentFile),
  [`release · ${oldId} · ${newId}`],
);
const unrelated = "ffffffff-eeee-4ddd-8ccc-bbbbbbbbbbbb";
assert.deepEqual(
  start(`release · ${unrelated}`, newId, "fork", parentFile),
  [`release · ${unrelated} · ${newId}`],
);
EOF

# Pi has no approval or sandbox layer. The launcher forwards tool restrictions
# only when the caller requests them; it adds no permission prompt policy.
output="$(
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/pi-instructions" \
    AGENT_PI_FLAGS='--offline --no-tools' \
    "$agent" pi -m qwen3.6-27b --print hello
)"

expected='<--offline>
<--no-tools>
<--no-context-files>
<--append-system-prompt>
<pi-system>
<--model>
<local/qwen3.6-27b>
<--print>
<hello>'

[[ "$output" == "$expected" ]]

output="$(
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/pi-instructions" \
    "$agent" pi -m @q365d --print hello
)"

expected='<--no-context-files>
<--append-system-prompt>
<pi-system>
<--model>
<local/qwen3.6-35b-a3b>
<--print>
<hello>'

[[ "$output" == "$expected" ]]

output="$(
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/pi-instructions" \
    AGENT_BIN=pi \
    "$agent" -m qwen3.6-27b --print hello
)"

expected='<--no-context-files>
<--append-system-prompt>
<pi-system>
<--model>
<local/qwen3.6-27b>
<--print>
<hello>'

[[ "$output" == "$expected" ]]

output="$(
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/pi-instructions" \
    AGENT_CLAUDE_FLAGS='--model sonnet' \
    "$agent" claude --print hello
)"

expected='<--dangerously-skip-permissions>
<--model>
<sonnet>
<--print>
<hello>
<--append-system-prompt>
<pi-system>'

[[ "$output" == "$expected" ]]

output="$(
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    "$agent" claude --print hello
)"

expected='<--dangerously-skip-permissions>
<--print>
<hello>'
[[ "$output" == "$expected" ]]

# An explicit Claude permission mode replaces the no-prompt default, whether
# it comes from the launcher environment or the command line.
output="$(
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CLAUDE_FLAGS='--permission-mode plan --model sonnet' \
    "$agent" claude --print hello
)"

expected='<--permission-mode>
<plan>
<--model>
<sonnet>
<--print>
<hello>'
[[ "$output" == "$expected" ]]

output="$(
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CLAUDE_FLAGS= \
    "$agent" claude --permission-mode manual --print hello
)"

expected='<--permission-mode>
<manual>
<--print>
<hello>'
[[ "$output" == "$expected" ]]

mkdir -p "$tmp/src/repo/sub" "$tmp/outside"
git -C "$tmp/src/repo" init -q
mkdir -p "$tmp/codex-home/.codex"
: > "$tmp/codex-home/.codex/config.toml"
: > "$tmp/codex.log"

mapfile -t output < <(
  cd "$tmp/src/repo/sub"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CODEX_FLAGS= \
    CODEX_TEST_LOG="$tmp/codex.log" \
    HOME="$tmp/codex-home" \
    AGENT_ENV_PATH="$tmp/missing-env" \
    AGENT_CODEX_AUTO_TRUST_ROOT="$tmp/src" \
    "$agent" codex --version
)

[[ "${output[0]}" == '<--sandbox>' ]]
[[ "${output[1]}" == '<danger-full-access>' ]]
[[ "${output[2]}" == '<--ask-for-approval>' ]]
[[ "${output[3]}" == '<never>' ]]
[[ "${output[4]}" == '<-c>' ]]
[[ "${output[5]}" == '<check_for_update_on_startup=false>' ]]
[[ "${output[6]}" == '<--version>' ]]
[[ "${#output[@]}" -eq 7 ]]

expected_key_path="projects.\"$tmp/src/repo\".trust_level"
[[ "$(
  jq -r 'select(.id == 1) | .params.keyPath' "$tmp/codex.log"
)" == "$expected_key_path" ]]

: > "$tmp/codex.log"
mapfile -t output < <(
  cd "$tmp/outside"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CODEX_FLAGS= \
    CODEX_TEST_LOG="$tmp/codex.log" \
    HOME="$tmp/codex-home" \
    AGENT_ENV_PATH="$tmp/missing-env" \
    AGENT_CODEX_AUTO_TRUST_ROOT="$tmp/src" \
    "$agent" codex -C "$tmp/src/repo/sub" --version
)

[[ "${output[0]}" == '<--sandbox>' ]]
[[ "${output[1]}" == '<danger-full-access>' ]]
[[ "${output[2]}" == '<--ask-for-approval>' ]]
[[ "${output[3]}" == '<never>' ]]
[[ "${output[4]}" == '<-c>' ]]
[[ "${output[5]}" == '<check_for_update_on_startup=false>' ]]
[[ "${output[6]}" == '<-C>' ]]
[[ "${output[7]}" == "<$tmp/src/repo/sub>" ]]
[[ "${output[8]}" == '<--version>' ]]
[[ "${#output[@]}" -eq 9 ]]
[[ "$(
  jq -r 'select(.id == 1) | .params.keyPath' "$tmp/codex.log"
)" == "$expected_key_path" ]]

printf '[projects."%s"]\ntrust_level = "trusted"\n' \
  "$tmp/src/repo" > "$tmp/codex-home/.codex/config.toml"
: > "$tmp/codex.log"
mapfile -t output < <(
  cd "$tmp/src/repo"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CODEX_FLAGS= \
    CODEX_TEST_LOG="$tmp/codex.log" \
    HOME="$tmp/codex-home" \
    AGENT_ENV_PATH="$tmp/missing-env" \
    AGENT_CODEX_AUTO_TRUST_ROOT="$tmp/src" \
    "$agent" codex --version
)

[[ "${output[0]}" == '<--sandbox>' ]]
[[ "${output[1]}" == '<danger-full-access>' ]]
[[ "${output[2]}" == '<--ask-for-approval>' ]]
[[ "${output[3]}" == '<never>' ]]
[[ "${output[4]}" == '<-c>' ]]
[[ "${output[5]}" == '<check_for_update_on_startup=false>' ]]
[[ "${output[6]}" == '<--version>' ]]
[[ "${#output[@]}" -eq 7 ]]
[[ ! -s "$tmp/codex.log" ]]

: > "$tmp/codex.log"
mapfile -t output < <(
  cd "$tmp/src/repo"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CODEX_FLAGS= \
    CODEX_TEST_LOG="$tmp/codex.log" \
    HOME="$tmp/codex-home" \
    AGENT_ENV_PATH="$tmp/missing-env" \
    AGENT_CODEX_AUTO_TRUST_ROOT= \
    "$agent" codex --version
)

[[ "${output[0]}" == '<--sandbox>' ]]
[[ "${output[1]}" == '<danger-full-access>' ]]
[[ "${output[2]}" == '<--ask-for-approval>' ]]
[[ "${output[3]}" == '<never>' ]]
[[ "${output[4]}" == '<-c>' ]]
[[ "${output[5]}" == '<check_for_update_on_startup=false>' ]]
[[ "${output[6]}" == '<--version>' ]]
[[ "${#output[@]}" -eq 7 ]]
[[ ! -s "$tmp/codex.log" ]]

mkdir -p "$tmp/src/not-a-repo"
: > "$tmp/codex.log"
mapfile -t output < <(
  cd "$tmp/src/not-a-repo"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CODEX_FLAGS= \
    CODEX_TEST_LOG="$tmp/codex.log" \
    HOME="$tmp/codex-home" \
    AGENT_ENV_PATH="$tmp/missing-env" \
    AGENT_CODEX_AUTO_TRUST_ROOT="$tmp/src" \
    "$agent" codex --version
)

[[ "${output[0]}" == '<--sandbox>' ]]
[[ "${output[1]}" == '<danger-full-access>' ]]
[[ "${output[2]}" == '<--ask-for-approval>' ]]
[[ "${output[3]}" == '<never>' ]]
[[ "${output[4]}" == '<-c>' ]]
[[ "${output[5]}" == '<check_for_update_on_startup=false>' ]]
[[ "${output[6]}" == '<--version>' ]]
[[ "${#output[@]}" -eq 7 ]]
[[ "$(
  jq -r 'select(.id == 1) | .params.keyPath' "$tmp/codex.log"
)" == "projects.\"$tmp/src/not-a-repo\".trust_level" ]]

# Codex gets the same no-prompt defaults for interactive resumes as for exec.
mapfile -t output < <(
  cd "$tmp/outside"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CODEX_FLAGS= \
    AGENT_CODEX_AUTO_TRUST_ROOT= \
    AGENT_ENV_PATH="$tmp/missing-env" \
    HOME="$tmp/codex-home" \
    "$agent" codex resume test-session
)

expected='<--sandbox>
<danger-full-access>
<--ask-for-approval>
<never>
<-c>
<check_for_update_on_startup=false>
<-c>
<tui.status_line=["model-with-reasoning","context-remaining","current-dir","thread-id"]>
<resume>
<test-session>'
[[ "${output[*]}" == "$(tr '\n' ' ' <<<"$expected" | sed 's/ $//')" ]]

# Explicit values, including AGENT_CODEX_FLAGS, replace each default without
# producing duplicate options that Codex rejects.
mapfile -t output < <(
  cd "$tmp/outside"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CODEX_FLAGS='--sandbox workspace-write' \
    AGENT_CODEX_AUTO_TRUST_ROOT= \
    AGENT_ENV_PATH="$tmp/missing-env" \
    HOME="$tmp/codex-home" \
    "$agent" codex --ask-for-approval on-request resume test-session
)

expected='<--sandbox>
<workspace-write>
<-c>
<check_for_update_on_startup=false>
<-c>
<tui.status_line=["model-with-reasoning","context-remaining","current-dir","thread-id"]>
<--ask-for-approval>
<on-request>
<resume>
<test-session>'
[[ "${output[*]}" == "$(tr '\n' ' ' <<<"$expected" | sed 's/ $//')" ]]

# The old exec-specific sandbox environment remains a compatibility alias.
mapfile -t output < <(
  cd "$tmp/outside"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CODEX_FLAGS= \
    AGENT_CODEX_APPROVAL=on-request \
    AGENT_CODEX_AUTO_TRUST_ROOT= \
    AGENT_ENV_PATH="$tmp/missing-env" \
    AGENT_EXEC_SANDBOX=read-only \
    HOME="$tmp/codex-home" \
    "$agent" codex exec hello
)

expected='<--sandbox>
<read-only>
<--ask-for-approval>
<on-request>
<-c>
<check_for_update_on_startup=false>
<exec>
<hello>'
[[ "${output[*]}" == "$(tr '\n' ' ' <<<"$expected" | sed 's/ $//')" ]]

# The combined Codex bypass flag is already a complete explicit policy.
mapfile -t output < <(
  cd "$tmp/outside"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CODEX_FLAGS= \
    AGENT_CODEX_AUTO_TRUST_ROOT= \
    AGENT_ENV_PATH="$tmp/missing-env" \
    HOME="$tmp/codex-home" \
    "$agent" codex --dangerously-bypass-approvals-and-sandbox resume test-session \
      2>"$tmp/codex-default-status.stderr"
)

expected='<-c>
<check_for_update_on_startup=false>
<-c>
<tui.status_line=["model-with-reasoning","context-remaining","current-dir","thread-id"]>
<--dangerously-bypass-approvals-and-sandbox>
<resume>
<test-session>'
[[ "${output[*]}" == "$(tr '\n' ' ' <<<"$expected" | sed 's/ $//')" ]]
[[ ! -s "$tmp/codex-default-status.stderr" ]]

# Codex status-line composition preserves the effective array while enforcing
# the copyable native thread ID. The config/read response models user and
# project layers after Codex has applied their real precedence.
codex_layered_response='{"id":1,"result":{"config":{"tui":{"status_line":["git-branch","model"]}},"origins":{"tui.status_line":{"name":{"type":"project","dotCodexFolder":"/tmp/.codex"},"version":"test"}},"layers":[{"name":{"type":"user","file":"/tmp/config.toml"},"version":"user","config":{"tui":{"status_line":["model"]}}},{"name":{"type":"project","dotCodexFolder":"/tmp/.codex"},"version":"project","config":{"tui":{"status_line":["git-branch","model"]}}}]}}'
: > "$tmp/codex-status.log"
: > "$tmp/codex-app-server-args.log"
mapfile -t output < <(
  cd "$tmp/outside"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CODEX_FLAGS='--config tui.status_line=["model"] -c model="env"' \
    AGENT_CODEX_AUTO_TRUST_ROOT= \
    AGENT_ENV_PATH="$tmp/missing-env" \
    CODEX_TEST_LOG="$tmp/codex-status.log" \
    CODEX_TEST_APP_SERVER_ARGS_LOG="$tmp/codex-app-server-args.log" \
    CODEX_TEST_CONFIG_RESPONSE="$codex_layered_response" \
    HOME="$tmp/codex-home" \
    "$agent" codex --config='tui.status_line=["git-branch","model"]' \
      resume test-session
)
[[ "$(printf '%s\n' "${output[@]}" | grep -Fxc '<tui.status_line=["git-branch","model","thread-id"]>')" -eq 1 ]]
! printf '%s\n' "${output[@]}" | grep -Fq '<tui.status_line=["model"]>'
printf '%s\n' "${output[@]}" | grep -Fqx '<model="env">'
grep -Fqx '<tui.status_line=["model"]>' "$tmp/codex-app-server-args.log"
grep -Fqx '<tui.status_line=["git-branch","model"]>' "$tmp/codex-app-server-args.log"
[[ "$(
  jq -r 'select(.method == "config/read") | .params.cwd' "$tmp/codex-status.log"
)" == "$tmp/outside" ]]

# Explicit null and empty values intentionally collapse to an ID-only footer;
# an existing thread-id is not duplicated.
for status_case in null empty present; do
  case "$status_case" in
    null)
      effective=null
      expected_status='["thread-id"]'
      ;;
    empty)
      effective='[]'
      expected_status='["thread-id"]'
      ;;
    present)
      effective='["thread-id","current-dir"]'
      expected_status='["thread-id","current-dir"]'
      ;;
  esac
  codex_status_response="$(
    jq -cn --argjson status "$effective" '{
      id: 1,
      result: {
        config: {tui: {status_line: $status}},
        origins: {"tui.status_line": {name: {type: "sessionFlags"}, version: "test"}},
        layers: [{name: {type: "sessionFlags"}, version: "test",
          config: {tui: {status_line: $status}}}]
      }
    }'
  )"
  mapfile -t output < <(
    cd "$tmp/outside"
    PATH="$tmp/bin:$PATH" \
      AGENTSPATH="$tmp/missing-instructions" \
      AGENT_CODEX_FLAGS= \
      AGENT_CODEX_AUTO_TRUST_ROOT= \
      AGENT_ENV_PATH="$tmp/missing-env" \
      CODEX_TEST_CONFIG_RESPONSE="$codex_status_response" \
      HOME="$tmp/codex-home" \
      "$agent" codex resume test-session
  )
  [[ "$(printf '%s\n' "${output[@]}" | grep -Fxc "<tui.status_line=$expected_status>")" -eq 1 ]]
done

# Claude trusts the project root when it sits under the auto-trust root:
# the launcher accepts the trust dialog in the configuration file ahead of
# the launch, exactly as the Codex path persists its trust level.
mkdir -p "$tmp/claude-home"
printf '{}\n' > "$tmp/claude-home/.claude.json"
(
  cd "$tmp/src/repo/sub"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CLAUDE_FLAGS= \
    HOME="$tmp/claude-home" \
    AGENT_ENV_PATH="$tmp/missing-env" \
    AGENT_CLAUDE_AUTO_TRUST_ROOT="$tmp/src" \
    "$agent" claude --version >/dev/null
)
jq -e --arg dir "$tmp/src/repo" \
  '.projects[$dir].hasTrustDialogAccepted == true' \
  "$tmp/claude-home/.claude.json" >/dev/null

# A second launch finds the trust in place and leaves the file alone.
before="$(cat "$tmp/claude-home/.claude.json")"
touch -d '2001-01-01 00:00:00' "$tmp/claude-home/.claude.json"
(
  cd "$tmp/src/repo"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CLAUDE_FLAGS= \
    HOME="$tmp/claude-home" \
    AGENT_ENV_PATH="$tmp/missing-env" \
    AGENT_CLAUDE_AUTO_TRUST_ROOT="$tmp/src" \
    "$agent" claude --version >/dev/null
)
[[ "$(cat "$tmp/claude-home/.claude.json")" == "$before" ]]
[[ "$(date -r "$tmp/claude-home/.claude.json" '+%Y')" == 2001 ]]

# An empty auto-trust root turns the write off.
printf '{}\n' > "$tmp/claude-home/.claude.json"
(
  cd "$tmp/src/repo"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CLAUDE_FLAGS= \
    HOME="$tmp/claude-home" \
    AGENT_ENV_PATH="$tmp/missing-env" \
    AGENT_CLAUDE_AUTO_TRUST_ROOT= \
    "$agent" claude --version >/dev/null
)
[[ "$(cat "$tmp/claude-home/.claude.json")" == '{}' ]]

# The home directory never gains trust, even under the auto-trust root:
# Claude refuses to save it, so a stale entry would only mask the dialog.
(
  cd "$tmp/claude-home"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CLAUDE_FLAGS= \
    HOME="$tmp/claude-home" \
    AGENT_ENV_PATH="$tmp/missing-env" \
    AGENT_CLAUDE_AUTO_TRUST_ROOT="$tmp" \
    "$agent" claude --version >/dev/null
)
[[ "$(cat "$tmp/claude-home/.claude.json")" == '{}' ]]

# A missing configuration file is never invented: first-run onboarding
# owns its creation.
rm -f "$tmp/claude-home/.claude.json"
(
  cd "$tmp/src/repo"
  PATH="$tmp/bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CLAUDE_FLAGS= \
    HOME="$tmp/claude-home" \
    AGENT_ENV_PATH="$tmp/missing-env" \
    AGENT_CLAUDE_AUTO_TRUST_ROOT="$tmp/src" \
    "$agent" claude --version >/dev/null
)
[[ ! -e "$tmp/claude-home/.claude.json" ]]

# Durable interactive Claude launches expose only UUIDs known before launch.
# The launcher composes custom names into the existing prompt-box name rather
# than adding another row.
run_claude_tty() {
  script -q -e /dev/null -- \
    env \
      PATH="$tmp/bin:$PATH" \
      AGENTSPATH="$tmp/missing-instructions" \
      AGENT_CLAUDE_FLAGS="${CLAUDE_TTY_FLAGS:-}" \
      AGENT_CLAUDE_AUTO_TRUST_ROOT= \
      HOME="$tmp/claude-home" \
      "$agent" claude "$@" |
    tr -d '\r'
}

claude_tty_output="$(run_claude_tty)"
generated_claude_id="$(
  awk '$0 == "<--session-id>" {getline; gsub(/[<>]/, ""); print; exit}' \
    <<<"$claude_tty_output"
)"
[[ "$generated_claude_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]
grep -Fqx "<$generated_claude_id>" <<<"$claude_tty_output"
[[ "$(grep -Fxc '<--name>' <<<"$claude_tty_output")" -eq 1 ]]

claude_uuid='11111111-2222-4333-8444-555555555555'
claude_other_uuid='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
claude_tty_output="$(run_claude_tty --session-id "$claude_uuid" --name release)"
[[ "$(grep -Fxc '<--session-id>' <<<"$claude_tty_output")" -eq 1 ]]
grep -Fqx "<release · $claude_uuid>" <<<"$claude_tty_output"

claude_tty_output="$(
  CLAUDE_TTY_FLAGS='--name=environment' \
    run_claude_tty --name command --resume="$claude_uuid"
)"
[[ "$(grep -Fxc '<--name>' <<<"$claude_tty_output")" -eq 1 ]]
grep -Fqx "<command · $claude_uuid>" <<<"$claude_tty_output"
! grep -Fq '<environment>' <<<"$claude_tty_output"

claude_tty_output="$(run_claude_tty -r "$claude_uuid")"
grep -Fqx "<$claude_uuid>" <<<"$claude_tty_output"
grep -Fqx '<--name>' <<<"$claude_tty_output"

assert_claude_unknown_selector() {
  local selector_output
  selector_output="$(run_claude_tty "$@")"
  ! grep -Fq '<--name>' <<<"$selector_output"
}

assert_claude_unknown_selector --resume
assert_claude_unknown_selector --resume search-term
assert_claude_unknown_selector --from-pr
assert_claude_unknown_selector --from-pr 123
assert_claude_unknown_selector --continue
assert_claude_unknown_selector --resume "$claude_uuid" --fork-session
assert_claude_unknown_selector --resume "$claude_uuid" \
  --session-id "$claude_other_uuid"
claude_tty_output="$(
  CLAUDE_TTY_FLAGS='--name=manual' run_claude_tty --continue
)"
grep -Fqx '<--name=manual>' <<<"$claude_tty_output"
! grep -Fq "<$claude_uuid>" <<<"$claude_tty_output"

if PATH="$tmp/bin:$PATH" "$agent" pi-bonsai >"$tmp/legacy.stdout" 2>"$tmp/legacy.stderr"; then
  exit 1
fi
[[ ! -s "$tmp/legacy.stdout" ]]
expected="The pi-bonsai selector was removed; use 'agent pi -m bonsai-8b-q1'."
[[ "$(cat "$tmp/legacy.stderr")" == "$expected" ]]

if PATH="$tmp/bin:$PATH" AGENTSPATH="$tmp/pi-instructions" \
  "$agent" pi -m qwen3.6 --print hello \
  >"$tmp/ambiguous.stdout" 2>"$tmp/ambiguous.stderr"; then
  exit 1
fi
[[ ! -s "$tmp/ambiguous.stdout" ]]
expected="agent pi: model pattern 'qwen3.6' is ambiguous:
  qwen3.6-27b
  qwen3.6-27b-q5
  qwen3.6-35b-a3b"
[[ "$(cat "$tmp/ambiguous.stderr")" == "$expected" ]]

# --- agent resume asks agent-transcripts for the recent-session list. A
# stub records the calls: an index refresh first, then the recent listing,
# scoped to the current repository unless --all widens it.
mkdir -p "$tmp/resume-bin"
export AGENT_TRANSCRIPTS_BIN="$tmp/resume-bin/agent-transcripts"
cat > "$tmp/resume-bin/agent-transcripts" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${AGENT_TEST_TRANSCRIPTS_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$AGENT_TEST_TRANSCRIPTS_LOG"
fi
if [[ ( "${1:-}" == sessions && "${2:-}" == --json ) ||
      ( "${1:-}" == recent && "${*: -1}" == --json ) ]]; then
  printf '%s\n' "${AGENT_TEST_SESSIONS:-}"
  exit 0
fi
if [[ -n "${AGENT_TEST_TRANSCRIPTS_LOG:-}" ]]; then
  exit 0
fi
printf 'stub:%s\n' "$*"
EOF
chmod +x "$tmp/resume-bin/agent-transcripts"

output="$(
  cd "$tmp/repo"
  PATH="$tmp/resume-bin:$PATH" "$agent" resume --list --all
)"
expected='stub:index --quiet
stub:recent --limit 30'
[[ "$output" == "$expected" ]]

repo_root_physical="$(cd "$tmp/repo" && git rev-parse --show-toplevel)"
output="$(
  cd "$tmp/repo"
  PATH="$tmp/resume-bin:$PATH" "$agent" resume --list --limit 5
)"
expected="stub:index --quiet
stub:recent --limit 5 --repo $repo_root_physical"
[[ "$output" == "$expected" ]]

# Outside a repository the scope is the launch directory itself.
output="$(
  cd "$tmp"
  PATH="$tmp/resume-bin:$PATH" "$agent" resume --list
)"
expected="stub:index --quiet
stub:recent --limit 30 --repo $(cd "$tmp" && pwd -P)"
[[ "$output" == "$expected" ]]

# An unknown resume argument is rejected before anything runs.
if PATH="$tmp/resume-bin:$PATH" "$agent" resume --bogus \
  >"$tmp/resume.stdout" 2>"$tmp/resume.stderr"; then
  exit 1
fi
[[ ! -s "$tmp/resume.stdout" ]]
[[ "$(cat "$tmp/resume.stderr")" == 'usage: agent resume [ID|HARNESS:ID] | agent resume [--all] [--list] [--limit N]' ]]

# A copied native ID bypasses the picker, resolves globally across harnesses,
# and restores the indexed working directory before invoking the native resume.
cat > "$tmp/resume-bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" app-server "* ]]; then
  while IFS= read -r request; do
    case "$request" in
      *'"id":0'*)
        printf '%s\n' '{"id":0,"result":{"userAgent":"test"}}'
        ;;
      *'"method":"config/read"'*)
        printf '%s\n' '{"id":1,"result":{"config":{"tui":null},"origins":{},"layers":[]}}'
        exit 0
        ;;
    esac
  done
  exit 0
fi
printf 'PWD=%s\n' "$PWD"
printf '<%s>\n' "$@"
EOF
cat > "$tmp/resume-bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'PWD=%s\n' "$PWD"
printf '<%s>\n' "$@"
EOF
cat > "$tmp/resume-bin/pi" <<'EOF'
#!/usr/bin/env bash
printf 'PWD=%s\n' "$PWD"
printf '<%s>\n' "$@"
EOF
chmod +x "$tmp/resume-bin/codex" "$tmp/resume-bin/claude" "$tmp/resume-bin/pi"

mkdir -p "$tmp/resume-codex" "$tmp/resume-claude" "$tmp/resume-pi"
session_rows="$(
  jq -cn \
    --arg codex_cwd "$tmp/resume-codex" \
    --arg claude_cwd "$tmp/resume-claude" \
    --arg pi_cwd "$tmp/resume-pi" '
      {harness: "codex", session_id: "codex-native", cwd: $codex_cwd},
      {harness: "claude", session_id: "11111111-2222-4333-8444-555555555555", cwd: $claude_cwd},
      {harness: "pi", session_id: "pi-native", cwd: $pi_cwd}
    '
)"
: > "$tmp/direct-transcripts.log"
for direct_id in codex-native 11111111-2222-4333-8444-555555555555 pi-native; do
  case "$direct_id" in
    codex-native) expected_resume_cwd="$tmp/resume-codex" ;;
    11111111-2222-4333-8444-555555555555) expected_resume_cwd="$tmp/resume-claude" ;;
    pi-native) expected_resume_cwd="$tmp/resume-pi" ;;
  esac
  direct_output="$(
    cd "$tmp"
    PATH="$tmp/resume-bin:$PATH" \
      AGENTSPATH="$tmp/missing-instructions" \
      AGENT_CODEX_AUTO_TRUST_ROOT= \
      AGENT_ENV_PATH="$tmp/missing-env" \
      AGENT_TEST_SESSIONS="$session_rows" \
      AGENT_TEST_TRANSCRIPTS_LOG="$tmp/direct-transcripts.log" \
      "$agent" resume "$direct_id"
  )"
  grep -Fqx "<$direct_id>" <<<"$direct_output"
  grep -Fqx "PWD=$expected_resume_cwd" <<<"$direct_output"
done
grep -Fqx "PWD=$tmp/resume-codex" <<<"$(
  cd "$tmp"
  PATH="$tmp/resume-bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CODEX_AUTO_TRUST_ROOT= \
    AGENT_ENV_PATH="$tmp/missing-env" \
    AGENT_TEST_SESSIONS="$session_rows" \
    AGENT_TEST_TRANSCRIPTS_LOG="$tmp/direct-transcripts.log" \
    "$agent" resume codex:codex-native
)"
grep -Fqx 'sessions --json' "$tmp/direct-transcripts.log"

# Re-entering the launcher must keep the selected role and load it in the
# resumed working directory.
mkdir -p "$tmp/resume-pi/AGENTS.md.d"
printf 'resumed-review-role\n' > "$tmp/resume-pi/AGENTS.md.d/role-review.md"
role_resume_output="$(
  PATH="$tmp/resume-bin:$PATH" \
    AGENTSPATH=. AGENT_TEST_SESSIONS="$session_rows" \
    AGENT_TEST_TRANSCRIPTS_LOG="$tmp/direct-transcripts.log" \
    "$agent" --role review resume pi:pi-native
)"
grep -Fqx '<resumed-review-role>' <<<"$role_resume_output"

ambiguous_rows="$(
  jq -cn \
    --arg codex_cwd "$tmp/resume-codex" \
    --arg claude_cwd "$tmp/resume-claude" '
      {harness: "codex", session_id: "shared-native", cwd: $codex_cwd},
      {harness: "claude", session_id: "shared-native", cwd: $claude_cwd}
    '
)"
if PATH="$tmp/resume-bin:$PATH" \
  AGENT_TEST_SESSIONS="$ambiguous_rows" \
  AGENT_TEST_TRANSCRIPTS_LOG="$tmp/direct-transcripts.log" \
  "$agent" resume shared-native \
  >"$tmp/direct.stdout" 2>"$tmp/direct.stderr"; then
  exit 1
fi
[[ ! -s "$tmp/direct.stdout" ]]
grep -Fqx "agent resume: native ID 'shared-native' is ambiguous; use HARNESS:ID." \
  "$tmp/direct.stderr"
prefixed_output="$(
    PATH="$tmp/resume-bin:$PATH" \
      AGENTSPATH="$tmp/missing-instructions" \
      AGENT_ENV_PATH="$tmp/missing-env" \
      AGENT_TEST_SESSIONS="$ambiguous_rows" \
    AGENT_TEST_TRANSCRIPTS_LOG="$tmp/direct-transcripts.log" \
    "$agent" resume claude:shared-native
)"
grep -Fqx 'PWD='"$tmp/resume-claude" <<<"$prefixed_output"
grep -Fqx '<shared-native>' <<<"$prefixed_output"

# A native session remains one resume target when the index contains copied
# primary transcripts or child-agent transcripts that repeat the parent's ID.
# Prefer a nonempty cwd from the earliest primary row, deterministically.
duplicate_claude_id='22222222-3333-4444-8555-666666666666'
mkdir -p "$tmp/resume-claude-copy" "$tmp/resume-claude-child"
duplicate_claude_rows="$(
  jq -cn \
    --arg id "$duplicate_claude_id" \
    --arg original_cwd "$tmp/resume-claude" \
    --arg copy_cwd "$tmp/resume-claude-copy" \
    --arg child_cwd "$tmp/resume-claude-child" '
      {harness: "claude", session_id: $id, cwd: $copy_cwd,
        started_at: "2026-08-31T00:00:02Z",
        path: ("/copies/late/" + $id + ".jsonl")},
      {harness: "claude", session_id: $id, cwd: $original_cwd,
        started_at: "2026-08-31T00:00:01Z",
        path: ("/copies/early/" + $id + ".jsonl")},
      {harness: "claude", session_id: $id, cwd: $child_cwd,
        started_at: "2026-08-31T00:00:00Z",
        path: ("/copies/early/" + $id + "/subagents/agent-a.jsonl")}
    '
)"
for duplicate_selector in "$duplicate_claude_id" "claude:$duplicate_claude_id"; do
  duplicate_output="$(
    cd "$tmp"
    PATH="$tmp/resume-bin:$PATH" \
      AGENTSPATH="$tmp/missing-instructions" \
      AGENT_ENV_PATH="$tmp/missing-env" \
      AGENT_TEST_SESSIONS="$duplicate_claude_rows" \
      AGENT_TEST_TRANSCRIPTS_LOG="$tmp/direct-transcripts.log" \
      "$agent" resume "$duplicate_selector"
  )"
  grep -Fqx "PWD=$tmp/resume-claude" <<<"$duplicate_output"
  grep -Fqx "<$duplicate_claude_id>" <<<"$duplicate_output"
done

# Codex subagents record the resumable parent session_id in a transcript whose
# own rollout filename has a different thread ID. Ignore those child rows.
duplicate_codex_id='019ff1bc-a631-7693-8e53-411ae64a4e30'
mkdir -p "$tmp/resume-codex-child"
duplicate_codex_rows="$(
  jq -cn \
    --arg id "$duplicate_codex_id" \
    --arg primary_cwd "$tmp/resume-codex" \
    --arg child_cwd "$tmp/resume-codex-child" '
      {harness: "codex", session_id: $id, cwd: $primary_cwd,
        started_at: "2026-08-31T00:00:01Z",
        path: ("/sessions/rollout-2026-08-31-" + $id + ".jsonl")},
      {harness: "codex", session_id: $id, cwd: $child_cwd,
        started_at: "2026-08-31T00:00:02Z",
        path: "/sessions/rollout-2026-08-31-019ff779-20ca-7bd3-bb2f-d5faf2cbcb5d.jsonl"}
    '
)"
duplicate_output="$(
  cd "$tmp"
  PATH="$tmp/resume-bin:$PATH" \
    AGENTSPATH="$tmp/missing-instructions" \
    AGENT_CODEX_AUTO_TRUST_ROOT= \
    AGENT_ENV_PATH="$tmp/missing-env" \
    AGENT_TEST_SESSIONS="$duplicate_codex_rows" \
    AGENT_TEST_TRANSCRIPTS_LOG="$tmp/direct-transcripts.log" \
    "$agent" resume "$duplicate_codex_id"
)"
grep -Fqx "PWD=$tmp/resume-codex" <<<"$duplicate_output"
grep -Fqx "<$duplicate_codex_id>" <<<"$duplicate_output"

if PATH="$tmp/resume-bin:$PATH" \
  AGENT_TEST_SESSIONS="$session_rows" \
  AGENT_TEST_TRANSCRIPTS_LOG="$tmp/direct-transcripts.log" \
  "$agent" resume missing-native \
  >"$tmp/direct.stdout" 2>"$tmp/direct.stderr"; then
  exit 1
fi
grep -Fqx "agent resume: no indexed session has native ID 'missing-native'." \
  "$tmp/direct.stderr"

if PATH="$tmp/resume-bin:$PATH" "$agent" resume one two \
  >"$tmp/direct.stdout" 2>"$tmp/direct.stderr"; then
  exit 1
fi
grep -Fqx 'usage: agent resume [ID|HARNESS:ID] | agent resume [--all] [--list] [--limit N]' \
  "$tmp/direct.stderr"

if PATH="$tmp/resume-bin:$PATH" "$agent" resume unknown:native \
  >"$tmp/direct.stdout" 2>"$tmp/direct.stderr"; then
  exit 1
fi
grep -Fqx "agent resume: unsupported harness prefix 'unknown'." \
  "$tmp/direct.stderr"

# The interactive picker keeps roles and restores paths without a TSV round
# trip. A backslash in the working directory must reach the native harness.
picker_cwd="$tmp/resume-picker\\project"
mkdir -p "$picker_cwd/AGENTS.md.d"
printf 'picker-review-role\n' > "$picker_cwd/AGENTS.md.d/role-review.md"
cat > "$tmp/resume-bin/fzf" <<'EOF'
#!/usr/bin/env bash
sed -n '2p'
EOF
chmod +x "$tmp/resume-bin/fzf"
picker_rows="$(jq -cn --arg cwd "$picker_cwd" '
  {harness: "pi", session_id: "first", cwd: "/absent"},
  {harness: "pi", session_id: "picked", cwd: $cwd}')"
picker_output="$(
  PATH="$tmp/resume-bin:$PATH" AGENTSPATH=. \
    AGENT_TEST_SESSIONS="$picker_rows" \
    AGENT_TEST_TRANSCRIPTS_LOG="$tmp/direct-transcripts.log" \
    script -qec "'$agent' --role review resume --all" /dev/null | tr -d '\r'
)"
grep -Fqx "PWD=$picker_cwd" <<<"$picker_output"
grep -Fqx '<picked>' <<<"$picker_output"
grep -Fqx '<picker-review-role>' <<<"$picker_output"
