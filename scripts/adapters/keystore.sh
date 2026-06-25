#!/usr/bin/env bash
# Adapter: keystore — age-encrypt the captured value to a recipient PUBLIC key, then
# ship the encrypted blob to a remote keystore host over SSH. The value is encrypted
# locally BEFORE it leaves the machine, so only ciphertext ever transits the network;
# the plaintext never lands on disk, on argv, in env, or on the remote host in the clear.
#
# The encrypted blob lands at  $KEYSTORE_DIR/<service>.age  on the keystore host. A
# separate runtime consumer (e.g. `keyrun`) decrypts it there with the matching age
# identity — that consumer is out of scope for this adapter, which only PROVISIONS.
#
# Flags (all deployment-specific values are env- or flag-driven — nothing is baked in):
#   --service <name>          key name; the blob is <service>.age. [a-z0-9_-]. Required.
#   --recipient <age1...>     age recipient PUBLIC key. Resolution order:
#                               --recipient > $KEYSTORE_RECIPIENT > $KEYSTORE_RECIPIENT_FILE
#                               > the host's $KEYSTORE_DIR/recipient.pub.
#   --keystore-host <host>    ssh host (or $KEYSTORE_HOST). Required.
#   --keystore-dir <dir>      remote dir (or $KEYSTORE_DIR, default /etc/keystore).
#   --keystore-group <group>  remote group (or $KEYSTORE_GROUP). When set, the blob is
#                             written 0640 root:<group> (group-readable by the consumer);
#                             when unset, 0600 root-only.
#   --ssh-user <user>         ssh user (else the host's ssh config default).
#
# Encryption needs ONLY the public recipient — no secret to provision. Idempotent:
# an existing <service>.age is left intact unless --rotate is passed.
#
# Stdout:  keystore:<target>:<dir>/<service>.age

set -euo pipefail

SERVICE=""
RECIPIENT=""
KS_HOST="${KEYSTORE_HOST:-}"
KS_DIR="${KEYSTORE_DIR:-/etc/keystore}"
KS_GROUP="${KEYSTORE_GROUP:-}"
SSH_USER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)        SERVICE="$2"; shift 2 ;;
    --recipient)      RECIPIENT="$2"; shift 2 ;;
    --keystore-host)  KS_HOST="$2"; shift 2 ;;
    --keystore-dir)   KS_DIR="$2"; shift 2 ;;
    --keystore-group) KS_GROUP="$2"; shift 2 ;;
    --ssh-user)       SSH_USER="$2"; shift 2 ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$SERVICE" ]] && { echo "USAGE_ERROR: --service required" >&2; exit 2; }
case "$SERVICE" in *[!a-z0-9_-]*) echo "USAGE_ERROR: --service must be [a-z0-9_-]" >&2; exit 2 ;; esac
[[ -z "$KS_HOST" ]] && { echo "USAGE_ERROR: --keystore-host or \$KEYSTORE_HOST required" >&2; exit 2; }

ROTATE="${ROTATE:-}"

command -v age >/dev/null 2>&1 \
  || { echo "ADAPTER_ERROR: 'age' not found (install: brew install age)" >&2; exit 7; }

# Resolve the recipient PUBLIC key (not a secret): flag > env > file.
[[ -z "$RECIPIENT" ]] && RECIPIENT="${KEYSTORE_RECIPIENT:-}"
if [[ -z "$RECIPIENT" && -n "${KEYSTORE_RECIPIENT_FILE:-}" && -r "${KEYSTORE_RECIPIENT_FILE}" ]]; then
  RECIPIENT="$(cat "$KEYSTORE_RECIPIENT_FILE")"
fi

# Build the ssh target.
if [[ -n "$SSH_USER" ]]; then
  SSH_TARGET="${SSH_USER}@${KS_HOST}"
else
  SSH_TARGET="$KS_HOST"
fi

# Common ssh options — mirror the ssh adapter:
#   -o BatchMode=no               allow agent prompt (1P SSH Agent, system agent)
#   -o ConnectTimeout=10          fail fast if host unreachable
#   -T                            no tty (stdin is the value / ciphertext)
SSH_OPTS=(-o BatchMode=no -o ConnectTimeout=10 -T)

# Last-resort recipient resolution: read the public recipient off the host.
# </dev/null so this ssh doesn't drain the script's stdin (which carries the value).
if [[ -z "$RECIPIENT" ]]; then
  RECIPIENT="$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "cat '$KS_DIR/recipient.pub' 2>/dev/null" </dev/null 2>/dev/null || true)"
fi

case "$RECIPIENT" in
  age1*) ;;
  *) echo "ADAPTER_ERROR: no valid age recipient (age1...) — set --recipient, \$KEYSTORE_RECIPIENT, \$KEYSTORE_RECIPIENT_FILE, or provide $KS_DIR/recipient.pub on $SSH_TARGET" >&2; exit 7 ;;
esac

# Connectivity preflight. </dev/null so it doesn't drain the value on stdin.
if ! ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'true' </dev/null >/dev/null 2>&1; then
  echo "ADAPTER_ERROR: cannot ssh to $SSH_TARGET (check host, agent, and reachability)" >&2
  exit 7
fi

blob="$KS_DIR/$SERVICE.age"

# Duplicate probe — does the blob already exist? </dev/null so it doesn't drain stdin.
set +e
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "test -f '$blob'" </dev/null
probe_rc=$?
set -e

if [[ "$probe_rc" -eq 0 && -z "$ROTATE" ]]; then
  echo "DUPLICATE: $blob already exists on $SSH_TARGET; pass --rotate to overwrite" >&2
  exit 6
fi

# Remote install command. Group-readable (0640 root:<group>) when a group is given so a
# group-member consumer can read it; else 0600 root-only. The dir is created idempotently.
if [[ -n "$KS_GROUP" ]]; then
  install_cmd="umask 077; sudo install -d -m 0750 -o root -g '$KS_GROUP' '$KS_DIR' 2>/dev/null; sudo tee '$blob' >/dev/null && sudo chgrp '$KS_GROUP' '$blob' && sudo chmod 640 '$blob' && echo OK"
else
  install_cmd="umask 077; sudo install -d -m 0700 -o root '$KS_DIR' 2>/dev/null; sudo tee '$blob' >/dev/null && sudo chmod 600 '$blob' && echo OK"
fi

# The one place the value moves: stdin (plaintext) -> age encrypt -> ssh -> remote tee.
# age reads the plaintext from this script's stdin and emits ciphertext; only ciphertext
# crosses the network. Value never on argv, in env, or in a shell variable.
result="$(age -r "$RECIPIENT" | ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$install_cmd")" \
  || { echo "ADAPTER_ERROR: encrypt/ship failed for '$SERVICE' on $SSH_TARGET" >&2; exit 7; }

[[ "$result" == *OK* ]] \
  || { echo "ADAPTER_ERROR: remote install did not confirm OK for '$SERVICE' on $SSH_TARGET" >&2; exit 7; }

printf 'keystore:%s:%s/%s.age\n' "$SSH_TARGET" "$KS_DIR" "$SERVICE"
