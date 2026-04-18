#!/usr/bin/env bash
# Per-target preflight checks. Each should be fast and touch no value.
# Failures emit AUTH_FAIL or ADAPTER_ERROR on stderr with a remediation hint.

preflight_check() {
  local target="$1"
  shift
  case "$target" in
    1password) _pf_1password ;;
    keychain) _pf_keychain ;;
    gh-secret) _pf_gh ;;
    wrangler) _pf_wrangler ;;
    coolify) _pf_coolify ;;
    n8n) _pf_n8n ;;
    env-file) : ;;
    *) echo "USAGE_ERROR: no preflight for target '$target'" >&2; return 2 ;;
  esac
}

_pf_1password() {
  command -v op >/dev/null 2>&1 \
    || { echo "ADAPTER_ERROR: 'op' (1Password CLI) not found" >&2; return 7; }
  op whoami >/dev/null 2>&1 \
    || { echo "AUTH_FAIL: 1Password CLI not signed in (run: eval \$(op signin))" >&2; return 8; }
}

_pf_keychain() {
  [[ "$(uname -s)" == "Darwin" ]] \
    || { echo "ADAPTER_ERROR: keychain adapter is macOS-only" >&2; return 7; }
  command -v security >/dev/null 2>&1 \
    || { echo "ADAPTER_ERROR: 'security' not found" >&2; return 7; }
  command -v expect >/dev/null 2>&1 \
    || { echo "ADAPTER_ERROR: 'expect' required for leak-free keychain writes" >&2; return 7; }
}

_pf_gh() {
  command -v gh >/dev/null 2>&1 \
    || { echo "ADAPTER_ERROR: 'gh' (GitHub CLI) not found" >&2; return 7; }
  gh auth status >/dev/null 2>&1 \
    || { echo "AUTH_FAIL: GitHub CLI not authenticated (run: gh auth login)" >&2; return 8; }
}

_pf_wrangler() {
  command -v wrangler >/dev/null 2>&1 \
    || { echo "ADAPTER_ERROR: 'wrangler' (Cloudflare CLI) not found" >&2; return 7; }
}

_pf_coolify() {
  command -v curl >/dev/null 2>&1 \
    || { echo "ADAPTER_ERROR: 'curl' not found" >&2; return 7; }
  command -v jq >/dev/null 2>&1 \
    || { echo "ADAPTER_ERROR: 'jq' not found" >&2; return 7; }
  local url
  url=$(config_get "defaults.coolify.url")
  [[ -n "$url" ]] \
    || { echo "CONFIG_ERROR: defaults.coolify.url is not set in $SC_CONFIG_FILE" >&2; return 9; }
}

_pf_n8n() {
  command -v curl >/dev/null 2>&1 \
    || { echo "ADAPTER_ERROR: 'curl' not found" >&2; return 7; }
  command -v jq >/dev/null 2>&1 \
    || { echo "ADAPTER_ERROR: 'jq' not found" >&2; return 7; }
}
