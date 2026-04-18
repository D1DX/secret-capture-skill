#!/usr/bin/env bash
# secret-capture — entry script.
#
# Parses --target and adapter flags, loads config, runs preflight, then invokes
# the adapter in a single subshell with the dialog-captured value piped into it.
# The only thing this script emits on stdout is the adapter's reference string.

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SKILL_ROOT

# shellcheck source=lib/hygiene.sh
source "$SKILL_ROOT/scripts/lib/hygiene.sh"
# shellcheck source=lib/dialog.sh
source "$SKILL_ROOT/scripts/lib/dialog.sh"
# shellcheck source=lib/config.sh
source "$SKILL_ROOT/scripts/lib/config.sh"
# shellcheck source=lib/preflight.sh
source "$SKILL_ROOT/scripts/lib/preflight.sh"
# shellcheck source=lib/validate.sh
source "$SKILL_ROOT/scripts/lib/validate.sh"

usage() {
  cat >&2 <<'USAGE'
secret-capture — capture a secret via hidden-input dialog and route it to a destination.

Usage:
  capture.sh --target <target> [target-flags] [--rotate] [--expect <shape>] [--prompt <label>]

Targets: 1password | keychain | gh-secret | wrangler | coolify | n8n | env-file

See SKILL.md for target-specific flags, or the README for examples.
USAGE
}

TARGET=""
ROTATE=""
EXPECT=""
PROMPT_LABEL=""
ADAPTER_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --rotate) ROTATE="1"; shift ;;
    --expect) EXPECT="$2"; shift 2 ;;
    --prompt) PROMPT_LABEL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*)
      if [[ $# -ge 2 && "${2:0:2}" != "--" ]]; then
        ADAPTER_ARGS+=("$1" "$2"); shift 2
      else
        ADAPTER_ARGS+=("$1"); shift
      fi
      ;;
    *)
      echo "USAGE_ERROR: unexpected arg '$1'" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  usage
  exit 2
fi

ADAPTER_SCRIPT="$SKILL_ROOT/scripts/adapters/${TARGET}.sh"
[[ -f "$ADAPTER_SCRIPT" ]] \
  || { echo "USAGE_ERROR: unknown target '$TARGET'" >&2; exit 2; }

config_adapter_enabled "$TARGET" \
  || { echo "DISABLED: '$TARGET' is not in adapters.enabled" >&2; exit 2; }

preflight_check "$TARGET" || exit $?

[[ -z "$PROMPT_LABEL" ]] && PROMPT_LABEL="$TARGET"

# Single subshell: dialog -> (optional validate) -> adapter.
# Only the adapter's reference line reaches the caller's stdout.
if [[ -n "$EXPECT" ]]; then
  dialog_capture "$PROMPT_LABEL" \
    | validate_and_forward "$EXPECT" \
    | ROTATE="$ROTATE" SKILL_ROOT="$SKILL_ROOT" bash "$ADAPTER_SCRIPT" ${ADAPTER_ARGS[@]+"${ADAPTER_ARGS[@]}"}
else
  dialog_capture "$PROMPT_LABEL" \
    | ROTATE="$ROTATE" SKILL_ROOT="$SKILL_ROOT" bash "$ADAPTER_SCRIPT" ${ADAPTER_ARGS[@]+"${ADAPTER_ARGS[@]}"}
fi
