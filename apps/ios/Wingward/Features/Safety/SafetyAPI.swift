import CryptoKit
import Foundation
import Security

protocol SafetyAPI: Sendable {
  func report(_ request: ModerationReportRequest) async throws -> ModerationReportResponse
  func block(userID: UUID) async throws -> ModerationBlockResponse
  func unblock(userID: UUID) async throws -> ModerationUnblockResponse
}

struct LiveSafetyAPI: SafetyAPI, Sendable {
  static let reportsPath = "/api/moderation/reports"
  static let blocksPath = "/api/moderation/blocks"

  let client: any AuthenticatedAPIClientProtocol

  init(client: any AuthenticatedAPIClientProtocol) {
    self.client = client
  }

  init(
    baseURL: URL,
    ownerID: String,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    transport: any APIHTTPTransport = URLSession(configuration: .ephemeral)
  ) throws {
    let provider = OwnerBoundAuthSessionTokenProvider(
      expectedOwnerID: ownerID,
      authService: authService,
      profileAPI: profileAPI
    )
    let client = try AuthenticatedAPIClient(
      baseURL: baseURL,
      tokenProvider: provider,
      transport: transport
    )
    self.init(client: client)
  }

  func report(_ request: ModerationReportRequest) async throws -> ModerationReportResponse {
    let body = try JSONEncoder().encode(request)
    return try await client.post(Self.reportsPath, body: body, as: ModerationReportResponse.self)
  }

  func block(userID: UUID) async throws -> ModerationBlockResponse {
    let body = try JSONEncoder().encode(BlockRequest(userID: userID))
    return try await client.post(Self.blocksPath, body: body, as: ModerationBlockResponse.self)
  }

  func unblock(userID: UUID) async throws -> ModerationUnblockResponse {
    try await client.delete(Self.blockPath(for: userID), as: ModerationUnblockResponse.self)
  }

  static func blockPath(for userID: UUID) -> String {
    "\(blocksPath)/\(userID.uuidString.lowercased())"
  }
}

private struct BlockRequest: Encodable, Sendable {
  let userID: UUID

  private enum CodingKeys: String, CodingKey {
    case userID = "user_id"
  }
}

enum SafetyAPIError: Error, Equatable, Sendable {
  case unauthenticated
  case ownerMismatch
  case invalidResponse
  case notFound
  case invalidState
  case rateLimited
  case temporarilyUnavailable
  case cancelled

  var userMessage: String {
    switch self {
    case .unauthenticated:
      return "Sign in again before changing safety settings."
    case .ownerMismatch:
      return "Safety settings are unavailable for this account."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .cancelled:
      return ""
    case .invalidResponse, .notFound, .invalidState, .temporarilyUnavailable:
      return "We couldn't update safety settings. Try again."
    }
  }
}

protocol AccountLifecycleAPI: Sendable {
  func deleteAccount() async throws -> AccountDeletionResponse
}

struct LiveAccountLifecycleAPI: AccountLifecycleAPI, Sendable {
  static let deletionPath = "/api/auth/me"
  static let intentPath = "/api/auth/me/deletion-intent"
  static let statusPath = "/api/auth/deletion-status"

  let client: any AuthenticatedAPIClientProtocol
  private let ownerProfileID: String?
  private let authService: (any AuthService)?
  private let profileAPI: (any ProfileAPI)?
  private let receiptStorage: any AccountDeletionReceiptStoring
  private let statusChecker: any AccountDeletionStatusChecking
  private let receiptGenerator: any AccountDeletionReceiptGenerating
  private let now: @Sendable () -> Date

  init(
    client: any AuthenticatedAPIClientProtocol,
    ownerID: String,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    receiptStorage: any AccountDeletionReceiptStoring,
    statusChecker: any AccountDeletionStatusChecking,
    receiptGenerator: any AccountDeletionReceiptGenerating,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.client = client
    self.ownerProfileID = ownerID
    self.authService = authService
    self.profileAPI = profileAPI
    self.receiptStorage = receiptStorage
    self.statusChecker = statusChecker
    self.receiptGenerator = receiptGenerator
    self.now = now
  }

  init(
    baseURL: URL,
    ownerID: String,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    transport: any APIHTTPTransport = URLSession(configuration: .ephemeral),
    receiptStorage: any AccountDeletionReceiptStoring = KeychainAccountDeletionReceiptStorage(),
    statusChecker: (any AccountDeletionStatusChecking)? = nil,
    receiptGenerator: any AccountDeletionReceiptGenerating = SecureAccountDeletionReceiptGenerator(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    let provider = OwnerBoundAuthSessionTokenProvider(
      expectedOwnerID: ownerID,
      authService: authService,
      profileAPI: profileAPI
    )
    let client = try AuthenticatedAPIClient(
      baseURL: baseURL,
      tokenProvider: provider,
      transport: transport
    )
    self.init(
      client: client,
      ownerID: ownerID,
      authService: authService,
      profileAPI: profileAPI,
      receiptStorage: receiptStorage,
      statusChecker: try statusChecker ?? LiveAccountDeletionStatusChecker(baseURL: baseURL),
      receiptGenerator: receiptGenerator,
      now: now
    )
  }

  func deleteAccount() async throws -> AccountDeletionResponse {
    guard let ownerProfileID, let authService, let profileAPI else {
      throw AccountDeletionError.temporarilyUnavailable
    }
    return try await AccountDeletionMutex.shared.run(key: ownerProfileID) {
      try await self.performDeletion(
        ownerProfileID: ownerProfileID,
        authService: authService,
        profileAPI: profileAPI
      )
    }
  }

  private func performDeletion(
    ownerProfileID: String,
    authService: any AuthService,
    profileAPI: any ProfileAPI
  ) async throws -> AccountDeletionResponse {
    guard Self.isCanonicalUUID(ownerProfileID) else { throw AccountDeletionError.ownerMismatch }
    var stored: StoredAccountDeletionReceipt?
    do {
      stored = try receiptStorage.load(ownerProfileID: ownerProfileID)
    } catch {
      throw AccountDeletionError.temporarilyUnavailable
    }

    let session: AuthSession?
    var sessionLookupFailed = false
    do {
      session = try await authService.currentSession()
    } catch {
      session = nil
      sessionLookupFailed = true
    }

    if let existing = stored {
      guard existing.isValid, existing.ownerProfileID == ownerProfileID else {
        throw AccountDeletionError.invalidResponse
      }
      if let currentAuthUserID = session?.authUserID,
        currentAuthUserID != existing.authUserID
      {
        throw AccountDeletionError.ownerMismatch
      }
      // The server is the expiry authority. Always consult its receipt status
      // before using the local wall clock, because a changed clock must not
      // discard proof that the server still recognizes as deleted or pending.
      var statusWasNotFound = false
      do {
        if try await statusChecker.status(receipt: existing.receipt) == .deleted {
          return AccountDeletionResponse(deleted: true)
        }
      } catch let error as AccountDeletionError where error == .notFound {
        statusWasNotFound = true
      } catch let error as AccountDeletionError {
        guard session != nil else { throw error }
      } catch {
        guard session != nil else { throw AccountDeletionError.temporarilyUnavailable }
      }
      if statusWasNotFound && existing.isExpired(at: now()) {
        // A generalized 404 permits stale local cleanup only after the local
        // retention horizon. A valid pending/deleted status always wins.
        do { try receiptStorage.remove(ownerProfileID: ownerProfileID) } catch {
          throw AccountDeletionError.temporarilyUnavailable
        }
        stored = nil
      }
      guard let session else {
        throw sessionLookupFailed ? AccountDeletionError.temporarilyUnavailable : AccountDeletionError.unauthenticated
      }
      guard session.purpose == .ordinary, !session.accessToken.isEmpty else {
        throw AccountDeletionError.unauthenticated
      }
    }

    if sessionLookupFailed { throw AccountDeletionError.temporarilyUnavailable }
    guard let session,
      session.purpose == .ordinary,
      !session.accessToken.isEmpty,
      let authUserID = session.authUserID,
      Self.isCanonicalUUID(authUserID)
    else {
      throw AccountDeletionError.unauthenticated
    }

    let profile: UserProfile
    do {
      profile = try await profileAPI.fetchProfile(accessToken: session.accessToken)
    } catch {
      if error is CancellationError { throw AccountDeletionError.cancelled }
      throw AccountDeletionError.temporarilyUnavailable
    }
    guard profile.id == ownerProfileID else { throw AccountDeletionError.ownerMismatch }

    var receiptRecord: StoredAccountDeletionReceipt
    if let stored {
      guard stored.isValid, stored.authUserID == authUserID else {
        throw AccountDeletionError.ownerMismatch
      }
      receiptRecord = stored
    } else {
      receiptRecord = try makeAndPersistReceipt(ownerProfileID: ownerProfileID, authUserID: authUserID)
    }

    // A prior attempt can have lost its HTTP response after registering the
    // intent or even after deleting Auth. Re-registering the same receipt is
    // idempotent; a new receipt is never minted while this one is still live.
    let intent: AccountDeletionIntentResponse
    do {
      intent = try await client.post(
        Self.intentPath,
        body: nil,
        accountDeletionReceipt: receiptRecord.receipt,
        as: AccountDeletionIntentResponse.self
      )
      // Expiry is enforced by the server. Do not compare it with device wall
      // time here; clock skew must not block a same-receipt retry.
      receiptRecord.expiresAt = intent.expiresAt
      try receiptStorage.store(receiptRecord)
    } catch let error as AccountDeletionError {
      throw error
    } catch {
      if error is CancellationError { throw AccountDeletionError.cancelled }
      // One bounded retry covers a lost registration response. The same
      // Keychain receipt makes this safe against concurrent/replayed requests.
      if (error as? APIClientError) == .rateLimited { throw AccountDeletionError.rateLimited }
      if (error as? APIClientError) == .notFound { throw AccountDeletionError.notFound }
      if (error as? APIClientError) == .unauthenticated {
        if await isConfirmedDeleted(receipt: receiptRecord.receipt) {
          return AccountDeletionResponse(deleted: true)
        }
        throw AccountDeletionError.unauthenticated
      }
      if (error as? APIClientError) == .forbidden { throw AccountDeletionError.ownerMismatch }
      do {
        let retry = try await client.post(
          Self.intentPath,
          body: nil,
          accountDeletionReceipt: receiptRecord.receipt,
          as: AccountDeletionIntentResponse.self
        )
        receiptRecord.expiresAt = retry.expiresAt
        try receiptStorage.store(receiptRecord)
      } catch {
        if (error as? APIClientError) == .rateLimited { throw AccountDeletionError.rateLimited }
        if (error as? APIClientError) == .notFound { throw AccountDeletionError.notFound }
        if (error as? APIClientError) == .unauthenticated {
          if await isConfirmedDeleted(receipt: receiptRecord.receipt) {
            return AccountDeletionResponse(deleted: true)
          }
          throw AccountDeletionError.unauthenticated
        }
        if (error as? APIClientError) == .forbidden { throw AccountDeletionError.ownerMismatch }
        // A status lookup below decides whether the first or second POST was
        // committed. No failure path turns uncertainty into success.
      }
    }

    do {
      let status = try await statusChecker.status(receipt: receiptRecord.receipt)
      if status == .deleted {
        return AccountDeletionResponse(deleted: true)
      }
    } catch let error as AccountDeletionError {
      if error == .notFound { throw error }
      // The authenticated DELETE remains safe to retry with this receipt even
      // if an intermediate status read is throttled or unavailable.
    } catch {
      // Continue to the idempotent DELETE, but keep the receipt on all failures.
    }

    do {
      let response = try await client.delete(
        Self.deletionPath,
        accountDeletionReceipt: receiptRecord.receipt,
        as: AccountDeletionResponse.self
      )
      if response.deleted {
        return response
      }
    } catch let error as APIClientError {
      switch error {
      case .rateLimited: throw AccountDeletionError.rateLimited
      case .unauthenticated:
        if await isConfirmedDeleted(receipt: receiptRecord.receipt) {
          return AccountDeletionResponse(deleted: true)
        }
        throw AccountDeletionError.unauthenticated
      case .forbidden: throw AccountDeletionError.ownerMismatch
      case .notFound: throw AccountDeletionError.notFound
      case .cancelled: throw AccountDeletionError.cancelled
      case .invalidRequest, .invalidResponse: throw AccountDeletionError.invalidResponse
      case .invalidURL, .transportFailure, .temporarilyUnavailable, .ageVerificationRequired,
        .quotaExhausted, .invalidState:
        break
      }
    } catch {
      if error is CancellationError { throw AccountDeletionError.cancelled }
    }

    // The server may have removed Auth and lost the DELETE response. This GET
    // carries only the receipt and needs no surviving access token.
    do {
      switch try await statusChecker.status(receipt: receiptRecord.receipt) {
      case .deleted:
        return AccountDeletionResponse(deleted: true)
      case .pending:
        throw AccountDeletionError.notAcknowledged
      }
    } catch let error as AccountDeletionError {
      throw error
    } catch {
      if error is CancellationError { throw AccountDeletionError.cancelled }
      throw AccountDeletionError.temporarilyUnavailable
    }
  }

  private func makeAndPersistReceipt(
    ownerProfileID: String,
    authUserID: String
  ) throws -> StoredAccountDeletionReceipt {
    let receipt: String
    do {
      receipt = try receiptGenerator.makeReceipt()
    } catch {
      throw AccountDeletionError.temporarilyUnavailable
    }
    let createdAt = now()
    var record = StoredAccountDeletionReceipt(
      ownerProfileID: ownerProfileID,
      authUserID: authUserID,
      receipt: receipt,
      createdAt: createdAt,
      expiresAt: nil
    )
    guard record.isValid else { throw AccountDeletionError.invalidResponse }
    do { try receiptStorage.store(record) } catch {
      throw AccountDeletionError.temporarilyUnavailable
    }
    return record
  }

  private func isConfirmedDeleted(receipt: String) async -> Bool {
    guard let status = try? await statusChecker.status(receipt: receipt) else { return false }
    return status == .deleted
  }

  private static func isCanonicalUUID(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value) else { return false }
    return uuid.uuidString.lowercased() == value
  }
}

private actor AccountDeletionMutex {
  static let shared = AccountDeletionMutex()
  private var heldKeys = Set<String>()
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  func run<Value: Sendable>(key: String, operation: @Sendable () async throws -> Value) async throws -> Value {
    await acquire(key)
    defer { release(key) }
    if Task.isCancelled { throw AccountDeletionError.cancelled }
    return try await operation()
  }

  private func acquire(_ key: String) async {
    guard !heldKeys.contains(key) else {
      await withCheckedContinuation { continuation in
        waiters[key, default: []].append(continuation)
      }
      return
    }
    heldKeys.insert(key)
  }

  private func release(_ key: String) {
    if var queue = waiters[key], !queue.isEmpty {
      let next = queue.removeFirst()
      waiters[key] = queue.isEmpty ? nil : queue
      next.resume()
    } else {
      heldKeys.remove(key)
    }
  }
}

protocol AccountDeletionReceiptStoring: Sendable {
  func load(ownerProfileID: String) throws -> StoredAccountDeletionReceipt?
  func loadAll() throws -> [StoredAccountDeletionReceipt]
  func store(_ receipt: StoredAccountDeletionReceipt) throws
  func remove(ownerProfileID: String) throws
}

struct StoredAccountDeletionReceipt: Codable, Equatable, Sendable {
  let ownerProfileID: String
  let authUserID: String
  let receipt: String
  let createdAt: Date
  var expiresAt: Date?

  var isValid: Bool {
    Self.isUUID(ownerProfileID) && Self.isUUID(authUserID)
      && AccountDeletionReceipt.isValid(receipt)
      && createdAt.timeIntervalSince1970.isFinite
      && (expiresAt?.timeIntervalSince1970.isFinite ?? true)
  }

  func isExpired(at now: Date) -> Bool {
    now >= (expiresAt ?? createdAt.addingTimeInterval(7 * 24 * 60 * 60))
  }

  private static func isUUID(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value) else { return false }
    return uuid.uuidString.lowercased() == value
  }
}

enum AccountDeletionReceipt {
  static func isValid(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 80, bytes[36] == 46 else { return false }
    let uuid = String(decoding: bytes[0..<36], as: UTF8.self)
    guard let parsed = UUID(uuidString: uuid), parsed.uuidString.lowercased() == uuid else { return false }
    return bytes[37...].allSatisfy { byte in
      (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
    }
  }
}

protocol AccountDeletionReceiptGenerating: Sendable {
  func makeReceipt() throws -> String
}

struct SecureAccountDeletionReceiptGenerator: AccountDeletionReceiptGenerating, Sendable {
  func makeReceipt() throws -> String {
    var secret = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, secret.count, &secret) == errSecSuccess else {
      throw AccountDeletionError.temporarilyUnavailable
    }
    let operationID = UUID().uuidString.lowercased()
    let encodedSecret = Data(secret).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let receipt = "\(operationID).\(encodedSecret)"
    guard AccountDeletionReceipt.isValid(receipt) else { throw AccountDeletionError.invalidResponse }
    return receipt
  }
}

enum AccountDeletionServerStatus: String, Equatable, Sendable {
  case pending
  case deleted
}

private struct AccountDeletionDynamicCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}

struct AccountDeletionIntentResponse: APIValidatable, Equatable, Sendable {
  let status: String
  let expiresAt: Date

  private enum CodingKeys: String, CodingKey { case status, expiresAt = "expires_at" }

  init(from decoder: Decoder) throws {
    let dynamicContainer = try decoder.container(keyedBy: AccountDeletionDynamicCodingKey.self)
    guard Set(dynamicContainer.allKeys.map(\.stringValue)) == Set(["status", "expires_at"]) else {
      throw AccountDeletionError.invalidResponse
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(String.self, forKey: .status)
    let rawDate = try container.decode(String.self, forKey: .expiresAt)
    expiresAt = try APIDTOValidation.requireRFC3339(rawDate)
    try Self.validate(self)
  }

  static func validate(_ value: AccountDeletionIntentResponse) throws {
    guard ["pending", "deleting", "deleted"].contains(value.status) else {
      throw AccountDeletionError.invalidResponse
    }
  }
}

struct AccountDeletionStatusResponse: APIValidatable, Equatable, Sendable {
  let status: AccountDeletionServerStatus

  private enum CodingKeys: String, CodingKey { case status }

  init(from decoder: Decoder) throws {
    let dynamicContainer = try decoder.container(keyedBy: AccountDeletionDynamicCodingKey.self)
    guard Set(dynamicContainer.allKeys.map(\.stringValue)) == Set(["status"]) else {
      throw AccountDeletionError.invalidResponse
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard let status = AccountDeletionServerStatus(rawValue: try container.decode(String.self, forKey: .status)) else {
      throw AccountDeletionError.invalidResponse
    }
    self.status = status
  }

  static func validate(_ value: AccountDeletionStatusResponse) throws {}
}

protocol AccountDeletionStatusChecking: Sendable {
  func status(receipt: String) async throws -> AccountDeletionServerStatus
}

struct LiveAccountDeletionStatusChecker: AccountDeletionStatusChecking, Sendable {
  let baseURL: URL
  let transport: any APIHTTPTransport

  init(baseURL: URL, transport: (any APIHTTPTransport)? = nil) throws {
    guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
      baseURL.user == nil, baseURL.password == nil, baseURL.fragment == nil
    else { throw AccountDeletionError.invalidResponse }
    self.baseURL = baseURL
    self.transport = transport ?? AccountDeletionNoRedirectURLSession()
  }

  func status(receipt: String) async throws -> AccountDeletionServerStatus {
    guard AccountDeletionReceipt.isValid(receipt),
      var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    else { throw AccountDeletionError.invalidResponse }
    let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
    components.path = basePath + LiveAccountLifecycleAPI.statusPath
    components.query = nil
    components.fragment = nil
    guard let url = components.url, url.scheme?.lowercased() == "https", url.host == baseURL.host else {
      throw AccountDeletionError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue(receipt, forHTTPHeaderField: "X-Account-Deletion-Receipt")
    do {
      let (data, response) = try await transport.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw AccountDeletionError.invalidResponse }
      switch http.statusCode {
      case 200:
        guard data.count <= 4_096 else { throw AccountDeletionError.invalidResponse }
        let response = try APIResponseDecoder.decode(data, as: AccountDeletionStatusResponse.self)
        return response.status
      case 404: throw AccountDeletionError.notFound
      case 429: throw AccountDeletionError.rateLimited
      case 401, 403: throw AccountDeletionError.ownerMismatch
      case 500...599: throw AccountDeletionError.temporarilyUnavailable
      default: throw AccountDeletionError.invalidResponse
      }
    } catch let error as AccountDeletionError {
      throw error
    } catch let error as APIClientError {
      switch error {
      case .invalidResponse, .invalidRequest:
        throw AccountDeletionError.invalidResponse
      case .cancelled:
        throw AccountDeletionError.cancelled
      default:
        throw AccountDeletionError.temporarilyUnavailable
      }
    } catch {
      if error is CancellationError || ((error as? URLError)?.code == .cancelled) {
        throw AccountDeletionError.cancelled
      }
      throw AccountDeletionError.temporarilyUnavailable
    }
  }
}

private struct AccountDeletionNoRedirectURLSession: APIHTTPTransport, Sendable {
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: configuration, delegate: AccountDeletionNoRedirectDelegate(), delegateQueue: nil)
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }
}

private final class AccountDeletionNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

protocol AccountDeletionRecoveryChecking: Sendable {
  func check(authUserID: String?) async -> AccountDeletionRecoveryOutcome
  func clearDeletedReceipt(ownerProfileID: String) async throws
}

enum AccountDeletionRecoveryOutcome: Equatable, Sendable {
  case none
  case pending
  case deleted(ownerProfileID: String, authUserID: String)
  case unavailable
}

struct LiveAccountDeletionRecovery: AccountDeletionRecoveryChecking, Sendable {
  let storage: any AccountDeletionReceiptStoring
  let checker: any AccountDeletionStatusChecking
  private let now: @Sendable () -> Date

  init(
    storage: any AccountDeletionReceiptStoring = KeychainAccountDeletionReceiptStorage(),
    checker: any AccountDeletionStatusChecking,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.storage = storage
    self.checker = checker
    self.now = now
  }

  func check(authUserID: String?) async -> AccountDeletionRecoveryOutcome {
    let records: [StoredAccountDeletionReceipt]
    do { records = try storage.loadAll() } catch { return .unavailable }
    var foundPending = false
    for record in records {
      guard record.isValid else { return .unavailable }
      guard authUserID == nil || record.authUserID == authUserID else { continue }
      do {
        switch try await checker.status(receipt: record.receipt) {
        case .deleted:
          // Keep the record until AuthSessionController resets external state
          // and explicitly clears it after local sign-out/cleanup completes.
          return .deleted(ownerProfileID: record.ownerProfileID, authUserID: record.authUserID)
        case .pending:
          foundPending = true
        }
      } catch let error as AccountDeletionError where error == .notFound {
        // A 404 intentionally hides whether the receipt is unknown, mismatched,
        // or expired. It can permit local cleanup only after the local retention
        // horizon; server-confirmed pending/deleted always wins over device time.
        if record.isExpired(at: now()) {
          do { try storage.remove(ownerProfileID: record.ownerProfileID) } catch { return .unavailable }
          continue
        }
        return .unavailable
      } catch {
        return .unavailable
      }
    }
    return foundPending ? .pending : .none
  }

  func clearDeletedReceipt(ownerProfileID: String) async throws {
    try storage.remove(ownerProfileID: ownerProfileID)
  }
}

enum AccountDeletionError: Error, Equatable, Sendable {
  case unauthenticated
  case ownerMismatch
  case notFound
  case notAcknowledged
  case invalidResponse
  case rateLimited
  case temporarilyUnavailable
  case cancelled

  var userMessage: String {
    switch self {
    case .unauthenticated:
      return "Sign in again before deleting your account."
    case .ownerMismatch:
      return "Account deletion is unavailable for this account."
    case .notFound, .notAcknowledged, .invalidResponse, .temporarilyUnavailable:
      return "We couldn't confirm account deletion. Try again."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .cancelled:
      return ""
    }
  }
}

/// The auth layer injects the final local cleanup operation.  This protocol
/// keeps the feature from clearing a session before the server acknowledgement.
protocol SessionCleanup: Sendable {
  /// The auth boundary must compare this expected owner with its current
  /// session before clearing anything. A stale deletion response must never
  /// sign out a different user who has since signed in on the same device.
  func clearAfterServerDeletion(ownerID: String) async
}
