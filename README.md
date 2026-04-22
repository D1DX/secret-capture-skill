# secret-capture

[![Author](https://img.shields.io/badge/Author-Daniel_Rudaev-000000?style=flat)](https://github.com/daniel-rudaev)
[![Studio](https://img.shields.io/badge/Studio-D1DX-000000?style=flat)](https://d1dx.com)
[![Claude Code](https://img.shields.io/badge/Claude_Code-Skill-CC785C?style=flat)](https://github.com/anthropics/claude-code)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat)](./LICENSE)

A Claude Code skill (and standalone CLI) that captures a secret from you via a hidden-input dialog and writes it directly to a destination — **without the value ever appearing in any tool result, log, or chat transcript**.

---

## The problem

When an AI agent needs an API key or token, the obvious path leaks: paste the key into chat → it's in the conversation transcript. Type it in the terminal → it's in shell history. Pass it as a flag → it shows up in `ps`.

`secret-capture` breaks that pattern. Instead of asking you to paste a value, the agent invokes this skill. You type the secret into a native hidden-input dialog (like a password prompt). The value flows directly from the dialog to the destination in a single subshell — the agent only ever sees the reference back.

---

## How it works

```
  Agent invokes:
  bash capture.sh --target <destination> [destination flags]
         │
         ▼
  ┌─ hidden-input dialog (osascript) ─────────────────┐
  │  ● ● ● ● ● ● ● ● ●   ← you type here, not in chat │
  └────────────────────────────────────────────────────┘
         │  value never leaves this pipe
         ▼
  adapter writes to destination  →  output suppressed
         │
         ▼
  stdout: a reference string (e.g. op://Personal/my-key/credential)
         │
         ▼
  Agent receives: the reference. Never the value.
```

The reference is a pointer the agent can use later to retrieve or consume the secret — without ever seeing the secret itself.

---

## Pick your destination

Eight adapters ship with v1. Choose based on **who or what will consume the secret**:

| I need the secret to live in… | Use adapter | Best for |
|---|---|---|
| **1Password** | `1password` | Anything you'll consume from your own machine — CLI tools, agents, MCPs, scripts. `op read` retrieves it anywhere. |
| **macOS Keychain** | `keychain` | Local CLI tools or scripts that use `security find-generic-password`. |
| **GitHub Actions** | `gh-secret` | CI/CD secrets for a repo, org, or environment. |
| **Cloudflare Workers** | `wrangler` | Worker secrets injected at runtime via the Cloudflare platform. |
| **Coolify** | `coolify` | Environment variables for an app managed by your Coolify instance. |
| **n8n** | `n8n` | Credentials for a workflow running on your n8n instance. |
| **A `.env` file** | `env-file` | Local development or any tool that reads a `.env` file. |
| **A remote server** | `ssh` | Secrets on a VPS — dotenv files, TLS keys, single-token files read by a daemon. |

**Rule of thumb:** if _you_ consume it from your machine → `1password`. If a _platform_ consumes it at runtime → the matching platform adapter.

---

## Adapters

### `1password`

Writes to a 1Password item (create or rotate). Returns a reference you pass to `op read` later.

```bash
bash capture.sh --target 1password \
  --vault <vault-name> \
  --item  <item-name>  \
  --field <field-name> \
  [--category API_CREDENTIAL] \
  [--rotate]
# → op://Personal/my-key/credential
```

Requires: `op` CLI signed in (`brew install 1password-cli`).

---

### `keychain`

Writes to the macOS login keychain. Use `security find-generic-password -s <service> -w` to read it later.

```bash
bash capture.sh --target keychain \
  --service <service-name> \
  --account <account>      \
  [--rotate]
# → keychain:my-service
```

Requires: built into macOS (uses `security` + `expect`).

---

### `gh-secret`

Sets a GitHub Actions secret at repo, org, or environment scope.

```bash
# Repo secret
bash capture.sh --target gh-secret --scope repo \
  --repo <owner/repo> --name <SECRET_NAME>
# → gh-secret:owner/repo#SECRET_NAME

# Org secret
bash capture.sh --target gh-secret --scope org \
  --org <org> --name <SECRET_NAME>
# → gh-secret:org/myorg#SECRET_NAME

# Environment secret
bash capture.sh --target gh-secret --scope env \
  --repo <owner/repo> --env <env-name> --name <SECRET_NAME>
# → gh-secret:owner/repo/env/production#SECRET_NAME
```

Requires: `gh` CLI authenticated (`brew install gh && gh auth login`).

---

### `wrangler`

Sets a Cloudflare Workers secret. The Worker reads it as an environment binding at runtime.

```bash
bash capture.sh --target wrangler \
  --worker <worker-name> \
  --name   <SECRET_NAME> \
  [--rotate]
# → wrangler-secret:my-worker#SECRET_NAME
```

Requires: `wrangler` CLI with Cloudflare auth (`npm i -g wrangler && wrangler login`).

---

### `coolify`

Writes an environment variable to a Coolify application via the Coolify REST API. Bypasses the MCP intentionally — the MCP response would echo the value back into the transcript.

```bash
bash capture.sh --target coolify \
  --app-uuid <uuid> \
  --key       <ENV_VAR_NAME> \
  [--build-time] \
  [--rotate]
# → coolify-env:abc123#MY_VAR
```

Requires: Coolify instance URL + API token configured in `~/.config/secret-capture/config.yaml` (see [Configure](#configure)).

---

### `n8n`

Creates a credential in your n8n instance. The credential type name must match n8n's internal type (e.g. `anthropicApi`, `openAiApi`, `httpHeaderAuth`).

```bash
bash capture.sh --target n8n \
  --instance   <instance-alias> \
  --name       <credential-name> \
  --type       <n8n-credential-type> \
  [--data-field <field-name>]
# → n8n-cred:My Anthropic Key (id=42)
```

Requires: n8n instance URL + API key configured in `~/.config/secret-capture/config.yaml` (see [Configure](#configure)).

---

### `env-file`

Appends or updates a `KEY=value` line in a local `.env` file (creates it at mode 0600 if it doesn't exist).

```bash
bash capture.sh --target env-file \
  --file <path/to/.env> \
  --key  <KEY_NAME>     \
  [--rotate]
# → env-file:.env#MY_KEY
```

Requires: nothing beyond bash.

---

### `ssh`

Writes a secret to a file on a remote server over SSH, without the value touching argv or env at any point.

```bash
# KEY=value line in a remote dotenv file
bash capture.sh --target ssh \
  --ssh-host    <host>        \
  --mode        file-kv       \
  --remote-path <remote-path> \
  --key         <KEY_NAME>    \
  [--chmod 600] [--rotate]
# → ssh-kv:user@host:/path/to/file#KEY_NAME

# Raw value into a remote file (PEM, cert, token)
bash capture.sh --target ssh \
  --ssh-host    <host>        \
  --mode        file-raw      \
  --remote-path <remote-path> \
  [--chmod 600] [--rotate]
# → ssh-file:user@host:/path/to/file
```

Requires: SSH agent (1Password SSH Agent or system agent). Uses `StrictHostKeyChecking=accept-new` on first connect. Writes atomically via a temp file + `mv`.

---

## Install

### As a Claude Code skill

```bash
git clone https://github.com/D1DX/secret-capture-skill.git ~/.claude/skills/secret-capture
```

Claude Code auto-discovers skills in `~/.claude/skills/` at session start. The skill auto-triggers when the agent detects a credential task and is also manually invocable as `/secret-capture`.

### As a standalone CLI

```bash
git clone https://github.com/D1DX/secret-capture-skill.git ~/.local/share/secret-capture
echo 'alias secret-capture="bash $HOME/.local/share/secret-capture/scripts/capture.sh"' >> ~/.zshrc
```

---

## Requirements

- **macOS** — dialog uses `osascript`. No Automation permission required. Linux/Windows support planned.
- `bash` ≥ 4 (or `zsh`), `jq`, `curl`
- `yq` (Go version, mikefarah/yq) — needed by `1password`, `coolify`, `n8n` adapters and `--expect` validation
- `expect` — preinstalled on macOS; needed by `keychain` adapter
- Per-adapter tooling — only install what you need:

```bash
brew install jq yq 1password-cli gh && npm i -g wrangler
```

---

## Configure

Create `~/.config/secret-capture/config.yaml` (mode 0600). See [`config.example.yaml`](./config.example.yaml) for the full shape.

**Minimum config:**

```yaml
adapters:
  enabled: [1password, keychain, gh-secret, wrangler, env-file]

defaults:
  1password:
    vault: "Personal"
```

**For Coolify and n8n** — these adapters need to authenticate to your instance. Configure where the skill should source their API credentials (the credentials the _skill_ uses, not the secret being captured):

```yaml
defaults:
  coolify:
    url: "https://coolify.example.com"
    api_key_source: "keychain:coolify-api"   # or op:// or env:MY_VAR

  n8n:
    instances:
      production:
        url: "https://n8n.example.com"
        api_key_source: "keychain:n8n-production-api"
```

`api_key_source` supports: `keychain:<service>`, `op:<op-ref>`, `env:<VAR>`, `file:<path>`, `command:<shell>`.

---

## Options

### `--rotate` — overwrite an existing secret

By default every adapter fails with `DUPLICATE` if the item already exists. Pass `--rotate` to switch to an update/overwrite flow:

```bash
bash capture.sh --target 1password --rotate --vault Personal --item my-key --field credential
```

Works on all adapters.

### `--expect <shape>` — validate format before writing

Validates the captured value against a known regex before the adapter runs. Useful to catch paste mistakes.

```bash
bash capture.sh --target keychain --service openai --account default --expect openai
```

16 built-in shapes in [`patterns/common.yaml`](./patterns/common.yaml): `openai`, `anthropic`, `github-pat`, `github-fine-grained`, `github-app`, `aws-access-key`, `aws-secret-key`, `stripe-live`, `stripe-test`, `cloudflare-token`, `cloudflare-global-key`, `slack-bot`, `slack-user`, `slack-workflow`, `jwt`, `uuid`.

Add custom patterns at `~/.config/secret-capture/patterns.yaml`. See [`docs/PATTERNS.md`](./docs/PATTERNS.md).

Off by default. On mismatch: exits with `FORMAT_MISMATCH` — re-invoke to retry.

---

## Security model

Every adapter enforces the same invariants:

- **Value never on argv** — adapters read from stdin, never from a flag
- **Value never in env** — no `export` of the captured value
- **Value never in shell history** — `HISTFILE=/dev/null` + `set +o history`
- **Value never in stdout** — every subcommand that touches the value redirects to `/dev/null`; the only stdout is the reference string
- **Tempfiles are 0600 + shredded** — `umask 077` + `mktemp` + `trap shred EXIT`

See [`docs/SECURITY.md`](./docs/SECURITY.md) for the full threat model, leak vectors, and how to verify no leaks locally.

For framework-level enforcement (blocking unsafe `op read` patterns, scanning written files for hardcoded secrets), see [`docs/HOOKS.md`](./docs/HOOKS.md).

---

## Error codes

All errors emit a machine-readable code on stderr. The value is never in an error message.

| Code | When |
|---|---|
| `CANCELLED` | User hit Cancel in dialog or Ctrl-C at TTY |
| `NO_GUI` | No WindowServer and no TTY available |
| `TIMEOUT` | osascript 2-minute auto-dismiss |
| `AUTH_FAIL` | Destination rejected credentials (op not signed in, gh not authed, API 401) |
| `DUPLICATE` | Item already exists — re-invoke with `--rotate` |
| `NOT_FOUND` | `--rotate` passed but item does not exist |
| `FORMAT_MISMATCH` | `--expect` regex did not match |
| `ADAPTER_ERROR` | Adapter subcommand exited non-zero |

---

## Roadmap

- Linux: `zenity` / `kdialog` dialog fallback
- Windows: PowerShell `Read-Host -AsSecureString`
- More adapters: Vercel, Netlify, Fly.io, AWS Secrets Manager, AWS SSM Parameter Store, GCP Secret Manager, HashiCorp Vault, Kubernetes, Docker secrets
- `generic` adapter for arbitrary stdin-consuming commands (opt-in via config)

---

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md). Each new adapter must pass the hygiene lint (`scripts/lint-adapters.sh`) and meet the full contract in [`docs/ADAPTERS.md`](./docs/ADAPTERS.md).

## License

MIT — see [LICENSE](./LICENSE).