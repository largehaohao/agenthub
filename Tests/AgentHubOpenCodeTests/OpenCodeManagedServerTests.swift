import Foundation
import XCTest
@testable import AgentHubOpenCode

final class OpenCodeManagedServerTests: XCTestCase {
    func testEnsureRunningStartsOnceWithLoopbackAndEnvironmentOnlyPassword() async throws {
        let process = FakeManagedOpenCodeProcess(processID: 4321)
        let probe = HealthProbe()
        let server = makeServer(process: process, probe: probe)

        let first = try await server.ensureRunning()
        let second = try await server.ensureRunning()
        let startCount = await process.startCount()
        let arguments = await process.arguments()
        let environment = await process.environment()
        let credentials = await probe.credentials()

        XCTAssertEqual(first.summary.baseURL, "http://127.0.0.1:41789")
        XCTAssertEqual(first.summary.id, second.summary.id)
        XCTAssertEqual(first.processID, 4321)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(
            arguments,
            ["serve", "--hostname", "127.0.0.1", "--port", "41789", "--print-logs"]
        )
        XCTAssertEqual(environment["OPENCODE_SERVER_USERNAME"], "opencode")
        XCTAssertEqual(environment["OPENCODE_SERVER_PASSWORD"], "generated-secret")
        XCTAssertFalse(arguments.contains("--pure"))
        XCTAssertFalse(arguments.contains("generated-secret"))
        XCTAssertEqual(credentials, ["opencode:generated-secret"])
    }

    func testReadinessRetriesAndStopTerminatesOnlyOwnedProcess() async throws {
        let process = FakeManagedOpenCodeProcess(processID: 9876)
        let probe = HealthProbe(failuresBeforeSuccess: 2)
        let sleeps = SleepRecorder()
        let server = makeServer(process: process, probe: probe, sleeps: sleeps)

        _ = try await server.ensureRunning()
        await server.stop()
        await server.stop()
        let probeCalls = await probe.callCount()
        let recordedSleeps = await sleeps.values()
        let terminationCount = await process.terminationCount()

        XCTAssertEqual(probeCalls, 3)
        XCTAssertEqual(recordedSleeps, [.milliseconds(100), .milliseconds(100)])
        XCTAssertEqual(terminationCount, 1)
    }

    func testRestartBackoffIsBoundedAndResetsAfterHealthyRun() {
        var backoff = OpenCodeRestartBackoff()

        XCTAssertEqual((0..<9).map { _ in backoff.nextDelay() }, [1, 2, 4, 8, 16, 32, 60, 60, 60])
        backoff.recordHealthy()
        XCTAssertEqual(backoff.nextDelay(), 1)
    }

    func testDiagnosticsRedactCredentialsAndRingIsBounded() {
        var ring = OpenCodeDiagnosticRing()
        for index in 0..<70 {
            ring.append(
                "\(index) Authorization: Basic dXNlcjpwYXNz password=private token=secret-token"
            )
        }

        XCTAssertEqual(ring.lines.count, 64)
        XCTAssertTrue(ring.lines.first?.hasPrefix("6 ") == true)
        XCTAssertFalse(ring.lines.joined().contains("dXNlcjpwYXNz"))
        XCTAssertFalse(ring.lines.joined().contains("private"))
        XCTAssertFalse(ring.lines.joined().contains("secret-token"))
    }

    private func makeServer(
        process: FakeManagedOpenCodeProcess,
        probe: HealthProbe,
        sleeps: SleepRecorder = SleepRecorder()
    ) -> ManagedOpenCodeServer {
        ManagedOpenCodeServer(
            environment: ["PATH": "/usr/bin"],
            executableResolver: { _ in URL(fileURLWithPath: "/usr/local/bin/opencode") },
            portAllocator: { 41789 },
            passwordGenerator: { "generated-secret" },
            processFactory: { process },
            healthProbe: { url, username, password in
                try await probe.call(url: url, username: username, password: password)
            },
            sleep: { duration in try await sleeps.sleep(duration) },
            readinessAttempts: 100,
            now: { Date(timeIntervalSince1970: 123) }
        )
    }
}

private actor FakeManagedOpenCodeProcess: ManagedOpenCodeProcess {
    private let pid: Int32
    private var starts = 0
    private var terminations = 0
    private var capturedArguments: [String] = []
    private var capturedEnvironment: [String: String] = [:]

    init(processID: Int32) {
        pid = processID
    }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onTermination: @escaping @Sendable (Int32) -> Void,
        onDiagnostics: @escaping @Sendable (Data) -> Void
    ) async throws {
        starts += 1
        capturedArguments = arguments
        capturedEnvironment = environment
    }

    func terminate() async {
        terminations += 1
    }

    func processIdentifier() async -> Int32? { pid }
    func startCount() -> Int { starts }
    func terminationCount() -> Int { terminations }
    func arguments() -> [String] { capturedArguments }
    func environment() -> [String: String] { capturedEnvironment }
}

private actor HealthProbe {
    private let failuresBeforeSuccess: Int
    private var calls = 0
    private var capturedCredentials: [String] = []

    init(failuresBeforeSuccess: Int = 0) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func call(url: URL, username: String, password: String) throws -> OpenCodeHealth {
        calls += 1
        capturedCredentials.append("\(username):\(password)")
        if calls <= failuresBeforeSuccess {
            throw URLError(.cannotConnectToHost)
        }
        return OpenCodeHealth(healthy: true, version: "1.18.10")
    }

    func callCount() -> Int { calls }
    func credentials() -> [String] { capturedCredentials }
}

private actor SleepRecorder {
    private var durations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
    }

    func values() -> [Duration] { durations }
}
