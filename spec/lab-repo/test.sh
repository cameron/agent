#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
catalog="$repo_root/bin/lab.repo"
tmp="$(mktemp -d)"
cleanup_root="${TMPDIR:-/tmp}/rm4agent-lab-repo-$UID-$BASHPID"
trap 'RM4AGENT_ROOT="$cleanup_root" rm4agent -r "$tmp" >/dev/null' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$tmp/src/alpha" "$tmp/src/beta" "$tmp/src/gamma" \
  "$tmp/src/delta" "$tmp/src/not-a-repo"
git -C "$tmp/src/alpha" init -q
git -C "$tmp/src/beta" init -q
git -C "$tmp/src/gamma" init -q
git -C "$tmp/src/delta" init -q
printf 'GPU model lifecycle tools\nsecond line is ignored\n' \
  >"$tmp/src/alpha/.repo-description"
cat >"$tmp/src/alpha/flake.nix" <<'EOF'
{
  description = "lower-priority flake description";
}
EOF
cat >"$tmp/src/beta/flake.nix" <<'EOF'
{
  description = "Repair boot state from rescue systems";
}
EOF
printf 'gamma\tLegacy lab fixture\n' >"$tmp/catalog.tsv"

expected=$'REPOSITORY\tDESCRIPTION\nalpha\tGPU model lifecycle tools\nbeta\tRepair boot state from rescue systems\ndelta\t[description needed]\ngamma\tLegacy lab fixture'
actual="$(LAB_REPO_ROOT="$tmp/src" LAB_REPO_CATALOG="$tmp/catalog.tsv" \
  "$catalog" 2>"$tmp/warning")"
[[ "$actual" == "$expected" ]] ||
  fail "unexpected catalog: $actual"
[[ "$(<"$tmp/warning")" == \
  'lab.repo: description needed for: delta' ]] ||
  fail 'the missing description was not reported'

expected=$'REPOSITORY\tDESCRIPTION\nalpha\tGPU model lifecycle tools'
actual="$(LAB_REPO_ROOT="$tmp/src" LAB_REPO_CATALOG="$tmp/catalog.tsv" \
  "$catalog" gpu MODEL 2>/dev/null)"
[[ "$actual" == "$expected" ]] ||
  fail 'description search did not select alpha'

expected=$'REPOSITORY\tDESCRIPTION\nbeta\tRepair boot state from rescue systems'
actual="$(LAB_REPO_ROOT="$tmp/src" LAB_REPO_CATALOG="$tmp/catalog.tsv" \
  "$catalog" BETA 2>/dev/null)"
[[ "$actual" == "$expected" ]] ||
  fail 'name search did not select the repository with a flake description'

if LAB_REPO_ROOT="$tmp/src" LAB_REPO_CATALOG="$tmp/catalog.tsv" \
  "$catalog" --check >"$tmp/check.stdout" 2>"$tmp/check.stderr"; then
  fail '--check accepted a repository without a description'
fi
[[ "$(<"$tmp/check.stderr")" == \
  'lab.repo: description needed for: delta' ]] ||
  fail '--check did not identify the missing repository'

printf 'delta\tDescription audit fixture\n' >>"$tmp/catalog.tsv"
LAB_REPO_ROOT="$tmp/src" LAB_REPO_CATALOG="$tmp/catalog.tsv" \
  "$catalog" --check >/dev/null 2>"$tmp/complete.stderr" ||
  fail '--check rejected complete description coverage'
[[ ! -s "$tmp/complete.stderr" ]] ||
  fail '--check warned after every repository had a description'

mkdir -p "$tmp/src/kindle-alexandrias-archive"
git -C "$tmp/src/kindle-alexandrias-archive" init -q
printf 'Sync purchased books\n' \
  >"$tmp/src/kindle-alexandrias-archive/.repo-description"

expected=$'REPOSITORY\tDESCRIPTION\nkindle-alexandrias-archive\tSync purchased books'
actual="$(LAB_REPO_ROOT="$tmp/src" LAB_REPO_CATALOG="$tmp/catalog.tsv" \
  "$catalog" kindle alexandrias archive 2>/dev/null)"
[[ "$actual" == "$expected" ]] ||
  fail "space-separated name tokens did not match a hyphenated name: $actual"

expected=$'REPOSITORY\tDESCRIPTION\nalpha\tGPU model lifecycle tools'
actual="$(LAB_REPO_ROOT="$tmp/src" LAB_REPO_CATALOG="$tmp/catalog.tsv" \
  "$catalog" alpha LIFECYCLE 2>/dev/null)"
[[ "$actual" == "$expected" ]] ||
  fail "tokens spanning name and description did not select alpha: $actual"

actual="$(LAB_REPO_ROOT="$tmp/src" LAB_REPO_CATALOG="$tmp/catalog.tsv" \
  "$catalog" rescue lifecycle 2>"$tmp/nomatch.stderr")"
[[ "$actual" == $'REPOSITORY\tDESCRIPTION' ]] ||
  fail "tokens from different repositories matched one: $actual"
[[ "$(<"$tmp/nomatch.stderr")" == \
  'lab.repo: no repository matched: rescue lifecycle' ]] ||
  fail 'an empty filtered listing was not diagnosed on stderr'

printf 'PASS: lab.repo resolves, audits, and filters repository descriptions\n'
