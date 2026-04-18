#!/usr/bin/env bash
# Format validation — optional regex check against a named pattern in patterns/common.yaml.

: "${SC_PATTERNS_FILE:=$SKILL_ROOT/patterns/common.yaml}"
: "${SC_USER_PATTERNS_FILE:=$HOME/.config/secret-capture/patterns.yaml}"

# lookup_pattern <name>
# Emits the regex to stdout, or exits non-zero if not found.
lookup_pattern() {
  local name="$1" regex=""
  _yq_available || { echo "ADAPTER_ERROR: 'yq' required for --expect" >&2; return 7; }
  if [[ -f "$SC_USER_PATTERNS_FILE" ]]; then
    regex=$(yq -r ".patterns.${name}.regex // \"\"" "$SC_USER_PATTERNS_FILE" 2>/dev/null || true)
  fi
  if [[ -z "$regex" || "$regex" == "null" ]]; then
    regex=$(yq -r ".patterns.${name}.regex // \"\"" "$SC_PATTERNS_FILE" 2>/dev/null || true)
  fi
  if [[ -z "$regex" || "$regex" == "null" ]]; then
    echo "FORMAT_MISMATCH: unknown pattern '$name'" >&2
    return 5
  fi
  printf '%s' "$regex"
}

# validate_and_forward <pattern-name>
# Reads value from stdin. If it matches the pattern, emits to stdout. Else exits 5.
validate_and_forward() {
  local pattern="$1" regex buf
  regex=$(lookup_pattern "$pattern") || return 5
  IFS= read -r -d '' buf || true
  if [[ "$buf" =~ ^${regex}$ ]]; then
    printf '%s' "$buf"
    buf=""
  else
    buf=""
    echo "FORMAT_MISMATCH: value does not match '$pattern'" >&2
    return 5
  fi
}
