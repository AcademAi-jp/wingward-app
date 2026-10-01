import Foundation
import Observation

enum VoiceProfileStoreError: Error, Equatable, Sendable {
  case unauthenticated
  case ageVerificationRequired
  case forbidden
  case notFound
  case ownerMismatch
  case settingsUnavailable
  case invalidResponse
  case invalidState
  case microphonePermissionDenied
  case voiceUnavailable
  case voiceConnectionFailed
  case completionFailed
  case generationFailed
  case partnerGenerationFailed
  case confirmationFailed
  case rateLimited
  case temporarilyUnavailable
  case cancelled

  var userMessage: String {
    switch self {
    case .microphonePermissionDenied:
      return "Allow microphone access to start the interview, then try again."
    case .voiceUnavailable:
      return "The voice interview is not available yet."
    case .voiceConnectionFailed:
      return "The interview connection ended before it could be saved."
    case .completionFailed:
      return "We couldn't verify that this interview was saved. The interview is not marked complete."
    case .generationFailed:
      return "We couldn't prepare your profile. Try again later."
    case .partnerGenerationFailed:
      return "Your personal profile is saved, but we couldn't prepare your AI partner. Try again."
    case .confirmationFailed:
      return "Your personal profile is saved, but we couldn't save your confirmation. Try again."
    case .settingsUnavailable:
      return "Complete your conversation settings before starting an interview."
    case .ageVerificationRequired:
      return "Verify your age before starting the interview."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .unauthenticated, .forbidden, .notFound, .ownerMismatch, .invalidResponse,
      .invalidState, .temporarilyUnavailable, .cancelled:
      return "We couldn't continue the interview. Try again."
    }
  }
}

enum VoiceProfileStorePhase: Equatable, Sendable {
  case idle
  case loading
  case candidates
  case permissionDenied
  case connecting
  case interviewing
  case savingInterview
  case completionFailed
  case readyToGenerate
  case generating
  case confirming
  case review
  case confirmed
  case failed(VoiceProfileStoreError)
}

@MainActor
@Observable
final class VoiceProfileStore {
  var selectedRealtimeVoice: RealtimeVoice = .cedar
  func realtimeVoice(for type: VoicePersonaType) -> RealtimeVoice {
    let voices = RealtimeVoice.allCases
    let offset = voices.firstIndex(of: selectedRealtimeVoice) ?? 0
    return voices[(offset + type.sortOrder) % voices.count]
  }

  static let interviewDurationSeconds = 120
  private(set) var interviewStartedAt: Date?
  static let requiredInterviewCount = VoicePersonaType.allCases.count
  static let maxTranscriptEntries = 200

  private(set) var ownerID: String
  private(set) var phase: VoiceProfileStorePhase = .idle
  private(set) var personas: [VoicePersona] = []
  private(set) var currentPersonaIndex: Int?
  private(set) var currentSessionID: UUID?
  private(set) var transcript: [VoiceTranscriptEntry] = []
  private(set) var completedSessionIDs: Set<UUID> = []
  private(set) var completedPersonaIDs: Set<UUID> = []
  private(set) var requiredInterviewCount: Int = VoiceProfileStore.requiredInterviewCount
  private(set) var interviewWaiverActive = false
  private(set) var profileRevisionStatus: VoiceProfileRevisionStatus?
  private(set) var canRegenerateFromThree = false
  private(set) var profileRevisionNeedsRefresh = false
  private(set) var isCreatingNewProfileFromThree = false
  private(set) var insight: OwnInsight?
  private(set) var lastError: VoiceProfileStoreError?
  private(set) var isSpeaking = false
  private(set) var isSavingDraft = false
  private(set) var draftEditError: String?
  private(set) var draftNeedsRefresh = false

  private let apiOwnerID: String
  private let module: VoiceProfileModule
  @ObservationIgnored private var operationTask: Task<Void, Never>?
  @ObservationIgnored private var pendingCompletion: PendingCompletion?
  private var generation = 0
  private var endRequested = false
  private var didGenerateProfile = false
  private var didGenerateWingfox = false

  /// The only data retained after a completion request fails. This payload is
  /// owner-bound and remains in memory until the user retries, discards the
  /// interview, cancels, or changes accounts. A retry therefore submits the
  /// exact session and transcript that failed, without recording another call.
  private struct PendingCompletion: Equatable, Sendable {
    let ownerID: String
    let sessionID: UUID
    let personaID: UUID
    let transcript: [VoiceTranscriptEntry]
  }

  init(ownerID: String, module: VoiceProfileModule) {
    self.ownerID = ownerID
    self.apiOwnerID = ownerID
    self.module = module
  }

  var currentPersona: VoicePersona? {
    guard let currentPersonaIndex, personas.indices.contains(currentPersonaIndex) else { return nil }
    return personas[currentPersonaIndex]
  }

  var hasAllInterviews: Bool {
    completedPersonaIDs.count >= requiredInterviewCount
  }

  var canGenerateProfile: Bool {
    (phase == .readyToGenerate || phase == .failed(.generationFailed))
      && hasAllInterviews
      && ownerID == apiOwnerID
      && profileRevisionStatus == nil
      && !profileRevisionNeedsRefresh
  }

  var needsPersonaGeneration: Bool {
    personas.count < Self.requiredInterviewCount && phase == .candidates
  }

  var needsWingfoxGeneration: Bool {
    !didGenerateWingfox && profileRevisionStatus != .completed
  }

  var canCreateNewProfileFromThree: Bool {
    phase == .review
      && profileRevisionStatus == .available
      && canRegenerateFromThree
      && !profileRevisionNeedsRefresh
      && ownerID == apiOwnerID
  }

  var canConfirmProfile: Bool {
    phase == .review
      && insight != nil
      && !profileRevisionBlocksConfirmation
      && !isSavingDraft && !draftNeedsRefresh
  }

  var profileRevisionBlocksConfirmation: Bool {
    profileRevisionNeedsRefresh
      || profileRevisionStatus == .available
      || profileRevisionStatus == .claimed
  }

  func isPersonaCompleted(_ persona: VoicePersona) -> Bool {
    completedPersonaIDs.contains(persona.id)
  }

  var isBusy: Bool {
    switch phase {
    case .loading, .connecting, .interviewing, .savingInterview, .generating, .confirming:
      return true
    case .idle, .candidates, .permissionDenied, .completionFailed, .readyToGenerate,
      .review, .confirmed, .failed:
      return false
    }
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    guard ownerID == apiOwnerID else {
      clearProtectedContent()
      lastError = .ownerMismatch
      phase = .failed(.ownerMismatch)
      return Task {}
    }
    invalidateOperation()
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    clearProtectedContent()
    phase = .loading
    lastError = nil

    let task = Task { [weak self] in
      guard let self else { return }
      await self.performLoad(ownerID: capturedOwnerID, generation: capturedGeneration)
    }
    operationTask = task
    return task
  }

  @discardableResult
  func retryLoad() -> Task<Void, Never> {
    load()
  }

  @discardableResult
  func generatePersonas() -> Task<Void, Never> {
    guard ownerID == apiOwnerID, !isBusy else { return Task {} }
    invalidateOperation()
    pendingCompletion = nil
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    phase = .loading
    lastError = nil

    let task = Task { [weak self] in
      guard let self else { return }
      await self.performGeneratePersonas(ownerID: capturedOwnerID, generation: capturedGeneration)
    }
    operationTask = task
    return task
  }

  @discardableResult
  func startInterview(personaID: UUID) -> Task<Void, Never> {
    guard ownerID == apiOwnerID, !isBusy,
      let index = personas.firstIndex(where: { $0.id == personaID })
    else { return Task {} }

    guard !completedPersonaIDs.contains(personaID) else {
      lastError = .invalidState
      phase = .failed(.invalidState)
      return Task {}
    }

    guard module.transport.isAvailable else {
      lastError = .voiceUnavailable
      phase = .failed(.voiceUnavailable)
      return Task {}
    }

    invalidateOperation()
    pendingCompletion = nil
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    currentPersonaIndex = index
    currentSessionID = nil
    transcript = []
    isSpeaking = false
    endRequested = false
    lastError = nil
    phase = .connecting

    let task = Task { [weak self] in
      guard let self else { return }
      await self.performStartInterview(
        personaID: personaID,
        ownerID: capturedOwnerID,
        generation: capturedGeneration
      )
    }
    operationTask = task
    return task
  }

  /// Requests a graceful provider stop. The transport contract requires it to
  /// close its stream with `.ended`; only that event is allowed to submit the
  /// transcript. A cancellation or socket failure never claims completion.
  func endInterview() {
    guard phase == .interviewing else { return }
    endRequested = true
    let transport = module.transport
    Task { await transport.stop() }
  }

  /// Retries only the completion request that failed. The interview transport
  /// is never started again, and the retained payload is immutable so the
  /// retry cannot accidentally submit a different session or transcript.
  @discardableResult
  func retryCompletion() -> Task<Void, Never> {
    guard ownerID == apiOwnerID,
      phase == .completionFailed,
      let pending = pendingCompletion,
      pending.ownerID == ownerID,
      !isBusy
    else { return Task {} }

    invalidateOperation()
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    phase = .savingInterview
    lastError = nil

    let task = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.submitCompletion(
          pending: pending,
          ownerID: capturedOwnerID,
          generation: capturedGeneration
        )
      } catch {
        // submitCompletion preserves completionFailed and the pending payload
        // for an explicit next retry. Stale/cancelled work exits silently.
      }
    }
    operationTask = task
    return task
  }

  /// Drops an unsubmitted or failed interview. No transcript or signed URL is
  /// retained after this method returns.
  func discardCurrentInterview() {
    guard phase == .completionFailed || phase == .permissionDenied || phase == .failed(.voiceConnectionFailed) else {
      return
    }
    invalidateOperation()
    Task { await module.transport.stop() }
    pendingCompletion = nil
    clearInterviewContent()
    lastError = nil
    phase = hasAllInterviews ? .readyToGenerate : .candidates
  }

  @discardableResult
  func generateProfile() -> Task<Void, Never> {
    guard ownerID == apiOwnerID,
      profileRevisionStatus == nil,
      !profileRevisionNeedsRefresh,
      canGenerateProfile || (phase == .failed(.generationFailed) && hasAllInterviews)
    else { return Task {} }
    invalidateOperation()
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    phase = .generating
    lastError = nil

    let task = Task { [weak self] in
      guard let self else { return }
      await self.performGenerateProfile(
        ownerID: capturedOwnerID,
        generation: capturedGeneration,
        profileRevision: false
      )
    }
    operationTask = task
    return task
  }

  @discardableResult
  func createNewProfileFromThree() -> Task<Void, Never> {
    guard ownerID == apiOwnerID, canCreateNewProfileFromThree else { return Task {} }
    invalidateOperation()
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    profileRevisionNeedsRefresh = true
    isCreatingNewProfileFromThree = true
    phase = .generating
    lastError = nil

    let task = Task { [weak self] in
      guard let self else { return }
      await self.performGenerateProfile(
        ownerID: capturedOwnerID,
        generation: capturedGeneration,
        profileRevision: true
      )
    }
    operationTask = task
    return task
  }

  var canEditDraftProfile: Bool {
    phase == .review && insight?.status == "draft" && ownerID == apiOwnerID
      && !profileRevisionBlocksConfirmation && !isSavingDraft && !draftNeedsRefresh
  }

  func saveDraftProfile(tags: [String], bio: String) async {
    guard canEditDraftProfile, let previous = insight else { return }
    let capturedOwner = ownerID
    let capturedGeneration = generation
    guard (3...5).contains(tags.count), Set(tags).count == tags.count,
      tags.allSatisfy({ !$0.isEmpty && $0.count <= 100 }), bio.count <= 1_000 else {
      draftEditError = "Use 3–5 different tags up to 100 characters each and a bio up to 1,000 characters."
      return
    }
    isSavingDraft = true
    draftNeedsRefresh = true
    draftEditError = nil
    do {
      let value = try await module.insightAPI.updateDraftProfile(tags: tags, bio: bio)
      guard isCurrent(ownerID: capturedOwner, generation: capturedGeneration) else { return }
      try OwnInsight.validate(value)
      guard value.id == previous.id, value.userID.uuidString.caseInsensitiveCompare(capturedOwner) == .orderedSame,
        value.status == "draft", value.personalityTags == tags, (value.bio ?? "") == bio else { throw APIClientError.invalidResponse }
      insight = value
      draftNeedsRefresh = false
      isSavingDraft = false
    } catch {
      guard isCurrent(ownerID: capturedOwner, generation: capturedGeneration) else { return }
      isSavingDraft = false
      draftEditError = "We couldn't confirm that your draft was saved. Refresh profile status before confirming."
    }
  }

  @discardableResult
  func confirmProfile() -> Task<Void, Never> {
    guard ownerID == apiOwnerID, canConfirmProfile else { return Task {} }
    invalidateOperation()
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    lastError = nil
    phase = .confirming

    let task = Task { [weak self] in
      guard let self else { return }
      await self.performConfirmProfile(ownerID: capturedOwnerID, generation: capturedGeneration)
    }
    operationTask = task
    return task
  }

  func cancel() {
    invalidateOperation()
    Task { await module.transport.stop() }
    clearProtectedContent()
    lastError = nil
    phase = .idle
    isSavingDraft = false
    draftNeedsRefresh = false
    draftEditError = nil
  }

  func updateOwner(_ newOwnerID: String) {
    guard ownerID != newOwnerID else { return }
    cancel()
    ownerID = newOwnerID
  }

  private func performLoad(ownerID: String, generation: Int) async {
    do {
      guard let settings = try await module.settingsAPI.fetchSettings() else {
        throw VoiceProfileStoreError.settingsUnavailable
      }
      try OnboardingSettings.validate(settings)
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }

      let fetched = try await module.api.fetchPersonas()
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      try applyPersonas(fetched)

      // Keep the generation action unavailable until the server-owned state
      // and, when needed, the saved insight have both been hydrated.
      phase = .loading
      let generationState = try await module.api.fetchGenerationState()
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      if let generationState {
        try restoreGenerationState(
          generationState,
          ownerID: ownerID,
          generation: generation
        )
        guard isCurrent(ownerID: ownerID, generation: generation) else { return }
        if generationState.profileGenerated {
          let savedInsight = try await module.insightAPI.fetchInsight()
          guard isCurrent(ownerID: ownerID, generation: generation) else { return }
          try OwnInsight.validate(savedInsight)
          guard isCurrent(ownerID: ownerID, generation: generation) else { return }
          guard savedInsight.userID.uuidString.caseInsensitiveCompare(ownerID) == .orderedSame else {
            throw VoiceProfileStoreError.ownerMismatch
          }
          let expectedStatus = generationState.profileConfirmed ? "confirmed" : "draft"
          guard savedInsight.status == expectedStatus else {
            throw VoiceProfileDTOValidationError.invalidStatus
          }
          insight = savedInsight
          draftNeedsRefresh = false
          draftEditError = nil
          phase = generationState.profileConfirmed ? .confirmed : .review
        }
      } else {
        // Compatibility fakes do not expose generation state. Persona
        // completion remains the only local source for that legacy path.
        phase = hasAllInterviews ? .readyToGenerate : .candidates
      }
      lastError = nil
      operationTask = nil
    } catch {
      handleFailure(error, ownerID: ownerID, generation: generation, generationFailure: false)
    }
  }

  private func performGeneratePersonas(ownerID: String, generation: Int) async {
    do {
      guard let settings = try await module.settingsAPI.fetchSettings() else {
        throw VoiceProfileStoreError.settingsUnavailable
      }
      try OnboardingSettings.validate(settings)
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }

      let generated = try await module.api.generatePersonas()
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      try VoicePersonasPayload.validate(VoicePersonasPayload(personas: generated))
      guard generated.count == Self.requiredInterviewCount else {
        throw VoiceProfileDTOValidationError.invalidPersonaCount
      }
      // Reload the authoritative catalog, including saved completion markers.
      let saved = try await module.api.fetchPersonas()
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      try applyPersonas(saved.isEmpty ? generated : saved)
      lastError = nil
      operationTask = nil
    } catch {
      handleFailure(error, ownerID: ownerID, generation: generation, generationFailure: false)
    }
  }

  private func performStartInterview(personaID: UUID, ownerID: String, generation: Int) async {
    do {
      guard let settings = try await module.settingsAPI.fetchSettings() else {
        throw VoiceProfileStoreError.settingsUnavailable
      }
      try OnboardingSettings.validate(settings)
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }

      let permission = await module.permissionClient.requestMicrophonePermission()
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      guard permission == .granted else {
        phase = .permissionDenied
        lastError = .microphonePermissionDenied
        operationTask = nil
        return
      }

      let session = try await module.api.startSession(personaID: personaID)
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      guard session.personaID == personaID else { throw VoiceProfileDTOValidationError.ownerMismatch }

      let request: VoiceInterviewRequest
      switch module.bootstrapKind {
      case .legacySignedURL:
        let bootstrap = try await module.api.fetchSignedURL(sessionID: session.sessionID)
        guard isCurrent(ownerID: ownerID, generation: generation) else { return }
        try VoiceInterviewBootstrap.validate(bootstrap)
        guard bootstrap.overrides.language == settings.conversationLanguage else {
          throw VoiceProfileDTOValidationError.unsupportedLanguage
        }
        request = VoiceInterviewRequest(
          sessionID: session.sessionID,
          signedURL: bootstrap.signedURL,
          overrides: bootstrap.overrides
        )
      case .openAIRealtime:
        guard let persona = currentPersona else { throw VoiceProfileStoreError.invalidState }
        let voice = realtimeVoice(for: persona.type)
        let bootstrap = try await module.api.fetchRealtimeBootstrap(sessionID: session.sessionID, voice: voice)
        guard isCurrent(ownerID: ownerID, generation: generation) else { return }
        try RealtimeVoiceBootstrap.validate(bootstrap)
        guard bootstrap.sessionID == session.sessionID, bootstrap.overrides.language == settings.conversationLanguage,
          bootstrap.overrides.voiceID == voice.rawValue else { throw VoiceProfileDTOValidationError.invalidSession }
        request = VoiceInterviewRequest(sessionID: session.sessionID,
          credential: bootstrap.serverBounded ? .serverBoundedRealtime(maxSeconds: bootstrap.maxDurationSeconds)
            : .realtimeSecret(bootstrap.clientSecret, expiresAt: bootstrap.expiresAt), overrides: bootstrap.overrides)
      case .nativeConversationToken:
        let bootstrap = try await module.api.fetchNativeBootstrap(sessionID: session.sessionID)
        guard isCurrent(ownerID: ownerID, generation: generation) else { return }
        guard bootstrap.sessionID == session.sessionID else {
          throw VoiceProfileDTOValidationError.invalidSession
        }
        try NativeVoiceBootstrap.validate(bootstrap)
        guard bootstrap.overrides.language == settings.conversationLanguage else {
          throw VoiceProfileDTOValidationError.unsupportedLanguage
        }
        request = VoiceInterviewRequest(
          sessionID: session.sessionID,
          credential: .conversationToken(bootstrap.conversationToken),
          overrides: bootstrap.overrides
        )
      }
      try VoiceInterviewRequest.validate(request)
      currentSessionID = session.sessionID

      let stream = try await module.transport.start(request)
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      interviewStartedAt = Date()
      phase = .interviewing

      var ended = false
      for try await event in stream {
        guard isCurrent(ownerID: ownerID, generation: generation) else { return }
        switch event {
        case .connected:
          break
        case let .speaking(value):
          isSpeaking = value
        case let .transcript(entry):
          try VoiceTranscriptEntry.validate(entry)
          guard transcript.count < Self.maxTranscriptEntries else {
            throw VoiceProfileDTOValidationError.invalidTranscript
          }
          transcript.append(entry)
        case .ended:
          ended = true
        }
        if ended { break }
      }

      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      guard ended else {
        throw VoiceInterviewTransportError.connectionFailed
      }
      phase = .savingInterview
      isSpeaking = false
      try await performCompletion(ownerID: ownerID, generation: generation)
    } catch {
      handleInterviewFailure(error: error, ownerID: ownerID, generation: generation)
    }
  }

  private func performCompletion(ownerID: String, generation: Int) async throws {
    guard let sessionID = currentSessionID,
      let personaID = currentPersona?.id,
      isCurrent(ownerID: ownerID, generation: generation)
    else { return }

    let pending = PendingCompletion(
      ownerID: ownerID,
      sessionID: sessionID,
      personaID: personaID,
      transcript: transcript
    )
    pendingCompletion = pending
    try await submitCompletion(pending: pending, ownerID: ownerID, generation: generation)
  }

  private func submitCompletion(
    pending: PendingCompletion,
    ownerID: String,
    generation: Int
  ) async throws {
    guard pending.ownerID == ownerID,
      pending.ownerID == self.ownerID,
      pendingCompletion == pending,
      isCurrent(ownerID: ownerID, generation: generation)
    else { return }

    do {
      let completion = try await module.api.completeSession(
        sessionID: pending.sessionID,
        transcript: pending.transcript
      )
      guard isCurrent(ownerID: ownerID, generation: generation),
        pendingCompletion == pending
      else { return }
      guard completion.sessionID == pending.sessionID, completion.status == "completed" else {
        throw VoiceProfileDTOValidationError.invalidSession
      }
      completedSessionIDs.insert(pending.sessionID)
      completedPersonaIDs.insert(pending.personaID)
      pendingCompletion = nil
      clearInterviewContent()
      phase = hasAllInterviews ? .readyToGenerate : .candidates
      lastError = nil
      operationTask = nil
      if hasAllInterviews {
        // A saved draft can predate the final interview. Ask the server for
        // its current owner-bound state before offering profile generation.
        // Keep the acknowledged completion markers while doing this read.
        await restoreSavedDraftAfterCompletion(ownerID: ownerID, generation: generation)
      }
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation),
        pendingCompletion == pending
      else { return }
      // A failed response cannot tell us whether the atomic server save
      // committed. Keep the exact payload for an explicit idempotent retry;
      // never claim success until its acknowledgement is validated.
      phase = .completionFailed
      lastError = .completionFailed
      operationTask = nil
      throw error
    }
  }

  private func performGenerateProfile(
    ownerID: String,
    generation: Int,
    profileRevision: Bool
  ) async {
    do {
      if profileRevision || !didGenerateProfile {
        try await module.api.generateProfile()
        guard isCurrent(ownerID: ownerID, generation: generation) else { return }
        didGenerateProfile = true
      }
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      if profileRevision {
        guard let state = try await module.api.fetchGenerationState(),
          isCurrent(ownerID: ownerID, generation: generation)
        else { throw VoiceProfileStoreError.invalidState }
        try restoreGenerationState(state, ownerID: ownerID, generation: generation)
        guard state.profileRevisionStatus == .completed, state.profileGenerated else {
          throw VoiceProfileStoreError.invalidState
        }
      }
      let insight = try await module.insightAPI.fetchInsight()
      try OwnInsight.validate(insight)
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      guard insight.userID.uuidString.caseInsensitiveCompare(ownerID) == .orderedSame else {
        throw VoiceProfileStoreError.ownerMismatch
      }
      guard insight.status == "draft" else {
        throw VoiceProfileDTOValidationError.invalidStatus
      }
      self.insight = insight
      phase = .review
      isCreatingNewProfileFromThree = false
      profileRevisionNeedsRefresh = false
      lastError = nil
      operationTask = nil
    } catch {
      if profileRevision {
        await recoverProfileRevision(ownerID: ownerID, generation: generation)
      } else {
        handleFailure(error, ownerID: ownerID, generation: generation, generationFailure: true)
      }
    }
  }

  private func recoverProfileRevision(ownerID: String, generation: Int) async {
    guard isCurrent(ownerID: ownerID, generation: generation) else { return }
    do {
      guard let state = try await module.api.fetchGenerationState(),
        isCurrent(ownerID: ownerID, generation: generation)
      else { throw VoiceProfileStoreError.invalidState }
      try restoreGenerationState(state, ownerID: ownerID, generation: generation)

      if state.profileRevisionStatus == .completed, state.profileGenerated {
        let replacement = try await module.insightAPI.fetchInsight()
        try OwnInsight.validate(replacement)
        guard isCurrent(ownerID: ownerID, generation: generation),
          replacement.userID.uuidString.caseInsensitiveCompare(ownerID) == .orderedSame,
          replacement.status == (state.profileConfirmed ? "confirmed" : "draft")
        else { throw VoiceProfileStoreError.invalidResponse }
        insight = replacement
        phase = state.profileConfirmed ? .confirmed : .review
        lastError = nil
      } else {
        phase = state.profileGenerated ? .review : .failed(.generationFailed)
        lastError = .generationFailed
      }
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      // A failed status read leaves the revision and confirmation controls
      // closed until a fresh owner-bound GET resolves the server state.
      profileRevisionNeedsRefresh = true
      phase = .review
      lastError = .temporarilyUnavailable
    }
    isCreatingNewProfileFromThree = false
    operationTask = nil
  }

  private func restoreSavedDraftAfterCompletion(ownerID: String, generation: Int) async {
    do {
      guard let state = try await module.api.fetchGenerationState(),
        isCurrent(ownerID: ownerID, generation: generation)
      else { return }
      try restoreGenerationState(state, ownerID: ownerID, generation: generation)
      guard state.profileGenerated else { return }
      let savedInsight = try await module.insightAPI.fetchInsight()
      try OwnInsight.validate(savedInsight)
      guard isCurrent(ownerID: ownerID, generation: generation),
        savedInsight.userID.uuidString.caseInsensitiveCompare(ownerID) == .orderedSame,
        savedInsight.status == (state.profileConfirmed ? "confirmed" : "draft")
      else { throw VoiceProfileStoreError.invalidResponse }
      insight = savedInsight
      phase = state.profileConfirmed ? .confirmed : .review
      lastError = nil
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      // Completion was already acknowledged. Require a fresh load rather than
      // offering a generation action whose saved-state check just failed.
      let failure = Self.map(error)
      lastError = failure
      phase = .failed(failure)
    }
  }

  private func performConfirmProfile(ownerID: String, generation: Int) async {
    do {
      guard isCurrent(ownerID: ownerID, generation: generation),
        insight != nil,
        !profileRevisionBlocksConfirmation
      else { return }
      if needsWingfoxGeneration {
        do {
          try await module.api.generateWingfox()
        } catch {
          guard isCurrent(ownerID: ownerID, generation: generation) else { return }
          if isCancellation(error) { throw error }
          throw VoiceProfileStoreError.partnerGenerationFailed
        }
        guard isCurrent(ownerID: ownerID, generation: generation) else { return }
        didGenerateWingfox = true
      }
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      let confirmation = try await module.api.confirmProfile()
      try VoiceProfileConfirmation.validate(confirmation)
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      phase = .confirmed
      lastError = nil
      operationTask = nil
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      if isCancellation(error) {
        lastError = nil
      } else if let generationError = error as? VoiceProfileStoreError {
        lastError = generationError
      } else {
        lastError = .confirmationFailed
      }
      phase = .review
      operationTask = nil
    }
  }

  private func handleInterviewFailure(error: Error, ownerID: String, generation: Int) {
    guard isCurrent(ownerID: ownerID, generation: generation) else { return }
    if isCancellation(error) {
      clearInterviewContent()
      phase = .candidates
      lastError = nil
      operationTask = nil
      return
    }
    if phase == .completionFailed { return }
    clearInterviewContent()
    let mapped = Self.map(error)
    lastError = mapped
    phase = .failed(mapped)
    operationTask = nil
  }

  private func handleFailure(
    _ error: Error,
    ownerID: String,
    generation: Int,
    generationFailure: Bool
  ) {
    guard isCurrent(ownerID: ownerID, generation: generation) else { return }
    clearInterviewContent()
    if isCancellation(error) {
      phase = .idle
      lastError = nil
    } else {
      let mapped: VoiceProfileStoreError = generationFailure ? .generationFailed : Self.map(error)
      lastError = mapped
      phase = .failed(mapped)
    }
    operationTask = nil
  }

  private func clearInterviewContent() {
    currentPersonaIndex = nil
    currentSessionID = nil
    transcript = []
    isSpeaking = false
    endRequested = false
  }

  private func restoreGenerationState(
    _ state: GenerationStateDTO,
    ownerID: String,
    generation: Int
  ) throws {
    try GenerationStateDTO.validate(state)
    guard state.userID.uuidString.caseInsensitiveCompare(ownerID) == .orderedSame else {
      throw VoiceProfileStoreError.ownerMismatch
    }
    guard isCurrent(ownerID: ownerID, generation: generation) else { return }

    didGenerateProfile = state.profileGenerated
    didGenerateWingfox = state.wingfoxGenerated
    profileRevisionStatus = state.profileRevisionStatus
    canRegenerateFromThree = state.canRegenerateFromThree ?? false
    profileRevisionNeedsRefresh = false
    requiredInterviewCount = state.requiredInterviewCount
    interviewWaiverActive = state.interviewWaiverActive
    guard state.profileGenerated else {
      phase = hasAllInterviews ? .readyToGenerate : .candidates
      return
    }

    // The generation-state route is read-only. Saved insight hydration is
    // performed by performLoad after this validation returns.
  }

  /// Replaces the catalog and restores completion markers supplied by the
  /// owner-bound GET response. A generated catalog may omit markers, which
  /// intentionally resets only the in-memory progress projection for that
  /// catalog; the server remains the source of truth on the next load.
  private func applyPersonas(_ values: [VoicePersona]) throws {
    try VoicePersonasPayload.validate(VoicePersonasPayload(personas: values))

    let sortedPersonas = values.sorted { $0.type.sortOrder < $1.type.sortOrder }
    var restoredCompletedSessionIDs = Set<UUID>()
    var restoredCompletedPersonaIDs = Set<UUID>()
    for persona in sortedPersonas {
      guard let completedSessionID = persona.completedSessionID else { continue }
      // VoicePersonasPayload.validate rejects duplicate markers. Keep this
      // guard adjacent to hydration so future callers cannot accidentally
      // turn one session marker into multiple completion records.
      guard restoredCompletedSessionIDs.insert(completedSessionID).inserted else {
        throw VoiceProfileDTOValidationError.duplicateSession
      }
      restoredCompletedPersonaIDs.insert(persona.id)
    }

    personas = sortedPersonas
    completedSessionIDs = restoredCompletedSessionIDs
    completedPersonaIDs = restoredCompletedPersonaIDs
    phase = hasAllInterviews ? .readyToGenerate : .candidates
  }

  private func clearProtectedContent() {
    pendingCompletion = nil
    personas = []
    completedSessionIDs = []
    completedPersonaIDs = []
    requiredInterviewCount = Self.requiredInterviewCount
    interviewWaiverActive = false
    insight = nil
    didGenerateProfile = false
    didGenerateWingfox = false
    profileRevisionStatus = nil
    canRegenerateFromThree = false
    profileRevisionNeedsRefresh = false
    isCreatingNewProfileFromThree = false
    clearInterviewContent()
  }

  private func invalidateOperation() {
    operationTask?.cancel()
    operationTask = nil
    generation &+= 1
  }

  private func isCurrent(ownerID: String, generation: Int) -> Bool {
    !Task.isCancelled && self.ownerID == ownerID && self.generation == generation
  }

  private static func map(_ error: Error) -> VoiceProfileStoreError {
    if let storeError = error as? VoiceProfileStoreError { return storeError }
    if error is VoiceProfileDTOValidationError || error is APIDTOValidationError {
      return .invalidResponse
    }
    if error is OnboardingDTOValidationError { return .settingsUnavailable }
    if let transportError = error as? VoiceInterviewTransportError {
      switch transportError {
      case .unavailable: return .voiceUnavailable
      case .connectionFailed: return .voiceConnectionFailed
      case .cancelled: return .cancelled
      }
    }
    guard let clientError = error as? APIClientError else { return .temporarilyUnavailable }
    switch clientError {
    case .unauthenticated: return .unauthenticated
    case .ageVerificationRequired: return .ageVerificationRequired
    case .forbidden: return .forbidden
    case .notFound: return .notFound
    case .invalidResponse, .invalidRequest, .invalidURL: return .invalidResponse
    case .invalidState: return .invalidState
    case .rateLimited: return .rateLimited
    case .cancelled: return .cancelled
    case .transportFailure, .temporarilyUnavailable, .quotaExhausted:
      return .temporarilyUnavailable
    }
  }

  private func isCancellation(_ error: Error) -> Bool {
    if let clientError = error as? APIClientError { return clientError == .cancelled }
    if let transportError = error as? VoiceInterviewTransportError { return transportError == .cancelled }
    return error is CancellationError || Task.isCancelled
  }
}
