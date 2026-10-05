#!/usr/bin/env bash
set -euo pipefail

# add-saia-openhands.sh — Add GWDG SAIA provider to OpenHands CLI
#
# Reads SAIA API key from environment variable SAIA_API_KEY or --key/--key-file.
# Writes ~/.openhands/agent_settings.json with an `llm` block pointing at the
# GWDG SAIA OpenAI-compatible API.
#
# With extra keys (SAIA_API_KEYS_EXTRA / --extra-keys / --extra-keys-file)
# OpenHands is pointed at the local saia-keyring proxy instead, which swaps to
# the next key when the active one is revoked, drained or rate limited
# (saia-keyring.sh).
#
# Usage:
#   SAIA_API_KEY="your-key" ./add-saia-openhands.sh
#   ./add-saia-openhands.sh --key "your-key"
#   ./add-saia-openhands.sh --key-file ~/.local/share/opencode/auth.json
#   SAIA_API_KEYS_EXTRA="key2,key3" ./add-saia-openhands.sh --key "your-key"
#
# Note: OpenHands stores the API key in plaintext in agent_settings.json
# (chmod 600). The key is written regardless of --api-key-env, matching how
# OpenHands reads its config.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_FILE="${SCRIPT_DIR}/models.txt"
DATA_DIR="${OPENHANDS_DATA_DIR:-$HOME/.openhands}"
CONFIG_FILE="$DATA_DIR/agent_settings.json"
DEFAULT_MODEL="${SAIA_DEFAULT_MODEL:-deepseek-v4-flash-0731}"
# Base URL override for tests and local gateways (default: production SAIA).
SAIA_BASE_URL="${SAIA_BASE_URL:-https://chat-ai.academiccloud.de/v1}"
FORCE_KEY=0
# shellcheck source=saia-keyring.sh
source "${SCRIPT_DIR}/saia-keyring.sh"

# ── Parse arguments ──────────────────────────────────────────────────
KEY=""
KEY_FILE=""
SAIA_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)
      KEY="$2"
      shift 2
      ;;
    --key-file)
      KEY_FILE="$2"
      shift 2
      ;;
    --force-key)
      FORCE_KEY=1
      shift
      ;;
    --extra-keys|--extra-keys-file|--keyring|--no-keyring)
      keyring_arg "$@"
      shift "$KEYRING_SHIFT"
      ;;
    -h|--help)
      echo "Usage: SAIA_API_KEY=... ./add-saia-openhands.sh [--key <key> | --key-file <path>] [--force-key]"
      echo ""
      echo "Options:"
      echo "  --key <value>       SAIA API key (overrides SAIA_API_KEY env)"
      echo "  --key-file <path>   File containing the SAIA API key"
      echo "  --force-key         Replace an existing SAIA key in the config"
      keyring_usage
      echo "  -h, --help          Show this help"
      echo ""
      echo "The API key is taken from:"
      echo "  1. --key <value> argument (if provided)"
      echo "  2. SAIA_API_KEY environment variable (if set)"
      echo "  3. --key-file <path> (reads first line)"
      echo "  4. the key stored by a previous install, if any"
      echo "  5. an interactive prompt, if none of the above is set"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Pull the key out of a previous install so a reinstall does not ask again.
# Scoped to the llm block that points at SAIA — directly, or through the local
# saia-keyring proxy — so a config that uses a different provider is left alone.
key_from_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  KR_CONFIG="$KEYRING_CONFIG" python3 - "$CONFIG_FILE" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
try:
    with open(path) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
try:
    port = int(json.load(open(os.environ["KR_CONFIG"])).get("port") or 8788)
except Exception:
    port = 8788
llm = data.get("llm", {})
base = llm.get("base_url", "") if isinstance(llm, dict) else ""
if base.startswith("https://chat-ai.academiccloud.de") or base.rstrip("/") == f"http://127.0.0.1:{port}/v1":
    print(llm.get("api_key", ""))
PYEOF
  return 0
}

prompt_for_key() {
  if ! { : </dev/tty; } 2>/dev/null; then   # -r only stats; this actually opens it
    echo "ERROR: No SAIA API key given and no terminal to ask on." >&2
    echo "Set it: SAIA_API_KEY=\"your-key\" ./add-saia-openhands.sh" >&2
    echo "Get one at https://chat-ai.academiccloud.de/" >&2
    exit 1
  fi
  local key=""
  for _ in 1 2 3; do
    read -rsp "GWDG SAIA API key (input hidden): " key </dev/tty
    echo >&2
    key="${key//[[:space:]]/}"   # paste hygiene; SAIA keys carry no whitespace
    if [[ -n "$key" ]]; then
      export SAIA_API_KEY="$key"
      return
    fi
    echo "Key cannot be empty." >&2
  done
  echo "ERROR: no key entered." >&2
  exit 1
}

# ── Obtain API key ───────────────────────────────────────────────────
if [[ -n "$KEY" ]]; then
  SAIA_KEY="$KEY"
elif [[ -n "${SAIA_API_KEY:-}" ]]; then
  SAIA_KEY="$SAIA_API_KEY"
elif [[ -n "$KEY_FILE" ]]; then
  if [[ ! -f "$KEY_FILE" ]]; then
    echo "ERROR: Key file not found: $KEY_FILE" >&2
    exit 1
  fi
  # Try to read as JSON (opencode auth.json format)
  if command -v python3 &>/dev/null; then
    SAIA_KEY=$(python3 -c "import json; d=json.load(open('$KEY_FILE')); print(d.get('saia-gwdg',{}).get('key',''))" 2>/dev/null || echo "")
  fi
  # Fallback: read first line
  if [[ -z "$SAIA_KEY" ]]; then
    SAIA_KEY=$(head -n 1 "$KEY_FILE" 2>/dev/null || echo "")
  fi
else
  SAIA_KEY="$(key_from_config)"
  if [[ -n "$SAIA_KEY" ]]; then
    echo "Reusing the SAIA key already in your OpenHands config (pass --key to replace it)."
  else
    prompt_for_key
    SAIA_KEY="$SAIA_API_KEY"
  fi
fi

if [[ -z "$SAIA_KEY" ]]; then
  echo "ERROR: SAIA_API_KEY is empty." >&2
  exit 1
fi

# ── Load models ──────────────────────────────────────────────────────
if [[ ! -f "$MODELS_FILE" ]]; then
  echo "ERROR: Models file not found: $MODELS_FILE" >&2
  exit 1
fi

MODELS=()
while IFS= read -r model || [[ -n "$model" ]]; do
  [[ -z "$model" || "$model" =~ ^# ]] && continue
  MODELS+=("$model")
done < "$MODELS_FILE"

if [[ ${#MODELS[@]} -eq 0 ]]; then
  echo "ERROR: No models found in $MODELS_FILE" >&2
  exit 1
fi

if ! printf '%s\n' "${MODELS[@]}" | grep -qxF "$DEFAULT_MODEL"; then
  echo "ERROR: default model '$DEFAULT_MODEL' not in $MODELS_FILE" >&2
  exit 1
fi

# ── Write the config ─────────────────────────────────────────────────
mkdir -p "$DATA_DIR"

# If the config already points at SAIA and --force-key is not given, keep the
# existing key (unless one was explicitly supplied above).
if [[ -f "$CONFIG_FILE" ]] && [[ $FORCE_KEY -eq 0 ]] && [[ -z "$KEY" && -z "${SAIA_API_KEY:-}" && -z "$KEY_FILE" ]]; then
  existing="$(key_from_config)"
  if [[ -n "$existing" ]]; then
    SAIA_KEY="$existing"
    echo "Keeping the SAIA key already in $CONFIG_FILE (pass --force-key to replace it)."
  fi
fi

# ── Automatic key swap (2+ keys) ─────────────────────────────────────
# Sets SAIA_EFFECTIVE_BASE_URL: the local proxy when it is up, else SAIA itself.
keyring_setup "$SAIA_KEY"

echo "Writing GWDG SAIA provider to OpenHands config..."
echo "Config file: $CONFIG_FILE"
echo "Base URL: $SAIA_EFFECTIVE_BASE_URL"
echo "Default model: $DEFAULT_MODEL"
echo "Models available: ${#MODELS[@]}"

SAIA_CONFIG="$CONFIG_FILE" SAIA_KEY="$SAIA_KEY" SAIA_BASE="$SAIA_EFFECTIVE_BASE_URL" \
SAIA_DEFAULT="$DEFAULT_MODEL" SAIA_MODELS="$(printf '%s\n' "${MODELS[@]}")" \
python3 <<'PYEOF'
import json, os

path = os.environ["SAIA_CONFIG"]
key = os.environ["SAIA_KEY"]
base = os.environ["SAIA_BASE"]
default = os.environ["SAIA_DEFAULT"]
models = [m for m in os.environ["SAIA_MODELS"].splitlines() if m]

try:
    with open(path) as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}

llm = data.get("llm", {})
if not isinstance(llm, dict):
    llm = {}

# OpenHands CLI passes the model string straight to litellm, which needs the
# provider encoded in the model name (it ignores a separate provider field).
# Prefix with "openai/" so litellm routes to the OpenAI-compatible base_url.
llm["model"] = f"openai/{default}"
llm["api_key"] = key
llm["base_url"] = base
llm["drop_params"] = True

data["llm"] = llm

tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
os.chmod(path, 0o600)
PYEOF

echo ""
echo "✓ GWDG SAIA provider installed successfully!"
echo "  Config: $CONFIG_FILE"
echo "  Base URL: $SAIA_EFFECTIVE_BASE_URL"
echo "  Default model: $DEFAULT_MODEL"
echo "  Models: ${#MODELS[@]} ready SAIA models"
echo ""
echo "Usage: openhands                       # SAIA is the default model"
echo "       openhands --model openai/$DEFAULT_MODEL"
