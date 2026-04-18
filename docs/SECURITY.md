# Security model

`secret-capture` is designed so that a captured value **never appears in any agent tool result, log, chat transcript, or shell history**. This document enumerates the leak vectors the skill defends against, how each adapter defends against them, and the known residual risks.

## Threat model

The skill assumes:

- A trusted local user on a single macOS machine.
- A Claude Code (or similar) agent running in the same shell the user invoked the skill from, with the ability to read the skill's stdout and stderr.
- A possibly-adversarial other-UID process on the same machine (via `ps` / `/proc/<pid>/cmdline`).
- An adversarial *future* reader of shell history, log files, and process accounting.
- The destination system itself (1Password, GitHub, Cloudflare, Coolify, n8n) is trusted — if the destination is compromised, this skill offers no defense.

The skill does **not** defend against:

- A compromised dialog interceptor (malware running as the user).
- Memory dumps of the running `capture.sh` / adapter / `expect` / `jq` processes.
- The destination service leaking the value after the skill has written it.

## Leak vectors and mitigations

| Vector | Mitigation |
|---|---|
| **argv exposure** (`ps`, `/proc/<pid>/cmdline`) | Values never appear on argv. `jq --rawfile v /dev/stdin` reads from stdin; `curl -H @file --data @file` reads from files; `expect` drives `security` with the value sent over a pty (never argv). |
| **Environment inheritance** (`/proc/<pid>/environ`) | The value is never `export`ed. Only non-secret metadata (service names, accounts) is passed via env to subprocesses (e.g., `expect`). |
| **Shell history** | `capture.sh` sets `set +o history`, `HISTFILE=/dev/null`. No invocation ever contains the value as a literal. |
| **Stdout/stderr leakage to the agent transcript** | Every subcommand that could echo the value is redirected to `/dev/null`. The only stdout the caller ever sees is the reference string (`op://...`, `keychain:...`, etc). |
| **Tempfiles** | `umask 077` before any `mktemp`. Every tempfile is `trap`-cleaned on exit via `shred -u` (falling back to `rm -f`). |
| **Coolify response echo** | Coolify's REST API echoes the env var value in create/read responses. The adapter bypasses the Coolify MCP (whose response would enter the agent transcript) and uses `curl ... -o /dev/null` to discard the response. |
| **Wrangler stdin bug** | `wrangler secret put` has a broken stdin handler (cloudflare/workers-sdk#1303, open since 2022). The adapter uses `wrangler secret bulk <file>` with a 0600 tempfile, shredded on exit. |
| **n8n response echo** | The n8n public API redacts password-type fields in responses — safe to parse `.id` without value exposure. |
| **Dialog cancellation race** | osascript exits non-zero on cancel; adapter never runs because `set -o pipefail` aborts the pipeline. |

## Residual risks

1. **In-process memory**: the value lives briefly in the memory of `osascript`, `expect`, `jq`, `curl`, and the dialog `TextField`. Same-UID processes with access to `/proc/<pid>/mem` can read them during execution. The skill does not use `mlock`.
2. **Keychain-adapter argv of `security`**: argv is `[-a ACCOUNT -s SERVICE -U -w]` — the `-w` has no value because `expect` drives the interactive prompt. Verify with `ps -ax | grep security` during a write — you should see no value.
3. **Disk residue**: on the rare adapters that tempfile (`wrangler`, `coolify`, `n8n`, `env-file`), the tempfile lives for milliseconds before `shred`. An adversary with live fs access could snapshot it.
4. **osascript limits**: no GUI → skill hard-errors with `NO_GUI` (configurable). osascript auto-dismisses the dialog after 120s (`TIMEOUT`). SSH sessions without `launchctl asuser` cannot show a dialog.
5. **User-supplied `command:` source spec in config**: `command:<shell-fragment>` is evaluated via `bash -c`. The user controls this line in their own config file; it is not attacker-controlled unless the user's config file is.

## Verifying no leaks locally

During a write, in another terminal:

```bash
# Confirm no `security` argv leak (keychain adapter)
ps -axo args | grep 'security add-generic-password'   # should NOT contain the value

# Confirm no history entry
tail -n 1 ~/.zsh_history   # should not be the capture command

# Confirm shell history disabled in the capturing shell
echo "$HISTFILE"            # /dev/null
```

For curl-based adapters (`coolify`, `n8n`):

```bash
# Start mitmproxy or a local HTTPS intercept to confirm the request body is POSTed with the correct shape.
# The adapter never logs the request body.
```

## Reporting a vulnerability

If you discover a way the skill leaks a captured value, please open a GitHub issue tagged `security` — or, for sensitive disclosures, email the repo owner directly.
