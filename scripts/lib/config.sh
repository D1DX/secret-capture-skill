#!/usr/bin/env bash
# Config loader — reads ~/.config/secret-capture/config.yaml.
# Requires `yq` (Go version, mikefarah/yq). Falls back to a no-op reader when absent,
# so adapters that don't depend on config still work.

: "${SC_CONFIG_FILE:=$HOME/.config/secret-capture/config.yaml}"

_yq_available() {
  command -v yq >/dev/null 2>&1
}

# config_get <dotted.path> [default]
config_get() {
  local path="$1" default="${2:-}"
  [[ ! -f "$SC_CONFIG_FILE" ]] && { printf '%s' "$default"; return 0; }
  if _yq_available; then
    local v
    v=$(yq -r ".${path} // \"\"" "$SC_CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$v" && "$v" != "null" ]]; then
      printf '%s' "$v"
    else
      printf '%s' "$default"
    fi
  else
    printf '%s' "$default"
  fi
}

# config_adapter_enabled <target>
# Returns 0 if enabled (or if config file doesn't exist — default-open).
config_adapter_enabled() {
  local target="$1"
  [[ ! -f "$SC_CONFIG_FILE" ]] && return 0
  _yq_available || return 0
  local enabled
  enabled=$(yq -r '.adapters.enabled[]?' "$SC_CONFIG_FILE" 2>/dev/null || true)
  # If adapters.enabled is missing entirely, default-open.
  if [[ -z "$enabled" ]]; then
    local disabled
    disabled=$(yq -r '.adapters.disabled[]?' "$SC_CONFIG_FILE" 2>/dev/null || true)
    if printf '%s\n' "$disabled" | grep -Fxq "$target"; then
      return 1
    fi
    return 0
  fi
  printf '%s\n' "$enabled" | grep -Fxq "$target"
}

# resolve_source <source-spec>
# Emits resolved credential value to stdout. Supported schemes:
#   keychain:<service>[#<account>]
#   env:<VAR>
#   file:<path>
#   op:<op-ref>
#   command:<shell-fragment>
resolve_source() {
  local spec="$1"
  case "$spec" in
    keychain:*)
      local rest="${spec#keychain:}"
      local service account
      if [[ "$rest" == *"#"* ]]; then
        service="${rest%%#*}"
        account="${rest#*#}"
      else
        service="$rest"
        account="${USER}"
      fi
      security find-generic-password -s "$service" -a "$account" -w 2>/dev/null
      ;;
    env:*)
      local var="${spec#env:}"
      printf '%s' "${!var:-}"
      ;;
    file:*)
      local path="${spec#file:}"
      path="${path/#\~/$HOME}"
      [[ -r "$path" ]] && cat "$path"
      ;;
    op:*)
      local ref="${spec#op:}"
      op read "$ref" 2>/dev/null
      ;;
    command:*)
      local cmd="${spec#command:}"
      bash -c "$cmd" 2>/dev/null
      ;;
    *)
      echo "CONFIG_ERROR: unknown source scheme '$spec'" >&2
      return 1
      ;;
  esac
}
