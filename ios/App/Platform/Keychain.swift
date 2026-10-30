// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import Foundation
import Security

/// A Keychain failure, carrying the raw `OSStatus`.
struct KeychainError: Error, Sendable, Equatable, CustomStringConvertible {
    let status: OSStatus
    let operation: String

    var description: String {
        // API: SecCopyErrorMessageString(_ status: OSStatus, _ reserved: UnsafeMutableRawPointer?) -> CFString?
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain \(operation) failed: \(status) (\(message))"
    }
}

/// Generic-password items under one service, one item per account. Device-only,
/// available after first unlock, never synchronised to iCloud. Stateless, so
/// freely `Sendable`.
struct GenericPasswordStore: Sendable {
    let service: String

    func read(account: String) throws -> Data? {
        var query = identity(account)
        query[kSecReturnData] = true // API: kSecReturnData
        query[kSecMatchLimit] = kSecMatchLimitOne // API: kSecMatchLimitOne
        var result: CFTypeRef?
        // API: SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status, operation: "read")
        }
    }

    func write(_ data: Data, account: String) throws {
        let key = identity(account)
        var add = key
        add[kSecValueData] = data // API: kSecValueData
        // API: kSecAttrAccessible with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // API: SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // API: SecItemUpdate(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus
            let updateStatus = SecItemUpdate(key as CFDictionary, [kSecValueData: data] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError(status: updateStatus, operation: "update")
            }
        default:
            throw KeychainError(status: status, operation: "add")
        }
    }

    func delete(account: String) throws {
        // API: SecItemDelete(_ query: CFDictionary) -> OSStatus
        let status = SecItemDelete(identity(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete")
        }
    }

    private func identity(_ account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword, // API: kSecClass / kSecClassGenericPassword
            kSecAttrService: service, // API: kSecAttrService
            kSecAttrAccount: account, // API: kSecAttrAccount
            kSecAttrSynchronizable: false, // API: kSecAttrSynchronizable (no iCloud sync)
        ]
    }
}
