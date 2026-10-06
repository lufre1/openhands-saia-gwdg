# openhands-saia

GWDG SAIA provider for **OpenHands** (CLI)

This repo provides an installer that configures the [GWDG SAIA](https://chat-ai.academiccloud.de/) OpenAI-compatible API as the LLM provider for OpenHands, giving you access to 14 ready models including Qwen, DeepSeek, GLM, and more.

## Quick start

```bash
SAIA_API_KEY="your-key" bash install-openhands-saia.sh --yes
```

No key in the environment? Run `bash install-openhands-saia.sh --yes` and it asks for one
(or pass `--key <value>` / `--key-file <path>`). Reinstalls reuse the key already in your
OpenHands config, so you only ever type it once.

This one-shot installer:
- Installs OpenHands (if missing) via the official installer (`curl -fsSL https://install.openhands.dev/install.sh | sh`)
- Writes `~/.openhands/agent_settings.json` with the SAIA provider (base URL, API key, default model)
- Optional, with `--keyring`: routes OpenHands through a local
  key-rotating proxy that swaps keys automatically when one is revoked, drained or
  rate limited (see `SETUP.md` → *Multiple keys*)
- Works on macOS, Linux, and WSL

Or see `SETUP.md` for detailed instructions and troubleshooting.

## What's included

| File | Purpose |
|------|---------|
| `install-openhands-saia.sh` | Self-contained installer (generated; never edit directly) |
| `build.sh` | Regenerates the installer from source files |
| `src/add-saia-openhands.sh` | Live source script (portable key sourcing + config write) |
| `src/models.txt` | List of 14 ready SAIA models |
| `src/saia_keyring.py`, `src/saia-keyring.sh` | Key-rotating proxy and its install logic, vendored from `opencode-extras/keyring/` (never edit here) |
| `test/test-config.sh` | Smoke test for the config-write logic and the key swap (not packed) |
| `test/fake-saia.py` | Fake SAIA endpoint for the key-swap test (not packed) |

## Architecture

```
SAIA_API_KEY → install-openhands-saia.sh → [OpenHands install] → src/add-saia-openhands.sh → ~/.openhands/agent_settings.json
```

## Maintaining

After changing `src/add-saia-openhands.sh` or `src/models.txt`, regenerate the installer
(the keyring files are synced in by `opencode-extras/keyring/sync.sh`, which also rebuilds):

```bash
./build.sh
```

## License

MIT
