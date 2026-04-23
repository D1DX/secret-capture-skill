#!/usr/bin/env bash
# Adapter: SSH — inject a secret into a remote host via SSH without the value
# ever appearing in argv, env, shell variables, or the agent transcript.
#
# Two modes:
#   file-kv   Write `KEY='value'` to a remote dotenv-style file. Idempotent;
#             --rotate required to overwrite an existing KEY. Default chmod 600.
#   file-raw  Write the raw value (no KEY=) to a remote file. For PEM, cert,
#             single-token destinations. --rotate required to overwrite.
#
# The value is piped end-to-end: capture.sh's tempfile → this script's stdin →
# local tempfile (0600, shredded) → ssh stdin → remote `cat > tempfile` → remote atomic mv.
# Never in argv, env, or shell variable.
#
# Authentication: relies on your ssh-agent (1Password SSH Agent, system agent,
# or similar). No private key file is ever read by this adapter. If the SSH
# connection can't be established, the adapter fails fast with ADAPTER_ERROR.
#
# Stdout:
#   file-kv  → `ssh-kv:<user>@<host>:<path>#<key>`
#   file-raw → `ssh-file:<user>@<host>:<path>`

set -euo pipefail

SSH_HOST=""
SSH_USER=""
MODE=""
REMOTE_PATH=""
KEY=""
CHMOD="600"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-host)    SSH_HOST="$2"; shift 2 ;;
    --ssh-user)    SSH_USER="$2"; shift 2 ;;
    --mode)        MODE="$2"; shift 2 ;;
    --remote-path) REMOTE_PATH="$2"; shift 2 ;;
    --key)         KEY="$2"; shift 2 ;;
    --chmod)       CHMOD="$2"; shift 2 ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$SSH_HOST" ]]    && { echo "USAGE_ERROR: --ssh-host required" >&2; exit 2; }
[[ -z "$MODE" ]]        && { echo "USAGE_ERROR: --mode required (file-kv|file-raw)" >&2; exit 2; }
[[ -z "$REMOTE_PATH" ]] && { echo "USAGE_ERROR: --remote-path required" >&2; exit 2; }

case "$MODE" in
  file-kv|file-raw) ;;
  *) echo "USAGE_ERROR: --mode must be 'file-kv' or 'file-raw' (got '$MODE')" >&2; exit 2 ;;
esac

if [[ "$MODE" == "file-kv" ]] && [[ -z "$KEY" ]]; then
  echo "USAGE_ERROR: --key required for --mode file-kv" >&2
  exit 2
fi

case "$CHMOD" in
  [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
  *) echo "USAGE_ERROR: --chmod must be an octal mode like 600 or 0600 (got '$CHMOD')" >&2; exit 2 ;;
esac

ROTATE="${ROTATE:-}"

# Build the SSH target — user@host form if user given.
if [[ -n "$SSH_USER" ]]; then
  SSH_TARGET="${SSH_USER}@${SSH_HOST}"
else
  SSH_TARGET="$SSH_HOST"
fi

# Common ssh options:
#   -o BatchMode=no               — allow agent prompt (1P SSH Agent, system agent)
#   -o ConnectTimeout=10          — fail fast if host unreachable
#   -o StrictHostKeyChecking=accept-new — first-use auto-accept; change if you prefer paranoid
#   -T                            — no tty allocation (stdin is the secret)
SSH_OPTS=(-o BatchMode=no -o ConnectTimeout=10 -T)

# Connectivity preflight: a trivial remote command. If this fails, everything else will too.
# </dev/null so ssh doesn't drain the stdin pipe (which carries the secret value).
if ! ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'true' </dev/null >/dev/null 2>&1; then
  echo "ADAPTER_ERROR: cannot ssh to $SSH_TARGET (check host, agent, and reachability)" >&2
  exit 7
fi

umask 077

case "$MODE" in

  file-kv)
    # Existence probe — remote grep for the KEY. Exit status is what we care about.
    # 0 = key found; 1 = file missing or key not present; anything else = remote error.
    # </dev/null so the probe ssh doesn't drain the script's stdin (which has the value).
    set +e
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "grep -Eq '^${KEY}=' '$REMOTE_PATH' 2>/dev/null" </dev/null
    probe_rc=$?
    set -e

    if [[ "$probe_rc" -eq 0 && -z "$ROTATE" ]]; then
      echo "DUPLICATE: $KEY already set in $REMOTE_PATH on $SSH_TARGET; pass --rotate to overwrite" >&2
      exit 6
    fi

    # Pull current remote file content (or empty). Strip any existing KEY= line.
    current=$(mktemp -t sc-ssh-current-XXXXXX)
    stripped=$(mktemp -t sc-ssh-stripped-XXXXXX)
    trimmed=$(mktemp -t sc-ssh-trimmed-XXXXXX)
    combined=$(mktemp -t sc-ssh-combined-XXXXXX)
    cleanup_kv() { shred -u "$current" "$stripped" "$trimmed" "$combined" 2>/dev/null || rm -f "$current" "$stripped" "$trimmed" "$combined"; }
    trap cleanup_kv EXIT

    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "cat '$REMOTE_PATH' 2>/dev/null || true" </dev/null > "$current"

    awk -v key="$KEY" '$0 ~ "^" key "=" { next } { print }' "$current" > "$stripped"

    # Capture the value from stdin into a tempfile, stripping the trailing newline
    # that the dialog/pipeline appends. file-kv values must be single-line (dotenv
    # constraint) — if you need multi-line values, use --mode file-raw instead.
    # Uses awk to preserve internal newlines through read but chomp the last one.
    # `RS="\x00"` makes awk consume the whole stream as one record.
    awk 'BEGIN { RS="\x00" } { sub(/\n+$/, ""); printf "%s", $0 }' > "$trimmed"

    # Build the final file: stripped content + new KEY=value line (unquoted).
    # Docker env_file, Python dotenv, and most env parsers read values literally —
    # shell-quoting (KEY='value') makes the quotes part of the value. Write bare.
    # Values containing spaces or special chars are the caller's responsibility;
    # for shell-sourced files, strip and re-add quotes in the consuming script.
    {
      cat "$stripped"
      printf "%s=" "$KEY"
      cat "$trimmed"
      printf "\n"
    } > "$combined"

    # Atomic remote write: upload to temp, chmod, mv into place.
    # The `.sc-new` suffix is predictable but is only on disk for the duration of ssh call.
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
      "umask 077 && cat > '${REMOTE_PATH}.sc-new' && chmod $CHMOD '${REMOTE_PATH}.sc-new' && mv '${REMOTE_PATH}.sc-new' '$REMOTE_PATH'" \
      < "$combined" \
      || { echo "ADAPTER_ERROR: remote write failed on $SSH_TARGET:$REMOTE_PATH" >&2; exit 7; }

    printf 'ssh-kv:%s:%s#%s\n' "$SSH_TARGET" "$REMOTE_PATH" "$KEY"
    ;;

  file-raw)
    # Existence probe — does the file exist?
    # </dev/null so the probe ssh doesn't drain the script's stdin.
    set +e
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "test -f '$REMOTE_PATH'" </dev/null
    probe_rc=$?
    set -e

    if [[ "$probe_rc" -eq 0 && -z "$ROTATE" ]]; then
      echo "DUPLICATE: $REMOTE_PATH already exists on $SSH_TARGET; pass --rotate to overwrite" >&2
      exit 6
    fi

    # Atomic remote write: stdin → remote temp → chmod → mv.
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
      "umask 077 && cat > '${REMOTE_PATH}.sc-new' && chmod $CHMOD '${REMOTE_PATH}.sc-new' && mv '${REMOTE_PATH}.sc-new' '$REMOTE_PATH'" \
      || { echo "ADAPTER_ERROR: remote write failed on $SSH_TARGET:$REMOTE_PATH" >&2; exit 7; }

    printf 'ssh-file:%s:%s\n' "$SSH_TARGET" "$REMOTE_PATH"
    ;;

esac
