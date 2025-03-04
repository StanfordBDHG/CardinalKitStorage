//
// This source file is part of the Stanford Spezi open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//


import Foundation
import Security


// MARK: Adding Credentials

extension KeychainStorage {
    /// Store credentials into the keychain.
    ///
    /// - parameter credentials: The credentials which should be stored
    /// - parameter tag: The tag defining how and where the credentials should be stored.
    /// - parameter replaceDuplicates: Whether the insert operation adding these credentials into the keychain should replace potential duplicates. Since there cannot be
    public func store(_ credentials: Credentials, for tag: CredentialsTag, replaceDuplicates: Bool = true) throws {
        var query = queryFor(username: credentials.username, tag: tag)
        query[kSecValueData] = Data(credentials.password.utf8)
        // NOTE: we need to use the switch here; credentials.asGenericCredentials is unavailable,
        // since the credentials object we're getting in was most likely manually created.
        switch tag.kind {
        case .genericPassword:
            let credentials = GenericCredentials(other: credentials)
            if let genericData = credentials.generic {
                query[kSecAttrGeneric] = genericData
            }
        case .internetPassword:
            let credentials = InternetCredentials(other: credentials)
            if let description = credentials.description {
                query[kSecAttrDescription] = description
            }
            if let comment = credentials.comment {
                query[kSecAttrComment] = comment
            }
            if let label = credentials.label ?? tag.label {
                query[kSecAttrLabel] = label
            }
        }
        try addAccessControlFields(for: tag, to: &query)
        do {
            try execute(SecItemAdd(query as CFDictionary, nil))
        } catch .duplicateItem where replaceDuplicates {
            try deleteCredentials(withUsername: credentials.username, for: tag)
            try store(credentials, for: tag, replaceDuplicates: false)
        }
    }
    
    
    /// Replaces the credentials identified by `username` and `tag` with a new entry.
    public func updateCredentials(withUsername username: String, for tag: CredentialsTag, with newCredentials: Credentials) throws {
        try deleteCredentials(withUsername: username, for: tag)
        try store(newCredentials, for: tag)
    }
}


// MARK: Retrieving Credentials

extension KeychainStorage {
    private enum RetrieveCredentialsLimit {
        case one, all
        
        var rawValue: CFString {
            switch self {
            case .one: kSecMatchLimitOne
            case .all: kSecMatchLimitAll
            }
        }
    }
    
    /// Retrieves the first matching credentials for the specified tag that match the specified username
    /// - parameter username: The username to check for. Specify `nil` to ignore this and fetch the first matching credentials that match the tag, regardless of their usernames.
    /// - parameter tag: The ``CredentialsTag`` whose entries should be queried.
    public func retrieveCredentials(withUsername username: String?, for tag: CredentialsTag) throws -> Credentials? {
        try retrieveAllCredentials(withUsername: username, for: tag).first
    }
    
    
    /// Retrieves all credentials for the specified tag that match the specified username
    /// - parameter username: The username to check for. Specify `nil` to ignore this and fetch all credentials that match the tag, regardless of their usernames.
    /// - parameter tag: The ``CredentialsTag`` whose entries should be queried.
    public func retrieveAllCredentials(
        withUsername username: String? = nil, // swiftlint:disable:this function_default_parameter_at_end
        for tag: CredentialsTag
    ) throws -> [Credentials] {
        var query: [CFString: Any] = [:]
        query[kSecAttrSynchronizable] = tag.storageOption.isSynchronizable
        if let username {
            query[kSecAttrAccount] = username
        }
        switch tag.kind {
        case .genericPassword(let service):
            query[kSecClass] = kSecClassGenericPassword
            query[kSecAttrService] = service
        case .internetPassword(let server):
            query[kSecClass] = kSecClassInternetPassword
            query[kSecAttrServer] = server
        }
        return try runRetrieveCredentialsQuery(limit: .all, extraQueryEntries: query)
    }
    
    
    /// Retrieves all credentials of the "generic password" kind, for the specified service.
    /// - parameter service: The service for which the credentials should be filtered. Pass `nil` to skip the filtering and return all generic credentials.
    public func retrieveAllGenericCredentials(forService service: String? = nil) throws -> [Credentials] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword
        ]
        if let service {
            query[kSecAttrService] = service
        }
        return try runRetrieveCredentialsQuery(limit: .all, extraQueryEntries: query)
    }
    
    
    /// Retrieves all credentials of the "internet password" kind, for the specified service.
    /// - parameter server: The server for which the credentials should be filtered. Pass `nil` to skip the filtering and return all internet credentials.
    public func retrieveAllInternetCredentials(forServer server: String? = nil) throws -> [Credentials] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword
        ]
        if let server {
            query[kSecAttrServer] = server
        }
        return try runRetrieveCredentialsQuery(limit: .all, extraQueryEntries: query)
    }
    
    
    /// Retrieves all credentials stored in the keychain.
    public func retrieveAllCredentials() throws -> [Credentials] {
        var results: [Credentials] = []
        results.append(contentsOf: try runRetrieveCredentialsQuery(limit: .all, extraQueryEntries: [
            kSecClass: kSecClassGenericPassword
        ]))
        results.append(contentsOf: try runRetrieveCredentialsQuery(limit: .all, extraQueryEntries: [
            kSecClass: kSecClassInternetPassword
        ]))
        return results
    }
    
    
    private func runRetrieveCredentialsQuery(limit: RetrieveCredentialsLimit, extraQueryEntries: [CFString: Any]) throws -> [Credentials] {
        var query: [CFString: Any] = [
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecReturnAttributes: true,
            kSecReturnData: true,
            kSecMatchLimit: limit.rawValue
        ]
        query.merge(extraQueryEntries, uniquingKeysWith: { $1 }) // have incoming entries override existing ones
        var result: CFTypeRef?
        do {
            try execute(SecItemCopyMatching(query as CFDictionary, &result))
        } catch .itemNotFound {
            return []
        } catch {
            throw error
        }
        let items: [[CFString: Any]]
        switch limit {
        case .one:
            guard let result = result as? [CFString: Any] else {
                throw KeychainError.other("Unable to fetch entry")
            }
            items = [result]
        case .all:
            guard let results = result as? [[CFString: Any]] else {
                throw KeychainError.other("Unable to fetch entries")
            }
            items = results
        }
        return items.map { Credentials($0) }
    }
}


// MARK: Deleting Credentials

extension KeychainStorage {
    /// Deletes all matching credentials entries from the keychain.
    ///
    /// If no matching credentials entries exist in the keychain, nothing will be deleted.
    ///
    /// - Warning: Be careful not to delete more than you actually want to delete. If e.g. you pass in a `nil` value for the username, this will delete **all**  password entries for the specified tag.
    ///
    /// ```swift
    /// try keychainStorage.deleteAllCredentials(
    ///     withUsername: "lukas",
    ///     for: .stanfordSUNet
    /// )
    /// ```
    ///
    /// - parameter username: The username associated with the credentials.
    /// - parameter tag: The tag identifying the credentials entry.
    public func deleteCredentials(
        withUsername username: String? = nil, // swiftlint:disable:this function_default_parameter_at_end
        for tag: CredentialsTag
    ) throws {
        do {
            try execute(SecItemDelete(queryFor(username: username, tag: tag) as CFDictionary))
        } catch .itemNotFound {
            return
        } catch {
            throw error
        }
    }
    
    
    // MARK: Bulk Deletion
    
    /// Deletes all credentials from the keychain.
    /// - parameter accessGroup: optional filter determining the access group whose credentials should be deleted.
    @_spi(Internal)
    public func deleteAllCredentials(accessGroup: AccessGroupFilter) throws {
        try deleteAllGenericCredentials(service: nil, accessGroup: accessGroup)
        try deleteAllInternetCredentials(server: nil, accessGroup: accessGroup)
    }
    
    /// Deletes all generic credentials from the keychain.
    /// - parameter service: the service whose credentials should be deleted. pass `nil` to not filter based on service and instead delete everything.
    /// - parameter accessGroup: optional filter determining the access group whose credentials should be deleted.
    @_spi(Internal)
    public func deleteAllGenericCredentials(service: String?, accessGroup: AccessGroupFilter) throws {
        var query = queryFor(username: nil, kind: nil, synchronizable: nil, accessGroup: accessGroup.stringValue)
        query[kSecClass] = kSecClassGenericPassword
        if let service {
            query[kSecAttrService] = service
        }
        do {
            try execute(SecItemDelete(query as CFDictionary))
        } catch .itemNotFound {
            return
        } catch {
            throw error
        }
    }
    
    /// Deletes all internet credentials from the keychain.
    ///
    /// - parameter server: optional filter; if nonnil only internet credentials matching the server will be deleted.
    /// - parameter accessGroup: specify the access group from which the credentials should be deleted.
    @_spi(Internal)
    public func deleteAllInternetCredentials(server: String?, accessGroup: AccessGroupFilter) throws {
        var query = queryFor(username: nil, kind: nil, synchronizable: nil, accessGroup: accessGroup.stringValue)
        query[kSecClass] = kSecClassInternetPassword
        if let server {
            query[kSecAttrServer] = server
        }
        do {
            try execute(SecItemDelete(query as CFDictionary))
        } catch .itemNotFound {
            return
        } catch {
            throw error
        }
    }
}


// MARK: SecItem-Func Dictionary Creation

extension KeychainStorage {
    /// Constructs a query dictionary for the specified username and tag.
    private func queryFor(username account: String?, tag: CredentialsTag) -> [CFString: Any] {
        queryFor(
            username: account,
            kind: tag.kind,
            synchronizable: tag.storageOption.isSynchronizable,
            accessGroup: tag.storageOption.accessGroup
        )
    }
    
    /// Constructs a query dict for fetching credentials via `SecItemCopyMatching`.
    ///
    /// - parameter synchronizable: defines how the query should filter items based on their synchronizability.
    ///     if you pass `nil` for this parameter, the query will match both synchronizable and non-synchroniable entries.
    ///     if you pass `true` or `false`, the query will match only those entries whose synchronizability matches the param value.
    private func queryFor(
        username account: String?,
        kind: CredentialsKind?,
        synchronizable: Bool?, // swiftlint:disable:this discouraged_optional_boolean
        accessGroup: String?
    ) -> [CFString: Any] {
        // This method uses code provided by the Apple Developer documentation at
        // https://developer.apple.com/documentation/security/keychain_services/keychain_items/using_the_keychain_to_manage_user_secrets
        var query: [CFString: Any] = [
            kSecUseDataProtectionKeychain: true
        ]
        switch kind {
        case nil:
            break
        case .genericPassword(let service):
            query[kSecClass] = kSecClassGenericPassword
            query[kSecAttrService] = service
        case .internetPassword(let server):
            query[kSecClass] = kSecClassInternetPassword
            query[kSecAttrServer] = server
        }
        if let account {
            query[kSecAttrAccount] = account
        }
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        switch synchronizable {
        case .none:
            // if the `synchronizable` parameter is set to nil, we do not filter for this field,
            // and instead wanna fetch all entried (both synchronizable and non-synchronizable)
            query[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
        case .some(let value):
            // if the parameter is set, we want to filter for that value
            query[kSecAttrSynchronizable] = value
        }
        return query
    }
}
