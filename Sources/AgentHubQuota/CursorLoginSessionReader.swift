import Foundation
import SQLite3

public enum CursorLoginSessionError: Error, Equatable, Sendable {
    case databaseUnavailable
    case accessTokenMissing
}

/// Reads the Cursor IDE login access token from local application support.
///
/// The token exists only in process memory after `readAccessToken()` returns.
/// This type never logs token material.
public struct CursorLoginSessionReader: Sendable {
    /// Live-probed on macOS: `state.vscdb` ItemTable key `cursorAuth/accessToken`.
    public static let stateDatabaseRelativePath =
        "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    public static let accessTokenItemKey = "cursorAuth/accessToken"

    private let databaseURL: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.databaseURL = homeDirectory.appendingPathComponent(Self.stateDatabaseRelativePath)
    }

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func readAccessToken() throws -> String {
        guard FileManager.default.isReadableFile(atPath: databaseURL.path) else {
            throw CursorLoginSessionError.databaseUnavailable
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK, let database else {
            throw CursorLoginSessionError.databaseUnavailable
        }
        defer { sqlite3_close(database) }

        let query = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CursorLoginSessionError.databaseUnavailable
        }
        defer { sqlite3_finalize(statement) }

        var token: String?
        let bindStatus = Self.accessTokenItemKey.withCString { keyPointer in
            sqlite3_bind_text(statement, 1, keyPointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bindStatus == SQLITE_OK else {
            throw CursorLoginSessionError.databaseUnavailable
        }

        if sqlite3_step(statement) == SQLITE_ROW,
           let raw = sqlite3_column_text(statement, 0) {
            let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                token = value
            }
        }

        guard let token else {
            throw CursorLoginSessionError.accessTokenMissing
        }
        return token
    }
}
