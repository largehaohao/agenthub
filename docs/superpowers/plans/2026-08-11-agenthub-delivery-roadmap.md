# AgentHub Delivery Roadmap

**Source design:** `docs/superpowers/specs/2026-08-11-agenthub-design.md`

The approved design contains several independently testable provider integrations. Delivery is split into six plans so every plan ends with useful, reviewable software.

| Order | Plan | Independently testable result |
|---|---|---|
| 1 | macOS foundation and Codex vertical slice | Native dashboard and daemon can launch, observe, approve, message, and inspect quota for managed Codex sessions |
| 2 | OpenCode adapter | The same dashboard manages OpenCode sessions, children, permissions, events, and handoffs through its HTTP API |
| 3 | Claude Code CLI adapter | AgentHub launches Claude Code under a managed PTY, installs scoped hooks, shows subagents, and safely forwards requests |
| 4 | CodexBar quota aggregation and routing | Codex, Claude, Cursor, and OpenCode Go windows appear with freshness and explainable provider recommendations |
| 5 | Native desktop discovery and navigation | Codex Desktop, Claude Desktop, and Cursor IDE sessions are discovered read-only and opened through explicit L2/L3 fallbacks |
| 6 | Cross-provider hardening and release | Cross-adapter handoff, restart recovery, privacy controls, Accessibility fallbacks, packaging, and release acceptance tests are complete |

Plans 2–5 consume the adapter, persistence, IPC, and SwiftUI boundaries established by Plan 1. Plan 6 is the release gate; it adds no new provider family.

The first executable plan is `docs/superpowers/plans/2026-08-11-agenthub-foundation-codex.md`.
