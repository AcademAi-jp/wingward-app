import XCTest
import Security
@testable import Wingward

final class ConfigurationSecurityTests: XCTestCase {
  func testCheckedInInfoPlistHasNoATSException() throws {
    let infoURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Wingward/Info.plist")
    let data = try Data(contentsOf: infoURL)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    let dictionary = try XCTUnwrap(plist as? [String: Any])
    XCTAssertNil(dictionary["NSAppTransportSecurity"])
    XCTAssertNotNil(dictionary["SUPABASE_PUBLISHABLE_KEY"])
    XCTAssertNil(dictionary["SUPABASE_ANON_KEY"])
  }

  func testAppSourcesDoNotUseUserDefaultsPersistence() throws {
    let appDirectory = iosDirectory().appendingPathComponent("Wingward")
    let fileManager = FileManager.default
    let recursiveSwiftFiles = fileManager.enumerator(
      at: appDirectory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: []
    )?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    let directSwiftFiles = try fileManager.contentsOfDirectory(
      at: appDirectory.deletingLastPathComponent(),
      includingPropertiesForKeys: [.isRegularFileKey],
      options: []
    ).filter { $0.pathExtension == "swift" }
    let sourceFiles = (recursiveSwiftFiles + directSwiftFiles).sorted { $0.path < $1.path }

    XCTAssertFalse(sourceFiles.isEmpty)
    for file in sourceFiles {
      let source = try String(contentsOf: file)
      XCTAssertFalse(source.contains("UserDefaults"), file.path)
    }
  }

  func testSupabaseAuthOptionsPreserveSecurityWiring() throws {
    let source = try String(
      contentsOf: iosDirectory().appendingPathComponent("Wingward/SupabaseAuthService.swift")
    )
    for token in [
      "auth: .init(\n        storage: storage",
      "storageKey: KeychainAuthLocalStorage.storageKey",
      "flowType: .pkce",
      "try await Self.performSignOut(",
      "try await client.auth.signOut()",
    ] {
      XCTAssertEqual(source.components(separatedBy: token).count - 1, 1, token)
    }
  }

  func testAuthPurposeGatesRemainWiredAtEveryInstanceBoundary() throws {
    let source = try String(
      contentsOf: iosDirectory().appendingPathComponent("Wingward/SupabaseAuthService.swift")
    )

    XCTAssertEqual(
      source.components(separatedBy: "try await requireOrdinaryAuthPurpose()").count - 1,
      3,
      "sign-up, sign-in, and ordinary callbacks must keep their instance purpose gates"
    )
    XCTAssertEqual(
      source.components(separatedBy: "try await requireOrdinaryAuthPurpose(activeSession: session)").count - 1,
      1,
      "ordinary authentication completion must keep its instance purpose gate"
    )
  }

  func testInstanceCurrentSessionRestoresPasswordRecoveryPurposeFromSDKStorage() async throws {
    let identity = recoveryIdentity()
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.instance-current-session.\(UUID().uuidString)"
    )
    let fixture = try storedSupabaseSession(for: identity)
    LocalAuthURLProtocol.install(responseData: fixture.userData)
    defer {
      LocalAuthURLProtocol.reset()
      try? storage.remove(key: KeychainAuthLocalStorage.storageKey)
      try? storage.clearRecoveryPurposeMarker()
    }

    try storage.store(
      key: KeychainAuthLocalStorage.storageKey,
      value: fixture.sessionData
    )
    try storage.storeRecoveryPurpose(for: identity)

    let networkConfiguration = URLSessionConfiguration.ephemeral
    networkConfiguration.protocolClasses = [LocalAuthURLProtocol.self]
    let service = SupabaseAuthService(
      configuration: try XCTUnwrap(AppConfiguration.load(values: validValues()).value),
      storage: storage,
      networkSession: URLSession(configuration: networkConfiguration)
    )

    let restored = try await service.currentSession()

    XCTAssertEqual(restored?.accessToken, fixture.accessToken)
    XCTAssertEqual(restored?.purpose, .passwordRecovery)
    XCTAssertEqual(LocalAuthURLProtocol.requestCount, 1)
    XCTAssertEqual(LocalAuthURLProtocol.requestPaths, ["/auth/v1/user"])
  }

  func testInstanceCurrentSessionFailsClosedForMismatchedRecoveryBinding() async throws {
    let boundIdentity = recoveryIdentity()
    let sessionIdentity = recoveryIdentity(
      userID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
      sessionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    )
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.instance-current-session-mismatch.\(UUID().uuidString)"
    )
    let fixture = try storedSupabaseSession(for: sessionIdentity)
    LocalAuthURLProtocol.install(responseData: fixture.userData)
    defer {
      LocalAuthURLProtocol.reset()
      try? storage.remove(key: KeychainAuthLocalStorage.storageKey)
      try? storage.clearRecoveryPurposeMarker()
    }

    try storage.store(
      key: KeychainAuthLocalStorage.storageKey,
      value: fixture.sessionData
    )
    try storage.storeRecoveryPurpose(for: boundIdentity)

    let networkConfiguration = URLSessionConfiguration.ephemeral
    networkConfiguration.protocolClasses = [LocalAuthURLProtocol.self]
    let service = SupabaseAuthService(
      configuration: try XCTUnwrap(AppConfiguration.load(values: validValues()).value),
      storage: storage,
      networkSession: URLSession(configuration: networkConfiguration)
    )

    let restored = try await service.currentSession()

    XCTAssertNil(restored)
    XCTAssertNil(try storage.retrieve(key: KeychainAuthLocalStorage.storageKey))
    XCTAssertFalse(try storage.hasRecoveryPurposeBinding())
  }

  func testPasswordRecoveryUsesPurposeSpecificPKCEWiring() throws {
    let contracts = try String(
      contentsOf: iosDirectory().appendingPathComponent("Wingward/AuthContracts.swift")
    )
    let service = try String(
      contentsOf: iosDirectory().appendingPathComponent("Wingward/SupabaseAuthService.swift")
    )

    XCTAssertEqual(
      contracts.components(separatedBy: "wingward://login-callback/").count - 1,
      2
    )
    XCTAssertTrue(contracts.contains("wingward://login-callback/recovery"))
    XCTAssertTrue(service.contains("client.auth.resetPasswordForEmail(email, redirectTo: redirectTo)"))
    XCTAssertTrue(service.contains("client.auth.update(user: UserAttributes(password: password))"))
    XCTAssertTrue(service.contains("CallbackURLPolicy.hasPKCECode(url)"))
    XCTAssertTrue(service.contains("performRecoveryExchange("))
    XCTAssertTrue(service.contains("performPasswordUpdate("))
    XCTAssertTrue(service.contains("redirectTo == CallbackURLPolicy.recoveryCallbackURL"))
  }

  func testServiceRejectsRecoveryCallbackWithoutPKCEBeforeWritingBinding() async throws {
    let serviceIdentifier = "com.wingward.tests.callback.\(UUID().uuidString)"
    let storage = KeychainAuthLocalStorage(service: serviceIdentifier)
    let service = SupabaseAuthService(
      configuration: try XCTUnwrap(AppConfiguration.load(values: validValues()).value),
      storage: storage
    )
    defer { try? storage.clearRecoveryPurposeMarker() }

    do {
      _ = try await service.handleCallback(CallbackURLPolicy.recoveryCallbackURL)
      XCTFail("A recovery callback without a PKCE code must be rejected")
    } catch let error as AuthServiceError {
      XCTAssertEqual(error, .callbackIncomplete)
    }

    XCTAssertFalse(try storage.hasRecoveryPurposeBinding())
  }

  func testServiceRejectsNonRecoveryResetRedirect() async throws {
    let serviceIdentifier = "com.wingward.tests.reset.\(UUID().uuidString)"
    let service = SupabaseAuthService(
      configuration: try XCTUnwrap(AppConfiguration.load(values: validValues()).value),
      storage: KeychainAuthLocalStorage(service: serviceIdentifier)
    )

    do {
      try await service.resetPasswordForEmail(
        email: "person@example.test",
        redirectTo: CallbackURLPolicy.callbackURL
      )
      XCTFail("Password reset must use the recovery callback URL")
    } catch let error as AuthServiceError {
      XCTAssertEqual(error, .callbackIncomplete)
    }
  }

  func testKeychainStoreUsesAndRepairsThisDeviceOnlyAccessibility() throws {
    let service = "com.wingward.tests.\(UUID().uuidString)"
    let key = UUID().uuidString
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    defer { SecItemDelete(query as CFDictionary) }

    let storage = KeychainAuthLocalStorage(service: service)
    try storage.store(key: key, value: Data([0x01]))

    var attributesQuery = query
    attributesQuery[kSecReturnAttributes as String] = true
    attributesQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    XCTAssertEqual(
      SecItemCopyMatching(attributesQuery as CFDictionary, &result),
      errSecSuccess
    )
    let attributes = try XCTUnwrap(result as? [String: Any])
    XCTAssertEqual(
      attributes[kSecAttrAccessible as String] as? String,
      KeychainAuthLocalStorage.accessibility as String
    )

    XCTAssertEqual(
      SecItemUpdate(
        query as CFDictionary,
        [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked] as CFDictionary
      ),
      errSecSuccess
    )
    try storage.store(key: key, value: Data([0x02]))

    result = nil
    XCTAssertEqual(
      SecItemCopyMatching(attributesQuery as CFDictionary, &result),
      errSecSuccess
    )
    let repairedAttributes = try XCTUnwrap(result as? [String: Any])
    XCTAssertEqual(
      repairedAttributes[kSecAttrAccessible as String] as? String,
      KeychainAuthLocalStorage.accessibility as String
    )
  }

  func testRecoveryPurposeBindingUsesThisDeviceOnlyStorageAndCanBeCleared() throws {
    let service = "com.wingward.tests.recovery.\(UUID().uuidString)"
    let storage = KeychainAuthLocalStorage(service: service)
    let markerKey = KeychainAuthLocalStorage.recoveryPurposeKey
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: markerKey,
    ]
    defer { SecItemDelete(query as CFDictionary) }

    let identity = recoveryIdentity()
    try storage.storeRecoveryPurpose(for: identity)
    XCTAssertTrue(try storage.hasRecoveryPurposeBinding())
    XCTAssertTrue(try storage.recoveryPurposeMatches(identity: identity))
    XCTAssertFalse(
      try storage.recoveryPurposeMatches(
        identity: recoveryIdentity(sessionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
      )
    )

    var attributesQuery = query
    attributesQuery[kSecReturnAttributes as String] = true
    attributesQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    XCTAssertEqual(
      SecItemCopyMatching(attributesQuery as CFDictionary, &result),
      errSecSuccess
    )
    let attributes = try XCTUnwrap(result as? [String: Any])
    XCTAssertEqual(
      attributes[kSecAttrAccessible as String] as? String,
      KeychainAuthLocalStorage.accessibility as String
    )

    try storage.clearRecoveryPurposeMarker()
    XCTAssertFalse(try storage.hasRecoveryPurposeBinding())
  }

  func testSessionPurposeSurvivesAccessTokenRotationWithinSameSession() throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.recovery-purpose.\(UUID().uuidString)"
    )
    defer { try? storage.clearRecoveryPurposeMarker() }

    let identity = recoveryIdentity()
    try storage.storeRecoveryPurpose(for: identity)
    XCTAssertEqual(
      try SupabaseAuthService.sessionPurpose(
        identity: identity,
        storage: storage
      ),
      .passwordRecovery
    )
    // The access token is deliberately absent from the binding API. A rotated
    // token with the same verified user/session identity keeps recovery scope.
    XCTAssertTrue(try storage.recoveryPurposeMatches(identity: identity))
  }

  func testMismatchedRecoverySessionDropsLocalSessionInsteadOfBecomingOrdinary() async throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.mismatched-purpose.\(UUID().uuidString)"
    )
    defer {
      try? storage.remove(key: KeychainAuthLocalStorage.storageKey)
      try? storage.clearRecoveryPurposeMarker()
    }
    try storage.store(key: KeychainAuthLocalStorage.storageKey, value: Data([0x01]))
    try storage.storeRecoveryPurpose(for: recoveryIdentity())
    var clearedInMemory = false

    let resolved = try await SupabaseAuthService.resolveCurrentSession(
      context: recoveryContext(
        accessToken: "rotated-but-different-session",
        sessionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
      ),
      storage: storage,
      clearInMemorySession: { clearedInMemory = true }
    )

    XCTAssertNil(resolved)
    XCTAssertTrue(clearedInMemory)
    XCTAssertNil(try storage.retrieve(key: KeychainAuthLocalStorage.storageKey))
    XCTAssertFalse(try storage.hasRecoveryPurposeBinding())
  }

  func testRecoveryIntentAcceptsOnlyRecoveryPathWithMatchingPKCEVerifier() throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.recovery-intent.\(UUID().uuidString)"
    )
    defer {
      try? storage.remove(key: KeychainAuthLocalStorage.pkceCodeVerifierKey)
      try? storage.clearRecoveryIntent()
    }
    try storage.store(
      key: KeychainAuthLocalStorage.pkceCodeVerifierKey,
      value: Data("trusted-recovery-verifier".utf8)
    )
    try storage.storeRecoveryIntentForCurrentPKCEVerifier()

    XCTAssertEqual(
      try SupabaseAuthService.trustedCallbackPurpose(
        callbackPurpose: .recovery,
        storage: storage
      ),
      .passwordRecovery
    )
    XCTAssertThrowsError(
      try SupabaseAuthService.trustedCallbackPurpose(
        callbackPurpose: .normal,
        storage: storage
      )
    ) { error in
      XCTAssertEqual(error as? AuthServiceError, .callbackIncomplete)
    }
  }

  func testRecoveryPathWithoutMatchingPKCEIntentIsRejected() throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.untrusted-recovery.\(UUID().uuidString)"
    )
    defer {
      try? storage.remove(key: KeychainAuthLocalStorage.pkceCodeVerifierKey)
      try? storage.clearRecoveryIntent()
    }

    XCTAssertThrowsError(
      try SupabaseAuthService.trustedCallbackPurpose(
        callbackPurpose: .recovery,
        storage: storage
      )
    ) { error in
      XCTAssertEqual(error as? AuthServiceError, .callbackIncomplete)
    }

    try storage.store(
      key: KeychainAuthLocalStorage.pkceCodeVerifierKey,
      value: Data("recovery-verifier".utf8)
    )
    try storage.storeRecoveryIntentForCurrentPKCEVerifier()
    try storage.store(
      key: KeychainAuthLocalStorage.pkceCodeVerifierKey,
      value: Data("newer-ordinary-verifier".utf8)
    )
    XCTAssertThrowsError(
      try SupabaseAuthService.trustedCallbackPurpose(
        callbackPurpose: .recovery,
        storage: storage
      )
    )
    XCTAssertFalse(try storage.hasRecoveryIntent())
  }

  func testFailedRecoveryExchangeDoesNotCreateOrReplaceBinding() async throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.failed-recovery.\(UUID().uuidString)"
    )
    defer {
      try? storage.remove(key: KeychainAuthLocalStorage.storageKey)
      try? storage.remove(key: KeychainAuthLocalStorage.pkceCodeVerifierKey)
      try? storage.clearRecoveryIntent()
      try? storage.clearRecoveryPurposeMarker()
    }
    try storage.store(key: KeychainAuthLocalStorage.storageKey, value: Data([0x01]))
    try storage.store(
      key: KeychainAuthLocalStorage.pkceCodeVerifierKey,
      value: Data("failed-recovery-verifier".utf8)
    )
    try storage.storeRecoveryIntentForCurrentPKCEVerifier()
    var clearedInMemory = false

    do {
      _ = try await SupabaseAuthService.performRecoveryExchange(
        storage: storage,
        exchange: { throw AuthServiceError.unavailable },
        persistRecoveryPurpose: { try storage.storeRecoveryPurpose(for: $0) },
        clearInMemorySession: { clearedInMemory = true }
      )
      XCTFail("A failed exchange must not create recovery authority")
    } catch let error as AuthServiceError {
      XCTAssertEqual(error, .unavailable)
    }
    XCTAssertFalse(try storage.hasRecoveryPurposeBinding())
    XCTAssertFalse(try storage.hasRecoveryIntent())
    XCTAssertNil(try storage.retrieve(key: KeychainAuthLocalStorage.pkceCodeVerifierKey))
    XCTAssertNil(try storage.retrieve(key: KeychainAuthLocalStorage.storageKey))
    XCTAssertTrue(clearedInMemory)
  }

  func testSuccessfulRecoveryExchangeBindsOnlyAfterExchangeSucceeds() async throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.successful-recovery.\(UUID().uuidString)"
    )
    defer {
      try? storage.clearRecoveryIntent()
      try? storage.clearRecoveryPurposeMarker()
    }
    try storage.store(
      key: KeychainAuthLocalStorage.pkceCodeVerifierKey,
      value: Data("recovery-verifier".utf8)
    )
    try storage.storeRecoveryIntentForCurrentPKCEVerifier()
    let context = recoveryContext(accessToken: "exchanged-recovery-session")

    let session = try await SupabaseAuthService.performRecoveryExchange(
      storage: storage,
      exchange: {
        XCTAssertFalse(try storage.hasRecoveryPurposeBinding())
        return context
      },
      persistRecoveryPurpose: { try storage.storeRecoveryPurpose(for: $0) },
      clearInMemorySession: { XCTFail("Successful exchange must not clear the session") }
    )

    XCTAssertEqual(session.purpose, .passwordRecovery)
    XCTAssertEqual(session.accessToken, "exchanged-recovery-session")
    XCTAssertTrue(try storage.recoveryPurposeMatches(identity: context.identity))
    XCTAssertFalse(try storage.hasRecoveryIntent())
    XCTAssertNil(try storage.retrieve(key: KeychainAuthLocalStorage.pkceCodeVerifierKey))
  }

  func testInterruptedRecoveryBindingNeverBecomesOrdinaryAuthentication() async throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.interrupted-recovery.\(UUID().uuidString)"
    )
    defer {
      try? storage.remove(key: KeychainAuthLocalStorage.storageKey)
      try? storage.remove(key: KeychainAuthLocalStorage.pkceCodeVerifierKey)
      try? storage.clearRecoveryIntent()
      try? storage.clearRecoveryPurposeMarker()
    }
    try storage.store(key: KeychainAuthLocalStorage.storageKey, value: Data([0x01]))
    try storage.store(
      key: KeychainAuthLocalStorage.pkceCodeVerifierKey,
      value: Data("recovery-verifier".utf8)
    )
    try storage.storeRecoveryIntentForCurrentPKCEVerifier()
    var clearedInMemory = false

    let session = try await SupabaseAuthService.resolveUnboundCurrentSession(
      accessToken: "sdk-persisted-before-purpose-binding",
      storage: storage,
      clearInMemorySession: { clearedInMemory = true }
    )

    XCTAssertNil(session)
    XCTAssertTrue(clearedInMemory)
    XCTAssertNil(try storage.retrieve(key: KeychainAuthLocalStorage.storageKey))
    XCTAssertFalse(try storage.hasRecoveryIntent())
  }

  func testMissingSessionPreservesRecoveryIntentForQueuedColdStartCallback() throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.cold-start-recovery.\(UUID().uuidString)"
    )
    defer {
      try? storage.remove(key: KeychainAuthLocalStorage.pkceCodeVerifierKey)
      try? storage.clearRecoveryIntent()
      try? storage.clearRecoveryPurposeMarker()
    }
    try storage.store(
      key: KeychainAuthLocalStorage.pkceCodeVerifierKey,
      value: Data("cold-start-recovery-verifier".utf8)
    )
    try storage.storeRecoveryIntentForCurrentPKCEVerifier()
    try storage.storeRecoveryPurpose(for: recoveryIdentity())

    try SupabaseAuthService.clearStaleRecoveryStateWithoutSession(storage: storage)

    XCTAssertFalse(try storage.hasRecoveryPurposeBinding())
    XCTAssertTrue(try storage.hasRecoveryIntent())
    XCTAssertEqual(
      try SupabaseAuthService.trustedCallbackPurpose(
        callbackPurpose: .recovery,
        storage: storage
      ),
      .passwordRecovery
    )
  }

  func testRecoveryPurposeBindingFailureClearsPersistedSDKSession() async throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.binding-failure.\(UUID().uuidString)"
    )
    defer {
      try? storage.remove(key: KeychainAuthLocalStorage.storageKey)
      try? storage.clearRecoveryIntent()
      try? storage.clearRecoveryPurposeMarker()
    }
    try storage.store(key: KeychainAuthLocalStorage.storageKey, value: Data([0x01]))
    var clearedInMemory = false

    do {
      _ = try await SupabaseAuthService.performRecoveryExchange(
        storage: storage,
        exchange: { self.recoveryContext(accessToken: "persisted-by-sdk") },
        persistRecoveryPurpose: { _ in throw AuthServiceError.unavailable },
        clearInMemorySession: { clearedInMemory = true }
      )
      XCTFail("A purpose-binding failure must reject the persisted SDK session")
    } catch let error as AuthServiceError {
      XCTAssertEqual(error, .unavailable)
    }

    XCTAssertTrue(clearedInMemory)
    XCTAssertNil(try storage.retrieve(key: KeychainAuthLocalStorage.storageKey))
    XCTAssertFalse(try storage.hasRecoveryPurposeBinding())
  }

  func testOrdinaryAuthenticationGateRejectsMatchingRecoverySession() async throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.ordinary-gate-match.\(UUID().uuidString)"
    )
    defer { try? storage.clearRecoveryPurposeMarker() }
    let identity = recoveryIdentity()
    try storage.storeRecoveryPurpose(for: identity)
    var clearedInMemory = false

    do {
      try await SupabaseAuthService.requireOrdinaryAuthPurpose(
        identity: identity,
        storage: storage,
        clearInMemorySession: { clearedInMemory = true }
      )
      XCTFail("A recovery-scoped session must not pass ordinary authentication")
    } catch let error as AuthServiceError {
      XCTAssertEqual(error, .callbackIncomplete)
    }

    XCTAssertFalse(clearedInMemory)
    XCTAssertTrue(try storage.recoveryPurposeMatches(identity: identity))
  }

  func testOrdinaryAuthenticationGateClearsMismatchedRecoverySession() async throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.ordinary-gate-mismatch.\(UUID().uuidString)"
    )
    defer {
      try? storage.remove(key: KeychainAuthLocalStorage.storageKey)
      try? storage.clearRecoveryPurposeMarker()
    }
    try storage.store(key: KeychainAuthLocalStorage.storageKey, value: Data([0x01]))
    try storage.storeRecoveryPurpose(for: recoveryIdentity())
    var clearedInMemory = false

    do {
      try await SupabaseAuthService.requireOrdinaryAuthPurpose(
        identity: recoveryIdentity(
          sessionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        ),
        storage: storage,
        clearInMemorySession: { clearedInMemory = true }
      )
      XCTFail("A mismatched recovery binding must fail closed")
    } catch let error as AuthServiceError {
      XCTAssertEqual(error, .unavailable)
    }

    XCTAssertTrue(clearedInMemory)
    XCTAssertNil(try storage.retrieve(key: KeychainAuthLocalStorage.storageKey))
    XCTAssertFalse(try storage.hasRecoveryPurposeBinding())
  }

  func testOrdinaryAuthenticationGateInstanceClearsMarkerWhenSessionIsMissing() async throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.ordinary-gate-instance.\(UUID().uuidString)"
    )
    defer {
      try? storage.remove(key: KeychainAuthLocalStorage.pkceCodeVerifierKey)
      try? storage.clearRecoveryIntent()
      try? storage.clearRecoveryPurposeMarker()
    }
    try storage.storeRecoveryPurpose(for: recoveryIdentity())

    let service = SupabaseAuthService(
      configuration: try XCTUnwrap(AppConfiguration.load(values: validValues()).value),
      storage: storage
    )

    try await service.requireOrdinaryAuthPurpose()

    XCTAssertFalse(try storage.hasRecoveryPurposeBinding())
  }

  func testSuccessfulOrdinaryAuthenticationClearsStaleRecoveryIntent() async throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.ordinary-finish.\(UUID().uuidString)"
    )
    defer {
      try? storage.remove(key: KeychainAuthLocalStorage.pkceCodeVerifierKey)
      try? storage.clearRecoveryIntent()
    }
    try storage.store(
      key: KeychainAuthLocalStorage.pkceCodeVerifierKey,
      value: Data("stale-recovery-verifier".utf8)
    )
    try storage.storeRecoveryIntentForCurrentPKCEVerifier()

    let session = try await SupabaseAuthService.finishOrdinaryAuthentication(
      accessToken: "ordinary-session",
      storage: storage,
      clearInMemorySession: { XCTFail("A successful ordinary session must remain active") }
    )

    XCTAssertEqual(session.accessToken, "ordinary-session")
    XCTAssertEqual(session.purpose, .ordinary)
    XCTAssertFalse(try storage.hasRecoveryIntent())
    XCTAssertNil(try storage.retrieve(key: KeychainAuthLocalStorage.pkceCodeVerifierKey))
  }

  func testVerifierWithoutRecoveryIntentCannotGrantRecoveryPurpose() throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.verifier-without-intent.\(UUID().uuidString)"
    )
    defer { try? storage.remove(key: KeychainAuthLocalStorage.pkceCodeVerifierKey) }
    try storage.store(
      key: KeychainAuthLocalStorage.pkceCodeVerifierKey,
      value: Data("orphaned-verifier".utf8)
    )

    XCTAssertEqual(
      try SupabaseAuthService.trustedCallbackPurpose(
        callbackPurpose: .normal,
        storage: storage
      ),
      .ordinary
    )
    XCTAssertThrowsError(
      try SupabaseAuthService.trustedCallbackPurpose(
        callbackPurpose: .recovery,
        storage: storage
      )
    ) { error in
      XCTAssertEqual(error as? AuthServiceError, .callbackIncomplete)
    }
  }

  func testPasswordUpdateRequiresMatchingRecoverySession() async throws {
    let storage = KeychainAuthLocalStorage(
      service: "com.wingward.tests.password-update.\(UUID().uuidString)"
    )
    defer {
      try? storage.remove(key: KeychainAuthLocalStorage.storageKey)
      try? storage.clearRecoveryPurposeMarker()
    }
    var updateCount = 0
    var clearCount = 0

    do {
      try await SupabaseAuthService.performPasswordUpdate(
        storage: storage,
        currentSession: { recoveryContext(accessToken: "ordinary-session") },
        clearInMemorySession: { clearCount += 1 },
        update: { updateCount += 1 }
      )
      XCTFail("An ordinary session must not update the password")
    } catch let error as AuthServiceError {
      XCTAssertEqual(error, .unavailable)
    }
    XCTAssertEqual(updateCount, 0)
    XCTAssertEqual(clearCount, 1)

    let recovery = recoveryContext(accessToken: "recovery-session")
    try storage.storeRecoveryPurpose(for: recovery.identity)
    try storage.store(key: KeychainAuthLocalStorage.storageKey, value: Data([0x01]))
    do {
      try await SupabaseAuthService.performPasswordUpdate(
        storage: storage,
        currentSession: {
          recoveryContext(
            accessToken: "different-session",
            sessionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
          )
        },
        clearInMemorySession: { clearCount += 1 },
        update: { updateCount += 1 }
      )
      XCTFail("A stale binding must not update the password")
    } catch let error as AuthServiceError {
      XCTAssertEqual(error, .unavailable)
    }
    XCTAssertEqual(updateCount, 0)
    XCTAssertEqual(clearCount, 2)
    XCTAssertNil(try storage.retrieve(key: KeychainAuthLocalStorage.storageKey))
    XCTAssertFalse(try storage.hasRecoveryPurposeBinding())

    try storage.storeRecoveryPurpose(for: recovery.identity)
    try await SupabaseAuthService.performPasswordUpdate(
      storage: storage,
      currentSession: {
        // Simulates an access-token refresh: the token changes but the verified
        // user/session identity stays stable.
        recoveryContext(accessToken: "rotated-recovery-session")
      },
      clearInMemorySession: { clearCount += 1 },
      update: { updateCount += 1 }
    )
    XCTAssertEqual(updateCount, 1)
    XCTAssertEqual(clearCount, 2)
  }

  func testSupabaseSignOutRemovesLocalSessionAfterRemoteFailure() async throws {
    let service = "com.wingward.tests.signout.\(UUID().uuidString)"
    let storage = KeychainAuthLocalStorage(service: service)
    let sessionKey = KeychainAuthLocalStorage.storageKey
    defer { try? storage.remove(key: sessionKey) }

    try storage.store(key: sessionKey, value: Data([0x01]))

    do {
      try await SupabaseAuthService.performSignOut(
        remoteSignOut: { throw AuthServiceError.unavailable },
        removeLocalSession: { try storage.remove(key: sessionKey) }
      )
      XCTFail("A remote sign-out failure must remain unavailable")
    } catch let error as AuthServiceError {
      XCTAssertEqual(error, .unavailable)
    }

    XCTAssertNil(try storage.retrieve(key: sessionKey))
  }

  func testInstanceSignOutClearsAllLocalAuthAndRecoveryState() async throws {
    let serviceIdentifier = "com.wingward.tests.instance-signout.\(UUID().uuidString)"
    let storage = KeychainAuthLocalStorage(service: serviceIdentifier)
    let keys = [
      KeychainAuthLocalStorage.storageKey,
      KeychainAuthLocalStorage.recoveryIntentKey,
      KeychainAuthLocalStorage.recoveryPurposeKey,
      KeychainAuthLocalStorage.pkceCodeVerifierKey,
    ]
    defer {
      for key in keys {
        try? storage.remove(key: key)
      }
    }

    try storage.store(key: KeychainAuthLocalStorage.storageKey, value: Data([0x01]))
    try storage.store(
      key: KeychainAuthLocalStorage.pkceCodeVerifierKey,
      value: Data("sign-out-verifier".utf8)
    )
    try storage.storeRecoveryIntentForCurrentPKCEVerifier()
    try storage.storeRecoveryPurpose(for: recoveryIdentity())

    let service = SupabaseAuthService(
      configuration: try XCTUnwrap(AppConfiguration.load(values: validValues()).value),
      storage: storage
    )

    do {
      try await service.signOut()
    } catch let error as AuthServiceError {
      XCTAssertEqual(error, .unavailable)
    }

    for key in keys {
      XCTAssertNil(try storage.retrieve(key: key), key)
    }
  }

  func testLiveProfileAPIDefaultSessionIsEphemeralAndDoesNotCache() throws {
    let api = LiveProfileAPI(baseURL: URL(string: "https://api.wingward.test")!)
    let configuration = api.urlSession.configuration

    XCTAssertNil(configuration.urlCache)
    XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertNil(configuration.httpCookieStorage)
    XCTAssertNil(configuration.urlCredentialStorage)
  }

  func testDateOfBirthPickersUseUTCCalendarAndTimeZone() throws {
    let source = try String(contentsOf: iosDirectory().appendingPathComponent("Views.swift"))
    let lines = source.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    let utcCalendar = #".environment(\.calendar, BirthDateValidator.utcGregorianCalendar)"#
    let utcTimeZone = #".environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)"#
    let pairCount = zip(lines, lines.dropFirst()).filter { calendar, timeZone in
      calendar == utcCalendar && timeZone == utcTimeZone
    }.count

    XCTAssertEqual(source.components(separatedBy: "DatePicker(").count - 1, 2)
    XCTAssertEqual(pairCount, 2)
  }

  func testDebugBootstrapIsDebugOnlyAndReleaseConfigurationsDoNotEnableDEBUG() throws {
    let appSource = try String(
      contentsOf: iosDirectory().appendingPathComponent("Wingward/WingwardApp.swift")
    )
    for token in ["DebugBootstrap", "DebugQuizBootstrap"] {
      XCTAssertEqual(appSource.components(separatedBy: token).count - 1, 2, token)
      let declarationSnippet = "#if DEBUG\n  private enum \(token)"
      let declaration = try XCTUnwrap(appSource.range(of: declarationSnippet), token)
      let use = try XCTUnwrap(
        appSource.range(of: token, range: appSource.startIndex..<declaration.lowerBound),
        token
      )
      let beforeUse = String(appSource[..<use.lowerBound])
      let lastDebugFence = try XCTUnwrap(
        beforeUse.range(of: "#if DEBUG", options: .backwards),
        token
      )
      let useBranch = String(beforeUse[lastDebugFence.upperBound...])
      XCTAssertFalse(useBranch.contains("#else"), token)
      XCTAssertFalse(useBranch.contains("#elseif"), token)
      XCTAssertFalse(useBranch.contains("#endif"), token)
      XCTAssertTrue(String(appSource[use.upperBound...]).contains("#endif"), token)
      XCTAssertTrue(String(appSource[declaration.upperBound...]).contains("#endif"), token)
    }

    let project = try String(
      contentsOf: iosDirectory().appendingPathComponent("Wingward.xcodeproj/project.pbxproj")
    )
    let configurationSection = try XCTUnwrap(xcBuildConfigurationSection(in: project))
    let releaseBlocks = configurationSection
      .components(separatedBy: "\n\t\t};")
      .filter { $0.contains("/* Release */ = {") }
    let rawReleaseStartCount = configurationSection
      .components(separatedBy: "/* Release */ = {").count - 1
    XCTAssertEqual(releaseBlocks.count, rawReleaseStartCount)
    XCTAssertFalse(releaseBlocks.isEmpty)

    let debugAssignment = try NSRegularExpression(
      pattern: #"SWIFT_ACTIVE_COMPILATION_CONDITIONS\s*=\s*[^;]*\bDEBUG\b[^;]*;"#
    )
    for block in releaseBlocks {
      let range = NSRange(block.startIndex..<block.endIndex, in: block)
      XCTAssertNil(
        debugAssignment.firstMatch(in: block, range: range),
        "Release SWIFT_ACTIVE_COMPILATION_CONDITIONS must not contain DEBUG"
      )
    }
  }

  #if DEBUG
    func testLocalAuthResetRequiresTheValidationBundleAndExactLaunchArgument() throws {
      let bundleID = WingwardLocalAuthReset.validationBundleIdentifier
      let resetArgument = WingwardLocalAuthReset.launchArgument
      var removed: [String] = []

      XCTAssertFalse(
        WingwardLocalAuthReset.isRequested(
          bundleIdentifier: "com.wingward.app",
          arguments: [resetArgument]
        )
      )
      XCTAssertFalse(
        WingwardLocalAuthReset.isRequested(
          bundleIdentifier: bundleID,
          arguments: ["Wingward"]
        )
      )
      XCTAssertTrue(
        WingwardLocalAuthReset.isRequested(
          bundleIdentifier: bundleID,
          arguments: ["Wingward", resetArgument]
        )
      )

      XCTAssertTrue(
        try WingwardLocalAuthReset.runIfRequested(
          bundleIdentifier: bundleID,
          arguments: ["Wingward", resetArgument],
          remove: { removed.append($0) }
        )
      )
      XCTAssertEqual(removed, WingwardLocalAuthReset.keychainKeys)
    }

    func testLocalAuthResetFailsClosedWithoutAttemptingLaterKeys() {
      enum ResetFailure: Error { case injected }
      var attempted: [String] = []

      XCTAssertThrowsError(
        try WingwardLocalAuthReset.runIfRequested(
          bundleIdentifier: WingwardLocalAuthReset.validationBundleIdentifier,
          arguments: [WingwardLocalAuthReset.launchArgument],
          remove: { key in
            attempted.append(key)
            if key == KeychainAuthLocalStorage.pkceCodeVerifierKey {
              throw ResetFailure.injected
            }
          }
        )
      )
      XCTAssertEqual(
        attempted,
        [
          KeychainAuthLocalStorage.storageKey,
          KeychainAuthLocalStorage.pkceCodeVerifierKey,
        ]
      )
    }

    func testLocalAuthResetDoesNotRunForNormalValidationLaunch() throws {
      var called = false
      XCTAssertFalse(
        try WingwardLocalAuthReset.runIfRequested(
          bundleIdentifier: WingwardLocalAuthReset.validationBundleIdentifier,
          arguments: ["Wingward"],
          remove: { _ in called = true }
        )
      )
      XCTAssertFalse(called)
    }
  #endif

  func testConfigurationRejectsMissingBlankAndCheckedInPlaceholders() {
    let valid = validValues()
    let keys = ["SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY", "API_BASE_URL"]

    for key in keys {
      var missing = valid
      missing.removeValue(forKey: key)
      XCTAssertEqual(
        AppConfiguration.load(values: missing),
        .failure(.missingOrPlaceholder),
        "Missing \(key) must fail closed"
      )

      var blank = valid
      blank[key] = "   "
      XCTAssertEqual(
        AppConfiguration.load(values: blank),
        .failure(.missingOrPlaceholder),
        "Blank \(key) must fail closed"
      )
    }

    let placeholders: [(String, String, String)] = [
      ("Shared Supabase URL", "SUPABASE_URL", "https://placeholder.invalid"),
      ("Shared API URL", "API_BASE_URL", "https://placeholder.invalid"),
      ("Shared publishable key", "SUPABASE_PUBLISHABLE_KEY", "PLACEHOLDER_PUBLISHABLE_KEY"),
      ("Local Supabase URL", "SUPABASE_URL", "https://YOUR_PROJECT_REF.supabase.co"),
      ("Local publishable key", "SUPABASE_PUBLISHABLE_KEY", "REPLACE_WITH_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
      ("Local API URL", "API_BASE_URL", "https://YOUR_API_HOST"),
    ]

    for (label, key, placeholder) in placeholders {
      var values = valid
      values[key] = placeholder
      XCTAssertEqual(
        AppConfiguration.load(values: values),
        .failure(.missingOrPlaceholder),
        "Checked-in placeholder family \(label) must fail closed"
      )
    }
  }

  func testConfigurationAcceptsRealLookingHttpsValues() throws {
    let result = AppConfiguration.load(values: validValues())
    guard case let .success(configuration) = result else {
      XCTFail("Non-placeholder HTTPS configuration should be accepted")
      return
    }
    XCTAssertEqual(configuration.supabaseURL.absoluteString, "https://supabase.wingward.test")
    XCTAssertEqual(configuration.apiBaseURL.absoluteString, "https://api.wingward.test")
    XCTAssertEqual(configuration.publishableKey, "public-key-fixture-123")
  }

  func testConfigurationRejectsInvalidURLFormsForBothEndpoints() {
    let invalidURLs = [
      "http://api.wingward.test",
      "https://user:pw@api.wingward.test",
      "https://",
    ]

    for key in ["SUPABASE_URL", "API_BASE_URL"] {
      for invalidURL in invalidURLs {
        var values = validValues()
        values[key] = invalidURL
        XCTAssertEqual(
          AppConfiguration.load(values: values),
          .failure(.invalidURL),
          "Invalid \(key) value should fail URL validation: \(invalidURL)"
        )
      }
    }
  }

  private func validValues() -> [String: String] {
    [
      "SUPABASE_URL": "https://supabase.wingward.test",
      "SUPABASE_PUBLISHABLE_KEY": "public-key-fixture-123",
      "API_BASE_URL": "https://api.wingward.test",
    ]
  }

  private func recoveryIdentity(
    userID: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
    sessionID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  ) -> RecoverySessionIdentity {
    RecoverySessionIdentity(userID: userID, sessionID: sessionID)
  }

  private func recoveryContext(
    accessToken: String,
    userID: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
    sessionID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  ) -> RecoverySessionContext {
    RecoverySessionContext(
      accessToken: accessToken,
      identity: recoveryIdentity(userID: userID, sessionID: sessionID)
    )
  }

  private func storedSupabaseSession(
    for identity: RecoverySessionIdentity
  ) throws -> StoredSupabaseSessionFixture {
    let expiresAt = Date().addingTimeInterval(3_600)
    let accessToken = accessToken(for: identity, expiresAt: expiresAt)
    let createdAt = "1970-01-01T00:00:00.000Z"
    let storageUser: [String: Any] = [
      "id": identity.userID.uuidString,
      "aud": "authenticated",
      "appMetadata": [:],
      "userMetadata": [:],
      "createdAt": createdAt,
      "updatedAt": createdAt,
      "isAnonymous": false,
    ]
    let apiUser: [String: Any] = [
      "id": identity.userID.uuidString,
      "aud": "authenticated",
      "app_metadata": [:],
      "user_metadata": [:],
      "created_at": createdAt,
      "updated_at": createdAt,
      "is_anonymous": false,
    ]
    let session: [String: Any] = [
      "accessToken": accessToken,
      "tokenType": "bearer",
      "expiresIn": 3_600,
      "expiresAt": expiresAt.timeIntervalSince1970,
      "refreshToken": "refresh-token-fixture",
      "user": storageUser,
    ]
    return StoredSupabaseSessionFixture(
      accessToken: accessToken,
      sessionData: try JSONSerialization.data(withJSONObject: session, options: [.sortedKeys]),
      userData: try JSONSerialization.data(withJSONObject: apiUser, options: [.sortedKeys])
    )
  }

  private func accessToken(
    for identity: RecoverySessionIdentity,
    expiresAt: Date
  ) -> String {
    let header = Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8)
    let payload = Data(
      """
      {"sub":"\(identity.userID.uuidString)","session_id":"\(identity.sessionID.uuidString)","exp":\(Int(expiresAt.timeIntervalSince1970))}
      """.utf8
    )
    return "\(base64URLEncoded(header)).\(base64URLEncoded(payload)).c2lnbmF0dXJl"
  }

  private func base64URLEncoded(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func iosDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func xcBuildConfigurationSection(in project: String) -> String? {
    guard let start = project.range(of: "/* Begin XCBuildConfiguration section */"),
      let end = project.range(
        of: "/* End XCBuildConfiguration section */",
        range: start.upperBound..<project.endIndex
      )
    else {
      return nil
    }
    return String(project[start.upperBound..<end.lowerBound])
  }
}

private struct StoredSupabaseSessionFixture {
  let accessToken: String
  let sessionData: Data
  let userData: Data
}

private final class LocalAuthURLProtocolState: @unchecked Sendable {
  private let lock = NSLock()
  private var responseData = Data()
  private var paths: [String] = []

  func install(responseData: Data) {
    lock.lock()
    defer { lock.unlock() }
    self.responseData = responseData
    paths.removeAll(keepingCapacity: true)
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    responseData = Data()
    paths.removeAll(keepingCapacity: false)
  }

  func response(for request: URLRequest) -> (statusCode: Int, data: Data) {
    lock.lock()
    defer { lock.unlock() }
    let path = request.url?.path ?? ""
    paths.append(path)
    guard path == "/auth/v1/user" else { return (500, Data()) }
    return (200, responseData)
  }

  var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return paths.count
  }

  var requestPaths: [String] {
    lock.lock()
    defer { lock.unlock() }
    return paths
  }
}

private final class LocalAuthURLProtocol: URLProtocol {
  private static let state = LocalAuthURLProtocolState()

  override class func canInit(with _: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let result = Self.state.response(for: request)
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: result.statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !result.data.isEmpty {
      client?.urlProtocol(self, didLoad: result.data)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func install(responseData: Data) {
    state.install(responseData: responseData)
  }

  static func reset() {
    state.reset()
  }

  static var requestCount: Int { state.requestCount }

  static var requestPaths: [String] { state.requestPaths }
}
