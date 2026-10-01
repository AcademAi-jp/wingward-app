import Foundation
import Observation
import SwiftUI

@main
struct WingwardApp: App {
  @State private var controller: AuthSessionController
  @State private var showTeaser = false
  @State private var requestedRoute: AppRoute?
  #if DEBUG
  @State private var showVoiceSmoke = false
  @State private var showReferenceJourney = false
  @State private var showBilingualReferenceJourney = false
  @State private var showNativeJourney = false
  #endif
  private let onboardingAPIFactory: (any OnboardingSettingsAPIFactory)?
  private let matchesAPIFactory: (any MatchesAPIFactory)?
  private let matchDetailAPIFactory: (any MatchDetailAPIFactory)?
  private let conversationInsightAPIFactory: (any ConversationInsightAPIFactory)?
  private let quizAPIFactory: (any QuizAPIFactory)?
  private let nativeIntegration: NativeFeatureIntegration
  private var notificationRuntime: WingwardNotificationRuntime?
  private var notificationEventsAPIFactory: (any WingwardNotificationEventsAPIFactory)?
  private var notificationSeenAPIFactory: (any WingwardNotificationSeenAPIFactory)?
  private let initiallyShowsMatches: Bool

  init() {
    #if DEBUG
      if WingwardLocalAuthReset.isRequested(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        arguments: ProcessInfo.processInfo.arguments
      ) {
        do {
          try WingwardLocalAuthReset.runIfRequested(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            arguments: ProcessInfo.processInfo.arguments,
            storage: KeychainAuthLocalStorage()
          )
        } catch {
          _controller = State(initialValue: AuthSessionController.configurationFailure())
          onboardingAPIFactory = nil
          matchesAPIFactory = nil
          matchDetailAPIFactory = nil
          conversationInsightAPIFactory = nil
          quizAPIFactory = nil
          nativeIntegration = .unavailable
          initiallyShowsMatches = false
          return
        }
      }

      if ProcessInfo.processInfo.arguments.contains("--wingward-voice-smoke") {
        _showVoiceSmoke = State(initialValue: true)
        _controller = State(initialValue: AuthSessionController.preview(state: .signedOut))
        onboardingAPIFactory = nil
        matchesAPIFactory = nil
        matchDetailAPIFactory = nil
        conversationInsightAPIFactory = nil
        quizAPIFactory = nil
        nativeIntegration = .unavailable
        initiallyShowsMatches = false
        return
      }

      if ProcessInfo.processInfo.arguments.contains("--wingward-native-journey") {
        _showNativeJourney = State(initialValue: true)
        _controller = State(initialValue: AuthSessionController.preview(state: .authenticated(profile: .fixture)))
        onboardingAPIFactory = nil
        matchesAPIFactory = nil
        matchDetailAPIFactory = nil
        conversationInsightAPIFactory = nil
        quizAPIFactory = nil
        nativeIntegration = NativeFeatureDebugJourney.integration
        initiallyShowsMatches = false
        return
      }

      if ProcessInfo.processInfo.arguments.contains("--wingward-reference-journey") {
        _showReferenceJourney = State(initialValue: true)
        _controller = State(initialValue: AuthSessionController.preview(state: .authenticated(profile: .fixture)))
        onboardingAPIFactory = nil
        matchesAPIFactory = nil
        matchDetailAPIFactory = nil
        conversationInsightAPIFactory = nil
        quizAPIFactory = nil
        nativeIntegration = .unavailable
        initiallyShowsMatches = false
        return
      }

      if ProcessInfo.processInfo.arguments.contains("--wingward-bilingual-reference-journey") {
        _showBilingualReferenceJourney = State(initialValue: true)
        _controller = State(initialValue: AuthSessionController.preview(state: .authenticated(profile: .fixture)))
        onboardingAPIFactory = nil
        matchesAPIFactory = nil
        matchDetailAPIFactory = nil
        conversationInsightAPIFactory = nil
        quizAPIFactory = nil
        nativeIntegration = .unavailable
        initiallyShowsMatches = false
        return
      }

      if ProcessInfo.processInfo.arguments.contains("--wingward-teaser") {
        _showTeaser = State(initialValue: true)
        _controller = State(initialValue: AuthSessionController.preview(state: .authenticated(profile: .fixture)))
        onboardingAPIFactory = nil
        matchesAPIFactory = nil
        matchDetailAPIFactory = nil
        conversationInsightAPIFactory = nil
        quizAPIFactory = nil
        nativeIntegration = .unavailable
        initiallyShowsMatches = false
        return
      }

      if let quizScenario = DebugQuizBootstrap.requestedScenario {
        _controller = State(initialValue: AuthSessionController.preview(state: .authenticated(profile: .fixture)))
        onboardingAPIFactory = DebugOnboardingSettingsAPIFactory()
        matchesAPIFactory = DebugMatchesAPIFactory(scenario: .success)
        matchDetailAPIFactory = nil
        conversationInsightAPIFactory = nil
        quizAPIFactory = DebugQuizAPIFactory(scenario: quizScenario)
        nativeIntegration = .unavailable
        initiallyShowsMatches = false
        return
      }

      if let matchesScenario = DebugMatchesScenario.requested {
        let arguments = ProcessInfo.processInfo.arguments
        _controller = State(initialValue: AuthSessionController.preview(state: .authenticated(profile: .fixture)))
        onboardingAPIFactory = DebugOnboardingSettingsAPIFactory()
        matchesAPIFactory = DebugMatchesAPIFactory(
          scenario: matchesScenario,
          recordingRehearsalFixtureEnabled: arguments.contains(
            "--wingward-recording-matching-fixture"
          )
        )
        matchDetailAPIFactory = DebugMatchDetailAPIFactory(scenario: matchesScenario)
        conversationInsightAPIFactory = DebugConversationInsightAPIFactory(scenario: matchesScenario)
        quizAPIFactory = nil
        nativeIntegration = arguments.contains("--wingward-production-callback-fixture")
          ? NativeFeatureDebugJourney.integration
          : .unavailable
        if arguments.contains("--wingward-production-deep-link-safety") {
          _requestedRoute = State(
            initialValue: .matchDetail(NativeFeatureDebugJourney.safetyReconciliationMatchID)
          )
        }
        initiallyShowsMatches = true
        return
      }

      if let demoState = DebugBootstrap.requestedState {
        _controller = State(initialValue: AuthSessionController.preview(state: demoState))
        onboardingAPIFactory = DebugOnboardingSettingsAPIFactory()
        matchesAPIFactory = DebugMatchesAPIFactory(scenario: .success)
        matchDetailAPIFactory = nil
        conversationInsightAPIFactory = nil
        quizAPIFactory = nil
        nativeIntegration = .unavailable
        initiallyShowsMatches = false
        return
      }

    #endif

    switch AppConfiguration.load() {
    case let .success(configuration):
      let storage = KeychainAuthLocalStorage()
      let authService = SupabaseAuthService(configuration: configuration, storage: storage)
      let profileAPI = LiveProfileAPI(baseURL: configuration.apiBaseURL)
      let deletionRecovery: LiveAccountDeletionRecovery?
      if let statusChecker = try? LiveAccountDeletionStatusChecker(baseURL: configuration.apiBaseURL) {
        deletionRecovery = LiveAccountDeletionRecovery(
          storage: KeychainAccountDeletionReceiptStorage(),
          checker: statusChecker
        )
      } else {
        deletionRecovery = nil
      }
      let nativeLiveConfiguration = NativeFeatureLiveConfiguration.loadForComposition()
      let liveController = AuthSessionController(
        authService: authService,
        profileAPI: profileAPI,
        storageHealthChecker: KeychainStorageHealthChecker(storage: storage),
        externalIdentityCleanup: RevenueCatAuthExternalIdentityCleanup(),
        deletionRecovery: deletionRecovery
      )
      _controller = State(initialValue: liveController)
      onboardingAPIFactory = LiveOnboardingSettingsAPIFactory(
        baseURL: configuration.apiBaseURL,
        authService: authService,
        profileAPI: profileAPI
      )
      #if DEBUG
        let allowJudgeLaunchArgument = true
      #else
        let allowJudgeLaunchArgument = false
      #endif
      do {
        let recordingRehearsalMatchingEnabled = try RecordingRehearsalMatchingConfiguration.enabled(
          info: Bundle.main.infoDictionary ?? [:],
          arguments: ProcessInfo.processInfo.arguments,
          allowDevelopmentMode: allowJudgeLaunchArgument
        )
        let judgeEnabled = try DemoJudgeMatchingConfiguration.enabled(
          info: Bundle.main.infoDictionary ?? [:],
          arguments: ProcessInfo.processInfo.arguments,
          allowLaunchArgument: allowJudgeLaunchArgument
        )
        matchesAPIFactory = LiveMatchesAPIFactory(
          baseURL: configuration.apiBaseURL,
          authService: authService,
          profileAPI: profileAPI,
          recordingRehearsalMatchingEnabled: recordingRehearsalMatchingEnabled,
          demoJudgeMatchingEnabled: judgeEnabled
        )
      } catch {
        matchesAPIFactory = nil
      }
      matchDetailAPIFactory = LiveMatchDetailAPIFactory(
        baseURL: configuration.apiBaseURL,
        authService: authService,
        profileAPI: profileAPI
      )
      conversationInsightAPIFactory = LiveConversationInsightAPIFactory(
        baseURL: configuration.apiBaseURL,
        authService: authService,
        profileAPI: profileAPI
      )
      quizAPIFactory = LiveQuizAPIFactory(
        baseURL: configuration.apiBaseURL,
        authService: authService,
        profileAPI: profileAPI
      )
      let notificationRuntime = WingwardNotificationRuntime()
      notificationRuntime.install()
      self.notificationRuntime = notificationRuntime
      self.notificationEventsAPIFactory = LiveWingwardNotificationEventsAPIFactory(
        baseURL: configuration.apiBaseURL,
        authService: authService,
        profileAPI: profileAPI
      )
      self.notificationSeenAPIFactory = LiveWingwardNotificationSeenAPIFactory(
        baseURL: configuration.apiBaseURL,
        authService: authService,
        profileAPI: profileAPI
      )
      nativeIntegration = NativeFeatureLiveIntegration.make(
        baseURL: configuration.apiBaseURL,
        authService: authService,
        profileAPI: profileAPI,
        sessionController: liveController,
        notificationCoordinator: notificationRuntime.coordinator,
        configuration: nativeLiveConfiguration
      )
      initiallyShowsMatches = false
    case .failure:
      _controller = State(initialValue: AuthSessionController.configurationFailure())
      onboardingAPIFactory = nil
      matchesAPIFactory = nil
      matchDetailAPIFactory = nil
      conversationInsightAPIFactory = nil
      quizAPIFactory = nil
      nativeIntegration = .unavailable
      initiallyShowsMatches = false
    }
  }

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if showVoiceSmoke {
          NativeVoiceSmokeView()
        } else if showReferenceJourney {
          ReferenceJourney()
        } else if showBilingualReferenceJourney {
          BilingualReferenceJourney()
        } else if showNativeJourney {
          NativeFeatureDebugJourneyView(integration: nativeIntegration)
        } else if showTeaser {
          TeaserJourney(localizedFixturePrice: "Demo plan · ¥1,500/month")
        } else {
          authenticatedRoot
        }
      #else
        authenticatedRoot
      #endif
    }
  }

  private var authenticatedRoot: some View {
    RootView(
      controller: controller,
      onboardingAPIFactory: onboardingAPIFactory,
      matchesAPIFactory: matchesAPIFactory,
      matchDetailAPIFactory: matchDetailAPIFactory,
      conversationInsightAPIFactory: conversationInsightAPIFactory,
      quizAPIFactory: quizAPIFactory,
      nativeIntegration: nativeIntegration,
      notificationRuntime: notificationRuntime,
      notificationEventsAPIFactory: notificationEventsAPIFactory,
      notificationSeenAPIFactory: notificationSeenAPIFactory,
      requestedRoute: requestedRoute,
      onNotificationRoute: { route in requestedRoute = route },
      onRouteConsumed: { requestedRoute = nil },
      initiallyShowsMatches: initiallyShowsMatches
    )
      .task { await controller.bootstrap() }
      .onOpenURL { url in
        if let route = AppDeepLinkParser.parse(url) {
          requestedRoute = route
        } else {
          Task { await controller.handleCallback(url) }
        }
      }
  }
}

#if DEBUG
  private enum DebugQuizBootstrap {
    static var requestedScenario: DebugQuizScenario? {
      let arguments = ProcessInfo.processInfo.arguments
      let flags = ["--wingward-quiz-fixture", "--wingward-quiz-scenario"]
      guard let flag = flags.first(where: { arguments.contains($0) }),
        let index = arguments.firstIndex(of: flag)
      else { return nil }
      guard arguments.indices.contains(index + 1) else { return .success }
      return DebugQuizScenario(rawValue: arguments[index + 1]) ?? .success
    }
  }
#endif

#if DEBUG
private enum NativeVoiceSmokeStopReason {
  case manual
  case timeLimit
  case lifecycle

  var status: String {
    switch self {
    case .manual: return "終了"
    case .timeLimit: return "30秒で停止"
    case .lifecycle: return "終了"
    }
  }
}

private enum NativeVoiceSmokeError: Error {
  case invalidResponse
  case invalidLanguage
  case connectionFailed
}

/// A deliberately isolated bootstrap client for the local native SDK smoke.
/// It has no auth/session dependency and never persists the returned token.
private enum NativeVoiceSmokeBootstrapClient {
  static let marker = "wingward-live-dev-20260909"
  static let maxResponseBytes = 128_000

  static func fetch(language: OnboardingLanguage) async throws -> NativeVoiceBootstrap {
    guard let url = URL(string: "https://127.0.0.1:55444/bootstrap/\(language.rawValue)") else {
      throw NativeVoiceSmokeError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(marker, forHTTPHeaderField: "X-Wingward-Voice-Smoke")

    // URLSession.shared uses the simulator's normal, verified TLS trust. This
    // smoke path intentionally has no delegate or trust bypass.
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      data.count <= maxResponseBytes
    else {
      throw NativeVoiceSmokeError.invalidResponse
    }

    let bootstrap = try JSONDecoder().decode(NativeVoiceBootstrap.self, from: data)
    try NativeVoiceBootstrap.validate(bootstrap)
    guard bootstrap.overrides.language == language else {
      throw NativeVoiceSmokeError.invalidLanguage
    }
    return bootstrap
  }
}

@MainActor
@Observable
private final class NativeVoiceSmokeModel {
  private(set) var status = "待機中"
  private(set) var elapsed: TimeInterval = 0
  private(set) var eventCount = 0
  private(set) var firstSpeakingLatency: TimeInterval?
  private(set) var hasUserTranscript = false
  private(set) var hasAITranscript = false
  private(set) var inFlightLanguage: OnboardingLanguage?
  private(set) var attemptedLanguages: Set<OnboardingLanguage> = []

  @ObservationIgnored private let transport: LiveVoiceInterviewTransport
  @ObservationIgnored private var runTask: Task<Void, Never>?
  @ObservationIgnored private var timeoutTask: Task<Void, Never>?
  @ObservationIgnored private var elapsedTask: Task<Void, Never>?
  private var activeRunID: UUID?
  private var stopRequested = false
  private var sdkStartedAt: Date?

  init() {
    // This is the one path that is allowed to exercise the real native SDK.
    transport = LiveVoiceInterviewTransport(enabled: true)
  }

  var isRunning: Bool { inFlightLanguage != nil }

  func canStart(_ language: OnboardingLanguage) -> Bool {
    inFlightLanguage == nil && !attemptedLanguages.contains(language)
  }

  func begin(_ language: OnboardingLanguage) {
    guard canStart(language) else { return }

    attemptedLanguages.insert(language)
    inFlightLanguage = language
    status = "マイク権限を確認中"
    elapsed = 0
    eventCount = 0
    firstSpeakingLatency = nil
    hasUserTranscript = false
    hasAITranscript = false
    sdkStartedAt = nil
    stopRequested = false

    let runID = UUID()
    activeRunID = runID
    runTask = Task { [weak self] in
      await self?.run(language: language, runID: runID)
    }
  }

  func stop(reason: NativeVoiceSmokeStopReason = .manual) {
    guard activeRunID != nil else { return }

    stopRequested = true
    status = reason.status
    runTask?.cancel()
    timeoutTask?.cancel()
    elapsedTask?.cancel()

    // Stop the SDK session even when the bootstrap request is still in flight.
    let transport = self.transport
    Task { await transport.stop() }
  }

  private func run(language: OnboardingLanguage, runID: UUID) async {
    defer { finish(runID: runID) }

    do {
      let permission = await SystemVoicePermissionClient().requestMicrophonePermission()
      try Task.checkCancellation()
      guard isActive(runID) else { return }
      guard permission == .granted else {
        status = "マイク権限なし"
        return
      }

      status = "接続準備中"
      let bootstrap = try await NativeVoiceSmokeBootstrapClient.fetch(language: language)
      try Task.checkCancellation()
      guard isActive(runID) else { return }

      let request = VoiceInterviewRequest(
        sessionID: bootstrap.sessionID,
        credential: .conversationToken(bootstrap.conversationToken),
        overrides: bootstrap.overrides
      )
      try VoiceInterviewRequest.validate(request)

      // The 30-second window starts at the SDK request itself, before the
      // real transport is awaited.
      sdkStartedAt = Date()
      elapsed = 0
      status = "SDK接続中"
      startElapsedTicker(runID: runID)
      startTimeout(runID: runID)

      let stream = try await transport.start(request)
      guard isActive(runID) else { return }

      var didEnd = false
      for try await event in stream {
        try Task.checkCancellation()
        guard isActive(runID) else { return }
        handle(event)
        if case .ended = event {
          didEnd = true
          break
        }
      }
      guard isActive(runID) else { return }
      guard didEnd else { throw NativeVoiceSmokeError.connectionFailed }
      status = "終了"
    } catch {
      if isCancellation(error) {
        if !stopRequested, isActive(runID) {
          status = "終了"
        }
      } else if isActive(runID) {
        // Keep provider, HTTP, and token details out of this diagnostic UI.
        status = "接続失敗"
      }
    }

    await transport.stop()
  }

  private func handle(_ event: VoiceInterviewEvent) {
    eventCount += 1
    switch event {
    case .connected:
      status = "接続済み"
    case .speaking(true):
      status = "会話中"
      if firstSpeakingLatency == nil, let sdkStartedAt {
        firstSpeakingLatency = max(0, Date().timeIntervalSince(sdkStartedAt))
      }
    case .speaking(false):
      status = "接続済み"
    case let .transcript(entry):
      switch entry.source {
      case .user: hasUserTranscript = true
      case .ai: hasAITranscript = true
      }
    case .ended:
      status = "終了"
    }
  }

  private func startElapsedTicker(runID: UUID) {
    elapsedTask?.cancel()
    elapsedTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.isActive(runID) else { return }
        self.updateElapsed()
        do {
          try await Task.sleep(nanoseconds: 100_000_000)
        } catch {
          return
        }
      }
    }
  }

  private func startTimeout(runID: UUID) {
    timeoutTask?.cancel()
    timeoutTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 30_000_000_000)
      } catch {
        return
      }
      guard let self, self.isActive(runID) else { return }
      self.stop(reason: .timeLimit)
    }
  }

  private func updateElapsed() {
    guard let sdkStartedAt else { return }
    elapsed = min(max(0, Date().timeIntervalSince(sdkStartedAt)), 30)
  }

  private func finish(runID: UUID) {
    guard activeRunID == runID else { return }
    updateElapsed()
    timeoutTask?.cancel()
    timeoutTask = nil
    elapsedTask?.cancel()
    elapsedTask = nil
    inFlightLanguage = nil
    activeRunID = nil
    stopRequested = false
    runTask = nil
  }

  private func isActive(_ runID: UUID) -> Bool {
    !Task.isCancelled && activeRunID == runID
  }

  private func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let transportError = error as? VoiceInterviewTransportError {
      return transportError == .cancelled
    }
    if let urlError = error as? URLError {
      return urlError.code == .cancelled
    }
    return false
  }
}

private struct NativeVoiceSmokeView: View {
  @State private var model: NativeVoiceSmokeModel
  @Environment(\.scenePhase) private var scenePhase

  init() {
    _model = State(initialValue: NativeVoiceSmokeModel())
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("テスト用の会話設定で SDK 接続だけを確認します。認証・DBは使用しません。")
            .font(.subheadline)
            .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 12) {
            metricRow("状態", model.status)
            metricRow(
              "経過 / イベント数",
              "\(durationText(model.elapsed)) / \(model.eventCount)"
            )
            metricRow("初回の発声まで", latencyText(model.firstSpeakingLatency))
            metricRow("あなたの声を認識", model.hasUserTranscript ? "確認済み" : "未確認")
            metricRow("AIの応答", model.hasAITranscript ? "確認済み" : "未確認")
          }
          .padding(16)
          .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

          VStack(spacing: 12) {
            HStack(spacing: 12) {
              Button("日本語で開始") { model.begin(.ja) }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart(.ja))

              Button("英語で開始") { model.begin(.en) }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart(.en))
            }
            .frame(maxWidth: .infinity)

            Button("終了") { model.stop() }
              .buttonStyle(.bordered)
              .disabled(!model.isRunning)
              .frame(maxWidth: .infinity)
          }
        }
        .padding(20)
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .navigationTitle("SDK音声接続テスト")
      .navigationBarTitleDisplayMode(.inline)
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .background else { return }
      model.stop(reason: .lifecycle)
    }
    .onDisappear {
      model.stop(reason: .lifecycle)
    }
    .preferredColorScheme(.light)
  }

  private func metricRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(value)
        .font(.body.monospacedDigit())
        .multilineTextAlignment(.trailing)
    }
  }

  private func durationText(_ duration: TimeInterval) -> String {
    guard duration.isFinite else { return "—" }
    return String(format: "%.1fs", max(0, duration))
  }

  private func latencyText(_ latency: TimeInterval?) -> String {
    guard let latency, latency.isFinite else { return "—" }
    return String(format: "%.1fs", max(0, latency))
  }
}
#endif

#if DEBUG
  private enum DebugBootstrap {
    static var requestedState: AuthState? {
      guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--wingward-debug-state"),
        ProcessInfo.processInfo.arguments.indices.contains(index + 1)
      else { return nil }
      switch ProcessInfo.processInfo.arguments[index + 1] {
      case "success": return .authenticated(profile: .fixture)
      case "signedOut": return .signedOut
      case "passwordResetRequest": return .passwordResetRequest
      case "passwordResetRequested": return .passwordResetRequested
      case "passwordRecovery": return .passwordRecovery
      case "confirmation":
        return .awaitingEmailConfirmation(maskedEmail: "a••••@example.com")
      case "needsAge": return .needsAgeVerification
      case "recoverableError": return .recoverableError
      case "input-error": return .signedOut
      default: return nil
      }
    }
  }
#endif
