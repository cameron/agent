#!/usr/bin/env bash

# Exercise the agent.template renderer and its seam with the agent launcher.
#
# The Nix selection only evaluates derivations, so buildGoModule's check phase
# does not run on a merge. The unit tests run from here, followed by the
# command-line behaviour of the built binary and one end-to-end pass through
# `agent --print-instructions` with the real renderer on PATH.

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_directory="$repo_root/agent-template/src"
agent="$repo_root/bin/agent"
tmp="$(mktemp -d)"
archive_root="${TMPDIR:-/tmp}/rm4agent-$UID"
trap 'RM4AGENT_ROOT="$archive_root" rm4agent -r "$tmp" >/dev/null 2>&1 || true' EXIT
trap 'printf "FAIL: line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_equal() {
  local label="$1" got="$2" want="$3"

  [[ "$got" == "$want" ]] || fail "$label: got '$got', want '$want'"
}

command -v go >/dev/null || fail 'go is not available'

unformatted="$(cd "$source_directory" && gofmt -l .)"
[[ -z "$unformatted" ]] || fail "gofmt reports: $unformatted"

# Keep the build hermetic: no module downloads, and caches inside the sandbox.
export GOFLAGS=-mod=mod
export GOPATH="$tmp/gopath"
export GOCACHE="$tmp/gocache"
export GOMODCACHE="$tmp/gomodcache"

(
  cd "$source_directory"
  go vet ./... || fail 'go vet reported problems'
  go test ./... || fail 'the agent-template unit tests failed'
  go build -o "$tmp/bin/agent.template" . || fail 'agent.template did not build'
)

render="$tmp/bin/agent.template"
mkdir -p "$tmp/work"

# A file with no actions is a valid template and passes through unchanged.
printf 'plain text\nsecond line\n' > "$tmp/work/plain.md.tmpl"
expect_equal 'plain passthrough' \
  "$("$render" "$tmp/work/plain.md.tmpl")" \
  "$(printf 'plain text\nsecond line')"

# A parameter reads its environment variable, and falls back when the variable
# is unset or empty.
printf 'density {{param "AGENT_SPEECH_INFO_DENSITY" "100"}}%%' \
  > "$tmp/work/density.md.tmpl"
expect_equal 'parameter set' \
  "$(AGENT_SPEECH_INFO_DENSITY=25 "$render" "$tmp/work/density.md.tmpl")" \
  'density 25%'
expect_equal 'parameter unset' \
  "$(env -u AGENT_SPEECH_INFO_DENSITY "$render" "$tmp/work/density.md.tmpl")" \
  'density 100%'
expect_equal 'parameter empty' \
  "$(AGENT_SPEECH_INFO_DENSITY= "$render" "$tmp/work/density.md.tmpl")" \
  'density 100%'

# A parameter cannot name a variable outside the AGENT_ prefix, so an
# instruction file cannot carry a credential into a prompt.
printf '{{param "SECRET_TOKEN" ""}}' > "$tmp/work/leak.md.tmpl"
if SECRET_TOKEN=hunter2 "$render" "$tmp/work/leak.md.tmpl" > "$tmp/leak.out" 2>"$tmp/leak.err"; then
  fail 'the renderer accepted a parameter outside the AGENT_ prefix'
fi
grep -q hunter2 "$tmp/leak.out" "$tmp/leak.err" &&
  fail 'the renderer leaked the value of a rejected parameter'

# Facts come from the launcher; an unknown fact name is an error rather than
# silence rendered into a prompt.
printf '{{fact "harness"}} in {{fact "worktree"}}' > "$tmp/work/facts.md.tmpl"
expect_equal 'supplied fact' \
  "$("$render" -fact harness=claude -fact worktree=/srv/wt "$tmp/work/facts.md.tmpl")" \
  'claude in /srv/wt'
expect_equal 'unsupplied fact renders empty' \
  "$("$render" -fact harness=codex "$tmp/work/facts.md.tmpl")" \
  'codex in '

printf '{{fact "harnes"}}' > "$tmp/work/typo.md.tmpl"
"$render" "$tmp/work/typo.md.tmpl" >/dev/null 2>&1 &&
  fail 'the renderer accepted an unknown fact name'

# The file name appears in a render error so a broken drop-in is findable.
printf '{{param "AGENT_X"' > "$tmp/work/broken.md.tmpl"
"$render" "$tmp/work/broken.md.tmpl" >"$tmp/broken.out" 2>"$tmp/broken.err" &&
  fail 'the renderer accepted an unterminated action'
grep -q 'broken.md.tmpl' "$tmp/broken.err" ||
  fail 'the render error does not name the file'

# A wrong command line is status 2; a bad file or template is status 1.
status=0
"$render" >/dev/null 2>&1 || status=$?
expect_equal 'no operand status' "$status" 2
status=0
"$render" -fact hostname=forge "$tmp/work/plain.md.tmpl" >/dev/null 2>&1 || status=$?
expect_equal 'unknown fact flag status' "$status" 2
status=0
"$render" "$tmp/work/absent.md.tmpl" >/dev/null 2>&1 || status=$?
expect_equal 'missing file status' "$status" 1

# End to end: the launcher renders a template scope with the real binary.
mkdir -p "$tmp/etc/AGENTS.md.d" "$tmp/repo"
printf 'density {{param "AGENT_SPEECH_INFO_DENSITY" "100"}}%% under {{fact "harness"}}\n' \
  > "$tmp/etc/AGENTS.md.tmpl"
printf 'roles [{{fact "roles"}}]\n' > "$tmp/etc/AGENTS.md.d/50-roles.md.tmpl"
git -C "$tmp/repo" init -q

output="$(
  cd "$tmp/repo"
  PATH="$tmp/bin:$PATH" \
    AGENT_WORKTREE_MODE=here \
    AGENT_SPEECH_INFO_DENSITY=40 \
    AGENTSPATH="$tmp/etc" \
    "$agent" claude --print-instructions
)"
expect_equal 'end to end' "$output" "$(printf 'density 40%% under claude\n\nroles []')"

printf 'PASS\n'
