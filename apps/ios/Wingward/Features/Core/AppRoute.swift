import Foundation

/// These routes are the complete set of destinations that feature code may
/// request.  External strings are converted to this enum only by
/// `AppDeepLinkParser`.
enum AppRoute: Hashable, Sendable {
  case authentication
  case ageGate
  case onboarding(OnboardingRoute)
  case matches
  case matchDetail(UUID)
  case foxConversation(UUID)
  case partnerFoxChat(UUID)
  case directChat(UUID)
  case settings
  case report(targetID: UUID, context: ReportContext)
  case paywall(PaywallSource)
  case meetup(UUID)
  case meetupVerification(UUID)
  case meetupFeedback(UUID)
  case meetupResult(UUID)
  case foxConversationResult(UUID)
  case chatRequest(UUID)
  case foxLearned(UUID)
  case availability
  case notificationLanding(UUID)
}

/// Onboarding destinations are intentionally closed even though the current
/// server contract does not expose a deep-link format for them.
enum OnboardingRoute: Hashable, Sendable {
  case welcome
  case quiz
  case profile
  case review
}

enum ReportContext: String, Hashable, Sendable, Codable, CaseIterable {
  case match
  case foxConversation = "fox_conversation"
  case partnerFoxChat = "partner_fox_chat"
  case directChat = "direct_chat"
  case meetup
}

/// A paywall can be presented only for a closed set of quota exhaustion points.
/// Meet-intent is deliberately absent: it is free and unlimited.
enum PaywallSource: String, Hashable, Sendable, Codable, CaseIterable {
  case foxConversation = "fox_conversation"
  case meetupArrange = "meetup_arrange"
  case arrangeRetry = "arrange_retry"
}

enum ServerEntitlement: Equatable, Sendable {
  case unknown
  case inactive
  case active
}

struct AppGateContext: Equatable, Sendable {
  let configurationHealthy: Bool
  let storageHealthy: Bool
  let isAuthenticated: Bool
  let ageVerified: Bool
  let onboardingCompleted: Bool
  let entitlement: ServerEntitlement
  let requestedRoute: AppRoute
  let premiumSource: PaywallSource?

  init(
    configurationHealthy: Bool = true,
    storageHealthy: Bool = true,
    isAuthenticated: Bool,
    ageVerified: Bool = false,
    onboardingCompleted: Bool = false,
    entitlement: ServerEntitlement = .unknown,
    requestedRoute: AppRoute = .matches,
    premiumSource: PaywallSource? = nil
  ) {
    self.configurationHealthy = configurationHealthy
    self.storageHealthy = storageHealthy
    self.isAuthenticated = isAuthenticated
    self.ageVerified = ageVerified
    self.onboardingCompleted = onboardingCompleted
    self.entitlement = entitlement
    self.requestedRoute = requestedRoute
    self.premiumSource = premiumSource
  }
}

enum AppGateDecision: Equatable, Sendable {
  case configurationError
  case storageError
  case authenticationRequired
  case ageVerificationRequired
  case onboardingRequired
  case entitlementRequired(PaywallSource)
  case route(AppRoute)
}

/// Resolves gates in the contract's fixed order.  The resolver is pure so it
/// can be exercised independently of SwiftUI and server state.
enum AppGateResolver {
  static func resolve(_ context: AppGateContext) -> AppGateDecision {
    if !context.configurationHealthy {
      return .configurationError
    }
    if !context.storageHealthy {
      return .storageError
    }
    if !context.isAuthenticated {
      return .authenticationRequired
    }
    if !context.ageVerified {
      return .ageVerificationRequired
    }
    if !context.onboardingCompleted {
      return .onboardingRequired
    }

    // A paywall is a feature gate, not an entitlement claim.  Only a
    // server-confirmed active entitlement proceeds; unknown and inactive both
    // fail closed.  A caller without a premium source is not charged here.
    if let source = context.premiumSource,
      context.entitlement != .active,
      context.requestedRoute != .paywall(source)
    {
      return .entitlementRequired(source)
    }
    return .route(context.requestedRoute)
  }
}

/// Converts only the server's allowlisted URLs into routes.  Notification
/// payloads should first be turned into a URL by the notification client and
/// then pass through this parser; payload text never names a SwiftUI view
/// directly.
enum AppDeepLinkParser {
  static let scheme = "wingward"

  static func parse(_ rawValue: String) -> AppRoute? {
    guard let url = URL(string: rawValue) else { return nil }
    return parse(url)
  }

  static func parse(_ url: URL) -> AppRoute? {
    guard
      url.scheme == scheme,
      url.user == nil,
      url.password == nil,
      url.port == nil,
      url.query == nil,
      url.fragment == nil,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      !components.percentEncodedPath.contains("%")
    else {
      return nil
    }

    let host = url.host
    let segments = components.path.split(separator: "/", omittingEmptySubsequences: true)

    switch host {
    case "meetup":
      guard let first = segments.first else { return nil }
      guard let id = uuid(from: String(first)) else { return nil }
      if segments.count == 1 {
        guard components.path == "/\(first)" else { return nil }
        return .meetup(id)
      }
      guard segments.count == 2, components.path == "/\(first)/\(segments[1])" else {
        return nil
      }
      switch segments[1] {
      case "verify": return .meetupVerification(id)
      case "feedback": return .meetupFeedback(id)
      case "result": return .meetupResult(id)
      default: return nil
      }
    case "chat-requests":
      guard segments.count == 1,
        components.path == "/\(segments[0])",
        let id = uuid(from: String(segments[0]))
      else { return nil }
      return .chatRequest(id)
    case "match":
      guard segments.count == 2,
        components.path == "/\(segments[0])/\(segments[1])",
        let id = uuid(from: String(segments[0]))
      else { return nil }
      switch segments[1] {
      case "fox-result": return .foxConversationResult(id)
      case "fox-learned": return .foxLearned(id)
      default: return nil
      }
    case "availability":
      guard components.path.isEmpty, segments.isEmpty else { return nil }
      return .availability
    default:
      return nil
    }
  }

  private static func uuid(from rawValue: String) -> UUID? {
    try? APIDTOValidation.requireUUID(rawValue)
  }
}
