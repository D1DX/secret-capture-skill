# Changelog

## [0.1.0] — 2026-04-22

Initial release.

### Adapters

- `1password` — create or rotate a 1Password item via `op` CLI; returns `op://<vault>/<item>/<field>`
- `keychain` — write to macOS login keychain via `security` + `expect`; returns `keychain:<service>`
- `gh-secret` — set a GitHub Actions secret (repo / org / environment scope) via `gh` CLI; returns `gh-secret:...`
- `wrangler` — set a Cloudflare Workers secret via `wrangler secret bulk`; returns `wrangler-secret:<worker>#<name>`
- `coolify` — write a Coolify application env var via REST (bypasses MCP to avoid transcript echo); returns `coolify-env:<uuid>#<key>`
- `n8n` — create an n8n credential via REST; returns `n8n-cred:<name> (id=<id>)`
- `env-file` — write a `KEY=value` line to a local `.env` file (mode 0600); returns `env-file:<path>#<key>`
- `ssh` — write a secret to a remote file over SSH without the value touching argv or env; returns `ssh-kv:...` or `ssh-file:...`

### Features

- Hidden-input dialog via osascript (TTY fallback with `read -s`)
- `--rotate` flag for overwrite/update flows across all adapters
- `--expect <shape>` format validation against 16 built-in regex patterns (`patterns/common.yaml`); user patterns via `~/.config/secret-capture/patterns.yaml`
- Hygiene lint (`scripts/lint-adapters.sh`) — auto-discovers all adapters, checks for argv/env/stdout/tempfile violations
- Config file at `~/.config/secret-capture/config.yaml` — adapter allowlist, per-destination defaults, dialog timeout, TTY fallback, pattern enforcement
- xtrace guard in `scripts/lib/dialog.sh` — `bash -x` debugging cannot leak the captured value
- Machine-readable error codes on stderr: `CANCELLED`, `NO_GUI`, `TIMEOUT`, `AUTH_FAIL`, `DUPLICATE`, `NOT_FOUND`, `FORMAT_MISMATCH`, `ADAPTER_ERROR`