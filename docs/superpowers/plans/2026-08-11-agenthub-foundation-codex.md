# AgentHub macOS Foundation and Codex Vertical Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS AgentHub application and persistent local daemon that can launch, observe, approve, message, jump to, and inspect quota for managed Codex App Server sessions.

**Architecture:** A SwiftUI/AppKit dashboard connects to a per-user Swift daemon through a mode-0600 Unix domain socket. The daemon owns a GRDB SQLite store, provider-neutral state reducer, Codex JSON-RPC adapter, request center, same-provider handoff queue, and quota snapshots. This plan delivers one complete L1 provider slice and freezes the boundaries consumed by later provider plans.

**Tech Stack:** macOS 14+, Xcode 16+ with Swift 6, SwiftUI, AppKit, Foundation `Process`, SwiftNIO 2.87–2.97, GRDB 7.10.0, XcodeGen 2.45.4, XCTest.

## Global Constraints

- Target macOS 14 or newer and one local user.
- Use Swift 6 language mode and complete strict-concurrency checking.
- Run the MVP app outside App Sandbox because it must launch local agent processes, read provider-owned local metadata, and use Accessibility; document this deliberate boundary and rely on user-scoped paths, Keychain, and mode-0600 IPC.
- Communicate only through a per-user Unix socket with filesystem mode `0600`.
- Persist normalized metadata and at most three visible turns or 256 KiB per session; remove cached output 24 hours after completion.
- Never store OAuth tokens, cookies, API keys, passwords, or verification codes in SQLite.
- Never ingest a complete provider transcript by default.
- Bind approvals to exact provider request, thread, turn, and item IDs; never auto-approve.
- Read at most 20 selected visible turns for handoff; never deliver while the target works or waits for a request.
- Run live provider tests only with `AGENTHUB_RUN_LIVE_CODEX_TESTS=1`.
- Use TDD and commit every independently reviewable task.

---

## Planned file structure

```text
Package.swift / project.yml                Swift package and XcodeGen graph
App/                                       SwiftUI app, dashboard, sessions, requests, quota
Sources/AgentHubCore/                      Models, adapter contract, reducer, tree, handoff
Sources/AgentHubPersistence/               GRDB migrations, records, store
Sources/AgentHubIPC/                       Versioned Unix-socket messages and client/server
Sources/AgentHubCodex/                     Process, JSON-RPC, DTOs, Codex adapter
Sources/AgentHubDaemon/                    Coordinator, request/handoff services, daemon API
Sources/agenthubd/main.swift               Daemon executable
Sources/AgentHubTestSupport/Fixtures.swift Shared core-model factories used only by tests
Support/                                   User LaunchAgent template and installer
Tests/                                     Unit, contract, integration, app, privacy fixtures
scripts/check.sh                           Repeatable build and test gate
docs/development.md                        Operator and contributor guide
```

## Task 1: Establish the build and project-generation baseline

**Files:**
- Create: `.gitignore`
- Create: `Package.swift`
- Create: `project.yml`
- Create: `Config/AgentHubApp.entitlements`
- Create: `App/AgentHubApp.swift`
- Create: `App/PlaceholderView.swift`
- Create: `Sources/AgentHubCore/Version.swift`
- Create: `Sources/AgentHubPersistence/Bootstrap.swift`
- Create: `Sources/AgentHubIPC/Bootstrap.swift`
- Create: `Sources/AgentHubCodex/Bootstrap.swift`
- Create: `Sources/AgentHubDaemon/Bootstrap.swift`
- Create: `Sources/AgentHubTestSupport/Bootstrap.swift`
- Create: `Sources/agenthubd/main.swift`
- Create: `Tests/AgentHubCoreTests/BootstrapTests.swift`
- Create: `Tests/AgentHubPersistenceTests/BootstrapTests.swift`
- Create: `Tests/AgentHubIPCTests/BootstrapTests.swift`
- Create: `Tests/AgentHubCodexTests/BootstrapTests.swift`
- Create: `Tests/AgentHubDaemonTests/BootstrapTests.swift`
- Create: `scripts/check.sh`
- Modify: `README.md`

**Interfaces:**
- Produces libraries `AgentHubCore`, `AgentHubPersistence`, `AgentHubIPC`, `AgentHubCodex`, `AgentHubDaemon`.
- Produces executables `AgentHubApp`, `agenthubd`, and verification command `scripts/check.sh`.

- [ ] **Step 1: Verify the toolchain and install XcodeGen**

```bash
test -d /Applications/Xcode.app
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
swift --version
brew install xcodegen
xcodegen --version
```

Expected: Xcode 16+, Swift 6+, and XcodeGen 2.45.4 or compatible newer 2.x. Stop if full Xcode is absent; the current Command Line Tools installation cannot build the app.

- [ ] **Step 2: Write the failing bootstrap test**

```swift
import XCTest
@testable import AgentHubCore

final class BootstrapTests: XCTestCase {
    func testLibraryExportsVersion() {
        XCTAssertEqual(AgentHubCoreVersion.current, "0.1.0")
    }
}
```

- [ ] **Step 3: Verify the test fails**

Run: `swift test --filter BootstrapTests/testLibraryExportsVersion`

Expected: FAIL because the package and version symbol do not exist.

- [ ] **Step 4: Add the minimal package and generated Xcode project**

Use this dependency and target graph in `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentHub",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentHubCore", targets: ["AgentHubCore"]),
        .library(name: "AgentHubPersistence", targets: ["AgentHubPersistence"]),
        .library(name: "AgentHubIPC", targets: ["AgentHubIPC"]),
        .library(name: "AgentHubCodex", targets: ["AgentHubCodex"]),
        .library(name: "AgentHubDaemon", targets: ["AgentHubDaemon"]),
        .library(name: "AgentHubTestSupport", targets: ["AgentHubTestSupport"]),
        .executable(name: "agenthubd", targets: ["agenthubd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
        .package(url: "https://github.com/apple/swift-nio.git", "2.87.0"..<"2.98.0"),
    ],
    targets: [
        .target(name: "AgentHubCore"),
        .target(name: "AgentHubPersistence", dependencies: ["AgentHubCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "AgentHubIPC", dependencies: ["AgentHubCore", .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio")]),
        .target(name: "AgentHubCodex", dependencies: ["AgentHubCore"]),
        .target(name: "AgentHubDaemon", dependencies: ["AgentHubCore", "AgentHubPersistence", "AgentHubIPC", "AgentHubCodex"]),
        .target(name: "AgentHubTestSupport", dependencies: ["AgentHubCore"]),
        .executableTarget(name: "agenthubd", dependencies: ["AgentHubDaemon"]),
        .testTarget(name: "AgentHubCoreTests", dependencies: ["AgentHubCore", "AgentHubTestSupport"]),
        .testTarget(name: "AgentHubPersistenceTests", dependencies: ["AgentHubPersistence", "AgentHubTestSupport"]),
        .testTarget(name: "AgentHubIPCTests", dependencies: ["AgentHubIPC", "AgentHubTestSupport"]),
        .testTarget(name: "AgentHubCodexTests", dependencies: ["AgentHubCodex", "AgentHubTestSupport"]),
        .testTarget(name: "AgentHubDaemonTests", dependencies: ["AgentHubDaemon", "AgentHubTestSupport"]),
    ]
)
```

Create `AgentHubCoreVersion.current = "0.1.0"`. Define `public enum AgentHubPersistenceBootstrap {}`, `public enum AgentHubIPCBootstrap {}`, `public enum AgentHubCodexBootstrap {}`, and `public enum AgentHubDaemonBootstrap {}` in their listed bootstrap files, plus internal `enum AgentHubTestSupportBootstrap {}`. Give each bootstrap test target one passing module-import smoke test so SwiftPM accepts the complete graph from the first commit.

Create the initial app entry points:

```swift
// App/AgentHubApp.swift
import SwiftUI

@main
struct AgentHubApp: App {
    var body: some Scene { WindowGroup { PlaceholderView() } }
}

// App/PlaceholderView.swift
import SwiftUI

struct PlaceholderView: View {
    var body: some View { Text("AgentHub") }
}

// Sources/agenthubd/main.swift
import AgentHubDaemon

print("agenthubd bootstrap")
```

Use this complete initial `project.yml`:

```yaml
name: AgentHub
options:
  minimumXcodeGenVersion: 2.45.4
  deploymentTarget:
    macOS: "14.0"
packages:
  AgentHubPackage:
    path: .
settings:
  base:
    SWIFT_VERSION: 6.0
    SWIFT_STRICT_CONCURRENCY: complete
targets:
  AgentHubApp:
    type: application
    platform: macOS
    sources:
      - App
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.agenthub.app
        CODE_SIGN_ENTITLEMENTS: Config/AgentHubApp.entitlements
    dependencies:
      - package: AgentHubPackage
        product: AgentHubCore
      - package: AgentHubPackage
        product: AgentHubIPC
```

The MVP is intentionally not sandboxed. Use this entitlements file, with no `com.apple.security.app-sandbox` key:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
```

Create `scripts/check.sh`:

```bash
#!/bin/zsh
set -euo pipefail
swift test
xcodegen generate
xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 5: Verify the baseline**

Run: `chmod +x scripts/check.sh && ./scripts/check.sh`

Expected: bootstrap test and unsigned app build pass.

- [ ] **Step 6: Commit**

```bash
git add .gitignore Package.swift project.yml Config App Sources Tests scripts README.md
git commit -m "build: scaffold AgentHub macOS workspace"
```

## Task 2: Define the provider-neutral model and adapter contract

**Files:**
- Create: `Sources/AgentHubCore/Models.swift`
- Create: `Sources/AgentHubCore/AgentAdapter.swift`
- Create: `Sources/AgentHubTestSupport/Fixtures.swift`
- Create: `Tests/AgentHubCoreTests/ModelTests.swift`

**Interfaces:**
- Produces all provider-neutral model types and `AgentAdapter`.
- Consumed by persistence, IPC, daemon, provider, and UI tasks.

- [ ] **Step 1: Write failing model tests**

```swift
func testSessionRoundTripKeepsIdentity() throws {
    let session = AgentSession.fixture(status: .waitingPermission)
    let data = try JSONEncoder.agentHub.encode(session)
    XCTAssertEqual(try JSONDecoder.agentHub.decode(AgentSession.self, from: data), session)
}

func testQuotaRejectsOutOfRangePercent() {
    XCTAssertThrowsError(try QuotaWindow(provider: .codex, accountID: "personal", usedPercent: 101, windowDuration: 900, resetsAt: .now, fetchedAt: .now, source: "codex-app-server"))
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --filter ModelTests`

Expected: FAIL because the domain types do not exist.

- [ ] **Step 3: Implement the exact vocabulary**

```swift
public enum Provider: String, Codable, CaseIterable, Sendable { case codex, claude, cursor, openCode }
public enum ReliabilityLevel: Int, Codable, Comparable, Sendable { case l1 = 1, l2 = 2, l3 = 3 }
public enum Capability: String, Codable, Hashable, Sendable { case discover, launch, status, children, recentTurns, sendInput, resolveRequest, jump, quota }
public enum SessionStatus: String, Codable, Sendable { case starting, working, waitingPermission, waitingInput, idle, completed, error, disconnected }
public enum SessionOwnership: String, Codable, Sendable { case managed, discovered }
public enum RequestKind: String, Codable, Sendable { case permission, planApproval, choice, textInput, confirmation, authentication }
public enum RequestState: String, Codable, Sendable { case pending, resolving, resolved, expired }
public enum DeliveryState: String, Codable, Sendable { case queued, delivering, delivered, failed, manual }

public struct ProviderSessionRef: Codable, Hashable, Sendable {
    public let provider: Provider
    public let accountID: String
    public let nativeID: String
}

public struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var providerRef: ProviderSessionRef
    public var title: String
    public var surface: String
    public var ownership: SessionOwnership
    public var status: SessionStatus
    public var rootID: UUID
    public var parentID: UUID?
    public var cwd: String?
    public var repository: String?
    public var branch: String?
    public var lastActivityAt: Date
    public var capabilities: [Capability: ReliabilityLevel]
    public var preview: [VisibleTurn]
}

public struct AgentNode: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var sessionID: UUID
    public var nativeID: String
    public var parentNativeID: String?
    public var kind: String
    public var status: SessionStatus
    public var lastActivityAt: Date
}

public struct VisibleTurn: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var role: String
    public var text: String
    public var createdAt: Date
}

public struct PendingRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var provider: Provider
    public var providerRequestID: String
    public var sessionID: UUID
    public var threadID: String
    public var turnID: String?
    public var itemID: String?
    public var kind: RequestKind
    public var title: String
    public var detail: String
    public var allowedActions: [String]
    public var state: RequestState
    public var reliability: ReliabilityLevel
    public var createdAt: Date
    public var expiresAt: Date?
}

public struct MessageEnvelope: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var sourceSessionID: UUID
    public var targetSessionID: UUID
    public var repository: String?
    public var cwd: String?
    public var branch: String?
    public var turns: [VisibleTurn]
    public var userNote: String?
    public var createdAt: Date
    public var expiresAt: Date
    public var state: DeliveryState
    public var failure: String?
}

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let accountID: String
    public let usedPercent: Double
    public let windowDuration: TimeInterval
    public let resetsAt: Date
    public let fetchedAt: Date
    public let source: String
    public init(provider: Provider, accountID: String, usedPercent: Double, windowDuration: TimeInterval, resetsAt: Date, fetchedAt: Date, source: String) throws
    public func isStale(now: Date, sourceTTL: TimeInterval? = nil) -> Bool
    public func availablePace(now: Date) -> Double?
}
```

Define adapter command/event types with these exact cases:

```swift
public struct LaunchRequest: Codable, Equatable, Sendable { public let clientRequestID: String; public let cwd: String; public let prompt: String }
public struct AdapterSnapshot: Codable, Equatable, Sendable { public var sessions: [AgentSession]; public var nodes: [AgentNode]; public var requests: [PendingRequest]; public var quotas: [QuotaWindow] }
public struct AgentInput: Codable, Equatable, Sendable { public let text: String; public let provenance: String? }
public struct ProviderRequestRef: Codable, Equatable, Sendable { public let provider: Provider; public let requestID: String; public let threadID: String; public let turnID: String?; public let itemID: String? }
public enum RequestDecision: Codable, Equatable, Sendable { case accept; case acceptForSession; case decline; case cancel; case text(String); case choices([String]) }
public enum JumpTarget: Codable, Equatable, Sendable { case agentHubDetail(sessionNativeID: String); case terminal(pane: String); case application(bundleID: String, windowHint: String?); case unavailable(String) }
public enum AgentEvent: Codable, Equatable, Sendable { case sessionUpserted(AgentSession); case nodeUpserted(AgentNode); case requestUpserted(PendingRequest); case requestResolutionStarted(id: UUID); case requestResolved(id: UUID, outcome: String); case envelopeUpserted(MessageEnvelope); case quotaUpserted(QuotaWindow); case adapterHealth(Provider, AdapterHealth) }
public struct AdapterHealth: Codable, Equatable, Sendable { public var connected: Bool; public var message: String?; public var changedAt: Date }
```

Implement `ReliabilityLevel.<` by comparing raw values. Validate quota percent `0...100`, default stale TTL 15 minutes, and turn limit `1...20`. `Sources/AgentHubTestSupport/Fixtures.swift` supplies deterministic factories for every core model used as `.fixture(...)`, plus `.duplicateA` and `.duplicateB`; factories use fixed UUIDs and dates so tests remain stable.

Use one deterministic wire/storage encoding everywhere:

```swift
public extension JSONEncoder {
    static var agentHub: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var agentHub: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
```

Define the adapter contract:

```swift
public protocol AgentAdapter: Sendable {
    var provider: Provider { get }
    func capabilities() async -> [Capability: ReliabilityLevel]
    func launch(_ request: LaunchRequest) async throws -> ProviderSessionRef
    func reconcile() async throws -> AdapterSnapshot
    func eventStream() async -> AsyncStream<AgentEvent>
    func recentTurns(for session: ProviderSessionRef, limit: Int) async throws -> [VisibleTurn]
    func send(_ input: AgentInput, to session: ProviderSessionRef) async throws
    func resolve(_ request: ProviderRequestRef, decision: RequestDecision) async throws
    func jumpTarget(for session: ProviderSessionRef) async -> JumpTarget
}
```

- [ ] **Step 4: Run model tests**

Run: `swift test --filter ModelTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubCore Tests/AgentHubCoreTests
git commit -m "feat: define provider-neutral agent model"
```

## Task 3: Implement deterministic state reduction and hierarchy

**Files:**
- Create: `Sources/AgentHubCore/StateReducer.swift`
- Create: `Sources/AgentHubCore/SessionTree.swift`
- Create: `Tests/AgentHubCoreTests/StateReducerTests.swift`
- Create: `Tests/AgentHubCoreTests/SessionTreeTests.swift`

**Interfaces:**
- Produces `AgentHubState`, `StateReducer.reduce`, and `SessionTreeBuilder.build`.

- [ ] **Step 1: Write failing race and deduplication tests**

```swift
func testResolvedRequestNeverReturnsToResolving() {
    var state = AgentHubState.empty
    let request = PendingRequest.fixture(state: .pending)
    StateReducer.reduce(state: &state, event: .requestUpserted(request))
    StateReducer.reduce(state: &state, event: .requestResolved(id: request.id, outcome: "accepted"))
    StateReducer.reduce(state: &state, event: .requestResolutionStarted(id: request.id))
    XCTAssertEqual(state.requests[request.id]?.state, .resolved)
}

func testSameNativeIdentityProducesOneRoot() {
    XCTAssertEqual(SessionTreeBuilder.build(sessions: [.duplicateA, .duplicateB], nodes: []).count, 1)
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --filter 'StateReducerTests|SessionTreeTests'`

Expected: FAIL because reducer and tree builder do not exist.

- [ ] **Step 3: Implement state and hierarchy**

```swift
public struct AgentHubState: Equatable, Codable, Sendable {
    public var sessions: [UUID: AgentSession]
    public var requests: [UUID: PendingRequest]
    public var envelopes: [UUID: MessageEnvelope]
    public var quotas: [String: QuotaWindow]
    public var adapterHealth: [Provider: AdapterHealth]
    public static let empty: AgentHubState
}

public enum StateReducer {
    public static func reduce(state: inout AgentHubState, event: AgentEvent)
}

public enum SessionTreeBuilder {
    public static func build(sessions: [AgentSession], nodes: [AgentNode]) -> [SessionTreeRow]
}
```

Terminal request states are monotonic. Merge sessions by provider/account/native ID, cap previews, map verification loss to `.disconnected`, and nest only explicit parent relationships. Unknown relationships remain separate roots.

- [ ] **Step 4: Run core tests**

Run: `swift test --filter AgentHubCoreTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubCore Tests/AgentHubCoreTests
git commit -m "feat: reduce agent lifecycle into session tree"
```

## Task 4: Persist normalized state with GRDB

**Files:**
- Create: `Sources/AgentHubPersistence/Database.swift`
- Create: `Sources/AgentHubPersistence/Records.swift`
- Create: `Sources/AgentHubPersistence/Store.swift`
- Create: `Tests/AgentHubPersistenceTests/StoreTests.swift`

**Interfaces:**
- Produces actor `AgentHubStore` with `apply`, `snapshot`, `prunePreviewCache`, and `appendAudit`.

- [ ] **Step 1: Write failing restart and idempotency tests**

```swift
func testRestartRestoresPendingAndQueuedState() async throws {
    let url = temporaryDatabaseURL()
    let first = try AgentHubStore(databaseURL: url)
    try await first.apply(.requestUpserted(.fixture(state: .pending)))
    try await first.apply(.envelopeUpserted(.fixture(state: .queued)))
    let restored = try await AgentHubStore(databaseURL: url).snapshot()
    XCTAssertEqual(restored.requests.values.first?.state, .pending)
    XCTAssertEqual(restored.envelopes.values.first?.state, .queued)
}

func testDuplicateProviderRequestCreatesOneRow() async throws {
    let store = try inMemoryStore()
    let request = PendingRequest.fixture(providerRequestID: "rpc-7")
    try await store.apply(.requestUpserted(request))
    try await store.apply(.requestUpserted(request))
    let count = try await store.snapshot().requests.count
    XCTAssertEqual(count, 1)
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --filter AgentHubPersistenceTests`

Expected: FAIL because persistence does not exist.

- [ ] **Step 3: Add migrations and model mappings**

Create tables `sessions`, `agent_nodes`, `pending_requests`, `message_envelopes`, `quota_windows`, `audit_events`, and `cached_turns`. Add unique indexes for `(provider, account_id, native_id)` and `(provider, provider_request_id)`. Store model bodies as JSON blobs; add no credential columns.

```swift
public actor AgentHubStore {
    public init(databaseURL: URL) throws
    public func apply(_ event: AgentEvent) throws
    public func snapshot() throws -> AgentHubState
    public func prunePreviewCache(now: Date) throws
    public func appendAudit(_ event: AuditEvent) throws
}
```

Enforce three turns/256 KiB during writes and remove caches 24 hours after completion.

- [ ] **Step 4: Run persistence and core tests**

Run: `swift test --filter 'AgentHubPersistenceTests|AgentHubCoreTests'`

Expected: PASS, including reopening a file-backed temporary database.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubPersistence Tests/AgentHubPersistenceTests
git commit -m "feat: persist restart-safe agent state"
```

## Task 5: Add versioned Unix-socket IPC

**Files:**
- Create: `Sources/AgentHubIPC/Messages.swift`
- Create: `Sources/AgentHubIPC/JSONLineCodec.swift`
- Create: `Sources/AgentHubIPC/UnixServer.swift`
- Create: `Sources/AgentHubIPC/UnixClient.swift`
- Create: `Tests/AgentHubIPCTests/IPCTests.swift`

**Interfaces:**
- Produces `DaemonCommand`, `DaemonReply`, `DaemonEvent`, `UnixDaemonServer`, and `UnixDaemonClient`.
- Uses newline-delimited JSON with `protocolVersion == 1`.

- [ ] **Step 1: Write failing framing, mode, and reconnect tests**

```swift
func testSocketHasUserOnlyMode() async throws {
    let path = temporarySocketPath()
    let server = try await UnixDaemonServer.bind(path: path) { _ in .ok }
    defer { Task { await server.stop() } }
    XCTAssertEqual(try fileMode(path) & 0o777, 0o600)
}

func testSnapshotThenLiveEvent() async throws {
    let pair = try await makeConnectedPair()
    _ = try await pair.client.send(.getSnapshot)
    let version = await pair.client.negotiatedProtocolVersion
    XCTAssertEqual(version, 1)
    await pair.server.broadcast(.stateChanged(sequence: 2))
    let event = await pair.client.events.firstValue()
    XCTAssertEqual(event, .stateChanged(sequence: 2))
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --filter AgentHubIPCTests`

Expected: FAIL because IPC does not exist.

- [ ] **Step 3: Implement exact wire types and socket behavior**

```swift
public struct IPCEnvelope<Body: Codable & Sendable>: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let body: Body
}

public enum DaemonCommand: Codable, Sendable {
    case getSnapshot
    case launchCodex(LaunchRequest)
    case resolveRequest(UUID, RequestDecision)
    case sendInput(UUID, AgentInput)
    case createHandoff(source: UUID, target: UUID, turnLimit: Int, note: String?)
    case jumpTarget(UUID)
}

public enum DaemonReply: Codable, Equatable, Sendable {
    case snapshot(AgentHubState)
    case accepted(UUID)
    case jump(JumpTarget)
    case failure(String)
}

public enum DaemonEvent: Codable, Equatable, Sendable {
    case stateChanged(sequence: UInt64)
    case adapterHealth(Provider, AdapterHealth)
}
```

`UnixDaemonClient.negotiatedProtocolVersion` is an actor-isolated read-only `Int?` set after the first valid envelope.

Use SwiftNIO Unix-domain bootstrap APIs. After binding, set and verify mode `0600`; fail closed otherwise. Reject frames over 1 MiB and protocol versions other than `1`. Reconnect with jittered delays of 1, 2, 4, 8, 16, 32, then 60 seconds. Remove the socket on clean shutdown.

- [ ] **Step 4: Run IPC tests**

Run: `swift test --filter AgentHubIPCTests`

Expected: PASS and no socket remains after shutdown.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubIPC Tests/AgentHubIPCTests
git commit -m "feat: add private daemon IPC"
```

## Task 6: Implement the Codex App Server JSON-RPC transport

**Files:**
- Create: `Sources/AgentHubCodex/JSONValue.swift`
- Create: `Sources/AgentHubCodex/JSONRPC.swift`
- Create: `Sources/AgentHubCodex/CodexProcess.swift`
- Create: `Sources/AgentHubCodex/CodexRPCClient.swift`
- Create: `Tests/Fixtures/Codex/initialize.jsonl`
- Create: `Tests/AgentHubCodexTests/CodexRPCClientTests.swift`

**Interfaces:**
- Produces actor `CodexRPCClient` and process-backed `LineTransport`.

- [ ] **Step 1: Write failing response-correlation and server-request tests**

```swift
func testOutOfOrderResponsesResumeCorrectCallers() async throws {
    let transport = ScriptedLineTransport()
    let client = CodexRPCClient(transport: transport)
    async let first = client.call(method: "thread/read", params: .object(["threadId": .string("a")]))
    async let second = client.call(method: "account/rateLimits/read", params: nil)
    transport.receive(#"{"id":2,"result":{"rateLimits":null}}"#)
    transport.receive(#"{"id":1,"result":{"thread":{"id":"a"}}}"#)
    let firstValue = try await first
    let secondValue = try await second
    XCTAssertEqual(firstValue["thread"]?["id"], .string("a"))
    XCTAssertEqual(secondValue["rateLimits"], .null)
}

func testApprovalLineIsServerRequest() throws {
    let message = try decodeRPC(#"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"t"}}"#)
    XCTAssertTrue(message.isServerRequest)
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --filter CodexRPCClientTests`

Expected: FAIL because JSON-RPC types do not exist.

- [ ] **Step 3: Implement process and RPC actors**

```swift
public protocol LineTransport: Sendable {
    func start() async throws
    func send(line: Data) async throws
    func lines() async -> AsyncThrowingStream<Data, Error>
    func stop() async
}

public actor CodexRPCClient {
    public init(transport: any LineTransport)
    public func start(clientName: String, clientVersion: String) async throws
    public func call(method: String, params: JSONValue?) async throws -> JSONValue
    public func respond(id: JSONRPCID, result: JSONValue) async throws
    public func messages() -> AsyncStream<JSONRPCMessage>
    public func stop() async
}
```

`CodexProcess` resolves an executable whose basename is exactly `codex`, launches arguments `app-server`, drains stderr into a credential-redacted ring buffer, and converts exit into one terminal error. `start` sends `initialize`, waits for success, and sends `initialized`. EOF and stop resume every pending continuation exactly once.

- [ ] **Step 4: Run transport tests**

Run: `swift test --filter CodexRPCClientTests`

Expected: PASS for out-of-order replies, malformed frames, server requests, EOF, and redaction.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubCodex Tests/AgentHubCodexTests Tests/Fixtures/Codex
git commit -m "feat: connect to Codex app server"
```

## Task 7: Map Codex sessions, subagents, turns, approvals, and quota

**Files:**
- Create: `Sources/AgentHubCodex/CodexWireModels.swift`
- Create: `Sources/AgentHubCodex/CodexAdapter.swift`
- Create: `Tests/Fixtures/Codex/thread-status.jsonl`
- Create: `Tests/Fixtures/Codex/subagent-tree.jsonl`
- Create: `Tests/Fixtures/Codex/rate-limits.jsonl`
- Create: `Tests/AgentHubCodexTests/CodexAdapterTests.swift`

**Interfaces:**
- Implements `AgentAdapter` for `.codex`.
- Produces L1 launch, status, children, turns, input, approvals, jump, and quota.

- [ ] **Step 1: Write failing mapping tests**

```swift
func testWaitingApprovalMapsToNormalizedStatus() async throws {
    let snapshot = try await makeAdapter("thread-status").reconcile()
    XCTAssertEqual(snapshot.sessions.first?.status, .waitingPermission)
}

func testSpawnedThreadUsesExplicitParent() async throws {
    let snapshot = try await makeAdapter("subagent-tree").reconcile()
    XCTAssertEqual(snapshot.nodes.first?.parentNativeID, "root-thread")
}

func testRateLimitProducesTwoWindows() async throws {
    let windows = try await makeAdapter("rate-limits").quotaWindows()
    XCTAssertEqual(windows.count, 2)
    XCTAssertTrue(windows.allSatisfy { $0.source == "codex-app-server" })
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --filter CodexAdapterTests`

Expected: FAIL because Codex DTOs and adapter do not exist.

- [ ] **Step 3: Implement the narrow DTOs and adapter**

```swift
public actor CodexAdapter: AgentAdapter {
    public let provider: Provider = .codex
    public init(accountID: String, rpc: CodexRPCClient, now: @escaping @Sendable () -> Date = Date.init)
    public func launch(_ request: LaunchRequest) async throws -> ProviderSessionRef
    public func reconcile() async throws -> AdapterSnapshot
    public func eventStream() async -> AsyncStream<AgentEvent>
    public func recentTurns(for session: ProviderSessionRef, limit: Int) async throws -> [VisibleTurn]
    public func send(_ input: AgentInput, to session: ProviderSessionRef) async throws
    public func resolve(_ request: ProviderRequestRef, decision: RequestDecision) async throws
    public func jumpTarget(for session: ProviderSessionRef) async -> JumpTarget
    public func quotaWindows() async throws -> [QuotaWindow]
}
```

Decode only required fields: thread ID/name/status/cwd/git/source/parent, visible turn text, approval identifiers/decisions, and rate-limit percentage/duration/reset. Use `thread/list`, `thread/loaded/list`, `thread/status/changed`, `thread/turns/list` with `itemsView: summary`, and `account/rateLimits/read`. Clamp turns to 20. Managed Codex jump returns AgentHub detail because AgentHub owns the client.

- [ ] **Step 4: Run all Codex tests**

Run: `swift test --filter AgentHubCodexTests`

Expected: PASS for status, hierarchy, caps, sparse quota updates, approvals, and disconnection.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubCodex Tests/AgentHubCodexTests Tests/Fixtures/Codex
git commit -m "feat: normalize managed Codex sessions"
```

## Task 8: Route requests and handoffs safely

**Files:**
- Create: `Sources/AgentHubCore/HandoffRouter.swift`
- Create: `Sources/AgentHubDaemon/RequestService.swift`
- Create: `Sources/AgentHubDaemon/HandoffService.swift`
- Create: `Tests/AgentHubCoreTests/HandoffRouterTests.swift`
- Create: `Tests/AgentHubDaemonTests/RequestServiceTests.swift`
- Create: `Tests/AgentHubDaemonTests/HandoffServiceTests.swift`

**Interfaces:**
- Produces `HandoffRouter`, actor `RequestService`, and actor `HandoffService`.

- [ ] **Step 1: Write failing queue and race tests**

```swift
func testWorkingTargetQueuesWithoutSending() async throws {
    let adapter = SpyAdapter()
    let service = HandoffService(store: inMemoryStore(), adapters: [.codex: adapter])
    try await service.submit(.fixture(), target: .fixture(status: .working), pendingRequests: [])
    XCTAssertTrue(adapter.sentInputs.isEmpty)
}

func testPendingRequestBlocksDelivery() {
    XCTAssertEqual(HandoffRouter.eligibility(target: .fixture(status: .waitingPermission), pendingRequests: [.fixture()]), .blockedByRequest)
}

func testResolvedRequestCannotSubmitAgain() async throws {
    let request = PendingRequest.fixture(state: .resolved)
    let service = RequestService(store: resolvedRequestStore(request), adapters: [.codex: SpyAdapter()])
    do {
        try await service.resolve(id: request.id, decision: .accept)
        XCTFail("resolved request was submitted twice")
    } catch {
        XCTAssertEqual(error as? RequestServiceError, .notPending)
    }
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --filter 'HandoffRouterTests|RequestServiceTests|HandoffServiceTests'`

Expected: FAIL because services do not exist.

- [ ] **Step 3: Implement exact transitions**

```swift
public enum HandoffEligibility: Equatable, Sendable { case deliverNow, queue, blockedByRequest, manualOnly(String) }
public enum HandoffRouter {
    public static func eligibility(target: AgentSession, pendingRequests: [PendingRequest]) -> HandoffEligibility
    public static func render(_ envelope: MessageEnvelope, source: AgentSession) -> String
}
public actor RequestService { public func resolve(id: UUID, decision: RequestDecision) async throws }
public actor HandoffService {
    public func submit(_ envelope: MessageEnvelope, target: AgentSession, pendingRequests: [PendingRequest]) async throws
    public func sessionBecameIdle(_ session: AgentSession, pendingRequests: [PendingRequest]) async
    public func retry(id: UUID) async throws
}
```

Define `public enum RequestServiceError: Error, Equatable { case notFound, notPending, unsupportedProvider }`. The Task 9 test file defines `CoordinatorHarness` around a temporary store and spy adapter. The Task 10 test file defines `FakeDaemonClient` conforming to `DaemonClientProtocol`. Task 12 test files define `CodexVerticalSliceHarness` and `PrivacyHarness` from production components rather than alternate implementations.

Move requests transactionally from pending to resolving, call the exact provider reference, then resolve; provider-already-resolved is idempotent success. Render provenance and user note. Enforce 20 turns, target idle, no pending request, and five-minute expiry.

- [ ] **Step 4: Run core and daemon safety tests**

Run: `swift test --filter 'AgentHubCoreTests|AgentHubDaemonTests'`

Expected: PASS with zero sends to working or waiting targets.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubCore Sources/AgentHubDaemon Tests/AgentHubCoreTests Tests/AgentHubDaemonTests
git commit -m "feat: queue safe Codex approvals and handoffs"
```

## Task 9: Assemble the coordinator and daemon API

**Files:**
- Create: `Sources/AgentHubDaemon/Coordinator.swift`
- Create: `Sources/AgentHubDaemon/DaemonAPI.swift`
- Replace: `Sources/agenthubd/main.swift`
- Create: `Tests/AgentHubDaemonTests/CoordinatorTests.swift`
- Create: `Tests/AgentHubDaemonTests/DaemonAPITests.swift`

**Interfaces:**
- Produces actor `Coordinator` as the only normalized-state writer.
- Produces `DaemonAPI.handle(_:)` for all IPC commands.

- [ ] **Step 1: Write failing restart and idempotent-launch tests**

```swift
func testReconcileRunsBeforeRecoveredActionsEnable() async throws {
    let harness = try await CoordinatorHarness.persistedRequest(providerResolved: true)
    try await harness.coordinator.start()
    let snapshot = await harness.coordinator.snapshot()
    XCTAssertEqual(snapshot.requests.values.first?.state, .resolved)
}

func testRepeatedLaunchRequestReturnsSameSessionID() async throws {
    let api = makeDaemonAPI()
    let request = LaunchRequest.fixture(clientRequestID: "launch-1")
    let first = await api.handle(.launchCodex(request))
    let second = await api.handle(.launchCodex(request))
    XCTAssertEqual(first, second)
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --filter 'CoordinatorTests|DaemonAPITests'`

Expected: FAIL because coordinator and API do not exist.

- [ ] **Step 3: Implement orchestration and startup ordering**

```swift
public actor Coordinator {
    public init(store: AgentHubStore, adapters: [Provider: any AgentAdapter], clock: any Clock<Duration>)
    public func start() async throws
    public func stop() async
    public func snapshot() -> AgentHubState
    public func launch(provider: Provider, request: LaunchRequest) async throws -> UUID
    public func apply(_ event: AgentEvent) async throws
}

public actor DaemonAPI {
    public init(coordinator: Coordinator, requests: RequestService, handoffs: HandoffService)
    public func handle(_ command: DaemonCommand) async -> DaemonReply
}
```

Startup order: migrate database, load snapshot, start Codex RPC, reconcile provider, reconcile requests/envelopes, bind IPC, publish events. `main.swift` uses `~/Library/Application Support/AgentHub` for database/socket, handles SIGTERM/SIGINT, and redacts errors. Daemon exit preserves provider work.

- [ ] **Step 4: Run daemon tests and config smoke check**

```bash
swift test --filter AgentHubDaemonTests
swift run agenthubd --check-config
```

Expected: tests pass; config check prints validated paths without starting a daemon or exposing credentials.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubDaemon Sources/agenthubd Tests/AgentHubDaemonTests
git commit -m "feat: coordinate persistent Codex daemon"
```

## Task 10: Build the native dashboard

**Files:**
- Replace: `App/AgentHubApp.swift`
- Delete: `App/PlaceholderView.swift`
- Create: `App/AppEnvironment.swift`
- Create: `App/DaemonClient.swift`
- Create: `App/Features/Dashboard/DashboardView.swift`
- Create: `App/Features/Dashboard/DashboardViewModel.swift`
- Create: `App/Features/Sessions/SessionTreeView.swift`
- Create: `App/Features/Sessions/SessionDetailView.swift`
- Create: `App/Features/Requests/RequestInboxView.swift`
- Create: `App/Features/Quota/QuotaStripView.swift`
- Create: `App/Features/Health/AdapterHealthView.swift`
- Create: `Tests/AgentHubAppTests/DashboardViewModelTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces `DashboardViewModel` and the MVP three-column interface.

- [ ] **Step 1: Write failing view-model tests**

```swift
@MainActor
func testResolveDisablesButtonsImmediately() async {
    let client = FakeDaemonClient(snapshot: .fixture(pendingRequest: true))
    let model = DashboardViewModel(client: client)
    await model.connect()
    await model.resolve(requestID, decision: .accept)
    XCTAssertFalse(model.canResolve(requestID))
}

@MainActor
func testJumpSelectsManagedDetail() async {
    let model = DashboardViewModel(client: FakeDaemonClient(jump: .agentHubDetail(sessionNativeID: "codex-1")))
    await model.jump(to: sessionID)
    XCTAssertEqual(model.selectedSessionID, sessionID)
}
```

- [ ] **Step 2: Verify app tests fail**

Run: `xcodegen generate && xcodebuild test -project AgentHub.xcodeproj -scheme AgentHubApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`

Expected: FAIL because dashboard and app test target do not exist.

- [ ] **Step 3: Implement view model and minimal UI**

Define the app-side seam before the view model so tests do not open a real socket:

```swift
enum ConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case disconnected(String)
}

protocol DaemonClientProtocol: Sendable {
    func connect() async throws
    func send(_ command: DaemonCommand) async throws -> DaemonReply
    func events() async -> AsyncStream<DaemonEvent>
}

struct DaemonClient: DaemonClientProtocol {
    init(socketPath: String)
    func connect() async throws
    func send(_ command: DaemonCommand) async throws -> DaemonReply
    func events() async -> AsyncStream<DaemonEvent>
}
```

```swift
@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var state: AgentHubState = .empty
    @Published var selectedSessionID: UUID?
    @Published private(set) var connection: ConnectionState = .connecting
    init(client: any DaemonClientProtocol)
    func connect() async
    func launchCodex(cwd: String, prompt: String) async
    func resolve(_ id: UUID, decision: RequestDecision) async
    func send(_ text: String, to sessionID: UUID) async
    func handoff(source: UUID, target: UUID, turnLimit: Int, note: String?) async
    func jump(to sessionID: UUID) async
    func canResolve(_ id: UUID) -> Bool
}
```

Use `NavigationSplitView`: quota/filter header, nested running/recent sidebar, session detail center, request inbox inspector. Show L1 badges on actions. Quota shows used percent/reset/source/stale. Disable a request after click until daemon acknowledgement. Composer targets managed L1 sessions only.

Extend `project.yml` with an `AgentHubAppTests` `bundle.unit-test` target sourced from `Tests/AgentHubAppTests`, depending on `AgentHubApp`, `AgentHubCore`, and `AgentHubIPC`. Add that test target to the generated `AgentHubApp` scheme's test action. `AppEnvironment` selects `FakeDaemonClient` only when `AGENTHUB_FIXTURE_MODE=1`; production always constructs `DaemonClient` with the user application-support socket path.

- [ ] **Step 4: Run app and package tests**

Run: `./scripts/check.sh`

Expected: all tests and unsigned app build pass.

- [ ] **Step 5: Run fixture-mode UI smoke check**

Run: `AGENTHUB_FIXTURE_MODE=1 open .build/xcode/Build/Products/Debug/AgentHubApp.app`

Expected: one root Codex session, nested subagent, pending approval, two quota windows, and adapter-health banner appear without contacting Codex.

- [ ] **Step 6: Commit**

```bash
git add App Tests/AgentHubAppTests project.yml
git rm App/PlaceholderView.swift
git commit -m "feat: add native AgentHub Codex dashboard"
```

## Task 11: Package a safe per-user LaunchAgent

**Files:**
- Create: `Support/com.agenthub.daemon.plist`
- Create: `Support/install-daemon.sh`
- Create: `Support/uninstall-daemon.sh`
- Create: `App/DaemonInstallation.swift`
- Create: `Tests/AgentHubAppTests/DaemonInstallationTests.swift`
- Modify: `project.yml`
- Modify: `scripts/check.sh`

**Interfaces:**
- Produces `DaemonInstallation.status`, `install`, `uninstall`.

- [ ] **Step 1: Write failing path and plist tests**

```swift
func testInstallerUsesUserLaunchAgentsOnly() {
    let paths = DaemonInstallation.paths(home: URL(fileURLWithPath: "/Users/tester"))
    XCTAssertEqual(paths.plist.path, "/Users/tester/Library/LaunchAgents/com.agenthub.daemon.plist")
}

func testPlistDoesNotRequestRoot() throws {
    let plist = try DaemonInstallation.renderPlist(executable: "/Applications/AgentHub.app/Contents/Helpers/agenthubd")
    XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
    XCTAssertNil(plist["UserName"])
}
```

- [ ] **Step 2: Verify tests fail**

Run: `xcodebuild test -project AgentHub.xcodeproj -scheme AgentHubApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AgentHubAppTests/DaemonInstallationTests`

Expected: FAIL because installation support does not exist.

- [ ] **Step 3: Implement user-scoped installation**

Copy the embedded daemon to `~/Library/Application Support/AgentHub/bin/agenthubd`, atomically write mode-0600 plist to `~/Library/LaunchAgents/com.agenthub.daemon.plist`, then run:

```bash
launchctl bootout "gui/$(id -u)/com.agenthub.daemon" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.agenthub.daemon.plist"
launchctl kickstart -k "gui/$(id -u)/com.agenthub.daemon"
```

Never use `sudo`. Uninstall performs `launchctl bootout` and moves the plist and helper copy to the user's Trash. Add XcodeGen copy phases for helper and template.

- [ ] **Step 4: Run packaging and dry-run checks**

```bash
./scripts/check.sh
Support/install-daemon.sh --dry-run
```

Expected: build/tests pass; dry-run lists only user-home paths and mutates nothing.

- [ ] **Step 5: Commit**

```bash
git add Support App/DaemonInstallation.swift Tests/AgentHubAppTests/DaemonInstallationTests project.yml scripts/check.sh
git commit -m "feat: package user-scoped AgentHub daemon"
```

## Task 12: Add vertical-slice acceptance and privacy gates

**Files:**
- Create: `Tests/AgentHubDaemonTests/CodexVerticalSliceTests.swift`
- Create: `Tests/AgentHubDaemonTests/PrivacyTests.swift`
- Create: `Tests/AgentHubCodexTests/LiveCodexTests.swift`
- Create: `docs/development.md`
- Modify: `README.md`
- Modify: `scripts/check.sh`

**Interfaces:**
- Produces ordinary gate `scripts/check.sh` and opt-in gate `AGENTHUB_RUN_LIVE_CODEX_TESTS=1 swift test --filter LiveCodexTests`.

- [ ] **Step 1: Write failing acceptance and privacy tests**

```swift
func testLaunchApprovalHandoffQuotaAndRestart() async throws {
    let harness = try await CodexVerticalSliceHarness.start()
    let source = try await harness.launch(prompt: "inspect the project")
    let target = try await harness.launch(prompt: "wait for a handoff")
    await harness.codex.emitApproval(threadID: source.nativeID, requestID: "approval-1")
    try await harness.resolve(requestID: "approval-1", decision: .accept)
    try await harness.handoff(source: source, target: target, turns: 1)
    let deliveries = await harness.codex.deliveries(to: target.nativeID)
    let snapshot = try await harness.snapshot()
    XCTAssertEqual(deliveries.count, 1)
    XCTAssertFalse(snapshot.quotas.isEmpty)
    try await harness.restartDaemon()
    let count = try await harness.sessionCount()
    XCTAssertEqual(count, 2)
}

func testDatabaseAndLogsContainNoSecrets() async throws {
    let harness = try await PrivacyHarness(secret: "sk-test-never-persist")
    try await harness.exerciseAllPaths()
    let database = String(decoding: try harness.databaseBytes(), as: UTF8.self)
    let logs = String(decoding: try harness.logBytes(), as: UTF8.self)
    XCTAssertFalse(database.contains("sk-test-never-persist"))
    XCTAssertFalse(logs.contains("sk-test-never-persist"))
}
```

- [ ] **Step 2: Verify tests fail**

Run: `swift test --filter 'CodexVerticalSliceTests|PrivacyTests'`

Expected: FAIL until production coordinator wiring satisfies the harness.

- [ ] **Step 3: Build deterministic harnesses and live-test guard**

Use the production coordinator, temporary database, Unix socket, scripted Codex transport, and manual clock. Add redaction and IPC idempotency until tests pass. Every live test begins with:

```swift
try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTHUB_RUN_LIVE_CODEX_TESTS"] == "1")
```

The live test creates a temporary thread with `Reply with the single word READY and do not use tools`, waits for idle, verifies one assistant turn, reads quota, and archives the thread. It never approves tools or edits files.

- [ ] **Step 4: Document exact operator commands**

`docs/development.md` covers prerequisites, Xcode selection, generation, fixture mode, daemon dry-run/install/uninstall, database/socket paths, redaction, ordinary checks, and opt-in live test. README links the design, roadmap, plan, and development guide.

- [ ] **Step 5: Run the complete non-live gate**

```bash
./scripts/check.sh
git diff --check
```

Expected: all non-live tests pass and diff check is silent.

- [ ] **Step 6: Run live smoke only with explicit consent**

```bash
AGENTHUB_RUN_LIVE_CODEX_TESTS=1 swift test --filter LiveCodexTests
```

Expected: PASS, temporary thread archived, no project file changed.

- [ ] **Step 7: Commit**

```bash
git add Tests scripts/check.sh docs/development.md README.md
git commit -m "test: verify AgentHub Codex vertical slice"
```

## Completion gate

Run:

```bash
./scripts/check.sh
git status --short
```

Expected: the complete gate passes, `git status --short` prints nothing, and fixture-mode manual inspection confirms session tree, pending request, quota strip, handoff state, reliability badges, and adapter health.
