#if DEBUG
import Foundation
import SwiftUI

/// A local-only Voice/Profile destination for visual inspection. It uses the
/// production VoiceProfileView and stores all state in memory; no auth token,
/// microphone, provider, or network request is used.
enum VoiceProfileDebugFixture {
  enum Scenario: String, CaseIterable, Sendable {
    case interview
    case permissionDenied
    case unavailable
    case profileRevisionAvailable
  }

  static let ownerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

  static func makeModule(
    ownerID: String = Self.ownerID,
    scenario: Scenario = .interview
  ) -> VoiceProfileModule {
    let state = VoiceProfileDebugState(
      ownerID: UUID(uuidString: ownerID) ?? UUID(uuidString: Self.ownerID)!,
      scenario: scenario
    )
    let api = VoiceProfileDebugAPI(state: state)
    let permission: any VoicePermissionClient
    let transport: any VoiceInterviewTransport

    switch scenario {
    case .interview:
      permission = DebugVoicePermissionClient(status: .granted)
      transport = DebugVoiceInterviewTransport(events: [
        .connected,
        .transcript(VoiceTranscriptEntry(source: .ai, message: "What kind of day helps you feel like yourself?")),
        .transcript(VoiceTranscriptEntry(source: .user, message: "A slow morning and a good conversation.")),
        .ended
      ])
    case .permissionDenied:
      permission = DebugVoicePermissionClient(status: .denied)
      transport = DebugVoiceInterviewTransport()
    case .unavailable:
      permission = DebugVoicePermissionClient(status: .granted)
      transport = UnavailableVoiceInterviewTransport()
    case .profileRevisionAvailable:
      permission = DebugVoicePermissionClient(status: .granted)
      transport = DebugVoiceInterviewTransport(events: [])
    }

    return VoiceProfileModule(
      api: api,
      photoAPI: WatercolorProfileDebugPhotoAPI(),
      settingsAPI: VoiceProfileDebugSettingsAPI(),
      insightAPI: VoiceProfileDebugInsightAPI(
        state: state,
        ownerID: UUID(uuidString: ownerID) ?? UUID(uuidString: Self.ownerID)!
      ),
      permissionClient: permission,
      transport: transport
    )
  }

  static func makeDestination(
    ownerID: String = Self.ownerID,
    scenario: Scenario = .interview
  ) -> AnyView {
    AnyView(
      VoiceProfileView(
        ownerID: ownerID,
        module: makeModule(ownerID: ownerID, scenario: scenario)
      )
    )
  }

  /// Directly assignable to `NativeFeatureIntegration.voiceProfile` by the
  /// shared DEBUG journey without changing a shared file here.
  static func ownerViewFactory(
    scenario: Scenario = .interview
  ) -> NativeFeatureIntegration.OwnerViewFactory {
    let selectedScenario = ProcessInfo.processInfo.arguments.contains(
      "--wingward-native-profile-revision"
    ) ? Scenario.profileRevisionAvailable : scenario
    return { ownerID, _ in
      makeDestination(ownerID: ownerID, scenario: selectedScenario)
    }
  }
}

private actor VoiceProfileDebugState {
  private let ownerID: UUID
  private var sessions: [UUID: UUID] = [:]
  private var completedPersonas: Set<UUID> = []
  private var completedSessionIDs: [UUID: UUID] = [:]
  private var profileGenerated = false
  private var wingfoxGenerated = false
  private var confirmed = false
  private var profileRevisionStatus: VoiceProfileRevisionStatus?
  private var canRegenerateFromThree = false
  private var profileSignature = "You make room for honest, unhurried conversations."

  init(ownerID: UUID, scenario: VoiceProfileDebugFixture.Scenario) {
    self.ownerID = ownerID
    guard scenario == .profileRevisionAvailable else { return }
    profileGenerated = true
    wingfoxGenerated = true
    profileRevisionStatus = .available
    canRegenerateFromThree = true
    profileSignature = "An older debug profile, preserved for review."
    for (personaID, sessionID) in Self.revisionFixtureSessions {
      completedPersonas.insert(personaID)
      completedSessionIDs[personaID] = sessionID
    }
  }

  private static let revisionFixtureSessions: [(UUID, UUID)] = [
    (
      UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
      UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    ),
    (
      UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
      UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    ),
    (
      UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
      UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    )
  ]

  func register(sessionID: UUID, personaID: UUID) {
    sessions[sessionID] = personaID
  }

  func complete(sessionID: UUID) throws -> Bool {
    guard let personaID = sessions[sessionID] else { throw APIClientError.notFound }
    completedPersonas.insert(personaID)
    completedSessionIDs[personaID] = sessionID
    return completedPersonas.count == VoicePersonaType.allCases.count
  }

  func markProfileGenerated() {
    profileGenerated = true
    if profileRevisionStatus == .available {
      profileRevisionStatus = .completed
      canRegenerateFromThree = false
      profileSignature = "A fresh debug profile from all three interviews."
    }
  }

  func markWingfoxGenerated() {
    wingfoxGenerated = true
  }

  func canReadInsight() -> Bool {
    profileGenerated
  }

  func personaCatalog(_ personas: [VoicePersona]) -> [VoicePersona] {
    personas.map { persona in
      VoicePersona(
        id: persona.id,
        type: persona.type,
        name: persona.name,
        completedSessionID: completedSessionIDs[persona.id]
      )
    }
  }

  func generationState() -> GenerationStateDTO? {
    guard let profileRevisionStatus else { return nil }
    return GenerationStateDTO(
      userID: ownerID,
      profileGenerated: profileGenerated,
      wingfoxGenerated: wingfoxGenerated,
      profileConfirmed: confirmed,
      profileRevisionStatus: profileRevisionStatus,
      canRegenerateFromThree: canRegenerateFromThree
    )
  }

  func currentProfileSignature() -> String { profileSignature }

  func markConfirmed() {
    confirmed = true
  }

  func isConfirmed() -> Bool { confirmed }
}

private actor VoiceProfileDebugAPI: VoiceProfileAPI {
  private let state: VoiceProfileDebugState
  private let personas: [VoicePersona] = [
    VoicePersona(
      id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
      type: .similar,
      name: "Aoi"
    ),
    VoicePersona(
      id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
      type: .complementary,
      name: "Mio"
    ),
    VoicePersona(
      id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
      type: .discovery,
      name: "Ren"
    )
  ]

  init(state: VoiceProfileDebugState) {
    self.state = state
  }

  func fetchPersonas() async throws -> [VoicePersona] {
    await state.personaCatalog(personas)
  }
  func generatePersonas() async throws -> [VoicePersona] { personas }
  func fetchGenerationState() async throws -> GenerationStateDTO? {
    await state.generationState()
  }

  func startSession(personaID: UUID) async throws -> VoiceSessionStartResult {
    guard let persona = personas.first(where: { $0.id == personaID }) else {
      throw APIClientError.notFound
    }
    let sessionID = UUID()
    await state.register(sessionID: sessionID, personaID: personaID)
    return VoiceSessionStartResult(
      sessionID: sessionID,
      personaID: persona.id,
      personaName: persona.name
    )
  }

  func fetchSignedURL(sessionID: UUID) async throws -> VoiceInterviewBootstrap {
    let overrides = VoiceInterviewOverrides(
      prompt: "Keep the conversation warm and concise.",
      firstMessage: "Hello, I'm ready to listen.",
      language: .en,
      voiceID: "debug-voice"
    )
    return VoiceInterviewBootstrap(
      signedURL: URL(string: "wss://api.elevenlabs.io/v1/convai/conversation?conversation_signature=debug-fixture")!,
      overrides: overrides,
      personaName: "Debug partner"
    )
  }

  func completeSession(sessionID: UUID, transcript: [VoiceTranscriptEntry]) async throws -> VoiceSessionCompletion {
    let allCompleted = try await state.complete(sessionID: sessionID)
    return VoiceSessionCompletion(
      sessionID: sessionID,
      status: "completed",
      allSessionsCompleted: allCompleted
    )
  }

  func generateProfile() async throws {
    await state.markProfileGenerated()
  }

  func generateWingfox() async throws {
    await state.markWingfoxGenerated()
  }

  func confirmProfile() async throws -> VoiceProfileConfirmation {
    guard await state.canReadInsight() else { throw APIClientError.invalidState }
    await state.markConfirmed()
    return VoiceProfileConfirmation(
      status: "confirmed",
      confirmedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }
}

private struct VoiceProfileDebugSettingsAPI: OnboardingSettingsAPI, Sendable {
  private static let settings = OnboardingSettings(
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

  func fetchSettings() async throws -> OnboardingSettings? { Self.settings }

  func fetchOptions(market: OnboardingDatingMarket, locale: OnboardingLanguage) async throws -> OnboardingOptions {
    throw APIClientError.invalidState
  }

  func saveSettings(_ settings: OnboardingSettings) async throws -> OnboardingSettings { settings }
}

private actor VoiceProfileDebugInsightAPI: ConversationInsightAPI {
  let state: VoiceProfileDebugState
  let ownerID: UUID
  private var editedTags: [String]?
  private var editedBio: String?

  init(state: VoiceProfileDebugState, ownerID: UUID) {
    self.state = state
    self.ownerID = ownerID
  }

  func updateDraftProfile(tags: [String], bio: String) async throws -> OwnInsight {
    guard await state.canReadInsight(), (3...5).contains(tags.count), bio.count <= 1_000 else { throw APIClientError.invalidState }
    editedTags = tags
    editedBio = bio
    return try await fetchInsight()
  }

  func fetchInsight() async throws -> OwnInsight {
    guard await state.canReadInsight() else { throw APIClientError.invalidState }
    let signature = await state.currentProfileSignature()
    return OwnInsight(
      id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
      userID: ownerID,
      personalityTags: editedTags ?? ["Listens carefully", "Enjoys thoughtful mornings"],
      // Personal profiles are saved as drafts until the explicit confirm
      // action succeeds, matching the live generation contract.
      status: "draft",
      overallSignature: signature,
      bio: editedBio
    )
  }
}
#endif
