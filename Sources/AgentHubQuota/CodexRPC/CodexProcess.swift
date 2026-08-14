import Foundation

public actor CodexProcess: LineTransport {
    private let explicitExecutableURL: URL?
    private let environment: [String: String]
    private let lineStream: AsyncThrowingStream<Data, Error>
    private let lineContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var diagnosticBuffer = Data()
    private var diagnosticLines: [String] = []
    private var finished = false

    public init(
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        explicitExecutableURL = executableURL
        self.environment = environment
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        lineStream = pair.stream
        lineContinuation = pair.continuation
    }

    public func start() async throws {
        guard process == nil else { throw CodexRPCError.alreadyStarted }
        let executable = try Self.resolveExecutable(
            explicit: explicitExecutableURL,
            environment: environment
        )

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        // Codex ships as a Node script whose shebang is `/usr/bin/env node`, so
        // finding codex is not enough — the child has to be able to find node
        // too, and launchd's PATH cannot.
        var childEnvironment = environment
        childEnvironment["PATH"] = Self.searchPath(environment).joined(separator: ":")
        process.environment = childEnvironment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            Task { await self.consumeOutput(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            Task { await self.consumeDiagnostics(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            guard let self else { return }
            Task { await self.processTerminated(status: status) }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        self.process = process
        inputPipe = input
        outputPipe = output
        errorPipe = errors
    }

    public func send(line: Data) async throws {
        guard let process, process.isRunning, let inputPipe else {
            throw CodexRPCError.notStarted
        }
        var framed = line
        if framed.last != 0x0A {
            framed.append(0x0A)
        }
        try inputPipe.fileHandleForWriting.write(contentsOf: framed)
    }

    public func lines() async -> AsyncThrowingStream<Data, Error> {
        lineStream
    }

    public func stop() async {
        guard !finished else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        try? inputPipe?.fileHandleForWriting.close()
        finish(throwing: nil)
    }

    public func diagnostics() -> [String] {
        diagnosticLines
    }

    static func redact(_ text: String) -> String {
        var value = text
        value = replacing(
            pattern: #"(?i)Bearer\s+[^\s\"']+"#,
            in: value,
            with: "Bearer [REDACTED]"
        )
        value = replacing(
            pattern: #"\bsk-[A-Za-z0-9_-]+\b"#,
            in: value,
            with: "sk-[REDACTED]"
        )
        value = replacing(
            pattern: #"(?i)(\"(?:api[_-]?key|access_token|refresh_token|token)\"\s*:\s*\")[^\"]+(\")"#,
            in: value,
            with: "$1[REDACTED]$2"
        )
        return value
    }

    private static func resolveExecutable(
        explicit: URL?,
        environment: [String: String]
    ) throws -> URL {
        if let explicit {
            guard explicit.lastPathComponent == "codex" else {
                throw CodexRPCError.invalidExecutable(explicit.path)
            }
            guard FileManager.default.isExecutableFile(atPath: explicit.path) else {
                throw CodexRPCError.executableNotFound
            }
            return explicit
        }

        for directory in searchPath(environment) {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw CodexRPCError.executableNotFound
    }

    /// Where CLI tools are installed, beyond whatever `PATH` we inherited.
    ///
    /// An app launched from Finder or Spotlight inherits launchd's `PATH`,
    /// which is just `/usr/bin:/bin:/usr/sbin:/sbin` unless the user has set
    /// one — none of the places a per-user CLI installs itself. Relying on the
    /// inherited value alone meant Codex worked when the app was started from a
    /// terminal and silently reported nothing otherwise.
    static let toolDirectories = [
        ".local/bin",
        ".bun/bin",
        ".cargo/bin",
        ".codex/bin",
        ".volta/bin",
    ]

    static func searchPath(_ environment: [String: String]) -> [String] {
        let inherited = environment["PATH", default: ""]
            .split(separator: ":")
            .map(String.init)
        let home = environment["HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
        let wellKnown = toolDirectories.map {
            home.appendingPathComponent($0).path
        } + ["/opt/homebrew/bin", "/usr/local/bin"]

        // The inherited entries come first: a user who has put a particular
        // codex on their PATH means that one.
        var seen = Set<String>()
        return (inherited + wellKnown).filter { seen.insert($0).inserted }
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            lineContinuation.yield(line)
        }
    }

    private func consumeDiagnostics(_ data: Data) {
        diagnosticBuffer.append(data)
        while let newline = diagnosticBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: diagnosticBuffer[..<newline], as: UTF8.self)
            diagnosticBuffer.removeSubrange(...newline)
            appendDiagnostic(line)
        }
    }

    private func appendDiagnostic(_ line: String) {
        diagnosticLines.append(Self.redact(line))
        if diagnosticLines.count > 64 {
            diagnosticLines.removeFirst(diagnosticLines.count - 64)
        }
    }

    private func processTerminated(status: Int32) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if !outputBuffer.isEmpty {
            lineContinuation.yield(outputBuffer)
            outputBuffer.removeAll(keepingCapacity: false)
        }
        if !diagnosticBuffer.isEmpty {
            appendDiagnostic(String(decoding: diagnosticBuffer, as: UTF8.self))
            diagnosticBuffer.removeAll(keepingCapacity: false)
        }
        if status == 0 {
            finish(throwing: nil)
        } else {
            finish(throwing: CodexRPCError.processExited(status))
        }
    }

    private func finish(throwing error: Error?) {
        guard !finished else { return }
        finished = true
        if let error {
            lineContinuation.finish(throwing: error)
        } else {
            lineContinuation.finish()
        }
    }
}

private func replacing(pattern: String, in value: String, with template: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
    let range = NSRange(value.startIndex..., in: value)
    return expression.stringByReplacingMatches(
        in: value,
        range: range,
        withTemplate: template
    )
}
