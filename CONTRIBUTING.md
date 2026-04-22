# Contributing

## Issues

Bug reports and feature requests are welcome via GitHub Issues. For security vulnerabilities, see [`docs/SECURITY.md`](./docs/SECURITY.md) — reporting process is at the bottom of that file.

## Pull requests

All PRs target `main`. Keep changes focused — one adapter, one pattern set, one fix per PR.

### Adding an adapter

1. Read [`docs/ADAPTERS.md`](./docs/ADAPTERS.md) — it specifies the full contract an adapter must satisfy.
2. Create `scripts/adapters/<name>.sh` following the spec.
3. Run the hygiene lint and confirm zero violations:
   ```bash
   bash scripts/lint-adapters.sh
   ```
4. Add an entry to the destinations table in `README.md`.
5. Document the new target in `SKILL.md` under `## Targets`.
6. Open a PR. Description should include: destination name, what it writes to, what it requires, and the reference format it returns.

### Adding a pattern

See [`docs/PATTERNS.md`](./docs/PATTERNS.md).

### General changes

- Functional changes to `scripts/lib/` or `scripts/capture.sh` must not introduce any of the [leak vectors](./docs/SECURITY.md) enumerated in the security model.
- Update `CHANGELOG.md` under an `[Unreleased]` heading.

## Lint

`scripts/lint-adapters.sh` checks every adapter for the hygiene invariants (no argv assignment, no `export`, no stdout of value, no unguarded tempfile). It must pass with 0 violations before merging.

## License

By contributing you agree that your contributions will be licensed under the MIT License.