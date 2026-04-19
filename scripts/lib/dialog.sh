#!/usr/bin/env bash
# Dialog capture — prompts the user for a secret without echoing it anywhere.
# Emits the value to stdout (for the pipeline).

_has_gui_macos() {
  [[ "$(uname -s)" == "Darwin" ]] && pgrep -q "WindowServer" 2>/dev/null
}

_has_tty() {
  [[ -t 0 && -t 2 ]]
}

# dialog_capture <prompt-label>
# Emits the captured value (no trailing newline) to stdout.
# On cancel: exit 4 (CANCELLED). On no-GUI and no-TTY: exit 3 (NO_GUI).
dialog_capture() {
  # Defensive: silence xtrace inside this function so values never appear in
  # `bash -x` / `set -x` traces. Saved/restored around the function body.
  local _xtrace_was_on=""
  case $- in *x*) _xtrace_was_on=1 ;; esac
  set +x

  local prompt="${1:-secret}"
  local value=""

  if _has_gui_macos; then
    # osascript hidden-input dialog. Value comes back on stdout.
    # 2>/dev/null swallows the "user cancelled" stderr message.
    value=$(osascript \
      -e "tell application \"System Events\" to display dialog \"Enter $prompt (input hidden):\" default answer \"\" with hidden answer with title \"secret-capture\"" \
      -e 'text returned of result' 2>/dev/null) || {
      echo "CANCELLED" >&2
      return 4
    }
  elif _has_tty; then
    # TTY fallback: read -s suppresses echo.
    printf 'Enter %s (hidden): ' "$prompt" >&2
    IFS= read -rs value || { echo "CANCELLED" >&2; return 4; }
    printf '\n' >&2
  else
    echo "NO_GUI: no WindowServer and no TTY available" >&2
    return 3
  fi

  # Defensive newline strip: osascript's `text returned` already excludes the trailing
  # newline, and `read -rs` doesn't add one — but if upstream changes or a future
  # capture path appends one, this guarantees adapters receive a clean value.
  value="${value%$'\n'}"

  # Emit without trailing newline; adapters can handle as raw.
  #
  # Pipeline-SIGPIPE defense: some adapters (e.g. keychain via `expect`) close
  # their stdin immediately after `read stdin` returns. Bash's pipefail then
  # propagates the writer's SIGPIPE (exit 141) as a phantom pipeline failure
  # even though the value was already delivered and the adapter succeeded.
  # The subshell with `set +e`, `trap '' PIPE`, and explicit `exit 0` guarantees
  # this stage returns 0 regardless of EPIPE.
  ( set +e; trap '' PIPE; printf '%s' "$value"; exit 0 )
  value=""

  # Restore xtrace if the caller had it on.
  [[ -n "$_xtrace_was_on" ]] && set -x || true
  return 0
}
