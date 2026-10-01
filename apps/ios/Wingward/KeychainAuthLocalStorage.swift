import CryptoKit
import Foundation
import Security
import Supabase

struct KeychainAuthLocalStorage: AuthLocalStorage, Sendable {
  static let storageKey = "com.wingward.auth.session"
  static let pkceCodeVerifierKey = "\(storageKey)-code-verifier"
  static let recoveryIntentKey = "com.wingward.auth.session.recovery-intent"
  static let recoveryPurposeKey = "com.wingward.auth.session.recovery-purpose"
  static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

  private let service: String

  init(service: String = "com.wingward.auth") {
    self.service = service
  }

  func store(key: String, value: Data) throws {
    let query = baseQuery(for: key)
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [
        kSecValueData as String: value,
        kSecAttrAccessible as String: Self.accessibility,
      ] as CFDictionary
    )

    if updateStatus == errSecItemNotFound {
      var addQuery = query
      addQuery[kSecValueData as String] = value
      addQuery[kSecAttrAccessible as String] = Self.accessibility
      let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeychainStorageError.status(addStatus) }
      return
    }

    guard updateStatus == errSecSuccess else {
      throw KeychainStorageError.status(updateStatus)
    }
  }

  func retrieve(key: String) throws -> Data? {
    var query = baseQuery(for: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainStorageError.status(status) }
    guard let data = result as? Data else { throw KeychainStorageError.invalidData }
    return data
  }

  func remove(key: String) throws {
    let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
    if status == errSecItemNotFound { return }
    guard status == errSecSuccess else { throw KeychainStorageError.status(status) }
  }

  func storeRecoveryIntentForCurrentPKCEVerifier() throws {
    guard let verifier = try retrieve(key: Self.pkceCodeVerifierKey), !verifier.isEmpty else {
      throw KeychainStorageError.invalidData
    }
    try store(key: Self.recoveryIntentKey, value: Self.binding(for: verifier))
  }

  func recoveryIntentMatchesCurrentPKCEVerifier() throws -> Bool {
    guard let intent = try retrieve(key: Self.recoveryIntentKey) else { return false }
    guard intent.count == 32 else { throw KeychainStorageError.invalidData }
    guard let verifier = try retrieve(key: Self.pkceCodeVerifierKey), !verifier.isEmpty else {
      return false
    }
    return intent == Self.binding(for: verifier)
  }

  func hasRecoveryIntent() throws -> Bool {
    try retrieve(key: Self.recoveryIntentKey) != nil
  }

  func clearRecoveryIntent() throws {
    try remove(key: Self.recoveryIntentKey)
  }

  func storeRecoveryPurpose(for identity: RecoverySessionIdentity) throws {
    try store(key: Self.recoveryPurposeKey, value: Self.recoveryPurposeBinding(for: identity))
  }

  func clearRecoveryPurposeMarker() throws {
    try remove(key: Self.recoveryPurposeKey)
  }

  func hasRecoveryPurposeBinding() throws -> Bool {
    try retrieve(key: Self.recoveryPurposeKey) != nil
  }

  func recoveryPurposeMatches(identity: RecoverySessionIdentity) throws -> Bool {
    guard let binding = try retrieve(key: Self.recoveryPurposeKey) else { return false }
    guard binding.count == 32 else {
      throw KeychainStorageError.invalidData
    }
    return binding == Self.recoveryPurposeBinding(for: identity)
  }

  private static func recoveryPurposeBinding(for identity: RecoverySessionIdentity) -> Data {
    binding(for: Data("\(identity.userID.uuidString.lowercased())\u{0}\(identity.sessionID.uuidString.lowercased())".utf8))
  }

  private static func binding(for data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }

  private func baseQuery(for key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }
}

/// Deletion recovery receipts use a separate Keychain service from Supabase
/// session material. This adapter only reads and writes its own synthetic
/// receipt records; it never opens the Auth storage namespace.
struct KeychainAccountDeletionReceiptStorage: AccountDeletionReceiptStoring, Sendable {
  static let service = "com.wingward.account-deletion.receipts"
  private static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

  func load(ownerProfileID: String) throws -> StoredAccountDeletionReceipt? {
    var query = baseQuery(ownerProfileID: ownerProfileID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainStorageError.status(status) }
    guard let data = result as? Data else { throw KeychainStorageError.invalidData }
    return try Self.decode(data)
  }

  func loadAll() throws -> [StoredAccountDeletionReceipt] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    query[kSecAttrSynchronizable as String] = false
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw KeychainStorageError.status(status) }
    guard let items = result as? [Data] else { throw KeychainStorageError.invalidData }
    return try items.map(Self.decode)
  }

  func store(_ receipt: StoredAccountDeletionReceipt) throws {
    let data = try JSONEncoder().encode(receipt)
    let query = baseQuery(ownerProfileID: receipt.ownerProfileID)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: Self.accessibility,
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecItemNotFound {
      var addQuery = query
      addQuery[kSecValueData as String] = data
      addQuery[kSecAttrAccessible as String] = Self.accessibility
      let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
      if addStatus == errSecDuplicateItem {
        let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard retryStatus == errSecSuccess else { throw KeychainStorageError.status(retryStatus) }
        return
      }
      guard addStatus == errSecSuccess else { throw KeychainStorageError.status(addStatus) }
      return
    }
    guard updateStatus == errSecSuccess else { throw KeychainStorageError.status(updateStatus) }
  }

  func remove(ownerProfileID: String) throws {
    let status = SecItemDelete(baseQuery(ownerProfileID: ownerProfileID) as CFDictionary)
    if status == errSecItemNotFound { return }
    guard status == errSecSuccess else { throw KeychainStorageError.status(status) }
  }

  private func baseQuery(ownerProfileID: String) -> [String: Any] {
    let ownerDigest = Data(SHA256.hash(data: Data(ownerProfileID.utf8)))
      .map { String(format: "%02x", $0) }
      .joined()
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: "receipt.\(ownerDigest)",
      kSecAttrSynchronizable as String: false,
    ]
  }

  private static func decode(_ data: Data) throws -> StoredAccountDeletionReceipt {
    let value = try JSONDecoder().decode(StoredAccountDeletionReceipt.self, from: data)
    guard value.isValid else { throw KeychainStorageError.invalidData }
    return value
  }
}

enum KeychainStorageError: Error, Equatable {
  case status(OSStatus)
  case invalidData
}

#if DEBUG
/// One-shot local-auth cleanup for the isolated validation bundle only.
///
/// This deliberately performs deletes without reading any stored values. It
/// never signs out remotely and never touches profile, onboarding, or app
/// settings state.
enum WingwardLocalAuthReset {
  static let launchArgument = "--wingward-reset-local-auth"
  static let validationBundleIdentifier = "com.wingward.postmatchvalidation"
  static let keychainKeys = [
    KeychainAuthLocalStorage.storageKey,
    KeychainAuthLocalStorage.pkceCodeVerifierKey,
    KeychainAuthLocalStorage.recoveryIntentKey,
    KeychainAuthLocalStorage.recoveryPurposeKey,
  ]

  static func isRequested(bundleIdentifier: String?, arguments: [String]) -> Bool {
    bundleIdentifier == validationBundleIdentifier && arguments.contains(launchArgument)
  }

  @discardableResult
  static func runIfRequested(
    bundleIdentifier: String?,
    arguments: [String],
    remove: (String) throws -> Void
  ) throws -> Bool {
    guard isRequested(bundleIdentifier: bundleIdentifier, arguments: arguments) else {
      return false
    }
    for key in keychainKeys {
      try remove(key)
    }
    return true
  }

  @discardableResult
  static func runIfRequested(
    bundleIdentifier: String?,
    arguments: [String],
    storage: KeychainAuthLocalStorage
  ) throws -> Bool {
    try runIfRequested(
      bundleIdentifier: bundleIdentifier,
      arguments: arguments,
      remove: { key in try storage.remove(key: key) }
    )
  }
}
#endif

struct KeychainStorageHealthChecker: AuthStorageHealthChecking, Sendable {
  private let storage: KeychainAuthLocalStorage

  init(storage: KeychainAuthLocalStorage) {
    self.storage = storage
  }

  func preflight() throws {
    // A missing session is a normal first-launch condition. Any other
    // Keychain read failure must stop auth-state interpretation.
    _ = try storage.retrieve(key: KeychainAuthLocalStorage.storageKey)

    let key = "\(KeychainAuthLocalStorage.storageKey).health"
    let marker = Data([0x57, 0x49, 0x4E, 0x47])
    try storage.store(key: key, value: marker)
    let retrieved = try storage.retrieve(key: key)
    try storage.remove(key: key)
    guard retrieved == marker else {
      throw KeychainStorageError.invalidData
    }
  }
}
