import Foundation
import XCTest
@testable import Wingward

@MainActor
final class VoiceProfileTests: XCTestCase {
  private let ownerID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let sessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  private let personaIDs = [
    UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
    UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
    UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
  ]
  private let persistedSessionIDs = [
    UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
    UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
    UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
  ]

  func testPersonasAcceptPartialAndRejectDuplicateCatalogs() {
    let partial = tryDecode(
      envelope("""
      [{"id":"33333333-3333-4333-8333-333333333333","persona_type":"virtual_similar","name":"A"}]
      """),
      as: VoicePersonasPayload.self
    )
    XCTAssertEqual(partial?.personas.count, 1)

    let duplicate = tryDecode(
      envelope("""
      [
        {"id":"33333333-3333-4333-8333-333333333333","persona_type":"virtual_similar","name":"A"},
        {"id":"33333333-3333-4333-8333-333333333333","persona_type":"virtual_complementary","name":"B"},
        {"id":"55555555-5555-4555-8555-555555555555","persona_type":"virtual_discovery","name":"C"}
      ]
      """),
      as: VoicePersonasPayload.self
    )
    XCTAssertNil(duplicate)
  }

  func testPersonasDecodeOptionalCompletionMarkersAndRejectMalformedOrDuplicateMarkers() {
    let payload = tryDecode(
      envelope("""
      [
        {"id":"33333333-3333-4333-8333-333333333333","persona_type":"virtual_similar","name":"A","completed_session_id":"88888888-8888-4888-8888-888888888888"},
        {"id":"44444444-4444-4444-8444-444444444444","persona_type":"virtual_complementary","name":"B","completed_session_id":null},
        {"id":"55555555-5555-4555-8555-555555555555","persona_type":"virtual_discovery","name":"C"}
      ]
      """),
      as: VoicePersonasPayload.self
    )
    XCTAssertEqual(payload?.personas[0].completedSessionID, persistedSessionIDs[0])
    XCTAssertNil(payload?.personas[1].completedSessionID)
    XCTAssertNil(payload?.personas[2].completedSessionID)

    let malformed = tryDecode(
      envelope("""
      [
        {"id":"33333333-3333-4333-8333-333333333333","persona_type":"virtual_similar","name":"A","completed_session_id":"unknown-session"},
        {"id":"44444444-4444-4444-8444-444444444444","persona_type":"virtual_complementary","name":"B"},
        {"id":"55555555-5555-4555-8555-555555555555","persona_type":"virtual_discovery","name":"C"}
      ]
      """),
      as: VoicePersonasPayload.self
    )
    XCTAssertNil(malformed)

    let duplicate = tryDecode(
      envelope("""
      [
        {"id":"33333333-3333-4333-8333-333333333333","persona_type":"virtual_similar","name":"A","completed_session_id":"88888888-8888-4888-8888-888888888888"},
        {"id":"44444444-4444-4444-8444-444444444444","persona_type":"virtual_complementary","name":"B","completed_session_id":"88888888-8888-4888-8888-888888888888"},
        {"id":"55555555-5555-4555-8555-555555555555","persona_type":"virtual_discovery","name":"C"}
      ]
      """),
      as: VoicePersonasPayload.self
    )
    XCTAssertNil(duplicate)
  }

  func testGenerationStateDecodesAndRejectsContradictoryFlags() {
    let valid = tryDecode(
      envelope("""
      {
        "user_id":"11111111-1111-4111-8111-111111111111",
        "profile_generated":true,
        "wingfox_generated":false,
        "profile_confirmed":false
      }
      """),
      as: GenerationStateDTO.self
    )
    XCTAssertEqual(valid?.userID, ownerID)
    XCTAssertEqual(valid?.profileGenerated, true)
    XCTAssertEqual(valid?.wingfoxGenerated, false)
    XCTAssertEqual(valid?.profileConfirmed, false)
    XCTAssertEqual(valid?.requiredInterviewCount, 3)
    XCTAssertFalse(valid?.interviewWaiverActive ?? true)

    for flags in [
      (false, true, false),
      (false, false, true),
      (true, false, true)
    ] {
      let contradictory = tryDecode(
        envelope("""
        {
          "user_id":"11111111-1111-4111-8111-111111111111",
          "profile_generated":(flags.0),
          "wingfox_generated":(flags.1),
          "profile_confirmed":(flags.2)
        }
        """),
        as: GenerationStateDTO.self
      )
      XCTAssertNil(contradictory)
    }
  }

  func testGenerationStateAcceptsOnlyExplicitTwoInterviewWaiver() {
    let waiver = tryDecode(
      envelope("""
      {
        "user_id":"11111111-1111-4111-8111-111111111111",
        "profile_generated":false,
        "wingfox_generated":false,
        "profile_confirmed":false,
        "required_interview_count":2,
        "interview_waiver_active":true
      }
      """),
      as: GenerationStateDTO.self
    )
    XCTAssertEqual(waiver?.requiredInterviewCount, 2)
    XCTAssertTrue(waiver?.interviewWaiverActive ?? false)

    let malformed = tryDecode(
      envelope("""
      {
        "user_id":"11111111-1111-4111-8111-111111111111",
        "profile_generated":false,
        "wingfox_generated":false,
        "profile_confirmed":false,
        "required_interview_count":2,
        "interview_waiver_active":false
      }
      """),
      as: GenerationStateDTO.self
    )
    XCTAssertNil(malformed)
  }

  func testGenerationStateDecodesProfileRevisionAndRejectsUnsafeCombinations() {
    let available = tryDecode(
      envelope("""
      {
        "user_id":"11111111-1111-4111-8111-111111111111",
        "profile_generated":true,
        "wingfox_generated":true,
        "profile_confirmed":false,
        "profile_revision_status":"available",
        "can_regenerate_from_three":true
      }
      """),
      as: GenerationStateDTO.self
    )
    XCTAssertEqual(available?.profileRevisionStatus, .available)
    XCTAssertEqual(available?.canRegenerateFromThree, true)

    let claimed = tryDecode(
      envelope("""
      {
        "user_id":"11111111-1111-4111-8111-111111111111",
        "profile_generated":true,
        "wingfox_generated":true,
        "profile_confirmed":false,
        "profile_revision_status":"claimed",
        "can_regenerate_from_three":false
      }
      """),
      as: GenerationStateDTO.self
    )
    XCTAssertEqual(claimed?.profileRevisionStatus, .claimed)
    XCTAssertEqual(claimed?.canRegenerateFromThree, false)

    let completed = tryDecode(
      envelope("""
      {
        "user_id":"11111111-1111-4111-8111-111111111111",
        "profile_generated":true,
        "wingfox_generated":true,
        "profile_confirmed":false,
        "profile_revision_status":"completed",
        "can_regenerate_from_three":false
      }
      """),
      as: GenerationStateDTO.self
    )
    XCTAssertEqual(completed?.profileRevisionStatus, .completed)
    XCTAssertEqual(completed?.canRegenerateFromThree, false)

    let malformedStates = [
      #"{"user_id":"11111111-1111-4111-8111-111111111111","profile_generated":true,"wingfox_generated":true,"profile_confirmed":false,"profile_revision_status":"unknown","can_regenerate_from_three":false}"#,
      #"{"user_id":"11111111-1111-4111-8111-111111111111","profile_generated":true,"wingfox_generated":true,"profile_confirmed":false,"profile_revision_status":"claimed","can_regenerate_from_three":true}"#,
      #"{"user_id":"11111111-1111-4111-8111-111111111111","profile_generated":true,"wingfox_generated":true,"profile_confirmed":false,"profile_revision_status":"completed","can_regenerate_from_three":true}"#,
      #"{"user_id":"11111111-1111-4111-8111-111111111111","profile_generated":true,"wingfox_generated":true,"profile_confirmed":false,"profile_revision_status":"available"}"#,
      #"{"user_id":"11111111-1111-4111-8111-111111111111","profile_generated":true,"wingfox_generated":true,"profile_confirmed":false,"can_regenerate_from_three":true}"#,
      #"{"user_id":"11111111-1111-4111-8111-111111111111","profile_generated":false,"wingfox_generated":false,"profile_confirmed":false,"profile_revision_status":"available","can_regenerate_from_three":true}"#,
      #"{"user_id":"11111111-1111-4111-8111-111111111111","profile_generated":true,"wingfox_generated":true,"profile_confirmed":true,"profile_revision_status":"available","can_regenerate_from_three":true}"#,
      #"{"user_id":"11111111-1111-4111-8111-111111111111","profile_generated":true,"wingfox_generated":false,"profile_confirmed":false,"profile_revision_status":"claimed","can_regenerate_from_three":false}"#,
      #"{"user_id":"11111111-1111-4111-8111-111111111111","profile_generated":true,"wingfox_generated":true,"profile_confirmed":false,"required_interview_count":2,"interview_waiver_active":true,"profile_revision_status":"available","can_regenerate_from_three":true}"#
    ]
    for state in malformedStates {
      XCTAssertNil(tryDecode(envelope(state), as: GenerationStateDTO.self), state)
    }
  }

  func testSignedURLRequiresElevenLabsWSSHostAndNoUserInfo() {
    let valid = bootstrapResponse(url: "wss://api.elevenlabs.io/v1/convai/conversation?conversation_signature=synthetic")
    XCTAssertNotNil(tryDecode(valid, as: VoiceInterviewBootstrap.self))

    for url in [
      "https://api.elevenlabs.io/v1/convai/conversation?conversation_signature=synthetic",
      "wss://evil.example.test/v1/convai/conversation?conversation_signature=synthetic",
      "wss://user:password@api.elevenlabs.io/v1/convai/conversation?conversation_signature=synthetic",
      "wss://api.elevenlabs.io:8443/v1/convai/conversation?conversation_signature=synthetic#fragment"
    ] {
      XCTAssertNil(tryDecode(bootstrapResponse(url: url), as: VoiceInterviewBootstrap.self), "URL must fail closed: \(url)")
    }
  }

  func testUnavailableTransportDoesNotCreateAnOrphanSession() async {
    let api = FakeVoiceAPI(personas: fixturePersonas())
    let module = makeModule(api: api, transport: UnavailableVoiceInterviewTransport())
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    await store.startInterview(personaID: personaIDs[0]).value

    XCTAssertEqual(store.phase, .failed(.voiceUnavailable))
    let startCalls = await api.startCallCount()
    XCTAssertEqual(startCalls, 0)
  }

  func testPermissionDenialDoesNotCreateSessionAndCanBeRetried() async {
    let api = FakeVoiceAPI(personas: fixturePersonas())
    let permission = DebugVoicePermissionClient(status: .denied)
    let module = makeModule(api: api, permission: permission, transport: DebugVoiceInterviewTransport())
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    await store.startInterview(personaID: personaIDs[0]).value

    XCTAssertEqual(store.phase, .permissionDenied)
    XCTAssertEqual(store.lastError, .microphonePermissionDenied)
    let deniedStartCalls = await api.startCallCount()
    XCTAssertEqual(deniedStartCalls, 0)

    let grantedModule = makeModule(api: api, permission: DebugVoicePermissionClient(), transport: DebugVoiceInterviewTransport())
    let retriedStore = VoiceProfileStore(ownerID: ownerID.uuidString, module: grantedModule)
    await retriedStore.load().value
    await retriedStore.startInterview(personaID: personaIDs[0]).value
    let retriedStartCalls = await api.startCallCount()
    XCTAssertEqual(retriedStartCalls, 1)
  }

  func testSuccessfulInterviewPersistsOnlyProviderTranscriptAndDoesNotClaimAllSessions() async {
    let api = FakeVoiceAPI(personas: fixturePersonas())
    let module = makeModule(
      api: api,
      transport: DebugVoiceInterviewTransport(events: [
        .connected,
        .transcript(VoiceTranscriptEntry(source: .ai, message: "Hello")),
        .transcript(VoiceTranscriptEntry(source: .user, message: "Hi")),
        .ended
      ])
    )
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    await store.startInterview(personaID: personaIDs[0]).value

    XCTAssertEqual(store.phase, .candidates)
    XCTAssertTrue(store.transcript.isEmpty)
    let transcripts = await api.completedTranscripts()
    XCTAssertEqual(transcripts, [[
      VoiceTranscriptEntry(source: .ai, message: "Hello"),
      VoiceTranscriptEntry(source: .user, message: "Hi")
    ]])
    let completeCalls = await api.completeCallCount()
    XCTAssertEqual(completeCalls, 1)
    XCTAssertFalse(store.hasAllInterviews)

    await store.startInterview(personaID: personaIDs[0]).value
    XCTAssertEqual(store.phase, .failed(.invalidState))
    let duplicateCompleteCalls = await api.completeCallCount()
    XCTAssertEqual(duplicateCompleteCalls, 1)
  }

  func testCompletionFailureIsTruthfulAndIsNotRetriedAutomatically() async {
    let api = FakeVoiceAPI(personas: fixturePersonas(), completeError: .temporarilyUnavailable)
    let module = makeModule(api: api, transport: DebugVoiceInterviewTransport())
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    await store.startInterview(personaID: personaIDs[0]).value

    XCTAssertEqual(store.phase, .completionFailed)
    XCTAssertEqual(store.lastError, .completionFailed)
    let completeCalls = await api.completeCallCount()
    XCTAssertEqual(completeCalls, 1)
    XCTAssertFalse(store.hasAllInterviews)
    XCTAssertEqual(store.transcript.count, 2)
  }

  func testCompletionFailureCanBeRetriedWithExactPayloadWithoutStartingAnotherInterview() async {
    let api = FakeVoiceAPI(
      personas: fixturePersonas(),
      completionErrors: [.temporarilyUnavailable]
    )
    let transport = RecordingVoiceInterviewTransport()
    let module = makeModule(api: api, transport: transport)
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    await store.startInterview(personaID: personaIDs[0]).value

    XCTAssertEqual(store.phase, .completionFailed)
    let failedPayload = [
      VoiceTranscriptEntry(source: .ai, message: "Hello!"),
      VoiceTranscriptEntry(source: .user, message: "Nice to meet you.")
    ]
    let failedAttempts = await api.completionAttempts()
    XCTAssertEqual(failedAttempts, [failedPayload])

    await store.retryCompletion().value

    XCTAssertEqual(store.phase, .candidates)
    let completeCalls = await api.completeCallCount()
    let startCalls = await api.startCallCount()
    let transportStartCalls = await transport.startCallCount()
    let attempts = await api.completionAttempts()
    XCTAssertEqual(completeCalls, 2)
    XCTAssertEqual(startCalls, 1)
    XCTAssertEqual(transportStartCalls, 1)
    XCTAssertEqual(attempts, [failedPayload, failedPayload])
    XCTAssertTrue(store.transcript.isEmpty)
    XCTAssertNil(store.currentSessionID)
    XCTAssertEqual(store.completedSessionIDs, Set([sessionID]))
  }

  func testCancellationDuringCompletionRetryDropsStaleCompletionAndPayload() async {
    let api = FakeVoiceAPI(
      personas: fixturePersonas(),
      completionErrors: [.temporarilyUnavailable]
    )
    let module = makeModule(api: api, transport: RecordingVoiceInterviewTransport())
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    await store.startInterview(personaID: personaIDs[0]).value
    await api.setCompletionGated(true)
    let retryTask = store.retryCompletion()
    await api.waitForCompletionStart()

    store.cancel()
    await api.releaseCompletion()
    await retryTask.value

    XCTAssertEqual(store.phase, .idle)
    XCTAssertTrue(store.completedSessionIDs.isEmpty)
    XCTAssertTrue(store.transcript.isEmpty)
    XCTAssertNil(store.currentSessionID)
    let completeCalls = await api.completeCallCount()
    XCTAssertEqual(completeCalls, 2)
  }

  func testOwnerChangeDuringCompletionRetryCannotInstallCompletionForPreviousOwner() async {
    let api = FakeVoiceAPI(
      personas: fixturePersonas(),
      completionErrors: [.temporarilyUnavailable]
    )
    let module = makeModule(api: api, transport: RecordingVoiceInterviewTransport())
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    await store.startInterview(personaID: personaIDs[0]).value
    await api.setCompletionGated(true)
    let retryTask = store.retryCompletion()
    await api.waitForCompletionStart()

    store.updateOwner("66666666-6666-4666-8666-666666666666")
    await api.releaseCompletion()
    await retryTask.value

    XCTAssertEqual(store.phase, .idle)
    XCTAssertTrue(store.personas.isEmpty)
    XCTAssertTrue(store.completedSessionIDs.isEmpty)
    XCTAssertTrue(store.transcript.isEmpty)
    XCTAssertNil(store.currentSessionID)
    let completeCalls = await api.completeCallCount()
    XCTAssertEqual(completeCalls, 2)
    await store.retryCompletion().value
    let staleRetryCalls = await api.completeCallCount()
    XCTAssertEqual(staleRetryCalls, 2)
  }

  func testOwnerChangeCannotReuseAnAPIThatWasBoundToPreviousOwner() async {
    let api = FakeVoiceAPI(personas: fixturePersonas())
    let module = makeModule(api: api)
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    let callsBeforeOwnerChange = await api.personaFetchCallCount()
    store.updateOwner("66666666-6666-4666-8666-666666666666")
    await store.load().value

    XCTAssertEqual(store.phase, .failed(.ownerMismatch))
    let fetchCalls = await api.personaFetchCallCount()
    XCTAssertEqual(fetchCalls, callsBeforeOwnerChange)
    XCTAssertTrue(store.personas.isEmpty)
    XCTAssertNil(store.currentSessionID)
    XCTAssertTrue(store.transcript.isEmpty)
  }

  func testLoadHydratesOneCompletedInterviewWithoutUnlockingGeneration() async {
    let api = FakeVoiceAPI(
      personas: fixturePersonas(completedSessionIDs: [persistedSessionIDs[0], nil, nil])
    )
    let module = makeModule(api: api)
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value

    XCTAssertEqual(store.phase, .candidates)
    XCTAssertEqual(store.completedPersonaIDs, Set([personaIDs[0]]))
    XCTAssertEqual(store.completedSessionIDs, Set([persistedSessionIDs[0]]))
    XCTAssertFalse(store.hasAllInterviews)
    XCTAssertFalse(store.canGenerateProfile)
    let personaFetchCalls = await api.personaFetchCallCount()
    let completeCalls = await api.completeCallCount()
    XCTAssertEqual(personaFetchCalls, 1)
    XCTAssertEqual(completeCalls, 0)

    await store.startInterview(personaID: personaIDs[0]).value
    XCTAssertEqual(store.phase, .failed(.invalidState))
    let startCalls = await api.startCallCount()
    XCTAssertEqual(startCalls, 0)
  }

  func testLoadHydratesThreeCompletedInterviewsAndDraftProfileCanBeReviewedThenConfirmed() async {
    let api = FakeVoiceAPI(
      personas: fixturePersonas(completedSessionIDs: persistedSessionIDs.map { $0 as UUID? })
    )
    let module = makeModule(
      api: api,
      insight: FixtureInsightAPI(ownerID: ownerID, status: "draft")
    )
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value

    XCTAssertEqual(store.phase, .readyToGenerate)
    XCTAssertTrue(store.hasAllInterviews)
    XCTAssertTrue(store.canGenerateProfile)
    XCTAssertEqual(store.completedPersonaIDs, Set(personaIDs))
    XCTAssertEqual(store.completedSessionIDs, Set(persistedSessionIDs))

    await store.generateProfile().value

    XCTAssertEqual(store.phase, .review)
    XCTAssertEqual(store.insight?.status, "draft")
    let profileCalls = await api.profileGenerationCalls()
    let wingfoxCalls = await api.wingfoxGenerationCalls()
    XCTAssertEqual(profileCalls, 1)
    XCTAssertEqual(wingfoxCalls, 0)

    await store.confirmProfile().value
    XCTAssertEqual(store.phase, .confirmed)
    let confirmedWingfoxCalls = await api.wingfoxGenerationCalls()
    XCTAssertEqual(confirmedWingfoxCalls, 1)
    let confirmCalls = await api.confirmCallCount()
    XCTAssertEqual(confirmCalls, 1)
  }

  func testUnconfirmedRevisionCopyIdentifiesOldDraftAndKeepsRefreshInstruction() {
    let english = VoiceProfileCopy(language: .en)
    let japanese = VoiceProfileCopy(language: .ja)
    for body in [english.profileRevisionClaimedBody, english.profileRevisionRefreshBody] {
      XCTAssertTrue(body.contains("OLD profile"))
      XCTAssertTrue(body.contains("Saving the new profile has not been confirmed"))
      XCTAssertTrue(body.contains(english.refreshProfileRevision))
    }
    XCTAssertTrue(english.profileRevisionClaimedBody.contains("Generation cannot be repeated"))
    XCTAssertTrue(english.profileRevisionClaimedBody.contains("confirmation is blocked"))
    for body in [japanese.profileRevisionClaimedBody, japanese.profileRevisionRefreshBody] {
      XCTAssertTrue(body.contains("表示中は以前のプロフィール"))
      XCTAssertTrue(body.contains("新しいプロフィールの保存は確認できていません"))
      XCTAssertTrue(body.contains(japanese.refreshProfileRevision))
      XCTAssertTrue(body.contains("作成の再実行と確定はできません"))
    }
  }

  func testProfileRevisionClaimFailureRefreshesStateAndConsumesRetry() async {
    let availableState = GenerationStateDTO(
      userID: ownerID,
      profileGenerated: true,
      wingfoxGenerated: true,
      profileConfirmed: false,
      profileRevisionStatus: .available,
      canRegenerateFromThree: true
    )
    let claimedState = GenerationStateDTO(
      userID: ownerID,
      profileGenerated: true,
      wingfoxGenerated: true,
      profileConfirmed: false,
      profileRevisionStatus: .claimed,
      canRegenerateFromThree: false
    )
    let api = FakeVoiceAPI(
      personas: fixturePersonas(completedSessionIDs: persistedSessionIDs.map { $0 as UUID? }),
      profileGenerationErrors: [.temporarilyUnavailable],
      generationState: availableState,
      generationStateAfterProfileAttempt: claimedState
    )
    let module = makeModule(
      api: api,
      insight: FixtureInsightAPI(ownerID: ownerID, status: "draft")
    )
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    XCTAssertEqual(store.phase, .review)
    XCTAssertTrue(store.canCreateNewProfileFromThree)
    XCTAssertFalse(store.canConfirmProfile)
    let oldDraftID = store.insight?.id

    await store.createNewProfileFromThree().value

    XCTAssertEqual(store.phase, .review)
    XCTAssertEqual(store.profileRevisionStatus, .claimed)
    XCTAssertFalse(store.canRegenerateFromThree)
    XCTAssertFalse(store.canCreateNewProfileFromThree)
    XCTAssertFalse(store.canConfirmProfile)
    XCTAssertEqual(store.insight?.id, oldDraftID)
    XCTAssertEqual(store.lastError, .generationFailed)

    await store.retryLoad().value
    XCTAssertEqual(store.phase, .review)
    XCTAssertEqual(store.profileRevisionStatus, .claimed)
    XCTAssertFalse(store.canCreateNewProfileFromThree)
    XCTAssertFalse(store.canConfirmProfile)
    await store.createNewProfileFromThree().value
    await store.confirmProfile().value

    let generationCalls = await api.profileGenerationCalls()
    let wingfoxCalls = await api.wingfoxGenerationCalls()
    let confirmationCalls = await api.confirmCallCount()
    let stateFetchCalls = await api.generationStateFetchCallCount()
    XCTAssertEqual(generationCalls, 1)
    XCTAssertEqual(wingfoxCalls, 0)
    XCTAssertEqual(confirmationCalls, 0)
    XCTAssertGreaterThanOrEqual(stateFetchCalls, 3)
  }

  func testSuccessfulProfileRevisionConfirmsNewDraftWithoutRegeneratingWingfox() async {
    let availableState = GenerationStateDTO(
      userID: ownerID,
      profileGenerated: true,
      wingfoxGenerated: true,
      profileConfirmed: false,
      profileRevisionStatus: .available,
      canRegenerateFromThree: true
    )
    let completedState = GenerationStateDTO(
      userID: ownerID,
      profileGenerated: true,
      wingfoxGenerated: true,
      profileConfirmed: false,
      profileRevisionStatus: .completed,
      canRegenerateFromThree: false
    )
    let api = FakeVoiceAPI(
      personas: fixturePersonas(completedSessionIDs: persistedSessionIDs.map { $0 as UUID? }),
      generationState: availableState,
      generationStateAfterProfileAttempt: completedState
    )
    let insightAPI = SequenceFixtureInsightAPI(
      ownerID: ownerID,
      signatures: ["The preserved old draft.", "A fresh profile from all three interviews."]
    )
    let module = makeModule(api: api, insight: insightAPI)
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    XCTAssertEqual(store.insight?.overallSignature, "The preserved old draft.")
    XCTAssertTrue(store.canCreateNewProfileFromThree)
    XCTAssertFalse(store.canConfirmProfile)
    await store.confirmProfile().value
    let blockedConfirmCalls = await api.confirmCallCount()
    XCTAssertEqual(blockedConfirmCalls, 0)

    await store.createNewProfileFromThree().value

    XCTAssertEqual(store.phase, .review)
    XCTAssertEqual(store.profileRevisionStatus, .completed)
    XCTAssertEqual(store.insight?.overallSignature, "A fresh profile from all three interviews.")
    XCTAssertFalse(store.canCreateNewProfileFromThree)
    XCTAssertTrue(store.canConfirmProfile)
    XCTAssertFalse(store.needsWingfoxGeneration)
    await store.confirmProfile().value

    XCTAssertEqual(store.phase, .confirmed)
    let generationCalls = await api.profileGenerationCalls()
    let wingfoxCalls = await api.wingfoxGenerationCalls()
    let confirmationCalls = await api.confirmCallCount()
    XCTAssertEqual(generationCalls, 1)
    XCTAssertEqual(wingfoxCalls, 0)
    XCTAssertEqual(confirmationCalls, 1)
  }

  func testLoadHydratesTwoCompletedInterviewsOnlyWhenServerWaiverIsActive() async {
    let api = FakeVoiceAPI(
      personas: fixturePersonas(completedSessionIDs: [persistedSessionIDs[0], persistedSessionIDs[1], nil]),
      generationState: GenerationStateDTO(
        userID: ownerID,
        profileGenerated: false,
        wingfoxGenerated: false,
        profileConfirmed: false,
        requiredInterviewCount: 2,
        interviewWaiverActive: true
      )
    )
    let module = makeModule(
      api: api,
      insight: FixtureInsightAPI(ownerID: ownerID, status: "draft")
    )
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value

    XCTAssertEqual(store.phase, .readyToGenerate)
    XCTAssertTrue(store.hasAllInterviews)
    XCTAssertTrue(store.canGenerateProfile)
    XCTAssertEqual(store.requiredInterviewCount, 2)
    XCTAssertTrue(store.interviewWaiverActive)
    XCTAssertEqual(store.completedPersonaIDs.count, 2)

    await store.generateProfile().value

    XCTAssertEqual(store.phase, .review)
    let profileCalls = await api.profileGenerationCalls()
    XCTAssertEqual(profileCalls, 1)
  }

  func testLoadShowsSavedDraftBeforeWingfoxAndConfirmationPreparesItExplicitly() async {
    let api = FakeVoiceAPI(
      personas: fixturePersonas(completedSessionIDs: persistedSessionIDs.map { $0 as UUID? }),
      generationState: GenerationStateDTO(
        userID: ownerID,
        profileGenerated: true,
        wingfoxGenerated: false,
        profileConfirmed: false
      )
    )
    let module = makeModule(
      api: api,
      insight: FixtureInsightAPI(ownerID: ownerID, status: "draft")
    )
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value

    XCTAssertEqual(store.phase, .review)
    XCTAssertEqual(store.insight?.status, "draft")
    XCTAssertTrue(store.needsWingfoxGeneration)
    let profileCallsBeforeConfirm = await api.profileGenerationCalls()
    let wingfoxCallsBeforeConfirm = await api.wingfoxGenerationCalls()
    let confirmCallsBeforeConfirm = await api.confirmCallCount()
    XCTAssertEqual(profileCallsBeforeConfirm, 0)
    XCTAssertEqual(wingfoxCallsBeforeConfirm, 0)
    XCTAssertEqual(confirmCallsBeforeConfirm, 0)

    await store.confirmProfile().value

    XCTAssertEqual(store.phase, .confirmed)
    XCTAssertFalse(store.needsWingfoxGeneration)
    let profileCalls = await api.profileGenerationCalls()
    let wingfoxCalls = await api.wingfoxGenerationCalls()
    let confirmCalls = await api.confirmCallCount()
    XCTAssertEqual(profileCalls, 0)
    XCTAssertEqual(wingfoxCalls, 1)
    XCTAssertEqual(confirmCalls, 1)
  }

  func testLoadShowsConfirmedInsightOnlyWhenStateAndInsightAgree() async {
    let api = FakeVoiceAPI(
      personas: fixturePersonas(completedSessionIDs: persistedSessionIDs.map { $0 as UUID? }),
      generationState: GenerationStateDTO(
        userID: ownerID,
        profileGenerated: true,
        wingfoxGenerated: true,
        profileConfirmed: true
      )
    )
    let module = makeModule(
      api: api,
      insight: FixtureInsightAPI(ownerID: ownerID, status: "confirmed")
    )
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value

    XCTAssertEqual(store.phase, .confirmed)
    XCTAssertEqual(store.insight?.status, "confirmed")
    XCTAssertFalse(store.needsWingfoxGeneration)
    let profileCalls = await api.profileGenerationCalls()
    let wingfoxCalls = await api.wingfoxGenerationCalls()
    XCTAssertEqual(profileCalls, 0)
    XCTAssertEqual(wingfoxCalls, 0)
  }

  func testLoadRejectsConfirmedStateWhenSavedInsightIsStillDraft() async {
    let api = FakeVoiceAPI(
      personas: fixturePersonas(completedSessionIDs: persistedSessionIDs.map { $0 as UUID? }),
      generationState: GenerationStateDTO(
        userID: ownerID,
        profileGenerated: true,
        wingfoxGenerated: true,
        profileConfirmed: true
      )
    )
    let module = makeModule(
      api: api,
      insight: FixtureInsightAPI(ownerID: ownerID, status: "draft")
    )
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value

    XCTAssertEqual(store.phase, .failed(.invalidResponse))
    XCTAssertNil(store.insight)
    XCTAssertFalse(store.needsWingfoxGeneration)
  }

  func testLoadRejectsGenerationStateForAnotherOwner() async {
    let api = FakeVoiceAPI(
      personas: fixturePersonas(completedSessionIDs: persistedSessionIDs.map { $0 as UUID? }),
      generationState: GenerationStateDTO(
        userID: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
        profileGenerated: true,
        wingfoxGenerated: false,
        profileConfirmed: false
      )
    )
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: makeModule(api: api))

    await store.load().value

    XCTAssertEqual(store.phase, .failed(.ownerMismatch))
    XCTAssertNil(store.insight)
    let profileCalls = await api.profileGenerationCalls()
    let wingfoxCalls = await api.wingfoxGenerationCalls()
    XCTAssertEqual(profileCalls, 0)
    XCTAssertEqual(wingfoxCalls, 0)
  }

  func testThreeCompletedInterviewsGenerateClosedInsightThenConfirm() async {
    let api = FakeVoiceAPI(personas: fixturePersonas(), allSessionsCompleted: true)
    let module = makeModule(api: api, transport: DebugVoiceInterviewTransport())
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    await store.startInterview(personaID: personaIDs[0]).value
    await store.startInterview(personaID: personaIDs[1]).value
    await store.startInterview(personaID: personaIDs[2]).value
    XCTAssertTrue(store.canGenerateProfile)

    await store.generateProfile().value
    XCTAssertEqual(store.phase, .review)
    XCTAssertEqual(store.insight?.userID, ownerID)
    let profileCalls = await api.profileGenerationCalls()
    let wingfoxCalls = await api.wingfoxGenerationCalls()
    XCTAssertEqual(profileCalls, 1)
    XCTAssertEqual(wingfoxCalls, 0)

    await store.confirmProfile().value
    XCTAssertEqual(store.phase, .confirmed)
  }

  func testFinalInterviewRestoresExistingDraftWithoutRegeneration() async {
    let savedState = GenerationStateDTO(
      userID: ownerID,
      profileGenerated: true,
      wingfoxGenerated: true,
      profileConfirmed: false
    )
    let api = FakeVoiceAPI(
      personas: fixturePersonas(completedSessionIDs: [persistedSessionIDs[0], persistedSessionIDs[1], nil]),
      generationState: GenerationStateDTO(
        userID: ownerID,
        profileGenerated: false,
        wingfoxGenerated: false,
        profileConfirmed: false
      ),
      generationStateAfterCompletion: savedState
    )
    let module = makeModule(
      api: api,
      insight: FixtureInsightAPI(ownerID: ownerID, status: "draft"),
      transport: DebugVoiceInterviewTransport()
    )
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    XCTAssertEqual(store.phase, .candidates)
    await store.startInterview(personaID: personaIDs[2]).value

    XCTAssertEqual(store.phase, .review)
    XCTAssertEqual(store.insight?.status, "draft")
    XCTAssertEqual(store.completedPersonaIDs, Set(personaIDs))
    let profileCalls = await api.profileGenerationCalls()
    let wingfoxCalls = await api.wingfoxGenerationCalls()
    XCTAssertEqual(profileCalls, 0)
    XCTAssertEqual(wingfoxCalls, 0)
  }

  func testConfirmCannotBeSubmittedTwiceWhileTheFirstRequestIsPending() async {
    let api = FakeVoiceAPI(personas: fixturePersonas(), allSessionsCompleted: true)
    let module = makeModule(api: api, transport: DebugVoiceInterviewTransport())
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    await store.startInterview(personaID: personaIDs[0]).value
    await store.startInterview(personaID: personaIDs[1]).value
    await store.startInterview(personaID: personaIDs[2]).value
    await store.generateProfile().value
    await api.setConfirmGated(true)

    let first = store.confirmProfile()
    await api.waitForConfirmStart()
    let second = store.confirmProfile()
    await Task.yield()
    XCTAssertEqual(store.phase, .confirming)
    let confirmCalls = await api.confirmCallCount()
    XCTAssertEqual(confirmCalls, 1)

    await api.releaseConfirm()
    await first.value
    await second.value
    XCTAssertEqual(store.phase, .confirmed)
  }

  func testPartialGenerationRetryDoesNotRegenerateCompletedProfile() async {
    let api = FakeVoiceAPI(personas: fixturePersonas(), allSessionsCompleted: true, wingfoxError: .temporarilyUnavailable)
    let module = makeModule(api: api, transport: DebugVoiceInterviewTransport())
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    await store.startInterview(personaID: personaIDs[0]).value
    await store.startInterview(personaID: personaIDs[1]).value
    await store.startInterview(personaID: personaIDs[2]).value
    await store.generateProfile().value
    XCTAssertEqual(store.phase, .review)
    let profileCallsBeforeConfirm = await api.profileGenerationCalls()
    let wingfoxCallsBeforeConfirm = await api.wingfoxGenerationCalls()
    XCTAssertEqual(profileCallsBeforeConfirm, 1)
    XCTAssertEqual(wingfoxCallsBeforeConfirm, 0)

    await store.confirmProfile().value
    XCTAssertEqual(store.phase, .review)
    XCTAssertEqual(store.lastError, .partnerGenerationFailed)
    let profileCalls = await api.profileGenerationCalls()
    XCTAssertEqual(profileCalls, 1)
    let failedWingfoxCalls = await api.wingfoxGenerationCalls()
    XCTAssertEqual(failedWingfoxCalls, 1)

    await api.setWingfoxError(nil)
    await store.confirmProfile().value
    XCTAssertEqual(store.phase, .confirmed)
    let retryProfileCalls = await api.profileGenerationCalls()
    let retryWingfoxCalls = await api.wingfoxGenerationCalls()
    XCTAssertEqual(retryProfileCalls, 1)
    XCTAssertEqual(retryWingfoxCalls, 2)
  }

  func testCancelledPartnerPreparationRetainsDraftWithoutConfirming() async {
    let api = FakeVoiceAPI(
      personas: fixturePersonas(),
      allSessionsCompleted: true,
      wingfoxError: .cancelled
    )
    let module = makeModule(api: api)
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    await store.startInterview(personaID: personaIDs[0]).value
    await store.startInterview(personaID: personaIDs[1]).value
    await store.startInterview(personaID: personaIDs[2]).value
    await store.generateProfile().value
    await store.confirmProfile().value

    XCTAssertEqual(store.phase, .review)
    XCTAssertNil(store.lastError)
    XCTAssertEqual(store.insight?.status, "draft")
    let profileCalls = await api.profileGenerationCalls()
    let wingfoxCalls = await api.wingfoxGenerationCalls()
    let confirmCalls = await api.confirmCallCount()
    XCTAssertEqual(profileCalls, 1)
    XCTAssertEqual(wingfoxCalls, 1)
    XCTAssertEqual(confirmCalls, 0)
  }

  func testCancelledGenerationCannotInstallDraftInsight() async {
    let api = FakeVoiceAPI(
      personas: fixturePersonas(completedSessionIDs: persistedSessionIDs.map { $0 as UUID? })
    )
    let insight = GatedFixtureInsightAPI(ownerID: ownerID)
    let module = makeModule(api: api, insight: insight)
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    let generationTask = store.generateProfile()
    await insight.waitForFetchStart()
    store.cancel()
    await insight.release()
    await generationTask.value

    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.insight)
    let profileCalls = await api.profileGenerationCalls()
    let wingfoxCalls = await api.wingfoxGenerationCalls()
    XCTAssertEqual(profileCalls, 1)
    XCTAssertEqual(wingfoxCalls, 0)
  }

  func testCancelledGenerationCannotLeaveAStaleAcknowledgementAfterReload() async {
    let api = FakeVoiceAPI(
      personas: fixturePersonas(completedSessionIDs: persistedSessionIDs.map { $0 as UUID? })
    )
    let module = makeModule(api: api)
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await api.setProfileGated(true)
    await store.load().value
    let cancelledGenerationTask = store.generateProfile()
    await api.waitForProfileStart()

    store.cancel()
    let reloadTask = store.load()
    await reloadTask.value
    await api.releaseProfile()
    await cancelledGenerationTask.value

    await api.setProfileGated(false)
    await store.generateProfile().value

    XCTAssertEqual(store.phase, .review)
    let profileCalls = await api.profileGenerationCalls()
    let wingfoxCalls = await api.wingfoxGenerationCalls()
    XCTAssertEqual(profileCalls, 2)
    XCTAssertEqual(wingfoxCalls, 0)
  }

  func testOwnerChangeDuringGenerationCannotInstallDraftInsight() async {
    let api = FakeVoiceAPI(
      personas: fixturePersonas(completedSessionIDs: persistedSessionIDs.map { $0 as UUID? })
    )
    let insight = GatedFixtureInsightAPI(ownerID: ownerID)
    let module = makeModule(api: api, insight: insight)
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: module)

    await store.load().value
    let generationTask = store.generateProfile()
    await insight.waitForFetchStart()
    store.updateOwner("66666666-6666-4666-8666-666666666666")
    await insight.release()
    await generationTask.value

    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.insight)
    XCTAssertTrue(store.personas.isEmpty)
    XCTAssertTrue(store.completedPersonaIDs.isEmpty)
  }

  func testLiveAPIUsesFrozenRouteShapesAndDoesNotDecodePrivateGenerationDocument() async throws {
    let client = FakeAuthenticatedAPIClient()
    let personasRequest = APIRequest(method: .get, path: LiveVoiceProfileAPI.personasPath)
    await client.setResponseData(personasResponse(), for: personasRequest)
    let generatedRequest = APIRequest(method: .post, path: LiveVoiceProfileAPI.personasPath)
    await client.setResponseData(personasResponse(), for: generatedRequest)
    await client.setResponseData(envelope("""
    {
      "user_id":"11111111-1111-4111-8111-111111111111",
      "profile_generated":false,
      "wingfox_generated":false,
      "profile_confirmed":false
    }
    """), for: APIRequest(method: .get, path: LiveVoiceProfileAPI.generationStatePath))
    let startRequest = try APIRequest.json(
      method: .post,
      path: LiveVoiceProfileAPI.sessionsPath,
      body: PersonaRequest(personaID: personaIDs[0].uuidString.lowercased())
    )
    await client.setResponseData(envelope("""
    {"session_id":"22222222-2222-4222-8222-222222222222","persona":{"id":"33333333-3333-4333-8333-333333333333","name":"A","personality_summary":"private"}}
    """), for: startRequest)
    let signedRequest = APIRequest(method: .get, path: "/api/speed-dating/sessions/\(sessionID.uuidString.lowercased())/signed-url")
    await client.setResponseData(bootstrapResponse(), for: signedRequest)
    let completeRequest = try APIRequest.json(
      method: .post,
      path: "/api/speed-dating/sessions/\(sessionID.uuidString.lowercased())/complete",
      body: CompletionRequest(transcript: [VoiceTranscriptEntry(source: .user, message: "Hi")])
    )
    await client.setResponseData(envelope("""
    {"session_id":"22222222-2222-4222-8222-222222222222","status":"completed","all_sessions_completed":false}
    """), for: completeRequest)
    let generationAcknowledgement = """
    {"id":"77777777-7777-4777-8777-777777777777","user_id":"11111111-1111-4111-8111-111111111111","raw_profile":{"private":"must remain server-side"}}
    """
    await client.setResponseData(envelope(generationAcknowledgement), for: APIRequest(method: .post, path: LiveVoiceProfileAPI.profileGenerationPath))
    await client.setResponseData(envelope(generationAcknowledgement), for: APIRequest(method: .post, path: LiveVoiceProfileAPI.wingfoxGenerationPath))
    await client.setResponseData(envelope("""
    {"status":"confirmed","confirmed_at":"2026-09-09T00:00:00Z"}
    """), for: APIRequest(method: .post, path: LiveVoiceProfileAPI.profileConfirmationPath))

    let api = try LiveVoiceProfileAPI(client: client, ownerID: ownerID.uuidString)
    let fetchedPersonas = try await api.fetchPersonas()
    let generatedPersonas = try await api.generatePersonas()
    let generationState = try await api.fetchGenerationState()
    XCTAssertEqual(fetchedPersonas.count, 3)
    XCTAssertEqual(generatedPersonas.count, 3)
    XCTAssertEqual(generationState?.userID, ownerID)
    XCTAssertFalse(generationState?.profileGenerated ?? true)
    _ = try await api.startSession(personaID: personaIDs[0])
    _ = try await api.fetchSignedURL(sessionID: sessionID)
    _ = try await api.completeSession(sessionID: sessionID, transcript: [VoiceTranscriptEntry(source: .user, message: "Hi")])
    try await api.generateProfile()
    try await api.generateWingfox()
    let confirmation = try await api.confirmProfile()
    XCTAssertEqual(confirmation.status, "confirmed")
    let requests = await client.recordedRequests()
    XCTAssertEqual(requests.count, 9)
  }

  func testLiveAPINativeBootstrapUsesDedicatedRouteAndBindsSessionID() async throws {
    let client = FakeAuthenticatedAPIClient()
    let nativePath = "/api/speed-dating/sessions/\(sessionID.uuidString.lowercased())/native-bootstrap"
    await client.setResponseData(envelope("""
    {
      "session_id":"22222222-2222-4222-8222-222222222222",
      "conversation_token":"synthetic-conversation-token",
      "overrides":{"agent":{"prompt":{"prompt":"Keep it kind."},"firstMessage":"Hello!","language":"en"},"tts":{"voiceId":"voice-en"}}
    }
    """), for: APIRequest(method: .get, path: nativePath))

    let api = try LiveVoiceProfileAPI(client: client, ownerID: ownerID.uuidString)
    let bootstrap = try await api.fetchNativeBootstrap(sessionID: sessionID)
    XCTAssertEqual(bootstrap.sessionID, sessionID)
    XCTAssertEqual(bootstrap.conversationToken, "synthetic-conversation-token")
    let recordedRequests = await client.recordedRequests()
    XCTAssertEqual(recordedRequests, [APIRequest(method: .get, path: nativePath)])

    await client.setResponseData(envelope("""
    {
      "session_id":"66666666-6666-4666-8666-666666666666",
      "conversation_token":"synthetic-conversation-token",
      "overrides":{"agent":{"prompt":{"prompt":"Keep it kind."},"firstMessage":"Hello!","language":"en"},"tts":{"voiceId":"voice-en"}}
    }
    """), for: APIRequest(method: .get, path: nativePath))
    do {
      _ = try await api.fetchNativeBootstrap(sessionID: sessionID)
      XCTFail("Native bootstrap for another session must fail closed")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidResponse)
    }
  }

  func testLiveAPIRejectsGenerationAcknowledgementForAnotherOwner() async throws {
    let client = FakeAuthenticatedAPIClient()
    await client.setResponseData(envelope("""
    {"id":"77777777-7777-4777-8777-777777777777","user_id":"88888888-8888-4888-8888-888888888888","raw_profile":{"private":"must remain server-side"}}
    """), for: APIRequest(method: .post, path: LiveVoiceProfileAPI.profileGenerationPath))
    let api = try LiveVoiceProfileAPI(client: client, ownerID: ownerID.uuidString)

    do {
      try await api.generateProfile()
      XCTFail("Generation acknowledgement for another owner must fail closed")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidResponse)
    }
  }

  func testLiveAPIRejectsGenerationStateForAnotherOwner() async throws {
    let client = FakeAuthenticatedAPIClient()
    await client.setResponseData(envelope("""
    {
      "user_id":"88888888-8888-4888-8888-888888888888",
      "profile_generated":true,
      "wingfox_generated":false,
      "profile_confirmed":false
    }
    """), for: APIRequest(method: .get, path: LiveVoiceProfileAPI.generationStatePath))
    let api = try LiveVoiceProfileAPI(client: client, ownerID: ownerID.uuidString)

    do {
      _ = try await api.fetchGenerationState()
      XCTFail("Generation state for another owner must fail closed")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidResponse)
    }
  }

  func testLiveAPIReadsServerOwnedProfileRevisionControls() async throws {
    let client = FakeAuthenticatedAPIClient()
    let stateRequest = APIRequest(method: .get, path: LiveVoiceProfileAPI.generationStatePath)
    await client.setResponseData(envelope("""
    {
      "user_id":"11111111-1111-4111-8111-111111111111",
      "profile_generated":true,
      "wingfox_generated":true,
      "profile_confirmed":false,
      "profile_revision_status":"available",
      "can_regenerate_from_three":true
    }
    """), for: stateRequest)
    let api = try LiveVoiceProfileAPI(client: client, ownerID: ownerID.uuidString)

    let state = try await api.fetchGenerationState()

    XCTAssertEqual(state?.profileRevisionStatus, .available)
    XCTAssertEqual(state?.canRegenerateFromThree, true)
    let recordedRequests = await client.recordedRequests()
    XCTAssertEqual(recordedRequests, [stateRequest])
  }

  func testLiveAPIRejectsMalformedGenerationAcknowledgement() async throws {
    let client = FakeAuthenticatedAPIClient()
    await client.setResponseData(envelope("""
    {"raw_profile":{"private":"must remain server-side"}}
    """), for: APIRequest(method: .post, path: LiveVoiceProfileAPI.profileGenerationPath))
    let api = try LiveVoiceProfileAPI(client: client, ownerID: ownerID.uuidString)

    do {
      try await api.generateProfile()
      XCTFail("Malformed generation acknowledgement must fail closed")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidResponse)
    }
  }

  func testDraftEditorSavesOnlyBoundOwnerDraftAndFailureBlocksConfirmationUntilRefresh() async {
    let api = FakeVoiceAPI(personas: fixturePersonas(completedSessionIDs: persistedSessionIDs.map { $0 as UUID? }),
      generationState: GenerationStateDTO(userID: ownerID, profileGenerated: true, wingfoxGenerated: true, profileConfirmed: false))
    let insight = EditableDraftInsightAPI(ownerID: ownerID)
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: makeModule(api: api, insight: insight))
    await store.load().value
    XCTAssertTrue(store.canEditDraftProfile)
    await store.saveDraftProfile(tags: ["Calm", "Curious", "Kind"], bio: "A quiet afternoon.")
    XCTAssertEqual(store.insight?.bio, "A quiet afternoon.")
    XCTAssertEqual(store.insight?.personalityTags, ["Calm", "Curious", "Kind"])
    XCTAssertTrue(store.canConfirmProfile)
    await insight.failNextSave()
    await store.saveDraftProfile(tags: ["Calm", "Curious", "Kind"], bio: "Another draft.")
    XCTAssertTrue(store.draftNeedsRefresh)
    XCTAssertFalse(store.canConfirmProfile)
    await store.retryLoad().value
    XCTAssertFalse(store.draftNeedsRefresh)
    XCTAssertTrue(store.canConfirmProfile)
    XCTAssertEqual(store.insight?.bio, "A quiet afternoon.")
  }

  func testDraftEditorRejectsReturnedProfileForAnotherOwner() async {
    let api = FakeVoiceAPI(personas: fixturePersonas(completedSessionIDs: persistedSessionIDs.map { $0 as UUID? }),
      generationState: GenerationStateDTO(userID: ownerID, profileGenerated: true, wingfoxGenerated: true, profileConfirmed: false))
    let insight = EditableDraftInsightAPI(ownerID: ownerID, wrongOwnerOnSave: true)
    let store = VoiceProfileStore(ownerID: ownerID.uuidString, module: makeModule(api: api, insight: insight))
    await store.load().value
    await store.saveDraftProfile(tags: ["Calm", "Curious", "Kind"], bio: "A quiet afternoon.")
    XCTAssertEqual(store.insight?.userID, ownerID)
    XCTAssertNil(store.insight?.bio)
    XCTAssertTrue(store.draftNeedsRefresh)
    XCTAssertFalse(store.canConfirmProfile)
  }

  private func makeModule(
    api: any VoiceProfileAPI,
    settings: any OnboardingSettingsAPI = FixtureSettingsAPI(),
    insight: any ConversationInsightAPI = FixtureInsightAPI(ownerID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!),
    permission: any VoicePermissionClient = DebugVoicePermissionClient(),
    transport: any VoiceInterviewTransport = DebugVoiceInterviewTransport()
  ) -> VoiceProfileModule {
    VoiceProfileModule(
      api: api,
      settingsAPI: settings,
      insightAPI: insight,
      permissionClient: permission,
      transport: transport
    )
  }

  private func fixturePersonas(completedSessionIDs: [UUID?] = [nil, nil, nil]) -> [VoicePersona] {
    [
      VoicePersona(
        id: personaIDs[0],
        type: .similar,
        name: "A",
        completedSessionID: completedSessionIDs[0]
      ),
      VoicePersona(
        id: personaIDs[1],
        type: .complementary,
        name: "B",
        completedSessionID: completedSessionIDs[1]
      ),
      VoicePersona(
        id: personaIDs[2],
        type: .discovery,
        name: "C",
        completedSessionID: completedSessionIDs[2]
      )
    ]
  }

  private func personasResponse() -> Data {
    envelope("""
    [
      {"id":"33333333-3333-4333-8333-333333333333","persona_type":"virtual_similar","name":"A","compiled_document":"private"},
      {"id":"44444444-4444-4444-8444-444444444444","persona_type":"virtual_complementary","name":"B","compiled_document":"private"},
      {"id":"55555555-5555-4555-8555-555555555555","persona_type":"virtual_discovery","name":"C","compiled_document":"private"}
    ]
    """)
  }

  private func bootstrapResponse(url: String = "wss://api.elevenlabs.io/v1/convai/conversation?conversation_signature=synthetic") -> Data {
    envelope("""
    {
      "signed_url":"\(url)",
      "overrides":{"agent":{"prompt":{"prompt":"Keep it kind."},"firstMessage":"Hello!","language":"en"},"tts":{"voiceId":"voice-en"}},
      "persona":{"name":"A"}
    }
    """)
  }

  private func envelope(_ data: String) -> Data {
    Data(("{\"data\":" + data + "}").utf8)
  }

  private func tryDecode<Value: APIValidatable>(_ data: Data, as type: Value.Type) -> Value? {
    try? APIResponseDecoder.decode(data, as: type)
  }
}

private struct PersonaRequest: Encodable {
  let personaID: String
  enum CodingKeys: String, CodingKey { case personaID = "persona_id" }
}

private struct CompletionRequest: Encodable {
  let transcript: [VoiceTranscriptEntry]
}

private actor FakeVoiceAPI: VoiceProfileAPI {
  private let personas: [VoicePersona]
  private var generationState: GenerationStateDTO?
  private let generationStateAfterCompletion: GenerationStateDTO?
  private let allSessionsCompleted: Bool
  private let completeError: APIClientError?
  private var completionErrors: [APIClientError]
  private var profileGenerationErrors: [APIClientError]
  private var wingfoxError: APIClientError?
  private let generationStateAfterProfileAttempt: GenerationStateDTO?
  private var confirmGated = false
  private var confirmStarted = false
  private var completionGated = false
  private var completionStarted = false
  private var profileGated = false
  private var profileStarted = false
  private var confirmCalls = 0
  private var confirmStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var confirmContinuations: [CheckedContinuation<VoiceProfileConfirmation, Never>] = []
  private var completionStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var completionContinuations: [CheckedContinuation<Void, Never>] = []
  private var profileStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var profileContinuations: [CheckedContinuation<Void, Never>] = []
  private var personaFetchCalls = 0
  private var startCalls = 0
  private var completeCalls = 0
  private var profileCalls = 0
  private var generationStateFetchCalls = 0
  private var wingfoxCalls = 0
  private var transcripts: [[VoiceTranscriptEntry]] = []
  private var recordedCompletionAttempts: [[VoiceTranscriptEntry]] = []

  init(
    personas: [VoicePersona],
    allSessionsCompleted: Bool = false,
    completeError: APIClientError? = nil,
    completionErrors: [APIClientError] = [],
    profileGenerationErrors: [APIClientError] = [],
    wingfoxError: APIClientError? = nil,
    generationState: GenerationStateDTO? = nil,
    generationStateAfterCompletion: GenerationStateDTO? = nil,
    generationStateAfterProfileAttempt: GenerationStateDTO? = nil
  ) {
    self.personas = personas
    self.allSessionsCompleted = allSessionsCompleted
    self.completeError = completeError
    self.completionErrors = completionErrors
    self.profileGenerationErrors = profileGenerationErrors
    self.wingfoxError = wingfoxError
    self.generationState = generationState
    self.generationStateAfterCompletion = generationStateAfterCompletion
    self.generationStateAfterProfileAttempt = generationStateAfterProfileAttempt
  }

  func fetchPersonas() async throws -> [VoicePersona] {
    personaFetchCalls += 1
    return personas
  }

  func generatePersonas() async throws -> [VoicePersona] { personas }
  func fetchGenerationState() async throws -> GenerationStateDTO? {
    generationStateFetchCalls += 1
    return generationState
  }

  func startSession(personaID: UUID) async throws -> VoiceSessionStartResult {
    startCalls += 1
    guard let persona = personas.first(where: { $0.id == personaID }) else { throw APIClientError.notFound }
    return VoiceSessionStartResult(sessionID: sessionID(for: personaID), personaID: persona.id, personaName: persona.name)
  }

  func fetchSignedURL(sessionID: UUID) async throws -> VoiceInterviewBootstrap {
    let overrides = VoiceInterviewOverrides(prompt: "Keep it kind.", firstMessage: "Hello!", language: .en, voiceID: "voice-en")
    return VoiceInterviewBootstrap(
      signedURL: URL(string: "wss://api.elevenlabs.io/v1/convai/conversation?conversation_signature=synthetic")!,
      overrides: overrides,
      personaName: "A"
    )
  }

  func completeSession(sessionID: UUID, transcript: [VoiceTranscriptEntry]) async throws -> VoiceSessionCompletion {
    completeCalls += 1
    recordedCompletionAttempts.append(transcript)
    let nextError = completionErrors.isEmpty ? completeError : completionErrors.removeFirst()
    if completionGated {
      completionStarted = true
      completionStartWaiters.forEach { $0.resume() }
      completionStartWaiters.removeAll()
      await withCheckedContinuation { continuation in
        completionContinuations.append(continuation)
      }
    }
    if let nextError { throw nextError }
    transcripts.append(transcript)
    if let generationStateAfterCompletion { generationState = generationStateAfterCompletion }
    return VoiceSessionCompletion(sessionID: sessionID, status: "completed", allSessionsCompleted: allSessionsCompleted)
  }

  func generateProfile() async throws {
    profileCalls += 1
    if profileGated {
      profileStarted = true
      profileStartWaiters.forEach { $0.resume() }
      profileStartWaiters.removeAll()
      await withCheckedContinuation { continuation in
        profileContinuations.append(continuation)
      }
    }
    if let generationStateAfterProfileAttempt {
      generationState = generationStateAfterProfileAttempt
    }
    if !profileGenerationErrors.isEmpty {
      throw profileGenerationErrors.removeFirst()
    }
  }
  func generateWingfox() async throws {
    wingfoxCalls += 1
    if let wingfoxError { throw wingfoxError }
  }

  func confirmProfile() async throws -> VoiceProfileConfirmation {
    confirmCalls += 1
    confirmStarted = true
    confirmStartWaiters.forEach { $0.resume() }
    confirmStartWaiters.removeAll()
    if confirmGated {
      return await withCheckedContinuation { continuation in
        confirmContinuations.append(continuation)
      }
    }
    return VoiceProfileConfirmation(status: "confirmed", confirmedAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  func personaFetchCallCount() -> Int { personaFetchCalls }
  func startCallCount() -> Int { startCalls }
  func completeCallCount() -> Int { completeCalls }
  func completedTranscripts() -> [[VoiceTranscriptEntry]] { transcripts }
  func completionAttempts() -> [[VoiceTranscriptEntry]] { recordedCompletionAttempts }
  func profileGenerationCalls() -> Int { profileCalls }
  func generationStateFetchCallCount() -> Int { generationStateFetchCalls }
  func wingfoxGenerationCalls() -> Int { wingfoxCalls }
  func confirmCallCount() -> Int { confirmCalls }

  func setWingfoxError(_ error: APIClientError?) { wingfoxError = error }
  func setConfirmGated(_ gated: Bool) { confirmGated = gated }
  func setCompletionGated(_ gated: Bool) {
    completionGated = gated
    completionStarted = false
  }
  func setProfileGated(_ gated: Bool) { profileGated = gated }

  func waitForConfirmStart() async {
    if confirmStarted { return }
    await withCheckedContinuation { continuation in
      confirmStartWaiters.append(continuation)
    }
  }

  func waitForCompletionStart() async {
    if completionStarted { return }
    await withCheckedContinuation { continuation in
      completionStartWaiters.append(continuation)
    }
  }

  func releaseCompletion() {
    completionGated = false
    completionContinuations.forEach { $0.resume() }
    completionContinuations.removeAll()
  }

  func waitForProfileStart() async {
    if profileStarted { return }
    await withCheckedContinuation { continuation in
      profileStartWaiters.append(continuation)
    }
  }

  func releaseProfile() {
    profileContinuations.forEach { $0.resume() }
    profileContinuations.removeAll()
    profileGated = false
  }

  func releaseConfirm() {
    let result = VoiceProfileConfirmation(status: "confirmed", confirmedAt: Date(timeIntervalSince1970: 1_700_000_000))
    confirmContinuations.forEach { $0.resume(returning: result) }
    confirmContinuations.removeAll()
  }

  private func sessionID(for personaID: UUID) -> UUID {
    switch personaID.uuidString.lowercased() {
    case "33333333-3333-4333-8333-333333333333":
      return UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    case "44444444-4444-4444-8444-444444444444":
      return UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    default:
      return UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    }
  }
}

private actor RecordingVoiceInterviewTransport: VoiceInterviewTransport {
  nonisolated let isAvailable = true
  private let events: [VoiceInterviewEvent]
  private var starts = 0

  init(
    events: [VoiceInterviewEvent] = [
      .connected,
      .transcript(VoiceTranscriptEntry(source: .ai, message: "Hello!")),
      .transcript(VoiceTranscriptEntry(source: .user, message: "Nice to meet you.")),
      .ended
    ]
  ) {
    self.events = events
  }

  func start(_ request: VoiceInterviewRequest) async throws -> AsyncThrowingStream<VoiceInterviewEvent, Error> {
    starts += 1
    return AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }

  func stop() async {}

  func startCallCount() -> Int { starts }
}

private struct FixtureSettingsAPI: OnboardingSettingsAPI, Sendable {
  static let settings = OnboardingSettings(
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

private actor SequenceFixtureInsightAPI: ConversationInsightAPI {
  private let ownerID: UUID
  private let signatures: [String]
  private var fetchCount = 0

  init(ownerID: UUID, signatures: [String]) {
    self.ownerID = ownerID
    self.signatures = signatures
  }

  func fetchInsight() async throws -> OwnInsight {
    let signature = signatures[min(fetchCount, signatures.count - 1)]
    fetchCount += 1
    return OwnInsight(
      id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
      userID: ownerID,
      personalityTags: ["Listens carefully"],
      status: "draft",
      overallSignature: signature
    )
  }
}

private actor EditableDraftInsightAPI: ConversationInsightAPI {
  private var profile: OwnInsight
  private var shouldFail = false
  private let wrongOwnerOnSave: Bool
  init(ownerID: UUID, wrongOwnerOnSave: Bool = false) {
    profile = OwnInsight(id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
      userID: ownerID, personalityTags: ["Calm", "Curious", "Kind"], status: "draft", overallSignature: nil)
    self.wrongOwnerOnSave = wrongOwnerOnSave
  }
  func failNextSave() { shouldFail = true }
  func fetchInsight() async throws -> OwnInsight { profile }
  func updateDraftProfile(tags: [String], bio: String) async throws -> OwnInsight {
    if shouldFail { shouldFail = false; throw APIClientError.temporarilyUnavailable }
    let saved = OwnInsight(id: profile.id, userID: wrongOwnerOnSave ? UUID() : profile.userID,
      personalityTags: tags, status: "draft", overallSignature: profile.overallSignature, bio: bio)
    if !wrongOwnerOnSave { profile = saved }
    return saved
  }
}

private struct FixtureInsightAPI: ConversationInsightAPI, Sendable {
  let ownerID: UUID
  let status: String

  init(ownerID: UUID, status: String = "draft") {
    self.ownerID = ownerID
    self.status = status
  }

  func fetchInsight() async throws -> OwnInsight {
    OwnInsight(
      id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
      userID: ownerID,
      personalityTags: ["Listens carefully"],
      status: status,
      overallSignature: "A saved signature."
    )
  }
}

private actor GatedFixtureInsightAPI: ConversationInsightAPI {
  private let ownerID: UUID
  private var started = false
  private var released = false

  init(ownerID: UUID) {
    self.ownerID = ownerID
  }

  func fetchInsight() async throws -> OwnInsight {
    started = true
    while !released {
      await Task.yield()
    }
    return OwnInsight(
      id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
      userID: ownerID,
      personalityTags: ["Listens carefully"],
      status: "draft",
      overallSignature: "A saved signature."
    )
  }

  func waitForFetchStart() async {
    while !started {
      await Task.yield()
    }
  }

  func release() {
    released = true
  }
}


@MainActor
final class ChatMeetupReflectionVoiceLimitTests: XCTestCase {
  private let ownerID = "11111111-1111-4111-8111-111111111111"
  private let meetupID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

  func testDeadlineStopsHangingVoiceAndKeepsFinalizedStatementsForDrafting() async {
    let deadlines = ManualReflectionDeadlineSleeper()
    let transport = ControlledReflectionVoiceTransport()
    let store = makeStore(transport: transport, deadlines: deadlines)

    await store.start()
    await deadlines.waitForScheduledCount(1)
    await transport.waitForStreamCount(1)
    await transport.emit(
      .transcript(VoiceTranscriptEntry(source: .user, message: "I like a quiet first meeting.")),
      on: 0
    )
    await waitForStatement("I like a quiet first meeting.", in: store)

    let duration = await deadlines.requestedDuration(at: 0)
    XCTAssertEqual(duration, .seconds(180))

    await deadlines.fire(0)
    await transport.waitForStopCount(1)
    await waitForPhase(.idle, in: store)

    XCTAssertEqual(store.userStatements.map(\.text), ["I like a quiet first meeting."])
    XCTAssertEqual(
      store.statusMessage,
      "Voice reflection reached its time limit. You can draft suggestions from your own words or leave without saving."
    )
    XCTAssertNil(store.errorMessage)
  }

  func testEndedAndErroredStreamsStopTransportAndRetainOwnerStatements() async {
    let endedDeadlines = ManualReflectionDeadlineSleeper()
    let endedTransport = ControlledReflectionVoiceTransport()
    let endedStore = makeStore(transport: endedTransport, deadlines: endedDeadlines)

    await endedStore.start()
    await endedDeadlines.waitForScheduledCount(1)
    await endedTransport.waitForStreamCount(1)
    await endedTransport.emit(
      .transcript(VoiceTranscriptEntry(source: .user, message: "I prefer a relaxed pace.")),
      on: 0
    )
    await waitForStatement("I prefer a relaxed pace.", in: endedStore)
    await endedTransport.end(on: 0)
    await endedTransport.waitForStopCount(1)
    await waitForPhase(.idle, in: endedStore)

    XCTAssertEqual(endedStore.userStatements.map(\.text), ["I prefer a relaxed pace."])
    XCTAssertEqual(
      endedStore.statusMessage,
      "Voice ended. You can draft suggestions from your own words or leave without saving."
    )

    let failedDeadlines = ManualReflectionDeadlineSleeper()
    let failedTransport = ControlledReflectionVoiceTransport()
    let failedStore = makeStore(transport: failedTransport, deadlines: failedDeadlines)

    await failedStore.start()
    await failedDeadlines.waitForScheduledCount(1)
    await failedTransport.waitForStreamCount(1)
    await failedTransport.emit(
      .transcript(VoiceTranscriptEntry(source: .user, message: "I enjoy thoughtful conversation.")),
      on: 0
    )
    await waitForStatement("I enjoy thoughtful conversation.", in: failedStore)
    await failedTransport.fail(on: 0)
    await failedTransport.waitForStopCount(1)
    await waitForPhase(.idle, in: failedStore)

    XCTAssertEqual(failedStore.userStatements.map(\.text), ["I enjoy thoughtful conversation."])
    XCTAssertEqual(
      failedStore.errorMessage,
      "Voice reflection ended. You can retry or leave without saving."
    )
    await endedDeadlines.fireAll()
    await failedDeadlines.fireAll()
  }

  func testCancelledDeadlineCannotStopAReplacementSession() async {
    let deadlines = ManualReflectionDeadlineSleeper()
    let transport = ControlledReflectionVoiceTransport()
    let store = makeStore(transport: transport, deadlines: deadlines)

    await store.start()
    await deadlines.waitForScheduledCount(1)
    await transport.waitForStreamCount(1)
    await transport.end(on: 0)
    await transport.waitForStopCount(1)
    await waitForPhase(.idle, in: store)

    await store.start()
    await deadlines.waitForScheduledCount(2)
    await transport.waitForStreamCount(2)

    await deadlines.fire(0)
    await deadlines.waitForCompletion(0)
    for _ in 0..<20 { await Task.yield() }

    let stopCount = await transport.stopCount()
    XCTAssertEqual(stopCount, 1)
    XCTAssertEqual(store.phase, .interviewing)

    await transport.end(on: 1)
    await transport.waitForStopCount(2)
    await waitForPhase(.idle, in: store)
    await deadlines.fireAll()
  }

  func testLateStartupIsStoppedBeforeAReplacementCanStart() async {
    let deadlines = ManualReflectionDeadlineSleeper()
    let transport = ControlledReflectionVoiceTransport(gateFirstStart: true)
    let store = makeStore(transport: transport, deadlines: deadlines)
    let startup = Task { await store.start() }

    await deadlines.waitForScheduledCount(1)
    await transport.waitForStartCallCount(1)
    await store.stopAndClear()
    XCTAssertEqual(store.phase, .idle)

    await store.start()
    let blockedStartCount = await transport.startCallCount()
    XCTAssertEqual(blockedStartCount, 1)

    await transport.releaseFirstStart()
    await startup.value
    await transport.waitForStopCount(2)
    XCTAssertEqual(store.phase, .idle)

    await store.start()
    await deadlines.waitForScheduledCount(2)
    await transport.waitForStartCallCount(2)
    await transport.waitForStreamCount(2)
    XCTAssertEqual(store.phase, .interviewing)

    await deadlines.fire(0)
    await deadlines.waitForCompletion(0)
    for _ in 0..<20 { await Task.yield() }

    let stopCount = await transport.stopCount()
    XCTAssertEqual(stopCount, 2)
    XCTAssertEqual(store.phase, .interviewing)

    await transport.end(on: 1)
    await transport.waitForStopCount(3)
    await waitForPhase(.idle, in: store)
    await deadlines.fireAll()
  }

  func testLeavingReflectionStillClearsTemporaryStatements() async {
    let deadlines = ManualReflectionDeadlineSleeper()
    let transport = ControlledReflectionVoiceTransport()
    let store = makeStore(transport: transport, deadlines: deadlines)

    await store.start()
    await deadlines.waitForScheduledCount(1)
    await transport.waitForStreamCount(1)
    await transport.emit(
      .transcript(VoiceTranscriptEntry(source: .user, message: "Keep this only until I leave.")),
      on: 0
    )
    await waitForStatement("Keep this only until I leave.", in: store)

    await store.stopAndClear()

    XCTAssertTrue(store.userStatements.isEmpty)
    XCTAssertNil(store.draft)
    XCTAssertEqual(store.phase, .idle)
    await deadlines.fireAll()
  }

  private func makeStore(
    transport: ControlledReflectionVoiceTransport,
    deadlines: ManualReflectionDeadlineSleeper
  ) -> ChatMeetupReflectionStore {
    ChatMeetupReflectionStore(
      ownerID: ownerID,
      meetupID: meetupID,
      api: ReflectionStoreTestAPI(),
      transport: transport,
      permissionClient: DebugVoicePermissionClient(),
      deadlineSleeper: { duration in await deadlines.sleep(for: duration) }
    )
  }

  private func waitForStatement(_ text: String, in store: ChatMeetupReflectionStore) async {
    for _ in 0..<500 {
      if store.userStatements.contains(where: { $0.text == text }) { return }
      await Task.yield()
    }
    XCTFail("The finalized owner statement was not added to the reflection.")
  }

  private func waitForPhase(_ phase: ChatMeetupReflectionPhase, in store: ChatMeetupReflectionStore) async {
    for _ in 0..<500 {
      if store.phase == phase { return }
      await Task.yield()
    }
    XCTFail("The reflection did not reach phase \(phase).")
  }
}

private actor ManualReflectionDeadlineSleeper {
  private var nextID = 0
  private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
  private var completed = Set<Int>()
  private var durations: [Int: Duration] = [:]

  func sleep(for duration: Duration) async {
    let id = nextID
    nextID += 1
    durations[id] = duration
    await withCheckedContinuation { continuation in
      continuations[id] = continuation
    }
    completed.insert(id)
  }

  func waitForScheduledCount(_ count: Int) async {
    while nextID < count { await Task.yield() }
  }

  func requestedDuration(at id: Int) -> Duration? { durations[id] }

  func fire(_ id: Int) {
    continuations.removeValue(forKey: id)?.resume()
  }

  func fireAll() {
    let pending = Array(continuations.values)
    continuations.removeAll()
    pending.forEach { $0.resume() }
  }

  func waitForCompletion(_ id: Int) async {
    while !completed.contains(id) { await Task.yield() }
  }
}

private actor ControlledReflectionVoiceTransport: VoiceInterviewTransport {
  nonisolated let isAvailable = true
  private let gateFirstStart: Bool
  private var continuations: [AsyncThrowingStream<VoiceInterviewEvent, Error>.Continuation] = []
  private var gatedStartContinuations: [
    CheckedContinuation<AsyncThrowingStream<VoiceInterviewEvent, Error>, Never>
  ] = []
  private var starts = 0
  private var stops = 0

  init(gateFirstStart: Bool = false) {
    self.gateFirstStart = gateFirstStart
  }

  func start(_ request: VoiceInterviewRequest) async throws -> AsyncThrowingStream<VoiceInterviewEvent, Error> {
    starts += 1
    if gateFirstStart && starts == 1 {
      return await withCheckedContinuation { continuation in
        gatedStartContinuations.append(continuation)
      }
    }
    let pair = AsyncThrowingStream<VoiceInterviewEvent, Error>.makeStream()
    continuations.append(pair.continuation)
    return pair.stream
  }

  func stop() async {
    stops += 1
    continuations.forEach { $0.finish() }
  }

  func emit(_ event: VoiceInterviewEvent, on index: Int) {
    guard continuations.indices.contains(index) else { return }
    continuations[index].yield(event)
  }

  func end(on index: Int) {
    guard continuations.indices.contains(index) else { return }
    continuations[index].yield(.ended)
    continuations[index].finish()
  }

  func fail(on index: Int) {
    guard continuations.indices.contains(index) else { return }
    continuations[index].finish(throwing: ReflectionTransportTestError.failed)
  }

  func stopCount() -> Int { stops }
  func startCallCount() -> Int { starts }

  func releaseFirstStart() {
    guard !gatedStartContinuations.isEmpty else { return }
    let pair = AsyncThrowingStream<VoiceInterviewEvent, Error>.makeStream()
    continuations.append(pair.continuation)
    gatedStartContinuations.removeFirst().resume(returning: pair.stream)
  }

  func waitForStartCallCount(_ count: Int) async {
    while starts < count { await Task.yield() }
  }

  func waitForStreamCount(_ count: Int) async {
    while continuations.count < count { await Task.yield() }
  }

  func waitForStopCount(_ count: Int) async {
    while stops < count { await Task.yield() }
  }
}

private enum ReflectionTransportTestError: Error {
  case failed
}

private struct ReflectionStoreTestAPI: DirectChatsAPI {
  func fetchDirectChats() async throws -> [DirectChatSummary] { [] }
  func fetchDirectMessages(roomID: UUID, limit: Int, cursor: String?) async throws -> DirectChatMessagesPayload {
    DirectChatMessagesPayload(messages: [])
  }
  func sendDirectMessage(roomID: UUID, content: String) async throws -> DirectChatSendResult {
    DirectChatSendResult(id: UUID(), content: content, createdAt: Date())
  }
  func markDirectMessageRead(roomID: UUID, messageID: UUID) async throws -> DirectChatReadResult {
    DirectChatReadResult(readCount: 1)
  }
  func fetchChatRequests() async throws -> [ChatRequestSummary] { [] }
  func createChatRequest(matchID: UUID) async throws -> ChatRequestCreateResult {
    ChatRequestCreateResult(id: UUID(), matchID: matchID, status: "pending", expiresAt: Date().addingTimeInterval(60))
  }
  func respondToChatRequest(requestID: UUID, action: ChatRequestAction) async throws -> ChatRequestDecisionResult {
    ChatRequestDecisionResult(requestID: requestID, status: "declined", directChatRoomID: nil)
  }

  func bootstrapMeetupReflection(meetupID: UUID, voice: RealtimeVoice) async throws -> RealtimeVoiceBootstrap {
    RealtimeVoiceBootstrap(
      sessionID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
      clientSecret: "ek_synthetic_test_secret",
      expiresAt: Date().addingTimeInterval(60).timeIntervalSince1970,
      model: "gpt-realtime-2.1-mini",
      overrides: VoiceInterviewOverrides(
        prompt: "Private self-reflection only.",
        firstMessage: "What feels worth noticing?",
        language: .en,
        voiceID: "cedar"
      )
    )
  }
}
