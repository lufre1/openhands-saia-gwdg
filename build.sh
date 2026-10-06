#!/usr/bin/env bash
#
# build.sh — pack the live SAIA config into install-openhands-saia.sh
#
# Reads the current src/add-saia-openhands.sh, src/models.txt and the vendored
# keyring (src/saia_keyring.py, src/saia-keyring.sh — from opencode-saia-gwdg) and
# emits a single self-contained installer that can be copied to other devices.
# Rerun this after ANY change to those files, and commit both.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

OUT="install-openhands-saia.sh"
MANIFEST=(
  src/add-saia-openhands.sh
  src/models.txt
  src/saia-keyring.sh
  src/saia_keyring.py
)

# ── Sanity checks ────────────────────────────────────────────────────
for f in "${MANIFEST[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: missing source file: $f" >&2
    exit 1
  fi
  if grep -qF "__OHS_EOF__" "$f"; then
    echo "ERROR: delimiter '__OHS_EOF__' occurs in $f — pick a different delimiter" >&2
    exit 1
  fi
  if [[ -n "$(tail -c 1 "$f")" ]]; then
    echo "ERROR: $f lacks a trailing newline (heredoc packing would add one)" >&2
    exit 1
  fi
done

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=""
git diff --quiet HEAD -- "${MANIFEST[@]}" 2>/dev/null || DIRTY="-dirty"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TMP_OUT="$(mktemp "$OUT.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT

# ── Header (interpolates the stamp) ──────────────────────────────────
cat >"$TMP_OUT" <<OHS_GEN_HEADER
#!/usr/bin/env bash
#
# install-openhands-saia.sh — GENERATED FILE, DO NOT EDIT.
# Regenerate with: ./build.sh  (in the openhands-saia repo)
# Source: openhands-saia commit $COMMIT$DIRTY, packed $STAMP
#
# Installs the GWDG SAIA setup for OpenHands: provider + ${#MANIFEST[@]} source files.

OHS_GEN_HEADER

# ── Static installer body ────────────────────────────────────────────
cat >>"$TMP_OUT" <<'OHS_GEN_BODY'
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
      --extra-keys <k2,k3>      with --keyring: extra SAIA keys to swap to
                                (or SAIA_API_KEYS_EXTRA, which keeps them out of ps)
      --extra-keys-file <path>  with --keyring: extra keys from {"keys": [...]} (opencode's
                                saia-gwdg-keys.json) or one key per line
      --keyring                 opt in: route through the local key-rotating proxy
      --no-keyring              talk to SAIA directly with one key (the default)
  -h, --help          show this help

The API key is taken from --key, --key-file or the SAIA_API_KEY environment
variable; if none of them is set, you are prompted for it.
Files that would be overwritten are backed up to ~/.openhands.bak-<timestamp>/ first.

With --keyring OpenHands talks to a local proxy (saia-keyring, 127.0.0.1:8788) that
swaps to the next key when the active one is revoked, drained or rate limited.
USAGE
}

# Pull the key out of a previous install so a reinstall does not ask again.
# Scoped to the llm block that points at SAIA — directly, or through the local
# saia-keyring proxy.
key_from_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  KR_CONFIG="${SAIA_KEYRING_CONFIG:-$HOME/.config/saia-keyring/keyring.json}" \
  python3 - "$CONFIG_FILE" <<'PYEOF'
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
KEYRING_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --force-key) FORCE_KEY=1; shift ;;
    --key|--key-file)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
      if [[ $1 == --key ]]; then KEY="$2"; else KEY_FILE="$2"; fi
      shift 2
      ;;
    --extra-keys|--extra-keys-file)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
      KEYRING_ARGS+=("$1" "$2")
      shift 2
      ;;
    --keyring|--no-keyring) KEYRING_ARGS+=("$1"); shift ;;
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
OHS_GEN_BODY

# ── Append the packed source files ───────────────────────────────────
echo "" >>"$TMP_OUT"
echo "# ── Packed source files ────────────────────────────────────────────" >>"$TMP_OUT"

for f in "${MANIFEST[@]}"; do
  echo "cat >\"\$EXTRACT_DIR/$f\" <<'__OHS_EOF__'" >>"$TMP_OUT"
  cat "$f" >>"$TMP_OUT"
  echo "__OHS_EOF__" >>"$TMP_OUT"
  echo "" >>"$TMP_OUT"
done

# ── Static installer tail: run what we just unpacked ──────────────────
cat >>"$TMP_OUT" <<'OHS_GEN_TAIL'
chmod +x "$EXTRACT_DIR/src/add-saia-openhands.sh"
CHILD_ARGS=()
if [[ -n "$KEY" ]]; then CHILD_ARGS+=(--key "$KEY"); fi
if [[ -n "$KEY_FILE" ]]; then CHILD_ARGS+=(--key-file "$KEY_FILE"); fi
if [[ $FORCE_KEY -eq 1 ]]; then CHILD_ARGS+=(--force-key); fi
CHILD_ARGS+=(${KEYRING_ARGS[@]+"${KEYRING_ARGS[@]}"})
# ${a[@]+"${a[@]}"}: bash 3.2 (stock macOS) calls an empty array unbound under set -u
"$EXTRACT_DIR/src/add-saia-openhands.sh" ${CHILD_ARGS[@]+"${CHILD_ARGS[@]}"}

echo ""
echo "✓ GWDG SAIA provider installed successfully!"
echo "  Config: $CONFIG_FILE"
echo "  Usage:  openhands"
OHS_GEN_TAIL

# ── Finalize ─────────────────────────────────────────────────────────
bash -n "$TMP_OUT"
chmod +x "$TMP_OUT"
mv "$TMP_OUT" "$OUT"
trap - EXIT

echo "Generated: $OUT"
echo "Commit: $COMMIT$DIRTY"
echo "Timestamp: $STAMP"
