#!/usr/bin/env bash
# Adapter: Cloudflare Workers secret.
# Uses `wrangler secret bulk <file>` — the stdin form of `wrangler secret put` has been
# broken since 2022 (workers-sdk#1303). Tempfile is mode 0600 and shredded on exit.
#
# Stdout: wrangler-secret:<worker>#<name>

set -euo pipefail

WORKER=""
NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker) WORKER="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$WORKER" ]] && { echo "USAGE_ERROR: --worker required" >&2; exit 2; }
[[ -z "$NAME" ]]   && { echo "USAGE_ERROR: --name required" >&2; exit 2; }

umask 077
payload=$(mktemp -t sc-wrangler-XXXXXX)
cleanup() { shred -u "$payload" 2>/dev/null || rm -f "$payload"; }
trap cleanup EXIT

jq -n \
  --arg name "$NAME" \
  --rawfile v /dev/stdin \
  '{ ($name): ($v | rtrimstr("\n")) }' > "$payload"

wrangler secret bulk "$payload" --name "$WORKER" >/dev/null 2>&1 \
  || { echo "ADAPTER_ERROR: wrangler secret bulk failed" >&2; exit 7; }

printf 'wrangler-secret:%s#%s\n' "$WORKER" "$NAME"
