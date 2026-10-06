#!/usr/bin/env bash
#
# test-config.sh — smoke test for the SAIA config-write logic.
#
# Runs src/add-saia-openhands.sh against a throwaway OPENHANDS_DATA_DIR and
# checks the resulting agent_settings.json. Zero real SAIA requests, zero
# OpenHands installs. Not packed into the installer.
#
# The last cases check the automatic key swap against test/fake-saia.py: with
# two keys, the first one revoked, OpenHands is pointed at the local
# saia-keyring proxy and a request through it fails over to the second key.
# HOME is a throwaway dir and SAIA_KEYRING_SERVICE=none, so the real keyring
# config, systemd user manager and shell rc are never touched.
#
set -euo pipefail
unset SAIA_API_KEY SAIA_API_KEYS_EXTRA   # caller's keys would mask the reuse checks
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMP="$(mktemp -d)"
export HOME="$TMP/home"
export SAIA_KEYRING_SERVICE=none
mkdir -p "$HOME"

cleanup() {
  [[ -n "${FAKE_PID:-}" ]] && kill "$FAKE_PID" 2>/dev/null || true
  if [[ -n "${KR_PORT:-}" ]]; then
    curl -s "http://127.0.0.1:$KR_PORT/_keyring/health" \
      | python3 -c 'import json,os,sys; os.kill(json.load(sys.stdin)["pid"], 15)' 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Fresh write via env key
OPENHANDS_DATA_DIR="$TMP/a" SAIA_API_KEY="key-1" ./src/add-saia-openhands.sh >/dev/null 2>&1
python3 - "$TMP/a/agent_settings.json" <<'PY' || fail "fresh write"
import json, sys
d = json.load(open(sys.argv[1]))["llm"]
assert d["model"] == "openai/deepseek-v4-flash-0731", d
assert d["api_key"] == "key-1", d
assert d["base_url"] == "https://chat-ai.academiccloud.de/v1", d
assert "custom_llm_provider" not in d, d
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

# SAIA_BASE_URL override (used by the benchmark's local gateway)
OPENHANDS_DATA_DIR="$TMP/ov" SAIA_BASE_URL="http://127.0.0.1:9/v1" SAIA_API_KEY="key-5" \
  ./src/add-saia-openhands.sh >/dev/null 2>&1 || fail "installer failed with SAIA_BASE_URL set"
python3 - "$TMP/ov/agent_settings.json" <<'PY' || fail "SAIA_BASE_URL override"
import json, sys
assert json.load(open(sys.argv[1]))["llm"]["base_url"] == "http://127.0.0.1:9/v1"
PY
echo "PASS: SAIA_BASE_URL override"

# Extra keys without --keyring: SAIA directly, no proxy (opt-in only)
OPENHANDS_DATA_DIR="$TMP/nk" SAIA_API_KEYS_EXTRA=extra-key SAIA_API_KEY="key-6" \
  ./src/add-saia-openhands.sh >"$TMP/nk.log" 2>&1 || fail "installer failed with extra keys but no --keyring"
python3 - "$TMP/nk/agent_settings.json" <<'PY' || fail "extra keys alone pointed OpenHands away from SAIA"
import json, sys
assert json.load(open(sys.argv[1]))["llm"]["base_url"] == "https://chat-ai.academiccloud.de/v1"
PY
[[ ! -e "$HOME/.config/saia-keyring" ]] || fail "keyring set up without --keyring"
grep -q "opt-in (add --keyring)" "$TMP/nk.log" || fail "no note about the unused extra keys"
echo "PASS: extra keys without --keyring: direct to SAIA, no proxy"

# 6. Automatic key swap: two keys, the first one revoked
FAKE_DEAD_KEYS=dead-key SEEN_FILE="$TMP/seen" COUNT_FILE="$TMP/count" \
  python3 test/fake-saia.py >"$TMP/port" 2>"$TMP/fake.log" &
FAKE_PID=$!
for _ in $(seq 40); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
PORT="$(cat "$TMP/port")"
[[ -n "$PORT" ]] || fail "fake-saia did not start"
KR_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
OPENHANDS_DATA_DIR="$TMP/kr" SAIA_KEYRING_PORT="$KR_PORT" SAIA_BASE_URL="http://127.0.0.1:$PORT/v1" \
  SAIA_API_KEY=dead-key ./src/add-saia-openhands.sh --keyring --extra-keys good-key >"$TMP/kr.log" 2>&1 \
  || { cat "$TMP/kr.log" >&2; fail "installer failed with --keyring"; }
KR_PORT="$KR_PORT" python3 - "$TMP/kr/agent_settings.json" <<'PY' || { cat "$TMP/kr.log" >&2; fail "keyring base_url"; }
import json, os, sys
d = json.load(open(sys.argv[1]))["llm"]
assert d["base_url"] == f"http://127.0.0.1:{os.environ['KR_PORT']}/v1", d
assert d["api_key"] == "dead-key", d
PY
[[ "$(stat -c '%a' "$HOME/.config/saia-keyring/keyring.json")" == "600" ]] || fail "keyring.json not 600"
: >"$TMP/seen"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer dead-key" \
  "http://127.0.0.1:$KR_PORT/v1/models")"
[[ "$CODE" == 200 ]] || fail "request through the keyring proxy returned $CODE"
[[ "$(paste -sd, "$TMP/seen")" == "dead-key,good-key" ]] \
  || fail "proxy did not fail over from the revoked key (saw: $(paste -sd, "$TMP/seen"))"
echo "PASS: automatic key swap (revoked key -> next key through the local proxy)"

# 7. Re-run with no key reuses the key from a proxy-pointed config
OPENHANDS_DATA_DIR="$TMP/kr" SAIA_KEYRING_PORT="$KR_PORT" SAIA_BASE_URL="http://127.0.0.1:$PORT/v1" \
  ./src/add-saia-openhands.sh --keyring </dev/null >"$TMP/kr2.log" 2>&1 \
  || { cat "$TMP/kr2.log" >&2; fail "re-run with the keyring failed"; }
KR_PORT="$KR_PORT" python3 - "$TMP/kr/agent_settings.json" "$HOME/.config/saia-keyring/keyring.json" <<'PY' \
  || { cat "$TMP/kr2.log" >&2; fail "reuse through the proxy"; }
import json, os, sys
d = json.load(open(sys.argv[1]))["llm"]
assert d["api_key"] == "dead-key", d
assert d["base_url"] == f"http://127.0.0.1:{os.environ['KR_PORT']}/v1", d
assert json.load(open(sys.argv[2]))["keys"] == ["dead-key", "good-key"], "extras not kept"
PY
echo "PASS: re-run reuses the key and extras of a keyring install"

echo ""
echo "All tests passed."
