# GWDG SAIA Provider Setup for OpenHands

## Summary

This installer configures the GWDG SAIA provider in OpenHands (CLI) with 14 ready models.

## Prerequisites

- **SAIA API key** (from GWDG SAIA) — the installer reuses the key from a previous
  install, and prompts for it only when there is none
- **OpenHands** will be installed automatically if missing (via the official installer)

## Quick start

```bash
SAIA_API_KEY="your-key" bash install-openhands-saia.sh --yes
```

This one-shot installer:
- Installs OpenHands (if missing) via the official installer
- Writes `~/.openhands/agent_settings.json` with the SAIA provider
- Works on macOS, Linux, and WSL

## Detailed installation

### 1. Obtain your SAIA API key

Your key is stored in `~/.local/share/opencode/auth.json` (if you use opencode with SAIA), or you can generate a new one at the GWDG SAIA portal.

### 2. Run the installer

```bash
# Option A: via environment variable (recommended)
SAIA_API_KEY="your-key" bash install-openhands-saia.sh --yes

# Option B: via --key argument
bash install-openhands-saia.sh --key "your-key" --yes

# Option C: via --key-file (reads from a file)
bash install-openhands-saia.sh --key-file ~/.local/share/opencode/auth.json --yes

# Option D: pass nothing — reuses the key from a previous install,
# or asks for it (input hidden) if this is the first one
bash install-openhands-saia.sh --yes
```

The `--yes` flag enables non-interactive mode and auto-installs OpenHands if missing. Without it, the installer will prompt before installing OpenHands.

The installer will:
- Verify OpenHands is installed (or install it)
- Back up your existing `~/.openhands/agent_settings.json` if it already has an `llm` block
- Write the SAIA provider config
- Verify the config was written

### 3. Verify installation

```bash
cat ~/.openhands/agent_settings.json
```

You should see an `llm` block pointing at `https://chat-ai.academiccloud.de/v1`
(or at `http://127.0.0.1:8788/v1` with `--keyring` — see *Multiple keys* below).

### 4. Test the provider

```bash
openhands --task "Say hello"
```

## Usage

### Start a session with a SAIA model

```bash
# Use the TUI
openhands

# Or start with a specific model
openhands --model openai/deepseek-v4-flash-0731
```

### Available models

All 14 ready SAIA models:

- apertus-70b-instruct-2509
- devstral-2-123b-instruct-2512
- qwen3.8-27b
- deepseek-v4-flash-0731
- glm-5.3-flash
- qwen3-coder-next
- qwen3-omni-30b-a3b-instruct
- mistral-medium-3.5-128b
- qwen3.5-397b-a17b
- gemma-4-31b-it
- qwen3.6-35b-a3b
- meta-llama-3.1-8b-instruct
- openai-gpt-oss-120b
- qwen3-30b-a3b-instruct-2507

## Config schema

The provider is stored in `~/.openhands/agent_settings.json`:

```json
{
  "llm": {
    "model": "openai/deepseek-v4-flash-0731",
    "api_key": "<your-key>",
    "base_url": "https://chat-ai.academiccloud.de/v1",
    "drop_params": true
  }
}
```

**Note**: The model name is prefixed with `openai/`. OpenHands passes the model
string straight to LiteLLM, which needs the provider encoded in the model name
to route to the OpenAI-compatible `base_url` (a separate provider field is
ignored). Without the prefix you get `LLM Provider NOT provided`.

**Note**: OpenHands stores the API key in plaintext in `agent_settings.json`. The file has 600 permissions (owner read/write only).

## Multiple keys: automatic key swap

SAIA rate limits are per key (30/min, 200/hour, 1000/day, 3000/month). Opt in with
`--keyring`, give the installer extra keys, and OpenHands swaps to the next one by
itself when the active key is revoked (401/403), drained (its hour/day/month budget
nearly used up) or rate limited (429) — the same rotation the opencode setup does.

```bash
# Extra keys via the environment, so they never show up in `ps`
SAIA_API_KEYS_EXTRA="key2,key3" bash install-openhands-saia.sh --yes --keyring

# Or reuse the extra keys of an opencode setup
bash install-openhands-saia.sh --yes --keyring --extra-keys-file ~/.local/share/opencode/saia-gwdg-keys.json
```

With `--keyring` the installer starts **saia-keyring**, a small local proxy
(`~/.local/share/saia-keyring/saia_keyring.py`, stdlib Python 3), and writes
`"base_url": "http://127.0.0.1:8788/v1"` into the `llm` block of
`~/.openhands/agent_settings.json` instead of SAIA. OpenHands keeps sending its usual
key; the proxy only serves requests carrying one of the configured keys and forwards
them on the active key. Every harness installed with `--keyring` shares the same proxy
and key list. Keys are only swapped before a response starts — a stream in progress is
never cut over. OpenHands' LLM calls run in the CLI process on your machine, so the
loopback proxy is reachable (not from `openhands serve`'s Docker GUI, though).

| What | Where |
|------|-------|
| Keys | `~/.config/saia-keyring/keyring.json` (chmod 600), primary key first. A reinstall without extra keys keeps the stored ones; a changed list is backed up to `keyring.json.bak-<timestamp>` |
| Status | `saia-keyring status` — per-key budget, the active key, rejected keys |
| Log | `~/.cache/saia-keyring/proxy.log` |
| Service | systemd user unit `saia-keyring` (Linux), launchd agent `de.gwdg.saia-keyring` (macOS), otherwise a line in your shell rc |
| Turn off | re-run without `--keyring`: OpenHands talks to SAIA directly again |

A reinstall recognises a config pointing at the proxy as SAIA, so it reuses the key just
like a direct one. Without `--keyring` none of this is installed (extra keys are
ignored): OpenHands talks to SAIA directly, as before. When every key is out, OpenHands
shows why — e.g. `All 3 SAIA key(s) rejected by SAIA (...) — the key(s) are revoked or
expired`.

## Troubleshooting

### Config not taking effect

```bash
cat ~/.openhands/agent_settings.json
```

### API key errors

- Ensure `SAIA_API_KEY` is set correctly (no quotes in the env var value); with no
  key set at all, the installer asks for one, and fails only if there is no terminal
  to ask on (CI, cron) — set the env var there
- Verify the key is valid at the GWDG SAIA portal
- Check rate limits: 30 req/min, 200/hour, 1000/day, 3000/month per key

### OpenHands not found

The installer automatically installs OpenHands via the official installer if missing:

```bash
curl -fsSL https://install.openhands.dev/install.sh | sh
```

This installs the `openhands` binary to `/usr/local/bin` (or `~/.local/bin` if not writable).

## Advanced: Regenerate the installer

If you modify `src/add-saia-openhands.sh` or `src/models.txt`, regenerate the installer.
`src/saia_keyring.py` and `src/saia-keyring.sh` are vendored from
`opencode-saia-gwdg/keyring/` — change them there and run its `keyring/sync.sh`.

```bash
./build.sh
```

This creates a new `install-openhands-saia.sh` with the changes embedded.

## License

MIT
