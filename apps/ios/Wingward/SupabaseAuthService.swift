import Foundation
import Supabase

struct RecoverySessionIdentity: Equatable, Sendable {
  let userID: UUID
  let sessionID: UUID
}

struct RecoverySessionContext: Equatable, Sendable {
  let accessToken: String
  let identity: RecoverySessionIdentity
}

struct SupabaseAuthService: AuthService, Sendable {
  let client: SupabaseClient
  private let storage: KeychainAuthLocalStorage

  init(
    configuration: AppConfiguration,
    storage: KeychainAuthLocalStorage,
    networkSession: URLSession = .shared
  ) {
    self.storage = storage
    let options = SupabaseClientOptions(
      auth: .init(
        storage: storage,
        redirectToURL: CallbackURLPolicy.callbackURL,
        storageKey: KeychainAuthLocalStorage.storageKey,
        flowType: .pkce
      ),
      global: .init(session: networkSession)
    )
    client = SupabaseClient(
      supabaseURL: configuration.supabaseURL,
      supabaseKey: configuration.publishableKey,
      options: options
    )
  }

  func currentSession() async throws -> AuthSession? {
    do {
      let session = try await client.auth.session
      guard try storage.hasRecoveryPurposeBinding() else {
        return try await Self.resolveUnboundCurrentSession(
          accessToken: session.accessToken,
          authUserID: session.user.id.uuidString.lowercased(),
          storage: storage,
          clearInMemorySession: { try? await client.auth.signOut(scope: .local) }
        )
      }
      let context: RecoverySessionContext
      do {
      context = try await recoveryContext(for: session)
      } catch {
        try await Self.invalidateLocalSession(
          storage: storage,
          clearInMemorySession: { try? await client.auth.signOut(scope: .local) }
        )
        return nil
      }
      return try await Self.resolveCurrentSession(
        context: context,
        storage: storage,
        clearInMemorySession: { try? await client.auth.signOut(scope: .local) }
      )
    } catch let error as AuthError where error == .sessionMissing {
      try Self.clearStaleRecoveryStateWithoutSession(storage: storage)
      return nil
    } catch let error as AuthServiceError {
      throw error
    } catch {
      throw AuthServiceError.unavailable
    }
  }

  func signUp(email: String, password: String, redirectTo: URL) async throws -> AuthSession? {
    do {
      try await requireOrdinaryAuthPurpose()

      // No user data is supplied here. In particular, DOB never enters Supabase
      // Auth user metadata.
      let response = try await client.auth.signUp(
        email: email,
        password: password,
        redirectTo: redirectTo
      )
      guard let session = response.session else {
        do {
          try storage.clearRecoveryIntent()
          return nil
        } catch {
          throw AuthServiceError.unavailable
        }
      }
      return try await finishOrdinaryAuthentication(session)
    } catch let error as AuthServiceError {
      throw error
    } catch {
      throw Self.mapAuthFailure(error)
    }
  }

  func signIn(email: String, password: String) async throws -> AuthSession {
    do {
      try await requireOrdinaryAuthPurpose()
      let session = try await client.auth.signIn(email: email, password: password)
      return try await finishOrdinaryAuthentication(session)
    } catch let error as AuthServiceError {
      throw error
    } catch {
      throw Self.mapAuthFailure(error)
    }
  }

  func resetPasswordForEmail(email: String, redirectTo: URL) async throws {
    guard redirectTo == CallbackURLPolicy.recoveryCallbackURL else {
      throw AuthServiceError.callbackIncomplete
    }

    do {
      try await client.auth.resetPasswordForEmail(email, redirectTo: redirectTo)
      // Supabase creates the verifier before sending the request. Binding our
      // recovery intent to it makes the later callback path non-authoritative.
      try storage.storeRecoveryIntentForCurrentPKCEVerifier()
    } catch {
      try? storage.clearRecoveryIntent()
      try? storage.remove(key: KeychainAuthLocalStorage.pkceCodeVerifierKey)
      // The controller intentionally collapses reset outcomes so the UI never
      // reveals whether an account exists or exposes an SDK error.
      throw AuthServiceError.unavailable
    }
  }

  func updatePassword(_ password: String) async throws {
    try await Self.performPasswordUpdate(
      storage: storage,
      currentSession: {
        let session = try await client.auth.session
        return try await recoveryContext(for: session)
      },
      clearInMemorySession: { try? await client.auth.signOut(scope: .local) },
      update: { _ = try await client.auth.update(user: UserAttributes(password: password)) }
    )
  }

  func handleCallback(_ url: URL) async throws -> AuthSession {
    guard let callbackPurpose = CallbackURLPolicy.purpose(for: url) else {
      throw AuthServiceError.callbackIncomplete
    }
    guard CallbackURLPolicy.hasPKCECode(url) else {
      throw AuthServiceError.callbackIncomplete
    }

    let trustedPurpose: AuthSessionPurpose
    do {
      trustedPurpose = try Self.trustedCallbackPurpose(
        callbackPurpose: callbackPurpose,
        storage: storage
      )
    } catch let error as AuthServiceError {
      throw error
    } catch {
      throw AuthServiceError.unavailable
    }

    if trustedPurpose == .passwordRecovery {
      return try await Self.performRecoveryExchange(
        storage: storage,
        exchange: {
          let session = try await client.auth.session(from: url)
          return try await recoveryContext(for: session)
        },
        persistRecoveryPurpose: { try storage.storeRecoveryPurpose(for: $0) },
        clearInMemorySession: { try? await client.auth.signOut(scope: .local) }
      )
    }

    do {
      try await requireOrdinaryAuthPurpose()
      let session = try await client.auth.session(from: url)
      return try await finishOrdinaryAuthentication(session)
    } catch let error as AuthServiceError {
      throw error
    } catch {
      throw AuthServiceError.unavailable
    }
  }

  func signOut() async throws {
    try await Self.performSignOut(
      remoteSignOut: { try await client.auth.signOut() },
      removeLocalSession: {
        try storage.remove(key: KeychainAuthLocalStorage.storageKey)
        try storage.clearRecoveryIntent()
        try storage.clearRecoveryPurposeMarker()
        try storage.remove(key: KeychainAuthLocalStorage.pkceCodeVerifierKey)
      }
    )
  }

  static func mapAuthFailure(_ error: Error) -> AuthServiceError {
    if let authError = error as? AuthError {
      if case let .api(_, errorCode, _, response) = authError {
        if let authFailure = diagnosticAuthFailure(for: errorCode) {
          return .diagnostic(.authFailure(authFailure))
        }
        return .diagnostic(.httpStatus(response.statusCode))
      }
      return .diagnostic(.unknown)
    }
    if error is URLError {
      return .diagnostic(.transport)
    }
    if error is DecodingError {
      return .diagnostic(.decode)
    }
    return .diagnostic(.unknown)
  }

  private static func diagnosticAuthFailure(for errorCode: ErrorCode) -> AuthDiagnosticAuthFailure? {
    if errorCode == .invalidCredentials { return .invalidCredentials }
    if errorCode.rawValue == "email_address_invalid" { return .emailAddressInvalid }
    if errorCode == .emailNotConfirmed { return .emailNotConfirmed }
    if errorCode == .captchaFailed { return .captchaFailed }
    if errorCode == .emailProviderDisabled { return .emailProviderDisabled }
    if errorCode == .providerDisabled { return .providerDisabled }
    if errorCode == .overRequestRateLimit || errorCode == .overEmailSendRateLimit {
      return .rateLimited
    }
    return nil
  }

  static func performSignOut(
    remoteSignOut: () async throws -> Void,
    removeLocalSession: () throws -> Void
  ) async throws {
    var remoteSignOutFailed = false
    do {
      try await remoteSignOut()
    } catch {
      remoteSignOutFailed = true
    }

    do {
      try removeLocalSession()
    } catch {
      throw AuthServiceError.unavailable
    }

    if remoteSignOutFailed {
      throw AuthServiceError.unavailable
    }
  }

  static func trustedCallbackPurpose(
    callbackPurpose: CallbackURLPurpose,
    storage: KeychainAuthLocalStorage
  ) throws -> AuthSessionPurpose {
    let hasIntent = try storage.hasRecoveryIntent()
    let matchesRecoveryIntent = try storage.recoveryIntentMatchesCurrentPKCEVerifier()

    if matchesRecoveryIntent {
      // A recovery code delivered through the normal route is a route swap,
      // not ordinary authentication.
      guard callbackPurpose == .recovery else {
        throw AuthServiceError.callbackIncomplete
      }
      return .passwordRecovery
    }

    if hasIntent {
      // A newer non-recovery PKCE request may replace the verifier. Its normal
      // callback is allowed only after the now-stale recovery intent is gone.
      try storage.clearRecoveryIntent()
    }
    guard callbackPurpose == .normal else {
      throw AuthServiceError.callbackIncomplete
    }
    return .ordinary
  }

  static func sessionPurpose(
    identity: RecoverySessionIdentity,
    storage: KeychainAuthLocalStorage
  ) throws -> AuthSessionPurpose {
    guard try storage.hasRecoveryPurposeBinding() else { return .ordinary }
    guard try storage.recoveryPurposeMatches(identity: identity) else {
      throw AuthServiceError.unavailable
    }
    return .passwordRecovery
  }

  static func resolveCurrentSession(
    context: RecoverySessionContext,
    storage: KeychainAuthLocalStorage,
    clearInMemorySession: () async -> Void
  ) async throws -> AuthSession? {
    do {
      let purpose = try sessionPurpose(identity: context.identity, storage: storage)
      return AuthSession(
        accessToken: context.accessToken,
        purpose: purpose,
        authUserID: context.identity.userID.uuidString.lowercased()
      )
    } catch {
      try await invalidateLocalSession(
        storage: storage,
        clearInMemorySession: clearInMemorySession
      )
      return nil
    }
  }

  static func resolveUnboundCurrentSession(
    accessToken: String,
    authUserID: String? = nil,
    storage: KeychainAuthLocalStorage,
    clearInMemorySession: () async -> Void
  ) async throws -> AuthSession? {
    guard try storage.hasRecoveryIntent() else {
      return AuthSession(accessToken: accessToken, authUserID: authUserID)
    }

    // The SDK persists the exchanged session before this app can persist the
    // recovery-purpose binding. If execution stops in that window, the durable
    // recovery intent makes the next launch fail closed instead of promoting
    // the session to ordinary authentication.
    try await invalidateLocalSession(
      storage: storage,
      clearInMemorySession: clearInMemorySession
    )
    return nil
  }

  static func performRecoveryExchange(
    storage: KeychainAuthLocalStorage,
    exchange: () async throws -> RecoverySessionContext,
    persistRecoveryPurpose: (RecoverySessionIdentity) throws -> Void,
    clearInMemorySession: () async -> Void
  ) async throws -> AuthSession {
    let context: RecoverySessionContext
    do {
      context = try await exchange()
      try persistRecoveryPurpose(context.identity)
      try storage.clearRecoveryIntent()
      try storage.remove(key: KeychainAuthLocalStorage.pkceCodeVerifierKey)
    } catch {
      do {
        try await invalidateLocalSession(
          storage: storage,
          clearInMemorySession: clearInMemorySession
        )
      } catch {
        throw AuthServiceError.unavailable
      }
      throw AuthServiceError.unavailable
    }
    return AuthSession(
      accessToken: context.accessToken,
      purpose: .passwordRecovery,
      authUserID: context.identity.userID.uuidString.lowercased()
    )
  }

  static func performPasswordUpdate(
    storage: KeychainAuthLocalStorage,
    currentSession: () async throws -> RecoverySessionContext,
    clearInMemorySession: () async -> Void,
    update: () async throws -> Void
  ) async throws {
    let context: RecoverySessionContext
    do {
      context = try await currentSession()
    } catch {
      try await invalidateLocalSession(
        storage: storage,
        clearInMemorySession: clearInMemorySession
      )
      throw AuthServiceError.unavailable
    }

    do {
      guard try storage.recoveryPurposeMatches(identity: context.identity) else {
        try await invalidateLocalSession(
          storage: storage,
          clearInMemorySession: clearInMemorySession
        )
        throw AuthServiceError.unavailable
      }
    } catch let error as AuthServiceError {
      throw error
    } catch {
      throw AuthServiceError.unavailable
    }

    do {
      try await update()
    } catch {
      throw AuthServiceError.unavailable
    }
  }

  private static func invalidateLocalSession(
    storage: KeychainAuthLocalStorage,
    clearInMemorySession: () async -> Void
  ) async throws {
    await clearInMemorySession()
    try storage.remove(key: KeychainAuthLocalStorage.storageKey)
    try storage.clearRecoveryIntent()
    try storage.clearRecoveryPurposeMarker()
    try storage.remove(key: KeychainAuthLocalStorage.pkceCodeVerifierKey)
  }

  private func recoveryContext(for session: Session) async throws -> RecoverySessionContext {
    RecoverySessionContext(
      accessToken: session.accessToken,
      identity: try await recoveryIdentity(for: session)
    )
  }

  private func recoveryIdentity(for session: Session) async throws -> RecoverySessionIdentity {
    let claims = try await client.auth.getClaims(jwt: session.accessToken).claims
    // Supabase 2.54.1 exposes this explicit snake-case claim in additionalClaims
    // when its snake-case decoder is active. Prefer the typed field when present.
    let sessionIDString = claims.sessionId
      ?? claims.additionalClaims["session_id"]?.stringValue
      ?? claims.additionalClaims["sessionId"]?.stringValue
    guard
      let subject = claims.sub.flatMap(UUID.init(uuidString:)),
      subject == session.user.id,
      let sessionID = sessionIDString.flatMap(UUID.init(uuidString:))
    else {
      throw AuthServiceError.unavailable
    }
    return RecoverySessionIdentity(userID: session.user.id, sessionID: sessionID)
  }

  // Internal so the purpose gate's session/error branches can be regression
  // tested with real Keychain storage without exposing a production API.
  func requireOrdinaryAuthPurpose(activeSession: Session? = nil) async throws {
    guard try storage.hasRecoveryPurposeBinding() else { return }

    let session: Session
    if let activeSession {
      session = activeSession
    } else {
      do {
        session = try await client.auth.session
      } catch let error as AuthError where error == .sessionMissing {
        try await Self.requireOrdinaryAuthPurpose(
          identity: nil,
          storage: storage,
          clearInMemorySession: { try? await client.auth.signOut(scope: .local) }
        )
        return
      }
    }

    let identity: RecoverySessionIdentity
    do {
      identity = try await recoveryIdentity(for: session)
    } catch {
      try await Self.invalidateLocalSession(
        storage: storage,
        clearInMemorySession: { try? await client.auth.signOut(scope: .local) }
      )
      throw AuthServiceError.unavailable
    }
    try await Self.requireOrdinaryAuthPurpose(
      identity: identity,
      storage: storage,
      clearInMemorySession: { try? await client.auth.signOut(scope: .local) }
    )
  }

  static func requireOrdinaryAuthPurpose(
    identity: RecoverySessionIdentity?,
    storage: KeychainAuthLocalStorage,
    clearInMemorySession: () async -> Void
  ) async throws {
    guard try storage.hasRecoveryPurposeBinding() else { return }
    guard let identity else {
      try storage.clearRecoveryPurposeMarker()
      return
    }
    if try storage.recoveryPurposeMatches(identity: identity) {
      throw AuthServiceError.callbackIncomplete
    }

    try await Self.invalidateLocalSession(
      storage: storage,
      clearInMemorySession: clearInMemorySession
    )
    throw AuthServiceError.unavailable
  }

  private func finishOrdinaryAuthentication(_ session: Session) async throws -> AuthSession {
    try await requireOrdinaryAuthPurpose(activeSession: session)
    return try await Self.finishOrdinaryAuthentication(
      accessToken: session.accessToken,
      authUserID: session.user.id.uuidString.lowercased(),
      storage: storage,
      clearInMemorySession: { try? await client.auth.signOut(scope: .local) }
    )
  }

  static func finishOrdinaryAuthentication(
    accessToken: String,
    authUserID: String? = nil,
    storage: KeychainAuthLocalStorage,
    clearInMemorySession: () async -> Void
  ) async throws -> AuthSession {
    do {
      try storage.clearRecoveryIntent()
      try storage.remove(key: KeychainAuthLocalStorage.pkceCodeVerifierKey)
    } catch {
      try await Self.invalidateLocalSession(
        storage: storage,
        clearInMemorySession: clearInMemorySession
      )
      throw AuthServiceError.unavailable
    }
    return AuthSession(accessToken: accessToken, authUserID: authUserID)
  }

  static func clearStaleRecoveryStateWithoutSession(
    storage: KeychainAuthLocalStorage
  ) throws {
    // A recovery-purpose binding cannot outlive its session. The PKCE-bound
    // recovery intent can: a cold-start callback may already be queued while
    // bootstrap confirms that no prior session exists.
    try storage.clearRecoveryPurposeMarker()
  }
}
