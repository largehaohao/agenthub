import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubOpenCode

final class OpenCodeDiscoveryTests: XCTestCase {
    func testDiscoveryProbesOnlyCurrentUserOpenCodeProcessTreeLoopbackSockets() async throws {
        let snapshot = OpenCodeProcessSocketSnapshot(
            processes: [
                .init(
                    pid: 10,
                    parentPID: 1,
                    uid: 501,
                    command: "/Applications/OpenCode.app/Contents/MacOS/OpenCode",
                    bundleID: "ai.opencode.desktop",
                    tty: nil
                ),
                .init(pid: 11, parentPID: 10, uid: 501, command: "opencode serve", tty: nil),
                .init(pid: 12, parentPID: 1, uid: 502, command: "opencode serve", tty: "ttys002"),
                .init(pid: 13, parentPID: 1, uid: 501, command: "opencode serve", tty: "ttys003"),
            ],
            sockets: [
                .init(pid: 11, host: "127.0.0.1", port: 4096),
                .init(pid: 11, host: "0.0.0.0", port: 4097),
                .init(pid: 12, host: "127.0.0.1", port: 4098),
                .init(pid: 13, host: "::1", port: 4099),
                .init(pid: 13, host: "::1", port: 4099),
            ]
        )
        let probe = DiscoveryProbe()
        let discovery = MacOpenCodeDiscovery(
            uid: 501,
            snapshot: { snapshot },
            probe: { await probe.call($0) },
            now: { Date(timeIntervalSince1970: 123) }
        )

        let endpoints = try await discovery.discover()
        let urls = await probe.urls()

        XCTAssertEqual(
            endpoints.map(\.summary.baseURL),
            ["http://127.0.0.1:4096", "http://[::1]:4099"]
        )
        XCTAssertEqual(endpoints.map(\.summary.origin), [.desktop, .tui])
        XCTAssertEqual(endpoints[0].applicationBundleID, "ai.opencode.desktop")
        XCTAssertEqual(endpoints[1].terminalTTY, "ttys003")
        XCTAssertEqual(
            urls.map(\.absoluteString),
            ["http://127.0.0.1:4096/global/health", "http://[::1]:4099/global/health"]
        )
    }

    func testAuthenticationCandidateIsRetainedButOtherProbeFailuresAreRejected() async throws {
        let snapshot = OpenCodeProcessSocketSnapshot(
            processes: [
                .init(pid: 20, parentPID: 1, uid: 501, command: "opencode serve", tty: "ttys004"),
                .init(pid: 21, parentPID: 1, uid: 501, command: "opencode serve", tty: "ttys005"),
            ],
            sockets: [
                .init(pid: 20, host: "127.0.0.1", port: 5000),
                .init(pid: 21, host: "127.0.0.1", port: 5001),
            ]
        )
        let discovery = MacOpenCodeDiscovery(
            uid: 501,
            snapshot: { snapshot },
            probe: { url in
                if url.port == 5000 { throw OpenCodeHTTPError.authenticationRequired }
                throw URLError(.badServerResponse)
            }
        )

        let endpoints = try await discovery.discover()

        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoints[0].summary.baseURL, "http://127.0.0.1:5000")
        XCTAssertFalse(endpoints[0].summary.connected)
        XCTAssertEqual(endpoints[0].summary.message, "authenticationRequired")
    }

    func testManualEndpointValidatorAcceptsOnlyExplicitHTTPLoopbackURLs() throws {
        XCTAssertEqual(
            try OpenCodeManualEndpointValidator.validate("http://127.0.0.1:41789").absoluteString,
            "http://127.0.0.1:41789"
        )
        XCTAssertEqual(
            try OpenCodeManualEndpointValidator.validate("http://[::1]:41789").absoluteString,
            "http://[::1]:41789"
        )

        let rejected = [
            "http://localhost:41789",
            "http://0.0.0.0:41789",
            "http://192.168.1.2:41789",
            "https://127.0.0.1:41789",
            "http://127.0.0.1:41789/path",
            "http://127.0.0.1:41789?query=yes",
            "http://127.0.0.1",
            "http://user:pass@127.0.0.1:41789",
        ]
        for value in rejected {
            XCTAssertThrowsError(try OpenCodeManualEndpointValidator.validate(value), value)
        }
    }

    func testSnapshotterScopesLsofToExplicitCurrentUserOpenCodePIDs() async throws {
        let runner = SnapshotCommandRunner()
        let snapshotter = MacOpenCodeSnapshotter(
            uid: 501,
            run: { try await runner.run(executable: $0, arguments: $1) }
        )

        let snapshot = try await snapshotter.snapshot()
        let invocations = await runner.invocations()

        XCTAssertEqual(snapshot.processes.map(\.pid), [10, 11])
        XCTAssertEqual(snapshot.sockets, [.init(pid: 11, host: "127.0.0.1", port: 4096)])
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[1].executable, "/usr/sbin/lsof")
        XCTAssertTrue(invocations[1].arguments.contains("-p"))
        XCTAssertTrue(invocations[1].arguments.contains("10,11"))
    }
}

private actor DiscoveryProbe {
    private var capturedURLs: [URL] = []

    func call(_ url: URL) -> OpenCodeHealth {
        capturedURLs.append(url)
        return OpenCodeHealth(healthy: true, version: "1.18.10")
    }

    func urls() -> [URL] { capturedURLs }
}

private actor SnapshotCommandRunner {
    struct Invocation: Sendable {
        let executable: String
        let arguments: [String]
    }

    private var calls: [Invocation] = []

    func run(executable: String, arguments: [String]) throws -> String {
        calls.append(.init(executable: executable, arguments: arguments))
        if executable == "/bin/ps" {
            return """
              10     1   501 ??       /Applications/OpenCode.app/Contents/MacOS/OpenCode /Applications/OpenCode.app/Contents/MacOS/OpenCode
              11    10   501 ttys001  /usr/local/bin/opencode opencode serve
              12     1   502 ttys002  /usr/local/bin/opencode opencode serve
            """
        }
        return """
        p11
        n127.0.0.1:4096
        n0.0.0.0:4097
        """
    }

    func invocations() -> [Invocation] { calls }
}
