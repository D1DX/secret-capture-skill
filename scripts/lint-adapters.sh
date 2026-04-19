#!/usr/bin/env bash
# Static check: every adapter must never put a secret value on argv, in an
# exported env var, or emit it to stdout/stderr outside of the reference line.
# Run after any adapter edit; also wired into the optional install-time check.
#
# Exit 0 — all adapters clean.
# Exit 1 — one or more violations; lines printed on stderr.

set -euo pipefail

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER_DIR="$SKILL_ROOT/scripts/adapters"

violations=0

# Forbidden regexes. Key is a short name, value is a bash-ERE pattern.
declare -a patterns=(
  # Literal value on argv via the --body / --value / --data flag.
  '--body[ =]"?\$' 'value flag with direct expansion'
  '--value[ =]"?\$' 'value flag with direct expansion'
  '--data[ =]"?\$\{?[A-Za-z_]' 'data flag with shell var (use --data @file or --rawfile)'
  # `-w $VAR` (macOS security and similar).
  '-w[ =]\$[A-Za-z_]' 'inline -w with shell var (use expect/pty or stdin)'
  # export of a value (leaks via /proc/<pid>/environ).
  '^[[:space:]]*export[[:space:]]+[A-Z_]+=\$\(' 'export of $(...) — leaks via env'
  # `password=$VAR` inline assignment to op item create — leaks via argv.
  'password=\$[A-Za-z_]' 'op password= assignment on argv'
  'token=\$[A-Za-z_]' 'op token= assignment on argv'
  'credential=\$[A-Za-z_]' 'op credential= assignment on argv'
  # `echo "$VALUE"` that could reach stdout.
  '^[[:space:]]*echo[[:space:]]+"?\$[A-Za-z_]+"?[[:space:]]*$' 'bare echo of a shell var'
  # printf of a variable to stdout (if it's the capture value).
  'printf[[:space:]]+"\%s"[[:space:]]+"?\$[A-Za-z_]*VALUE' 'printf of a *VALUE variable'
)

emit() {
  echo "FAIL: $1"
  echo "   file: $2"
  echo "   line: $3"
  echo "   text: $4"
  echo
}

# Iterate patterns two at a time (regex, description).
n=${#patterns[@]}
for ((i=0; i<n; i+=2)); do
  re="${patterns[i]}"
  desc="${patterns[i+1]}"
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    lineno="${rest%%:*}"
    text="${rest#*:}"
    emit "$desc" "$file" "$lineno" "$text"
    violations=$((violations+1))
  done < <(grep -nE "$re" "$ADAPTER_DIR"/*.sh 2>/dev/null || true)
done

# Positive checks: every adapter should redirect op/curl/wrangler success to /dev/null.
for f in "$ADAPTER_DIR"/*.sh; do
  name=$(basename "$f" .sh)
  case "$name" in
    env-file|keychain) continue ;;  # no network call / no response echo to worry about
  esac
  # Look for op item create/edit or curl or wrangler invocations NOT followed by >/dev/null
  # (rough check — prints a WARN, not a FAIL).
  while IFS=: read -r lineno text; do
    [[ -z "$lineno" ]] && continue
    # Skip comment lines (matching only documentation of the pattern).
    [[ "$text" =~ ^[[:space:]]*# ]] && continue
    # Skip error-branch reporting lines (`|| { echo "ADAPTER_ERROR..." }`).
    [[ "$text" =~ ADAPTER_ERROR ]] && continue
    if [[ "$text" =~ (op\ item\ (create|edit)|curl\ -[sS]|wrangler\ secret) ]] \
       && ! [[ "$text" =~ /dev/null ]]; then
      # Multi-line command — check next 10 lines (covers curl with backslashes).
      end=$((lineno+10))
      window=$(sed -n "${lineno},${end}p" "$f")
      [[ "$window" =~ /dev/null ]] && continue
      [[ "$window" == *'http_code='* ]] && continue  # n8n captures code separately
      echo "WARN: potential un-redirected command"
      echo "   file: $f"
      echo "   line: $lineno"
      echo "   text: $text"
      echo
    fi
  done < <(grep -nE '(op item (create|edit)|curl -[sS]|wrangler secret)' "$f" 2>/dev/null || true)
done

if (( violations > 0 )); then
  echo "lint-adapters: $violations violation(s) across adapters" >&2
  exit 1
fi

echo "lint-adapters: OK ($(ls "$ADAPTER_DIR"/*.sh | wc -l | tr -d ' ') adapters checked, 0 violations)"
exit 0
