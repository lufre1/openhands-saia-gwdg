#!/usr/bin/env bash
#
# install-openhands-saia.sh — GENERATED FILE, DO NOT EDIT.
# Regenerate with: ./build.sh  (in the openhands-saia repo)
# Source: openhands-saia commit ee4e75f, packed 2026-09-30T05:54:14Z
#
# Installs the GWDG SAIA setup for OpenHands: provider + 2 source files.

set -euo pipefail

DATA_DIR="${OPENHANDS_DATA_DIR:-$HOME/.openhands}"
CONFIG_FILE="$DATA_DIR/agent_settings.json"
BACKUP_DIR=""
FORCE_KEY=0

usage() {
  cat <<'USAGE'
Usage: SAIA_API_KEY="your-key" bash install-openhands-saia.sh [OPTIONS]

Installs the GWDG SAIA setup for OpenHands:
  - Installs OpenHands (if missing) via the official installer
  - Writes ~/.openhands/agent_settings.json with the SAIA provider + models

Options:
  -y, --yes           answer yes to prompts (e.g. installing OpenHands)
      --key <value>   SAIA API key (overrides SAIA_API_KEY env)
      --key-file <p>  file containing the SAIA API key
      --force-key     replace an existing SAIA API key
  -h, --help          show this help

The API key is taken from --key, --key-file or the SAIA_API_KEY environment
variable; if none of them is set, you are prompted for it.
Files that would be overwritten are backed up to ~/.openhands.bak-<timestamp>/ first.
USAGE
}

# Pull the key out of a previous install so a reinstall does not ask again.
# Scoped to the llm block that points at the SAIA base URL.
key_from_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  python3 - "$CONFIG_FILE" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
llm = data.get("llm", {})
if isinstance(llm, dict) and llm.get("base_url", "").startswith("https://chat-ai.academiccloud.de"):
    print(llm.get("api_key", ""))
PYEOF
  return 0
}

prompt_for_key() {
  if ! { : </dev/tty; } 2>/dev/null; then   # -r only stats; this actually opens it
    echo "ERROR: No SAIA API key given and no terminal to ask on." >&2
    echo "Set it: SAIA_API_KEY=\"your-key\" bash install-openhands-saia.sh" >&2
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

ASSUME_YES=0
KEY=""
KEY_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --force-key) FORCE_KEY=1; shift ;;
    --key|--key-file)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
      if [[ $1 == --key ]]; then KEY="$2"; else KEY_FILE="$2"; fi
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ── Obtain the API key ───────────────────────────────────────────────
# Reuse a key from a previous install; only ask when there is none to reuse,
# and ask before anything is installed, so an empty-handed user loses nothing.
if [[ -z "$KEY" && -z "$KEY_FILE" && -z "${SAIA_API_KEY:-}" ]]; then
  SAIA_API_KEY="$(key_from_config)"
  if [[ -n "$SAIA_API_KEY" ]]; then
    export SAIA_API_KEY
    echo "Reusing the SAIA key already in $CONFIG_FILE (pass --key to replace it)."
  else
    prompt_for_key
  fi
fi

# ── Check/install OpenHands ──────────────────────────────────────────
OPENHANDS_BIN=""
if command -v openhands &>/dev/null; then
  OPENHANDS_BIN="$(command -v openhands)"
elif [[ -x /usr/local/bin/openhands ]]; then
  OPENHANDS_BIN=/usr/local/bin/openhands
  export PATH="/usr/local/bin:$PATH"
elif [[ -x "$HOME/.local/bin/openhands" ]]; then
  OPENHANDS_BIN="$HOME/.local/bin/openhands"
  export PATH="$HOME/.local/bin:$PATH"
fi

if [[ -z "$OPENHANDS_BIN" ]]; then
  if [[ $ASSUME_YES -eq 1 ]]; then
    echo "OpenHands not found — installing via official installer..."
  elif [[ -t 0 ]]; then
    read -r -p "OpenHands not found — install it via the official installer? [y/N] " reply
    if [[ $reply != [yY]* ]]; then
      echo "Aborted." >&2
      exit 1
    fi
  else
    echo "ERROR: OpenHands not found and not in TTY mode — use --yes to auto-install" >&2
    exit 1
  fi

  if ! command -v curl &>/dev/null; then
    echo "ERROR: curl is required to install OpenHands" >&2
    exit 1
  fi

  echo "Downloading and installing OpenHands..."
  if ! curl -fsSL https://install.openhands.dev/install.sh | sh; then
    echo "ERROR: OpenHands installation failed" >&2
    exit 1
  fi

  # The official installer puts the binary in /usr/local/bin or ~/.local/bin
  if command -v openhands &>/dev/null; then
    OPENHANDS_BIN="$(command -v openhands)"
  elif [[ -x /usr/local/bin/openhands ]]; then
    OPENHANDS_BIN=/usr/local/bin/openhands
    export PATH="/usr/local/bin:$PATH"
  elif [[ -x "$HOME/.local/bin/openhands" ]]; then
    OPENHANDS_BIN="$HOME/.local/bin/openhands"
    export PATH="$HOME/.local/bin:$PATH"
  fi

  if [[ -z "$OPENHANDS_BIN" ]]; then
    echo "ERROR: OpenHands installation completed but not found in PATH" >&2
    exit 1
  fi

  echo "OpenHands installed successfully: $OPENHANDS_BIN"
else
  echo "OpenHands found: $OPENHANDS_BIN"
fi

# ── Backup existing config if needed ─────────────────────────────────
if [[ -f "$CONFIG_FILE" ]] && grep -q '"base_url"' "$CONFIG_FILE"; then
  if [[ $ASSUME_YES -eq 1 ]]; then
    BACKUP_DIR=""
  elif [[ -t 0 ]]; then
    read -r -p "Backup existing config and overwrite? [y/N] " reply
    if [[ $reply == [yY]* ]]; then
      BACKUP_DIR="$DATA_DIR.bak-$(date +%Y%m%d%H%M%S)"
      mkdir -p "$BACKUP_DIR"
      cp "$CONFIG_FILE" "$BACKUP_DIR/agent_settings.json"
      echo "Backed up $CONFIG_FILE to $BACKUP_DIR/"
    else
      echo "Aborted." >&2
      exit 1
    fi
  else
    echo "ERROR: Config exists and not in TTY mode" >&2
    echo "Set SAIA_API_KEY and use --yes to overwrite" >&2
    exit 1
  fi
fi

# ── Unpack the bundled source files ──────────────────────────────────
# Into a temp dir, not next to the installer: this file is meant to be copied
# to a fresh machine on its own, and it must not litter (or overwrite) a repo
# checkout it happens to be run from.
EXTRACT_DIR="$(mktemp -d)"
trap 'rm -rf "$EXTRACT_DIR"' EXIT
mkdir -p "$EXTRACT_DIR/src"

# ── Packed source files ────────────────────────────────────────────
cat >"$EXTRACT_DIR/src/add-saia-openhands.sh" <<'__OHS_EOF__'
#!/usr/bin/env bash
set -euo pipefail

# add-saia-openhands.sh — Add GWDG SAIA provider to OpenHands CLI
#
# Reads SAIA API key from environment variable SAIA_API_KEY or --key/--key-file.
# Writes ~/.openhands/agent_settings.json with an `llm` block pointing at the
# GWDG SAIA OpenAI-compatible API.
#
# Usage:
#   SAIA_API_KEY="your-key" ./add-saia-openhands.sh
#   ./add-saia-openhands.sh --key "your-key"
#   ./add-saia-openhands.sh --key-file ~/.local/share/opencode/auth.json
#
# Note: OpenHands stores the API key in plaintext in agent_settings.json
# (chmod 600). The key is written regardless of --api-key-env, matching how
# OpenHands reads its config.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_FILE="${SCRIPT_DIR}/models.txt"
DATA_DIR="${OPENHANDS_DATA_DIR:-$HOME/.openhands}"
CONFIG_FILE="$DATA_DIR/agent_settings.json"
DEFAULT_MODEL="${SAIA_DEFAULT_MODEL:-deepseek-v4-flash-0731}"
BASE_URL="https://chat-ai.academiccloud.de/v1"
FORCE_KEY=0

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
    -h|--help)
      echo "Usage: SAIA_API_KEY=... ./add-saia-openhands.sh [--key <key> | --key-file <path>] [--force-key]"
      echo ""
      echo "Options:"
      echo "  --key <value>       SAIA API key (overrides SAIA_API_KEY env)"
      echo "  --key-file <path>   File containing the SAIA API key"
      echo "  --force-key         Replace an existing SAIA key in the config"
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
# Scoped to the llm block that points at the SAIA base URL, so a config that
# uses a different provider is left alone.
key_from_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  python3 - "$CONFIG_FILE" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
try:
    with open(path) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
llm = data.get("llm", {})
if isinstance(llm, dict) and llm.get("base_url", "").startswith("https://chat-ai.academiccloud.de"):
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

echo "Writing GWDG SAIA provider to OpenHands config..."
echo "Config file: $CONFIG_FILE"
echo "Base URL: $BASE_URL"
echo "Default model: $DEFAULT_MODEL"
echo "Models available: ${#MODELS[@]}"

SAIA_CONFIG="$CONFIG_FILE" SAIA_KEY="$SAIA_KEY" SAIA_BASE="$BASE_URL" \
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
echo "  Default model: $DEFAULT_MODEL"
echo "  Models: ${#MODELS[@]} ready SAIA models"
echo ""
echo "Usage: openhands                       # SAIA is the default model"
echo "       openhands --model openai/$DEFAULT_MODEL"
__OHS_EOF__

cat >"$EXTRACT_DIR/src/models.txt" <<'__OHS_EOF__'
apertus-70b-instruct-2509
devstral-2-123b-instruct-2512
qwen3.8-27b
deepseek-v4-flash-0731
glm-5.3-flash
qwen3-coder-next
qwen3-omni-30b-a3b-instruct
mistral-medium-3.5-128b
qwen3.5-397b-a17b
gemma-4-31b-it
qwen3.6-35b-a3b
meta-llama-3.1-8b-instruct
openai-gpt-oss-120b
qwen3-30b-a3b-instruct-2507
__OHS_EOF__

chmod +x "$EXTRACT_DIR/src/add-saia-openhands.sh"
CHILD_ARGS=()
if [[ -n "$KEY" ]]; then CHILD_ARGS+=(--key "$KEY"); fi
if [[ -n "$KEY_FILE" ]]; then CHILD_ARGS+=(--key-file "$KEY_FILE"); fi
if [[ $FORCE_KEY -eq 1 ]]; then CHILD_ARGS+=(--force-key); fi
# ${a[@]+"${a[@]}"}: bash 3.2 (stock macOS) calls an empty array unbound under set -u
"$EXTRACT_DIR/src/add-saia-openhands.sh" ${CHILD_ARGS[@]+"${CHILD_ARGS[@]}"}

echo ""
echo "✓ GWDG SAIA provider installed successfully!"
echo "  Config: $CONFIG_FILE"
echo "  Usage:  openhands"
