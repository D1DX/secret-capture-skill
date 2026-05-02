---
name: secret-capture
description: Capture a secret from the user via a hidden-input dialog and route it to exactly one destination (1Password, macOS Keychain, GitHub secret, Cloudflare Workers secret, Coolify env var, n8n credential, or a local .env file) without the value ever appearing in any tool result, log, or chat transcript. Auto-triggers whenever the agent needs a new credential, API key, token, password, or secret to configure a service, onboard an integration, set up an MCP, or rotate an existing credential. Use this every time you're about to say "paste your key here" — instead, invoke this skill.
disable-model-invocation: false
user-invocable: true
argument-hint: "destination spec (e.g., '1password vault=Personal item=openai-key field=credential')"
---

# Secret capture

Invoke this skill whenever you need the user to supply a credential. Never ask the user to paste a secret into chat or the terminal — use this skill instead.

## When to use

- Onboarding a new MCP, integration, or service that needs an API key
- Rotating an existing credential
- Creating a new n8n credential, Cloudflare Worker secret, GitHub secret, Coolify env var
- Storing a personal API key the user will consume from their shell / agents (→ 1Password)
- Any time mid-task you realize "I need a credential here"

## Decision rule — which destination

One secret, one home. Pick based on who consumes the value:

- **User consumes it** (terminal, agents, MCPs, HTTP calls from the user's machine) → `1password`
- **System consumes it natively** (n8n runs the workflow that uses this token, GitHub Actions runs the workflow, Cloudflare Worker runtime reads it, Coolify app reads the env var) → the matching target adapter

Never store the same secret in two places.

## Invocation

The skill is a bash script. Invoke via the Bash tool:

```bash
bash ~/.claude/skills/secret-capture/scripts/capture.sh --target <target> [target-flags] [--rotate] [--expect <shape>]
```

You pass only the destination metadata. You never pass, read, or handle the value. The script opens a hidden-input dialog, captures the value, pipes it directly to the destination, and returns a reference on stdout.

## Targets

### `1password`

```bash
bash capture.sh --target 1password \
  --vault <vault-name> --item <item-name> --field <field-name> \
  [--category API_CREDENTIAL] [--rotate]
```

Returns: `op://<vault>/<item>/<field>`

Use when the user will consume this secret from their machine (`op read ...`).

`--category` must be an op CLI **template ID** (uppercase-underscore form), not the friendly UI name. Common values: `API_CREDENTIAL` (default), `LOGIN`, `PASSWORD`, `DATABASE`, `SECURE_NOTE`, `SERVER`. Get the canonical list via `op item template list`. Passing the friendly form (e.g. `"API Credential"`) makes `op item create` reject the template — the adapter surfaces op's actual error in that case.

### `keychain`

```bash
bash capture.sh --target keychain --service <service-name> --account <account> [--rotate]
```

Returns: `keychain:<service>`

Use for macOS-local CLI tools or scripts that will read it via `security find-generic-password`.

### `gh-secret`

```bash
# repo scope
bash capture.sh --target gh-secret --scope repo --repo <owner/repo> --name <SECRET_NAME>
# org scope
bash capture.sh --target gh-secret --scope org --org <org> --name <SECRET_NAME>
# environment scope
bash capture.sh --target gh-secret --scope env --repo <owner/repo> --env <env-name> --name <SECRET_NAME>
```

Returns:
- repo: `gh-secret:<owner>/<repo>#<name>`
- org: `gh-secret:org/<org>#<name>`
- env: `gh-secret:<owner>/<repo>/env/<env>#<name>`

Use for GitHub Actions secrets.

### `wrangler`

```bash
bash capture.sh --target wrangler --worker <worker-name> --name <SECRET_NAME>
```

Returns: `wrangler-secret:<worker>#<name>`

Use for Cloudflare Workers secrets.

### `coolify`

```bash
bash capture.sh --target coolify --app-uuid <uuid> --key <ENV_VAR> [--build-time]
```

Returns: `coolify-env:<uuid>#<key>`

Uses Coolify REST directly (bypasses MCP — the MCP response echoes the value back into the transcript). Reads the Coolify URL + API token from the user's `~/.config/secret-capture/config.yaml`.

### `n8n`

```bash
bash capture.sh --target n8n --instance <instance-alias> --name <cred-name> --type <credential-type> [--data-field <field-name>]
```

Returns: `n8n-cred:<name> (id=<id>)`

Instance alias is looked up in the user's config (URL + API key). Credential type matches n8n's type name (e.g., `anthropicApi`, `httpHeaderAuth`, `openAiApi`).

### `env-file`

```bash
bash capture.sh --target env-file --file <path> --key <KEY_NAME>
```

Returns: `env-file:<path>#<key>`

Writes to a local `.env` file with mode 0600. Creates the file if missing.

### `ssh`

```bash
# KEY=VALUE into a remote dotenv / env file:
bash capture.sh --target ssh \
  --ssh-host <host> [--ssh-user <user>] \
  --mode file-kv --remote-path <remote-path> --key <KEY_NAME> [--chmod 600]

# Raw value into a remote file (PEM, cert, single-token):
bash capture.sh --target ssh \
  --ssh-host <host> [--ssh-user <user>] \
  --mode file-raw --remote-path <remote-path> [--chmod 600]
```

Returns:
- `file-kv` → `ssh-kv:<user>@<host>:<path>#<key>`
- `file-raw` → `ssh-file:<user>@<host>:<path>`

Use when you need to inject a secret into a remote server without reading it yourself. Common cases: dotenv on a VPS, docker-compose `.env`, systemd `EnvironmentFile=`, TLS key/cert drops, single-token files read by a daemon.

**Authentication:** uses your ssh-agent (1Password SSH Agent, system agent, or similar). No private key file is read. First-connect uses `StrictHostKeyChecking=accept-new`.

**Atomicity:** value is piped over ssh stdin, written to `<remote-path>.sc-new` with `umask 077`, chmod'd, then `mv`'d into place. No partial-write window.

**Security:** value never touches argv, env, or any shell variable. End-to-end pipe: local stdin → local temp (0600, shredded) → ssh stdin → remote `cat > .sc-new` → remote `mv`. Single quotes in the value (`file-kv` mode) are escaped via sed on the local side.

**Idempotency:** checks the remote file before writing. `file-kv` checks for the `KEY=` prefix; `file-raw` checks for file existence. Duplicate → `DUPLICATE` (exit 6) unless `--rotate` is passed.

## Rotation

Add `--rotate` to any invocation. The adapter switches from create → edit/update/overwrite. If the record doesn't exist, it fails with `NOT_FOUND`.

## Format validation

Pass `--expect <shape>` to sanity-check the captured value before writing:

```bash
bash capture.sh --target 1password --vault Personal --item openai-key --field credential --expect openai
```

Shapes supported out of the box: `openai`, `anthropic`, `github-pat`, `aws-access-key`, `stripe`, `cloudflare-token`, `slack`. On mismatch, the dialog reopens once; if still mismatch, returns `FORMAT_MISMATCH`.

## Return values

Every successful invocation prints **only a reference string** on stdout. The agent uses the reference to consume the secret later without ever seeing the value:

```bash
# Bad — the agent asks the user to paste the value
# Good — the agent invokes the skill, gets a reference, uses the reference
ref=$(bash capture.sh --target keychain --service anthropic-cli --account $(whoami))
# → ref = "keychain:anthropic-cli"
# Later, when consuming:
security find-generic-password -s anthropic-cli -w | some-cli --stdin
# The value flows through a pipe; the agent still never sees it.
```

## Error codes (stderr)

- `CANCELLED` — user cancelled the dialog
- `NO_GUI` — no window server and no TTY; run from a GUI session
- `TIMEOUT` — dialog auto-dismissed (osascript 2-min limit)
- `AUTH_FAIL` — destination auth failed; fix credentials and retry
- `DUPLICATE` — item exists; re-invoke with `--rotate` or pick a different name
- `FORMAT_MISMATCH` — `--expect` regex didn't match
- `ADAPTER_ERROR` — subcommand failed; check adapter preflight

None of these ever contain the value.

## Hygiene guarantees

- Value never on argv (readable via `ps`)
- Value never in env (readable via `/proc/<pid>/environ`)
- Value never in shell history
- Value never in any stdout the agent sees
- Tempfiles are 0600 and shredded on exit

## Do NOT

- **Never** ask the user to paste a secret into chat or the terminal
- **Never** construct a `curl` / CLI command that contains the value as an argument
- **Never** store the same secret in two places — pick 1Password OR the target system
- **Never** log the return value to a file that could be shared
- **Never** skip `--rotate` when overwriting — use it explicitly so the intent is logged

## Configuration

The skill reads `~/.config/secret-capture/config.yaml`. Users configure:
- Which adapters are enabled
- Default vault / account / scope
- Where to source API credentials the skill itself needs (Coolify API token, n8n API key) — via `keychain:`, `env:`, `file:`, `op:`, or `command:` sources
- Dialog timeout, TTY fallback, format validation strictness

See [config.example.yaml](../config.example.yaml) in the skill repo for the full shape.
