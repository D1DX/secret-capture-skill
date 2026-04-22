# Patterns

`--expect <shape>` validates the captured value against a known regex before writing it to the destination. The skill ships with 16 curated shapes in `patterns/common.yaml`. Users can add their own in `~/.config/secret-capture/patterns.yaml`.

## Built-in shapes

| Shape | Matches |
|---|---|
| `openai` | `sk-` or `sk-proj-` prefixed OpenAI keys |
| `anthropic` | `sk-ant-api01-` / `sk-ant-admin01-` Anthropic keys |
| `github-pat` | Classic PAT (`ghp_...`) |
| `github-fine-grained` | Fine-grained PAT (`github_pat_...`) |
| `github-app` | App tokens (`ghs_`, `ghu_`, `ghr_`) |
| `aws-access-key` | IAM access key ID (`AKIA...`) |
| `aws-secret-key` | IAM secret access key (40-char base64-ish) |
| `stripe-live` | Stripe live key (`sk/pk/rk_live_...`) |
| `stripe-test` | Stripe test key (`sk/pk/rk_test_...`) |
| `cloudflare-token` | CF API token (40-char opaque) |
| `cloudflare-global-key` | CF global API key (37-char hex, legacy) |
| `slack-bot` | Bot OAuth token (`xoxb-...`) |
| `slack-user` | User OAuth token (`xoxp-...`) |
| `slack-workflow` | Workflow trigger token (`xoxr-...`) |
| `jwt` | Three dot-separated base64url segments |
| `uuid` | UUID v1–v5 lowercase hex |

## Adding a user pattern

Create `~/.config/secret-capture/patterns.yaml` (mode 0600) with the same structure as `patterns/common.yaml`:

```yaml
patterns:
  my-service:
    regex: '^myservice_[A-Za-z0-9]{32}$'
    description: "My service API key"
```

User patterns are merged with the built-in set at runtime. User-defined names that collide with built-in names take precedence.

## Adding a built-in pattern (PR)

Edit `patterns/common.yaml`. Guidelines:

- **Conservative over permissive.** A false-negative (valid key rejected) is recoverable — the user re-invokes without `--expect`. A false-positive (invalid key accepted) could silently store garbage. When in doubt, widen the regex.
- **Anchor both ends.** Every pattern must start with `^` and end with `$`.
- **No capture groups.** The regex is used for match-only, not extraction.
- **Document the source.** Add a `description` field citing what the pattern matches and where the format comes from (official docs, observed samples, etc.).
- **Test before submitting.** Verify the regex matches at least three real (or redacted-real) examples and rejects at least three plausible near-misses.

## Regex engine

Patterns are evaluated with `bash =~` (ERE). No PCRE features (no lookaheads, no named groups).