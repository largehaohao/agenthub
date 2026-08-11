import Foundation
import GRDB

enum AgentHubDatabase {
    static func open(at url: URL) throws -> DatabaseQueue {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let queue = try DatabaseQueue(path: url.path)
        try migrator.migrate(queue)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return queue
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("normalized-state-v1") { database in
            try database.create(table: "sessions") { table in
                table.column("id", .text).primaryKey()
                table.column("provider", .text).notNull()
                table.column("account_id", .text).notNull()
                table.column("native_id", .text).notNull()
                table.column("status", .text).notNull()
                table.column("last_activity_at", .double).notNull()
                table.column("body", .blob).notNull()
                table.uniqueKey(["provider", "account_id", "native_id"])
            }

            try database.create(table: "agent_nodes") { table in
                table.column("id", .text).primaryKey()
                table.column("session_id", .text).notNull().indexed()
                table.column("body", .blob).notNull()
            }

            try database.create(table: "pending_requests") { table in
                table.column("id", .text).primaryKey()
                table.column("provider", .text).notNull()
                table.column("provider_request_id", .text).notNull()
                table.column("body", .blob).notNull()
                table.uniqueKey(["provider", "provider_request_id"])
            }

            try database.create(table: "message_envelopes") { table in
                table.column("id", .text).primaryKey()
                table.column("body", .blob).notNull()
            }

            try database.create(table: "quota_windows") { table in
                table.column("id", .text).primaryKey()
                table.column("body", .blob).notNull()
            }

            try database.create(table: "adapter_health") { table in
                table.column("provider", .text).primaryKey()
                table.column("body", .blob).notNull()
            }

            try database.create(table: "audit_events") { table in
                table.column("id", .text).primaryKey()
                table.column("created_at", .double).notNull().indexed()
                table.column("body", .blob).notNull()
            }

            try database.create(table: "cached_turns") { table in
                table.column("session_id", .text).notNull()
                table.column("turn_id", .text).notNull()
                table.column("position", .integer).notNull()
                table.column("byte_count", .integer).notNull()
                table.column("body", .blob).notNull()
                table.primaryKey(["session_id", "turn_id"])
            }
        }
        return migrator
    }
}
