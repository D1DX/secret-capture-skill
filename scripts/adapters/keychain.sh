#!/usr/bin/env bash
# Adapter: macOS Keychain (login keychain).
# Uses `expect` to drive `security add-generic-password -w` interactively so the value
# never appears on argv of the `security` process. `expect` is preinstalled on macOS.
#
# Stdout: keychain:<service>

set -euo pipefail

SERVICE=""
ACCOUNT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SERVICE="$2"; shift 2 ;;
    --account) ACCOUNT="$2"; shift 2 ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$SERVICE" ]] && { echo "USAGE_ERROR: --service required" >&2; exit 2; }
[[ -z "$ACCOUNT" ]] && ACCOUNT="${USER}"

ROTATE="${ROTATE:-}"

if security find-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1; then
  if [[ -z "$ROTATE" ]]; then
    echo "DUPLICATE: keychain entry '$SERVICE' (account '$ACCOUNT') exists; pass --rotate to overwrite" >&2
    exit 6
  fi
fi

# SC_ACCOUNT and SC_SERVICE reach the expect process via env — they are NOT secrets.
# The value itself is read from expect's stdin and only lives in expect's Tcl memory.
if ! SC_ACCOUNT="$ACCOUNT" SC_SERVICE="$SERVICE" expect <<'TCL' >/dev/null 2>&1
log_user 0
set acc $env(SC_ACCOUNT)
set svc $env(SC_SERVICE)
set val [read stdin]
regsub {\n$} $val {} val
spawn -noecho /usr/bin/security add-generic-password -a $acc -s $svc -U -w
expect {
  -re {password (data )?for (new|existing) item:} {}
  timeout { exit 7 }
}
send -- "$val\r"
expect {
  -re {retype password for (new|existing) item:} { send -- "$val\r"; exp_continue }
  eof {}
  timeout { exit 7 }
}
set val ""
TCL
then
  echo "ADAPTER_ERROR: expect-driven 'security add-generic-password' failed" >&2
  exit 7
fi

printf 'keychain:%s\n' "$SERVICE"
