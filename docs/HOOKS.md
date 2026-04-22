# Companion hooks

`secret-capture` eliminates the capture-time leak path. Two Claude Code hooks close the remaining gaps: one that enforces safe `op` usage at the framework level, and one that detects hardcoded secrets in files before they land in git.

Both hooks use the Claude Code hook protocol: they receive a JSON object on stdin and return `{}` to pass through or `{"decision":"block","reason":"..."}` to deny the tool call.

## Hook 1 — `op` pre-bash gate

**Event:** `PreToolUse` on `Bash`

Enforces that `op read` / `op item get` outputs never reach the agent transcript. The problem: both commands print secrets to stdout by default, and stdout becomes the tool result, which becomes the conversation context. `secret-capture` avoids this during capture, but a later `op read` invoked directly — for debugging, verification, or habit — creates the same leak.

### What it blocks

| Shape | Why blocked |
|---|---|
| `op read op://...` (bare) | stdout → tool result → transcript |
| `echo $(op read ...)` | printing command receives the expansion |
| `op read ... \| cat` | pipeline to a printer |
| `op read ... > file` | use `op inject -o <file>` instead |
| `VAR=$(op read ...)` (standalone) | long-lived shell variable; leaks via `set`, xtrace, child processes |
| `op inject` without `-o <file>` | secrets go to stdout |
| `$(op read ...)` with non-allowlisted consumer | arbitrary command; hook can't verify it's safe |

### What it allows

| Shape | Why safe |
|---|---|
| `curl -H "Authorization: Bearer $(op read ...)" ...` | value stays inside child-process argv; curl consumes it without echoing |
| `VAR=$(op read ...) python3 script.py` | inline env prefix; scope dies when the command exits |
| `op inject -i template.json -o .mcp.json` | writes to a gitignored file on disk; `-o` is required |

The allowlisted consumer set is: `curl`, `python`, `python3`, `node`, `wrangler`, `gh`.

### Implementation skeleton

```bash
#!/bin/bash
# PreToolUse hook — Bash tool
# Place at: ~/.claude/hooks/pre-bash-op-gate.sh
# Register in ~/.claude/settings.json under hooks.PreToolUse

set -euo pipefail
trap 'echo "{}"' ERR

input=$(head -c 65536)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
[[ -n "$cmd" ]] || { echo '{}'; exit 0; }

# Strip single-quoted strings (never expanded by bash) to avoid false positives
# in git commit messages, comments, etc.
cmd_classify=$(echo "$cmd" | sed "s/'[^']*'/''/g")

if echo "$cmd_classify" | grep -qE '\bop[[:space:]]+(read|item[[:space:]]+get|inject)\b'; then

  ALLOWLIST="curl|python|python3|node|wrangler|gh"

  # Block: printing command receives the expansion
  if echo "$cmd_classify" | grep -qE \
    '\b(echo|printf|cat|tee|less|head|tail|xxd|base64)\b[^|;&]*\$\(op[[:space:]]+(read|item[[:space:]]+get)'; then
    jq -n '{"decision":"block","reason":"op read expansion passed to a printing command — value would reach the tool result."}' ; exit 0
  fi

  # Block: piped to a printer
  if echo "$cmd_classify" | grep -qE \
    '\bop[[:space:]]+(read|item[[:space:]]+get)\b[^|]*\|[[:space:]]*(cat|tee|head|tail|base64|echo|printf)\b'; then
    jq -n '{"decision":"block","reason":"op read piped to a printing command."}' ; exit 0
  fi

  # Block: redirected to file
  if echo "$cmd_classify" | grep -qE \
    '\bop[[:space:]]+(read|item[[:space:]]+get)\b[^|;&]*>[>]?[[:space:]]*[^[:space:]]'; then
    jq -n '{"decision":"block","reason":"Use op inject -o <file> instead of redirecting op read."}' ; exit 0
  fi

  # Block: standalone VAR=$(op ...) with no consumer
  if echo "$cmd_classify" | grep -qE \
    '(^|;|&&|\|\|)[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\$\(op[[:space:]]+(read|item[[:space:]]+get)[^)]*\)[[:space:]]*(;|&&|\|\||$)'; then
    jq -n '{"decision":"block","reason":"Standalone VAR=\$(op ...) creates a long-lived variable. Use: VAR=\$(op read ...) <consumer> on the same line."}' ; exit 0
  fi

  # Block: op inject without -o <file> or with -o stdout
  if echo "$cmd_classify" | grep -qE '\bop[[:space:]]+inject\b'; then
    if ! echo "$cmd_classify" | grep -qE '\bop[[:space:]]+inject\b[^;&|]*-o[[:space:]]+[^[:space:]-]'; then
      jq -n '{"decision":"block","reason":"op inject without -o <file> writes secrets to stdout."}' ; exit 0
    fi
    if echo "$cmd_classify" | grep -qE '\bop[[:space:]]+inject\b[^;&|]*-o[[:space:]]+(-|/dev/stdout|/dev/stderr)'; then
      jq -n '{"decision":"block","reason":"op inject -o targeting stdout/stderr. Use a real gitignored path."}' ; exit 0
    fi
  fi

  # Block: $(op ...) with non-allowlisted consumer
  if echo "$cmd_classify" | grep -qE '\$\([[:space:]]*op[[:space:]]+(read|item[[:space:]]+get)\b'; then
    stripped=$(echo "$cmd_classify" | sed -E \
      's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=(\$\([^)]*\)|[^[:space:]]+)[[:space:]]+)+//')
    first_token=$(echo "$stripped" | awk '{print $1}' | sed 's|.*/||')
    if ! echo "$first_token" | grep -qE "^($ALLOWLIST)$"; then
      jq -n --arg t "$first_token" \
        '{"decision":"block","reason":"$(op ...) with non-allowlisted consumer \($t). Allowlist: curl, python, python3, node, wrangler, gh."}' ; exit 0
    fi
  fi

fi

echo '{}'
```

### Registration (`~/.claude/settings.json`)

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/pre-bash-op-gate.sh"
          }
        ]
      }
    ]
  }
}
```

---

## Hook 2 — secret content scanner

**Event:** `PostToolUse` on `Edit` and `Write`

Advisory scan on every file write. Warns (never blocks) when a written file contains patterns that look like API keys, tokens, or passwords, or when the filename itself is sensitive (`.env`, `.har`, `credentials.json`, etc.). Output goes to stderr and a local log; the tool call is never denied.

### What it detects

- Common API key patterns: OpenAI, Anthropic, AWS, GitHub, Stripe, Cloudflare, Slack, etc.
- Generic high-entropy strings in credential-like assignments (`api_key = "..."`, `token: ...`)
- Sensitive filenames: `.env`, `.har`, `credentials.json`, `*.key`, `*.pem`
- Templates (`.env.template`, `.env.example`) are excluded from filename checks

### Implementation skeleton

```bash
#!/bin/bash
# PostToolUse hook — Edit and Write tools
# Place at: ~/.claude/hooks/secret-scan.sh
# Register in ~/.claude/settings.json under hooks.PostToolUse

set -euo pipefail
trap 'echo "{}"' EXIT

input=$(head -c 65536)
file=$(echo "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || echo "")
[[ -n "$file" ]] || exit 0

SENSITIVE_FILENAMES='^\.(env|netrc)$|^credentials\.(json|yaml|yml)$|^.*\.(key|pem|p12|pfx|har)$'
SKIP_SUFFIXES='\.template$|\.example$|\.sample$'

basename_file=$(basename "$file")
if echo "$basename_file" | grep -qE "$SENSITIVE_FILENAMES" && \
   ! echo "$file"       | grep -qE "$SKIP_SUFFIXES"; then
  echo "SECURITY: '$basename_file' is a sensitive filename — confirm it is gitignored" >&2
fi

[[ -f "$file" ]] || exit 0

# Patterns: label | regex
PATTERNS=(
  "OpenAI key|sk-(proj-)?[A-Za-z0-9_-]{20,}"
  "Anthropic key|sk-ant-(api|admin)[0-9]{2}-[A-Za-z0-9_-]{20,}"
  "GitHub PAT|gh[pousr]_[A-Za-z0-9]{36}"
  "AWS access key|AKIA[0-9A-Z]{16}"
  "Stripe key|(sk|pk|rk)_(live|test)_[A-Za-z0-9]{24,}"
  "Cloudflare token|[A-Za-z0-9_-]{40}"
  "Slack token|xox[bpra]-[0-9A-Za-z-]+"
  "Generic secret assignment|(password|secret|api.?key|token)\s*[:=]\s*['\"][A-Za-z0-9_\-]{16,}['\"]"
)

file_content=$(head -c 102400 "$file" 2>/dev/null || true)
[[ -n "$file_content" ]] || exit 0

findings=0
for entry in "${PATTERNS[@]}"; do
  label="${entry%%|*}"
  regex="${entry##*|}"
  if echo "$file_content" | grep -qE "$regex" 2>/dev/null; then
    echo "SECURITY: Possible $label in $(basename "$file")" >&2
    findings=$((findings + 1))
  fi
done

[[ "$findings" -gt 0 ]] && \
  echo "SECURITY: $findings finding(s) — rotate any real value and move it to your secret store" >&2
```

### Registration

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/secret-scan.sh"
          }
        ]
      }
    ]
  }
}
```

---

## Layered model

Together these two hooks and the skill cover the full lifecycle:

| Stage | Mechanism |
|---|---|
| Agent needs a secret from you | `secret-capture` skill — value never in transcript |
| Agent reads a stored secret for use | pre-bash op gate — only allowlisted consumption shapes pass |
| Agent writes a file that might contain a secret | secret scanner — warns immediately, before git |
| Agent tries to hardcode a secret in a command | pre-bash op gate — blocked at the `op` invocation |

No single layer is sufficient. All three together mean a secret can travel from your input to its destination and later to its consumer without ever appearing in a tool result, log, shell history, or committed file.