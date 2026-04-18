#!/usr/bin/env bash
# Adapter: local .env file (dotenv format).
# Writes / updates a KEY=VALUE line in the target file. File mode locked to 0600.
# Idempotent: if KEY already exists, --rotate is required to overwrite.
#
# Stdout: env-file:<path>#<key>

set -euo pipefail

FILE=""
KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) FILE="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$FILE" ]] && { echo "USAGE_ERROR: --file required" >&2; exit 2; }
[[ -z "$KEY" ]]  && { echo "USAGE_ERROR: --key required" >&2; exit 2; }

FILE="${FILE/#\~/$HOME}"
ROTATE="${ROTATE:-}"

umask 077
if [[ ! -f "$FILE" ]]; then
  : > "$FILE"
fi
chmod 600 "$FILE" 2>/dev/null || true

exists=""
if grep -Eq "^${KEY}=" "$FILE" 2>/dev/null; then
  exists="1"
fi

if [[ -n "$exists" && -z "$ROTATE" ]]; then
  echo "DUPLICATE: $KEY already set in $FILE; pass --rotate to overwrite" >&2
  exit 6
fi

tmp=$(mktemp -t sc-env-XXXXXX)
cleanup() { shred -u "$tmp" 2>/dev/null || rm -f "$tmp"; }
trap cleanup EXIT

# Strip existing KEY= line (if any) from the file, then append KEY=VALUE from stdin.
# Value quoted with single quotes; single quotes in value are escaped via '\''.
awk -v key="$KEY" '
  $0 ~ "^" key "=" { next }
  { print }
' "$FILE" > "$tmp"

# Append new line — read value from stdin, escape single quotes, then write.
{
  cat "$tmp"
  printf "%s='" "$KEY"
  sed "s/'/'\\\\''/g"   # sed reads stdin, escapes any single quotes
  printf "'\n"
} > "${tmp}.new"

mv "${tmp}.new" "$FILE"
chmod 600 "$FILE"

printf 'env-file:%s#%s\n' "$FILE" "$KEY"
