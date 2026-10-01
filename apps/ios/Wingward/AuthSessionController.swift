import Foundation
import Observation

protocol AuthExternalIdentityCleanup: Sendable {
  func resetIdentity(ownerID: String) async
}

struct NoopAuthExternalIdentityCleanup: AuthExternalIdentityCleanup, Sendable {
  func resetIdentity(ownerID: String) async {}
}

@MainActor
@Observable
final class AuthSessionController {
  static let genericErrorMessage = "We couldn't complete that request. Try again."

  private(set) var state: AuthState
  private(set) var isSubmitting = false
  private(set) var lastInputError: InputValidationIssue?
  private(set) var hasPasswordUpdateError = false
  private(set) var lastDiagnostic: AuthDiagnostic?

  private let authService: any AuthService
  private let profileAPI: any ProfileAPI
  private let storageHealthChecker: any AuthStorageHealthChecking
  private let externalIdentityCleanup: any AuthExternalIdentityCleanup
  private let deletionRecovery: (any AccountDeletionRecoveryChecking)?
  private var hasConsumedRecoveryCallback = false
  private var pendingCallbacks: [URL] = []
  private var isDrainingPendingCallbacks = false

  init(
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    storageHealthChecker: any AuthStorageHealthChecking,
    externalIdentityCleanup: any AuthExternalIdentityCleanup = NoopAuthExternalIdentityCleanup(),
    deletionRecovery: (any AccountDeletionRecoveryChecking)? = nil,
    initialState: AuthState = .booting
  ) {
    self.authService = authService
    self.profileAPI = profileAPI
    self.storageHealthChecker = storageHealthChecker
    self.externalIdentityCleanup = externalIdentityCleanup
    self.deletionRecovery = deletionRecovery
    self.state = initialState
  }

  static func configurationFailure() -> AuthSessionController {
    AuthSessionController(
      authService: UnavailableAuthService(),
      profileAPI: UnavailableProfileAPI(),
      storageHealthChecker: AlwaysHealthyStorageHealthChecker(),
      initialState: .configurationError
    )
  }

  #if DEBUG
    static func preview(state: AuthState) -> AuthSessionController {
      AuthSessionController(
        authService: UnavailableAuthService(),
        profileAPI: UnavailableProfileAPI(),
        storageHealthChecker: AlwaysHealthyStorageHealthChecker(),
        initialState: state
      )
    }
  #endif

  func bootstrap() async {
    guard state == .booting, !isSubmitting else { return }
    lastDiagnostic = nil

    do {
      // This check must run before asking the SDK for its session. The SDK's
      // session storage intentionally turns storage errors into a nil session.
      do {
        try storageHealthChecker.preflight()
      } catch {
        recordDiagnostic(error, stage: .storage)
        state = .recoverableError
        return
      }
      guard let session = try await authService.currentSession() else {
        if let deletionRecovery {
          switch await deletionRecovery.check(authUserID: nil) {
          case let .deleted(ownerProfileID, _):
            await resetExternalIdentity(ownerID: ownerProfileID)
            do {
              try await deletionRecovery.clearDeletedReceipt(ownerProfileID: ownerProfileID)
            } catch {
              state = .recoverableError
              return
            }
          case .unavailable:
            state = .recoverableError
            return
          case .none, .pending:
            break
          }
        }
        state = .signedOut
        await drainPendingCallbacks()
        return
      }

      if session.purpose == .passwordRecovery {
        // A recovery-purpose marker survives a cold start, but it is never
        // sufficient on its own: AuthService only returns this purpose with a
        // real persisted Supabase session.
        hasConsumedRecoveryCallback = true
        lastInputError = nil
        hasPasswordUpdateError = false
        state = .passwordRecovery
        await drainPendingCallbacks()
        return
      }

      // A recovery callback delivered during launch takes precedence over an
      // ordinary persisted session. Do not fetch a profile or briefly enter an
      // authenticated state before the recovery exchange has completed.
      if pendingCallbacks.contains(where: { CallbackURLPolicy.isRecovery($0) }) {
        await drainPendingCallbacks()
        return
      }

      if let deletionRecovery, let authUserID = session.authUserID {
        if case let .deleted(ownerProfileID, recoveredAuthUserID) = await deletionRecovery.check(authUserID: authUserID),
          recoveredAuthUserID == authUserID
        {
          // The public receipt lookup is authoritative only for the same Auth
          // identity persisted with the receipt. Preserve the proof until
          // local sign-out succeeds so a retry can recover after interruption.
          await resetExternalIdentity(ownerID: ownerProfileID)
          do {
            try await authService.signOut()
            try await deletionRecovery.clearDeletedReceipt(ownerProfileID: ownerProfileID)
            hasConsumedRecoveryCallback = false
            state = .signedOut
          } catch {
            state = .recoverableError
          }
          await drainPendingCallbacks()
          return
        }
      }

      await refreshProfile(for: session)
      await drainPendingCallbacks()
    } catch {
      state = .recoverableError
    }
  }

  func retry() async {
    guard state == .recoverableError, !isSubmitting else { return }
    lastDiagnostic = nil
    state = .booting
    await bootstrap()
  }

  func signUp(form: SignUpForm, now: Date = Date()) async {
    guard !isSubmitting else { return }
    lastDiagnostic = nil
    let validation = form.validated(now: now)
    guard case let .success(validated) = validation else {
      if case let .failure(issue) = validation { lastInputError = issue }
      return
    }

    lastInputError = nil
    isSubmitting = true
    defer { isSubmitting = false }

    let session: AuthSession?
    do {
      session = try await authService.signUp(
        email: validated.email,
        password: validated.password,
        redirectTo: CallbackURLPolicy.callbackURL
      )
    } catch {
      recordDiagnostic(error, stage: .authSignUp)
      state = .recoverableError
      return
    }
    guard let session else {
      state = .awaitingEmailConfirmation(maskedEmail: maskedEmail(validated.email))
      return
    }

    // The date is held only in this call's memory. It is never passed to
    // Supabase Auth metadata or written to local storage.
    guard let birthDate = BirthDateValidator.formatted(validated.birthDate) else {
      lastDiagnostic = AuthDiagnostic(stage: .authSignUp, source: .unknown)
      state = .recoverableError
      return
    }
    do {
      try await profileAPI.verifyAge(accessToken: session.accessToken, birthDate: birthDate)
    } catch {
      recordDiagnostic(error, stage: .ageVerification)
      state = .recoverableError
      return
    }
    await refreshProfile(for: session)
  }

  func signIn(email: String, password: String) async {
    guard !isSubmitting else { return }
    lastDiagnostic = nil
    let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedEmail.isEmpty, !password.isEmpty else {
      state = .recoverableError
      return
    }

    lastInputError = nil
    isSubmitting = true
    defer { isSubmitting = false }

    let session: AuthSession
    do {
      session = try await authService.signIn(email: trimmedEmail, password: password)
    } catch {
      // Deliberately collapse every auth failure to the same state/message so
      // an account's existence cannot be inferred from the UI.
      recordDiagnostic(error, stage: .authSignIn)
      state = .recoverableError
      return
    }
    await refreshProfile(for: session)
  }

  func beginPasswordResetRequest() {
    guard !isSubmitting, state == .signedOut else { return }
    lastInputError = nil
    hasPasswordUpdateError = false
    hasConsumedRecoveryCallback = false
    state = .passwordResetRequest
  }

  func resetPassword(email: String) async {
    guard !isSubmitting, state == .passwordResetRequest else { return }

    let validation = PasswordResetRequestForm(email: email).validated()
    guard case let .success(validated) = validation else {
      if case let .failure(issue) = validation { lastInputError = issue }
      return
    }

    lastInputError = nil
    isSubmitting = true
    defer { isSubmitting = false }

    do {
      try await authService.resetPasswordForEmail(
        email: validated.email,
        redirectTo: CallbackURLPolicy.recoveryCallbackURL
      )
    } catch {
      // Deliberately collapse backend rejection, throttling, transport, and
      // configuration failures into the same result. A different screen here
      // could disclose whether a submitted address belongs to an account.
    }
    // Every locally valid address reaches the same completion state.
    state = .passwordResetRequested
  }

  func returnToSignedOut() {
    guard !isSubmitting else { return }
    guard state == .passwordResetRequest || state == .passwordResetRequested else { return }
    lastInputError = nil
    hasPasswordUpdateError = false
    hasConsumedRecoveryCallback = false
    state = .signedOut
  }

  func updatePassword(form: PasswordResetForm) async {
    guard !isSubmitting, state == .passwordRecovery else { return }

    let validation = form.validated()
    guard case let .success(validated) = validation else {
      if case let .failure(issue) = validation { lastInputError = issue }
      return
    }

    lastInputError = nil
    hasPasswordUpdateError = false
    isSubmitting = true
    defer { isSubmitting = false }

    do {
      try await authService.updatePassword(validated.password)
    } catch {
      // Keep the recovery state available for a retry, but never surface the
      // SDK error or any credential-bearing response to the UI.
      hasPasswordUpdateError = true
      state = .passwordRecovery
      return
    }

    do {
      // signOut keeps the existing fail-closed ordering: the local Keychain
      // session is removed even when the remote sign-out request fails.
      try await authService.signOut()
      hasConsumedRecoveryCallback = false
      state = .signedOut
    } catch {
      // Do not turn a failed local teardown into a signed-out state. The
      // existing sign-out path remains the source of truth for this failure.
      state = .recoverableError
    }
  }

  func handleCallback(_ url: URL) async {
    guard let purpose = CallbackURLPolicy.purpose(for: url) else {
      state = .recoverableError
      return
    }

    // The system can deliver a deep link before the app's .task starts. Keep
    // every valid callback behind bootstrap so storage health is checked first.
    if state == .booting, !isDrainingPendingCallbacks {
      enqueueCallback(url)
      return
    }

    guard !isSubmitting else { return }

    if purpose == .recovery {
      guard CallbackURLPolicy.hasPKCECode(url) else {
        state = .recoverableError
        return
      }

      // A recovery callback is one-time for this controller instance. Mark it
      // before exchanging the code so concurrent or duplicate callbacks cannot
      // enter the password screen or consume a second session.
      guard !hasConsumedRecoveryCallback else { return }
      hasConsumedRecoveryCallback = true
      lastInputError = nil
      hasPasswordUpdateError = false

      isSubmitting = true
      defer { isSubmitting = false }

      do {
        let session = try await authService.handleCallback(url)
        guard session.purpose == .passwordRecovery else {
          state = .recoverableError
          return
        }
        state = .passwordRecovery
      } catch {
        state = .recoverableError
      }
      return
    }

    // Do not let a later normal auth callback replace an active recovery flow.
    guard state != .passwordRecovery else { return }
    guard CallbackURLPolicy.hasPKCECode(url) else {
      state = .recoverableError
      return
    }

    isSubmitting = true
    defer { isSubmitting = false }

    do {
      let session = try await authService.handleCallback(url)
      guard session.purpose == .ordinary else {
        state = .recoverableError
        return
      }
      await refreshProfile(for: session)
    } catch {
      state = .recoverableError
    }
  }

  func submitAgeVerification(birthDate: Date, now: Date = Date()) async {
    guard !isSubmitting, state == .needsAgeVerification else { return }
    lastDiagnostic = nil
    guard let exactDate = BirthDateValidator.validatedDate(birthDate, now: now) else {
      lastInputError = .birthDateInvalid
      return
    }
    guard BirthDateValidator.isAtLeast18(exactDate, on: now) else {
      lastInputError = .under18
      return
    }
    guard let dateString = BirthDateValidator.formatted(exactDate) else {
      lastInputError = .birthDateInvalid
      return
    }

    lastInputError = nil
    isSubmitting = true
    defer { isSubmitting = false }

    let session: AuthSession?
    do {
      session = try await authService.currentSession()
    } catch {
      state = .recoverableError
      return
    }
    guard let session else {
      state = .recoverableError
      return
    }
    do {
      try await profileAPI.verifyAge(accessToken: session.accessToken, birthDate: dateString)
    } catch {
      recordDiagnostic(error, stage: .ageVerification)
      state = .recoverableError
      return
    }
    await refreshProfile(for: session)
  }

  func leaveEmailConfirmation() {
    guard !isSubmitting, case .awaitingEmailConfirmation = state else { return }
    lastInputError = nil
    state = .signedOut
  }

  func signOut() async {
    await performSignOut(force: false)
  }

  /// Refreshes the server-owned session/profile projection after an onboarding
  /// flow confirms a profile. The expected owner and ordinary session are
  /// rechecked before and after the request so a stale voice screen cannot
  /// publish a different account's onboarding state.
  @discardableResult
  func refreshProfileAfterOnboarding(ownerID expectedOwnerID: String) async -> Bool {
    guard !isSubmitting,
      case let .authenticated(currentProfile) = state,
      currentProfile.id == expectedOwnerID,
      !expectedOwnerID.isEmpty
    else { return false }

    isSubmitting = true
    defer { isSubmitting = false }

    let session: AuthSession?
    do {
      session = try await authService.currentSession()
    } catch {
      return false
    }
    guard let session, session.purpose == .ordinary, !session.accessToken.isEmpty else {
      return false
    }

    do {
      let profile = try await profileAPI.fetchProfile(accessToken: session.accessToken)
      guard !Task.isCancelled,
        profile.id == expectedOwnerID,
        profile.ageVerified,
        profile.onboardingCompleted
      else {
        return false
      }
      state = .authenticated(profile: profile)
      return true
    } catch {
      return false
    }
  }

  private func performSignOut(force: Bool) async {
    guard force || !isSubmitting else { return }
    let ownerID = authenticatedOwnerID()
    isSubmitting = true
    defer { isSubmitting = false }
    // Invalidate the vendor identity before tearing down auth. This keeps a
    // slow or failed auth sign-out from leaving the previous owner active in a
    // process-wide billing SDK singleton.
    await resetExternalIdentity(ownerID: ownerID)
    do {
      try await authService.signOut()
      hasConsumedRecoveryCallback = false
      state = .signedOut
    } catch {
      state = .recoverableError
    }
  }

  private func authenticatedOwnerID() -> String? {
    guard case let .authenticated(profile) = state,
      let ownerID = profile.id,
      !ownerID.isEmpty
    else { return nil }
    return ownerID
  }

  private func resetExternalIdentity(ownerID: String?) async {
    guard let ownerID else { return }
    await externalIdentityCleanup.resetIdentity(ownerID: ownerID)
  }

  private func refreshProfile(for session: AuthSession) async {
    do {
      let profile = try await profileAPI.fetchProfile(accessToken: session.accessToken)
      state = profile.ageVerified ? .authenticated(profile: profile) : .needsAgeVerification
    } catch {
      // Missing, malformed, or failed profile responses are not an anonymous
      // session. Fail closed into a recoverable state.
      recordDiagnostic(error, stage: .profileFetch)
      state = .recoverableError
    }
  }

  private func recordDiagnostic(_ error: Error, stage: AuthDiagnosticStage) {
    lastDiagnostic = AuthDiagnostic.from(error: error, stage: stage)
  }

  private func enqueueCallback(_ url: URL) {
    // The app only needs the small number of URLs delivered during one cold
    // start. Bound this queue so a hostile custom-URL flood cannot grow memory
    // while Keychain/session bootstrap is suspended.
    guard pendingCallbacks.count < 4, !pendingCallbacks.contains(url) else { return }
    pendingCallbacks.append(url)
  }

  private func drainPendingCallbacks() async {
    guard !pendingCallbacks.isEmpty else { return }
    let callbacks = pendingCallbacks
    pendingCallbacks.removeAll()
    isDrainingPendingCallbacks = true
    defer { isDrainingPendingCallbacks = false }

    // Recovery is a privileged, purpose-specific flow. Process it first and
    // never continue into normal callbacks once it has succeeded or failed.
    let recoveryCallbacks = callbacks.filter { CallbackURLPolicy.isRecovery($0) }
    let normalCallbacks = callbacks.filter { !CallbackURLPolicy.isRecovery($0) }
    for callback in recoveryCallbacks {
      await handleCallback(callback)
    }

    guard state != .passwordRecovery, state != .recoverableError else { return }
    for callback in normalCallbacks {
      guard state != .recoverableError else { return }
      await handleCallback(callback)
    }
  }
}

// Account deletion is allowed to clear the local session only after the
// server has acknowledged durable deletion.  The safety module owns that
// ordering; this adapter keeps the auth controller as the single teardown
// boundary.
extension AuthSessionController: SessionCleanup {
  func clearAfterServerDeletion(ownerID: String) async {
    // A deletion response is bound to the owner captured by the coordinator.
    // Never clear a later user's session, and never interrupt an in-flight auth
    // operation with a forced sign-out. Waiting keeps the coordinator in its
    // deleting state instead of claiming local cleanup completed early.
    while isSubmitting {
      do {
        try await Task.sleep(nanoseconds: 50_000_000)
      } catch {
        return
      }
    }
    guard case let .authenticated(profile) = state,
      profile.id == ownerID,
      !isSubmitting
    else { return }
    await performSignOut(force: false)
    if state == .signedOut {
      try? await deletionRecovery?.clearDeletedReceipt(ownerProfileID: ownerID)
    }
  }
}
