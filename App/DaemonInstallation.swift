import Darwin
import Foundation

struct DaemonInstallationPaths: Equatable {
    let supportDirectory: URL
    let executable: URL
    /// Claude invokes this helper directly by absolute path, so it is installed
    /// beside the daemon and never referenced from the LaunchAgent plist.
    let claudeHookExecutable: URL
    let plist: URL
    let standardOutput: URL
    let standardError: URL
}

enum DaemonInstallationStatus: Equatable {
    case notInstalled
    case installed
}

enum DaemonInstallationError: Error {
    case helperMissing
    case launchctlFailed
}

enum DaemonInstallation {
    static let label = "com.agenthub.daemon"

    static func paths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> DaemonInstallationPaths {
        let support = home
            .appendingPathComponent("Library/Application Support/AgentHub", isDirectory: true)
        let logs = support.appendingPathComponent("Logs", isDirectory: true)
        return DaemonInstallationPaths(
            supportDirectory: support,
            executable: support.appendingPathComponent("bin/agenthubd"),
            claudeHookExecutable: support.appendingPathComponent("bin/agenthub-claude-hook"),
            plist: home.appendingPathComponent("Library/LaunchAgents/\(label).plist"),
            standardOutput: logs.appendingPathComponent("agenthubd.log"),
            standardError: logs.appendingPathComponent("agenthubd.error.log")
        )
    }

    static func renderPlist(
        executable: String,
        pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"]
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    ) -> [String: Any] {
        let support = URL(fileURLWithPath: executable)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let logs = support.appendingPathComponent("Logs", isDirectory: true)
        return [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "ThrottleInterval": 5,
            "WorkingDirectory": support.path,
            "EnvironmentVariables": ["PATH": pathEnvironment],
            "StandardOutPath": logs.appendingPathComponent("agenthubd.log").path,
            "StandardErrorPath": logs.appendingPathComponent("agenthubd.error.log").path,
        ]
    }

    static func status(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> DaemonInstallationStatus {
        let paths = paths(home: home)
        return fileManager.fileExists(atPath: paths.executable.path)
            && fileManager.fileExists(atPath: paths.plist.path)
            ? .installed
            : .notInstalled
    }

    static func install(
        helper: URL,
        claudeHook: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"]
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        fileManager: FileManager = .default
    ) throws {
        let hook = claudeHook
            ?? helper.deletingLastPathComponent()
                .appendingPathComponent("agenthub-claude-hook")
        let paths = paths(home: home)

        try stageHelpers(
            daemon: helper,
            claudeHook: hook,
            home: home,
            fileManager: fileManager
        )
        try prepareDirectory(
            paths.standardOutput.deletingLastPathComponent(),
            mode: 0o700,
            fileManager: fileManager
        )
        try fileManager.createDirectory(
            at: paths.plist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let plist = renderPlist(
            executable: paths.executable.path,
            pathEnvironment: pathEnvironment
        )
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try stageData(
            plistData,
            to: paths.plist,
            mode: 0o600,
            fileManager: fileManager
        )

        let domain = "gui/\(getuid())"
        _ = try? runLaunchctl(["bootout", "\(domain)/\(label)"])
        try bootstrap(domain: domain, plist: paths.plist.path)
        try runLaunchctl(["kickstart", "-k", "\(domain)/\(label)"])
    }

    /// Stages both helpers together. Both are validated before either is
    /// copied, so a missing hook bridge cannot leave a half-installed runtime
    /// where the daemon runs but Claude sessions are never observed.
    static func stageHelpers(
        daemon: URL,
        claudeHook: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        for helper in [daemon, claudeHook] {
            guard fileManager.isExecutableFile(atPath: helper.path) else {
                throw DaemonInstallationError.helperMissing
            }
        }

        let paths = paths(home: home)
        try prepareDirectory(paths.supportDirectory, mode: 0o700, fileManager: fileManager)
        try prepareDirectory(
            paths.executable.deletingLastPathComponent(),
            mode: 0o700,
            fileManager: fileManager
        )

        try stageCopy(
            from: daemon,
            to: paths.executable,
            mode: 0o700,
            fileManager: fileManager
        )
        try stageCopy(
            from: claudeHook,
            to: paths.claudeHookExecutable,
            mode: 0o700,
            fileManager: fileManager
        )
    }

    private static func prepareDirectory(
        _ url: URL,
        mode: Int,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private static func stageCopy(
        from source: URL,
        to destination: URL,
        mode: Int,
        fileManager: FileManager
    ) throws {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staged)
        do {
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path)
            try replace(staged: staged, destination: destination, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }

    private static func stageData(
        _ data: Data,
        to destination: URL,
        mode: Int,
        fileManager: FileManager
    ) throws {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: staged, options: .atomic)
        do {
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path)
            try replace(staged: staged, destination: destination, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }

    private static func replace(
        staged: URL,
        destination: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DaemonInstallationError.launchctlFailed
        }
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    }

    private static func bootstrap(domain: String, plist: String) throws {
        for attempt in 1...10 {
            do {
                try runLaunchctl(["bootstrap", domain, plist])
                return
            } catch where attempt < 10 {
                usleep(500_000)
            }
        }
        throw DaemonInstallationError.launchctlFailed
    }
}
