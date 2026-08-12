import Foundation

/// A single process invocation. Commands are always executed directly with an
/// argument array — never through a shell — so titles, prompts, and paths can
/// never be reinterpreted as shell syntax.
public struct ClaudeCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let standardInput: String?

    public init(executable: String, arguments: [String], standardInput: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.standardInput = standardInput
    }
}

public struct ClaudeCommandResult: Equatable, Sendable {
    public let standardOutput: String
    public let exitStatus: Int32

    public init(standardOutput: String, exitStatus: Int32) {
        self.standardOutput = standardOutput
        self.exitStatus = exitStatus
    }
}

public enum ClaudeTerminalError: Error, Equatable, Sendable {
    case commandFailed
    case sessionNotFound
    case stalePrompt
}

/// An AgentHub-managed Claude runtime: one tmux session holding one Claude
/// process, optionally attached to a visible iTerm window.
public struct ClaudeManagedRuntime: Equatable, Sendable {
    public let sessionName: String
    public let paneID: String
    public let claudeSessionID: UUID?
    public let cwd: String?

    public init(
        sessionName: String,
        paneID: String,
        claudeSessionID: UUID? = nil,
        cwd: String? = nil
    ) {
        self.sessionName = sessionName
        self.paneID = paneID
        self.claudeSessionID = claudeSessionID
        self.cwd = cwd
    }
}

public protocol ClaudeTerminalControlling: Sendable {
    func launch(
        name: String,
        claudeSessionID: UUID,
        title: String,
        cwd: String,
        model: String?
    ) async throws -> ClaudeManagedRuntime
    func listManaged() async throws -> [ClaudeManagedRuntime]
    func capture(paneID: String) async throws -> String
    func pasteLiteral(_ text: String, paneID: String) async throws
    func submit(paneID: String) async throws
    func select(sessionName: String) async throws
    func attach(sessionName: String) async throws
    func isAlive(sessionName: String) async throws -> Bool
}

public struct TmuxClaudeTerminalRuntime: ClaudeTerminalControlling {
    /// Only sessions with this prefix are ever treated as AgentHub-managed, so
    /// the runtime cannot capture or send input to a user's own tmux sessions.
    public static let managedPrefix = "agenthub-"

    private let claudeExecutable: URL
    private let tmuxExecutable: URL
    private let osascriptExecutable: URL
    private let run: @Sendable (ClaudeCommand) async throws -> ClaudeCommandResult

    public init(
        claudeExecutable: URL,
        tmuxExecutable: URL,
        osascriptExecutable: URL = URL(fileURLWithPath: "/usr/bin/osascript"),
        run: @escaping @Sendable (ClaudeCommand) async throws -> ClaudeCommandResult
    ) {
        self.claudeExecutable = claudeExecutable
        self.tmuxExecutable = tmuxExecutable
        self.osascriptExecutable = osascriptExecutable
        self.run = run
    }

    public func launch(
        name: String,
        claudeSessionID: UUID,
        title: String,
        cwd: String,
        model: String?
    ) async throws -> ClaudeManagedRuntime {
        // Claude starts with no instruction. The initial prompt is delivered
        // later through a paste buffer so it never appears in process
        // arguments, where any local process could read it.
        var claudeArguments = [
            "--session-id", claudeSessionID.uuidString,
            "--name", title,
        ]
        if let model {
            claudeArguments.append(contentsOf: ["--model", model])
        }

        let create = ClaudeCommand(
            executable: tmuxExecutable.path,
            arguments: [
                "new-session", "-d",
                "-s", name,
                "-c", cwd,
                "--", claudeExecutable.path,
            ] + claudeArguments
        )
        try await runChecked(create)

        let paneID = try await paneID(for: name)
        try await attach(sessionName: name)

        return ClaudeManagedRuntime(
            sessionName: name,
            paneID: paneID,
            claudeSessionID: claudeSessionID,
            cwd: cwd
        )
    }

    public func listManaged() async throws -> [ClaudeManagedRuntime] {
        let result = try await run(
            ClaudeCommand(
                executable: tmuxExecutable.path,
                arguments: [
                    "list-panes", "-a",
                    "-F", "#{session_name}\t#{pane_id}",
                ]
            )
        )
        // tmux exits non-zero when no server is running; that simply means no
        // managed sessions exist.
        guard result.exitStatus == 0 else { return [] }

        var seen: Set<String> = []
        return result.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> ClaudeManagedRuntime? in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 2 else { return nil }
                let sessionName = String(fields[0])
                let paneID = String(fields[1])
                guard sessionName.hasPrefix(Self.managedPrefix),
                      !paneID.isEmpty,
                      seen.insert(sessionName).inserted else { return nil }
                return ClaudeManagedRuntime(sessionName: sessionName, paneID: paneID)
            }
    }

    public func capture(paneID: String) async throws -> String {
        try await runChecked(
            ClaudeCommand(
                executable: tmuxExecutable.path,
                arguments: ["capture-pane", "-p", "-t", paneID]
            )
        ).standardOutput
    }

    /// Delivers text verbatim. `load-buffer -` takes the text on stdin and
    /// `paste-buffer -d` inserts it without interpreting key sequences, so
    /// prompt content can never be executed as tmux commands or key bindings.
    public func pasteLiteral(_ text: String, paneID: String) async throws {
        let bufferName = "agenthub-\(UUID().uuidString)"
        try await runChecked(
            ClaudeCommand(
                executable: tmuxExecutable.path,
                arguments: ["load-buffer", "-b", bufferName, "-"],
                standardInput: text
            )
        )
        try await runChecked(
            ClaudeCommand(
                executable: tmuxExecutable.path,
                arguments: ["paste-buffer", "-d", "-b", bufferName, "-t", paneID]
            )
        )
    }

    public func submit(paneID: String) async throws {
        try await runChecked(
            ClaudeCommand(
                executable: tmuxExecutable.path,
                arguments: ["send-keys", "-t", paneID, "Enter"]
            )
        )
    }

    public func select(sessionName: String) async throws {
        try await runChecked(
            ClaudeCommand(
                executable: tmuxExecutable.path,
                arguments: ["switch-client", "-t", sessionName]
            )
        )
    }

    /// Opens or focuses an iTerm window attached to the exact tmux session. The
    /// AppleScript text is static and the session name is passed through argv,
    /// so it is data rather than script source.
    public func attach(sessionName: String) async throws {
        let script = """
        on run argv
            set sessionName to item 1 of argv
            tell application "iTerm"
                activate
                create window with default profile command \
        ("tmux -CC attach-session -t " & quoted form of sessionName)
            end tell
        end run
        """
        try await runChecked(
            ClaudeCommand(
                executable: osascriptExecutable.path,
                arguments: ["-e", script, sessionName]
            )
        )
    }

    public func isAlive(sessionName: String) async throws -> Bool {
        try await listManaged().contains { $0.sessionName == sessionName }
    }

    private func paneID(for sessionName: String) async throws -> String {
        guard let managed = try await listManaged()
            .first(where: { $0.sessionName == sessionName }) else {
            throw ClaudeTerminalError.sessionNotFound
        }
        return managed.paneID
    }

    @discardableResult
    private func runChecked(_ command: ClaudeCommand) async throws -> ClaudeCommandResult {
        let result = try await run(command)
        guard result.exitStatus == 0 else {
            throw ClaudeTerminalError.commandFailed
        }
        return result
    }
}
