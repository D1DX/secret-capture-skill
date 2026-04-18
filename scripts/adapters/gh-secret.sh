#!/usr/bin/env bash
# Adapter: GitHub Actions secret (repo / org / env).
# `gh secret set NAME` reads the value from stdin when --body is absent.
# Stdout: gh-secret:<scope-path>#<name>

set -euo pipefail

SCOPE="repo"
NAME=""
REPO=""
ORG=""
ENV_NAME=""
VISIBILITY="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --org) ORG="$2"; shift 2 ;;
    --env) ENV_NAME="$2"; shift 2 ;;
    --visibility) VISIBILITY="$2"; shift 2 ;;
    *) echo "USAGE_ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[[ -z "$NAME" ]] && { echo "USAGE_ERROR: --name required" >&2; exit 2; }

case "$SCOPE" in
  repo)
    [[ -z "$REPO" ]] && { echo "USAGE_ERROR: --repo required for scope=repo" >&2; exit 2; }
    gh secret set "$NAME" --repo "$REPO" >/dev/null 2>&1 \
      || { echo "ADAPTER_ERROR: gh secret set failed" >&2; exit 7; }
    printf 'gh-secret:%s#%s\n' "$REPO" "$NAME"
    ;;
  org)
    [[ -z "$ORG" ]] && { echo "USAGE_ERROR: --org required for scope=org" >&2; exit 2; }
    gh secret set "$NAME" --org "$ORG" --visibility "$VISIBILITY" >/dev/null 2>&1 \
      || { echo "ADAPTER_ERROR: gh secret set failed" >&2; exit 7; }
    printf 'gh-secret:org/%s#%s\n' "$ORG" "$NAME"
    ;;
  env)
    [[ -z "$REPO" || -z "$ENV_NAME" ]] && { echo "USAGE_ERROR: --repo and --env required for scope=env" >&2; exit 2; }
    gh secret set "$NAME" --repo "$REPO" --env "$ENV_NAME" >/dev/null 2>&1 \
      || { echo "ADAPTER_ERROR: gh secret set failed" >&2; exit 7; }
    printf 'gh-secret:%s/env/%s#%s\n' "$REPO" "$ENV_NAME" "$NAME"
    ;;
  *)
    echo "USAGE_ERROR: --scope must be repo|org|env" >&2
    exit 2
    ;;
esac
