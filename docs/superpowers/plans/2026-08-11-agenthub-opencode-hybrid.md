# AgentHub Hybrid OpenCode Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a production-ready OpenCode adapter that manages its own lazy local server, attaches to current-user Desktop/TUI servers, normalizes sessions and requests, and participates in AgentHub launch, navigation, and handoff workflows.

**Architecture:** A new `AgentHubOpenCode` target implements a hybrid `AgentAdapter` over an internal endpoint registry. Managed and attached endpoints share one HTTP/SSE protocol client, while the existing coordinator, store, IPC, and SwiftUI layers receive small generic extensions for endpoint summaries, structured questions, provider selection, and secure manual attachment. `AgentHubSecurity` owns Keychain access so secrets never enter SQLite or daemon IPC.

**Tech Stack:** Swift 6, macOS 14, Foundation `URLSession`, Security.framework, GRDB 7.10.0, SwiftNIO 2.87–2.97 for test HTTP servers, XCTest, SwiftUI/AppKit, OpenCode HTTP API validated against 1.18.10.

## Global Constraints

- Production connections are loopback-only: `127.0.0.1` or `[::1]`; remote hosts and broad port scanning are rejected.
- Automatic discovery is limited to listening sockets owned by current-user OpenCode Desktop/TUI process trees.
- The managed server binds loopback on a random port, receives a random Basic Auth secret through its environment, inherits normal user configuration, and never uses `--pure` in production.
- OpenCode Go quota remains unavailable in this plan; do not create percentages, reset times, or provider recommendations.
- Provider-native session identity is `openCode/local-default/ses_...`; endpoint URL and port never participate in identity.
- Preview reads are capped at 20 messages; persisted previews retain at most 3 turns or 256 KiB and expire 24 hours after completion.
- Keychain references may be persisted; passwords, Authorization headers, prompts, raw SSE archives, and question answers must not enter SQLite, IPC snapshots, or diagnostics.
- Default tests send no OpenCode prompt and consume no OpenCode Go inference quota. The opt-in live test uses isolated configuration and only health/create/read/delete operations.
- Unknown JSON fields and unknown SSE event types are ignored without disconnecting the adapter.
- One unhealthy OpenCode endpoint must not disconnect Codex or healthy OpenCode routes.
- Follow TDD for every behavior: observe the focused test fail, add the minimum implementation, then observe it pass before committing.

---

## File structure

### New production files

- `Sources/AgentHubSecurity/KeychainCredentialStore.swift` — generic-password Keychain read/write/delete with opaque references.
- `Sources/AgentHubOpenCode/OpenCodeWireModels.swift` — OpenCode request/response/event DTOs and normalized mapping helpers.
- `Sources/AgentHubOpenCode/ServerSentEvents.swift` — incremental SSE framing and decoding.
- `Sources/AgentHubOpenCode/OpenCodeHTTPClient.swift` — authenticated loopback HTTP API implementation.
- `Sources/AgentHubOpenCode/OpenCodeEndpointRegistry.swift` — endpoint health, session observations, deduplication, and route ranking.
- `Sources/AgentHubOpenCode/OpenCodeManagedServer.swift` — lazy `opencode serve` process lifecycle, secret generation, readiness, and restart backoff.
- `Sources/AgentHubOpenCode/OpenCodeDiscovery.swift` — current-user process-tree/listening-socket discovery.
- `Sources/AgentHubOpenCode/OpenCodeHybridAdapter.swift` — `AgentAdapter` orchestration, reconciliation, event relays, request routing, and jumps.
- `App/JumpOpener.swift` — AppKit activation for a provider-selected application target.
- `App/Features/OpenCode/OpenCodeSettingsView.swift` — endpoint health, manual loopback attachment, authentication, and detach UI.

### New tests and fixtures

- `Tests/AgentHubSecurityTests/KeychainCredentialStoreTests.swift`
- `Tests/AgentHubOpenCodeTests/OpenCodeHTTPClientTests.swift`
- `Tests/AgentHubOpenCodeTests/ServerSentEventsTests.swift`
- `Tests/AgentHubOpenCodeTests/OpenCodeEndpointRegistryTests.swift`
- `Tests/AgentHubOpenCodeTests/OpenCodeManagedServerTests.swift`
- `Tests/AgentHubOpenCodeTests/OpenCodeDiscoveryTests.swift`
- `Tests/AgentHubOpenCodeTests/OpenCodeHybridAdapterTests.swift`
- `Tests/AgentHubOpenCodeTests/FakeOpenCodeServer.swift`
- `Tests/AgentHubOpenCodeTests/LiveOpenCodeTests.swift`
- `Tests/AgentHubDaemonTests/OpenCodeVerticalSliceTests.swift`
- `Tests/Fixtures/OpenCode/health.json`
- `Tests/Fixtures/OpenCode/sessions.json`
- `Tests/Fixtures/OpenCode/permissions.json`
- `Tests/Fixtures/OpenCode/questions.json`
- `Tests/Fixtures/OpenCode/events.sse`

### Existing files modified

- `Package.swift` — add OpenCode/Security products, targets, and test dependencies.
- `project.yml` — link `AgentHubSecurity` into the desktop application.
- `Sources/AgentHubCore/Models.swift` — launch options, structured request fields, endpoint summaries, state/events.
- `Sources/AgentHubCore/AgentAdapter.swift` — configurable endpoint adapter refinement.
- `Sources/AgentHubCore/StateReducer.swift` — endpoint upsert/removal and authoritative request expiry.
- `Sources/AgentHubPersistence/Database.swift` — `provider-endpoints-v2` migration.
- `Sources/AgentHubPersistence/Store.swift` — endpoint persistence/removal and snapshot restore.
- `Sources/AgentHubIPC/Messages.swift` — generic launch and endpoint commands; protocol version 2.
- `Sources/AgentHubDaemon/Coordinator.swift` — endpoint restore/configuration and snapshot merging.
- `Sources/AgentHubDaemon/DaemonAPI.swift` — generic launch and endpoint command routing.
- `Sources/agenthubd/main.swift` — construct and stop the OpenCode adapter and managed server.
- `App/AppEnvironment.swift` — provide Keychain and mixed-provider fixture state.
- `App/Features/Dashboard/DashboardViewModel.swift` — provider launch, endpoint actions, secure credential lifecycle, and jump opening.
- `App/Features/Dashboard/DashboardView.swift` — provider-aware task sheet and settings presentation.
- `App/Features/Requests/RequestInboxView.swift` — OpenCode permission/question controls.
- `App/Features/Sessions/SessionTreeView.swift` — provider/surface badges and provider-neutral empty state.
- `App/Features/Sessions/SessionDetailView.swift` — permit L1 input for attached OpenCode sessions and show surfaces.
- Existing Core, IPC, daemon, and app tests — update exhaustive switches and generic launch expectations.

---

### Task 1: Add generic contracts and Swift package boundaries

**Files:**
- Modify: `Package.swift:7-84`
- Modify: `Sources/AgentHubCore/Models.swift:43-427`
- Modify: `Sources/AgentHubCore/AgentAdapter.swift:3-20`
- Modify: `Tests/AgentHubCoreTests/ModelTests.swift`

**Interfaces:**
- Produces: `LaunchModelSelection`, optional `LaunchRequest.agent/model`, `RequestField`, `ProviderEndpoint`, `ProviderEndpointAttachment`, `ProviderEndpointCredentialBinding`, `EndpointConfigurableAdapter`, and endpoint snapshot state.
- Consumes: existing `Provider`, `AgentAdapter`, `AgentHubState`, `PendingRequest`, and `AdapterSnapshot`.

- [ ] **Step 1: Write failing Core tests for backward-compatible launch data, structured request fields, and endpoint snapshot coding**

```swift
func testLaunchRequestDefaultsProviderOptionsToNil() {
    let request = LaunchRequest(clientRequestID: "r1", cwd: "/tmp/repo", prompt: "work")
    XCTAssertNil(request.agent)
    XCTAssertNil(request.model)
}

func testEndpointStateRoundTripsThroughCodable() throws {
    let endpoint = ProviderEndpoint(
        id: "openCode:manual:41789",
        provider: .openCode,
        origin: .manual,
        baseURL: "http://127.0.0.1:41789",
        credentialReference: "credential-ref",
        connected: true,
        version: "1.18.10",
        message: nil,
        lastSeenAt: Date(timeIntervalSince1970: 10)
    )
    let state = AgentHubState(endpoints: [endpoint.id: endpoint])
    let restored = try JSONDecoder.agentHub.decode(
        AgentHubState.self,
        from: JSONEncoder.agentHub.encode(state)
    )
    XCTAssertEqual(restored.endpoints[endpoint.id], endpoint)
}
```

- [ ] **Step 2: Run the focused Core tests and verify the new types/cases are missing**

Run: `swift test --filter ModelTests`

Expected: FAIL to compile because `ProviderEndpoint`, `LaunchRequest.agent`, and endpoint events do not exist.

- [ ] **Step 3: Add the exact generic contracts and defaults**

```swift
public struct LaunchModelSelection: Codable, Equatable, Sendable {
    public let providerID: String
    public let modelID: String
    public let variant: String?
}

public struct RequestField: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let prompt: String
    public let choices: [String]
    public let allowsMultiple: Bool
    public let allowsFreeText: Bool
}

public enum ProviderEndpointOrigin: String, Codable, Sendable {
    case managed, desktop, tui, manual
}

public struct ProviderEndpoint: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let origin: ProviderEndpointOrigin
    public let baseURL: String
    public let credentialReference: String?
    public var connected: Bool
    public var version: String?
    public var message: String?
    public var lastSeenAt: Date
}

public struct ProviderEndpointAttachment: Codable, Equatable, Sendable {
    public let provider: Provider
    public let baseURL: String
    public let credentialReference: String?
}

public struct ProviderEndpointCredentialBinding: Codable, Equatable, Sendable {
    public let provider: Provider
    public let endpointID: String
    public let credentialReference: String
}
```

Extend `LaunchRequest` with optional `agent` and `model` initializer arguments defaulting to `nil`. Extend `PendingRequest` with `fields: [RequestField] = []` and a custom `Decodable` implementation that supplies `[]` when older persisted request bodies lack the key. Add `endpoints: [String: ProviderEndpoint] = [:]` to `AgentHubState`, plus `endpoints: [ProviderEndpoint] = []` and `requestsAreAuthoritative: Bool = false` to `AdapterSnapshot`. Endpoint events are added atomically with persistence in Task 9.

Add this refinement without changing existing adapter requirements:

```swift
public protocol EndpointConfigurableAdapter: AgentAdapter {
    func restoreEndpoint(_ endpoint: ProviderEndpoint) async throws
    func attachEndpoint(_ attachment: ProviderEndpointAttachment) async throws -> ProviderEndpoint
    func authenticateEndpoint(_ binding: ProviderEndpointCredentialBinding) async throws -> ProviderEndpoint
    func detachEndpoint(id: String) async throws
}
```

Add `AgentHubSecurity`, `AgentHubOpenCode`, `AgentHubSecurityTests`, and `AgentHubOpenCodeTests` targets to `Package.swift`. `AgentHubOpenCode` depends on `AgentHubCore` and `AgentHubSecurity`; its tests also depend on `NIOCore`, `NIOPosix`, and `NIOHTTP1` from the already-pinned SwiftNIO package. Link Security.framework to the Security and OpenCode targets. Add both products to `AgentHubDaemon`/`agenthubd` dependencies where needed.

- [ ] **Step 4: Update exhaustive Core fixtures and run the focused tests**

Run: `swift test --filter AgentHubCoreTests`

Expected: PASS with endpoint state round-tripping and all existing model tests unchanged.

- [ ] **Step 5: Commit the contracts**

```bash
git add Package.swift Sources/AgentHubCore Tests/AgentHubCoreTests
git commit -m "feat: add provider endpoint contracts"
```

---

### Task 2: Add Keychain credential storage

**Files:**
- Create: `Sources/AgentHubSecurity/KeychainCredentialStore.swift`
- Create: `Tests/AgentHubSecurityTests/KeychainCredentialStoreTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Produces: `CredentialStoring`, `KeychainCredentialStore`, and opaque UUID references shared by app and daemon.
- Consumes: Security.framework generic-password APIs.

- [ ] **Step 1: Write failing round-trip, overwrite, and delete tests with a unique test service**

```swift
func testSaveReadOverwriteAndDelete() throws {
    let store = KeychainCredentialStore(service: "com.agenthub.tests.\(UUID().uuidString)")
    let reference = UUID().uuidString
    defer { try? store.delete(reference: reference) }

    try store.save("first", reference: reference)
    XCTAssertEqual(try store.read(reference: reference), "first")
    try store.save("second", reference: reference)
    XCTAssertEqual(try store.read(reference: reference), "second")
    try store.delete(reference: reference)
    XCTAssertThrowsError(try store.read(reference: reference))
}
```

- [ ] **Step 2: Run the Security tests and verify the store is missing**

Run: `swift test --filter AgentHubSecurityTests`

Expected: FAIL to compile because `KeychainCredentialStore` does not exist.

- [ ] **Step 3: Implement a sendable generic-password store**

```swift
public protocol CredentialStoring: Sendable {
    func save(_ secret: String, reference: String) throws
    func read(reference: String) throws -> String
    func delete(reference: String) throws
}

public struct KeychainCredentialStore: CredentialStoring, Sendable {
    public init(service: String = "com.agenthub.opencode")
    public func save(_ secret: String, reference: String) throws
    public func read(reference: String) throws -> String
    public func delete(reference: String) throws
}
```

Use `kSecClassGenericPassword`, the fixed service, and `reference` as `kSecAttrAccount`. Treat `errSecItemNotFound` as a typed `CredentialStoreError.notFound`; never include a secret in an error description. Update existing items with `SecItemUpdate`, zero temporary `Data` buffers where practical, and link Security.framework in `Package.swift`.

- [ ] **Step 4: Run the Keychain test twice to prove cleanup and overwrite behavior**

Run: `swift test --filter AgentHubSecurityTests && swift test --filter AgentHubSecurityTests`

Expected: both runs PASS with no persistent test item collision.

- [ ] **Step 5: Commit Keychain support**

```bash
git add Package.swift Sources/AgentHubSecurity Tests/AgentHubSecurityTests
git commit -m "feat: store endpoint credentials in Keychain"
```

---

### Task 3: Implement OpenCode HTTP and SSE protocol primitives

**Files:**
- Create: `Sources/AgentHubOpenCode/OpenCodeWireModels.swift`
- Create: `Sources/AgentHubOpenCode/ServerSentEvents.swift`
- Create: `Sources/AgentHubOpenCode/OpenCodeHTTPClient.swift`
- Create: `Tests/AgentHubOpenCodeTests/OpenCodeHTTPClientTests.swift`
- Create: `Tests/AgentHubOpenCodeTests/ServerSentEventsTests.swift`
- Create: `Tests/Fixtures/OpenCode/health.json`
- Create: `Tests/Fixtures/OpenCode/sessions.json`
- Create: `Tests/Fixtures/OpenCode/permissions.json`
- Create: `Tests/Fixtures/OpenCode/questions.json`
- Create: `Tests/Fixtures/OpenCode/events.sse`

**Interfaces:**
- Produces: `OpenCodeAPI`, `OpenCodeHTTPClient`, DTOs, `OpenCodeEvent`, and `ServerSentEventParser`.
- Consumes: `CredentialStoring` for attached Basic Auth references; ephemeral managed credentials are passed directly to the client initializer.

- [ ] **Step 1: Write failing request-shape and decoding tests using a custom `URLProtocol`**

```swift
func testCreateSessionUsesDirectoryAndBasicAuth() async throws {
    let response = #"{"id":"ses_1","title":"Task","directory":"/tmp/repo","time":{"created":1700000000000,"updated":1700000000000}}"#
    let recorder = URLRequestRecorder(status: 200, body: Data(response.utf8))
    let client = makeClient(recorder: recorder, username: "opencode", password: "secret")

    _ = try await client.createSession(directory: "/tmp/repo", title: "Task", agent: nil, model: nil)

    XCTAssertEqual(recorder.request?.httpMethod, "POST")
    XCTAssertEqual(recorder.request?.url?.path, "/session")
    XCTAssertEqual(recorder.request?.url?.query, "directory=/tmp/repo".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
    XCTAssertEqual(recorder.request?.value(forHTTPHeaderField: "Authorization"), "Basic b3BlbmNvZGU6c2VjcmV0")
}

func testPermissionReplyEncodesAlways() async throws {
    try await client.replyPermission(id: "per_1", reply: .always, message: nil, directory: "/tmp/repo")
    XCTAssertEqual(recorder.jsonBody?["reply"] as? String, "always")
}
```

- [ ] **Step 2: Write failing incremental SSE tests**

```swift
func testParserHandlesFragmentedFramesAndUnknownEvent() throws {
    var parser = ServerSentEventParser()
    XCTAssertTrue(try parser.append(Data("event: message.part.updated\ndata: {\"type\":\"message.part.updated\"".utf8)).isEmpty)
    let events = try parser.append(Data(",\"properties\":{}}\n\nevent: future.event\ndata: {\"type\":\"future.event\"}\n\n".utf8))
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events.first?.event, "message.part.updated")
}
```

- [ ] **Step 3: Run the focused protocol tests and verify missing implementations**

Run: `swift test --filter 'OpenCodeHTTPClientTests|ServerSentEventsTests'`

Expected: FAIL to compile because the HTTP client and SSE parser are absent.

- [ ] **Step 4: Define the protocol boundary and DTOs**

```swift
protocol OpenCodeAPI: Sendable {
    func health() async throws -> OpenCodeHealth
    func sessions(directory: String?) async throws -> [OpenCodeSession]
    func createSession(directory: String, title: String?, agent: String?, model: LaunchModelSelection?) async throws -> OpenCodeSession
    func session(id: String, directory: String?) async throws -> OpenCodeSession
    func deleteSession(id: String, directory: String?) async throws
    func statuses(directory: String?) async throws -> [String: OpenCodeSessionStatus]
    func children(sessionID: String, directory: String?) async throws -> [OpenCodeSession]
    func messages(sessionID: String, directory: String?, limit: Int) async throws -> [OpenCodeMessage]
    func promptAsync(sessionID: String, directory: String, input: AgentInput) async throws
    func permissions(directory: String?) async throws -> [OpenCodePermissionRequest]
    func replyPermission(id: String, reply: OpenCodePermissionReply, message: String?, directory: String?) async throws
    func questions(directory: String?) async throws -> [OpenCodeQuestionRequest]
    func replyQuestion(id: String, answers: [[String]], directory: String?) async throws
    func events(directory: String?) async -> AsyncThrowingStream<OpenCodeEvent, Error>
    func selectSession(id: String, directory: String?) async throws
}
```

Use tolerant `Decodable` DTOs for only fields AgentHub consumes. Decode millisecond timestamps explicitly. Map HTTP `401` to `.authenticationRequired`, `404` on request replies to `.alreadyResolved`, other non-2xx responses to `.httpStatus(Int)`, and require loopback URL validation before creating any request. Clamp message limits to `0...20` client-side.

- [ ] **Step 5: Implement incremental SSE framing and `URLSession` streaming**

`ServerSentEventParser.append(_:)` must preserve incomplete bytes, join repeated `data:` lines with newline, ignore comment/heartbeat lines, and emit only on a blank-line frame terminator. `OpenCodeHTTPClient.events` uses `URLSession.bytes(for:)`, feeds line bytes through the parser, decodes recognized event payloads, and represents unknown event types as `.unknown(type:)`.

- [ ] **Step 6: Run protocol tests**

Run: `swift test --filter 'OpenCodeHTTPClientTests|ServerSentEventsTests'`

Expected: PASS for method/path/query/body/auth, bounded messages, tolerant DTOs, fragmented SSE, heartbeat, and unknown events.

- [ ] **Step 7: Commit protocol primitives**

```bash
git add Sources/AgentHubOpenCode Tests/AgentHubOpenCodeTests Tests/Fixtures/OpenCode
git commit -m "feat: add OpenCode HTTP and event protocol"
```

---

### Task 4: Build endpoint registry, stable identity, and routing

**Files:**
- Create: `Sources/AgentHubOpenCode/OpenCodeEndpointRegistry.swift`
- Create: `Tests/AgentHubOpenCodeTests/OpenCodeEndpointRegistryTests.swift`

**Interfaces:**
- Produces: internal `OpenCodeRuntimeEndpoint`, `OpenCodeOperation`, and actor `OpenCodeEndpointRegistry`.
- Consumes: public `ProviderEndpoint` summaries and `OpenCodeAPI` client factory.

- [ ] **Step 1: Write failing deduplication and route-ranking tests**

```swift
func testSameSessionAcrossEndpointsHasOneStableIdentityAndMergedSurfaces() async {
    let registry = OpenCodeEndpointRegistry()
    await registry.upsert(desktopEndpoint)
    await registry.upsert(tuiEndpoint)
    await registry.observe(sessionID: "ses_shared", directory: "/repo", endpointID: desktopEndpoint.id, at: date(10))
    await registry.observe(sessionID: "ses_shared", directory: "/repo", endpointID: tuiEndpoint.id, at: date(20))

    XCTAssertEqual(await registry.surfaces(sessionID: "ses_shared"), [.desktop, .tui])
    XCTAssertEqual(await registry.route(sessionID: "ses_shared", directory: "/repo", operation: .jump)?.id, tuiEndpoint.id)
    XCTAssertEqual(stableOpenCodeUUID(accountID: "local-default", nativeID: "ses_shared"), stableOpenCodeUUID(accountID: "local-default", nativeID: "ses_shared"))
}

func testCommandNeverRoutesByDirectoryAlone() async {
    await registry.observe(sessionID: "ses_other", directory: "/repo", endpointID: desktopEndpoint.id, at: date(20))
    XCTAssertNil(await registry.route(sessionID: "ses_missing", directory: "/repo", operation: .send))
}
```

- [ ] **Step 2: Run the registry tests and verify missing symbols**

Run: `swift test --filter OpenCodeEndpointRegistryTests`

Expected: FAIL to compile because the registry and stable UUID function do not exist.

- [ ] **Step 3: Implement runtime endpoints without exposing secrets publicly**

```swift
enum OpenCodeCredential: Sendable {
    case none
    case ephemeral(username: String, password: String)
    case keychain(username: String, reference: String)
}

struct OpenCodeRuntimeEndpoint: Sendable {
    let summary: ProviderEndpoint
    let credential: OpenCodeCredential
    let processID: Int32?
    let applicationBundleID: String?
    let terminalTTY: String?
}

enum OpenCodeOperation { case read, send, resolveRequest, jump }
```

The registry stores observations by exact `sessionID`. Route scoring must require healthy endpoint plus matching observation. Managed observations win for managed launches; otherwise freshest matching endpoint wins. Jump scoring prefers `.desktop`/`.tui`, then `.manual`, then `.managed`. Surface display is deterministic in `managed, desktop, tui, manual` order. `stableOpenCodeUUID` hashes `openCode\0accountID\0nativeID`, never URL or port.

- [ ] **Step 4: Run registry tests including stale endpoint removal**

Run: `swift test --filter OpenCodeEndpointRegistryTests`

Expected: PASS for exact-session routing, directory match, stable IDs, surface ordering, unhealthy exclusion, and route removal.

- [ ] **Step 5: Commit the registry**

```bash
git add Sources/AgentHubOpenCode/OpenCodeEndpointRegistry.swift Tests/AgentHubOpenCodeTests/OpenCodeEndpointRegistryTests.swift
git commit -m "feat: route OpenCode sessions across endpoints"
```

---

### Task 5: Manage a lazy authenticated OpenCode server

**Files:**
- Create: `Sources/AgentHubOpenCode/OpenCodeManagedServer.swift`
- Create: `Tests/AgentHubOpenCodeTests/OpenCodeManagedServerTests.swift`

**Interfaces:**
- Produces: `ManagedOpenCodeServing` and actor `ManagedOpenCodeServer`.
- Consumes: `OpenCodeRuntimeEndpoint`, injected executable resolver, port allocator, health probe, clock, and random-byte generator.

- [ ] **Step 1: Write failing fake-executable tests for lazy launch and environment-only password delivery**

```swift
func testEnsureRunningStartsOnceWithLoopbackAndNoPureFlag() async throws {
    let fixture = try FakeOpenCodeExecutable()
    let server = makeServer(executable: fixture.url, port: 41789, password: "generated-secret")

    let first = try await server.ensureRunning()
    let second = try await server.ensureRunning()

    XCTAssertEqual(first.summary.baseURL, "http://127.0.0.1:41789")
    XCTAssertEqual(first.summary.id, second.summary.id)
    XCTAssertEqual(try fixture.arguments(), ["serve", "--hostname", "127.0.0.1", "--port", "41789", "--print-logs"])
    XCTAssertEqual(try fixture.environmentValue("OPENCODE_SERVER_PASSWORD"), "generated-secret")
    XCTAssertFalse(try fixture.arguments().contains("--pure"))
    XCTAssertFalse(try fixture.arguments().contains("generated-secret"))
}
```

- [ ] **Step 2: Write failing crash/backoff and stop tests**

Test that exit 1 schedules `[1, 2, 4, 8, 16, 32, 60]` seconds, resets after a healthy run, and that `stop()` terminates only the managed child.

- [ ] **Step 3: Run managed-server tests and verify the controller is missing**

Run: `swift test --filter OpenCodeManagedServerTests`

Expected: FAIL to compile because `ManagedOpenCodeServer` is absent.

- [ ] **Step 4: Implement the lifecycle actor**

```swift
protocol ManagedOpenCodeServing: Sendable {
    func ensureRunning() async throws -> OpenCodeRuntimeEndpoint
    func stop() async
}
```

Resolve `/opt/homebrew/bin/opencode`, `/usr/local/bin/opencode`, then `PATH`; require an executable named `opencode`. Allocate an ephemeral loopback TCP port, generate 32 random bytes with `SecRandomCopyBytes`, base64url-encode them, and start:

```text
opencode serve --hostname 127.0.0.1 --port <random> --print-logs
```

Set `OPENCODE_SERVER_USERNAME=opencode` and `OPENCODE_SERVER_PASSWORD=<secret>` only in `Process.environment`. Poll authenticated `/global/health` until healthy/version or a 10-second deadline. Redact Basic/Auth/password/token patterns from the 64-line diagnostic ring. Keep one process per daemon, restart unexpected exits with bounded exponential backoff, and terminate it on `stop()`.

- [ ] **Step 5: Run managed lifecycle tests**

Run: `swift test --filter OpenCodeManagedServerTests`

Expected: PASS for lazy singleton start, random-port plumbing, secret transport, readiness, no production `--pure`, restart schedule, redaction, and stop ownership.

- [ ] **Step 6: Commit managed server support**

```bash
git add Sources/AgentHubOpenCode/OpenCodeManagedServer.swift Tests/AgentHubOpenCodeTests/OpenCodeManagedServerTests.swift
git commit -m "feat: manage a private OpenCode server"
```

---

### Task 6: Discover and attach current-user endpoints safely

**Files:**
- Create: `Sources/AgentHubOpenCode/OpenCodeDiscovery.swift`
- Create: `Tests/AgentHubOpenCodeTests/OpenCodeDiscoveryTests.swift`

**Interfaces:**
- Produces: `OpenCodeEndpointDiscovering`, `MacOpenCodeDiscovery`, `OpenCodeProcess`, and `OpenCodeListeningSocket`.
- Consumes: injected process/sockets snapshot and health-probe factory.

- [ ] **Step 1: Write failing process-tree and socket filtering tests**

```swift
func testDiscoveryProbesOnlyCurrentUserOpenCodeProcessTreeLoopbackSockets() async throws {
    let snapshot = ProcessSocketSnapshot(
        processes: [
            .init(pid: 10, parentPID: 1, uid: 501, command: "OpenCode", bundleID: "ai.opencode.desktop", tty: nil),
            .init(pid: 11, parentPID: 10, uid: 501, command: "opencode serve", bundleID: nil, tty: nil),
            .init(pid: 12, parentPID: 1, uid: 502, command: "opencode serve", bundleID: nil, tty: nil),
        ],
        sockets: [
            .init(pid: 11, host: "127.0.0.1", port: 4096),
            .init(pid: 11, host: "0.0.0.0", port: 4097),
            .init(pid: 12, host: "127.0.0.1", port: 4098),
        ]
    )
    let discovery = MacOpenCodeDiscovery(uid: 501, snapshot: { snapshot }, probe: healthyProbe)
    let endpoints = try await discovery.discover()
    XCTAssertEqual(endpoints.map(\.summary.baseURL), ["http://127.0.0.1:4096"])
    XCTAssertEqual(probedURLs, ["http://127.0.0.1:4096/global/health"])
}
```

- [ ] **Step 2: Write failing manual URL validation tests**

Assert acceptance of `http://127.0.0.1:41789` and `http://[::1]:41789`; reject `localhost`, `0.0.0.0`, LAN IPs, HTTPS exceptions, paths, query strings, missing ports, and embedded user-info.

- [ ] **Step 3: Run discovery tests and verify missing implementation**

Run: `swift test --filter OpenCodeDiscoveryTests`

Expected: FAIL to compile because discovery and validator types are absent.

- [ ] **Step 4: Implement snapshot acquisition and validation**

Use `/bin/ps -axo pid=,ppid=,uid=,tty=,comm=,args=` to find current-UID OpenCode Desktop/TUI process trees. Pass the explicit comma-separated PID set to `/usr/sbin/lsof -nP -a -p <pids> -iTCP -sTCP:LISTEN -Fpn`; do not invoke `lsof` without the PID filter. Parse only `127.0.0.1:*` and `[::1]:*` listeners, then verify each candidate with `/global/health`. A healthy response produces an attached endpoint; `401` preserves the process-owned candidate as disconnected with `authenticationRequired` metadata instead of probing other ports. Determine `.desktop` from an owning app bundle and `.tui` from an OpenCode process with a TTY. Generate endpoint IDs from origin plus process identity, not from a session ID.

- [ ] **Step 5: Run discovery tests**

Run: `swift test --filter OpenCodeDiscoveryTests`

Expected: PASS for UID/process-tree constraints, explicit PID-scoped `lsof`, loopback validation, origin metadata, duplicate socket removal, non-OpenCode health rejection, and retained `401` authentication candidates.

- [ ] **Step 6: Commit discovery**

```bash
git add Sources/AgentHubOpenCode/OpenCodeDiscovery.swift Tests/AgentHubOpenCodeTests/OpenCodeDiscoveryTests.swift
git commit -m "feat: discover local OpenCode endpoints"
```

---

### Task 7: Reconcile, launch, send, and merge OpenCode sessions

**Files:**
- Create: `Sources/AgentHubOpenCode/OpenCodeHybridAdapter.swift`
- Create: `Tests/AgentHubOpenCodeTests/OpenCodeHybridAdapterTests.swift`

**Interfaces:**
- Produces: public actor `OpenCodeHybridAdapter: EndpointConfigurableAdapter`.
- Consumes: `OpenCodeAPI`, registry, managed server, discovery, Keychain credentials, and existing normalized models.

- [ ] **Step 1: Write failing multi-endpoint reconciliation tests**

```swift
func testReconcileMergesSessionAndBuildsExplicitChildTree() async throws {
    let adapter = makeAdapter(
        desktop: .fixture(sessions: [.root("ses_root"), .child("ses_child", parent: "ses_root")]),
        tui: .fixture(sessions: [.root("ses_root")])
    )
    let snapshot = try await adapter.reconcile()

    XCTAssertEqual(snapshot.sessions.map(\.providerRef.nativeID), ["ses_root"])
    XCTAssertEqual(snapshot.sessions.first?.surface, "OpenCode Desktop · TUI")
    XCTAssertEqual(snapshot.nodes.first?.nativeID, "ses_child")
    XCTAssertEqual(snapshot.nodes.first?.parentNativeID, "ses_root")
    XCTAssertTrue(snapshot.quotas.isEmpty)
}
```

Add tests that the newest provider state wins, status maps `busy→working`, `idle→idle`, `retry→working`, missing status→completed, recent turns deduplicate message/part IDs and clamp to 20, and a directory-only match cannot route a send.

- [ ] **Step 2: Write failing managed launch and handoff-send tests**

Assert `launch` calls `ensureRunning`, `POST /session?directory=...`, then `prompt_async` exactly once; an accepted session plus failed prompt remains reconcilable and the same launch is not duplicated by the adapter. Assert `send` resolves the exact native ID/directory route and preserves `AgentInput.provenance` in rendered text metadata only when supported.

- [ ] **Step 3: Run adapter tests and verify the hybrid adapter is missing**

Run: `swift test --filter OpenCodeHybridAdapterTests`

Expected: FAIL to compile because `OpenCodeHybridAdapter` does not exist.

- [ ] **Step 4: Implement snapshot assembly and normalized mapping**

```swift
public actor OpenCodeHybridAdapter: EndpointConfigurableAdapter {
    public nonisolated let provider: Provider = .openCode

    public init(
        accountID: String = "local-default",
        registry: OpenCodeEndpointRegistry,
        managedServer: any ManagedOpenCodeServing,
        discovery: any OpenCodeEndpointDiscovering,
        credentialStore: any CredentialStoring,
        clientFactory: @escaping @Sendable (OpenCodeRuntimeEndpoint) -> any OpenCodeAPI,
        now: @escaping @Sendable () -> Date = Date.init
    )
}
```

`reconcile()` restores/discovers endpoints, probes health, lists sessions/statuses/children, records exact route observations, merges by `ProviderSessionRef(.openCode, accountID, nativeID)`, and returns no quota windows. Root sessions use stable UUIDs; child sessions become nodes associated with the root. Fetch at most 20 recent messages for visible/recent roots and store only three in each session preview so the existing persistence cap remains authoritative.

- [ ] **Step 5: Implement endpoint configuration and safe mutation routing**

`restoreEndpoint` accepts persisted `.manual` endpoints and discovered Desktop/TUI credential bindings, then revalidates their process-owned routes. `attachEndpoint` validates a manual URL, resolves a Keychain reference through `CredentialStoring`, health-probes, and returns a public endpoint summary. `authenticateEndpoint` requires an already discovered `401` endpoint ID, reads only the supplied Keychain reference, reprobes health, and returns the authenticated summary. `detachEndpoint` removes a manual route; for Desktop/TUI it forgets only the saved credential binding and never stops the attached process. Each unauthenticated candidate also becomes a stable `.authentication` `PendingRequest` whose `threadID` is the endpoint ID and whose detail contains only the loopback URL. `launch` ensures the managed endpoint; `send`, `recentTurns`, and later request actions require an exact healthy session route and throw `OpenCodeAdapterError.staleRoute` otherwise.

- [ ] **Step 6: Run adapter and existing Codex tests**

Run: `swift test --filter 'OpenCodeHybridAdapterTests|AgentHubCodexTests'`

Expected: PASS with merged OpenCode routes and no Codex behavior change.

- [ ] **Step 7: Commit the session vertical slice**

```bash
git add Sources/AgentHubOpenCode/OpenCodeHybridAdapter.swift Tests/AgentHubOpenCodeTests/OpenCodeHybridAdapterTests.swift
git commit -m "feat: reconcile and launch OpenCode sessions"
```

---

### Task 8: Stream events and resolve permissions/questions with first-responder semantics

**Files:**
- Modify: `Sources/AgentHubCore/Models.swift`
- Modify: `Sources/AgentHubCore/StateReducer.swift`
- Modify: `Sources/AgentHubPersistence/Store.swift`
- Modify: `Sources/AgentHubDaemon/Coordinator.swift`
- Modify: `Sources/AgentHubCodex/CodexAdapter.swift`
- Modify: `Sources/AgentHubOpenCode/OpenCodeHybridAdapter.swift`
- Modify: `Sources/AgentHubOpenCode/OpenCodeWireModels.swift`
- Modify: `Tests/AgentHubOpenCodeTests/OpenCodeHybridAdapterTests.swift`
- Modify: `Tests/Fixtures/OpenCode/events.sse`

**Interfaces:**
- Produces: idempotent SSE relay, pending permission/question mapping, and `RequestDecision.answers([[String]])` support.
- Consumes: exact request route observations and existing `AdapterOperationError.requestAlreadyResolved` convergence in `RequestService`.

- [ ] **Step 1: Write failing permission and question snapshot tests**

```swift
func testPermissionAndOrderedQuestionBecomeNormalizedRequests() async throws {
    let snapshot = try await makeAdapterWithPendingRequests().reconcile()
    let permission = try XCTUnwrap(snapshot.requests.first { $0.kind == .permission })
    XCTAssertEqual(permission.allowedActions, ["once", "always", "reject"])
    let question = try XCTUnwrap(snapshot.requests.first { $0.kind == .choice })
    XCTAssertEqual(question.fields.map(\.id), ["0", "1"])
    XCTAssertEqual(question.fields[0].choices, ["Swift", "Rust"])
    XCTAssertTrue(question.fields[1].allowsFreeText)
}
```

- [ ] **Step 2: Write failing first-responder and reconnect-gap tests**

Assert `.accept→once`, `.acceptForSession→always`, `.decline/.cancel→reject`, `.answers([[String]])` preserves ordered answers, and HTTP 404 maps to `AdapterOperationError.requestAlreadyResolved`. Simulate SSE disconnect, remove a previously pending request, change the fake server snapshot, reconnect, and assert reconciliation expires the missing request and emits the new request before subsequent live events. Assert duplicate events produce one stable request UUID.

- [ ] **Step 3: Run the focused tests and verify failures**

Run: `swift test --filter OpenCodeHybridAdapterTests`

Expected: FAIL because request fields/answers and SSE relay behavior are not implemented.

- [ ] **Step 4: Add the decision case and request mapping**

Add `case answers([[String]])` to `RequestDecision` and `case unsupportedDecision` to `AdapterOperationError`; Codex throws the latter for `.answers` instead of guessing how to flatten it. Add `AgentEvent.requestExpired(id:)`, reducer/store handling that moves a non-terminal request to `.expired`, and coordinator logic that expires missing provider requests only when `AdapterSnapshot.requestsAreAuthoritative` is true. OpenCode sets that flag, uses stable UUID input `request:<providerRequestID>`, exact session ID, directory route, L1 reliability, and the three permission actions. OpenCode question fields preserve provider order and labels. Endpoint reconnect reconciliation compares the previous pending-ID set and emits expiry events for requests no longer returned by the authoritative lists.

- [ ] **Step 5: Implement one relay task per healthy endpoint**

On first `eventStream()` subscription, start endpoint relays once. Each relay consumes recognized session/message/child/permission/question events into idempotent `AgentEvent`s. On disconnect, mark that endpoint unhealthy, back off `[1,2,4,8,16,32,60]`, health-probe, call endpoint-scoped reconciliation, then resume SSE. Emit provider health disconnected only when no usable endpoint and managed launch is unavailable; never mark all OpenCode sessions disconnected because one route failed.

- [ ] **Step 6: Run request/event tests and daemon request regression tests**

Run: `swift test --filter 'OpenCodeHybridAdapterTests|RequestServiceTests|CodexAdapterTests'`

Expected: PASS for snapshot rebuild, live events, reconnect gap, unknown event, first responder, ordered answers, and existing Codex permission handling.

- [ ] **Step 7: Commit request streaming**

```bash
git add Sources/AgentHubCore Sources/AgentHubPersistence/Store.swift Sources/AgentHubDaemon/Coordinator.swift Sources/AgentHubCodex/CodexAdapter.swift Sources/AgentHubOpenCode Tests/AgentHubOpenCodeTests Tests/Fixtures/OpenCode/events.sse
git commit -m "feat: handle OpenCode requests and events"
```

---

### Task 9: Persist endpoints and expose generic daemon IPC actions

**Files:**
- Modify: `Sources/AgentHubPersistence/Database.swift:22-80`
- Modify: `Sources/AgentHubPersistence/Store.swift:12-300`
- Modify: `Sources/AgentHubCore/Models.swift:406-415`
- Modify: `Sources/AgentHubCore/StateReducer.swift:30-99`
- Modify: `Sources/AgentHubIPC/Messages.swift:4-55`
- Modify: `Sources/AgentHubDaemon/Coordinator.swift:43-205`
- Modify: `Sources/AgentHubDaemon/DaemonAPI.swift:20-85`
- Modify: `Sources/agenthubd/main.swift:4-105`
- Modify: `Tests/AgentHubPersistenceTests/StoreTests.swift`
- Modify: `Tests/AgentHubIPCTests/IPCTests.swift`
- Modify: `Tests/AgentHubDaemonTests/CoordinatorTests.swift`
- Modify: `Tests/AgentHubDaemonTests/DaemonAPITests.swift`
- Modify: `Tests/AgentHubDaemonTests/TestAdapter.swift`

**Interfaces:**
- Produces: protocol-v2 `.launch(Provider, LaunchRequest)`, `.attachEndpoint`, `.authenticateEndpoint`, `.detachEndpoint`, endpoint persistence, and OpenCode daemon wiring.
- Consumes: `EndpointConfigurableAdapter`, `ProviderEndpoint`, and the OpenCode adapter constructor.

- [ ] **Step 1: Write failing persistence migration/restore tests**

```swift
func testManualEndpointPersistsOnlyReferenceAndNonSecretMetadata() async throws {
    let store = try makeStore()
    try await store.apply(.endpointUpserted(manualEndpoint))
    let restoredState = try await store.snapshot()
    let restored = restoredState.endpoints[manualEndpoint.id]
    XCTAssertEqual(restored?.credentialReference, "keychain-ref")
    XCTAssertFalse(try databaseBytes().contains(Data("server-password".utf8)))
    try await store.apply(.endpointRemoved(manualEndpoint.id))
    XCTAssertNil(try await store.snapshot().endpoints[manualEndpoint.id])
}
```

- [ ] **Step 2: Write failing IPC and coordinator tests**

Encode/decode `.launch(.openCode, request)`, `.attachEndpoint(attachment)`, `.authenticateEndpoint(binding)`, and `.detachEndpoint(provider: .openCode, id: ...)` under protocol version 2. Assert coordinator restores persisted manual/authenticated attached endpoints before the adapter's first `reconcile`, applies the returned endpoint summary, and rejects endpoint commands for a non-configurable adapter.

- [ ] **Step 3: Run focused persistence/IPC/daemon tests and verify failures**

Run: `swift test --filter 'AgentHubPersistenceTests|AgentHubIPCTests|CoordinatorTests|DaemonAPITests'`

Expected: FAIL because the endpoint table and new commands are missing.

- [ ] **Step 4: Add migration and store behavior**

Add `endpointUpserted`/`endpointRemoved` to `AgentEvent` and `StateReducer`. Register `provider-endpoints-v2` with columns `id TEXT PRIMARY KEY`, `provider TEXT NOT NULL`, `origin TEXT NOT NULL`, and `body BLOB NOT NULL`. Persist `.manual` endpoints and authenticated Desktop/TUI summaries containing a Keychain reference; unauthenticated discovery and managed endpoints remain runtime observations. Add store handling and load summaries into `AgentHubState.endpoints`.

- [ ] **Step 5: Generalize IPC and coordinator actions**

Set `agentHubIPCProtocolVersion = 2` and replace `.launchCodex` with:

```swift
case launch(Provider, LaunchRequest)
case attachEndpoint(ProviderEndpointAttachment)
case authenticateEndpoint(ProviderEndpointCredentialBinding)
case detachEndpoint(provider: Provider, id: String)
```

At coordinator startup, restore persisted endpoints into a matching `EndpointConfigurableAdapter` before reconciliation. Add coordinator methods that cast the provider adapter, call attach/authenticate/detach, and persist resulting endpoint events. Update public failure copy to identify OpenCode launch/attachment/authentication without exposing underlying URLs, credentials, or raw error text.

- [ ] **Step 6: Wire the OpenCode adapter into `agenthubd`**

Create one shared `KeychainCredentialStore`, `OpenCodeEndpointRegistry`, `ManagedOpenCodeServer`, `MacOpenCodeDiscovery`, and `OpenCodeHybridAdapter`; register `.openCode` beside `.codex`. Add `OpenCodeHybridAdapter.shutdown()` to cancel endpoint SSE/retry tasks, then stop it and the managed server in both normal and error shutdown paths. Codex startup failure behavior remains unchanged; an unavailable OpenCode binary does not prevent daemon startup when attached discovery remains possible.

- [ ] **Step 7: Run daemon and persistence regression tests**

Run: `swift test --filter 'AgentHubPersistenceTests|AgentHubIPCTests|AgentHubDaemonTests'`

Expected: PASS for protocol v2, endpoint restore/removal, provider launch routing, daemon isolation, and all existing handoff/request tests.

- [ ] **Step 8: Commit daemon integration**

```bash
git add Sources/AgentHubPersistence Sources/AgentHubIPC Sources/AgentHubDaemon Sources/agenthubd Tests/AgentHubPersistenceTests Tests/AgentHubIPCTests Tests/AgentHubDaemonTests
git commit -m "feat: expose OpenCode through the daemon"
```

---

### Task 10: Implement exact jump selection and native app activation

**Files:**
- Modify: `Sources/AgentHubOpenCode/OpenCodeHybridAdapter.swift`
- Create: `App/JumpOpener.swift`
- Modify: `App/Features/Dashboard/DashboardViewModel.swift:120-137`
- Modify: `Tests/AgentHubOpenCodeTests/OpenCodeHybridAdapterTests.swift`
- Modify: `Tests/AgentHubAppTests/DashboardViewModelTests.swift`

**Interfaces:**
- Produces: `JumpOpening`, `WorkspaceJumpOpener`, and adapter jump targets after `/tui/select-session`.
- Consumes: registry `jump` route and existing `JumpTarget.application/agentHubDetail/unavailable`.

- [ ] **Step 1: Write failing exact-selection and degradation tests**

```swift
func testJumpSelectsTUISessionBeforeReturningOwningApplication() async {
    let adapter = makeAdapterWithTUI(bundleID: "com.googlecode.iterm2")
    let target = await adapter.jumpTarget(for: openCodeRef("ses_1"))
    XCTAssertEqual(fakeAPI.selectedSessions, ["ses_1"])
    XCTAssertEqual(target, .application(bundleID: "com.googlecode.iterm2", windowHint: "OpenCode ses_1"))
}

func testJumpFallsBackToAgentHubDetailWhenSelectionAndSurfaceAreUnavailable() async {
    XCTAssertEqual(await adapter.jumpTarget(for: openCodeRef("ses_1")), .agentHubDetail(sessionNativeID: "ses_1"))
}
```

- [ ] **Step 2: Write failing view-model opener tests**

Inject a recording `JumpOpening`; assert `.application` calls `open(bundleID:windowHint:)`, `.agentHubDetail` selects the row, and `.unavailable(reason)` displays the provider reason without claiming success.

- [ ] **Step 3: Run jump tests and verify failures**

Run: `swift test --filter 'OpenCodeHybridAdapterTests|DashboardViewModelTests'`

Expected: FAIL because native activation is not performed and OpenCode jump selection is absent.

- [ ] **Step 4: Implement selection and activation**

The adapter chooses the preferred healthy jump route, calls `selectSession(id:directory:)`, then returns the owning Desktop/terminal host bundle ID. If selection returns unsupported/not-found, return an application target only when a native owner is known; otherwise return AgentHub detail with an adapter health/degradation message.

`WorkspaceJumpOpener` resolves `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` and opens/activates it using `NSWorkspace.OpenConfiguration`. It never uses Accessibility or synthesized key events in this plan.

- [ ] **Step 5: Run jump tests**

Run: `swift test --filter 'OpenCodeHybridAdapterTests|DashboardViewModelTests'`

Expected: PASS for exact selection ordering, owning-app activation, managed detail, and explicit degradation.

- [ ] **Step 6: Commit navigation**

```bash
git add Sources/AgentHubOpenCode/OpenCodeHybridAdapter.swift App/JumpOpener.swift App/Features/Dashboard/DashboardViewModel.swift Tests/AgentHubOpenCodeTests/OpenCodeHybridAdapterTests.swift Tests/AgentHubAppTests/DashboardViewModelTests.swift
git commit -m "feat: open native OpenCode sessions"
```

---

### Task 11: Add provider-aware launch, requests, sessions, and endpoint settings UI

**Files:**
- Modify: `project.yml:26-60`
- Modify: `App/AppEnvironment.swift:5-146`
- Modify: `App/Features/Dashboard/DashboardViewModel.swift`
- Modify: `App/Features/Dashboard/DashboardView.swift`
- Modify: `App/Features/Requests/RequestInboxView.swift`
- Modify: `App/Features/Sessions/SessionTreeView.swift`
- Modify: `App/Features/Sessions/SessionDetailView.swift`
- Create: `App/Features/OpenCode/OpenCodeSettingsView.swift`
- Modify: `Tests/AgentHubAppTests/DashboardViewModelTests.swift`

**Interfaces:**
- Produces: secure manual attachment workflow and mixed-provider dashboard controls.
- Consumes: protocol-v2 daemon commands, `CredentialStoring`, structured request fields, endpoint summaries, and `JumpOpening`.

- [ ] **Step 1: Write failing view-model tests for provider launch and secure attachment cleanup**

```swift
func testLaunchOpenCodeSendsGenericProviderCommand() async {
    await model.launch(provider: .openCode, cwd: "/repo", prompt: "work", agent: nil, model: nil)
    guard case .launch(.openCode, let request) = await client.recordedCommands.last else {
        return XCTFail("expected OpenCode launch")
    }
    XCTAssertEqual(request.cwd, "/repo")
}

func testFailedAttachDeletesNewKeychainReference() async {
    client.reply = .failure("Unable to attach OpenCode endpoint")
    await model.attachOpenCode(url: "http://127.0.0.1:41789", password: "secret")
    XCTAssertEqual(credentials.savedSecrets.count, 1)
    XCTAssertEqual(credentials.deletedReferences, [credentials.savedSecrets[0].reference])
    XCTAssertFalse(await client.recordedCommands.description.contains("secret"))
}

func testDiscoveredEndpointAuthenticationSendsOnlyKeychainReference() async {
    await model.authenticateOpenCode(endpointID: "openCode:tui:42", password: "secret")
    guard case .authenticateEndpoint(let binding) = await client.recordedCommands.last else {
        return XCTFail("expected endpoint authentication")
    }
    XCTAssertEqual(binding.endpointID, "openCode:tui:42")
    XCTAssertNotEqual(binding.credentialReference, "secret")
    XCTAssertFalse(await client.recordedCommands.description.contains("secret"))
}
```

- [ ] **Step 2: Run app tests and verify missing APIs**

Run: `xcodegen generate && xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp -destination 'platform=macOS' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO test -only-testing:AgentHubAppTests`

Expected: FAIL to compile because generic launch, credentials, and endpoint actions are absent.

- [ ] **Step 3: Implement provider-aware view-model actions**

`launch(provider:cwd:prompt:agent:model:)` sends `.launch(provider, request)`. `attachOpenCode(url:password:)` generates a UUID reference, writes the password to Keychain, sends only `ProviderEndpointAttachment(provider:.openCode, baseURL:url, credentialReference:reference)`, and deletes the item if daemon attachment fails. `authenticateOpenCode(endpointID:password:)` uses the same write-first/rollback flow but sends `ProviderEndpointCredentialBinding`. `detachOpenCode(endpoint:)` asks the daemon to detach or forget the binding first, then deletes its Keychain reference after acknowledgement.

- [ ] **Step 4: Replace the Codex-only task sheet**

Rename it `LaunchTaskSheet`. Add a `Provider` picker limited to Codex/OpenCode in this release; show optional OpenCode agent, provider ID, model ID, and variant fields. Empty optional fields map to `nil`, so OpenCode defaults remain authoritative. Change toolbar copy to `New Task` and provider-neutral empty-state copy to `Launch a task to begin.`

- [ ] **Step 5: Render mixed sessions and provider-specific requests**

Session rows show provider and the aggregated `surface` string. Detail permits composition for any session with `.sendInput == .l1`, including attached OpenCode sessions, while the handoff eligibility service still blocks active/pending targets.

Permission cards render buttons from the normalized OpenCode actions as `Reject`, `Once`, and `Always`, mapping to `.decline`, `.accept`, and `.acceptForSession`. Question cards render each ordered `RequestField`: picker/toggles for labels and transient text fields for free text; submit one `.answers([[String]])`. Authentication cards do not call `.resolveRequest`; they open a secure field and invoke `authenticateOpenCode`, so only a Keychain reference crosses IPC. Clear local answers/passwords on dismissal/resolution and never copy them into `AgentHubState`.

- [ ] **Step 6: Add OpenCode settings**

`OpenCodeSettingsView` lists managed/discovered/manual endpoint origin, loopback URL, version, connection state, and non-secret message. The add sheet validates the URL before accepting an optional password. Manual endpoints expose `Detach`; authenticated Desktop/TUI endpoints expose `Forget password`, which preserves native process ownership. Include the explicit text `OpenCode Go quota is not available yet.` with no progress bar or recommendation.

- [ ] **Step 7: Add mixed fixture data and build UI tests**

Extend `AppEnvironment.fixtureState()` with one OpenCode TUI session, one OpenCode question, and endpoint summaries. Add view-model assertions for permission choices, ordered answers, attachment success/failure cleanup, detach ordering, application jump, and quota absence.

Run: `xcodegen generate && xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp -destination 'platform=macOS' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO test -only-testing:AgentHubAppTests`

Expected: PASS with all app tests and no credential value in recorded daemon commands.

- [ ] **Step 8: Commit the desktop UI**

```bash
git add project.yml App Tests/AgentHubAppTests
git commit -m "feat: add OpenCode controls to the dashboard"
```

---

### Task 12: Verify the multi-provider vertical slice, live compatibility, privacy, and packaging

**Files:**
- Create: `Tests/AgentHubOpenCodeTests/FakeOpenCodeServer.swift`
- Create: `Tests/AgentHubOpenCodeTests/LiveOpenCodeTests.swift`
- Create: `Tests/AgentHubDaemonTests/OpenCodeVerticalSliceTests.swift`
- Modify: `Tests/AgentHubDaemonTests/PrivacyTests.swift`
- Modify: `scripts/check.sh`
- Modify: `README.md` if present; otherwise create `docs/opencode-testing.md`

**Interfaces:**
- Produces: acceptance evidence for launch, deduplication, requests, handoff, restart, isolation, and package embedding.
- Consumes: all production interfaces from Tasks 1–11.

- [ ] **Step 1: Implement a deterministic NIO fake OpenCode server and write the failing vertical-slice test**

`FakeOpenCodeServer` binds loopback on port 0 and implements health, session CRUD, status, children, messages, prompt_async, permission/question list/reply, SSE, and TUI selection. It records method/path/query/body/auth without storing Basic Auth values in assertion failure text.

The acceptance test must perform this exact sequence through `UnixDaemonClient`:

1. attach two fake endpoint surfaces exposing the same `ses_shared` and assert one session row;
2. launch a managed OpenCode session in a selected directory;
3. emit a permission, resolve it once, then simulate a provider-first resolution and assert convergence;
4. expose an ordered question and submit two answer groups;
5. create a handoff from a Codex fixture session to idle OpenCode and assert one `prompt_async` delivery;
6. request jump and assert the fake TUI selected the exact session;
7. restart coordinator/store and assert normalized sessions, requests, envelope, and manual endpoint restore;
8. fail one fake endpoint and assert Codex plus the second OpenCode route remain connected.

- [ ] **Step 2: Run the vertical-slice test and verify it fails at the first missing integration**

Run: `swift test --filter OpenCodeVerticalSliceTests`

Expected: FAIL until every daemon/adapter connection in the sequence is complete; fix only the observed integration gaps, then rerun to PASS.

- [ ] **Step 3: Add the opt-in live compatibility test**

```swift
func testInstalledOpenCodeSessionCRUDWithoutPrompt() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTHUB_LIVE_OPENCODE"] == "1")
    let server = try await IsolatedLiveOpenCodeServer.start(pure: true)
    defer { Task { await server.stop() } }
    let client = server.client
    XCTAssertTrue(try await client.health().healthy)
    let created = try await client.createSession(directory: server.temporaryDirectory.path, title: "AgentHub live contract", agent: nil, model: nil)
    XCTAssertEqual(try await client.session(id: created.id, directory: server.temporaryDirectory.path).id, created.id)
    try await client.deleteSession(id: created.id, directory: server.temporaryDirectory.path)
}
```

Start `opencode serve --pure` with temporary `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`, and `XDG_STATE_HOME`. Do not call `prompt_async`, do not select a model, and skip by default. Document: `AGENTHUB_LIVE_OPENCODE=1 swift test --filter LiveOpenCodeTests`.

In the same opt-in suite, run `MacOpenCodeDiscovery` against the isolated server process and assert that it finds that server's exact loopback port through the real process-owned socket path. This verifies discovery without prompting a model.

- [ ] **Step 4: Add privacy assertions**

After launch, attach, authentication failure, request response, and handoff fixtures, read the SQLite file and captured diagnostics. Assert they do not contain the endpoint password, Authorization value, question free text, or full handoff prompt. Assert manual endpoint rows contain the Keychain reference and loopback URL only, and managed passwords disappear when the managed controller stops.

- [ ] **Step 5: Run all Swift package tests**

Run: `swift test`

Expected: all tests PASS; `LiveOpenCodeTests` reports one skip unless explicitly enabled.

- [ ] **Step 6: Run the full app/package verification**

Run: `zsh scripts/check.sh`

Expected: `git diff --check`, Swift tests, plist/shell validation, Xcode app tests, and embedded helper link-path check all PASS. Verify the built helper contains the OpenCode and Security modules through static linking and has no `.build/xcode` runtime dependency.

- [ ] **Step 7: Perform a packaged fixture-mode smoke test**

Launch the built app with `AGENTHUB_FIXTURE_MODE=1`, confirm the mixed Codex/OpenCode tree, endpoint settings, request controls, quota-unavailable copy, and no daemon/network dependency. Capture one screenshot for review outside the repository unless release documentation explicitly needs it.

- [ ] **Step 8: Commit acceptance coverage and documentation**

```bash
git add Tests/AgentHubOpenCodeTests Tests/AgentHubDaemonTests scripts/check.sh docs/opencode-testing.md README.md
git commit -m "test: verify the OpenCode vertical slice"
```

---

## Final review gate

- [ ] Map every acceptance criterion in `docs/superpowers/specs/2026-08-11-agenthub-opencode-hybrid-design.md` to a passing test in Task 12.
- [ ] Run `rg -n -i 'TBD|TODO|FIXME|placeholder|implement later|add appropriate|handle edge cases|write tests for the above|similar to task' docs/superpowers/plans/2026-08-11-agenthub-opencode-hybrid.md | rg -v 'Run .*rg -n -i'` and remove every reported red-flag marker.
- [ ] Run `rg -n 'OPENCODE_SERVER_PASSWORD|Authorization|password' Sources App` and review each hit for secret transport/redaction; no secret may be serialized into Core state or IPC.
- [ ] Run `git diff --check` and `zsh scripts/check.sh` from a clean worktree.
- [ ] Use `superpowers:verification-before-completion` before reporting implementation complete.

## External references

- [OpenCode Server API](https://opencode.ai/docs/server/)
- Local generated OpenAPI contract from OpenCode 1.18.10, used only during design validation; production code must not depend on a temporary generated file.
