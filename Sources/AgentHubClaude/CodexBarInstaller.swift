import Foundation

public enum CodexBarInstallerError: Error, Equatable, Sendable {
    case packageManagerUnavailable
    case installationFailed
    case validationFailed
}

/// Installs CodexBar through Homebrew, and only when the user explicitly asks.
/// AgentHub never mutates the system as a side effect of observing sessions or
/// of a failed quota read.
public struct CodexBarInstaller: Sendable {
    /// Only these absolute locations are trusted. Resolving `brew` from PATH
    /// would let a directory earlier in PATH decide what AgentHub executes.
    public static let trustedBrewPaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    private let brewPath: String?
    private let run: @Sendable (ClaudeCommand) async throws -> QuotaCommandResult
    private let validate: @Sendable () async throws -> Void

    public init(
        brewPath: String?,
        run: @escaping @Sendable (ClaudeCommand) async throws -> QuotaCommandResult,
        validate: @escaping @Sendable () async throws -> Void
    ) {
        self.brewPath = brewPath
        self.run = run
        self.validate = validate
    }

    public static func resolveBrew(
        isExecutable: (String) -> Bool
    ) -> String? {
        trustedBrewPaths.first(where: isExecutable)
    }

    public static func resolveBrew(fileManager: FileManager = .default) -> String? {
        resolveBrew { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Runs the exact cask installation, then confirms the helper actually
    /// works before reporting success.
    public func install() async throws {
        guard let brewPath else {
            throw CodexBarInstallerError.packageManagerUnavailable
        }

        let result: QuotaCommandResult
        do {
            result = try await run(
                ClaudeCommand(
                    executable: brewPath,
                    arguments: ["install", "--cask", "codexbar"]
                )
            )
        } catch {
            throw CodexBarInstallerError.installationFailed
        }

        guard result.exitStatus == 0 else {
            throw CodexBarInstallerError.installationFailed
        }

        do {
            try await validate()
        } catch {
            throw CodexBarInstallerError.validationFailed
        }
    }
}
