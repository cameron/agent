#!/usr/bin/env bash

set -euo pipefail

[[ -n "${NIX_BUILD_TOP:-}" ]] || {
  echo 'Run make test; terminal fixtures require the Nix sandbox.' >&2
  exit 2
}

# With AGENT_COMPOSE set, a lone interactive agent pane gains a companion
# editor pane on the tmux session's scratch file, and `agent send` delivers
# the text below the last marker line (three or more dashes) to the agent pane.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
agent="$repo_root/bin/agent"
real_tmux="$(command -v tmux)"
tmp="$(mktemp -d)"
socket="$tmp/tmux-socket"
cleanup_archive_root="${TMPDIR:-/tmp}/rm4agent-$UID/agent-compose-spec-$RANDOM-$BASHPID"

# The spec may itself run inside a tmux pane; the private server below must
# not look like a nested session to the tools under test.
unset TMUX TMUX_PANE

finish() {
  tmux -S "$socket" kill-server 2>/dev/null || true
  RM4AGENT_ROOT="$cleanup_archive_root" rm4agent -r "$tmp" >/dev/null
}
trap finish EXIT

trap 'printf "FAIL at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  printf 'roles: editor=%q shell=%q agent=%q\n' "${editor_pane:-}" "${shell_pane:-}" "${agent_pane:-}" >&2
  t list-panes -a -F 'pane=#{pane_id} role=#{@agent_compose_role} command=#{pane_current_command} dead=#{pane_dead} status=#{pane_dead_status}' >&2 || true
  t capture-pane -p -S - -t spec:.0 >&2 || true
  t capture-pane -p -S - -t spec:.+ >&2 || true
  exit 1
}

# -f /dev/null keeps the host configuration (base-index, default-command,
# remain-on-exit) out of the private server.
t() { tmux -S "$socket" -f /dev/null "$@"; }

# The editor split and the paste land asynchronously, so assertions poll.
wait_for() {
  local message="$1"
  shift
  for _ in {1..500}; do
    "$@" 2>/dev/null && return 0
    sleep 0.02
  done
  fail "timed out waiting for: $message"
}

mkdir -p \
  "$tmp/bin" "$tmp/home" "$tmp/session path's" "$tmp/delayed-session" "$tmp/work/launch" \
  "$tmp/agents" "$tmp/runtime"
session_dir="$(cd "$tmp/session path's" && pwd -P)"
launch_dir="$(cd "$tmp/work/launch" && pwd -P)"

# Record the exact submit key while delegating every operation to the private
# tmux server. An unmodified Enter is not equivalent to C-m for applications
# that negotiate extended keys.
mkdir -p "$tmp/send-bin"
cat > "$tmp/send-bin/tmux" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == send-keys ]]; then
  printf '%s\n' "\$*" >> "$tmp/send-keys.log"
fi
exec "$real_tmux" "\$@"
EOF
chmod +x "$tmp/send-bin/tmux"

# Stub harness: logs a per-launch mark so the spec can wait until a launcher
# run is past the editor-spawn decision, then stays alive like a real TUI.
cat > "$tmp/bin/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${AGENT_MARK:-}" >> "$tmp/codex.log"
sleep 300
EOF

# Stub editor: records the file it was opened on, then stays alive.
cat > "$tmp/bin/fake-editor" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$tmp/editor.log"
printf '%s\t%s\n' "\$1" "\$(stty size)" >> "$tmp/editor-size.log"
sleep 300
EOF

# Keep the sidecar launch independent of the host's deployed isolate-exec.
# This spec uses a private tmux server with no bound world.
cat > "$tmp/bin/isolate-exec" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

# The agent pane is respawned onto this recorder before send tests: the tty
# stays in canonical mode, so a line only lands in the log once a line
# terminator (a pasted newline or the submitting C-m) arrives.
cat > "$tmp/recorder" <<EOF
#!/usr/bin/env bash
while IFS= read -r line; do printf '%s\n' "\$line" >> "$tmp/received"; done
EOF

# Launcher wrapper: the checked-out script with the stub environment.
# AGENT_COMPOSE and AGENT_MARK come through per-window `env` prefixes.
cat > "$tmp/launch" <<EOF
#!/usr/bin/env bash
export PATH="$tmp/bin:\$PATH"
export HOME="$tmp/home"
export XDG_RUNTIME_DIR="$tmp/runtime"
export AGENT_BIN=codex
: "\${AGENT_COMPOSE=fake-editor}"
export AGENT_COMPOSE
export AGENT_MATRIX_TMUX_ENABLE=0
export AGENT_PROCESS_LABELER=
export AGENT_ENV_PATH="$tmp/missing-env"
export AGENT_CODEX_AUTO_TRUST_ROOT=
export AGENTSPATH="$tmp/agents"
export TMUX_AGENT_PANE_CENTER=0
exec "$agent"
EOF
chmod +x "$tmp/bin/codex" "$tmp/bin/fake-editor" "$tmp/bin/isolate-exec" \
  "$tmp/recorder" "$tmp/launch"

send() {
  PATH="$tmp/send-bin:$PATH" \
    TMUX="$socket,0,0" TMUX_PANE="$1" AGENT_COMPOSE_SETTLE_SECONDS=0.05 \
    "$agent" send "${@:2}"
}

# --- launch spawns the editor-and-shell sidecar beside the lone agent pane ---

PATH="$tmp/bin:$PATH" t new-session -d -s spec -x 200 -y 50 -c "$session_dir" \
  "cd '$launch_dir' && env AGENT_COMPOSE=fake-editor $tmp/launch"

three_panes() { [[ "$(t list-panes -t "${1:-spec}" | wc -l)" == 3 ]]; }
wait_for 'the editor and shell sidecar panes' three_panes spec

pane_by_role() {
  local role="$1" target="${2:-spec}"
  t list-panes -t "$target" -F $'#{pane_id}\t#{@agent_compose_role}' |
    awk -F '\t' -v role="$1" '$2 == role { print $1 }'
}
roles_ready() {
  editor_pane="$(pane_by_role editor)"
  shell_pane="$(pane_by_role shell)"
  agent_pane="$(pane_by_role '')"
  [[ -n "$editor_pane" && -n "$shell_pane" && -n "$agent_pane" ]]
}
# Pane creation precedes its role/target options; wait for both operations.
wait_for 'the compose pane roles' roles_ready
[[ "$(t show-options -pqv -t "$editor_pane" @agent_compose_target)" == "$agent_pane" ]] ||
  fail 'the editor pane does not point at the agent pane'
[[ "$(t show-options -pqv -t "$shell_pane" @agent_compose_target)" == "$agent_pane" ]] ||
  fail 'the shell pane does not point at the agent pane'
draft="$(t show-options -pqv -t "$editor_pane" @agent_compose_draft)"
[[ "$draft" == "$session_dir/.agent-compose-send" ]] ||
  fail "the draft is not based in the tmux session directory: $draft"
[[ -f "$draft" ]] || fail "the draft file is missing: $draft"
[[ "$(t show-options -pqv -t "$shell_pane" @agent_compose_draft)" == "$draft" ]] ||
  fail 'the shell pane does not carry the draft path'
wait_for 'the editor opened on the draft' grep -qx -- "$draft" "$tmp/editor.log"
for pane in "$editor_pane" "$shell_pane"; do
  [[ "$(t display-message -p -t "$pane" '#{pane_current_path}')" == "$session_dir" ]] ||
    fail "pane $pane did not start in the tmux session directory"
done
# The editor sits above the shell in the right column.
[[ "$(t display-message -p -t "$editor_pane" '#{pane_top}')" -lt \
   "$(t display-message -p -t "$shell_pane" '#{pane_top}')" ]] ||
  fail 'the editor pane is not above the shell pane'
[[ "$(t display-message -p -t spec '#{pane_id}')" == "$agent_pane" ]] ||
  fail 'the split moved the focus off the agent pane'
editor_size="$(awk -F '\t' -v draft="$draft" '$1 == draft { print $2; exit }' "$tmp/editor-size.log")"
expected_editor_size="$(t display-message -p -t "$editor_pane" '#{pane_height} #{pane_width}')"
[[ "$editor_size" == "$expected_editor_size" ]] ||
  fail "the editor started at $editor_size before its final $expected_editor_size layout"

# A detached session begins at tmux's default 80x24 size. The editor must wait
# for the client-driven resize instead of starting against that placeholder.
delayed_dir="$(cd "$tmp/delayed-session" && pwd -P)"
PATH="$tmp/bin:$PATH" t new-session -d -s delayed -c "$delayed_dir" \
  "env AGENT_COMPOSE=fake-editor $tmp/launch"
wait_for 'the delayed editor and shell sidecar panes' three_panes delayed
delayed_editor_pane="$(pane_by_role editor delayed)"
delayed_draft="$(t show-options -pqv -t "$delayed_editor_pane" @agent_compose_draft)"
sleep 0.2
grep -qx -- "$delayed_draft" "$tmp/editor.log" 2>/dev/null &&
  fail 'the editor started at the detached session default size'
t resize-window -t delayed -x 160 -y 40
wait_for 'the editor after its window resize' grep -qx -- "$delayed_draft" "$tmp/editor.log"
delayed_editor_size="$(
  awk -F '\t' -v draft="$delayed_draft" '$1 == draft { print $2; exit }' "$tmp/editor-size.log"
)"
expected_delayed_size="$(
  t display-message -p -t "$delayed_editor_pane" '#{pane_height} #{pane_width}'
)"
[[ "$delayed_editor_size" == "$expected_delayed_size" ]] ||
  fail "the delayed editor started at $delayed_editor_size, expected $expected_delayed_size"

# --- send delivers only the text below the last marker -----------------------

t respawn-pane -k -t "$agent_pane" "$tmp/recorder"
printf 'private notes\n---\nolder draft\n----\nline one\nline two\n' > "$draft"
send "$editor_pane" "$draft"
wait_for 'the payload below the last marker' grep -qx 'line two' "$tmp/received"
grep -qx 'line one' "$tmp/received" || fail 'the first payload line is missing'
grep -q 'private notes' "$tmp/received" && fail 'notes above the marker were sent'
grep -q 'older draft' "$tmp/received" && fail 'text above the last marker was sent'
[[ "$(tail -n 1 "$tmp/send-keys.log")" == "send-keys -t $agent_pane Enter" ]] ||
  fail 'send did not submit with an unmodified Enter'

# --- a draft with no marker sends whole --------------------------------------

: > "$tmp/received"
printf 'solo line A\nsolo line B\n' > "$draft"
send "$editor_pane" "$draft"
wait_for 'the whole markerless draft' grep -qx 'solo line B' "$tmp/received"
grep -qx 'solo line A' "$tmp/received" || fail 'the markerless draft was cut'

# --- only blanks below the marker: refuse, paste nothing ---------------------

: > "$tmp/received"
printf 'notes\n---\n\n   \n' > "$draft"
send "$editor_pane" "$draft" 2>/dev/null && fail 'an empty payload was accepted'
sleep 0.2
[[ ! -s "$tmp/received" ]] || fail 'an empty payload still pasted something'

# --- send with no argument resolves the draft from the shell pane's option ---

: > "$tmp/received"
printf -- '---\nfrom pane option\n' > "$draft"
send "$shell_pane"
wait_for 'the draft named by the pane option' \
  grep -qx 'from pane option' "$tmp/received"

# --- a pane without options falls back to the marked agent pane --------------

: > "$tmp/received"
t set-option -p -t "$agent_pane" @agent_center_role agent
helper_pane="$(t split-window -v -d -t spec: -P -F '#{pane_id}' 'sleep 300')"
printf -- '---\nvia role fallback\n' > "$draft"
send "$helper_pane" "$draft"
wait_for 'the payload through the role fallback' \
  grep -qx 'via role fallback' "$tmp/received"
t kill-pane -t "$helper_pane"

# --- a window with company spawns no editor ----------------------------------

busy_pane="$(t new-window -d -t spec -n busy -P -F '#{pane_id}' 'sleep 300')"
t split-window -d -t "$busy_pane" 'sleep 300'
t respawn-pane -k -t "$busy_pane" "env AGENT_MARK=busy $tmp/launch"
wait_for 'the harness in the busy window' grep -qx busy "$tmp/codex.log"
[[ "$(t list-panes -t "$busy_pane" | wc -l)" == 2 ]] ||
  fail 'a second pane did not stop the editor spawn'

# --- spacer panes do not count as company ------------------------------------

spaced_pane="$(t new-window -d -t spec -n spaced -P -F '#{pane_id}' 'sleep 300')"
for _ in 1 2; do
  spacer="$(t split-window -h -d -t "$spaced_pane" -P -F '#{pane_id}' 'sleep 300')"
  t set-option -p -t "$spacer" @agent_center_role spacer
done
t respawn-pane -k -t "$spaced_pane" \
  "env AGENT_MARK=spaced AGENT_COMPOSE=fake-editor $tmp/launch"
spaced_has_sidecar() { [[ "$(t list-panes -t "$spaced_pane" | wc -l)" == 5 ]]; }
wait_for 'the sidecar beside a spacer-padded agent' spaced_has_sidecar

# World adoption and pane restarts can replace a pane's one-shot environment.
# The durable start command must still reopen the draft without relying on it.
t respawn-pane -k -c "$session_dir" -e 'AGENT_COMPOSE_DRAFT=' -t "$editor_pane"
editor_reopened_draft() {
  [[ "$(tail -n 1 "$tmp/editor.log" 2>/dev/null)" == "$draft" ]]
}
wait_for 'the respawned editor reopened the draft' editor_reopened_draft

# --- AGENT_COMPOSE off spawns nothing ----------------------------------------

off_pane="$(t new-window -d -t spec -n off -P -F '#{pane_id}' \
  "env AGENT_MARK=off AGENT_COMPOSE=0 $tmp/launch")"
wait_for 'the harness with the editor off' grep -qx off "$tmp/codex.log"
[[ "$(t list-panes -t "$off_pane" | wc -l)" == 1 ]] ||
  fail 'AGENT_COMPOSE=0 still spawned an editor pane'

# The compose-only minor mode must win over Markdown's M-RET binding without
# changing M-RET in ordinary Markdown buffers.
emacs --batch -Q -l "$repo_root/spec/agent-compose/emacs-test.el"

echo PASS
