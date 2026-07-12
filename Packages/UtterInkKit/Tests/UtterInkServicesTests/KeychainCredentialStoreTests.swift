import Foundation
import Security
import XCTest
import UtterInkCore
import UtterInkServices

final class KeychainCredentialStoreTests: XCTestCase {
    private let profileID = UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678")!
    private let service = "dev.utterink.UtterInk.provider-credentials"

    func testPublicInitializerIsAvailableWithoutTouchingKeychain() {
        let store: any CredentialStore = KeychainCredentialStore()
        XCTAssertNotNil(store)
    }

    func testWriteAddsAnExactGenericPasswordItemWithoutAccessGroup() async throws {
        let client = KeychainSecurityClientFake()
        let store = KeychainCredentialStore(
            service: service,
            accessGroup: nil,
            client: client
        )
        let secret = SessionSecret(utf8: "write-canary")
        defer { secret.clear() }

        try await store.write(secret, profileID: profileID)

        let attributes = try XCTUnwrap(client.addQueries.single)
        assertBaseQuery(
            attributes,
            expectedKeys: baseKeys.union([key(kSecValueData)]),
            accessGroup: nil
        )
        XCTAssertEqual(attributes[key(kSecValueData)] as? Data, Data("write-canary".utf8))
        XCTAssertTrue(client.updateCalls.isEmpty)
    }

    func testDuplicateWriteUpdatesOnlyTheSecretUsingTheExactMatchQuery() async throws {
        let client = KeychainSecurityClientFake()
        client.addStatus = errSecDuplicateItem
        let store = KeychainCredentialStore(
            service: service,
            accessGroup: nil,
            client: client
        )
        let secret = SessionSecret(utf8: "replacement-canary")
        defer { secret.clear() }

        try await store.write(secret, profileID: profileID)

        let call = try XCTUnwrap(client.updateCalls.single)
        assertBaseQuery(call.query, expectedKeys: baseKeys, accessGroup: nil)
        XCTAssertEqual(Set(call.attributes.keys), [key(kSecValueData)])
        XCTAssertEqual(
            call.attributes[key(kSecValueData)] as? Data,
            Data("replacement-canary".utf8)
        )
    }

    func testReadUsesExactQueryAndReturnsCopiedSecret() async throws {
        let client = KeychainSecurityClientFake()
        client.copyResult = KeychainCopyResult(
            status: errSecSuccess,
            data: Data("read-canary".utf8)
        )
        let store = KeychainCredentialStore(
            service: service,
            accessGroup: nil,
            client: client
        )

        let secret = try await store.read(profileID: profileID)
        defer { secret?.clear() }

        let value = try XCTUnwrap(secret).withUTF8 { $0 }
        XCTAssertEqual(value, "read-canary")
        let query = try XCTUnwrap(client.copyQueries.single)
        assertBaseQuery(
            query,
            expectedKeys: baseKeys.union([key(kSecReturnData), key(kSecMatchLimit)]),
            accessGroup: nil
        )
        XCTAssertEqual(query[key(kSecReturnData)] as? Bool, true)
        XCTAssertEqual(query[key(kSecMatchLimit)] as? String, key(kSecMatchLimitOne))
    }

    func testReadNotFoundReturnsNil() async throws {
        let client = KeychainSecurityClientFake()
        client.copyResult = KeychainCopyResult(status: errSecItemNotFound, data: nil)
        let store = KeychainCredentialStore(client: client)

        let value = try await store.read(profileID: profileID)

        XCTAssertNil(value)
        XCTAssertEqual(client.copyQueries.count, 1)
    }

    func testDeleteUsesExactQueryAndTreatsNotFoundAsSuccess() async throws {
        let client = KeychainSecurityClientFake()
        client.deleteStatus = errSecItemNotFound
        let store = KeychainCredentialStore(
            service: service,
            accessGroup: nil,
            client: client
        )

        try await store.delete(profileID: profileID)

        let query = try XCTUnwrap(client.deleteQueries.single)
        assertBaseQuery(query, expectedKeys: baseKeys, accessGroup: nil)
    }

    func testAccessGroupIsIncludedInEveryItemQueryWhenConfigured() async throws {
        let accessGroup = "TEAMID.dev.utterink.shared"
        let client = KeychainSecurityClientFake()
        client.addStatus = errSecDuplicateItem
        client.copyResult = KeychainCopyResult(status: errSecItemNotFound, data: nil)
        let store = KeychainCredentialStore(
            service: service,
            accessGroup: accessGroup,
            client: client
        )
        let secret = SessionSecret(utf8: "group-canary")
        defer { secret.clear() }

        try await store.write(secret, profileID: profileID)
        _ = try await store.read(profileID: profileID)
        try await store.delete(profileID: profileID)

        let itemQueries = client.addQueries
            + client.updateCalls.map(\.query)
            + client.copyQueries
            + client.deleteQueries
        XCTAssertEqual(itemQueries.count, 4)
        for query in itemQueries {
            XCTAssertEqual(query[key(kSecAttrAccessGroup)] as? String, accessGroup)
            XCTAssertEqual(query[key(kSecAttrAccessible)] as? String, key(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly))
        }
    }

    func testAllOperationFailuresExposeOnlyTheStatusAndNoQueryOrSecretData() async throws {
        let canary = "SECRET-CANARY-DO-NOT-LEAK"
        let secret = SessionSecret(utf8: canary)
        defer { secret.clear() }

        let addClient = KeychainSecurityClientFake()
        addClient.addStatus = errSecNotAvailable
        let addError = await captureError {
            try await KeychainCredentialStore(
                service: "service-\(canary)",
                client: addClient
            ).write(secret, profileID: profileID)
        }

        let updateClient = KeychainSecurityClientFake()
        updateClient.addStatus = errSecDuplicateItem
        updateClient.updateStatus = errSecAuthFailed
        let updateError = await captureError {
            try await KeychainCredentialStore(client: updateClient)
                .write(secret, profileID: profileID)
        }

        let readClient = KeychainSecurityClientFake()
        readClient.copyResult = KeychainCopyResult(status: errSecInteractionNotAllowed, data: nil)
        let readError = await captureError {
            _ = try await KeychainCredentialStore(client: readClient).read(profileID: profileID)
        }

        let deleteClient = KeychainSecurityClientFake()
        deleteClient.deleteStatus = errSecNotAvailable
        let deleteError = await captureError {
            try await KeychainCredentialStore(client: deleteClient).delete(profileID: profileID)
        }

        let expected: [(Error?, OSStatus)] = [
            (addError, errSecNotAvailable),
            (updateError, errSecAuthFailed),
            (readError, errSecInteractionNotAllowed),
            (deleteError, errSecNotAvailable)
        ]
        for (error, status) in expected {
            let error = try XCTUnwrap(error)
            XCTAssertEqual((error as? KeychainError)?.status, status)
            let rendered = [
                String(describing: error),
                String(reflecting: error),
                error.localizedDescription
            ].joined(separator: " ")
            XCTAssertFalse(rendered.contains(canary))
            XCTAssertFalse(rendered.contains(service))
            XCTAssertFalse(rendered.contains(profileID.uuidString))
            XCTAssertTrue(rendered.contains(String(status)))
        }
    }

    func testSuccessfulReadWithMissingOrNonUTF8DataThrowsSanitizedDecodeStatus() async throws {
        for data in [nil, Data([0xFF, 0xFE])] as [Data?] {
            let client = KeychainSecurityClientFake()
            client.copyResult = KeychainCopyResult(status: errSecSuccess, data: data)
            let error = await captureError {
                _ = try await KeychainCredentialStore(client: client).read(profileID: profileID)
            }

            let typed = try XCTUnwrap(error as? KeychainError)
            XCTAssertEqual(typed.status, errSecDecode)
            XCTAssertEqual(typed.description, "Keychain operation failed with status \(errSecDecode).")
            XCTAssertEqual(typed.debugDescription, typed.description)
        }
    }

    private var baseKeys: Set<String> {
        [
            key(kSecClass),
            key(kSecAttrService),
            key(kSecAttrAccount),
            key(kSecAttrAccessible)
        ]
    }

    private func assertBaseQuery(
        _ query: [String: Any],
        expectedKeys: Set<String>,
        accessGroup: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var expectedKeys = expectedKeys
        if accessGroup != nil {
            expectedKeys.insert(key(kSecAttrAccessGroup))
        }
        XCTAssertEqual(Set(query.keys), expectedKeys, file: file, line: line)
        XCTAssertEqual(query[key(kSecClass)] as? String, key(kSecClassGenericPassword), file: file, line: line)
        XCTAssertEqual(query[key(kSecAttrService)] as? String, service, file: file, line: line)
        XCTAssertEqual(query[key(kSecAttrAccount)] as? String, profileID.uuidString, file: file, line: line)
        XCTAssertEqual(
            query[key(kSecAttrAccessible)] as? String,
            key(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly),
            file: file,
            line: line
        )
        XCTAssertEqual(query[key(kSecAttrAccessGroup)] as? String, accessGroup, file: file, line: line)
    }

    private func captureError(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }
}

private final class KeychainSecurityClientFake: KeychainSecurityClient, @unchecked Sendable {
    private let lock = NSLock()
    var addStatus: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecSuccess
    var copyResult = KeychainCopyResult(status: errSecSuccess, data: nil)
    var deleteStatus: OSStatus = errSecSuccess

    private var recordedAdds: [[String: Any]] = []
    private var recordedUpdates: [(query: [String: Any], attributes: [String: Any])] = []
    private var recordedCopies: [[String: Any]] = []
    private var recordedDeletes: [[String: Any]] = []

    var addQueries: [[String: Any]] { lock.withLock { recordedAdds } }
    var updateCalls: [(query: [String: Any], attributes: [String: Any])] {
        lock.withLock { recordedUpdates }
    }
    var copyQueries: [[String: Any]] { lock.withLock { recordedCopies } }
    var deleteQueries: [[String: Any]] { lock.withLock { recordedDeletes } }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock { recordedAdds.append(attributes) }
        return addStatus
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock { recordedUpdates.append((query, attributes)) }
        return updateStatus
    }

    func copyMatching(_ query: [String: Any]) -> KeychainCopyResult {
        lock.withLock { recordedCopies.append(query) }
        return copyResult
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock { recordedDeletes.append(query) }
        return deleteStatus
    }
}

private func key(_ value: CFString) -> String {
    value as String
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
