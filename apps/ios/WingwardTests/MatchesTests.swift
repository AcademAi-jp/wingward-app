import Foundation
import XCTest
@testable import Wingward

final class MatchesTests: XCTestCase {
  func testJudgeBuildBindingIsStrictAndMutuallyExclusive() throws {
    XCTAssertFalse(try DemoJudgeMatchingConfiguration.enabled(info: [:], arguments: [], allowLaunchArgument: false))
    XCTAssertTrue(try DemoJudgeMatchingConfiguration.enabled(info: ["WINGWARD_DEMO_JUDGE_MATCHING": "YES"], arguments: [], allowLaunchArgument: false))
    XCTAssertFalse(try DemoJudgeMatchingConfiguration.enabled(info: [:], arguments: ["--wingward-demo-judge-matching"], allowLaunchArgument: false))
    XCTAssertTrue(try DemoJudgeMatchingConfiguration.enabled(info: [:], arguments: ["--wingward-demo-judge-matching"], allowLaunchArgument: true))
    for invalid in ["true", "", "$(WINGWARD_DEMO_JUDGE_MATCHING)"] {
      XCTAssertThrowsError(try DemoJudgeMatchingConfiguration.enabled(info: ["WINGWARD_DEMO_JUDGE_MATCHING": invalid], arguments: [], allowLaunchArgument: false))
    }
    XCTAssertThrowsError(try DemoJudgeMatchingConfiguration.enabled(info: ["WINGWARD_DEMO_JUDGE_MATCHING": "YES"], arguments: ["--wingward-recording-matching"], allowLaunchArgument: false))
    XCTAssertThrowsError(try DemoJudgeMatchingConfiguration.enabled(info: ["WINGWARD_DEMO_JUDGE_MATCHING": "YES", "WINGWARD_RECORDING_REHEARSAL_MATCHING": "YES"], arguments: [], allowLaunchArgument: true))
    XCTAssertThrowsError(try DemoJudgeMatchingConfiguration.enabled(info: ["WINGWARD_RECORDING_REHEARSAL_MATCHING": "YES"], arguments: ["--wingward-demo-judge-matching"], allowLaunchArgument: true))
  }

  func testRecordingBuildBindingSurvivesHomeLaunchAndCannotEnableRelease() throws {
    XCTAssertFalse(try RecordingRehearsalMatchingConfiguration.enabled(info: [:], arguments: [], allowDevelopmentMode: true))
    XCTAssertTrue(try RecordingRehearsalMatchingConfiguration.enabled(info: ["WINGWARD_RECORDING_REHEARSAL_MATCHING": "YES"], arguments: [], allowDevelopmentMode: true))
    XCTAssertTrue(try RecordingRehearsalMatchingConfiguration.enabled(info: [:], arguments: ["--wingward-recording-matching"], allowDevelopmentMode: true))
    XCTAssertFalse(try RecordingRehearsalMatchingConfiguration.enabled(info: [:], arguments: ["--wingward-recording-matching"], allowDevelopmentMode: false))
    XCTAssertThrowsError(try RecordingRehearsalMatchingConfiguration.enabled(info: ["WINGWARD_RECORDING_REHEARSAL_MATCHING": "YES"], arguments: [], allowDevelopmentMode: false))
    for invalid: Any in ["true", "", "$(WINGWARD_RECORDING_REHEARSAL_MATCHING)", true] {
      XCTAssertThrowsError(try RecordingRehearsalMatchingConfiguration.enabled(info: ["WINGWARD_RECORDING_REHEARSAL_MATCHING": invalid], arguments: [], allowDevelopmentMode: true))
    }
  }

  func testDiscoveryPayloadRejectsWrongSourceCountsAndDuplicatePartners() throws {
    let valid = Data("{\"data\":{\"source\":\"ordinary-discovery\",\"matches\":[\(matchJSON())],\"total_matches\":1}}".utf8)
    let decoded = try APIResponseDecoder.decode(valid, as: DiscoveryMatchesPayload.self)
    XCTAssertEqual(decoded.matches.count, 1)
    for invalid in [
      "{\"data\":{\"source\":\"daily-results\",\"matches\":[],\"total_matches\":0}}",
      "{\"data\":{\"source\":\"ordinary-discovery\",\"matches\":[],\"total_matches\":1}}",
      "{\"data\":{\"source\":\"ordinary-discovery\",\"matches\":[\(matchJSON()),\(matchJSON())],\"total_matches\":2}}",
    ] {
      XCTAssertThrowsError(try APIResponseDecoder.decode(Data(invalid.utf8), as: DiscoveryMatchesPayload.self))
    }
    for invalid in [
      "{\"data\":{\"source\":\"ordinary-discovery\",\"outcome\":\"eligible\",\"count\":11}}",
      "{\"data\":{\"source\":\"recording\",\"outcome\":\"eligible\",\"count\":1}}",
    ] {
      XCTAssertThrowsError(try APIResponseDecoder.decode(Data(invalid.utf8), as: DemoJudgePreviewResult.self))
    }
  }

  @MainActor
  func testJudgePreviewNeverStartsAndExplicitStartLoadsIndependentResults() async throws {
    let api = JudgeMatchesTestAPI(previewCount: 2)
    let store = MatchesStore(ownerID: "synthetic-owner", api: api)
    await store.load().value
    XCTAssertNil(store.payload)
    XCTAssertNotNil(store.discoveryPayload)
    XCTAssertFalse(store.canStartDemoJudgeMatching)
    XCTAssertNil(store.startDemoJudgeMatching())
    try await XCTUnwrap(store.previewDemoJudgeMatching()).value
    let before = await api.counts()
    XCTAssertEqual(before.preview, 1)
    XCTAssertEqual(before.start, 0)
    XCTAssertEqual(before.daily, 0)
    XCTAssertTrue(store.canStartDemoJudgeMatching)
    try await XCTUnwrap(store.startDemoJudgeMatching()).value
    let after = await api.counts()
    XCTAssertEqual(after.start, 1)
    XCTAssertEqual(after.results, 2)
    XCTAssertEqual(store.demoJudgePhase, .finished(.started, 2))
    XCTAssertNil(store.startDemoJudgeMatching())
    await store.retry().value
    XCTAssertNil(store.startDemoJudgeMatching(), "Refreshing cannot repeat a mutating Start.")
  }

  @MainActor
  func testJudgeZeroCandidatesAndFailedStartNeverAutomaticallyRetry() async throws {
    let emptyAPI = JudgeMatchesTestAPI(previewCount: 0)
    let empty = MatchesStore(ownerID: "synthetic-owner", api: emptyAPI)
    await empty.load().value
    try await XCTUnwrap(empty.previewDemoJudgeMatching()).value
    XCTAssertFalse(empty.canStartDemoJudgeMatching)
    XCTAssertNil(empty.startDemoJudgeMatching())
    let failingAPI = JudgeMatchesTestAPI(previewCount: 1, failsStart: true)
    let failing = MatchesStore(ownerID: "synthetic-owner", api: failingAPI)
    await failing.load().value
    try await XCTUnwrap(failing.previewDemoJudgeMatching()).value
    try await XCTUnwrap(failing.startDemoJudgeMatching()).value
    XCTAssertEqual(failing.demoJudgePhase, .failed)
    XCTAssertNil(failing.startDemoJudgeMatching())
    await failing.retry().value
    XCTAssertFalse(failing.canPreviewDemoJudgeMatching)
    let counts = await failingAPI.counts()
    XCTAssertEqual(counts.start, 1)
    XCTAssertEqual(counts.daily, 0)
  }

  func testJudgeLiveFactoryUsesResultsEndpointAndRejectsOwnerChangeAndModeConflict() async throws {
    let auth = SwitchableMatchesAuthService(session: AuthSession(accessToken: "token-a"))
    let profile = TokenMappedMatchesProfileAPI(profiles: ["token-a": "owner-a", "token-b": "owner-b"])
    let transport = CapturingMatchesTransport(responseData: Data(#"{"data":{"source":"ordinary-discovery","matches":[],"total_matches":0}}"#.utf8))
    let factory = LiveMatchesAPIFactory(baseURL: URL(string: "https://api.example.test")!, authService: auth, profileAPI: profile, transport: transport, demoJudgeMatchingEnabled: true)
    let api = try XCTUnwrap(factory.make(ownerID: "owner-a"))
    XCTAssertNil(api.recordingRehearsalMatchingAPI)
    let judge = try XCTUnwrap(api.demoJudgeMatchingAPI)
    _ = try await judge.fetchDiscoveryResults()
    let requests = await transport.requestsSnapshot()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.url?.path, LiveMatchesAPI.discoveryResultsPath)
    XCTAssertEqual(requests.first?.httpMethod, "GET")
    await auth.setSession(AuthSession(accessToken: "token-b"))
    do { _ = try await judge.fetchDiscoveryResults(); XCTFail("Old owner must fail") }
    catch { XCTAssertEqual(error as? APIClientError, .unauthenticated) }
    let after = await transport.requestsSnapshot()
    XCTAssertEqual(after.count, 1)
    let conflicting = LiveMatchesAPIFactory(baseURL: URL(string: "https://api.example.test")!, authService: auth, profileAPI: profile, transport: transport, recordingRehearsalMatchingEnabled: true, demoJudgeMatchingEnabled: true)
    XCTAssertNil(conflicting.make(ownerID: "owner-a"))
  }

  func testJudgeLivePreviewAndStartUseDistinctPOSTRoutes() async throws {
    let auth = SwitchableMatchesAuthService(session: AuthSession(accessToken: "token-a"))
    let profile = TokenMappedMatchesProfileAPI(profiles: ["token-a": "owner-a"])
    let previewTransport = CapturingMatchesTransport(responseData: Data(#"{"data":{"source":"ordinary-discovery","outcome":"eligible","count":2}}"#.utf8))
    let previewAPI = try LiveMatchesAPI(baseURL: URL(string: "https://api.example.test")!, ownerID: "owner-a", authService: auth, profileAPI: profile, transport: previewTransport, demoJudgeMatchingEnabled: true)
    _ = try await previewAPI.previewDemoJudgeMatching()
    let previewRequests = await previewTransport.requestsSnapshot()
    XCTAssertEqual(previewRequests.map { $0.url?.path }, [LiveMatchesAPI.demoJudgePreviewPath])
    XCTAssertEqual(previewRequests.first?.httpMethod, "POST")
    let startTransport = CapturingMatchesTransport(responseData: Data(#"{"data":{"source":"ordinary-discovery","outcome":"started_partial","count":1}}"#.utf8))
    let startAPI = try LiveMatchesAPI(baseURL: URL(string: "https://api.example.test")!, ownerID: "owner-a", authService: auth, profileAPI: profile, transport: startTransport, demoJudgeMatchingEnabled: true)
    let started = try await startAPI.startDemoJudgeMatching()
    XCTAssertEqual(started.outcome, .startedPartial)
    let startRequests = await startTransport.requestsSnapshot()
    XCTAssertEqual(startRequests.map { $0.url?.path }, [LiveMatchesAPI.demoJudgeStartPath])
    XCTAssertEqual(startRequests.first?.httpMethod, "POST")
  }

  func testDailyResultsDecodeUsesSafeFallbackAndIgnoresScoreFields() throws {
    let payload = try decode(responseData())

    XCTAssertEqual(payload.batchDate, "2026-09-07")
    XCTAssertEqual(payload.matches.count, 1)
    XCTAssertEqual(payload.matches[0].partner.displayName, "Wingward member")
    XCTAssertEqual(payload.matches[0].status, "pending")
  }

  func testDailyResultsRejectsHTTPAvatarURL() {
    XCTAssertThrowsError(try decode(responseData(avatarURL: "http://images.example/avatar.png"))) { error in
      XCTAssertEqual(error as? APIClientError, .invalidResponse)
    }
  }

  func testDailyResultsRejectsInvalidCalendarDateAfterNormalization() {
    XCTAssertThrowsError(try decode(responseData(batchDate: "2026-02-30"))) { error in
      XCTAssertEqual(error as? APIClientError, .invalidResponse)
    }
  }

  func testDailyResultsRejectsExtremeConversationCountsWithoutOverflow() {
    XCTAssertThrowsError(
      try decode(
        responseData(
          matches: "",
          totalMatches: 0,
          conversationsCompleted: Int.max,
          conversationsFailed: Int.max
        )
      )
    ) { error in
      XCTAssertEqual(error as? APIClientError, .invalidResponse)
    }
  }

  func testDailyResultsRejectsDuplicateMatchAndPartnerIDs() {
    let duplicatePartner = matchJSON(
      id: "22222222-2222-2222-2222-222222222222",
      partnerID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    )
    XCTAssertThrowsError(
      try decode(responseData(matches: "\(matchJSON()),\(duplicatePartner)", totalMatches: 2))
    ) { error in
      XCTAssertEqual(error as? APIClientError, .invalidResponse)
    }

    let duplicateMatch = matchJSON(
      partnerID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    )
    XCTAssertThrowsError(
      try decode(responseData(matches: "\(matchJSON()),\(duplicateMatch)", totalMatches: 2))
    ) { error in
      XCTAssertEqual(error as? APIClientError, .invalidResponse)
    }
  }

  func testLiveMatchesAPIUsesDailyResultsPath() async throws {
    let client = FakeAuthenticatedAPIClient()
    let request = APIRequest(method: .get, path: LiveMatchesAPI.dailyResultsPath)
    await client.setResponseData(responseData(), for: request)

    let api = LiveMatchesAPI(client: client)
    let payload = try await api.fetchDailyResults()
    let requests = await client.recordedRequests()

    XCTAssertEqual(payload.totalMatches, 1)
    XCTAssertEqual(requests, [request])
  }

  func testRecordingRehearsalCapabilityIsDisabledByDefault() {
    let api = LiveMatchesAPI(client: FakeAuthenticatedAPIClient())

    XCTAssertNil(api.recordingRehearsalMatchingAPI)
  }

  func testDisabledRehearsalMethodsCannotCreatePOSTRequests() async throws {
    let client = FakeAuthenticatedAPIClient()
    let api = LiveMatchesAPI(client: client)

    do {
      _ = try await api.previewRecordingRehearsal()
      XCTFail("The preview endpoint must remain disabled without explicit opt-in")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidState)
    }

    let requests = await client.recordedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testLiveMatchesAPIUsesOnlyExpectedRehearsalPOSTsThenDailyGET() async throws {
    let client = FakeAuthenticatedAPIClient()
    let previewRequest = APIRequest(method: .post, path: LiveMatchesAPI.recordingRehearsalPreviewPath)
    let startRequest = APIRequest(method: .post, path: LiveMatchesAPI.recordingRehearsalStartPath)
    let dailyRequest = APIRequest(method: .get, path: LiveMatchesAPI.dailyResultsPath)
    await client.setResponseData(rehearsalResponse(outcome: "eligible", count: 1), for: previewRequest)
    await client.setResponseData(rehearsalResponse(outcome: "started", count: 1), for: startRequest)
    await client.setResponseData(responseData(), for: dailyRequest)
    let api = LiveMatchesAPI(client: client, recordingRehearsalMatchingEnabled: true)
    let rehearsalAPI = try XCTUnwrap(api.recordingRehearsalMatchingAPI)

    _ = try await rehearsalAPI.previewRecordingRehearsal()
    _ = try await rehearsalAPI.startRecordingRehearsal()
    _ = try await api.fetchDailyResults()

    let requests = await client.recordedRequests()
    XCTAssertEqual(requests, [previewRequest, startRequest, dailyRequest])
    XCTAssertTrue(requests.allSatisfy { $0.body == nil })
  }

  func testRecordingRehearsalDTORejectsUnexpectedFieldsAndWrongCounts() {
    let extraMemberData = Data(
      #"{"data":{"outcome":"eligible","count":1,"partner":{"nickname":"outside"}}}"#.utf8
    )
    XCTAssertThrowsError(
      try APIResponseDecoder.decode(extraMemberData, as: RecordingRehearsalPreviewResult.self)
    )

    let wrongEligibleCount = Data(#"{"data":{"outcome":"eligible","count":0}}"#.utf8)
    XCTAssertThrowsError(
      try APIResponseDecoder.decode(wrongEligibleCount, as: RecordingRehearsalPreviewResult.self)
    )
  }

  func testLiveMatchesAPIUsesOwnerBoundTokenAndInjectedTransport() async throws {
    let auth = SwitchableMatchesAuthService(session: AuthSession(accessToken: "token-a"))
    let profile = TokenMappedMatchesProfileAPI(profiles: ["token-a": "owner-a"])
    let transport = CapturingMatchesTransport(responseData: responseData())
    let api = try LiveMatchesAPI(
      baseURL: URL(string: "https://api.example.test")!,
      ownerID: "owner-a",
      authService: auth,
      profileAPI: profile,
      transport: transport
    )

    let payload = try await api.fetchDailyResults()
    let requests = await transport.requestsSnapshot()

    XCTAssertEqual(payload.totalMatches, 1)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.url?.path, LiveMatchesAPI.dailyResultsPath)
    XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token-a")
  }

  func testLiveMatchesAPIFactoryBindsOwnerAndInjectedTransport() async throws {
    let auth = SwitchableMatchesAuthService(session: AuthSession(accessToken: "token-a"))
    let profile = TokenMappedMatchesProfileAPI(
      profiles: ["token-a": "owner-a", "token-b": "owner-b"]
    )
    let transport = CapturingMatchesTransport(responseData: responseData())
    let factory = LiveMatchesAPIFactory(
      baseURL: URL(string: "https://api.example.test")!,
      authService: auth,
      profileAPI: profile,
      transport: transport
    )
    let api = try XCTUnwrap(factory.make(ownerID: "owner-a"))

    await auth.setSession(AuthSession(accessToken: "token-b"))
    do {
      _ = try await api.fetchDailyResults()
      XCTFail("A factory-created API must reject a different owner's session")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .unauthenticated)
    }

    let requests = await transport.requestsSnapshot()
    XCTAssertEqual(requests.count, 0)
  }

  func testLiveMatchesAPIRejectsNewOwnerBeforeTransport() async throws {
    let auth = SwitchableMatchesAuthService(session: AuthSession(accessToken: "token-a"))
    let profile = TokenMappedMatchesProfileAPI(
      profiles: ["token-a": "owner-a", "token-b": "owner-b"]
    )
    let transport = CapturingMatchesTransport(responseData: responseData())
    let api = try LiveMatchesAPI(
      baseURL: URL(string: "https://api.example.test")!,
      ownerID: "owner-a",
      authService: auth,
      profileAPI: profile,
      transport: transport
    )

    await auth.setSession(AuthSession(accessToken: "token-b"))
    do {
      _ = try await api.fetchDailyResults()
      XCTFail("An old owner-bound API must reject a new owner's session")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .unauthenticated)
    }

    let requests = await transport.requestsSnapshot()
    XCTAssertEqual(requests.count, 0)
  }

  func testLiveMatchesAPICapturesOldTokenWhileProfileVerificationAwaits() async throws {
    let auth = SwitchableMatchesAuthService(session: AuthSession(accessToken: "token-a"))
    let profile = GatedMatchesProfileAPI(profileID: "owner-a")
    let transport = CapturingMatchesTransport(responseData: responseData())
    let api = try LiveMatchesAPI(
      baseURL: URL(string: "https://api.example.test")!,
      ownerID: "owner-a",
      authService: auth,
      profileAPI: profile,
      transport: transport
    )

    let requestTask = Task {
      try await api.fetchDailyResults()
    }
    defer { requestTask.cancel() }

    guard await profile.waitUntilStarted() else {
      await profile.release()
      requestTask.cancel()
      _ = await requestTask.result
      XCTFail("The owner verification request did not start")
      return
    }
    await auth.setSession(AuthSession(accessToken: "token-b"))
    await profile.release()

    let payload = try await requestTask.value
    let requests = await transport.requestsSnapshot()
    XCTAssertEqual(payload.totalMatches, 1)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token-a")
  }

  func testRecoveryPurposeSessionCannotCreateMatchesRequest() async throws {
    let auth = SwitchableMatchesAuthService(
      session: AuthSession(accessToken: "recovery-token", purpose: .passwordRecovery)
    )
    let profile = CountingMatchesProfileAPI(profileID: "owner-a")
    let transport = CapturingMatchesTransport(responseData: responseData())
    let api = try LiveMatchesAPI(
      baseURL: URL(string: "https://api.example.test")!,
      ownerID: "owner-a",
      authService: auth,
      profileAPI: profile,
      transport: transport
    )

    do {
      _ = try await api.fetchDailyResults()
      XCTFail("Recovery-purpose sessions must not reach daily matches")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .unauthenticated)
    }

    let requests = await transport.requestsSnapshot()
    XCTAssertEqual(requests.count, 0)
    let profileCalls = await profile.fetchProfileCallCount()
    XCTAssertEqual(profileCalls, 0)
  }

  @MainActor
  func testStoreLoadsResults() async throws {
    let payload = try decode(responseData())
    let api = SequencedMatchesAPI(results: [.success(payload)])
    let store = MatchesStore(ownerID: "owner-a", api: api)

    await store.load().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.payload, payload)
  }

  @MainActor
  func testStoreLoadsAnEmptyResult() async throws {
    let payload = try decode(responseData(matches: "", totalMatches: 0))
    let api = SequencedMatchesAPI(results: [.success(payload)])
    let store = MatchesStore(ownerID: "owner-a", api: api)

    await store.load().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertTrue(store.payload?.matches.isEmpty == true)
  }

  @MainActor
  func testLoadAndNormalRefreshNeverCallRehearsalEndpoints() async throws {
    let empty = try decode(responseData(matches: "", totalMatches: 0))
    let state = ScriptedRecordingRehearsalState(dailyPayload: empty)
    let api = ScriptedRecordingRehearsalMatchesAPI(state: state)
    let store = MatchesStore(ownerID: "owner-a", api: api)

    await store.load().value
    XCTAssertTrue(store.canStartRecordingRehearsal)
    await store.retry().value

    let calls = await state.recordedCalls()
    XCTAssertEqual(calls, ["daily", "daily"])
    XCTAssertEqual(store.rehearsalPhase, .idle)
  }

  @MainActor
  func testEligibilityPreviewNeverStartsMatchingAndKeepsStartForRecording() async throws {
    let empty = try decode(responseData(matches: "", totalMatches: 0))
    let state = ScriptedRecordingRehearsalState(dailyPayload: empty, defersPreview: true)
    let store = MatchesStore(
      ownerID: "owner-a",
      api: ScriptedRecordingRehearsalMatchesAPI(state: state)
    )

    await store.load().value
    let task = try XCTUnwrap(store.previewRecordingRehearsal())
    let previewStarted = await state.waitForPreview()
    XCTAssertTrue(previewStarted)
    XCTAssertFalse(store.canStartRecordingRehearsal)
    await state.releasePreview(.eligible)
    await task.value

    XCTAssertEqual(store.rehearsalPhase, .previewed(.init(outcome: .eligible, count: 1)))
    XCTAssertTrue(store.canStartRecordingRehearsal)
    let calls = await state.recordedCalls()
    XCTAssertEqual(calls, ["daily", "preview"])
  }

  @MainActor
  func testExplicitRehearsalStartsOnlyAfterEligiblePreviewThenLoadsServerResults() async throws {
    let empty = try decode(responseData(matches: "", totalMatches: 0))
    let results = try decode(responseData())
    let state = ScriptedRecordingRehearsalState(dailyPayload: empty, refreshedPayload: results)
    let api = ScriptedRecordingRehearsalMatchesAPI(state: state)
    let store = MatchesStore(ownerID: "owner-a", api: api)

    await store.load().value
    let task = try XCTUnwrap(store.startRecordingRehearsal())
    await task.value

    let calls = await state.recordedCalls()
    XCTAssertEqual(calls, ["daily", "preview", "start", "daily"])
    XCTAssertEqual(store.rehearsalPhase, .finished(.started))
    XCTAssertEqual(store.payload, results)
  }

  @MainActor
  func testPartialRehearsalIsReportedAndUsesNormalDailyResults() async throws {
    let empty = try decode(responseData(matches: "", totalMatches: 0))
    let results = try decode(responseData())
    let state = ScriptedRecordingRehearsalState(
      dailyPayload: empty,
      refreshedPayload: results,
      startOutcome: .startedPartial
    )
    let store = MatchesStore(
      ownerID: "owner-a",
      api: ScriptedRecordingRehearsalMatchesAPI(state: state)
    )

    await store.load().value
    let task = try XCTUnwrap(store.startRecordingRehearsal())
    await task.value

    let calls = await state.recordedCalls()
    XCTAssertEqual(calls, ["daily", "preview", "start", "daily"])
    XCTAssertEqual(store.rehearsalPhase, .finished(.startedPartial))
    XCTAssertEqual(store.payload, results)
  }

  @MainActor
  func testNotEligibleAndExpiredPreviewNeverStartMatching() async throws {
    let empty = try decode(responseData(matches: "", totalMatches: 0))
    for (outcome, expected) in [
      (RecordingRehearsalPreviewOutcome.notEligible, MatchesRehearsalOutcome.notEligible),
      (.expired, .expired)
    ] {
      let state = ScriptedRecordingRehearsalState(dailyPayload: empty, previewOutcome: outcome)
      let store = MatchesStore(
        ownerID: "owner-a",
        api: ScriptedRecordingRehearsalMatchesAPI(state: state)
      )
      await store.load().value
      let task = try XCTUnwrap(store.startRecordingRehearsal())
      await task.value

      let calls = await state.recordedCalls()
      XCTAssertEqual(calls, ["daily", "preview"])
      XCTAssertEqual(store.rehearsalPhase, .finished(expected))
    }
  }

  @MainActor
  func testAlreadyExistingPreviewLoadsExistingServerResultsWithoutStartingAgain() async throws {
    let empty = try decode(responseData(matches: "", totalMatches: 0))
    let results = try decode(responseData())
    let state = ScriptedRecordingRehearsalState(
      dailyPayload: empty,
      refreshedPayload: results,
      previewOutcome: .alreadyExists
    )
    let store = MatchesStore(
      ownerID: "owner-a",
      api: ScriptedRecordingRehearsalMatchesAPI(state: state)
    )

    await store.load().value
    let task = try XCTUnwrap(store.startRecordingRehearsal())
    await task.value

    let calls = await state.recordedCalls()
    XCTAssertEqual(calls, ["daily", "preview", "daily"])
    XCTAssertEqual(store.rehearsalPhase, .finished(.alreadyExists))
    XCTAssertEqual(store.payload, results)
  }

  @MainActor
  func testOwnerChangeDuringPreviewCannotStartTheNextWrite() async throws {
    let empty = try decode(responseData(matches: "", totalMatches: 0))
    let state = ScriptedRecordingRehearsalState(dailyPayload: empty, defersPreview: true)
    let store = MatchesStore(
      ownerID: "owner-a",
      api: ScriptedRecordingRehearsalMatchesAPI(state: state)
    )
    await store.load().value
    let task = try XCTUnwrap(store.startRecordingRehearsal())
    guard await state.waitForPreview() else {
      XCTFail("The rehearsal preview did not start")
      return
    }

    store.updateOwner("owner-b")
    await state.releasePreview(.eligible)
    await task.value

    let calls = await state.recordedCalls()
    XCTAssertEqual(calls, ["daily", "preview"])
    XCTAssertEqual(store.ownerID, "owner-b")
  }

  @MainActor
  func testCancelDuringPreviewCannotStartTheNextWrite() async throws {
    let empty = try decode(responseData(matches: "", totalMatches: 0))
    let state = ScriptedRecordingRehearsalState(dailyPayload: empty, defersPreview: true)
    let store = MatchesStore(
      ownerID: "owner-a",
      api: ScriptedRecordingRehearsalMatchesAPI(state: state)
    )
    await store.load().value
    let task = try XCTUnwrap(store.startRecordingRehearsal())
    guard await state.waitForPreview() else {
      XCTFail("The rehearsal preview did not start")
      return
    }

    store.cancel()
    await state.releasePreview(.eligible)
    await task.value

    let calls = await state.recordedCalls()
    XCTAssertEqual(calls, ["daily", "preview"])
    XCTAssertEqual(store.phase, .idle)
    XCTAssertEqual(store.rehearsalPhase, .cancelled)
  }

  @MainActor
  func testPreviewErrorDoesNotStartOrAutomaticallyRetry() async throws {
    let empty = try decode(responseData(matches: "", totalMatches: 0))
    let state = ScriptedRecordingRehearsalState(dailyPayload: empty, failsPreview: true)
    let store = MatchesStore(
      ownerID: "owner-a",
      api: ScriptedRecordingRehearsalMatchesAPI(state: state)
    )
    await store.load().value
    let task = try XCTUnwrap(store.startRecordingRehearsal())
    await task.value

    XCTAssertEqual(store.rehearsalPhase, .failed)
    XCTAssertNil(store.startRecordingRehearsal())
    await store.retry().value
    let calls = await state.recordedCalls()
    XCTAssertEqual(calls, ["daily", "preview", "daily"])
  }

  @MainActor
  func testStartErrorDoesNotAutomaticallyRepeatMutation() async throws {
    let empty = try decode(responseData(matches: "", totalMatches: 0))
    let state = ScriptedRecordingRehearsalState(dailyPayload: empty, failsStart: true)
    let store = MatchesStore(
      ownerID: "owner-a",
      api: ScriptedRecordingRehearsalMatchesAPI(state: state)
    )
    await store.load().value
    let task = try XCTUnwrap(store.startRecordingRehearsal())
    await task.value

    XCTAssertEqual(store.rehearsalPhase, .failed)
    XCTAssertNil(store.startRecordingRehearsal())
    await store.retry().value
    let calls = await state.recordedCalls()
    XCTAssertEqual(calls, ["daily", "preview", "start", "daily"])
  }

  @MainActor
  func testStoreRetriesAfterFailure() async throws {
    let payload = try decode(responseData())
    let api = SequencedMatchesAPI(results: [.failure(.unavailable), .success(payload)])
    let store = MatchesStore(ownerID: "owner-a", api: api)

    await store.load().value
    XCTAssertEqual(store.phase, .failed(.temporarilyUnavailable))

    await store.retry().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.payload, payload)
  }

  @MainActor
  func testStoreDropsLateResultAfterCancel() async throws {
    let api = DeferredMatchesAPI()
    let store = MatchesStore(ownerID: "owner-a", api: api)
    let loadTask = store.load()
    try await waitForPending(api)

    store.cancel()
    await api.resolve(.success(try decode(responseData())))
    await loadTask.value

    XCTAssertNil(store.payload)
    XCTAssertEqual(store.phase, .idle)
  }

  @MainActor
  func testStoreDropsLateResultAfterOwnerChange() async throws {
    let api = DeferredMatchesAPI()
    let store = MatchesStore(ownerID: "owner-a", api: api)
    let loadTask = store.load()
    try await waitForPending(api)

    store.updateOwner("owner-b")
    await api.resolve(.success(try decode(responseData())))
    await loadTask.value

    XCTAssertEqual(store.ownerID, "owner-b")
    XCTAssertNil(store.payload)
    XCTAssertEqual(store.phase, .idle)
  }

  private func decode(_ data: Data) throws -> DailyMatchesPayload {
    try APIResponseDecoder.decode(data, as: DailyMatchesPayload.self)
  }

  private func rehearsalResponse(outcome: String, count: Int) -> Data {
    Data(#"{"data":{"outcome":"\#(outcome)","count":\#(count)}}"#.utf8)
  }

  private func waitForPending(_ api: DeferredMatchesAPI) async throws {
    for _ in 0..<40 {
      if await api.isWaiting() { return }
      await Task.yield()
    }
    XCTFail("The test API did not receive the request")
    throw NSError(domain: "MatchesTests", code: 1)
  }

  private enum StubMatchesAPIError: Error, Sendable {
    case unavailable
  }

  private actor ScriptedRecordingRehearsalState {
    private let dailyPayload: DailyMatchesPayload
    private let refreshedPayload: DailyMatchesPayload
    private let previewOutcome: RecordingRehearsalPreviewOutcome
    private let startOutcome: RecordingRehearsalStartOutcome
    private let defersPreview: Bool
    private let failsPreview: Bool
    private let failsStart: Bool
    private var calls: [String] = []
    private var previewStarted = false
    private var previewContinuation: CheckedContinuation<RecordingRehearsalPreviewResult, Error>?

    init(
      dailyPayload: DailyMatchesPayload,
      refreshedPayload: DailyMatchesPayload? = nil,
      previewOutcome: RecordingRehearsalPreviewOutcome = .eligible,
      startOutcome: RecordingRehearsalStartOutcome = .started,
      defersPreview: Bool = false,
      failsPreview: Bool = false,
      failsStart: Bool = false
    ) {
      self.dailyPayload = dailyPayload
      self.refreshedPayload = refreshedPayload ?? dailyPayload
      self.previewOutcome = previewOutcome
      self.startOutcome = startOutcome
      self.defersPreview = defersPreview
      self.failsPreview = failsPreview
      self.failsStart = failsStart
    }

    func fetchDailyResults() -> DailyMatchesPayload {
      calls.append("daily")
      return calls.filter { $0 == "daily" }.count == 1 ? dailyPayload : refreshedPayload
    }

    func preview() async throws -> RecordingRehearsalPreviewResult {
      calls.append("preview")
      previewStarted = true
      if failsPreview { throw APIClientError.temporarilyUnavailable }
      if defersPreview {
        return try await withCheckedThrowingContinuation { continuation in
          previewContinuation = continuation
        }
      }
      return RecordingRehearsalPreviewResult(
        outcome: previewOutcome,
        count: previewOutcome == .eligible ? 1 : 0
      )
    }

    func start() throws -> RecordingRehearsalStartResult {
      calls.append("start")
      if failsStart { throw APIClientError.temporarilyUnavailable }
      return RecordingRehearsalStartResult(
        outcome: startOutcome,
        count: startOutcome == .started || startOutcome == .startedPartial ? 1 : 0
      )
    }

    func recordedCalls() -> [String] { calls }

    func waitForPreview() async -> Bool {
      for _ in 0..<100 {
        if previewStarted { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
      }
      return previewStarted
    }

    func releasePreview(_ outcome: RecordingRehearsalPreviewOutcome) {
      guard let previewContinuation else { return }
      self.previewContinuation = nil
      previewContinuation.resume(
        returning: RecordingRehearsalPreviewResult(
          outcome: outcome,
          count: outcome == .eligible ? 1 : 0
        )
      )
    }
  }

  private struct ScriptedRecordingRehearsalMatchesAPI: MatchesAPI, RecordingRehearsalMatchingAPI {
    let state: ScriptedRecordingRehearsalState

    var recordingRehearsalMatchingAPI: (any RecordingRehearsalMatchingAPI)? { self }

    func fetchDailyResults() async throws -> DailyMatchesPayload {
      await state.fetchDailyResults()
    }

    func previewRecordingRehearsal() async throws -> RecordingRehearsalPreviewResult {
      try await state.preview()
    }

    func startRecordingRehearsal() async throws -> RecordingRehearsalStartResult {
      try await state.start()
    }
  }

  private actor SequencedMatchesAPI: MatchesAPI {
    private var results: [Result<DailyMatchesPayload, StubMatchesAPIError>]

    init(results: [Result<DailyMatchesPayload, StubMatchesAPIError>]) {
      self.results = results
    }

    func fetchDailyResults() async throws -> DailyMatchesPayload {
      guard !results.isEmpty else { throw StubMatchesAPIError.unavailable }
      return try results.removeFirst().get()
    }
  }

  private func responseData(
    batchDate: String = "2026-09-07",
    matches: String = matchJSON(),
    totalMatches: Int = 1,
    avatarURL: String? = nil,
    conversationsCompleted: Int = 0,
    conversationsFailed: Int = 0
  ) -> Data {
    let resolvedMatch = avatarURL == nil ? matches : matchJSON(avatarURL: avatarURL)
    let body = """
    {"data":{"batch_date":"\(batchDate)","batch_status":"completed","matches":[\(avatarURL == nil ? matches : resolvedMatch)],"is_new":true,"conversations_completed":\(conversationsCompleted),"conversations_failed":\(conversationsFailed),"total_matches":\(totalMatches)}}
    """
    return Data(body.utf8)
  }

  private actor DeferredMatchesAPI: MatchesAPI {
    private var continuation: CheckedContinuation<DailyMatchesPayload, Error>?

    func fetchDailyResults() async throws -> DailyMatchesPayload {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
      }
    }

    func isWaiting() -> Bool {
      continuation != nil
    }

    func resolve(_ result: Result<DailyMatchesPayload, Error>) {
      guard let continuation else { return }
      self.continuation = nil
      continuation.resume(with: result)
    }
  }
}

private func matchJSON(
  id: String = "11111111-1111-1111-1111-111111111111",
  partnerID: String = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  avatarURL: String? = nil
) -> String {
  let avatarField = avatarURL.map { ",\"avatar_url\":\"\($0)\"" } ?? ""
  return "{\"id\":\"\(id)\",\"partner_id\":\"\(partnerID)\",\"partner\":{\"nickname\":null\(avatarField)},\"status\":\"pending\",\"fox_conversation_id\":null,\"final_score\":0.94,\"score_details\":{\"semantic\":0.94},\"location\":{\"city\":\"Tokyo\",\"country\":\"JP\"}}"
}


private actor SwitchableMatchesAuthService: AuthService {
  private var session: AuthSession?

  init(session: AuthSession?) { self.session = session }

  func setSession(_ session: AuthSession?) { self.session = session }
  func currentSession() async throws -> AuthSession? { session }
  func signUp(email: String, password: String, redirectTo: URL) async throws -> AuthSession? { session }
  func signIn(email: String, password: String) async throws -> AuthSession {
    guard let session else { throw AuthServiceError.unavailable }
    return session
  }
  func resetPasswordForEmail(email: String, redirectTo: URL) async throws {}
  func updatePassword(_ password: String) async throws {}
  func handleCallback(_ url: URL) async throws -> AuthSession {
    guard let session else { throw AuthServiceError.unavailable }
    return session
  }
  func signOut() async throws {}
}

private actor TokenMappedMatchesProfileAPI: ProfileAPI {
  let profiles: [String: String]

  init(profiles: [String: String]) { self.profiles = profiles }

  func fetchProfile(accessToken: String) async throws -> UserProfile {
    UserProfile(id: profiles[accessToken], ageVerified: true)
  }

  func verifyAge(accessToken: String, birthDate: String) async throws {}
}

private actor GatedMatchesProfileAPI: ProfileAPI {
  let profileID: String
  private var started = false
  private var released = false

  init(profileID: String) { self.profileID = profileID }

  func fetchProfile(accessToken: String) async throws -> UserProfile {
    started = true
    while !released {
      try Task.checkCancellation()
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    return UserProfile(id: profileID, ageVerified: true)
  }

  func verifyAge(accessToken: String, birthDate: String) async throws {}

  func waitUntilStarted() async -> Bool {
    for _ in 0..<100 {
      if started { return true }
      do {
        try await Task.sleep(nanoseconds: 10_000_000)
      } catch {
        return false
      }
    }
    return started
  }

  func release() { released = true }
}

private actor CountingMatchesProfileAPI: ProfileAPI {
  let profileID: String
  private var fetchCalls = 0

  init(profileID: String) { self.profileID = profileID }

  func fetchProfile(accessToken: String) async throws -> UserProfile {
    fetchCalls += 1
    return UserProfile(id: profileID, ageVerified: true)
  }

  func fetchProfileCallCount() -> Int { fetchCalls }
  func verifyAge(accessToken: String, birthDate: String) async throws {}
}

private actor CapturingMatchesTransport: APIHTTPTransport {
  private let responseData: Data
  private(set) var requests: [URLRequest] = []

  init(responseData: Data) { self.responseData = responseData }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: nil, headerFields: nil
      )
    else {
      throw APIClientError.invalidResponse
    }
    return (responseData, response)
  }

  func requestsSnapshot() -> [URLRequest] { requests }
}

private actor JudgeMatchesTestAPI: MatchesAPI, DemoJudgeMatchingAPI {
  nonisolated var demoJudgeMatchingAPI: (any DemoJudgeMatchingAPI)? { self }
  let previewCount: Int
  let failsStart: Bool
  private var previewCalls = 0
  private var startCalls = 0
  private var resultsCalls = 0
  private var dailyCalls = 0

  init(previewCount: Int, failsStart: Bool = false) {
    self.previewCount = previewCount
    self.failsStart = failsStart
  }
  func fetchDailyResults() throws -> DailyMatchesPayload {
    dailyCalls += 1
    throw APIClientError.invalidState
  }
  func fetchDiscoveryResults() -> DiscoveryMatchesPayload {
    resultsCalls += 1
    return DiscoveryMatchesPayload(source: "ordinary-discovery", matches: [], totalMatches: 0)
  }
  func previewDemoJudgeMatching() -> DemoJudgePreviewResult {
    previewCalls += 1
    return DemoJudgePreviewResult(source: "ordinary-discovery", outcome: "eligible", count: previewCount)
  }
  func startDemoJudgeMatching() throws -> DemoJudgeStartResult {
    startCalls += 1
    if failsStart { throw APIClientError.temporarilyUnavailable }
    return DemoJudgeStartResult(source: "ordinary-discovery", outcome: .started, count: previewCount)
  }
  func counts() -> (preview: Int, start: Int, results: Int, daily: Int) {
    (previewCalls, startCalls, resultsCalls, dailyCalls)
  }
}
