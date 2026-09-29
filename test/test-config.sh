#!/usr/bin/env bash
#
# test-config.sh — smoke test for the SAIA config-write logic.
#
# Runs src/add-saia-openhands.sh against a throwaway OPENHANDS_DATA_DIR and
# checks the resulting agent_settings.json. Zero real SAIA requests, zero
# OpenHands installs. Not packed into the installer.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Fresh write via env key
OPENHANDS_DATA_DIR="$TMP/a" SAIA_API_KEY="key-1" ./src/add-saia-openhands.sh >/dev/null 2>&1
python3 - "$TMP/a/agent_settings.json" <<'PY' || fail "fresh write"
import json, sys
d = json.load(open(sys.argv[1]))["llm"]
assert d["model"] == "deepseek-v4-flash-0731", d
assert d["api_key"] == "key-1", d
assert d["base_url"] == "https://chat-ai.academiccloud.de/v1", d
assert d["custom_llm_provider"] == "openai", d
PY
[[ "$(stat -c '%a' "$TMP/a/agent_settings.json")" == "600" ]] || fail "perms not 600"
echo "PASS: fresh write (env key, perms 600)"

# 2. Re-run reuses the key (no env)
OPENHANDS_DATA_DIR="$TMP/a" ./src/add-saia-openhands.sh >/dev/null 2>&1
python3 - "$TMP/a/agent_settings.json" <<'PY' || fail "reuse"
import json, sys
assert json.load(open(sys.argv[1]))["llm"]["api_key"] == "key-1"
PY
echo "PASS: re-run reuses key"

# 3. --key-file (opencode auth.json format)
printf '{"saia-gwdg": {"type": "api", "key": "key-2"}}\n' > "$TMP/auth.json"
OPENHANDS_DATA_DIR="$TMP/b" ./src/add-saia-openhands.sh --key-file "$TMP/auth.json" >/dev/null 2>&1
python3 - "$TMP/b/agent_settings.json" <<'PY' || fail "key-file"
import json, sys
assert json.load(open(sys.argv[1]))["llm"]["api_key"] == "key-2"
PY
echo "PASS: --key-file (opencode auth.json)"

# 4. Merge preserves unrelated sections
mkdir -p "$TMP/c"
printf '{"core":{"debug":true},"llm":{"model":"old","api_key":"old","base_url":"https://chat-ai.academiccloud.de/v1"}}\n' > "$TMP/c/agent_settings.json"
OPENHANDS_DATA_DIR="$TMP/c" SAIA_API_KEY="key-3" ./src/add-saia-openhands.sh >/dev/null 2>&1
python3 - "$TMP/c/agent_settings.json" <<'PY' || fail "merge"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["core"]["debug"] is True, d
assert d["llm"]["api_key"] == "key-3", d
PY
echo "PASS: merge preserves unrelated sections"

# 5. --force-key replaces an existing key
OPENHANDS_DATA_DIR="$TMP/c" SAIA_API_KEY="key-4" ./src/add-saia-openhands.sh --force-key >/dev/null 2>&1
python3 - "$TMP/c/agent_settings.json" <<'PY' || fail "force-key"
import json, sys
assert json.load(open(sys.argv[1]))["llm"]["api_key"] == "key-4"
PY
echo "PASS: --force-key replaces key"

echo ""
echo "All tests passed."
