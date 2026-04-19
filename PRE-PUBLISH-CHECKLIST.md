# Pre-publish checklist

Run through this before flipping the repo from **private** to **public** on GitHub.

## Content review

- [ ] **README.md** — reads well cold; no D1DX-specific references; install/use/uninstall all accurate
- [ ] **SKILL.md** — frontmatter fields correct; every adapter documented; error codes match the code
- [ ] **LICENSE** — MIT, correct copyright line
- [ ] **docs/SECURITY.md** — threat model accurate; residual risks honest; no stale "known issues"
- [ ] **PRE-PUBLISH-CHECKLIST.md** — this file; move or delete after publish
- [ ] **.gitignore** — no local-only artifacts, no stray secrets files tracked
- [ ] **config.example.yaml** — shape matches current adapter code; no real vault names, no real URLs
- [ ] **patterns/common.yaml** — regexes match what's documented; no overspecific patterns

## Code review

- [ ] **`scripts/capture.sh`** — entry point, arg parsing, 2-stage capture, valfile shredding
- [ ] **`scripts/lib/*.sh`** — hygiene / dialog / config / preflight / validate; no D1DX strings
- [ ] **`scripts/adapters/*.sh`** — one file per target; each passes `lint-adapters.sh`
- [ ] **`scripts/lint-adapters.sh`** — runs clean against the repo (0 violations)
- [ ] No hardcoded vault names, URLs, item names, or account identifiers
- [ ] No TODOs or FIXMEs for things that should be shipped

## Repo hygiene

- [ ] **Repo description** filled: "Capture a secret via hidden-input dialog and route it to a destination without the value ever appearing in tool results, logs, or transcripts. macOS skill for Claude Code / Agent SDK."
- [ ] **Topics** added on GitHub: `claude-code`, `claude-skill`, `anthropic`, `macos`, `secret-management`, `1password`, `osascript`, `shell`
- [ ] **Default branch** = `main` ✓
- [ ] **GitHub Actions** — none yet; add later if CI is needed
- [ ] **Issues + Discussions** — enable both (default for public repos)
- [ ] **Settings → Merge options** — allow squash, disallow merge-commits & rebase (keep linear history)
- [ ] **Require PRs for main** (branch protection) — optional for v1; recommended once there are external contributors

## Docs to add before publish

- [ ] **`CONTRIBUTING.md`** — how to propose a new adapter, hygiene-lint requirement, test approach, PR process
- [ ] **`docs/ADAPTERS.md`** — spec for writing a new adapter (read value from stdin; never argv; never env; exit 0 with reference-only stdout; include in lint)
- [ ] **`docs/PATTERNS.md`** — how to add a shape to `patterns/common.yaml`
- [ ] **`CHANGELOG.md`** — start with v0.1.0 covering the 7 adapters that ship today

Optional: `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1 is the usual boilerplate).

## D1DX-specific scrub

- [ ] `grep -r "D1DX" .` — only the install URL should reference D1DX (`D1DX/secret-capture-skill`), nothing else
- [ ] `grep -r "d1dx.tools\|d1dx.com\|d1dx.xyz" .` — should be empty
- [ ] `grep -r "Employee\|BRURIA\|CBRN\|IMAD\|D1DX Finance\|D1DX Secret" .` — should be empty (vault names)
- [ ] `grep -r "daniel@d1dx\|daniel.rudaev" .` — should be empty
- [ ] `grep -r "coolify-d1dx\|n8n-d1dx\|airtable-d1dx" .` — should be empty (D1DX item names)

## Functional verification

- [ ] `bash scripts/capture.sh --help` — renders, no errors
- [ ] `bash scripts/lint-adapters.sh` — 0 violations
- [ ] Clean-machine smoke: run the 7 adapters in a dry-run loop, verify each writes + verifies + cleans up on a throwaway destination
- [ ] Verify a fresh user without existing `~/.config/secret-capture/config.yaml` can invoke `env-file` / `keychain` / `gh-secret` / `wrangler` without any setup

## Announcement prep (after flip)

- [ ] Short blog post / gist: "why this exists, what it does, what it doesn't"
- [ ] Claude Code community channels (Discord / GitHub Discussions)
- [ ] Anthropic Discord — `#community-built` or equivalent
- [ ] Social: one tweet / toot / linkedin with a 30-second use case example

## Flip

```bash
# Once every checkbox above is honestly ticked:
gh repo edit D1DX/secret-capture-skill --visibility public --accept-visibility-change-consequences
```

Verify: anonymous `curl -sI https://github.com/D1DX/secret-capture-skill` returns `200`, not `404`.

## Post-flip

- [ ] Delete this file (or move to `docs/release/pre-publish-checklist-v0.1.0.md` if you want to keep it for future releases)
- [ ] Archive the GitHub issue (if any) that tracked "publish gate"
- [ ] Monitor issue tracker for the first 2 weeks — respond within 48h
