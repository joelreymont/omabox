# Omabox

Omabox is a native, ARM64-first Dropbox sync service for Omarchy. It is written in Rust nightly and uses Dropbox's documented API and OAuth flow, never a private protocol.

## Product shape

- Run unattended as a systemd user service after one-time browser authentication.
- Keep real, local-first files rather than exposing a network-backed virtual filesystem.
- Keep the daemon headless. Put CLI and status behavior, and any optional Omarchy QML integration, in separate components.
- Prefer small, direct mechanisms and one concern per package. Do not introduce architecture before a concrete need proves it necessary.

## Safety invariants

- Record sync state in a durable, transactional journal.
- Stage downloads, verify their contents, and install them with atomic renames.
- Make uploads conditional on the last known Dropbox revision.
- Preserve every side of a conflict; never resolve conflicts destructively.
- Never infer deletions from uncertain, partial, stale, or inaccessible state.
- Keep automatic recovery data and backups for deleted or replaced files.
- Recovery must be automatic. Users must not manage locks, stale state, or recovery commands.

## Development

- Follow `~/.agents/docs/rust.md` for all Rust code; repository rules may be stricter.
- Use `jj` and keep commits small and focused.
- Run `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, and `cargo test` before landing Rust changes.
- Run `formal/DownloadLifecycle.tla` with TLC after changing durable download replay.
- Separate real Dropbox API integration tests from unit tests.
- Never weaken a safety invariant to make a test pass.
- Never commit credentials, OAuth tokens, test accounts, or other secrets.
