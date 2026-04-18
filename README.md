# secret-capture

A Claude Code skill (and standalone CLI) that captures a secret from you via a hidden-input dialog and routes it to exactly one destination, **without the value ever appearing in any tool result, log, or chat transcript**.

The problem this solves: agents routinely need to configure services with API keys and tokens. If you paste a secret into the chat or the terminal, it ends up in history, logs, and — with AI agents — the conversation transcript. `secret-capture` lets the agent prompt you for a secret via a native hidden-input dialog, pipe the value directly to the destination in a single subshell, and only return a reference string the agent can use later. The agent never sees the value.

## How it works

```
   Agent: "I need to store an OpenAI key in 1Password"
          │
          ▼
   bash capture.sh --target 1password --vault Personal --item openai-new --field credential
          │
          ▼
   osascript hidden-input dialog  ←  you type the secret here
          │
          ▼
   ┌──────────── single subshell, value never leaves the pipe ────────────┐
   │                                                                       │
   │   dialog_capture │ adapters/1password.sh → op item create --- >/dev/null │
   │                                                                       │
   └───────────────────────────────────────────────────────────────────────┘
          │
          ▼
   Stdout: "op://Personal/openai-new/credential"
          │
          ▼
   Agent receives: a reference. Never the value.
```

## Destinations supported (v1)

| Target | What it writes to | Requires |
|---|---|---|
| `1password` | A 1Password item (create or edit) | `op` CLI signed in |
| `keychain` | macOS login keychain | Built into macOS |
| `gh-secret` | GitHub Actions secret (repo / org / env) | `gh` CLI authed |
| `wrangler` | Cloudflare Workers secret | `wrangler` + Cloudflare auth |
| `coolify` | Coolify application env var (via REST) | Coolify instance URL + API token |
| `n8n` | n8n credential (via REST) | n8n instance URL + API key |
| `env-file` | Local `.env` file (mode 0600) | — |

More destinations are planned (Vercel, Netlify, Fly.io, HashiCorp Vault, AWS Secrets Manager, GCP Secret Manager, Kubernetes, Docker) — PRs welcome.

## Requirements

- **macOS** (osascript dialog). Linux / Windows support is planned — see [Roadmap](#roadmap).
- `bash` ≥ 4 (or `zsh`), `jq`, `curl`.
- Per-destination tooling: `op` (1Password CLI), `gh` (GitHub CLI), `wrangler` (Cloudflare).

## Install

### As a Claude Code skill

Clone (or add as a submodule) into your skills directory:

```bash
git clone https://github.com/D1DX/secret-capture-skill.git ~/.claude/skills/secret-capture
```

Claude Code auto-discovers skills in `~/.claude/skills/` at session start. The skill will auto-trigger when the agent detects a credential-configuration task, and is also manually invocable as `/secret-capture`.

### As a standalone CLI

```bash
git clone https://github.com/D1DX/secret-capture-skill.git ~/.local/share/secret-capture
echo 'alias secret-capture="bash $HOME/.local/share/secret-capture/scripts/capture.sh"' >> ~/.zshrc
```

## Configure

Create `~/.config/secret-capture/config.yaml`. See [`config.example.yaml`](./config.example.yaml) for the full shape. Minimum:

```yaml
adapters:
  enabled: [1password, keychain, gh-secret, wrangler, env-file]

defaults:
  1password:
    vault: "Personal"
```

For destinations that need their own API credentials (Coolify, n8n), each destination declares where to source them. Options: `keychain:<service>`, `env:<VAR>`, `file:<path>`, `op:<op-ref>`, `command:<shell>`. Example:

```yaml
defaults:
  coolify:
    url: "https://coolify.example.com"
    api_key_source: "keychain:coolify-api"
  n8n:
    instances:
      production:
        url: "https://n8n.example.com"
        api_key_source: "op:op://Personal/n8n-api/credential"
```

## Usage

### From an agent

The agent invokes the entry script. It passes the destination kind and the destination-specific spec as flags; it never passes the value.

```bash
bash ~/.claude/skills/secret-capture/scripts/capture.sh \
  --target 1password \
  --vault Personal \
  --item anthropic-key \
  --field credential
# → op://Personal/anthropic-key/credential
```

```bash
bash ~/.claude/skills/secret-capture/scripts/capture.sh \
  --target wrangler \
  --worker my-api \
  --name OPENAI_API_KEY
# → wrangler-secret:my-api#OPENAI_API_KEY
```

### From the user (manual invocation)

Same flags. For Claude Code:

```
/secret-capture --target keychain --service my-cli-tool --account $(whoami)
```

### Return values

Every adapter emits a **reference** — never the value:

| Target | Reference format |
|---|---|
| `1password` | `op://<vault>/<item>/<field>` |
| `keychain` | `keychain:<service>` |
| `gh-secret` | `gh-secret:<owner>/<repo>#<name>` |
| `wrangler` | `wrangler-secret:<worker>#<name>` |
| `coolify` | `coolify-env:<app-uuid>#<key>` |
| `n8n` | `n8n-cred:<name> (id=<id>)` |
| `env-file` | `env-file:<path>#<key>` |

The agent uses the reference to consume the secret later (e.g., `op read "op://Personal/anthropic-key/credential"`), without the skill ever holding the value in memory again.

## Rotation

Pass `--rotate`:

```bash
bash capture.sh --target 1password --rotate --vault Personal --item anthropic-key --field credential
```

The adapter detects whether an existing record exists and dispatches to edit/update/overwrite. One spec, one home.

## Format validation (opt-in)

Pass `--expect <shape>` to validate the captured value against a known-key regex before writing it:

```bash
bash capture.sh --target keychain --service openai --account default --expect openai
```

Shapes ship in [`patterns/common.yaml`](./patterns/common.yaml): `openai`, `anthropic`, `github-pat`, `aws-access-key`, `stripe`, `cloudflare-token`, `slack`. Add custom patterns at `~/.config/secret-capture/patterns.yaml`.

Off by default — strict validation can reject legitimate edge cases. Turn on per invocation when you know the shape.

## Security model

The skill enforces these invariants for every adapter:

- **Value never on argv** — adapters read stdin via `--rawfile /dev/stdin` or `cat -`; reject any `--value`-style flag
- **Value never in env** — nothing gets `export`ed
- **Value never in shell history** — `set +o history` + `HISTFILE=/dev/null`
- **Value never in stdout** — every subcommand that touches it is redirected to `/dev/null`
- **Tempfiles are 0600 + shredded** — `umask 077` + `mktemp` + `trap shred EXIT`
- **Tool results** — the capture script's only stdout is the reference string

See [`docs/SECURITY.md`](./docs/SECURITY.md) for the full threat model.

## Error codes

All errors emit machine-readable codes on stderr. The value is never in an error message.

| Code | When |
|---|---|
| `CANCELLED` | User hit Cancel in dialog or Ctrl-C at TTY |
| `NO_GUI` | No WindowServer and no TTY available |
| `TIMEOUT` | osascript 2-minute auto-dismiss |
| `AUTH_FAIL` | `op` not signed in / `gh auth` expired / destination 401 |
| `DUPLICATE` | Create without `--rotate`, record exists |
| `FORMAT_MISMATCH` | `--expect` mismatch |
| `ADAPTER_ERROR` | Subcommand non-zero exit |

## Roadmap

- Linux: `zenity` / `kdialog` dialog fallback
- Windows: PowerShell `Read-Host -AsSecureString`
- More adapters: Vercel, Netlify, Fly.io, Heroku, Railway, Render, Supabase, AWS Secrets Manager, AWS SSM Parameter Store, GCP Secret Manager, HashiCorp Vault, Kubernetes, Docker secrets
- `generic` escape-hatch adapter for arbitrary stdin-consuming commands (opt-in via config)

## Contributing

PRs welcome. Each new adapter must pass the hygiene lint (`scripts/lint-adapters.sh`) proving no argv/env/history/stdout leak paths.

## License

MIT — see [LICENSE](./LICENSE).
