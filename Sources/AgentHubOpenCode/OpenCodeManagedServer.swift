import Darwin
import Foundation
import Security
import AgentHubCore

protocol ManagedOpenCodeServing: Sendable {
    func ensureRunning() async throws -> OpenCodeRuntimeEndpoint
    func stop() async
}

protocol ManagedOpenCodeProcess: Sendable {
    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onTermination: @escaping @Sendable (Int32) -> Void,
        onDiagnostics: @escaping @Sendable (Data) -> Void
    ) async throws
    func terminate() async
    func processIdentifier() async -> Int32?
}

enum ManagedOpenCodeServerError: Error, Equatable {
    case executableNotFound
    case portAllocationFailed
    case randomGenerationFailed(Int32)
    case readinessTimedOut
}

struct OpenCodeRestartBackoff: Sendable {
    private static let schedule = [1, 2, 4, 8, 16, 32, 60]
    private var index = 0

    mutating func nextDelay() -> Int {
        let delay = Self.schedule[min(index, Self.schedule.count - 1)]
        index = min(index + 1, Self.schedule.count - 1)
        return delay
    }

    mutating func recordHealthy() {
        index = 0
    }
}

struct OpenCodeDiagnosticRing: Sendable {
    private(set) var lines: [String] = []

    mutating func append(_ line: String) {
        lines.append(Self.redact(line))
        if lines.count > 64 {
            lines.removeFirst(lines.count - 64)
        }
    }

    static func redact(_ text: String) -> String {
        var value = text
        let replacements = [
            (#"(?i)(Authorization\s*:\s*Basic\s+)[^\s\"']+"#, "$1[REDACTED]"),
            (#"(?i)(Authorization\s*:\s*Bearer\s+)[^\s\"']+"#, "$1[REDACTED]"),
            (#"(?i)\b(password|token|api[_-]?key)\s*[=:]\s*[^\s\"']+"#, "$1=[REDACTED]"),
        ]
        for (pattern, template) in replacements {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            value = expression.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..., in: value),
                withTemplate: template
            )
        }
        return value
    }
}

actor ManagedOpenCodeServer: ManagedOpenCodeServing {
    typealias ExecutableResolver = @Sendable ([String: String]) throws -> URL
    typealias PortAllocator = @Sendable () throws -> UInt16
    typealias PasswordGenerator = @Sendable () throws -> String
    typealias ProcessFactory = @Sendable () -> any ManagedOpenCodeProcess
    typealias HealthProbe = @Sendable (URL, String, String) async throws -> OpenCodeHealth
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let environment: [String: String]
    private let executableResolver: ExecutableResolver
    private let portAllocator: PortAllocator
    private let passwordGenerator: PasswordGenerator
    private let processFactory: ProcessFactory
    private let healthProbe: HealthProbe
    private let sleep: Sleep
    private let readinessAttempts: Int
    private let now: @Sendable () -> Date

    private var process: (any ManagedOpenCodeProcess)?
    private var endpoint: OpenCodeRuntimeEndpoint?
    private var desiredRunning = false
    private var generation = 0
    private var restartBackoff = OpenCodeRestartBackoff()
    private var restartTask: Task<Void, Never>?
    private var diagnosticRing = OpenCodeDiagnosticRing()

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableResolver: @escaping ExecutableResolver = ManagedOpenCodeServer.resolveExecutable,
        portAllocator: @escaping PortAllocator = ManagedOpenCodeServer.allocateLoopbackPort,
        passwordGenerator: @escaping PasswordGenerator = ManagedOpenCodeServer.generatePassword,
        processFactory: @escaping ProcessFactory = { FoundationManagedOpenCodeProcess() },
        healthProbe: @escaping HealthProbe = ManagedOpenCodeServer.probeHealth,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        readinessAttempts: Int = 100,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.executableResolver = executableResolver
        self.portAllocator = portAllocator
        self.passwordGenerator = passwordGenerator
        self.processFactory = processFactory
        self.healthProbe = healthProbe
        self.sleep = sleep
        self.readinessAttempts = max(1, readinessAttempts)
        self.now = now
    }

    func ensureRunning() async throws -> OpenCodeRuntimeEndpoint {
        desiredRunning = true
        if let endpoint { return endpoint }
        return try await launch()
    }

    func stop() async {
        guard desiredRunning || process != nil else { return }
        desiredRunning = false
        generation += 1
        restartTask?.cancel()
        restartTask = nil
        endpoint = nil
        let ownedProcess = process
        process = nil
        await ownedProcess?.terminate()
    }

    func diagnostics() -> [String] {
        diagnosticRing.lines
    }

    private func launch() async throws -> OpenCodeRuntimeEndpoint {
        let executable = try executableResolver(environment)
        let port = try portAllocator()
        let password = try passwordGenerator()
        guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
            throw ManagedOpenCodeServerError.portAllocationFailed
        }

        let child = processFactory()
        generation += 1
        let launchGeneration = generation
        process = child
        var childEnvironment = environment
        childEnvironment["OPENCODE_SERVER_USERNAME"] = "opencode"
        childEnvironment["OPENCODE_SERVER_PASSWORD"] = password
        let arguments = [
            "serve", "--hostname", "127.0.0.1", "--port", String(port), "--print-logs",
        ]

        do {
            try await child.start(
                executable: executable,
                arguments: arguments,
                environment: childEnvironment,
                onTermination: { [weak self] status in
                    Task { await self?.terminated(status: status, generation: launchGeneration) }
                },
                onDiagnostics: { [weak self] data in
                    Task { await self?.consumeDiagnostics(data) }
                }
            )

            var health: OpenCodeHealth?
            for attempt in 0..<readinessAttempts {
                do {
                    let result = try await healthProbe(baseURL, "opencode", password)
                    if result.healthy, !result.version.isEmpty {
                        health = result
                        break
                    }
                } catch {
                    // A just-started server commonly refuses connections until its socket is ready.
                }
                if attempt + 1 < readinessAttempts {
                    try await sleep(.milliseconds(100))
                }
            }
            guard let health else {
                throw ManagedOpenCodeServerError.readinessTimedOut
            }

            let runtime = OpenCodeRuntimeEndpoint(
                summary: ProviderEndpoint(
                    id: "opencode-managed",
                    provider: .openCode,
                    origin: .managed,
                    baseURL: baseURL.absoluteString,
                    connected: true,
                    version: health.version,
                    lastSeenAt: now()
                ),
                credential: .ephemeral(username: "opencode", password: password),
                processID: await child.processIdentifier(),
                applicationBundleID: nil,
                terminalTTY: nil
            )
            endpoint = runtime
            restartBackoff.recordHealthy()
            return runtime
        } catch {
            if generation == launchGeneration {
                process = nil
                endpoint = nil
            }
            await child.terminate()
            throw error
        }
    }

    private func terminated(status: Int32, generation terminatedGeneration: Int) {
        guard terminatedGeneration == generation else { return }
        process = nil
        endpoint = nil
        guard desiredRunning else { return }
        diagnosticRing.append("OpenCode exited with status \(status)")
        let delay = restartBackoff.nextDelay()
        restartTask?.cancel()
        restartTask = Task { [weak self, sleep] in
            try? await sleep(.seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.restartIfNeeded()
        }
    }

    private func restartIfNeeded() async {
        guard desiredRunning, process == nil else { return }
        do {
            _ = try await launch()
        } catch {
            diagnosticRing.append("OpenCode restart failed: \(error)")
            let delay = restartBackoff.nextDelay()
            restartTask = Task { [weak self, sleep] in
                try? await sleep(.seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.restartIfNeeded()
            }
        }
    }

    private func consumeDiagnostics(_ data: Data) {
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \ .isNewline) {
            diagnosticRing.append(String(line))
        }
    }

    private static func resolveExecutable(environment: [String: String]) throws -> URL {
        let fixedPaths = ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
        let pathCandidates = environment["PATH", default: ""].split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true)
                .appendingPathComponent("opencode").path
        }
        for path in fixedPaths + pathCandidates
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw ManagedOpenCodeServerError.executableNotFound
    }

    private static func allocateLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ManagedOpenCodeServerError.portAllocationFailed }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw ManagedOpenCodeServerError.portAllocationFailed }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard resolved == 0 else { throw ManagedOpenCodeServerError.portAllocationFailed }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func generatePassword() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ManagedOpenCodeServerError.randomGenerationFailed(status)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func probeHealth(
        baseURL: URL,
        username: String,
        password: String
    ) async throws -> OpenCodeHealth {
        try await OpenCodeHTTPClient(
            baseURL: baseURL,
            authorization: .basic(username: username, password: password)
        ).health()
    }
}

private actor FoundationManagedOpenCodeProcess: ManagedOpenCodeProcess {
    private var process: Process?
    private var errorPipe: Pipe?

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onTermination: @escaping @Sendable (Int32) -> Void,
        onDiagnostics: @escaping @Sendable (Data) -> Void
    ) async throws {
        let child = Process()
        let errors = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.environment = environment
        child.standardOutput = errors
        child.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { onDiagnostics(data) }
        }
        child.terminationHandler = { child in
            errors.fileHandleForReading.readabilityHandler = nil
            onTermination(child.terminationStatus)
        }
        do {
            try child.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process = child
        errorPipe = errors
    }

    func terminate() async {
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        errorPipe = nil
    }

    func processIdentifier() async -> Int32? {
        process?.processIdentifier
    }
}
