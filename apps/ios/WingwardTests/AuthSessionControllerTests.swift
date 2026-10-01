import Foundation
import Supabase
import XCTest
@testable import Wingward

@MainActor
final class AuthSessionControllerTests: XCTestCase {
  private let deletionOwnerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  private let deletionAuthUserID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

  func testBootstrapUsesDeletedReceiptForTheSameAuthIdentityAndThenClearsIt() async {
    let auth = FakeAuthService(
      currentSession: AuthSession(accessToken: "synthetic-token", authUserID: deletionAuthUserID)
    )
    let profile = FakeProfileAPI(profile: UserProfile(id: deletionOwnerID, ageVerified: true))
    let recovery = ScriptedDeletionRecovery(
      outcome: .deleted(ownerProfileID: deletionOwnerID, authUserID: deletionAuthUserID)
    )
    let cleanup = RecordingExternalIdentityCleanup()
    let controller = makeController(
      auth: auth,
      profile: profile,
      cleanup: cleanup,
      deletionRecovery: recovery
    )

    await controller.bootstrap()

    XCTAssertEqual(controller.state, .signedOut)
    XCTAssertEqual(auth.signOutCalls, 1)
    XCTAssertEqual(profile.fetchCalls, 0)
    let cleanedOwners = await cleanup.ownerIDs()
    let clearedOwners = await recovery.clearedOwnerIDs()
    XCTAssertEqual(cleanedOwners, [deletionOwnerID])
    XCTAssertEqual(clearedOwners, [deletionOwnerID])
  }

  func testPendingOrUnavailableDeletionStatusNeverSignsOutTheCurrentUser() async {
    for outcome in [AccountDeletionRecoveryOutcome.pending, .unavailable, .none] {
      let auth = FakeAuthService(
        currentSession: AuthSession(accessToken: "synthetic-token", authUserID: deletionAuthUserID)
      )
      let profile = FakeProfileAPI(profile: UserProfile(id: deletionOwnerID, ageVerified: true))
      let recovery = ScriptedDeletionRecovery(outcome: outcome)
      let controller = makeController(
        auth: auth,
        profile: profile,
        deletionRecovery: recovery
      )

      await controller.bootstrap()

      XCTAssertEqual(controller.state, .authenticated(profile: UserProfile(id: deletionOwnerID, ageVerified: true)))
      XCTAssertEqual(auth.signOutCalls, 0)
      XCTAssertEqual(profile.fetchCalls, 1)
    }
  }

  func testDeletedReceiptForDifferentAuthIdentityCannotClearSession() async {
    let auth = FakeAuthService(
      currentSession: AuthSession(accessToken: "synthetic-token", authUserID: deletionAuthUserID)
    )
    let profile = FakeProfileAPI(profile: UserProfile(id: deletionOwnerID, ageVerified: true))
    let recovery = ScriptedDeletionRecovery(
      outcome: .deleted(ownerProfileID: deletionOwnerID, authUserID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
    )
    let controller = makeController(auth: auth, profile: profile, deletionRecovery: recovery)

    await controller.bootstrap()

    XCTAssertEqual(controller.state, .authenticated(profile: UserProfile(id: deletionOwnerID, ageVerified: true)))
    XCTAssertEqual(auth.signOutCalls, 0)
    XCTAssertEqual(profile.fetchCalls, 1)
  }

  func testRestartAfterAuthSessionDisappearsChecksReceiptWithoutInventingPendingState() async {
    let auth = FakeAuthService(currentSession: nil)
    let profile = FakeProfileAPI(profile: UserProfile(id: deletionOwnerID, ageVerified: true))
    let recovery = ScriptedDeletionRecovery(
      outcome: .deleted(ownerProfileID: deletionOwnerID, authUserID: deletionAuthUserID)
    )
    let cleanup = RecordingExternalIdentityCleanup()
    let controller = makeController(
      auth: auth,
      profile: profile,
      cleanup: cleanup,
      deletionRecovery: recovery
    )

    await controller.bootstrap()

    XCTAssertEqual(controller.state, .signedOut)
    XCTAssertEqual(profile.fetchCalls, 0)
    let checkedIDs = await recovery.checkedIDs()
    let cleanedOwners = await cleanup.ownerIDs()
    let clearedOwners = await recovery.clearedOwnerIDs()
    XCTAssertEqual(checkedIDs.count, 1)
    XCTAssertNil(checkedIDs[0])
    XCTAssertEqual(cleanedOwners, [deletionOwnerID])
    XCTAssertEqual(clearedOwners, [deletionOwnerID])
  }

  func testReceiptClearFailureKeepsBootstrapRecoverableAfterConfirmedDeletion() async {
    let auth = FakeAuthService(currentSession: nil)
    let recovery = ScriptedDeletionRecovery(
      outcome: .deleted(ownerProfileID: deletionOwnerID, authUserID: deletionAuthUserID),
      failClear: true
    )
    let controller = makeController(auth: auth, deletionRecovery: recovery)

    await controller.bootstrap()

    XCTAssertEqual(controller.state, .recoverableError)
    XCTAssertEqual(auth.signOutCalls, 0)
  }

  func testMissingSessionWithUnavailableReceiptStatusDoesNotClaimSignedOutRecovery() async {
    let recovery = ScriptedDeletionRecovery(outcome: .unavailable)
    let cleanup = RecordingExternalIdentityCleanup()
    let controller = makeController(
      auth: FakeAuthService(currentSession: nil),
      cleanup: cleanup,
      deletionRecovery: recovery
    )

    await controller.bootstrap()

    XCTAssertEqual(controller.state, .recoverableError)
    let cleanedOwners = await cleanup.ownerIDs()
    let clearedOwners = await recovery.clearedOwnerIDs()
    XCTAssertTrue(cleanedOwners.isEmpty)
    XCTAssertTrue(clearedOwners.isEmpty)
  }

  func testUnder18NeverCallsSignUp() async {
    let auth = FakeAuthService()
    let controller = makeController(auth: auth)
    let now = date(2026, 8, 24)
    let form = SignUpForm(
      email: "young@example.test",
      password: "password123",
      passwordConfirmation: "password123",
      birthDate: date(2010, 8, 24)
    )

    await controller.signUp(form: form, now: now)

    XCTAssertEqual(auth.signUpCalls, 0)
    XCTAssertEqual(controller.lastInputError, .under18)
  }

  func testExact18BoundaryIsAccepted() {
    let today = date(2026, 8, 24)
    let birthday = date(2008, 8, 24)
    let dayBefore = date(2008, 8, 25)

    XCTAssertNotNil(BirthDateValidator.validatedDate(birthday, now: today))
    XCTAssertTrue(BirthDateValidator.isAtLeast18(birthday, on: today))
    XCTAssertFalse(BirthDateValidator.isAtLeast18(dayBefore, on: today))
  }

  func testLeapDayAnniversaryMatchesServerBoundary() {
    let birthday = date(2008, 2, 29)

    XCTAssertFalse(BirthDateValidator.isAtLeast18(birthday, on: date(2026, 2, 28)))
    XCTAssertTrue(BirthDateValidator.isAtLeast18(birthday, on: date(2026, 3, 1)))
  }

  func testSessionWithUnverifiedProfileCannotBecomeAuthenticated() async {
    let auth = FakeAuthService(currentSession: AuthSession(accessToken: "token"))
    let profile = FakeProfileAPI(profile: UserProfile(id: "user", ageVerified: false))
    let controller = makeController(auth: auth, profile: profile)

    await controller.bootstrap()

    XCTAssertEqual(controller.state, .needsAgeVerification)
  }

  func testPersistedRecoverySessionBootstrapsIntoRecoveryWithoutProfileAccess() async {
    let auth = FakeAuthService(
      currentSession: AuthSession(
        accessToken: "recovery-token",
        purpose: .passwordRecovery
      )
    )
    let profile = FakeProfileAPI(profile: UserProfile(id: "user", ageVerified: true))
    let controller = makeController(auth: auth, profile: profile)

    await controller.bootstrap()

    XCTAssertEqual(controller.state, .passwordRecovery)
    XCTAssertEqual(profile.fetchCalls, 0)
  }

  func testRecoveryCallbackQueuedDuringBootstrapIsDrainedAfterCurrentSession() async {
    let auth = FakeAuthService(
      callbackSession: AuthSession(
        accessToken: "recovery-token",
        purpose: .passwordRecovery
      ),
      holdCurrentSession: true
    )
    let profile = FakeProfileAPI(profile: UserProfile(id: "user", ageVerified: true))
    let controller = makeController(auth: auth, profile: profile)
    let recoveryURL = URL(string: "wingward://login-callback/recovery?code=abc")!

    let bootstrap = Task { await controller.bootstrap() }
    while !auth.currentSessionStarted { await Task.yield() }

    await controller.handleCallback(recoveryURL)
    XCTAssertEqual(auth.callbackCalls, 0)

    auth.releaseCurrentSession()
    await bootstrap.value

    XCTAssertEqual(auth.callbackCalls, 1)
    XCTAssertEqual(controller.state, .passwordRecovery)
  }

  func testUnder18AgeVerificationDoesNotCallProfileAPI() async {
    let auth = FakeAuthService(currentSession: AuthSession(accessToken: "token"))
    let profile = FakeProfileAPI()
    let controller = makeController(
      auth: auth,
      profile: profile,
      initialState: .needsAgeVerification
    )

    await controller.submitAgeVerification(
      birthDate: date(2010, 8, 24),
      now: date(2026, 8, 24)
    )

    XCTAssertTrue(profile.verifiedDates.isEmpty)
    XCTAssertEqual(controller.lastInputError, .under18)
    XCTAssertEqual(controller.state, .needsAgeVerification)
  }

  func testAuthenticatedStateIgnoresAgeVerificationSubmission() async {
    let auth = FakeAuthService(currentSession: AuthSession(accessToken: "token"))
    let profile = FakeProfileAPI()
    let controller = makeController(
      auth: auth,
      profile: profile,
      initialState: .authenticated(profile: .fixture)
    )

    await controller.submitAgeVerification(
      birthDate: date(2000, 1, 1),
      now: date(2026, 8, 24)
    )

    XCTAssertTrue(profile.verifiedDates.isEmpty)
    XCTAssertEqual(controller.state, .authenticated(profile: .fixture))
  }

  func testProfileFailureFailsClosedToRecoverableError() async {
    let auth = FakeAuthService(currentSession: AuthSession(accessToken: "token"))
    let profile = FakeProfileAPI(fetchError: TestError.sensitive)
    let controller = makeController(auth: auth, profile: profile)

    await controller.bootstrap()

    XCTAssertEqual(controller.state, .recoverableError)
    XCTAssertFalse(AuthSessionController.genericErrorMessage.contains("sensitive"))
  }

  func testSignInFailureUsesGenericRecoverableError() async {
    let auth = FakeAuthService(signInError: TestError.sensitive)
    let controller = makeController(auth: auth)

    await controller.signIn(email: "person@example.test", password: "password123")

    XCTAssertEqual(controller.state, .recoverableError)
    XCTAssertEqual(
      AuthSessionController.genericErrorMessage,
      "We couldn't complete that request. Try again."
    )
    XCTAssertFalse(AuthSessionController.genericErrorMessage.contains("sensitive"))
  }

  func testSignInFailureRecordsOnlySafeHTTPStatusDiagnostic() async {
    let auth = FakeAuthService(
      signInError: AuthServiceError.diagnostic(.httpStatus(401))
    )
    let controller = makeController(auth: auth)

    await controller.signIn(email: "person@example.test", password: "password123")

    XCTAssertEqual(controller.state, .recoverableError)
    XCTAssertEqual(controller.lastDiagnostic?.stage, .authSignIn)
    XCTAssertEqual(controller.lastDiagnostic?.category, .httpStatus)
    XCTAssertEqual(controller.lastDiagnostic?.httpStatus, 401)
    XCTAssertEqual(controller.lastDiagnostic?.reportCode, "SI-HTTP-401")
  }

  func testSignUpFailureRecordsAuthSignUpStageAndStatus() async {
    let auth = FakeAuthService(
      signUpError: AuthServiceError.diagnostic(.httpStatus(422))
    )
    let controller = makeController(auth: auth)
    let form = SignUpForm(
      email: "person@example.test",
      password: "password123",
      passwordConfirmation: "password123",
      birthDate: date(2000, 1, 1)
    )

    await controller.signUp(form: form, now: date(2026, 8, 24))

    XCTAssertEqual(controller.state, .recoverableError)
    XCTAssertEqual(controller.lastDiagnostic?.stage, .authSignUp)
    XCTAssertEqual(controller.lastDiagnostic?.reportCode, "SU-HTTP-422")
  }

  func testAgeVerificationFailureRecordsAgeStageAndStatus() async {
    let auth = FakeAuthService(signUpSession: AuthSession(accessToken: "token"))
    let profile = FakeProfileAPI(
      verifyError: ProfileAPIError.requestFailedWithStatus(403)
    )
    let controller = makeController(auth: auth, profile: profile)
    let form = SignUpForm(
      email: "person@example.test",
      password: "password123",
      passwordConfirmation: "password123",
      birthDate: date(2000, 1, 1)
    )

    await controller.signUp(form: form, now: date(2026, 8, 24))

    XCTAssertEqual(controller.state, .recoverableError)
    XCTAssertEqual(controller.lastDiagnostic?.stage, .ageVerification)
    XCTAssertEqual(controller.lastDiagnostic?.reportCode, "AV-HTTP-403")
  }

  func testProfileFailureRecordsSafeStatusWithoutResponseBody() async {
    let auth = FakeAuthService(currentSession: AuthSession(accessToken: "token"))
    let profile = FakeProfileAPI(
      fetchError: ProfileAPIError.requestFailedWithStatus(403)
    )
    let controller = makeController(auth: auth, profile: profile)

    await controller.bootstrap()

    XCTAssertEqual(controller.state, .recoverableError)
    XCTAssertEqual(controller.lastDiagnostic?.stage, .profileFetch)
    XCTAssertEqual(controller.lastDiagnostic?.reportCode, "PF-HTTP-403")
  }

  func testStorageFailureRecordsStorageCategory() async {
    let controller = makeController(
      health: FakeHealthChecker(error: KeychainStorageError.invalidData)
    )

    await controller.bootstrap()

    XCTAssertEqual(controller.state, .recoverableError)
    XCTAssertEqual(controller.lastDiagnostic?.stage, .storage)
    XCTAssertEqual(controller.lastDiagnostic?.category, .storage)
    XCTAssertEqual(controller.lastDiagnostic?.reportCode, "ST-STORE")
  }

  func testSupabaseAuthErrorMappingKeepsOnlyHTTPStatus() {
    let response = HTTPURLResponse(
      url: URL(string: "https://auth.example.test")!,
      statusCode: 422,
      httpVersion: nil,
      headerFields: nil
    )!
    let error = AuthError.api(
      message: "server detail",
      errorCode: .signupDisabled,
      underlyingData: Data("server detail".utf8),
      underlyingResponse: response
    )

    XCTAssertEqual(
      SupabaseAuthService.mapAuthFailure(error),
      .diagnostic(.httpStatus(422))
    )
  }

  func testSupabaseAuthErrorMappingUsesOnlyAllowlistedProviderReasons() {
    let response = HTTPURLResponse(
      url: URL(string: "https://auth.example.test")!,
      statusCode: 400,
      httpVersion: nil,
      headerFields: nil
    )!
    let cases: [(ErrorCode, AuthDiagnosticAuthFailure)] = [
      (.invalidCredentials, .invalidCredentials),
      (ErrorCode("email_address_invalid"), .emailAddressInvalid),
      (.emailNotConfirmed, .emailNotConfirmed),
      (.captchaFailed, .captchaFailed),
      (.emailProviderDisabled, .emailProviderDisabled),
      (.providerDisabled, .providerDisabled),
      (.overRequestRateLimit, .rateLimited),
      (.overEmailSendRateLimit, .rateLimited),
    ]

    for (errorCode, expectedReason) in cases {
      let error = AuthError.api(
        message: "untrusted provider message",
        errorCode: errorCode,
        underlyingData: Data("untrusted provider body".utf8),
        underlyingResponse: response
      )
      let mapped = SupabaseAuthService.mapAuthFailure(error)
      let diagnostic = AuthDiagnostic.from(error: mapped, stage: .authSignIn)

      XCTAssertEqual(mapped, .diagnostic(.authFailure(expectedReason)))
      XCTAssertEqual(diagnostic.category, .authFailure)
      XCTAssertEqual(diagnostic.reportCode, "SI-AUTH-\(expectedReason.rawValue)")
    }
  }

  func testUnknownSupabaseAuthErrorCodeFallsBackToHTTPStatusWithoutEchoingIt() {
    let unknownCode = "PWNED_RAW_PROVIDER_CODE"
    let rawMessage = "PWNED_RAW_PROVIDER_MESSAGE"
    let response = HTTPURLResponse(
      url: URL(string: "https://auth.example.test")!,
      statusCode: 400,
      httpVersion: nil,
      headerFields: nil
    )!
    let error = AuthError.api(
      message: rawMessage,
      errorCode: ErrorCode(unknownCode),
      underlyingData: Data(rawMessage.utf8),
      underlyingResponse: response
    )

    let mapped = SupabaseAuthService.mapAuthFailure(error)
    let reportCode = AuthDiagnostic.from(error: mapped, stage: .authSignIn).reportCode

    XCTAssertEqual(mapped, .diagnostic(.httpStatus(400)))
    XCTAssertEqual(reportCode, "SI-HTTP-400")
    XCTAssertFalse(reportCode.contains(unknownCode))
    XCTAssertFalse(reportCode.contains(rawMessage))
  }

  func testDiagnosticCategoriesAndStatusesAreFixedAndSanitized() {
    XCTAssertEqual(
      AuthDiagnostic.from(error: URLError(.timedOut), stage: .profileFetch).reportCode,
      "PF-NET"
    )
    let decodeError = DecodingError.dataCorrupted(
      .init(codingPath: [], debugDescription: "decoder failure")
    )
    XCTAssertEqual(
      AuthDiagnostic.from(error: decodeError, stage: .profileFetch).reportCode,
      "PF-DATA"
    )

    let invalidStatus = AuthDiagnostic(
      stage: .authSignIn,
      source: .httpStatus(700)
    )
    XCTAssertEqual(invalidStatus.category, .unknown)
    XCTAssertNil(invalidStatus.httpStatus)
    XCTAssertEqual(invalidStatus.reportCode, "SI-UNKNOWN")
  }

  func testDiagnosticPresentationOptInIsDebugOnlyAndKeepsValidationBundleBehavior() {
#if DEBUG
    XCTAssertTrue(
      AuthDiagnosticPresentation.isEnabled(
        bundleIdentifier: AuthDiagnosticPresentation.validationBundleIdentifier,
        arguments: []
      )
    )
    XCTAssertFalse(
      AuthDiagnosticPresentation.isEnabled(
        bundleIdentifier: AuthDiagnosticPresentation.ownerDebugBundleIdentifier,
        arguments: []
      )
    )
    XCTAssertTrue(
      AuthDiagnosticPresentation.isEnabled(
        bundleIdentifier: AuthDiagnosticPresentation.ownerDebugBundleIdentifier,
        arguments: [AuthDiagnosticPresentation.ownerDebugLaunchArgument]
      )
    )
    XCTAssertFalse(
      AuthDiagnosticPresentation.isEnabled(
        bundleIdentifier: AuthDiagnosticPresentation.ownerDebugBundleIdentifier,
        arguments: ["--wingward-auth-diagnostics-extra"]
      )
    )
    XCTAssertFalse(
      AuthDiagnosticPresentation.isEnabled(
        bundleIdentifier: "com.other.app",
        arguments: [AuthDiagnosticPresentation.ownerDebugLaunchArgument]
      )
    )
#else
    XCTAssertFalse(
      AuthDiagnosticPresentation.isEnabled(
        bundleIdentifier: AuthDiagnosticPresentation.validationBundleIdentifier,
        arguments: []
      )
    )
    XCTAssertFalse(
      AuthDiagnosticPresentation.isEnabled(
        bundleIdentifier: AuthDiagnosticPresentation.ownerDebugBundleIdentifier,
        arguments: [AuthDiagnosticPresentation.ownerDebugLaunchArgument]
      )
    )
#endif
    XCTAssertFalse(
      AuthDiagnosticPresentation.isEnabled(
        bundleIdentifier: nil,
        arguments: [AuthDiagnosticPresentation.ownerDebugLaunchArgument]
      )
    )
  }

  func testSignOutSuccessCallsAuthServiceOnceAndReachesSignedOut() async {
    let auth = FakeAuthService()
    let controller = makeController(
      auth: auth,
      initialState: .authenticated(profile: .fixture)
    )

    await controller.signOut()

    XCTAssertEqual(auth.signOutCalls, 1)
    XCTAssertEqual(controller.state, .signedOut)
  }

  func testSignOutResetsExternalIdentityForTheAuthenticatedOwner() async {
    let auth = FakeAuthService()
    let cleanup = RecordingExternalIdentityCleanup()
    let controller = makeController(
      auth: auth,
      cleanup: cleanup,
      initialState: .authenticated(profile: .fixture)
    )

    await controller.signOut()

    let ownerIDs = await cleanup.ownerIDs()
    XCTAssertEqual(ownerIDs, [UserProfile.fixture.id!])
  }

  func testServerDeletionCleanupSignsOutMatchingOwner() async {
    let auth = FakeAuthService()
    let controller = makeController(
      auth: auth,
      initialState: .authenticated(profile: .fixture)
    )

    await controller.clearAfterServerDeletion(ownerID: UserProfile.fixture.id!)

    XCTAssertEqual(auth.signOutCalls, 1)
    XCTAssertEqual(controller.state, .signedOut)
  }

  func testServerDeletionCleanupNeverSignsOutDifferentOwner() async {
    let auth = FakeAuthService()
    let controller = makeController(
      auth: auth,
      initialState: .authenticated(profile: .fixture)
    )

    await controller.clearAfterServerDeletion(ownerID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")

    XCTAssertEqual(auth.signOutCalls, 0)
    XCTAssertEqual(controller.state, .authenticated(profile: .fixture))
  }

  func testServerDeletionCleanupResetsExternalIdentityOnlyForMatchingOwner() async {
    let auth = FakeAuthService()
    let cleanup = RecordingExternalIdentityCleanup()
    let controller = makeController(
      auth: auth,
      cleanup: cleanup,
      initialState: .authenticated(profile: .fixture)
    )

    await controller.clearAfterServerDeletion(ownerID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    let ownerIDsBeforeMatch = await cleanup.ownerIDs()
    XCTAssertTrue(ownerIDsBeforeMatch.isEmpty)

    // The matching deletion path is the only path that reaches sign-out and
    // the injected vendor-identity reset.
    let matchingController = makeController(
      auth: FakeAuthService(),
      cleanup: cleanup,
      initialState: .authenticated(profile: .fixture)
    )
    await matchingController.clearAfterServerDeletion(ownerID: UserProfile.fixture.id!)
    let ownerIDsAfterMatch = await cleanup.ownerIDs()
    XCTAssertEqual(ownerIDsAfterMatch, [UserProfile.fixture.id!])
  }

  func testServerDeletionCleanupWaitsForBusyAuthOperationThenCleansUpSameOwner() async {
    let auth = FakeAuthService(
      signUpSession: AuthSession(accessToken: "new-token"),
      holdSignUp: true
    )
    let profile = FakeProfileAPI(profile: .fixture)
    let controller = makeController(
      auth: auth,
      profile: profile,
      initialState: .authenticated(profile: .fixture)
    )
    let form = SignUpForm(
      email: "person@example.test",
      password: "password123",
      passwordConfirmation: "password123",
      birthDate: date(2000, 1, 1)
    )

    let authOperation = Task {
      await controller.signUp(form: form, now: date(2026, 8, 24))
    }
    while auth.signUpCalls == 0 { await Task.yield() }
    XCTAssertTrue(controller.isSubmitting)

    let cleanup = Task {
      await controller.clearAfterServerDeletion(ownerID: UserProfile.fixture.id!)
    }
    for _ in 0..<3 { await Task.yield() }
    XCTAssertEqual(auth.signOutCalls, 0)

    auth.releaseSignUp()
    await authOperation.value
    await cleanup.value

    XCTAssertEqual(auth.signOutCalls, 1)
    XCTAssertEqual(controller.state, .signedOut)
  }

  func testServerDeletionCleanupDoesNotSignOutNewOwnerAfterBusyAuthOperationSwitchesOwner() async {
    let ownerB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let profileB = UserProfile(id: ownerB, ageVerified: true)
    let auth = FakeAuthService(
      signUpSession: AuthSession(accessToken: "new-token"),
      holdSignUp: true
    )
    let profile = FakeProfileAPI(profile: .fixture)
    let controller = makeController(
      auth: auth,
      profile: profile,
      initialState: .authenticated(profile: .fixture)
    )
    let form = SignUpForm(
      email: "person@example.test",
      password: "password123",
      passwordConfirmation: "password123",
      birthDate: date(2000, 1, 1)
    )

    let authOperation = Task {
      await controller.signUp(form: form, now: date(2026, 8, 24))
    }
    while auth.signUpCalls == 0 { await Task.yield() }
    let cleanup = Task {
      await controller.clearAfterServerDeletion(ownerID: UserProfile.fixture.id!)
    }
    for _ in 0..<3 { await Task.yield() }

    profile.profile = profileB
    auth.releaseSignUp()
    await authOperation.value
    await cleanup.value

    XCTAssertEqual(auth.signOutCalls, 0)
    XCTAssertEqual(controller.state, .authenticated(profile: profileB))
  }

  func testCancelledServerDeletionCleanupNeverSignsOut() async {
    let auth = FakeAuthService(
      signUpSession: AuthSession(accessToken: "new-token"),
      holdSignUp: true
    )
    let controller = makeController(
      auth: auth,
      initialState: .authenticated(profile: .fixture)
    )
    let form = SignUpForm(
      email: "person@example.test",
      password: "password123",
      passwordConfirmation: "password123",
      birthDate: date(2000, 1, 1)
    )

    let authOperation = Task {
      await controller.signUp(form: form, now: date(2026, 8, 24))
    }
    while auth.signUpCalls == 0 { await Task.yield() }
    let cleanup = Task {
      await controller.clearAfterServerDeletion(ownerID: UserProfile.fixture.id!)
    }
    for _ in 0..<3 { await Task.yield() }

    cleanup.cancel()
    await cleanup.value
    XCTAssertEqual(auth.signOutCalls, 0)

    auth.releaseSignUp()
    await authOperation.value
    XCTAssertEqual(auth.signOutCalls, 0)
  }

  func testSignOutFailureCallsAuthServiceOnceAndReachesRecoverableError() async {
    let auth = FakeAuthService(signOutError: TestError.sensitive)
    let cleanup = RecordingExternalIdentityCleanup()
    let controller = makeController(
      auth: auth,
      cleanup: cleanup,
      initialState: .authenticated(profile: .fixture)
    )

    await controller.signOut()

    XCTAssertEqual(auth.signOutCalls, 1)
    XCTAssertEqual(controller.state, .recoverableError)
    XCTAssertNotEqual(controller.state, .signedOut)
    let ownerIDs = await cleanup.ownerIDs()
    XCTAssertEqual(ownerIDs, [UserProfile.fixture.id!])
  }

  func testSignOutFailureCannotReenterAccountWhenRetryReadsClearedSession() async {
    let profile = UserProfile(id: "user", ageVerified: true)
    let auth = FakeAuthService(
      currentSession: AuthSession(accessToken: "token"),
      signOutError: TestError.sensitive
    )
    let controller = makeController(
      auth: auth,
      profile: FakeProfileAPI(profile: profile),
      initialState: .authenticated(profile: profile)
    )

    await controller.signOut()

    XCTAssertEqual(controller.state, .recoverableError)

    await controller.retry()

    XCTAssertEqual(controller.state, .signedOut)
    XCTAssertNotEqual(controller.state, .authenticated(profile: profile))
  }

  func testKeychainHealthFailureNeverLooksSignedOut() async {
    let health = FakeHealthChecker(error: TestError.sensitive)
    let controller = makeController(health: health)

    await controller.bootstrap()

    XCTAssertEqual(controller.state, .recoverableError)
  }

  func testAllowedCallbackReachesAuthServiceAndRefreshesProfile() async {
    let auth = FakeAuthService(callbackSession: AuthSession(accessToken: "token"))
    let profile = FakeProfileAPI(profile: UserProfile(id: "user", ageVerified: true))
    let controller = makeController(
      auth: auth,
      profile: profile,
      initialState: .signedOut
    )
    let url = URL(string: "wingward://login-callback/?code=abc&state=opaque")!

    await controller.handleCallback(url)

    XCTAssertEqual(auth.callbackCalls, 1)
    XCTAssertEqual(controller.state, .authenticated(profile: UserProfile(id: "user", ageVerified: true)))
  }

  func testCallbackBeforeBootstrapIsQueuedUntilStorageHealthIsChecked() async {
    let auth = FakeAuthService(
      callbackSession: AuthSession(
        accessToken: "recovery-token",
        purpose: .passwordRecovery
      )
    )
    let controller = makeController(auth: auth)
    let url = URL(string: "wingward://login-callback/recovery?code=abc")!

    await controller.handleCallback(url)

    XCTAssertEqual(auth.callbackCalls, 0)
    XCTAssertEqual(controller.state, .booting)

    await controller.bootstrap()

    XCTAssertEqual(auth.callbackCalls, 1)
    XCTAssertEqual(controller.state, .passwordRecovery)
  }

  func testQueuedRecoveryCallbackTakesPriorityOverPersistedOrdinarySession() async {
    let auth = FakeAuthService(
      currentSession: AuthSession(accessToken: "ordinary-token"),
      callbackSession: AuthSession(
        accessToken: "recovery-token",
        purpose: .passwordRecovery
      ),
      holdCurrentSession: true
    )
    let profile = FakeProfileAPI(profile: UserProfile(id: "user", ageVerified: true))
    let controller = makeController(auth: auth, profile: profile)
    let recoveryURL = URL(string: "wingward://login-callback/recovery?code=abc")!

    let bootstrap = Task { await controller.bootstrap() }
    while !auth.currentSessionStarted { await Task.yield() }

    await controller.handleCallback(recoveryURL)
    auth.releaseCurrentSession()
    await bootstrap.value

    XCTAssertEqual(auth.callbackCalls, 1)
    XCTAssertEqual(profile.fetchCalls, 0)
    XCTAssertEqual(controller.state, .passwordRecovery)
  }

  func testResetRequestUsesSameCompletionStateForAnyAcceptedAddress() async {
    for email in ["person@example.test", "unknown@example.test"] {
      let auth = FakeAuthService()
      let controller = makeController(auth: auth, initialState: .signedOut)

      controller.beginPasswordResetRequest()
      await controller.resetPassword(email: email)

      XCTAssertEqual(controller.state, .passwordResetRequested)
      XCTAssertEqual(auth.resetPasswordCalls, 1)
      XCTAssertEqual(auth.resetRedirects, [CallbackURLPolicy.recoveryCallbackURL])
    }
  }

  func testResetRequestFailureUsesSameCompletionStateWithoutLeakingDetails() async {
    let auth = FakeAuthService(resetError: TestError.sensitive)
    let controller = makeController(auth: auth, initialState: .signedOut)

    controller.beginPasswordResetRequest()
    await controller.resetPassword(email: "person@example.test")

    XCTAssertEqual(controller.state, .passwordResetRequested)
    XCTAssertEqual(auth.resetPasswordCalls, 1)
    XCTAssertFalse(AuthSessionController.genericErrorMessage.contains("sensitive"))
  }

  func testInvalidResetRequestNeverReachesAuthService() async {
    let auth = FakeAuthService()
    let controller = makeController(auth: auth, initialState: .signedOut)

    controller.beginPasswordResetRequest()
    await controller.resetPassword(email: "not-an-email")

    XCTAssertEqual(auth.resetPasswordCalls, 0)
    XCTAssertEqual(controller.lastInputError, .emailInvalid)
    XCTAssertEqual(controller.state, .passwordResetRequest)
  }

  func testDuplicatePasswordResetRequestsSubmitOnlyOnce() async {
    let auth = FakeAuthService(holdResetPassword: true)
    let controller = makeController(auth: auth, initialState: .signedOut)
    controller.beginPasswordResetRequest()

    let first = Task { await controller.resetPassword(email: "person@example.test") }
    while auth.resetPasswordCalls == 0 { await Task.yield() }
    await controller.resetPassword(email: "person@example.test")
    auth.releaseResetPassword()
    await first.value

    XCTAssertEqual(auth.resetPasswordCalls, 1)
  }

  func testNormalCallbackNeverEntersPasswordRecovery() async {
    let auth = FakeAuthService(callbackSession: AuthSession(accessToken: "token"))
    let profile = FakeProfileAPI(profile: UserProfile(id: "user", ageVerified: true))
    let controller = makeController(auth: auth, profile: profile, initialState: .signedOut)

    await controller.handleCallback(URL(string: "wingward://login-callback/?code=abc")!)

    XCTAssertEqual(auth.callbackCalls, 1)
    XCTAssertEqual(controller.state, .authenticated(profile: UserProfile(id: "user", ageVerified: true)))
    XCTAssertNotEqual(controller.state, .passwordRecovery)
  }

  func testNormalCallbackWithoutPKCECodeNeverReachesAuthService() async {
    let auth = FakeAuthService(callbackSession: AuthSession(accessToken: "token"))
    let profile = FakeProfileAPI(profile: UserProfile(id: "user", ageVerified: true))
    let controller = makeController(
      auth: auth,
      profile: profile,
      initialState: .signedOut
    )

    await controller.handleCallback(URL(string: "wingward://login-callback/")!)

    XCTAssertEqual(auth.callbackCalls, 0)
    XCTAssertEqual(profile.fetchCalls, 0)
    XCTAssertEqual(controller.state, .recoverableError)
  }

  func testNormalCallbackCannotUseRecoveryPurposeSession() async {
    let auth = FakeAuthService(
      callbackSession: AuthSession(
        accessToken: "recovery-token",
        purpose: .passwordRecovery
      )
    )
    let profile = FakeProfileAPI(profile: UserProfile(id: "user", ageVerified: true))
    let controller = makeController(
      auth: auth,
      profile: profile,
      initialState: .signedOut
    )

    await controller.handleCallback(
      URL(string: "wingward://login-callback/?code=abc")!
    )

    XCTAssertEqual(auth.callbackCalls, 1)
    XCTAssertEqual(profile.fetchCalls, 0)
    XCTAssertEqual(controller.state, .recoverableError)
    XCTAssertNotEqual(controller.state, .passwordRecovery)
  }

  func testRecoveryCallbackRequiresExactRecoveryPurpose() async {
    let auth = FakeAuthService(callbackSession: AuthSession(accessToken: "token"))
    let controller = makeController(auth: auth, initialState: .signedOut)

    await controller.handleCallback(URL(string: "wingward://login-callback/recovery/")!)

    XCTAssertEqual(auth.callbackCalls, 0)
    XCTAssertEqual(controller.state, .recoverableError)
    XCTAssertNotEqual(controller.state, .passwordRecovery)
  }

  func testCallbackPurposeAllowListSeparatesNormalAndRecoveryPaths() {
    XCTAssertEqual(
      CallbackURLPolicy.purpose(for: URL(string: "wingward://login-callback/?code=abc")!),
      .normal
    )
    XCTAssertEqual(
      CallbackURLPolicy.purpose(for: URL(string: "wingward://login-callback/recovery?code=abc")!),
      .recovery
    )

    for rawURL in [
      "wingward://login-callback/recovery/",
      "wingward://login-callback/%72ecovery?code=abc",
      "wingward://login-callback/recovery#fragment",
    ] {
      XCTAssertNil(CallbackURLPolicy.purpose(for: URL(string: rawURL)! ), rawURL)
    }
  }

  func testRecoveryCallbackWithoutPKCECodeNeverReachesAuthService() async {
    let auth = FakeAuthService(callbackSession: AuthSession(accessToken: "token"))
    let controller = makeController(auth: auth, initialState: .signedOut)

    await controller.handleCallback(URL(string: "wingward://login-callback/recovery")!)

    XCTAssertEqual(auth.callbackCalls, 0)
    XCTAssertEqual(controller.state, .recoverableError)
  }

  func testRecoveryCallbackExchangeFailureNeverEntersPasswordRecovery() async {
    let auth = FakeAuthService(callbackError: TestError.sensitive)
    let controller = makeController(auth: auth, initialState: .signedOut)

    await controller.handleCallback(
      URL(string: "wingward://login-callback/recovery?code=invalid")!
    )

    XCTAssertEqual(auth.callbackCalls, 1)
    XCTAssertEqual(controller.state, .recoverableError)
    XCTAssertNotEqual(controller.state, .passwordRecovery)
  }

  func testRecoveryCallbackCannotUseOrdinaryPurposeSession() async {
    let auth = FakeAuthService(callbackSession: AuthSession(accessToken: "ordinary-token"))
    let controller = makeController(auth: auth, initialState: .signedOut)

    await controller.handleCallback(
      URL(string: "wingward://login-callback/recovery?code=abc")!
    )

    XCTAssertEqual(auth.callbackCalls, 1)
    XCTAssertEqual(controller.state, .recoverableError)
    XCTAssertNotEqual(controller.state, .passwordRecovery)
  }

  func testDuplicateRecoveryCallbackExchangesCodeOnlyOnce() async {
    let auth = FakeAuthService(
      callbackSession: AuthSession(
        accessToken: "recovery-token",
        purpose: .passwordRecovery
      )
    )
    let controller = makeController(auth: auth, initialState: .signedOut)
    let url = URL(string: "wingward://login-callback/recovery?code=abc")!

    await controller.handleCallback(url)
    await controller.handleCallback(url)

    XCTAssertEqual(auth.callbackCalls, 1)
    XCTAssertEqual(controller.state, .passwordRecovery)
  }

  func testInvalidPasswordResetNeverCallsUpdate() async {
    let auth = FakeAuthService()
    let controller = makeController(auth: auth, initialState: .passwordRecovery)

    await controller.updatePassword(
      form: PasswordResetForm(password: "short", passwordConfirmation: "short")
    )

    XCTAssertEqual(auth.updatePasswordCalls, 0)
    XCTAssertEqual(controller.lastInputError, .passwordTooShort)
    XCTAssertEqual(controller.state, .passwordRecovery)
  }

  func testMismatchedPasswordResetNeverCallsUpdate() async {
    let auth = FakeAuthService()
    let controller = makeController(auth: auth, initialState: .passwordRecovery)

    await controller.updatePassword(
      form: PasswordResetForm(password: "new-password", passwordConfirmation: "different")
    )

    XCTAssertEqual(auth.updatePasswordCalls, 0)
    XCTAssertEqual(controller.lastInputError, .passwordsDoNotMatch)
    XCTAssertEqual(controller.state, .passwordRecovery)
  }

  func testMissingPasswordConfirmationNeverCallsUpdate() async {
    let auth = FakeAuthService()
    let controller = makeController(auth: auth, initialState: .passwordRecovery)

    await controller.updatePassword(
      form: PasswordResetForm(password: "new-password", passwordConfirmation: "")
    )

    XCTAssertEqual(auth.updatePasswordCalls, 0)
    XCTAssertEqual(controller.lastInputError, .passwordConfirmationRequired)
    XCTAssertEqual(controller.state, .passwordRecovery)
  }

  func testPasswordUpdateFailureKeepsRecoveryStateAndDoesNotSignOut() async {
    let auth = FakeAuthService(updatePasswordError: TestError.sensitive)
    let controller = makeController(auth: auth, initialState: .passwordRecovery)

    await controller.updatePassword(
      form: PasswordResetForm(password: "new-password", passwordConfirmation: "new-password")
    )

    XCTAssertEqual(auth.updatePasswordCalls, 1)
    XCTAssertEqual(auth.signOutCalls, 0)
    XCTAssertEqual(controller.state, .passwordRecovery)
    XCTAssertTrue(controller.hasPasswordUpdateError)
  }

  func testPasswordUpdateSuccessSignsOutAndClearsSession() async {
    let auth = FakeAuthService(
      currentSession: AuthSession(
        accessToken: "recovery-token",
        purpose: .passwordRecovery
      )
    )
    let controller = makeController(auth: auth, initialState: .passwordRecovery)

    await controller.updatePassword(
      form: PasswordResetForm(password: "new-password", passwordConfirmation: "new-password")
    )

    XCTAssertEqual(auth.updatePasswordCalls, 1)
    XCTAssertEqual(auth.signOutCalls, 1)
    XCTAssertNil(auth.currentSessionValue)
    XCTAssertEqual(controller.state, .signedOut)
  }

  func testPasswordUpdateSignOutFailureStillClearsLocalSessionAndFailsClosed() async {
    let auth = FakeAuthService(
      currentSession: AuthSession(
        accessToken: "recovery-token",
        purpose: .passwordRecovery
      ),
      signOutError: TestError.sensitive
    )
    let controller = makeController(auth: auth, initialState: .passwordRecovery)

    await controller.updatePassword(
      form: PasswordResetForm(password: "new-password", passwordConfirmation: "new-password")
    )

    XCTAssertEqual(auth.updatePasswordCalls, 1)
    XCTAssertEqual(auth.signOutCalls, 1)
    XCTAssertNil(auth.currentSessionValue)
    XCTAssertEqual(controller.state, .recoverableError)
    XCTAssertNotEqual(controller.state, .signedOut)

    await controller.retry()

    XCTAssertEqual(controller.state, .signedOut)
  }

  func testDuplicatePasswordUpdateSubmitsOnlyOnce() async {
    let auth = FakeAuthService(holdUpdatePassword: true)
    let controller = makeController(auth: auth, initialState: .passwordRecovery)
    let form = PasswordResetForm(password: "new-password", passwordConfirmation: "new-password")

    let first = Task { await controller.updatePassword(form: form) }
    while auth.updatePasswordCalls == 0 { await Task.yield() }
    await controller.updatePassword(form: form)
    auth.releaseUpdatePassword()
    await first.value

    XCTAssertEqual(auth.updatePasswordCalls, 1)
  }

  func testRejectedCallbacksNeverReachAuthService() async {
    let rejected = [
      "wingward://login-callback",
      "wingward://login-callback/extra",
      "https://login-callback/",
      "wingward://other/",
      "wingward://login-callback/#fragment",
      "wingward://user:password@login-callback/?code=abc",
      "wingward://login-callback:443/?code=abc",
    ]

    for rawURL in rejected {
      let auth = FakeAuthService(callbackSession: AuthSession(accessToken: "token"))
      let controller = makeController(auth: auth)
      await controller.handleCallback(URL(string: rawURL)!)
      XCTAssertEqual(auth.callbackCalls, 0, rawURL)
      XCTAssertEqual(controller.state, .recoverableError, rawURL)
    }
  }

  func testDuplicateSubmissionCallsSignUpOnce() async {
    let auth = FakeAuthService(signUpSession: nil, holdSignUp: true)
    let controller = makeController(auth: auth)
    let form = SignUpForm(
      email: "person@example.test",
      password: "password123",
      passwordConfirmation: "password123",
      birthDate: date(2000, 1, 1)
    )

    let first = Task { await controller.signUp(form: form, now: date(2026, 8, 24)) }
    while auth.signUpCalls == 0 { await Task.yield() }
    await controller.signUp(form: form, now: date(2026, 8, 24))
    auth.releaseSignUp()
    await first.value

    XCTAssertEqual(auth.signUpCalls, 1)
  }

  func testSignupWithoutSessionShowsMaskedConfirmationEmail() async {
    let auth = FakeAuthService(signUpSession: nil)
    let controller = makeController(auth: auth)
    let form = SignUpForm(
      email: "alexandra@example.test",
      password: "password123",
      passwordConfirmation: "password123",
      birthDate: date(2000, 1, 1)
    )

    await controller.signUp(form: form, now: date(2026, 8, 24))

    XCTAssertEqual(
      controller.state,
      .awaitingEmailConfirmation(maskedEmail: "a•••••@example.test")
    )
    if case let .awaitingEmailConfirmation(masked) = controller.state {
      XCTAssertFalse(masked.contains("alexandra"))
    }
  }

  func testOnlyConfirmationStateCanLeaveConfirmation() {
    let confirmationController = makeController(
      initialState: .awaitingEmailConfirmation(maskedEmail: "a••@example.test")
    )
    confirmationController.leaveEmailConfirmation()
    XCTAssertEqual(confirmationController.state, .signedOut)

    let recoverableController = makeController(initialState: .recoverableError)
    recoverableController.leaveEmailConfirmation()
    XCTAssertEqual(recoverableController.state, .recoverableError)
  }

  func testImmediateSignupSubmitsDateOnlyToProfileAPI() async {
    let auth = FakeAuthService(signUpSession: AuthSession(accessToken: "token"))
    let profile = FakeProfileAPI(profile: UserProfile(id: "user", ageVerified: true))
    let controller = makeController(auth: auth, profile: profile)
    let form = SignUpForm(
      email: "person@example.test",
      password: "password123",
      passwordConfirmation: "password123",
      birthDate: date(2000, 1, 2)
    )

    await controller.signUp(form: form, now: date(2026, 8, 24))

    XCTAssertEqual(profile.verifiedDates, ["2000-01-02"])
    XCTAssertEqual(controller.state, .authenticated(profile: UserProfile(id: "user", ageVerified: true)))
  }

  func testOnboardingRefreshPublishesMatchingServerProfile() async {
    let ownerID = UserProfile.fixture.id!
    let auth = FakeAuthService(currentSession: AuthSession(accessToken: "token"))
    let profile = FakeProfileAPI(
      profile: UserProfile(id: ownerID, ageVerified: true, onboardingStatus: "confirmed")
    )
    let controller = makeController(
      auth: auth,
      profile: profile,
      initialState: .authenticated(
        profile: UserProfile(id: ownerID, ageVerified: true, onboardingStatus: "not_started")
      )
    )

    let refreshed = await controller.refreshProfileAfterOnboarding(ownerID: ownerID)

    XCTAssertTrue(refreshed)
    XCTAssertEqual(profile.fetchCalls, 1)
    XCTAssertEqual(
      controller.state,
      .authenticated(profile: UserProfile(id: ownerID, ageVerified: true, onboardingStatus: "confirmed"))
    )
  }

  func testOnboardingRefreshRejectsAResponseForAnotherOwner() async {
    let ownerID = UserProfile.fixture.id!
    let auth = FakeAuthService(currentSession: AuthSession(accessToken: "token"))
    let profile = FakeProfileAPI(
      profile: UserProfile(
        id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        ageVerified: true,
        onboardingStatus: "confirmed"
      )
    )
    let controller = makeController(
      auth: auth,
      profile: profile,
      initialState: .authenticated(
        profile: UserProfile(id: ownerID, ageVerified: true, onboardingStatus: "not_started")
      )
    )

    let refreshed = await controller.refreshProfileAfterOnboarding(ownerID: ownerID)

    XCTAssertFalse(refreshed)
    XCTAssertEqual(profile.fetchCalls, 1)
    XCTAssertEqual(
      controller.state,
      .authenticated(profile: UserProfile(id: ownerID, ageVerified: true, onboardingStatus: "not_started"))
    )
  }

  func testOnboardingRefreshDoesNotRunWhileAuthenticationIsSubmitting() async {
    let auth = FakeAuthService(
      signUpSession: AuthSession(accessToken: "new-token"),
      holdSignUp: true
    )
    let profile = FakeProfileAPI(profile: .fixture)
    let controller = makeController(
      auth: auth,
      profile: profile,
      initialState: .authenticated(profile: .fixture)
    )
    let form = SignUpForm(
      email: "person@example.test",
      password: "password123",
      passwordConfirmation: "password123",
      birthDate: date(2000, 1, 1)
    )
    let authentication = Task {
      await controller.signUp(form: form, now: date(2026, 8, 24))
    }
    while auth.signUpCalls == 0 { await Task.yield() }

    let refreshed = await controller.refreshProfileAfterOnboarding(
      ownerID: UserProfile.fixture.id!
    )

    XCTAssertFalse(refreshed)
    XCTAssertEqual(profile.fetchCalls, 0)
    auth.releaseSignUp()
    await authentication.value
  }

  private func makeController(
    auth: FakeAuthService = FakeAuthService(),
    profile: FakeProfileAPI = FakeProfileAPI(),
    health: FakeHealthChecker = FakeHealthChecker(),
    cleanup: any AuthExternalIdentityCleanup = NoopAuthExternalIdentityCleanup(),
    deletionRecovery: (any AccountDeletionRecoveryChecking)? = nil,
    initialState: AuthState = .booting
  ) -> AuthSessionController {
    AuthSessionController(
      authService: auth,
      profileAPI: profile,
      storageHealthChecker: health,
      externalIdentityCleanup: cleanup,
      deletionRecovery: deletionRecovery,
      initialState: initialState
    )
  }

  private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    BirthDateValidator.exactDate(year: year, month: month, day: day)!
  }
}

private enum TestError: Error {
  case sensitive
}

private actor RecordingExternalIdentityCleanup: AuthExternalIdentityCleanup {
  private var recordedOwnerIDs: [String] = []

  func resetIdentity(ownerID: String) async {
    recordedOwnerIDs.append(ownerID)
  }

  func ownerIDs() -> [String] {
    recordedOwnerIDs
  }
}

private actor ScriptedDeletionRecovery: AccountDeletionRecoveryChecking {
  private let outcome: AccountDeletionRecoveryOutcome
  private let failClear: Bool
  private var checkedAuthUserIDs: [String?] = []
  private var cleared: [String] = []

  init(outcome: AccountDeletionRecoveryOutcome, failClear: Bool = false) {
    self.outcome = outcome
    self.failClear = failClear
  }

  func check(authUserID: String?) async -> AccountDeletionRecoveryOutcome {
    checkedAuthUserIDs.append(authUserID)
    return outcome
  }

  func clearDeletedReceipt(ownerProfileID: String) async throws {
    if failClear { throw AuthServiceError.unavailable }
    cleared.append(ownerProfileID)
  }

  func checkedIDs() -> [String?] { checkedAuthUserIDs }
  func clearedOwnerIDs() -> [String] { cleared }
}

private final class FakeAuthService: AuthService, @unchecked Sendable {
  var currentSessionValue: AuthSession?
  var signUpSession: AuthSession?
  var callbackSession: AuthSession?
  var signUpError: Error?
  var callbackError: Error?
  var signInError: Error?
  var signOutError: Error?
  var resetError: Error?
  var updatePasswordError: Error?
  var signUpCalls = 0
  var resetPasswordCalls = 0
  var resetRedirects: [URL] = []
  var updatePasswordCalls = 0
  var updatedPasswords: [String] = []
  var callbackCalls = 0
  var signOutCalls = 0
  var holdSignUp = false
  var holdResetPassword = false
  var holdUpdatePassword = false
  var holdCurrentSession = false
  var currentSessionStarted = false
  private var signUpContinuation: CheckedContinuation<Void, Never>?
  private var resetPasswordContinuation: CheckedContinuation<Void, Never>?
  private var updatePasswordContinuation: CheckedContinuation<Void, Never>?
  private var currentSessionContinuation: CheckedContinuation<Void, Never>?
  private let continuationLock = NSLock()
  private var signUpReleaseRequested = false
  private var resetPasswordReleaseRequested = false
  private var updatePasswordReleaseRequested = false
  private var currentSessionReleaseRequested = false

  init(
    currentSession: AuthSession? = nil,
    signUpSession: AuthSession? = nil,
    signUpError: Error? = nil,
    callbackSession: AuthSession? = nil,
    callbackError: Error? = nil,
    signInError: Error? = nil,
    signOutError: Error? = nil,
    resetError: Error? = nil,
    updatePasswordError: Error? = nil,
    holdSignUp: Bool = false,
    holdResetPassword: Bool = false,
    holdUpdatePassword: Bool = false,
    holdCurrentSession: Bool = false
  ) {
    self.currentSessionValue = currentSession
    self.signUpSession = signUpSession
    self.signUpError = signUpError
    self.callbackSession = callbackSession
    self.callbackError = callbackError
    self.signInError = signInError
    self.signOutError = signOutError
    self.resetError = resetError
    self.updatePasswordError = updatePasswordError
    self.holdSignUp = holdSignUp
    self.holdResetPassword = holdResetPassword
    self.holdUpdatePassword = holdUpdatePassword
    self.holdCurrentSession = holdCurrentSession
  }

  func currentSession() async throws -> AuthSession? {
    currentSessionStarted = true
    if holdCurrentSession {
      await withCheckedContinuation { continuation in
        continuationLock.lock()
        if currentSessionReleaseRequested {
          currentSessionReleaseRequested = false
          continuationLock.unlock()
          continuation.resume()
        } else {
          currentSessionContinuation = continuation
          continuationLock.unlock()
        }
      }
    }
    return currentSessionValue
  }

  func signUp(email: String, password: String, redirectTo: URL) async throws -> AuthSession? {
    signUpCalls += 1
    if holdSignUp {
      await withCheckedContinuation { continuation in
        continuationLock.lock()
        if signUpReleaseRequested {
          signUpReleaseRequested = false
          continuationLock.unlock()
          continuation.resume()
        } else {
          signUpContinuation = continuation
          continuationLock.unlock()
        }
      }
    }
    if let signUpError { throw signUpError }
    return signUpSession
  }

  func signIn(email: String, password: String) async throws -> AuthSession {
    if let signInError { throw signInError }
    return currentSessionValue ?? AuthSession(accessToken: "token")
  }

  func resetPasswordForEmail(email: String, redirectTo: URL) async throws {
    resetPasswordCalls += 1
    resetRedirects.append(redirectTo)
    if holdResetPassword {
      await withCheckedContinuation { continuation in
        continuationLock.lock()
        if resetPasswordReleaseRequested {
          resetPasswordReleaseRequested = false
          continuationLock.unlock()
          continuation.resume()
        } else {
          resetPasswordContinuation = continuation
          continuationLock.unlock()
        }
      }
    }
    if let resetError { throw resetError }
  }

  func updatePassword(_ password: String) async throws {
    updatePasswordCalls += 1
    updatedPasswords.append(password)
    if holdUpdatePassword {
      await withCheckedContinuation { continuation in
        continuationLock.lock()
        if updatePasswordReleaseRequested {
          updatePasswordReleaseRequested = false
          continuationLock.unlock()
          continuation.resume()
        } else {
          updatePasswordContinuation = continuation
          continuationLock.unlock()
        }
      }
    }
    if let updatePasswordError { throw updatePasswordError }
  }

  func handleCallback(_ url: URL) async throws -> AuthSession {
    callbackCalls += 1
    if let callbackError { throw callbackError }
    guard let callbackSession else { throw TestError.sensitive }
    return callbackSession
  }

  func signOut() async throws {
    signOutCalls += 1
    currentSessionValue = nil
    if let signOutError { throw signOutError }
  }

  func releaseSignUp() {
    continuationLock.lock()
    let continuation = signUpContinuation
    signUpContinuation = nil
    if continuation == nil {
      signUpReleaseRequested = true
    }
    continuationLock.unlock()
    if let continuation {
      continuation.resume()
    }
  }

  func releaseResetPassword() {
    continuationLock.lock()
    let continuation = resetPasswordContinuation
    resetPasswordContinuation = nil
    if continuation == nil {
      resetPasswordReleaseRequested = true
    }
    continuationLock.unlock()
    if let continuation {
      continuation.resume()
    }
  }

  func releaseUpdatePassword() {
    continuationLock.lock()
    let continuation = updatePasswordContinuation
    updatePasswordContinuation = nil
    if continuation == nil {
      updatePasswordReleaseRequested = true
    }
    continuationLock.unlock()
    if let continuation {
      continuation.resume()
    }
  }

  func releaseCurrentSession() {
    continuationLock.lock()
    let continuation = currentSessionContinuation
    currentSessionContinuation = nil
    if continuation == nil {
      currentSessionReleaseRequested = true
    }
    continuationLock.unlock()
    if let continuation {
      continuation.resume()
    }
  }
}

private final class FakeProfileAPI: ProfileAPI, @unchecked Sendable {
  var profile: UserProfile?
  var fetchError: Error?
  var verifyError: Error?
  var fetchCalls = 0
  var verifiedDates: [String] = []

  init(
    profile: UserProfile? = nil,
    fetchError: Error? = nil,
    verifyError: Error? = nil
  ) {
    self.profile = profile
    self.fetchError = fetchError
    self.verifyError = verifyError
  }

  func fetchProfile(accessToken: String) async throws -> UserProfile {
    fetchCalls += 1
    if let fetchError { throw fetchError }
    guard let profile else { throw TestError.sensitive }
    return profile
  }

  func verifyAge(accessToken: String, birthDate: String) async throws {
    if let verifyError { throw verifyError }
    verifiedDates.append(birthDate)
  }
}

private final class FakeHealthChecker: AuthStorageHealthChecking, @unchecked Sendable {
  let error: Error?

  init(error: Error? = nil) { self.error = error }

  func preflight() throws {
    if let error { throw error }
  }
}
