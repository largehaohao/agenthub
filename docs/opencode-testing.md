# OpenCode testing

AgentHub's default test suite uses a deterministic loopback NIO server. It
covers health checks, session CRUD, duplicate-session reconciliation, managed
launch, permissions, ordered questions, SSE updates, native session selection,
cross-provider handoff, restart restoration, endpoint isolation, and request
redaction without contacting an external provider.

Run the ordinary acceptance gate with:

```bash
zsh scripts/check.sh
```

## Installed OpenCode compatibility

An opt-in test starts `opencode serve --pure` with temporary, isolated
`XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`, and `XDG_STATE_HOME`
directories. It checks health, creates/reads/deletes one empty session, and
verifies macOS process-owned loopback socket discovery. It does not call
`prompt_async`, choose a model, or consume OpenCode Go quota.

```bash
AGENTHUB_LIVE_OPENCODE=1 swift test --filter LiveOpenCodeTests
```

The test is skipped by default. Its temporary server and XDG directories are
removed during teardown.

## Acceptance coverage

| Design criterion | Passing coverage |
| --- | --- |
| Secure lazy managed launch in a selected directory | `OpenCodeManagedServerTests`, `OpenCodeVerticalSliceTests` |
| Process-owned Desktop/TUI discovery and manual attachment | `OpenCodeDiscoveryTests`, `LiveOpenCodeTests`, `OpenCodeVerticalSliceTests` |
| Cross-endpoint native-session deduplication and routing | `OpenCodeHybridAdapterTests`, `OpenCodeVerticalSliceTests` |
| Sessions, children, status, bounded output, and restart reconciliation | `OpenCodeHybridAdapterTests`, `StoreTests`, `OpenCodeVerticalSliceTests` |
| Permission/question responses and provider-first convergence | `OpenCodeHybridAdapterTests`, `OpenCodeVerticalSliceTests` |
| Codex-to-OpenCode acknowledged handoff | `OpenCodeVerticalSliceTests` |
| Exact TUI selection and explicit jump fallback | `OpenCodeHybridAdapterTests`, `DashboardViewModelTests` |
| Managed crash/SSE recovery and endpoint isolation | `OpenCodeManagedServerTests`, `OpenCodeHybridAdapterTests`, `OpenCodeVerticalSliceTests` |
| No paid default prompt and credential/privacy boundaries | default-skipped `LiveOpenCodeTests`, `PrivacyTests`, `DashboardViewModelTests` |
| Packaged app and per-user daemon regression gate | `scripts/check.sh` |

## Credential and data boundaries

- Manual endpoints accept explicit HTTP loopback URLs only.
- Passwords are written to macOS Keychain before attachment; daemon IPC and
  SQLite receive only an opaque Keychain reference.
- A failed attachment/authentication deletes the newly created Keychain item.
- Detach/forget operations delete a Keychain item only after daemon
  acknowledgement.
- Question free text and Authorization values are not written to normalized
  state, diagnostics, or SQLite.
- OpenCode Go quota is reported as unavailable until OpenCode exposes a
  supported local quota source.
