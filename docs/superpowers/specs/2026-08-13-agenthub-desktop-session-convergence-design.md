# AgentHub Desktop Session Convergence

**Status:** Approved
**Date:** 2026-08-13
**Supersedes scope in:** `docs/superpowers/specs/2026-08-11-agenthub-design.md` sections 6–8

## 1. Context

AgentHub currently observes sessions from every surface it can reach: Claude
Code CLI sessions through hooks, Cursor IDE sessions through hooks, Codex
threads through the app server, and OpenCode sessions through its HTTP API. It
also runs a permission inbox, nests subagents and background tasks under their
parents, and offers a composer for direct input.

That breadth costs more than it returns. This design converges AgentHub on one
job: **show the sessions running in three desktop applications, and jump to
them.** Everything that does not serve that job is removed rather than left
dormant, so the remaining code is small enough to reason about.

Quota collection is untouched. It is a separate concern that already works for
all four providers and is not part of session management.

## 2. Goals and non-goals

### Goals

- List the sessions currently running in Codex Desktop and Cursor.
- Jump from an AgentHub row to the corresponding application surface.
- Keep cross-agent handoff, which remains the one action worth taking on a
  session from outside its own application.
- Delete, not disable, everything outside that scope.

### Non-goals

- CLI sessions of any provider.
- Subagents and background tasks.
- Approving or resolving permission requests.
- A composer for typing into a session from AgentHub.
- Claude Desktop sessions (see section 4).

## 3. Provider coverage

| Surface | Source | Level | State |
|---|---|---|---|
| Codex Desktop | Codex app server `thread/list`, filtered by originator | L1 | Works today |
| Cursor | Cursor IDE hooks | L2 observe, L3 jump | Works today, live sessions |
| Claude Desktop | — | — | Not observable; dropped |
| OpenCode | — | — | Out of scope; keeps quota only |

### Codex Desktop

ChatGPT Desktop bundles Codex and runs `codex app-server` as a child process.
Its threads are written to `~/.codex/sessions/` — the same storage the app
server reads — and each rollout file records `originator: "Codex Desktop"`.

That field is the Desktop/CLI discriminator: AgentHub lists only threads whose
originator is Codex Desktop, so `codex` runs from a terminal never appear.

Sessions are currently constructed with `ownership: .managed` hardcoded. That is
wrong for threads AgentHub did not launch; ownership becomes `.discovered`
unless the thread came from an AgentHub launch.

### Cursor

Cursor sessions arrive through the IDE's hooks, so they are desktop sessions by
construction and need no filter. Jump stays L3: activate the application.

## 4. Why Claude Desktop is dropped

Investigated before this design was written; all four routes are closed.

- Claude Desktop is a standard Electron application. It does not spawn Claude
  Code, so the existing `Desktop` branch of `ClaudeProcessClassifier` — which
  matches `Claude.app/Contents/MacOS` in a reporting process's ancestry — can
  never fire. It has produced zero sessions.
- Its local state holds scattered configuration keys and cached messages, not an
  enumerable index of conversations.
- The Claude Code OAuth token is scoped for inference and usage; the
  conversations endpoint rejects it.
- A `claude://` URL scheme exists, so the application can be activated, but no
  reliable per-conversation deep link was found.

There is also a modelling mismatch. Claude Desktop conversations are chat
threads, not sessions with runtime state. Section 6 of the original design
requires a live process, a provider-native active state, or a recent event plus
an observable runtime before anything is classified as running. A chat thread
has none of these, so every row would be permanently statusless.

Claude therefore contributes quota only. If Claude Desktop later exposes a local
agent surface, adding it back is its own piece of work.

## 5. What is removed

### Permission subsystem

`RequestService`, `PendingRequest` production and resolution, the
`resolveRequest` and `awaitHookPermission` IPC commands, `RequestInboxView`,
`CursorPermissionGate`, and the hook permission decision path.

OpenCode also produces permission requests; it receives the same treatment.

**Cursor hook consequence.** `beforeShellExecution` and `beforeMCPExecution` are
blocking hooks: the helper waits for AgentHub and falls back to `ask` on
timeout. If AgentHub stops answering while those hooks remain installed, every
Cursor shell command pays the timeout before Cursor's own prompt appears. Both
are therefore removed from the installer and uninstalled from
`~/.cursor/hooks.json`. The remaining events — `sessionStart`, `sessionEnd`,
`beforeSubmitPrompt`, `stop`, `afterShellExecution`, `afterMCPExecution`,
`afterAgentResponse`, `afterAgentThought`, `preCompact` — stay, because they are
how Cursor sessions are observed.

`subagentStart` and `subagentStop` also go, under the next heading.

### Subagents and background tasks

`AgentNode` production and the nested session tree.

### Persistence

The `agent_nodes` and `pending_requests` tables are dropped by a new migration,
consistent with how `provider-endpoints-v2` and `provider-components-v3` were
added. Dropping them is safe because nothing reads either table once the
subsystems above are gone; leaving them would preserve rows no code can surface.

This is a deliberate exception to the caution in section 7 about
`waitingPermission`: a status case lives inside a session's JSON blob and cannot
be removed without breaking decode, whereas a whole table has no such readers.

### Claude session collection

`ClaudeHookInstaller`, `ClaudeStatusLineInstaller`, `ClaudeHookModels`,
`ClaudeHookReporter`, `ClaudeProcessClassifier`, `ClaudeTranscriptReader`,
`ClaudeTerminalRuntime`, `ClaudeTerminalScreen`, `ClaudeHelperSocket`,
`ClaudeSettingsStore`, and the `agenthub-claude-hook` and
`agenthub-claude-statusline` executables.

`ClaudeAdapter` shrinks to a quota-only adapter retaining `ClaudeUsageAPI` and
`ClaudeUsageCacheReader`.

The user's machine is cleaned up too: the sixteen AgentHub hooks and the
status-line wrapper are removed from `~/.claude/settings.json`, after a backup,
leaving unrelated entries untouched.

### Composer

The detail-pane input and the `sendInput` IPC command.

## 6. What is kept, and why

**Quota** for all four providers, unchanged.

**Handoff** — envelopes, `HandoffService`, `DeliveryReconciler`, and the queue
that holds delivery until a working target goes idle.

**`AgentAdapter.send`** stays even though the composer goes. Handoff delivery to
an L1 target uses the provider input endpoint through `send`; removing it would
silently break handoff while leaving the button in place.

## 7. Consequences to accept deliberately

**A handoff eligibility rule disappears.** `HandoffRouter` currently refuses
delivery to a target holding a pending request, satisfying acceptance criterion
7 of the original design. With no pending requests, the rule is vacuous and is
removed. The companion rule — never overwrite a non-idle composer — is
unaffected and still enforced.

**`waitingPermission` remains in the status enum.** Nothing produces it once the
permission hooks are gone, but session status is persisted inside JSON blobs;
removing the case would fail to decode existing rows. It stays as an unused case
rather than forcing a migration.

**Acceptance criteria 4, 5 and 7 of the original design no longer apply.** They
describe permission behaviour that this design deletes.

## 8. Resulting user experience

A two-pane window: a flat session list on the left, a detail pane on the right
with metadata, recent output, delivery history, a jump control, and Hand off.
Above them, the quota strip and adapter health indicators.

No nesting, no inbox, no composer.

## 9. Testing

- Codex: originator filtering keeps Desktop threads and drops CLI threads;
  ownership reflects launch provenance rather than a hardcoded value.
- Cursor: sessions are still observed after the two blocking hooks are removed;
  the installer neither writes nor recognises them.
- Daemon: no `PendingRequest` is produced by any adapter.
- Handoff: queue-until-idle and the non-idle-composer guard still hold.
- Uninstall: Claude settings lose only AgentHub's entries; unrelated hooks and
  the user's own status line survive.

Live verification: Codex Desktop and Cursor rows both display and jump, and the
full gate is green.
