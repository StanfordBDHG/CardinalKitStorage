//
// This source file is part of the Stanford Spezi open-source project
//
// SPDX-FileCopyrightText: 2022 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Spezi
import XCTRuntimeAssertions


/// Securely store small chunks of data such as credentials and keys.
///
/// The storing of credentials and keys follows the Keychain documentation provided by Apple: 
/// [Using the keychain to manage user secrets](https://developer.apple.com/documentation/security/keychain_services/keychain_items/using_the_keychain_to_manage_user_secrets).
///
/// On the macOS platform, the `CredentialsStorage` uses the [Data protection keychain](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) which mirrors the data protection keychain originated on iOS.
///
/// ## Topics
/// ### Configuration
/// - ``init()``
///
/// ### Credentials
/// - ``Credentials``
/// - ``store(credentials:server:removeDuplicate:storageScope:)``
/// - ``retrieveCredentials(_:server:accessGroup:)``
/// - ``retrieveAllCredentials(forServer:accessGroup:)``
/// - ``updateCredentials(_:server:newCredentials:newServer:removeDuplicate:storageScope:)``
/// - ``deleteCredentials(_:server:accessGroup:)``
/// - ``deleteAllCredentials(itemTypes:accessGroup:)``
///
/// ### Keys
/// - ``createKey(for:size:storageScope:)``
/// - ``retrievePublicKey(for:)``
/// - ``retrievePrivateKey(for:)``
/// - ``deleteKeys(for:)``
public final class CredentialsStorage: Module, DefaultInitializable, EnvironmentAccessible, Sendable {
    /// Configure the `CredentialsStorage` module.
    ///
    /// The `CredentialsStorage` serves as a reusable `Module` that can be used to store store small chunks of data such as credentials and keys.
    ///
    /// - Note: The storing of credentials and keys follows the Keychain documentation provided by Apple:
    /// [Using the keychain to manage user secrets](https://developer.apple.com/documentation/security/keychain_services/keychain_items/using_the_keychain_to_manage_user_secrets).
    public required init() {}
    
    
    // MARK: - Key Handling
    
    /// Create a `ECSECPrimeRandom` key for a specified size.
    /// - Parameters:
    ///   - keyTag: The tag used to identify the key in the keychain or the secure enclave.
    ///   - size: The size of the key in bits. The default value is 256 bits.
    ///   - storageScope: The  ``CredentialsStorageScope`` used to store the newly generate key.
    /// - Returns: Returns the `SecKey` private key generated and stored in the keychain or the secure enclave.
    @discardableResult
    public func createKey(for keyTag: KeyTag, size: Int = 256, storageScope: CredentialsStorageScope = .secureEnclave) throws -> SecKey {
        // The key generation code follows
        // https://developer.apple.com/documentation/security/certificate_key_and_trust_services/keys/protecting_keys_with_the_secure_enclave
        // and
        // https://developer.apple.com/documentation/security/certificate_key_and_trust_services/keys/generating_new_cryptographic_keys
        
        var privateKeyAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: Data(keyTag.rawValue.utf8)
        ]
        if let accessControl = try storageScope.accessControl {
            privateKeyAttrs[kSecAttrAccessControl as String] = accessControl
        }
        
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: size as CFNumber,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: privateKeyAttrs
        ]
        
        // Use Data protection keychain on macOS
        #if os(macOS)
        attributes[kSecUseDataProtectionKeychain as String] = true
        #endif
        
        // Check that the device has a Secure Enclave
        if SecureEnclave.isAvailable {
            // Generate private key in Secure Enclave
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        }
        
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              SecKeyCopyPublicKey(privateKey) != nil else {
            throw CredentialsStorageError.createFailed(error?.takeRetainedValue())
        }
        
        return privateKey
    }
    
    
    /// Retrieves a private key stored in the keychain or the secure enclave identified by a `tag`.
    /// - Parameter keyTag: The tag used to identify the key in the keychain or the secure enclave.
    /// - Returns: Returns the private `SecKey` generated and stored in the keychain or the secure enclave.
    public func retrievePrivateKey(for keyTag: KeyTag) throws -> SecKey? {
        // This method follows
        // https://developer.apple.com/documentation/security/certificate_key_and_trust_services/keys/storing_keys_in_the_keychain
        // for guidance.
        var item: CFTypeRef?
        do {
            try execute(SecItemCopyMatching(keyQuery(for: keyTag) as CFDictionary, &item))
        } catch CredentialsStorageError.notFound {
            return nil
        } catch {
            throw error
        }
        // Unfortunately we have to do a force cast here.
        // The compiler complains that "Conditional downcast to CoreFoundation type 'SecKey' will always succeed"
        // if we use `item as? SecKey`.
        return (item as! SecKey) // swiftlint:disable:this force_cast
    }
    
    
    /// Retrieves a public key stored in the keychain or the secure enclave identified by a `tag`.
    /// - Parameter keyTag: The tag used to identify the key in the keychain or the secure enclave.
    /// - Returns: Returns the public `SecKey` generated and stored in the keychain or the secure enclave.
    public func retrievePublicKey(for keyTag: KeyTag) throws -> SecKey? {
        if let privateKey = try retrievePrivateKey(for: keyTag) {
            return SecKeyCopyPublicKey(privateKey)
        } else {
            return nil
        }
    }
    
    
    /// Deletes the key stored in the keychain or the secure enclave identified by a `tag`.
    /// - Parameter keyTag: The tag used to identify the key in the keychain or the secure enclave.
    public func deleteKeys(for keyTag: KeyTag) throws {
        do {
            try execute(SecItemDelete(keyQuery(for: keyTag) as CFDictionary))
        } catch CredentialsStorageError.notFound {
            return
        } catch {
            throw error
        }
    }
    
    
    private func keyQuery(for keyTag: KeyTag) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.rawValue,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
    
    
    // MARK: - Credentials Handling
    
    /// Stores credentials in the Keychain.
    ///
    /// ```swift
    /// do {
    ///     let serverCredentials = Credentials(
    ///         username: "user",
    ///         password: "password"
    ///     )
    ///     try credentialsStorage.store(
    ///         credentials: serverCredentials,
    ///         server: "stanford.edu",
    ///         storageScope: .keychainSynchronizable
    ///     )
    ///
    ///     // ...
    ///
    /// } catch {
    ///     // Handle creation error here.
    ///     // ...
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - credentials: The ``Credentials`` stored in the Keychain.
    ///   - server: The server associated with the credentials.
    ///   - removeDuplicate: A flag indicating if any existing key for the `username` and `server`
    ///                      combination should be overwritten when storing the credentials.
    ///   - storageScope: The ``CredentialsStorageScope`` of the stored credentials.
    ///                   The ``CredentialsStorageScope/secureEnclave(userPresence:)`` option is not supported for credentials.
    public func store(
        credentials: Credentials,
        server: String? = nil,
        removeDuplicate: Bool = true,
        storageScope: CredentialsStorageScope = .keychain
    ) throws {
        // This method uses code provided by the Apple Developer documentation at
        // https://developer.apple.com/documentation/security/keychain_services/keychain_items/adding_a_password_to_the_keychain.
        
        assert(!(.secureEnclave ~= storageScope), "Storing of keys in the secure enclave is not supported by Apple.")
        
        var query = queryFor(credentials.username, server: server, accessGroup: storageScope.accessGroup)
        query[kSecValueData as String] = Data(credentials.password.utf8)
        
        if case .keychainSynchronizable = storageScope {
            query[kSecAttrSynchronizable as String] = true
        } else if let accessControl = try storageScope.accessControl {
            query[kSecAttrAccessControl as String] = accessControl
        }
        
        do {
            try execute(SecItemAdd(query as CFDictionary, nil))
        } catch let CredentialsStorageError.keychainError(status) where status == -25299 && removeDuplicate {
            try deleteCredentials(credentials.username, server: server)
            try store(credentials: credentials, server: server, removeDuplicate: false)
        } catch {
            throw error
        }
    }
    
    
    /// Delete existing credentials stored in the Keychain.
    ///
    /// ```swift
    /// do {
    ///     try credentialsStorage.deleteCredentials(
    ///         "user",
    ///         server: "spezi.stanford.edu"
    ///     )
    /// } catch {
    ///     // Handle deletion error here.
    ///     // ...
    /// }
    /// ```
    ///
    /// Use to ``deleteAllCredentials(itemTypes:accessGroup:)`` delete all existing credentials stored in the Keychain.
    ///
    /// - Parameters:
    ///   - username: The username associated with the credentials.
    ///   - server: The server associated with the credentials.
    ///   - accessGroup: The access group associated with the credentials.
    public func deleteCredentials(_ username: String, server: String? = nil, accessGroup: String? = nil) throws {
        let query = queryFor(username, server: server, accessGroup: accessGroup)
        try execute(SecItemDelete(query as CFDictionary))
    }
    
    
    /// Delete all existing credentials stored in the Keychain.
    /// - Parameters:
    ///   - itemTypes: The types of items.
    ///   - accessGroup: The access group associated with the credentials.
    public func deleteAllCredentials(itemTypes: CredentialsStorageItemTypes = .all, accessGroup: String? = nil) throws {
        for kSecClassType in itemTypes.kSecClass {
            do {
                var query: [String: Any] = [kSecClass as String: kSecClassType]
                // Only append the accessGroup attribute if the `CredentialsStore` is configured to use KeyChain access groups
                if let accessGroup {
                    query[kSecAttrAccessGroup as String] = accessGroup
                }
                // Use Data protection keychain on macOS
                #if os(macOS)
                query[kSecUseDataProtectionKeychain as String] = true
                #endif
                try execute(SecItemDelete(query as CFDictionary))
            } catch CredentialsStorageError.notFound {
                // We are fine it no keychain items have been found and therefore non had been deleted.
                continue
            } catch {
                print(error)
            }
        }
    }
    
    
    /// Update existing credentials found in the Keychain.
    ///
    /// ```swift
    /// do {
    ///     let newCredentials = Credentials(
    ///         username: "user",
    ///         password: "newPassword"
    ///     )
    ///     try credentialsStorage.updateCredentials(
    ///         "user",
    ///         server: "stanford.edu",
    ///         newCredentials: newCredentials,
    ///         newServer: "spezi.stanford.edu"
    ///     )
    /// } catch {
    ///     // Handle update error here.
    ///     // ...
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - username: The username associated with the old credentials.
    ///   - server: The server associated with the old credentials.
    ///   - newCredentials: The new ``Credentials`` that should be stored in the Keychain.
    ///   - newServer: The server associated with the new credentials.
    ///   - removeDuplicate: A flag indicating if any existing key for the `username` of the new credentials and `newServer`
    ///                      combination should be overwritten when storing the credentials.
    ///   - storageScope: The ``CredentialsStorageScope`` of the newly stored credentials.
    public func updateCredentials(
        // The server parameter belongs to the `username` and therefore should be located next to the `username`.
        _ username: String,
        server: String? = nil, // swiftlint:disable:this function_default_parameter_at_end
        newCredentials: Credentials,
        newServer: String? = nil,
        removeDuplicate: Bool = true,
        storageScope: CredentialsStorageScope = .keychain
    ) throws {
        try deleteCredentials(username, server: server)
        try store(credentials: newCredentials, server: newServer, removeDuplicate: removeDuplicate, storageScope: storageScope)
    }
    
    
    /// Retrieve existing credentials stored in the Keychain.
    ///
    /// ```swift
    /// guard let serverCredentials = credentialsStorage.retrieveCredentials("user", server: "stanford.edu") else {
    ///     // Handle errors here.
    /// }
    ///
    /// // Use the credentials
    /// ```
    ///
    /// Use ``retrieveAllCredentials(forServer:accessGroup:)`` to retrieve all existing credentials stored in the Keychain for a specific server.
    ///
    /// - Parameters:
    ///   - username: The username associated with the credentials.
    ///   - server: The server associated with the credentials.
    ///   - accessGroup: The access group associated with the credentials.
    /// - Returns: Returns the credentials stored in the Keychain identified by the `username`, `server`, and `accessGroup`.
    public func retrieveCredentials(_ username: String, server: String? = nil, accessGroup: String? = nil) throws -> Credentials? {
        try retrieveAllCredentials(forServer: server, accessGroup: accessGroup)
            .first { credentials in
                credentials.username == username
            }
    }
    
    
    /// Retrieve all existing credentials stored in the Keychain for a specific server.
    /// - Parameters:
    ///   - server: The server associated with the credentials.
    ///   - accessGroup: The access group associated with the credentials.
    /// - Returns: Returns all existing credentials stored in the Keychain identified by the `server` and `accessGroup`.
    public func retrieveAllCredentials(forServer server: String? = nil, accessGroup: String? = nil) throws -> [Credentials] {
        // This method uses code provided by the Apple Developer documentation at
        // https://developer.apple.com/documentation/security/keychain_services/keychain_items/searching_for_keychain_items
        
        var query: [String: Any] = queryFor(nil, server: server, accessGroup: accessGroup)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        
        var item: CFTypeRef?
        do {
            try execute(SecItemCopyMatching(query as CFDictionary, &item))
        } catch CredentialsStorageError.notFound {
            return []
        } catch {
            throw error
        }
        
        guard let existingItems = item as? [[String: Any]] else {
            throw CredentialsStorageError.unexpectedCredentialsData
        }
        
        var credentials: [Credentials] = []
        
        for existingItem in existingItems {
            guard let passwordData = existingItem[kSecValueData as String] as? Data,
                  let password = String(data: passwordData, encoding: String.Encoding.utf8),
                  let account = existingItem[kSecAttrAccount as String] as? String else {
                continue
            }
            
            credentials.append(Credentials(username: account, password: password))
        }
        
        return credentials
    }
    
    
    private func execute(_ secOperation: @autoclosure () -> (OSStatus)) throws {
        let status = secOperation()
        
        guard status != errSecItemNotFound else {
            throw CredentialsStorageError.notFound
        }
        guard status != errSecMissingEntitlement else {
            throw CredentialsStorageError.missingEntitlement
        }
        guard status == errSecSuccess else {
            throw CredentialsStorageError.keychainError(status: status)
        }
    }
    
    
    private func queryFor(_ account: String?, server: String?, accessGroup: String?) -> [String: Any] {
        // This method uses code provided by the Apple Developer documentation at
        // https://developer.apple.com/documentation/security/keychain_services/keychain_items/using_the_keychain_to_manage_user_secrets
        
        var query: [String: Any] = [:]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        
        // Only append the accessGroup attribute if the `CredentialsStore` is configured to use KeyChain access groups
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        // Use Data protection keychain on macOS
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        
        // If the user provided us with a server associated with the credentials we assume it is an internet password.
        if server == nil {
            query[kSecClass as String] = kSecClassGenericPassword
        } else {
            query[kSecClass as String] = kSecClassInternetPassword
            // Only append the server attribute if we assume the credentials to be an internet password.
            query[kSecAttrServer as String] = server
        }
        
        return query
    }
}
