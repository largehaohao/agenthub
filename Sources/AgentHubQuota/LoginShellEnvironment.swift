import Foundation

/// The environment the user's login shell exports.
///
/// An app launched from Finder inherits launchd's environment, which holds
/// almost nothing: not the `PATH` a per-user CLI installs onto, and not the
/// proxy variables a CLI needs to reach the network. Everything the user set up
/// in `.zshrc` is invisible to us but plainly visible to the same command run in
/// their terminal — which is exactly why this class of bug looks like "works on
/// my machine" and reappears after being fixed once.
///
/// Rather than guess at individual variables, AgentHub asks the login shell what
/// it exports and hands that to the tools it spawns. Nothing is persisted, and
/// the shell is only ever asked to print its environment.
public actor LoginShellEnvironment {
    public static let shared = LoginShellEnvironment()

    /// Marks where the environment starts, so anything an interactive rc file
    /// prints on the way (banners, version notices) is discarded.
    static let sentinel = "__AGENTHUB_ENV__"

    /// Long enough for a slow rc file, short enough that a wedged shell does not
    /// hold up a refresh.
    static let timeout: Duration = .seconds(8)

    private let capture: @Sendable () async -> Data?
    private var cached: [String: String]?

    public init(capture: @escaping @Sendable () async -> Data? = LoginShellEnvironment.liveCapture) {
        self.capture = capture
    }

    /// Resolved once per launch: starting a login shell is slow, and its
    /// environment does not change under us.
    public func values() async -> [String: String] {
        if let cached { return cached }
        let resolved = await capture().map(Self.parse) ?? [:]
        cached = resolved
        return resolved
    }

    /// Splits `env -0` output. NUL-delimited so values containing newlines —
    /// which real shell configs do produce — cannot split a variable in two.
    static func parse(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        let body = text.components(separatedBy: sentinel).last ?? text

        var values: [String: String] = [:]
        for entry in body.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let split = entry.firstIndex(of: "=") else { continue }
            let name = String(entry[..<split])
            // A shell function exported into the environment is not a variable
            // and must not be handed to a child as one.
            guard !name.isEmpty, !name.hasPrefix("BASH_FUNC_") else { continue }
            values[name] = String(entry[entry.index(after: split)...])
        }
        return values
    }

    /// Asks the user's login shell to print its environment.
    ///
    /// `-l` so login files are read and `-i` so `.zshrc`/`.bashrc` are too —
    /// interactive rc files are where people usually put proxy settings.
    public static let liveCapture: @Sendable () async -> Data? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf %s \(sentinel); /usr/bin/env -0"]
        let output = Pipe()
        process.standardOutput = output
        // An rc file's chatter must not land in the parsed output or on our own
        // error stream.
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting: a shell that prints more than the pipe buffer
        // holds would block forever on a wait-then-read.
        let reader = Task.detached { try? output.fileHandleForReading.readToEnd() }
        let watchdog = Task.detached {
            try? await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        let data = await reader.value
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
