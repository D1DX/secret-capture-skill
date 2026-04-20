#!/usr/bin/env bash
# secret-capture — entry script.
#
# Parses --target and adapter flags, loads config, runs preflight, then invokes
# the adapter in a single subshell with the dialog-captured value piped into it.
# The only thing this script emits on stdout is the adapter's reference string.
#
# Exit codes (every error is also tagged on stderr with its NAMED CODE):
#   0  — success
#   2  — USAGE_ERROR        (bad args, unknown target, target not enabled in config)
#   3  — NO_GUI             (no WindowServer + no TTY)
#   4  — CANCELLED          (user dismissed dialog or Ctrl-C at TTY)
#   5  — FORMAT_MISMATCH    (--expect regex didn't match)
#   6  — DUPLICATE          (record exists at destination, --rotate not passed)
#   7  — ADAPTER_ERROR      (subcommand non-zero / missing tool)
#   8  — AUTH_FAIL          (op not signed in / gh auth expired / destination 401)
#   9  — CONFIG_ERROR       (required config field missing in ~/.config/secret-capture/config.yaml)

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

Targets: 1password | keychain | gh-secret | wrangler | coolify | n8n | env-file | ssh

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

# A1 — rotation confirmation prompt (opt-in via config).
# hygiene.require_rotation_confirm=true in ~/.config/secret-capture/config.yaml
# asks "rotate <target>? (y/N)" on /dev/tty before running the destructive
# side of a --rotate. Useful for shared items where a mistaken rotation
# would require recovery (e.g. 1P archive restore + token reissue at source).
if [[ -n "$ROTATE" ]]; then
  if [[ "$(config_get hygiene.require_rotation_confirm false)" == "true" ]] && [[ -e /dev/tty ]]; then
    printf 'Rotate %s? This overwrites the existing record. (y/N): ' "$TARGET" > /dev/tty
    read -r reply < /dev/tty || reply=""
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      echo "CANCELLED: rotation confirmation declined" >&2
      exit 4
    fi
  fi
fi

[[ -z "$PROMPT_LABEL" ]] && PROMPT_LABEL="$TARGET"

# Two-stage capture:
#   1. dialog_capture → 0600 tempfile (exit code CHECKED before continuing)
#   2. optional validate → same tempfile
#   3. adapter reads from tempfile via stdin redirect
#
# Why: if dialog_capture is piped directly to the adapter, a CANCELLED dialog
# (exit 4, empty stdout) still lets the adapter run with empty input and
# possibly write an empty value at the destination before pipefail aborts.
# Gating on the dialog's exit code BEFORE the adapter runs closes that gap.
# Tempfile is 0600, shredded on exit — same threat model as the adapter
# tempfiles (wrangler/coolify/n8n all already do this).

umask 077
valfile=$(mktemp -t sc-value-XXXXXX)
cleanup_value() { shred -u "$valfile" 2>/dev/null || rm -f "$valfile"; }
trap cleanup_value EXIT

dialog_capture "$PROMPT_LABEL" > "$valfile" || exit $?

if [[ -n "$EXPECT" ]]; then
  # A2 — one retry on FORMAT_MISMATCH. Rationale: a single stray character
  # (trailing space, accidental prefix) is the common cause; forcing the
  # user to re-invoke the whole skill for a typo-grade mistake is friction.
  # Two attempts total — first failure reopens the dialog, second failure
  # exits FORMAT_MISMATCH.
  valfile_validated=$(mktemp -t sc-value-v-XXXXXX)
  trap 'shred -u "$valfile" "$valfile_validated" 2>/dev/null || rm -f "$valfile" "$valfile_validated"' EXIT
  if ! validate_and_forward "$EXPECT" < "$valfile" > "$valfile_validated" 2>/dev/null; then
    echo "FORMAT_MISMATCH: value does not match '$EXPECT' — reopening dialog once" >&2
    dialog_capture "$PROMPT_LABEL" > "$valfile" || exit $?
    validate_and_forward "$EXPECT" < "$valfile" > "$valfile_validated" || exit $?
  fi
  mv "$valfile_validated" "$valfile"
fi

ROTATE="$ROTATE" SKILL_ROOT="$SKILL_ROOT" bash "$ADAPTER_SCRIPT" ${ADAPTER_ARGS[@]+"${ADAPTER_ARGS[@]}"} < "$valfile"
