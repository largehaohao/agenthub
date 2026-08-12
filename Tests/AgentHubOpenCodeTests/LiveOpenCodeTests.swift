import Darwin
import Foundation
import XCTest
@testable import AgentHubOpenCode

final class LiveOpenCodeTests: XCTestCase {
    func testInstalledOpenCodeSessionCRUDAndDiscoveryWithoutPrompt() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AGENTHUB_LIVE_OPENCODE"] == "1",
            "Set AGENTHUB_LIVE_OPENCODE=1 to test the installed OpenCode binary."
        )
        let server = try await IsolatedLiveOpenCodeServer.start()
        addTeardownBlock { await server.stop() }
        let client = OpenCodeHTTPClient(baseURL: server.baseURL)

        let health = try await client.health()
        XCTAssertTrue(health.healthy)
        let created = try await client.createSession(
            directory: server.temporaryDirectory.path,
            title: "AgentHub live contract",
            agent: nil,
            model: nil
        )
        let fetched = try await client.session(
            id: created.id,
            directory: server.temporaryDirectory.path
        )
        XCTAssertEqual(fetched.id, created.id)

        let discovered = try await MacOpenCodeDiscovery().discover()
        XCTAssertTrue(discovered.contains { $0.summary.baseURL == server.baseURL.absoluteString })

        try await client.deleteSession(
            id: created.id,
            directory: server.temporaryDirectory.path
        )
    }
}

private actor IsolatedLiveOpenCodeServer {
    let baseURL: URL
    let temporaryDirectory: URL
    private let process: Process

    static func start() async throws -> IsolatedLiveOpenCodeServer {
        let executable = try locateOpenCode()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHubLiveOpenCode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        for name in ["config", "data", "cache", "state"] {
            try FileManager.default.createDirectory(
                at: temporaryDirectory.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        let port = try unusedLoopbackPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q", "/dev/null", executable.path,
            "serve", "--pure", "--hostname", "127.0.0.1", "--port", String(port),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_CONFIG_HOME"] = temporaryDirectory.appendingPathComponent("config").path
        environment["XDG_DATA_HOME"] = temporaryDirectory.appendingPathComponent("data").path
        environment["XDG_CACHE_HOME"] = temporaryDirectory.appendingPathComponent("cache").path
        environment["XDG_STATE_HOME"] = temporaryDirectory.appendingPathComponent("state").path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        do {
            for _ in 0..<100 {
                if !process.isRunning { throw LiveOpenCodeError.exitedEarly }
                if let (data, response) = try? await URLSession.shared.data(
                    from: baseURL.appendingPathComponent("global/health")
                ), (response as? HTTPURLResponse)?.statusCode == 200,
                   !data.isEmpty {
                    return IsolatedLiveOpenCodeServer(
                        baseURL: baseURL,
                        temporaryDirectory: temporaryDirectory,
                        process: process
                    )
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw LiveOpenCodeError.readinessTimedOut
        } catch {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    private init(baseURL: URL, temporaryDirectory: URL, process: Process) {
        self.baseURL = baseURL
        self.temporaryDirectory = temporaryDirectory
        self.process = process
    }

    func stop() async {
        if process.isRunning {
            process.terminate()
            for _ in 0..<30 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

private enum LiveOpenCodeError: Error {
    case executableNotFound
    case portAllocationFailed
    case exitedEarly
    case readinessTimedOut
}

private func locateOpenCode() throws -> URL {
    for directory in ProcessInfo.processInfo.environment["PATH", default: ""]
        .split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory))
            .appendingPathComponent("opencode")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    throw LiveOpenCodeError.executableNotFound
}

private func unusedLoopbackPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw LiveOpenCodeError.portAllocationFailed }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw LiveOpenCodeError.portAllocationFailed }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard nameResult == 0 else { throw LiveOpenCodeError.portAllocationFailed }
    return UInt16(bigEndian: address.sin_port)
}
