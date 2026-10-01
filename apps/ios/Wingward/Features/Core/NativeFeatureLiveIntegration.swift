import Foundation
import SwiftUI

/// Builds only live, owner-bound feature destinations.  No feature closure
/// falls back to synthetic data in a release build; a failed client factory
/// simply removes that destination from navigation.
enum NativeFeatureLiveIntegration {
  static func make(
    baseURL: URL,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    sessionController: AuthSessionController,
    notificationCoordinator: WingwardNotificationCoordinator? = nil,
    configuration: NativeFeatureLiveConfiguration = .disabled
  ) -> NativeFeatureIntegration {
    let chatsFactory = LiveDirectChatsAPIFactory(
      baseURL: baseURL,
      authService: authService,
      profileAPI: profileAPI
    )
    let voiceTransportFactory = LiveVoiceInterviewTransportFactory(
      bootstrapKind: configuration.voiceBootstrapKind,
      enabled: configuration.voiceEnabled
    )
    let voiceFactory = LiveVoiceProfileAPIFactory(
      baseURL: baseURL,
      authService: authService,
      profileAPI: profileAPI,
      voiceTransport: voiceTransportFactory.make(),
      bootstrapKind: voiceTransportFactory.bootstrapKind
    )
    let profilePhotoFactory = LiveProfilePhotoAPIFactory(
      baseURL: baseURL,
      authService: authService,
      profileAPI: profileAPI
    )
    let meetupsFactory = LiveMeetupsAPIFactory(
      baseURL: baseURL,
      authService: authService,
      profileAPI: profileAPI
    )
    let matchDetailFactory = LiveMatchDetailAPIFactory(
      baseURL: baseURL,
      authService: authService,
      profileAPI: profileAPI
    )
    let notificationSeenFactory = LiveWingwardNotificationSeenAPIFactory(
      baseURL: baseURL,
      authService: authService,
      profileAPI: profileAPI
    )

    return NativeFeatureIntegration(
      directChats: { ownerID, callbacks in
        guard let api = chatsFactory.make(ownerID: ownerID) else { return nil }
        return AnyView(
          DirectChatsView(
            ownerID: ownerID,
            api: api,
            onOpenSettings: callbacks.onOpenSettings,
            onOpenReport: nil,
            onOpenReportForMatch: callbacks.onOpenReportForMatch,
            onOpenChatRequests: callbacks.onOpenChatRequests,
            reflectionTransport: LiveVoiceInterviewTransportFactory(
              bootstrapKind: .openAIRealtime,
              enabled: configuration.voiceEnabled && configuration.voiceBootstrapKind == .openAIRealtime
            ).make()
          )
        )
      },
      directChatsAPI: { ownerID in
        chatsFactory.make(ownerID: ownerID)
      },
      voiceProfile: { ownerID, callbacks in
        guard let module = voiceFactory.make(ownerID: ownerID) else { return nil }
        return AnyView(
          VoiceProfileView(
            ownerID: ownerID,
            module: module,
            onConfirmed: {
              Task {
                guard await sessionController.refreshProfileAfterOnboarding(ownerID: ownerID) else {
                  return
                }
                callbacks.onOpenSettings()
              }
            }
          )
        )
      },
      profilePhoto: { ownerID, _ in
        guard let api = profilePhotoFactory.make(ownerID: ownerID) else { return nil }
        return AnyView(WatercolorProfileView(ownerID: ownerID, api: api))
      },
      profilePhotoAPIFactory: profilePhotoFactory,
      meetups: { ownerID, callbacks in
        AnyView(NativeMeetupLandingView())
      },
      meetupForMatch: { ownerID, matchID, callbacks in
        guard let api = meetupsFactory.make(ownerID: ownerID) else { return nil }
        return AnyView(
          MeetupView(
            ownerID: ownerID,
            matchID: matchID,
            api: api,
            onOpenVerification: callbacks.onOpenVerification,
            onOpenPaywall: callbacks.onOpenPaywall,
            onOpenReportForMatch: callbacks.onOpenReportForMatch
          )
        )
      },
      chatRequestForMatch: { ownerID, matchID, callbacks in
        guard let api = chatsFactory.make(ownerID: ownerID) else { return nil }
        return AnyView(
          DirectChatRequestView(
            ownerID: ownerID,
            matchID: matchID,
            api: api,
            onOpenReportForMatch: callbacks.onOpenReportForMatch
          )
        )
      },
      billing: { ownerID, _ in
        guard let serverAPI = try? LiveBillingAPI(
          baseURL: baseURL,
          ownerID: ownerID,
          authService: authService,
          profileAPI: profileAPI
        ) else { return nil }
        let client = makeBillingClient(
          ownerID: ownerID,
          baseURL: baseURL,
          authService: authService,
          profileAPI: profileAPI,
          serverAPI: serverAPI,
          configuration: configuration.billing
        ) ?? UnavailableBillingClient(serverAPI: serverAPI)
        return AnyView(
          BillingView(
            ownerID: ownerID,
            client: client
          )
        )
      },
      accountSafety: { ownerID, _ in
        guard let safetyAPI = try? LiveSafetyAPI(
          baseURL: baseURL,
          ownerID: ownerID,
          authService: authService,
          profileAPI: profileAPI
        ), let deletionAPI = try? LiveAccountLifecycleAPI(
          baseURL: baseURL,
          ownerID: ownerID,
          authService: authService,
          profileAPI: profileAPI
        ) else { return nil }
        return AnyView(
          NativeAccountSafetyView(
            ownerID: ownerID,
            safetyAPI: safetyAPI,
            deletionAPI: deletionAPI,
            cleanup: sessionController
          )
        )
      },
      notificationSeenAPIFactory: { ownerID in
        notificationSeenFactory.make(ownerID: ownerID)
      },
      route: { ownerID, route, callbacks in
        makeRouteView(
          ownerID: ownerID,
          route: route,
          callbacks: callbacks,
          baseURL: baseURL,
          authService: authService,
          profileAPI: profileAPI,
          chatsFactory: chatsFactory,
          matchDetailFactory: matchDetailFactory,
          meetupsFactory: meetupsFactory,
          notificationCoordinator: notificationCoordinator,
          notificationSeenFactory: notificationSeenFactory,
          configuration: configuration
        )
      },
      safetyAction: { ownerID, targetID, context, messageID in
        guard let safetyAPI = try? LiveSafetyAPI(
          baseURL: baseURL,
          ownerID: ownerID,
          authService: authService,
          profileAPI: profileAPI
        ) else { return nil }
        return AnyView(
          SafetyActionView(
            ownerID: ownerID,
            targetID: targetID,
            context: context,
            messageID: messageID,
            api: safetyAPI
          )
        )
      },
      matchSafety: { ownerID, matchID, context, callbacks in
        guard let matchAPI = matchDetailFactory.make(ownerID: ownerID),
          let safetyAPI = try? LiveSafetyAPI(
            baseURL: baseURL,
            ownerID: ownerID,
            authService: authService,
            profileAPI: profileAPI
          )
        else { return nil }
        return AnyView(
          NativeMatchSafetyDestination(
            ownerID: ownerID,
            matchID: matchID,
            context: context,
            matchAPI: matchAPI,
            safetyAPI: safetyAPI,
            onBlocked: callbacks.onBlocked,
            onBlockNeedsReconciliation: callbacks.onBlockNeedsReconciliation
          )
        )
      }
    )
  }

  private static func makeBillingClient(
    ownerID: String,
    baseURL: URL,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    serverAPI: any BillingAPI,
    configuration: NativeFeatureLiveConfiguration.Billing
  ) -> (any BillingClient)? {
    guard configuration.enabled,
      let publicKey = configuration.publicKey,
      (try? APIDTOValidation.requireUUID(ownerID)) != nil
    else { return nil }

    let provider = OwnerBoundAuthSessionTokenProvider(
      expectedOwnerID: ownerID,
      authService: authService,
      profileAPI: profileAPI
    )
    guard let client = try? AuthenticatedAPIClient(
      baseURL: baseURL,
      tokenProvider: provider
    ) else { return nil }

    let identityAPI = LiveBillingIdentityAPI(client: client)
    let revenueCatClient = RevenueCatBillingClient(
      ownerID: ownerID,
      serverAPI: serverAPI,
      identityAPI: identityAPI
    )
    return ConfiguredRevenueCatBillingClient(
      client: revenueCatClient,
      publicKey: publicKey
    )
  }

  @MainActor
  private static func makeRouteView(
    ownerID: String,
    route: AppRoute,
    callbacks: NativeFeatureCallbacks,
    baseURL: URL,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    chatsFactory: any DirectChatsAPIFactory,
    matchDetailFactory: any MatchDetailAPIFactory,
    meetupsFactory: any MeetupsAPIFactory,
    notificationCoordinator: WingwardNotificationCoordinator?,
    notificationSeenFactory: any WingwardNotificationSeenAPIFactory,
    configuration: NativeFeatureLiveConfiguration
  ) -> AnyView? {
    if case let .notificationLanding(notificationID) = route {
      return AnyView(
        WingwardNotificationLandingView(
          ownerID: ownerID,
          notificationID: notificationID,
          coordinator: notificationCoordinator,
          seenAPI: notificationSeenFactory.make(ownerID: ownerID)
        )
      )
    }

    switch route {
    case let .matchDetail(matchID), let .foxConversation(matchID), let .foxConversationResult(matchID):
      guard let api = matchDetailFactory.make(ownerID: ownerID) else { return nil }
      let destination = AnyView(
        MatchDetailView(
          ownerID: ownerID,
          rank: 1,
          matchID: matchID,
          api: api,
          onOpenSettings: callbacks.onOpenSettings,
          onOpenReport: callbacks.onOpenReport,
          onOpenMeetup: callbacks.onOpenMeetup
        )
      )
      return AnyView(
        WingwardNotificationTrackedDestinationView(
          ownerID: ownerID,
          route: route,
          destination: destination,
          coordinator: notificationCoordinator
        )
      )
    case let .report(targetID, context):
      guard let api = try? LiveSafetyAPI(
        baseURL: baseURL,
        ownerID: ownerID,
        authService: authService,
        profileAPI: profileAPI
      ) else { return nil }
      return AnyView(
        SafetyActionView(
          ownerID: ownerID,
          targetID: targetID,
          context: context,
          api: api
        )
      )
    case let .meetup(meetupID), let .meetupVerification(meetupID):
      guard let api = meetupsFactory.make(ownerID: ownerID) else { return nil }
      return AnyView(
        MeetupView(
          ownerID: ownerID,
          meetupID: meetupID,
          api: api,
          onOpenVerification: callbacks.onOpenVerification,
          onOpenPaywall: callbacks.onOpenPaywall,
          onOpenReportForMatch: callbacks.onOpenReportForMatch
        )
      )
    case .meetupFeedback, .meetupResult:
      // S3 post-meet surfaces stay behind the closed-pilot flag.
      return nil
    case .availability:
      guard let api = meetupsFactory.make(ownerID: ownerID) else { return nil }
      return AnyView(
        MeetupView(
          ownerID: ownerID,
          api: api,
          onOpenVerification: callbacks.onOpenVerification,
          onOpenPaywall: callbacks.onOpenPaywall,
          onOpenReportForMatch: callbacks.onOpenReportForMatch
        )
      )
    case .chatRequest:
      guard let api = chatsFactory.make(ownerID: ownerID) else { return nil }
      return AnyView(
        ChatRequestsView(
          ownerID: ownerID,
          api: api,
          onOpenReportForMatch: callbacks.onOpenReportForMatch
        )
      )
    case .directChat:
      guard let api = chatsFactory.make(ownerID: ownerID) else { return nil }
      return AnyView(
        DirectChatsView(
          ownerID: ownerID,
          api: api,
          onOpenSettings: callbacks.onOpenSettings,
          onOpenReport: callbacks.onOpenReport,
          onOpenReportForMatch: callbacks.onOpenReportForMatch,
          onOpenChatRequests: callbacks.onOpenChatRequests,
          reflectionTransport: LiveVoiceInterviewTransportFactory(
            bootstrapKind: .openAIRealtime,
            enabled: configuration.voiceEnabled && configuration.voiceBootstrapKind == .openAIRealtime
          ).make()
        )
      )
    case .paywall:
      guard let serverAPI = try? LiveBillingAPI(
        baseURL: baseURL,
        ownerID: ownerID,
        authService: authService,
        profileAPI: profileAPI
      ) else { return nil }
      let client = makeBillingClient(
        ownerID: ownerID,
        baseURL: baseURL,
        authService: authService,
        profileAPI: profileAPI,
        serverAPI: serverAPI,
        configuration: configuration.billing
      ) ?? UnavailableBillingClient(serverAPI: serverAPI)
      return AnyView(
        BillingView(
          ownerID: ownerID,
          client: client
        )
      )
    default:
      return nil
    }
  }
}

/// AuthSessionController calls this seam before leaving an owner-bound auth
/// state. The coordinator is vendor-neutral at the call site and safely no-ops
/// when RevenueCat has never been configured.
struct RevenueCatAuthExternalIdentityCleanup: AuthExternalIdentityCleanup, Sendable {
  func resetIdentity(ownerID: String) async {
    await RevenueCatBillingConfigurationCoordinator.shared.resetIdentity(expectedOwnerID: ownerID)
  }
}

/// Keeps RevenueCat configuration lazy and owner-bound. Server status reads
/// remain available before vendor configuration, while offerings/purchase/
/// restore fail closed until the explicit public-key configuration succeeds.
private actor RevenueCatLiveConfigurationGate {
  private var configured = false

  func ensure(_ operation: @escaping @Sendable () async throws -> Void) async throws {
    if configured { return }
    try Task.checkCancellation()
    do {
      try await operation()
      try Task.checkCancellation()
      configured = true
    } catch {
      configured = false
      throw error
    }
  }

  func markConfigured() {
    configured = true
  }

  func reset() {
    configured = false
  }
}

private struct ConfiguredRevenueCatBillingClient: BillingClient, Sendable {
  let client: RevenueCatBillingClient
  let publicKey: String
  let gate: RevenueCatLiveConfigurationGate

  init(client: RevenueCatBillingClient, publicKey: String) {
    self.client = client
    self.publicKey = publicKey
    gate = RevenueCatLiveConfigurationGate()
  }

  func configure(publicKey: String, appUserID: String) async throws {
    guard publicKey == self.publicKey else {
      throw BillingClientError.notConfigured
    }
    try await client.configure(publicKey: publicKey, appUserID: appUserID)
    await gate.markConfigured()
  }

  func offerings() async throws -> [BillingOffering] {
    try await ensureConfigured()
    return try await client.offerings()
  }

  func purchase(packageID: String) async throws -> BillingPurchaseResult {
    try await ensureConfigured()
    return try await client.purchase(packageID: packageID)
  }

  func restore() async throws -> BillingStatus {
    try await ensureConfigured()
    return try await client.restore()
  }

  func currentStatus() async throws -> BillingStatus {
    // BillingStore treats the authenticated server mirror as authoritative;
    // this read must stay useful even while the vendor SDK is unavailable.
    try await client.currentStatus()
  }

  func resetIdentity() async {
    await client.resetIdentity()
    await gate.reset()
  }

  private func ensureConfigured() async throws {
    let client = self.client
    let publicKey = self.publicKey
    try await gate.ensure {
      try await client.configure(publicKey: publicKey)
    }
  }
}

struct NativeAccountSafetyView: View {
  let ownerID: String
  let safetyAPI: any SafetyAPI
  let deletionAPI: any AccountLifecycleAPI
  let cleanup: any SessionCleanup

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Safety & account")
            .font(.title.bold())
          Text("Report and block are available from each partner surface. Account deletion waits for durable server confirmation before clearing this session.")
            .font(.body)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

        AccountDeletionView(ownerID: ownerID, api: deletionAPI, cleanup: cleanup)
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.white)
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      }
      .padding(20)
      .frame(maxWidth: 700, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Safety & account")
    .navigationBarTitleDisplayMode(.inline)
    .background(ReferencePalette.cream.ignoresSafeArea())
    .tint(ReferencePalette.ink)
  }
}

/// Resolves the partner identity from the authenticated match resource before
/// constructing report/block UI.  A match ID is never treated as a user ID.
struct NativeMatchSafetyDestination: View {
  let ownerID: String
  let matchID: UUID
  let context: ReportContext
  let matchAPI: any MatchDetailAPI
  let safetyAPI: any SafetyAPI
  let onBlocked: () -> Void
  let onBlockNeedsReconciliation: () -> Void

  @State private var store: MatchDetailStore

  init(
    ownerID: String,
    matchID: UUID,
    context: ReportContext,
    matchAPI: any MatchDetailAPI,
    safetyAPI: any SafetyAPI,
    onBlocked: @escaping () -> Void = {},
    onBlockNeedsReconciliation: @escaping () -> Void = {}
  ) {
    self.ownerID = ownerID
    self.matchID = matchID
    self.context = context
    self.matchAPI = matchAPI
    self.safetyAPI = safetyAPI
    self.onBlocked = onBlocked
    self.onBlockNeedsReconciliation = onBlockNeedsReconciliation
    _store = State(initialValue: MatchDetailStore(ownerID: ownerID, matchID: matchID, api: matchAPI))
  }

  var body: some View {
    Group {
      switch store.phase {
      case .idle, .loading:
        ProgressView("Checking this partner…")
          .frame(maxWidth: .infinity, minHeight: 180)
      case .failed:
        NativeFeatureUnavailableView()
      case .loaded:
        if let partnerID = store.detail?.partnerID {
          VStack(alignment: .leading, spacing: 16) {
            Text("Safety")
              .font(.title.bold())
            SafetyActionView(
              ownerID: ownerID,
              targetID: partnerID,
              context: context,
              api: safetyAPI,
              onBlocked: onBlocked,
              onBlockNeedsReconciliation: onBlockNeedsReconciliation
            )
          }
          .padding(20)
        } else {
          NativeFeatureUnavailableView()
        }
      }
    }
    .navigationTitle("Safety")
    .navigationBarTitleDisplayMode(.inline)
    .background(ReferencePalette.cream.ignoresSafeArea())
    .task(id: "\(ownerID)-\(matchID.uuidString)") {
      await store.load().value
    }
    .onDisappear {
      store.cancel()
    }
  }
}
