import Foundation
import XCTest
@testable import Wingward

@MainActor
final class VoiceProfileNativeBootstrapTests: XCTestCase {
  private let ownerID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let sessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  private let personaID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

  func testThreePersonasUseDistinctVoicesForEverySelection() {
    let api = NativeBootstrapFixtureAPI(bootstrap: nativeBootstrap())
    let store = makeStore(api: api, bootstrapKind: .openAIRealtime)
    for first in RealtimeVoice.allCases {
      store.selectedRealtimeVoice = first
      XCTAssertEqual(store.realtimeVoice(for: .similar), first)
      XCTAssertEqual(Set(VoicePersonaType.allCases.map { store.realtimeVoice(for: $0).rawValue }).count, 3)
    }
  }

  func testRealtimeUsesSelectedVoiceAndExistingCompletion() async {
    let api = NativeBootstrapFixtureAPI(bootstrap: nativeBootstrap())
    let store = makeStore(api: api, bootstrapKind: .openAIRealtime)
    store.selectedRealtimeVoice = .ash
    await store.load().value
    await store.startInterview(personaID: personaID).value
    XCTAssertEqual(store.phase, .candidates)
    let voice = await api.requestedRealtimeVoice
    let legacy = await api.nativeBootstrapCallCount()
    let complete = await api.completeCallCount()
    XCTAssertEqual(voice, .ash)
    XCTAssertEqual(legacy, 0)
    XCTAssertEqual(complete, 1)
  }

  func testNativeModeUsesOnlyNativeBootstrap() async {
    let api = NativeBootstrapFixtureAPI(bootstrap: nativeBootstrap())
    let store = makeStore(api: api)

    await store.load().value
    await store.startInterview(personaID: personaID).value

    XCTAssertEqual(store.phase, .candidates)
    let nativeCalls = await api.nativeBootstrapCallCount()
    let signedURLCalls = await api.signedURLCallCount()
    let completeCalls = await api.completeCallCount()
    XCTAssertEqual(nativeCalls, 1)
    XCTAssertEqual(signedURLCalls, 0)
    XCTAssertEqual(completeCalls, 1)
  }

  func testNativeModeRejectsBootstrapForAnotherSession() async {
    let api = NativeBootstrapFixtureAPI(
      bootstrap: nativeBootstrap(sessionID: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!)
    )
    let store = makeStore(api: api)

    await store.load().value
    await store.startInterview(personaID: personaID).value

    XCTAssertEqual(store.phase, .failed(.invalidResponse))
    let signedURLCalls = await api.signedURLCallCount()
    let completeCalls = await api.completeCallCount()
    XCTAssertEqual(signedURLCalls, 0)
    XCTAssertEqual(completeCalls, 0)
  }

  func testNativeModeRejectsLanguageMismatchAndMalformedToken() async {
    let languageMismatch = NativeBootstrapFixtureAPI(
      bootstrap: nativeBootstrap(language: .ja)
    )
    let languageStore = makeStore(api: languageMismatch)
    await languageStore.load().value
    await languageStore.startInterview(personaID: personaID).value
    XCTAssertEqual(languageStore.phase, .failed(.invalidResponse))
    let languageSignedURLCalls = await languageMismatch.signedURLCallCount()
    XCTAssertEqual(languageSignedURLCalls, 0)

    let malformedToken = NativeBootstrapFixtureAPI(
      bootstrap: nativeBootstrap(token: " token ")
    )
    let tokenStore = makeStore(api: malformedToken)
    await tokenStore.load().value
    await tokenStore.startInterview(personaID: personaID).value
    XCTAssertEqual(tokenStore.phase, .failed(.invalidResponse))
    let tokenSignedURLCalls = await malformedToken.signedURLCallCount()
    XCTAssertEqual(tokenSignedURLCalls, 0)
  }

  func testNativeCancellationDoesNotCompleteSession() async {
    let api = NativeBootstrapFixtureAPI(bootstrap: nativeBootstrap())
    let store = makeStore(
      api: api,
      transport: DebugVoiceInterviewTransport(failure: .cancelled)
    )

    await store.load().value
    await store.startInterview(personaID: personaID).value

    XCTAssertEqual(store.phase, .candidates)
    let nativeCalls = await api.nativeBootstrapCallCount()
    let completeCalls = await api.completeCallCount()
    XCTAssertEqual(nativeCalls, 1)
    XCTAssertEqual(completeCalls, 0)
  }

  private func makeStore(
    api: NativeBootstrapFixtureAPI,
    transport: any VoiceInterviewTransport = DebugVoiceInterviewTransport(),
    bootstrapKind: VoiceInterviewBootstrapKind = .nativeConversationToken
  ) -> VoiceProfileStore {
    VoiceProfileStore(
      ownerID: ownerID.uuidString,
      module: VoiceProfileModule(
        api: api,
        settingsAPI: NativeBootstrapFixtureSettingsAPI(),
        insightAPI: NativeBootstrapFixtureInsightAPI(ownerID: ownerID),
        permissionClient: DebugVoicePermissionClient(),
        transport: transport,
        bootstrapKind: bootstrapKind
      )
    )
  }

  private func nativeBootstrap(
    sessionID: UUID? = nil,
    token: String = "synthetic-conversation-token",
    language: OnboardingLanguage = .en
  ) -> NativeVoiceBootstrap {
    NativeVoiceBootstrap(
      sessionID: sessionID ?? self.sessionID,
      conversationToken: token,
      overrides: VoiceInterviewOverrides(
        prompt: "Keep it kind.",
        firstMessage: "Hello!",
        language: language,
        voiceID: "voice-en"
      )
    )
  }
}

private actor NativeBootstrapFixtureAPI: VoiceProfileAPI {
  private let bootstrap: NativeVoiceBootstrap
  private let personas: [VoicePersona]
  private var nativeBootstrapCalls = 0
  private var signedURLCalls = 0
  private var completeCalls = 0
  private(set) var requestedRealtimeVoice: RealtimeVoice?

  init(bootstrap: NativeVoiceBootstrap) {
    self.bootstrap = bootstrap
    personas = [
      VoicePersona(
        id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
        type: .similar,
        name: "A"
      ),
      VoicePersona(
        id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
        type: .complementary,
        name: "B"
      ),
      VoicePersona(
        id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
        type: .discovery,
        name: "C"
      )
    ]
  }

  func fetchPersonas() async throws -> [VoicePersona] { personas }
  func generatePersonas() async throws -> [VoicePersona] { personas }

  func startSession(personaID: UUID) async throws -> VoiceSessionStartResult {
    guard personaID == personas[0].id else { throw APIClientError.notFound }
    return VoiceSessionStartResult(
      sessionID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
      personaID: personaID,
      personaName: "A"
    )
  }

  func fetchSignedURL(sessionID: UUID) async throws -> VoiceInterviewBootstrap {
    signedURLCalls += 1
    return VoiceInterviewBootstrap(
      signedURL: URL(string: "wss://api.elevenlabs.io/v1/convai/conversation?conversation_signature=synthetic")!,
      overrides: bootstrap.overrides,
      personaName: "A"
    )
  }

  func fetchNativeBootstrap(sessionID: UUID) async throws -> NativeVoiceBootstrap {
    nativeBootstrapCalls += 1
    return bootstrap
  }

  func fetchRealtimeBootstrap(sessionID: UUID, voice: RealtimeVoice) async throws -> RealtimeVoiceBootstrap {
    requestedRealtimeVoice = voice
    return RealtimeVoiceBootstrap(sessionID: sessionID, clientSecret: "ek_synthetic",
      expiresAt: Date().timeIntervalSince1970 + 120, model: "gpt-realtime-2.1-mini",
      overrides: VoiceInterviewOverrides(prompt: "Short replies.", firstMessage: nil, language: .en, voiceID: voice.rawValue))
  }

  func completeSession(sessionID: UUID, transcript: [VoiceTranscriptEntry]) async throws -> VoiceSessionCompletion {
    completeCalls += 1
    return VoiceSessionCompletion(sessionID: sessionID, status: "completed", allSessionsCompleted: false)
  }

  func generateProfile() async throws {}
  func generateWingfox() async throws {}
  func confirmProfile() async throws -> VoiceProfileConfirmation {
    VoiceProfileConfirmation(status: "confirmed", confirmedAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  func nativeBootstrapCallCount() -> Int { nativeBootstrapCalls }
  func signedURLCallCount() -> Int { signedURLCalls }
  func completeCallCount() -> Int { completeCalls }
}

private struct NativeBootstrapFixtureSettingsAPI: OnboardingSettingsAPI, Sendable {
  func fetchSettings() async throws -> OnboardingSettings? {
    OnboardingSettings(
      uiLocale: .en,
      datingMarket: .US,
      conversationLanguage: .en,
      timezone: "America/Los_Angeles",
      distanceUnit: .mi,
      genderIdentity: nil,
      preferredGenders: [.woman],
      preferenceMode: .selected,
      locationMode: .noTransit,
      stationID: nil,
      coarseAreaID: "us-ca-san-francisco"
    )
  }

  func fetchOptions(market: OnboardingDatingMarket, locale: OnboardingLanguage) async throws -> OnboardingOptions {
    throw APIClientError.invalidState
  }

  func saveSettings(_ settings: OnboardingSettings) async throws -> OnboardingSettings { settings }
}

private struct NativeBootstrapFixtureInsightAPI: ConversationInsightAPI, Sendable {
  let ownerID: UUID

  func fetchInsight() async throws -> OwnInsight {
    OwnInsight(
      id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
      userID: ownerID,
      personalityTags: ["Thoughtful"],
      status: "ready",
      overallSignature: "A kind conversation."
    )
  }
}
