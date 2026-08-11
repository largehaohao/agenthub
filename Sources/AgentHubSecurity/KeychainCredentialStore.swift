import Foundation
import Security

public protocol CredentialStoring: Sendable {
    func save(_ secret: String, reference: String) throws
    func read(reference: String) throws -> String
    func delete(reference: String) throws
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case notFound
    case invalidData
    case keychainStatus(OSStatus)
}

public struct KeychainCredentialStore: CredentialStoring, Sendable {
    private let service: String

    public init(service: String = "com.agenthub.opencode") {
        self.service = service
    }

    public func save(_ secret: String, reference: String) throws {
        let query = baseQuery(reference: reference)
        let data = Data(secret.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(addQuery as CFDictionary, nil))
        default:
            throw CredentialStoreError.keychainStatus(updateStatus)
        }
    }

    public func read(reference: String) throws -> String {
        var query = baseQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw CredentialStoreError.notFound
        }
        try check(status)
        guard let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidData
        }
        return secret
    }

    public func delete(reference: String) throws {
        let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)
        guard status != errSecItemNotFound else { return }
        try check(status)
    }

    private func baseQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainStatus(status)
        }
    }
}
