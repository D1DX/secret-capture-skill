#!/usr/bin/env bash
# Adapter: macOS Keychain (login keychain).
# Feeds `security -i` the add-generic-password command on stdin so the value never appears
# on argv of the `security` process.
#
# Flags:
#   --service <name>   keychain service name (required)
#   --account <name>   keychain account (default: $USER)
#   --silent-read      grant Apple-signed command-line tools (e.g. /usr/bin/security)
#                      silent, non-interactive read access to this item by setting its
#                      ACL partition list to `apple-tool:,apple:`. Use for secrets read
#                      by a background process (an MCP-launch wrapper, a cron job). Without
#                      it, the first non-interactive read pops a blocking Keychain auth
#                      dialog and fails ("auth prompt dismissed"). Setting the ACL requires
#                      unlocking the keychain, so this prompts once for the login password.
#
# Stdout: keychain:<service>

set -euo pipefail

SERVICE=""
ACCOUNT=""
SILENT_READ=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SERVICE="$2"; shift 2 ;;
    --account) ACCOUNT="$2"; shift 2 ;;
    --silent-read) SILENT_READ=1; shift ;;
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

# SC_ACCOUNT and SC_SERVICE reach python via env — they are NOT secrets. The value is read
# from stdin and handed to `security -i` as one command line on ITS stdin, so it lives only
# in python's memory and that pipe. The interactive `-w` prompt is not used: it cuts a
# password at 128 bytes. A value `security -i` cannot quote (whitespace, `"`, `\`) is refused.
set +e
SC_ACCOUNT="$ACCOUNT" SC_SERVICE="$SERVICE" python3 -c '
import os, subprocess, sys
val = sys.stdin.read()
if val.endswith("\n"):
    val = val[:-1]
if not val:
    sys.exit(8)
if any(c in val for c in "\"\\ \t\r\n"):
    sys.exit(9)
line = "add-generic-password -a \"%s\" -s \"%s\" -U -w \"%s\"\n" % (
    os.environ["SC_ACCOUNT"], os.environ["SC_SERVICE"], val)
out = subprocess.run(["/usr/bin/security", "-i"], input=line, text=True, capture_output=True)
sys.exit(0 if out.returncode == 0 and not out.stderr.strip() else 7)
' >/dev/null 2>&1
rc=$?
set -e
case "$rc" in
  0) ;;
  8) echo "ADAPTER_ERROR: empty value; nothing stored" >&2; exit 7 ;;
  9) echo "ADAPTER_ERROR: value holds whitespace, a quote or a backslash; the keychain adapter cannot store it" >&2; exit 7 ;;
  *) echo "ADAPTER_ERROR: 'security add-generic-password' failed" >&2; exit 7 ;;
esac

# --silent-read: open the item's ACL partition list to Apple-signed CLI tools so a
# background reader (e.g. /usr/bin/security inside an MCP-launch wrapper) gets the value
# without a Keychain prompt. Best-effort: the secret is already stored at this point, so
# a partition-list failure only loses silent access — warn and continue, never fail the
# capture. `set-generic-password-partition-list` needs the keychain unlocked and will
# prompt once for the login password.
if [[ -n "$SILENT_READ" ]]; then
  if ! security set-generic-password-partition-list \
        -S apple-tool:,apple: -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1; then
    echo "WARNING: could not set partition list for '$SERVICE'; first non-interactive read may show a Keychain prompt. Fix manually: security set-generic-password-partition-list -S apple-tool:,apple: -s '$SERVICE' -a '$ACCOUNT'" >&2
  fi
fi

printf 'keychain:%s\n' "$SERVICE"
