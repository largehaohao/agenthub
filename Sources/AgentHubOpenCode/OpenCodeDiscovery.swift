import Foundation
import AgentHubCore

struct OpenCodeProcess: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let uid: UInt32
    let command: String
    let bundleID: String?
    let tty: String?

    init(
        pid: Int32,
        parentPID: Int32,
        uid: UInt32,
        command: String,
        bundleID: String? = nil,
        tty: String? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.command = command
        self.bundleID = bundleID
        self.tty = tty
    }
}

struct OpenCodeListeningSocket: Equatable, Hashable, Sendable {
    let pid: Int32
    let host: String
    let port: UInt16
}

struct OpenCodeProcessSocketSnapshot: Equatable, Sendable {
    let processes: [OpenCodeProcess]
    let sockets: [OpenCodeListeningSocket]
}

protocol OpenCodeEndpointDiscovering: Sendable {
    func discover() async throws -> [OpenCodeRuntimeEndpoint]
}

enum OpenCodeManualEndpointError: Error, Equatable {
    case invalidURL
    case nonLoopbackURL
}

enum OpenCodeManualEndpointValidator {
    static func validate(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "http",
              let host = components.host,
              let port = components.port,
              (1...65_535).contains(port),
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              host == "127.0.0.1" || host == "::1" || host == "[::1]",
              let url = components.url else {
            throw OpenCodeManualEndpointError.invalidURL
        }
        return url
    }
}

struct MacOpenCodeDiscovery: OpenCodeEndpointDiscovering, Sendable {
    typealias Snapshot = @Sendable () async throws -> OpenCodeProcessSocketSnapshot
    typealias Probe = @Sendable (URL) async throws -> OpenCodeHealth

    private let uid: UInt32
    private let snapshot: Snapshot
    private let probe: Probe
    private let now: @Sendable () -> Date

    init(
        uid: UInt32 = getuid(),
        snapshot: @escaping Snapshot = {
            try await MacOpenCodeSnapshotter(uid: getuid()).snapshot()
        },
        probe: @escaping Probe = MacOpenCodeDiscovery.probeHealth,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.uid = uid
        self.snapshot = snapshot
        self.probe = probe
        self.now = now
    }

    func discover() async throws -> [OpenCodeRuntimeEndpoint] {
        let state = try await snapshot()
        let processes = Dictionary(
            uniqueKeysWithValues: state.processes
                .filter { $0.uid == uid && Self.isOpenCode($0.command) }
                .map { ($0.pid, $0) }
        )
        var seenURLs = Set<String>()
        var endpoints: [OpenCodeRuntimeEndpoint] = []

        for socket in state.sockets.sorted(by: Self.socketOrder) {
            guard socket.host == "127.0.0.1" || socket.host == "::1",
                  let process = processes[socket.pid],
                  let ownership = Self.ownership(of: process, processes: processes) else {
                continue
            }
            let formattedHost = socket.host == "::1" ? "[::1]" : socket.host
            let baseURLString = "http://\(formattedHost):\(socket.port)"
            guard seenURLs.insert(baseURLString).inserted,
                  let healthURL = URL(string: baseURLString + "/global/health") else {
                continue
            }

            do {
                let health = try await probe(healthURL)
                guard health.healthy, !health.version.isEmpty else { continue }
                endpoints.append(Self.endpoint(
                    socket: socket,
                    baseURL: baseURLString,
                    ownership: ownership,
                    connected: true,
                    version: health.version,
                    message: nil,
                    now: now()
                ))
            } catch OpenCodeHTTPError.authenticationRequired {
                endpoints.append(Self.endpoint(
                    socket: socket,
                    baseURL: baseURLString,
                    ownership: ownership,
                    connected: false,
                    version: nil,
                    message: "authenticationRequired",
                    now: now()
                ))
            } catch {
                continue
            }
        }
        return endpoints.sorted { $0.summary.baseURL < $1.summary.baseURL }
    }

    private struct Ownership {
        let origin: ProviderEndpointOrigin
        let ownerPID: Int32
        let bundleID: String?
        let tty: String?
    }

    private static func ownership(
        of process: OpenCodeProcess,
        processes: [Int32: OpenCodeProcess]
    ) -> Ownership? {
        var lineage: [OpenCodeProcess] = []
        var current: OpenCodeProcess? = process
        var visited = Set<Int32>()
        while let item = current, visited.insert(item.pid).inserted {
            lineage.append(item)
            current = processes[item.parentPID]
        }
        if let desktop = lineage.first(where: { $0.bundleID != nil }) {
            return Ownership(
                origin: .desktop,
                ownerPID: desktop.pid,
                bundleID: desktop.bundleID,
                tty: nil
            )
        }
        if let terminal = lineage.first(where: { $0.tty != nil }) {
            return Ownership(
                origin: .tui,
                ownerPID: terminal.pid,
                bundleID: nil,
                tty: terminal.tty
            )
        }
        return nil
    }

    private static func endpoint(
        socket: OpenCodeListeningSocket,
        baseURL: String,
        ownership: Ownership,
        connected: Bool,
        version: String?,
        message: String?,
        now: Date
    ) -> OpenCodeRuntimeEndpoint {
        OpenCodeRuntimeEndpoint(
            summary: ProviderEndpoint(
                id: "opencode-\(ownership.origin.rawValue)-\(ownership.ownerPID)-\(socket.pid)-\(socket.port)",
                provider: .openCode,
                origin: ownership.origin,
                baseURL: baseURL,
                connected: connected,
                version: version,
                message: message,
                lastSeenAt: now
            ),
            credential: .none,
            processID: socket.pid,
            applicationBundleID: ownership.bundleID,
            terminalTTY: ownership.tty
        )
    }

    private static func isOpenCode(_ command: String) -> Bool {
        command.lowercased().contains("opencode")
    }

    fileprivate static func socketOrder(
        _ left: OpenCodeListeningSocket,
        _ right: OpenCodeListeningSocket
    ) -> Bool {
        if left.host != right.host { return left.host < right.host }
        if left.port != right.port { return left.port < right.port }
        return left.pid < right.pid
    }

    private static func probeHealth(_ url: URL) async throws -> OpenCodeHealth {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw OpenCodeHTTPError.invalidResponse
        }
        if response.statusCode == 401 { throw OpenCodeHTTPError.authenticationRequired }
        guard (200..<300).contains(response.statusCode) else {
            throw OpenCodeHTTPError.httpStatus(response.statusCode)
        }
        return try JSONDecoder().decode(OpenCodeHealth.self, from: data)
    }
}

struct MacOpenCodeSnapshotter: Sendable {
    typealias CommandRunner = @Sendable (String, [String]) async throws -> String

    private let uid: UInt32
    private let run: CommandRunner

    init(
        uid: UInt32 = getuid(),
        run: @escaping CommandRunner = MacOpenCodeSnapshotter.runCommand
    ) {
        self.uid = uid
        self.run = run
    }

    func snapshot() async throws -> OpenCodeProcessSocketSnapshot {
        let output = try await run(
            "/bin/ps",
            ["-axo", "pid=,ppid=,uid=,tty=,comm=,args="]
        )
        let processes = Self.parseProcesses(output).filter {
            $0.uid == uid && $0.command.lowercased().contains("opencode")
        }.sorted { $0.pid < $1.pid }
        guard !processes.isEmpty else {
            return OpenCodeProcessSocketSnapshot(processes: [], sockets: [])
        }

        let pidList = processes.map { String($0.pid) }.joined(separator: ",")
        let socketsOutput = try await run(
            "/usr/sbin/lsof",
            ["-nP", "-a", "-p", pidList, "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        )
        let allowedPIDs = Set(processes.map(\.pid))
        let sockets = Self.parseSockets(socketsOutput).filter {
            allowedPIDs.contains($0.pid) && ($0.host == "127.0.0.1" || $0.host == "::1")
        }
        return OpenCodeProcessSocketSnapshot(
            processes: processes,
            sockets: Array(Set(sockets)).sorted(by: MacOpenCodeDiscovery.socketOrder)
        )
    }

    private static func parseProcesses(_ output: String) -> [OpenCodeProcess] {
        output.split(whereSeparator: \ .isNewline).compactMap { rawLine in
            let fields = rawLine.split(
                maxSplits: 5,
                omittingEmptySubsequences: true,
                whereSeparator: \ .isWhitespace
            )
            guard fields.count == 6,
                  let pid = Int32(fields[0]),
                  let parentPID = Int32(fields[1]),
                  let uid = UInt32(fields[2]) else {
                return nil
            }
            let ttyValue = String(fields[3])
            let command = String(fields[4]) + " " + String(fields[5])
            return OpenCodeProcess(
                pid: pid,
                parentPID: parentPID,
                uid: uid,
                command: command,
                bundleID: command.lowercased().contains("opencode.app/")
                    ? "ai.opencode.desktop"
                    : nil,
                tty: ttyValue == "??" || ttyValue == "-" ? nil : ttyValue
            )
        }
    }

    private static func parseSockets(_ output: String) -> [OpenCodeListeningSocket] {
        var pid: Int32?
        var sockets: [OpenCodeListeningSocket] = []
        for field in output.split(whereSeparator: \ .isNewline).map(String.init) {
            if field.first == "p" {
                pid = Int32(field.dropFirst())
            } else if field.first == "n", let pid,
                      let address = parseAddress(String(field.dropFirst())) {
                sockets.append(.init(pid: pid, host: address.host, port: address.port))
            }
        }
        return sockets
    }

    private static func parseAddress(_ value: String) -> (host: String, port: UInt16)? {
        if value.hasPrefix("[") {
            guard let bracket = value.firstIndex(of: "]"),
                  value.index(after: bracket) < value.endIndex,
                  value[value.index(after: bracket)] == ":",
                  let port = UInt16(value[value.index(bracket, offsetBy: 2)...]) else {
                return nil
            }
            return (String(value[value.index(after: value.startIndex)..<bracket]), port)
        }
        guard let colon = value.lastIndex(of: ":"),
              let port = UInt16(value[value.index(after: colon)...]) else {
            return nil
        }
        return (String(value[..<colon]), port)
    }

    private static func runCommand(_ executable: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus != 0 {
                let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
                throw MacOpenCodeSnapshotError.commandFailed(
                    executable,
                    process.terminationStatus,
                    String(decoding: diagnostic, as: UTF8.self)
                )
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

enum MacOpenCodeSnapshotError: Error {
    case commandFailed(String, Int32, String)
}
