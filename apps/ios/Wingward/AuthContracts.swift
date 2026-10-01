import Foundation

enum AuthState: Equatable, Sendable {
  case booting
  case signedOut
  case passwordResetRequest
  case passwordResetRequested
  case passwordRecovery
  case awaitingEmailConfirmation(maskedEmail: String)
  case needsAgeVerification
  case authenticated(profile: UserProfile)
  case configurationError
  case recoverableError
}

enum AuthDiagnosticStage: String, Equatable, Sendable {
  case authSignIn
  case authSignUp
  case ageVerification
  case profileFetch
  case storage

  var reportPrefix: String {
    switch self {
    case .authSignIn: "SI"
    case .authSignUp: "SU"
    case .ageVerification: "AV"
    case .profileFetch: "PF"
    case .storage: "ST"
    }
  }
}

enum AuthDiagnosticSource: Equatable, Sendable {
  case authFailure(AuthDiagnosticAuthFailure)
  case httpStatus(Int)
  case transport
  case decode
  case storage
  case unknown
}

enum AuthDiagnosticAuthFailure: String, Equatable, Sendable {
  case invalidCredentials = "INVALID_CREDENTIALS"
  case emailAddressInvalid = "EMAIL_ADDRESS_INVALID"
  case emailNotConfirmed = "EMAIL_NOT_CONFIRMED"
  case captchaFailed = "CAPTCHA_FAILED"
  case emailProviderDisabled = "EMAIL_PROVIDER_DISABLED"
  case providerDisabled = "PROVIDER_DISABLED"
  case rateLimited = "RATE_LIMITED"
}

enum AuthDiagnosticCategory: String, Equatable, Sendable {
  case authFailure
  case httpStatus
  case transport
  case decode
  case storage
  case unknown
}

struct AuthDiagnostic: Equatable, Sendable {
  let stage: AuthDiagnosticStage
  let category: AuthDiagnosticCategory
  let authFailure: AuthDiagnosticAuthFailure?
  let httpStatus: Int?

  init(stage: AuthDiagnosticStage, source: AuthDiagnosticSource) {
    self.stage = stage

    switch source {
    case let .authFailure(failure):
      category = .authFailure
      authFailure = failure
      httpStatus = nil
    case let .httpStatus(status) where (100...599).contains(status):
      category = .httpStatus
      authFailure = nil
      httpStatus = status
    case .transport:
      category = .transport
      authFailure = nil
      httpStatus = nil
    case .decode:
      category = .decode
      authFailure = nil
      httpStatus = nil
    case .storage:
      category = .storage
      authFailure = nil
      httpStatus = nil
    case .httpStatus, .unknown:
      category = .unknown
      authFailure = nil
      httpStatus = nil
    }
  }

  var reportCode: String {
    switch category {
    case .authFailure:
      return "\(stage.reportPrefix)-AUTH-\(authFailure?.rawValue ?? "UNKNOWN")"
    case .httpStatus:
      return "\(stage.reportPrefix)-HTTP-\(httpStatus ?? 0)"
    case .transport:
      return "\(stage.reportPrefix)-NET"
    case .decode:
      return "\(stage.reportPrefix)-DATA"
    case .storage:
      return "\(stage.reportPrefix)-STORE"
    case .unknown:
      return "\(stage.reportPrefix)-UNKNOWN"
    }
  }

  static func from(error: Error, stage: AuthDiagnosticStage) -> AuthDiagnostic {
    let source: AuthDiagnosticSource
    if let serviceError = error as? AuthServiceError {
      switch serviceError {
      case let .diagnostic(source):
        return AuthDiagnostic(stage: stage, source: source)
      case .unavailable, .callbackIncomplete:
        source = .unknown
      }
    } else if let profileError = error as? ProfileAPIError {
      switch profileError {
      case .requestFailed:
        source = .unknown
      case let .requestFailedWithStatus(status):
        source = .httpStatus(status)
      }
    } else if error is KeychainStorageError {
      source = .storage
    } else if error is DecodingError {
      source = .decode
    } else if error is URLError {
      source = .transport
    } else {
      source = .unknown
    }
    return AuthDiagnostic(stage: stage, source: source)
  }
}

enum AuthDiagnosticPresentation {
  static let validationBundleIdentifier = "com.wingward.postmatchvalidation"
  static let ownerDebugBundleIdentifier = "com.wingward.app"
  static let ownerDebugLaunchArgument = "--wingward-auth-diagnostics"

  static func isEnabled(bundleIdentifier: String?, arguments: [String]) -> Bool {
    #if DEBUG
      if bundleIdentifier == validationBundleIdentifier {
        return true
      }
      return bundleIdentifier == ownerDebugBundleIdentifier
        && arguments.contains(ownerDebugLaunchArgument)
    #else
      return false
    #endif
  }
}

struct AuthSession: Equatable, Sendable {
  let accessToken: String
  let purpose: AuthSessionPurpose
  /// The Auth user ID from the SDK session, kept separately from the app's
  /// profile ID so a deletion receipt can only resume for its original user.
  let authUserID: String?

  init(accessToken: String, purpose: AuthSessionPurpose = .ordinary, authUserID: String? = nil) {
    self.accessToken = accessToken
    self.purpose = purpose
    self.authUserID = authUserID
  }
}

enum AuthSessionPurpose: Equatable, Sendable {
  case ordinary
  case passwordRecovery
}

enum CallbackURLPurpose: Equatable, Sendable {
  case normal
  case recovery
}

struct UserProfile: Codable, Equatable, Sendable {
  let id: String?
  let ageVerified: Bool
  /// The API's existing projection uses `onboarding_status`; keep the raw
  /// value so a missing/unknown status fails closed at navigation gates.
  let onboardingStatus: String?

  var onboardingCompleted: Bool {
    onboardingStatus == "confirmed"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case ageVerified = "age_verified"
    case onboardingStatus = "onboarding_status"
    case onboardingCompleted = "onboarding_completed"
  }

  init(id: String?, ageVerified: Bool, onboardingStatus: String? = nil) {
    self.id = id
    self.ageVerified = ageVerified
    self.onboardingStatus = onboardingStatus
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id)
    ageVerified = try container.decode(Bool.self, forKey: .ageVerified)
    if let status = try container.decodeIfPresent(String.self, forKey: .onboardingStatus) {
      onboardingStatus = status
    } else if let completed = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) {
      onboardingStatus = completed ? "confirmed" : "not_started"
    } else {
      onboardingStatus = nil
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(id, forKey: .id)
    try container.encode(ageVerified, forKey: .ageVerified)
    try container.encodeIfPresent(onboardingStatus, forKey: .onboardingStatus)
  }

  static let fixture = UserProfile(
    id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    ageVerified: true,
    onboardingStatus: "confirmed"
  )
}

enum AuthServiceError: Error, Equatable {
  case unavailable
  case callbackIncomplete
  case diagnostic(AuthDiagnosticSource)
}

protocol AuthService: Sendable {
  func currentSession() async throws -> AuthSession?
  func signUp(email: String, password: String, redirectTo: URL) async throws -> AuthSession?
  func signIn(email: String, password: String) async throws -> AuthSession
  func resetPasswordForEmail(email: String, redirectTo: URL) async throws
  func updatePassword(_ password: String) async throws
  func handleCallback(_ url: URL) async throws -> AuthSession
  func signOut() async throws
}

protocol ProfileAPI: Sendable {
  func fetchProfile(accessToken: String) async throws -> UserProfile
  func verifyAge(accessToken: String, birthDate: String) async throws
}

protocol AuthStorageHealthChecking: Sendable {
  func preflight() throws
}

enum InputValidationIssue: Error, Equatable, Sendable {
  case emailRequired
  case emailInvalid
  case passwordRequired
  case passwordTooShort
  case passwordConfirmationRequired
  case passwordsDoNotMatch
  case birthDateInvalid
  case under18

  var userMessage: String {
    switch self {
    case .emailRequired: "Enter your email address."
    case .emailInvalid: "Enter a valid email address."
    case .passwordRequired: "Enter a password."
    case .passwordTooShort: "Use at least 8 characters for your password."
    case .passwordConfirmationRequired: "Confirm your password."
    case .passwordsDoNotMatch: "The passwords do not match."
    case .birthDateInvalid: "Enter a valid birth date."
    case .under18: "You must be at least 18 to use Wingward."
    }
  }
}

struct SignUpForm: Equatable, Sendable {
  let email: String
  let password: String
  let passwordConfirmation: String
  let birthDate: Date

  func validated(now: Date = Date()) -> Result<ValidatedSignUp, InputValidationIssue> {
    let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedEmail.isEmpty else { return .failure(.emailRequired) }
    guard EmailValidator.looksLikeEmail(trimmedEmail) else { return .failure(.emailInvalid) }
    guard !password.isEmpty else { return .failure(.passwordRequired) }
    guard password.count >= 8 else { return .failure(.passwordTooShort) }
    guard !passwordConfirmation.isEmpty else {
      return .failure(.passwordConfirmationRequired)
    }
    guard password == passwordConfirmation else { return .failure(.passwordsDoNotMatch) }
    guard let normalizedDate = BirthDateValidator.validatedDate(birthDate, now: now) else {
      return .failure(.birthDateInvalid)
    }
    guard BirthDateValidator.isAtLeast18(normalizedDate, on: now) else {
      return .failure(.under18)
    }

    return .success(
      ValidatedSignUp(
        email: trimmedEmail,
        password: password,
        birthDate: normalizedDate
      )
    )
  }
}

struct ValidatedSignUp: Equatable, Sendable {
  let email: String
  let password: String
  let birthDate: Date
}

struct PasswordResetRequestForm: Equatable, Sendable {
  let email: String

  func validated() -> Result<ValidatedPasswordResetRequest, InputValidationIssue> {
    let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedEmail.isEmpty else { return .failure(.emailRequired) }
    guard EmailValidator.looksLikeEmail(trimmedEmail) else { return .failure(.emailInvalid) }
    return .success(ValidatedPasswordResetRequest(email: trimmedEmail))
  }
}

struct ValidatedPasswordResetRequest: Equatable, Sendable {
  let email: String
}

struct PasswordResetForm: Equatable, Sendable {
  let password: String
  let passwordConfirmation: String

  func validated() -> Result<ValidatedPasswordReset, InputValidationIssue> {
    guard !password.isEmpty else { return .failure(.passwordRequired) }
    guard password.count >= 8 else { return .failure(.passwordTooShort) }
    guard !passwordConfirmation.isEmpty else {
      return .failure(.passwordConfirmationRequired)
    }
    guard password == passwordConfirmation else { return .failure(.passwordsDoNotMatch) }
    return .success(ValidatedPasswordReset(password: password))
  }
}

struct ValidatedPasswordReset: Equatable, Sendable {
  let password: String
}

private enum EmailValidator {
  static func looksLikeEmail(_ value: String) -> Bool {
    let pieces = value.split(separator: "@", omittingEmptySubsequences: false)
    guard pieces.count == 2 else { return false }
    return !pieces[0].isEmpty && pieces[1].contains(".") && !pieces[1].hasPrefix(".")
      && !pieces[1].hasSuffix(".")
  }
}

enum BirthDateValidator {
  static var utcGregorianCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }

  static func validatedDate(_ date: Date, now: Date) -> Date? {
    let calendar = utcGregorianCalendar
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    guard let exactDate = exactDate(year: components.year, month: components.month, day: components.day)
    else { return nil }
    let today = calendar.startOfDay(for: now)
    guard exactDate <= today else { return nil }
    guard let year = components.year, year >= 1900 else { return nil }
    return exactDate
  }

  static func exactDate(year: Int?, month: Int?, day: Int?) -> Date? {
    guard let year, let month, let day else { return nil }
    var components = DateComponents()
    components.calendar = utcGregorianCalendar
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = year
    components.month = month
    components.day = day
    guard let date = utcGregorianCalendar.date(from: components) else { return nil }
    let result = utcGregorianCalendar.dateComponents([.year, .month, .day], from: date)
    guard result.year == year, result.month == month, result.day == day else { return nil }
    return date
  }

  static func isAtLeast18(_ birthDate: Date, on now: Date) -> Bool {
    let calendar = utcGregorianCalendar
    let today = calendar.startOfDay(for: now)
    let birthComponents = calendar.dateComponents([.year, .month, .day], from: birthDate)
    guard
      let birthYear = birthComponents.year,
      let birthMonth = birthComponents.month,
      let birthDay = birthComponents.day
    else { return false }

    let anniversaryYear = birthYear + 18
    var eighteenthBirthday = exactDate(
      year: anniversaryYear,
      month: birthMonth,
      day: birthDay
    )
    if eighteenthBirthday == nil, birthMonth == 2, birthDay == 29 {
      // The server treats a Feb 29 birthday as reaching the anniversary on
      // March 1 when the anniversary year is not a leap year.
      eighteenthBirthday = exactDate(year: anniversaryYear, month: 3, day: 1)
    }
    guard let eighteenthBirthday else { return false }
    return eighteenthBirthday <= today
  }

  static func formatted(_ date: Date) -> String? {
    let components = utcGregorianCalendar.dateComponents([.year, .month, .day], from: date)
    guard let year = components.year, let month = components.month, let day = components.day
    else { return nil }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }
}

extension Result {
  var value: Success? {
    guard case let .success(value) = self else { return nil }
    return value
  }

  var failure: Failure? {
    guard case let .failure(error) = self else { return nil }
    return error
  }
}

enum CallbackURLPolicy {
  static let scheme = "wingward"
  static let host = "login-callback"
  static let callbackURL = URL(string: "wingward://login-callback/")!
  static let recoveryCallbackURL = URL(string: "wingward://login-callback/recovery")!

  static func purpose(for url: URL) -> CallbackURLPurpose? {
    guard
      url.scheme == scheme,
      url.host == host,
      url.fragment == nil,
      url.user == nil,
      url.password == nil,
      url.port == nil
    else { return nil }

    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }

    switch components.percentEncodedPath {
    case "/": return .normal
    case "/recovery": return .recovery
    default: return nil
    }
  }

  static func isAllowed(_ url: URL) -> Bool {
    purpose(for: url) != nil
  }

  static func isRecovery(_ url: URL) -> Bool {
    purpose(for: url) == .recovery
  }

  static func hasPKCECode(_ url: URL) -> Bool {
    guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return false }
    let codes = queryItems.filter { $0.name == "code" }
    return codes.count == 1 && !(codes[0].value?.isEmpty ?? true)
  }
}

func maskedEmail(_ email: String) -> String {
  let pieces = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
  guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else {
    return "your email address"
  }
  let local = String(pieces[0])
  let visiblePrefix = String(local.prefix(1))
  let maskCount = max(2, min(5, local.count))
  return "\(visiblePrefix)\(String(repeating: "•", count: maskCount))@\(pieces[1])"
}

struct UnavailableAuthService: AuthService {
  func currentSession() async throws -> AuthSession? { throw AuthServiceError.unavailable }
  func signUp(email: String, password: String, redirectTo: URL) async throws -> AuthSession? {
    throw AuthServiceError.unavailable
  }
  func signIn(email: String, password: String) async throws -> AuthSession {
    throw AuthServiceError.unavailable
  }
  func resetPasswordForEmail(email: String, redirectTo: URL) async throws {
    throw AuthServiceError.unavailable
  }
  func updatePassword(_ password: String) async throws {
    throw AuthServiceError.unavailable
  }
  func handleCallback(_ url: URL) async throws -> AuthSession {
    throw AuthServiceError.unavailable
  }
  func signOut() async throws { throw AuthServiceError.unavailable }
}

struct UnavailableProfileAPI: ProfileAPI {
  func fetchProfile(accessToken: String) async throws -> UserProfile {
    throw AuthServiceError.unavailable
  }
  func verifyAge(accessToken: String, birthDate: String) async throws {
    throw AuthServiceError.unavailable
  }
}

struct AlwaysHealthyStorageHealthChecker: AuthStorageHealthChecking {
  func preflight() throws {}
}
