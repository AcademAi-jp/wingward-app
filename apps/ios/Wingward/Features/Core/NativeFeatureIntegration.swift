import SwiftUI

/// Shared navigation seam for the remaining native features.
///
/// Feature modules own their DTOs, stores, and API factories.  The app only
/// receives owner-bound view closures, which prevents a view from being
/// created with an arbitrary account identifier or an unverified client.
struct NativeFeatureIntegration {
  typealias OwnerViewFactory = (String, NativeFeatureCallbacks) -> AnyView?
  typealias MatchViewFactory = (String, UUID, NativeFeatureCallbacks) -> AnyView?
  typealias MatchRequestViewFactory = (String, UUID, NativeFeatureCallbacks) -> AnyView?
  typealias MatchSafetyViewFactory = (String, UUID, ReportContext, NativeFeatureCallbacks) -> AnyView?
  /// Route destinations receive the same owner-scoped callback seam as the
  /// settings/matches feature factories.  Deep-link and notification routes
  /// can therefore expose report/block without inventing a partner user ID
  /// in the route layer.
  typealias RouteViewFactory = @MainActor (String, AppRoute, NativeFeatureCallbacks) -> AnyView?
  typealias SafetyViewFactory = (String, UUID, ReportContext, UUID?) -> AnyView?
  /// Owner-bound API access for match-scoped conversation surfaces. This is
  /// intentionally separate from the owner-wide DirectChats view factory so
  /// a production view can ask the existing store to resolve one match room
  /// without constructing a client for another account.
  typealias DirectChatsAPIFactory = (String) -> (any DirectChatsAPI)?
  typealias NotificationSeenAPIFactory = (String) -> (any WingwardNotificationSeenAPI)?

  let directChats: OwnerViewFactory?
  let directChatsAPI: DirectChatsAPIFactory?
  let voiceProfile: OwnerViewFactory?
  let profilePhoto: OwnerViewFactory?
  let profilePhotoAPIFactory: (any ProfilePhotoAPIFactory)?
  let meetups: OwnerViewFactory?
  let meetupForMatch: MatchViewFactory?
  let chatRequestForMatch: MatchRequestViewFactory?
  let billing: OwnerViewFactory?
  let accountSafety: OwnerViewFactory?
  let notificationSeenAPIFactory: NotificationSeenAPIFactory?
  let route: RouteViewFactory?
  let safetyAction: SafetyViewFactory?
  let matchSafety: MatchSafetyViewFactory?
  let isDebugFixture: Bool

  init(
    directChats: OwnerViewFactory? = nil,
    directChatsAPI: DirectChatsAPIFactory? = nil,
    voiceProfile: OwnerViewFactory? = nil,
    profilePhoto: OwnerViewFactory? = nil,
    profilePhotoAPIFactory: (any ProfilePhotoAPIFactory)? = nil,
    meetups: OwnerViewFactory? = nil,
    meetupForMatch: MatchViewFactory? = nil,
    chatRequestForMatch: MatchRequestViewFactory? = nil,
    billing: OwnerViewFactory? = nil,
    accountSafety: OwnerViewFactory? = nil,
    notificationSeenAPIFactory: NotificationSeenAPIFactory? = nil,
    route: RouteViewFactory? = nil,
    safetyAction: SafetyViewFactory? = nil,
    matchSafety: MatchSafetyViewFactory? = nil,
    isDebugFixture: Bool = false
  ) {
    self.directChats = directChats
    self.directChatsAPI = directChatsAPI
    self.voiceProfile = voiceProfile
    self.profilePhoto = profilePhoto
    self.profilePhotoAPIFactory = profilePhotoAPIFactory
    self.meetups = meetups
    self.meetupForMatch = meetupForMatch
    self.chatRequestForMatch = chatRequestForMatch
    self.billing = billing
    self.accountSafety = accountSafety
    self.notificationSeenAPIFactory = notificationSeenAPIFactory
    self.route = route
    self.safetyAction = safetyAction
    self.matchSafety = matchSafety
    self.isDebugFixture = isDebugFixture
  }

  static let unavailable = NativeFeatureIntegration()

  func ownerView(
    _ factory: OwnerViewFactory?,
    ownerID: String,
    callbacks: NativeFeatureCallbacks = .empty
  ) -> AnyView? {
    guard let factory, !ownerID.isEmpty else { return nil }
    return factory(ownerID, callbacks)
  }

  @MainActor
  func routeView(
    _ route: AppRoute,
    ownerID: String,
    callbacks: NativeFeatureCallbacks = .empty
  ) -> AnyView? {
    guard !ownerID.isEmpty else { return nil }
    return self.route?(ownerID, route, callbacks)
  }
}

struct NativeFeatureCallbacks {
  let onOpenSettings: () -> Void
  let onOpenReport: ((UUID, ReportContext) -> Void)?
  let onOpenReportForMatch: ((UUID, ReportContext) -> Void)?
  let onOpenMeetup: ((UUID) -> Void)?
  let onOpenChatRequests: (() -> Void)?
  let onBlocked: () -> Void
  let onOpenVerification: () -> Void
  let onOpenPaywall: (PaywallSource) -> Void
  let onBlockNeedsReconciliation: () -> Void

  init(
    onOpenSettings: @escaping () -> Void = {},
    onOpenReport: ((UUID, ReportContext) -> Void)? = nil,
    onOpenReportForMatch: ((UUID, ReportContext) -> Void)? = nil,
    onOpenMeetup: ((UUID) -> Void)? = nil,
    onOpenChatRequests: (() -> Void)? = nil,
    onBlocked: @escaping () -> Void = {},
    onOpenVerification: @escaping () -> Void = {},
    onOpenPaywall: @escaping (PaywallSource) -> Void = { _ in },
    onBlockNeedsReconciliation: @escaping () -> Void = {}
  ) {
    self.onOpenSettings = onOpenSettings
    self.onOpenReport = onOpenReport
    self.onOpenReportForMatch = onOpenReportForMatch
    self.onOpenMeetup = onOpenMeetup
    self.onOpenChatRequests = onOpenChatRequests
    self.onBlocked = onBlocked
    self.onOpenVerification = onOpenVerification
    self.onOpenPaywall = onOpenPaywall
    self.onBlockNeedsReconciliation = onBlockNeedsReconciliation
  }

  static let empty = NativeFeatureCallbacks()
}

/// External and notification routes are resolved through the shared gate
/// resolver.  This function never grants an entitlement or trusts a local
/// matches toggle as proof of onboarding.
enum NativeFeatureRouteGate {
  static func allows(
    _ route: AppRoute,
    isAuthenticated: Bool,
    ageVerified: Bool,
    onboardingCompleted: Bool
  ) -> Bool {
    switch route {
    case .authentication, .ageGate:
      return false
    default:
      let routeMayOpenBeforeOnboarding: Bool
      switch route {
      case .settings, .onboarding:
        routeMayOpenBeforeOnboarding = true
      default:
        routeMayOpenBeforeOnboarding = false
      }
      let effectiveOnboardingCompleted = onboardingCompleted || routeMayOpenBeforeOnboarding
      let context = AppGateContext(
        isAuthenticated: isAuthenticated,
        ageVerified: ageVerified,
        onboardingCompleted: effectiveOnboardingCompleted,
        entitlement: .unknown,
        requestedRoute: route
      )
      guard case .route = AppGateResolver.resolve(context) else { return false }
      return true
    }
  }
}

/// Keeps the feature route list closed after the shared gate resolver has
/// checked configuration, storage, authentication, age, and onboarding.
enum NativeFeatureRouteShape {
  static func isFeatureRoute(_ route: AppRoute) -> Bool {
    switch route {
    case .matches,
      .matchDetail,
      .foxConversation,
      .partnerFoxChat,
      .directChat,
      .report,
      .paywall,
      .meetup,
      .meetupVerification,
      .meetupFeedback,
      .meetupResult,
      .foxConversationResult,
      .chatRequest,
      .foxLearned,
      .availability,
      .notificationLanding:
      return true
    case .authentication, .ageGate, .onboarding, .settings:
      return false
    }
  }
}

/// A small, account-scoped launcher used by settings and matches.  A missing
/// factory removes that destination from the UI instead of showing a fake
/// success screen.
struct NativeFeatureHubView: View {
  let ownerID: String
  let integration: NativeFeatureIntegration
  let allowsPostOnboardingFeatures: Bool
  let callbacks: NativeFeatureCallbacks

  init(
    ownerID: String,
    integration: NativeFeatureIntegration,
    allowsPostOnboardingFeatures: Bool = true,
    callbacks: NativeFeatureCallbacks = .empty
  ) {
    self.ownerID = ownerID
    self.integration = integration
    self.allowsPostOnboardingFeatures = allowsPostOnboardingFeatures
    self.callbacks = callbacks
  }

  var body: some View {
    NavigationStack {
      List {
        if let voiceProfile = integration.ownerView(
          integration.voiceProfile,
          ownerID: ownerID,
          callbacks: callbacks
        ) {
          NavigationLink {
            voiceProfile
          } label: {
            featureRow(
              title: "Voice & profile",
              subtitle: "Complete your voice interview and review your profile.",
              systemImage: "waveform"
            )
          }
          .accessibilityIdentifier("nativeHub.voiceProfile")
        }

        if let profilePhoto = integration.ownerView(
          integration.profilePhoto,
          ownerID: ownerID,
          callbacks: callbacks
        ) {
          NavigationLink {
            profilePhoto
          } label: {
            featureRow(
              title: "Watercolor profile",
              subtitle: "Choose, review, and save a watercolor profile image.",
              systemImage: "paintbrush.pointed.fill"
            )
          }
          .accessibilityIdentifier("nativeHub.profilePhoto")
        }

        if allowsPostOnboardingFeatures,
          let directChats = integration.ownerView(
            integration.directChats,
            ownerID: ownerID,
            callbacks: callbacks
          )
        {
          NavigationLink {
            directChats
          } label: {
            featureRow(
              title: "Direct chats",
              subtitle: "Continue a conversation after a request is accepted.",
              systemImage: "message"
            )
          }
          .accessibilityIdentifier("nativeHub.directChats")
        }

        if allowsPostOnboardingFeatures,
          let meetups = integration.ownerView(
            integration.meetups,
            ownerID: ownerID,
            callbacks: callbacks
          )
        {
          NavigationLink {
            meetups
          } label: {
            featureRow(
              title: "Meetup scheduling",
              subtitle: "Review a mutual meetup and its next safe step.",
              systemImage: "calendar"
            )
          }
          .accessibilityIdentifier("nativeHub.meetups")
        }

        if let billing = integration.ownerView(
          integration.billing,
          ownerID: ownerID,
          callbacks: callbacks
        ) {
          NavigationLink {
            billing
          } label: {
            featureRow(
              title: "Billing",
              subtitle: "Check server-confirmed access or restore purchases.",
              systemImage: "creditcard"
            )
          }
          .accessibilityIdentifier("nativeHub.billing")
        }

        if let accountSafety = integration.ownerView(
          integration.accountSafety,
          ownerID: ownerID,
          callbacks: callbacks
        ) {
          NavigationLink {
            accountSafety
          } label: {
            featureRow(
              title: "Safety & account",
              subtitle: "Report or block from a partner surface and delete your account.",
              systemImage: "checkmark.shield"
            )
          }
          .accessibilityIdentifier("nativeHub.safetyAccount")
        }

        if integration.isDebugFixture {
          Text("DEBUG FIXTURE · synthetic preview · no account changes")
            .font(.caption.weight(.semibold))
            .foregroundStyle(ReferencePalette.ink)
            .listRowBackground(ReferencePalette.yellowSoft)
            .accessibilityIdentifier("nativeHub.debugFixture")
        }
      }
      .navigationTitle("Wingward features")
      .navigationBarTitleDisplayMode(.inline)
    }
    .tint(ReferencePalette.ink)
    .preferredColorScheme(.light)
  }

  private func featureRow(title: String, subtitle: String, systemImage: String) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.body.weight(.semibold))
        Text(subtitle)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } icon: {
      Image(systemName: systemImage)
        .frame(width: 28)
        .accessibilityHidden(true)
    }
    .padding(.vertical, 5)
  }
}

struct NativeRouteDestinationView: View {
  let ownerID: String
  let route: AppRoute
  let integration: NativeFeatureIntegration
  let callbacks: NativeFeatureCallbacks

  init(
    ownerID: String,
    route: AppRoute,
    integration: NativeFeatureIntegration,
    callbacks: NativeFeatureCallbacks = .empty
  ) {
    self.ownerID = ownerID
    self.route = route
    self.integration = integration
    self.callbacks = callbacks
  }

  var body: some View {
    if let destination = integration.routeView(
      route,
      ownerID: ownerID,
      callbacks: callbacks
    ) {
      destination
    } else {
      NativeFeatureUnavailableView()
    }
  }
}

struct NativeFeatureUnavailableView: View {
  var body: some View {
    MessageShellView(
      title: "This feature is unavailable",
      message: "The signed-in session could not prepare this screen. Try again from settings."
    )
  }
}

struct NativeMeetupLandingView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Meetup scheduling")
        .font(.title.bold())
      Text("Open a match first to express interest and start scheduling with that match.")
        .foregroundStyle(.secondary)
      Text("Meet-intent stays free; the server decides when a scheduling state can advance.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ReferencePalette.cream)
    .foregroundStyle(ReferencePalette.ink)
    .accessibilityIdentifier("meetup.landing")
  }
}

/// Small local shell so the Core integration file does not depend on the
/// private shell used by the authentication views in `Views.swift`.
private struct MessageShellView: View {
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "exclamationmark.triangle")
        .font(.title2)
        .accessibilityHidden(true)
      Text(title)
        .font(.title3.weight(.bold))
      Text(message)
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(28)
    .frame(maxWidth: .infinity, minHeight: 180)
    .background(ReferencePalette.cream)
    .foregroundStyle(ReferencePalette.ink)
  }
}
