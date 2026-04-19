#!/usr/bin/env bash
# Adapter: 1Password item.
# Reads value from stdin. Creates a new item or, with --rotate, deletes+recreates.
# Stdout: op://<vault>/<item>/<field>
#
# Why delete+recreate on rotation: `op item edit` only accepts value assignments on argv,
# which would leak the value through `ps`. `op item create --template <path>` reads the JSON
# from a 0600 tempfile built by jq with `--rawfile v /dev/stdin`, so the value never touches
# argv or a shell variable.
#
# Why CATEGORY default is "API_CREDENTIAL" (not "API Credential"): op CLI requires the
# uppercase-underscore template ID. Get the canonical list via `op item template list`.

set -euo pipefail

VAULT=""
ITEM=""
FIELD="credential"
CATEGORY="API_CREDENTIAL"
TITLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault) VAULT="$2"; shift 2 ;;
    --item) ITEM="$2"; shift 2 ;;
    --field) FIELD="$2"; shift 2 ;;
    --category) CATEGORY="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$VAULT" ]] && { echo "USAGE_ERROR: --vault required" >&2; exit 2; }
[[ -z "$ITEM" ]]  && { echo "USAGE_ERROR: --item required" >&2; exit 2; }
[[ -z "$TITLE" ]] && TITLE="$ITEM"

ROTATE="${ROTATE:-}"

umask 077
payload=$(mktemp -t sc-1p-XXXXXX)
cleanup() { shred -u "$payload" 2>/dev/null || rm -f "$payload"; }
trap cleanup EXIT

if op item get "$ITEM" --vault "$VAULT" --format=json >/dev/null 2>&1; then
  if [[ -z "$ROTATE" ]]; then
    echo "DUPLICATE: item '$ITEM' exists in vault '$VAULT'; pass --rotate to overwrite" >&2
    exit 6
  fi
  op item delete "$ITEM" --vault "$VAULT" --archive >/dev/null 2>&1 \
    || { echo "ADAPTER_ERROR: failed to archive existing item for rotation" >&2; exit 7; }
fi

jq -n \
  --arg title "$TITLE" \
  --arg cat "$CATEGORY" \
  --arg field "$FIELD" \
  --rawfile v /dev/stdin \
  '{
     title: $title,
     category: $cat,
     fields: [
       { id: $field, label: $field, type: "CONCEALED", value: ($v | rtrimstr("\n")) }
     ]
   }' > "$payload"

op item create --vault "$VAULT" --template "$payload" </dev/null >/dev/null 2>&1 \
  || { echo "ADAPTER_ERROR: op item create failed" >&2; exit 7; }

printf 'op://%s/%s/%s\n' "$VAULT" "$ITEM" "$FIELD"
