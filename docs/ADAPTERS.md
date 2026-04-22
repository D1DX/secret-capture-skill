# Adapter spec

An adapter is a bash script in `scripts/adapters/<name>.sh` that reads a secret from stdin, writes it to exactly one destination, and prints a reference string on stdout. The value never appears anywhere else.

## Contract

### Input

The adapter receives the secret value on **stdin**. It must read it exactly once, into a variable or tempfile, and never echo it back.

```bash
value=$(cat -)   # read once; never echo
```

### Output

Stdout: a single reference string identifying where the value was written. Nothing else.

```
op://Personal/openai-key/credential
keychain:my-service
wrangler-secret:my-worker#OPENAI_KEY
```

Stderr: human-readable status messages only. Never the value.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | `ADAPTER_ERROR` — subcommand failed |
| 2 | `DUPLICATE` — item exists and `--rotate` was not passed |
| 3 | `AUTH_FAIL` — destination rejected credentials |
| 4 | `NOT_FOUND` — `--rotate` passed but item does not exist |

Emit the code name on stderr before exiting: `echo "DUPLICATE" >&2`.

### Hygiene invariants (enforced by lint)

Every adapter must satisfy all of the following. `scripts/lint-adapters.sh` checks them automatically.

| Invariant | Rule |
|---|---|
| **No argv** | Never pass the value as a command-line argument. Use `--rawfile /dev/stdin` (jq), `@-` (curl), or a 0600 tempfile. |
| **No env export** | Never `export` a variable containing the value. |
| **No stdout of value** | Redirect every subcommand that could echo the value to `/dev/null`. |
| **Tempfile hygiene** | Use `umask 077` before `mktemp`. Register `trap 'shred -u "$tmp" 2>/dev/null \|\| rm -f "$tmp"' EXIT` immediately after creation. |
| **No history** | `capture.sh` sets `HISTFILE=/dev/null` globally, but adapters must not re-enable history. |

### xtrace guard

If the value is ever held in a shell variable, wrap that block:

```bash
_xt=$(set +o | grep xtrace); set +x
# ... value-touching code ...
eval "$_xt"
```

This prevents `bash -x` debugging from leaking the value to stderr.

## File layout

```
scripts/adapters/<name>.sh
```

Begin with a comment block:

```bash
# adapter: <name>
# Destination: <what it writes to>
# Requires: <tools / credentials needed>
# Stdout: <reference format>
```

Source `scripts/lib/hygiene.sh` for shared helpers:

```bash
SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/hygiene.sh
source "$SKILL_ROOT/scripts/lib/hygiene.sh"
```

## Preflight

Before touching stdin, validate that required tools and credentials are present. Use `scripts/lib/preflight.sh` helpers. Fail early with a clear message rather than letting the subcommand produce a cryptic error after the value has been read.

## Reference format

Choose a URI-like format that:
- Uniquely identifies the stored item
- Is sufficient for the consumer to retrieve the value later without re-prompting
- Contains no sensitive data

Follow the formats established by existing adapters (`op://`, `keychain:`, `wrangler-secret:`, etc.) where a convention already exists.

## Adding to lint

`scripts/lint-adapters.sh` auto-discovers all files matching `scripts/adapters/*.sh`. No registration required — adding the file is sufficient.

## Testing

Smoke-test your adapter against a throwaway destination before opening a PR:

1. Run with a dummy value and confirm: (a) the reference is printed, (b) the value does not appear in stdout or stderr, (c) no tempfile is left behind.
2. Run with `--rotate` against an existing item and confirm idempotent overwrite.
3. Run with `bash -x` and confirm the value does not appear in the xtrace output.
4. Run `scripts/lint-adapters.sh` and confirm 0 violations.