import Foundation

public struct AuditEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let action: String
    public let provider: String?
    public let sessionID: UUID?
    public let detail: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        action: String,
        provider: String? = nil,
        sessionID: UUID? = nil,
        detail: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.action = action
        self.provider = provider
        self.sessionID = sessionID
        self.detail = detail
        self.createdAt = createdAt
    }
}

enum PreviewCachePolicy {
    static let maximumTurns = 3
    static let maximumBytes = 256 * 1_024
    static let retention: TimeInterval = 24 * 60 * 60
}
