import Foundation
import Security
import UtterInkCore

package struct KeychainCopyResult: @unchecked Sendable {
    package let status: OSStatus
    package var data: Data?

    package init(status: OSStatus, data: Data?) {
        self.status = status
        self.data = data
    }
}

package protocol KeychainSecurityClient: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> KeychainCopyResult
    func delete(_ query: [String: Any]) -> OSStatus
}

package struct KeychainError: Error, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, LocalizedError
{
    package let status: OSStatus

    package init(status: OSStatus) {
        self.status = status
    }

    package var description: String {
        "Keychain operation failed with status \(status)."
    }

    package var debugDescription: String { description }
    package var errorDescription: String? { description }
}

public actor KeychainCredentialStore: CredentialStore {
    private let service: String
    private let accessGroup: String?
    private let client: any KeychainSecurityClient

    public init(
        service: String = "dev.utterink.UtterInk.provider-credentials",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.client = SystemKeychainSecurityClient()
    }

    package init(
        service: String = "dev.utterink.UtterInk.provider-credentials",
        accessGroup: String? = nil,
        client: any KeychainSecurityClient
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.client = client
    }

    public func read(profileID: UUID) async throws -> SessionSecret? {
        var query = itemQuery(profileID: profileID)
        query[securityKey(kSecReturnData)] = true
        query[securityKey(kSecMatchLimit)] = securityKey(kSecMatchLimitOne)

        var result = client.copyMatching(query)
        if result.status == errSecItemNotFound {
            return nil
        }
        guard result.status == errSecSuccess else {
            throw KeychainError(status: result.status)
        }
        guard var data = result.data else {
            throw KeychainError(status: errSecDecode)
        }
        result.data = nil
        defer {
            data.resetBytes(in: 0..<data.count)
            data.removeAll(keepingCapacity: false)
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return SessionSecret(utf8: value)
    }

    public func write(_ secret: SessionSecret, profileID: UUID) async throws {
        var data: Data
        do {
            data = try secret.withUTF8 { Data($0.utf8) }
        } catch {
            throw KeychainError(status: errSecDecode)
        }
        defer {
            data.resetBytes(in: 0..<data.count)
            data.removeAll(keepingCapacity: false)
        }

        let query = itemQuery(profileID: profileID)
        var attributes = query
        attributes[securityKey(kSecValueData)] = data

        let addStatus = client.add(attributes)
        attributes.removeAll(keepingCapacity: false)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw KeychainError(status: addStatus)
        }

        let updateStatus = client.update(
            query,
            attributes: [securityKey(kSecValueData): data]
        )
        guard updateStatus == errSecSuccess else {
            throw KeychainError(status: updateStatus)
        }
    }

    public func delete(profileID: UUID) async throws {
        let status = client.delete(itemQuery(profileID: profileID))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func itemQuery(profileID: UUID) -> [String: Any] {
        var query: [String: Any] = [
            securityKey(kSecClass): securityKey(kSecClassGenericPassword),
            securityKey(kSecAttrService): service,
            securityKey(kSecAttrAccount): profileID.uuidString,
            securityKey(kSecAttrAccessible): securityKey(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        ]
        if let accessGroup {
            query[securityKey(kSecAttrAccessGroup)] = accessGroup
        }
        return query
    }
}

private struct SystemKeychainSecurityClient: KeychainSecurityClient {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func copyMatching(_ query: [String: Any]) -> KeychainCopyResult {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return KeychainCopyResult(status: status, data: item as? Data)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

private func securityKey(_ value: CFString) -> String {
    value as String
}
