#!/usr/bin/env bash
# Adapter: n8n credential (via REST).
# Uses the n8n public API: POST /api/v1/credentials. Response redacts password-type
# fields — safe surface. Request body built via jq with --rawfile (never in argv).
#
# Stdout: n8n-cred:<name> (id=<id>)
#
# Config: defaults.n8n.instances.<alias>.url
#         defaults.n8n.instances.<alias>.api_key_source

set -euo pipefail

# shellcheck source=../lib/config.sh
source "${SKILL_ROOT:?SKILL_ROOT not set}/scripts/lib/config.sh"

INSTANCE=""
CRED_NAME=""
CRED_TYPE=""
DATA_FIELD="value"
FIELDS_JSON='{}'   # Extra non-secret fields for richer credential types.
                   # Example: --fields-json '{"name":"X-API-Key"}' merges into .data
                   # alongside the secret field. Good for httpHeaderAuth (needs a name +
                   # value), httpBasicAuth (needs user + password), oAuth2Api, etc.

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE="$2"; shift 2 ;;
    --name) CRED_NAME="$2"; shift 2 ;;
    --type) CRED_TYPE="$2"; shift 2 ;;
    --data-field) DATA_FIELD="$2"; shift 2 ;;
    --fields-json) FIELDS_JSON="$2"; shift 2 ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$INSTANCE" ]]  && { echo "USAGE_ERROR: --instance required" >&2; exit 2; }
[[ -z "$CRED_NAME" ]] && { echo "USAGE_ERROR: --name required" >&2; exit 2; }
[[ -z "$CRED_TYPE" ]] && { echo "USAGE_ERROR: --type required (e.g. anthropicApi, httpHeaderAuth)" >&2; exit 2; }

URL=$(config_get "defaults.n8n.instances.${INSTANCE}.url")
[[ -n "$URL" ]] || { echo "CONFIG_ERROR: defaults.n8n.instances.${INSTANCE}.url not set" >&2; exit 9; }

API_KEY_SOURCE=$(config_get "defaults.n8n.instances.${INSTANCE}.api_key_source")
[[ -n "$API_KEY_SOURCE" ]] || { echo "CONFIG_ERROR: defaults.n8n.instances.${INSTANCE}.api_key_source not set" >&2; exit 9; }

umask 077
body=$(mktemp -t sc-n8n-body-XXXXXX)
auth=$(mktemp -t sc-n8n-auth-XXXXXX)
out=$(mktemp -t sc-n8n-out-XXXXXX)
cleanup() {
  shred -u "$body" "$auth" "$out" 2>/dev/null || true
  rm -f "$body" "$auth" "$out"
}
trap cleanup EXIT

{ printf 'X-N8N-API-KEY: '; resolve_source "$API_KEY_SOURCE"; printf '\n'; } > "$auth"

jq -n \
  --arg name "$CRED_NAME" \
  --arg type "$CRED_TYPE" \
  --arg field "$DATA_FIELD" \
  --argjson extra "$FIELDS_JSON" \
  --rawfile v /dev/stdin \
  '{
    name: $name,
    type: $type,
    data: ($extra + { ($field): ($v | rtrimstr("\n")) })
  }' > "$body"

http_code=$(curl -sS -X POST \
  "${URL%/}/api/v1/credentials" \
  -H @"$auth" \
  -H 'content-type: application/json' \
  --data @"$body" \
  -o "$out" -w "%{http_code}")

if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
  echo "ADAPTER_ERROR: n8n HTTP $http_code" >&2
  exit 7
fi

# n8n response redacts password-type fields — safe to parse .id out of the response.
cred_id=$(jq -r '.id // empty' "$out" 2>/dev/null || true)

if [[ -z "$cred_id" ]]; then
  echo "ADAPTER_ERROR: n8n response missing credential id" >&2
  exit 7
fi

printf 'n8n-cred:%s (id=%s)\n' "$CRED_NAME" "$cred_id"
