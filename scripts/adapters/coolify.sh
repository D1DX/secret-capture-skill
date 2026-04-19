#!/usr/bin/env bash
# Adapter: Coolify application env var.
# Uses Coolify REST directly — the Coolify MCP response body echoes the env var value
# back, which would leak into the agent's tool_result. Shell + curl + >/dev/null avoids that.
#
# Stdout: coolify-env:<app-uuid>#<key>
#
# Config (~/.config/secret-capture/config.yaml):
#   defaults.coolify.url            — Coolify base URL
#   defaults.coolify.api_key_source — where to read the Coolify API token from

set -euo pipefail

# shellcheck source=../lib/config.sh
source "${SKILL_ROOT:?SKILL_ROOT not set}/scripts/lib/config.sh"

APP_UUID=""
KEY=""
IS_PREVIEW="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-uuid) APP_UUID="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --preview) IS_PREVIEW="true"; shift ;;
    # --build-time dropped: Coolify API (v4.0.0-beta.471) returns 422
    # "is_build_time: This field is not allowed" on the envs POST endpoint.
    # The stored record has an `is_buildtime` field (one word), defaulting to
    # true, but it's not settable via POST. Use Coolify UI if you need to
    # control it per variable.
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$APP_UUID" ]] && { echo "USAGE_ERROR: --app-uuid required" >&2; exit 2; }
[[ -z "$KEY" ]]      && { echo "USAGE_ERROR: --key required" >&2; exit 2; }

ROTATE="${ROTATE:-}"

COOLIFY_URL=$(config_get "defaults.coolify.url")
[[ -n "$COOLIFY_URL" ]] || { echo "CONFIG_ERROR: defaults.coolify.url not set" >&2; exit 9; }

API_KEY_SOURCE=$(config_get "defaults.coolify.api_key_source")
[[ -n "$API_KEY_SOURCE" ]] || { echo "CONFIG_ERROR: defaults.coolify.api_key_source not set" >&2; exit 9; }

umask 077
body=$(mktemp -t sc-coolify-body-XXXXXX)
auth=$(mktemp -t sc-coolify-auth-XXXXXX)
cleanup() {
  shred -u "$body" "$auth" 2>/dev/null || true
  rm -f "$body" "$auth"
}
trap cleanup EXIT

# Build auth header file without ever holding the token in a shell variable.
{ printf 'authorization: Bearer '; resolve_source "$API_KEY_SOURCE"; printf '\n'; } > "$auth"

# Build the POST body: key, value (from stdin), scoping flags.
jq -n \
  --arg k "$KEY" \
  --rawfile v /dev/stdin \
  --argjson pre "$IS_PREVIEW" \
  '{ key: $k, value: ($v | rtrimstr("\n")), is_preview: $pre }' > "$body"

METHOD="POST"
if [[ -n "$ROTATE" ]]; then
  METHOD="PATCH"
fi

# Response discarded entirely — Coolify echoes the value back in both create and get.
curl -sS -X "$METHOD" \
  "${COOLIFY_URL%/}/api/v1/applications/${APP_UUID}/envs" \
  -H @"$auth" \
  -H 'content-type: application/json' \
  --data @"$body" \
  -o /dev/null -w "%{http_code}\n" 2>/dev/null \
  | awk '{ if ($1 < 200 || $1 >= 300) { print "ADAPTER_ERROR: Coolify HTTP " $1 > "/dev/stderr"; exit 7 } }'

printf 'coolify-env:%s#%s\n' "$APP_UUID" "$KEY"
