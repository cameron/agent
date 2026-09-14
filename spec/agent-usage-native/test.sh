#!/usr/bin/env bash
set -euo pipefail
trap 'printf "FAIL: line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PYTHONDONTWRITEBYTECODE=1 python3 "$repo_root/spec/agent-usage-native/test.py" "$repo_root"
