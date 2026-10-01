import Foundation
import XCTest
@testable import Wingward

@MainActor
final class MatchDetailTests: XCTestCase {
  private let baseURL = URL(string: "https://api.example.test")!
  private let matchID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let partnerID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
  private let conversationID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
  private let partnerChatID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
  private let ownerUUID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

  func testDetailDTOUsesPublicFoxSummaryAndIgnoresScoresAndPrivateFields() throws {
    let data = envelope("""
    {
      "id":"11111111-1111-4111-8111-111111111111",
      "partner_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      "partner":{"nickname":null,"avatar_url":"https://example.test/avatar"},
      "status":"pending",
      "fox_conversation_id":null,
      "final_score":0.99,
      "profile_score":0.98,
      "conversation_score":0.97,
      "score_details":{"semantic":0.99},
      "layer_scores":{"profile":0.98},
      "fox_summary":"public summary",
      "location":{"city":"Tokyo"},
      "partner_fox_chat_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      "chat_request_status":"accepted",
      "direct_chat_room_id":"private-room-id"
    }
    """)

    let detail = try APIResponseDecoder.decode(data, as: ProductionMatchDetail.self)
    XCTAssertEqual(detail.id, matchID)
    XCTAssertEqual(detail.partnerID, partnerID)
    XCTAssertEqual(detail.partner.displayName, "Wingward member")
    XCTAssertEqual(detail.status, "pending")
    XCTAssertNil(detail.foxConversationID)
    XCTAssertEqual(detail.partnerFoxChatID, partnerChatID)
    XCTAssertEqual(detail.foxSummary, "public summary")
  }

  func testDetailDTORejectsOverlongPublicFoxSummary() {
    let detail = ProductionMatchDetail(
      id: matchID,
      partnerID: partnerID,
      partner: MatchDetailPartner(nickname: "Aoi"),
      status: "pending",
      foxConversationID: nil,
      foxSummary: String(repeating: "x", count: 2_001)
    )

    XCTAssertThrowsError(try ProductionMatchDetail.validate(detail))
  }

  func testMalformedSpeakerAndDuplicateMessageIDsFailClosed() {
    assertInvalidResponse(
      envelope("""
      [{"id":"44444444-4444-4444-8444-444444444444","speaker":"unknown","content":"hello","round_number":1,"created_at":"2026-01-01T00:00:00Z"}]
      """),
      as: FoxConversationMessagesPayload.self
    )

    assertInvalidResponse(
      envelope("""
      [
        {"id":"44444444-4444-4444-8444-444444444444","speaker":"my_fox","content":"one","round_number":1,"created_at":"2026-01-01T00:00:00Z"},
        {"id":"44444444-4444-4444-8444-444444444444","speaker":"partner_fox","content":"two","round_number":2,"created_at":"2026-01-01T00:01:00Z"}
      ]
      """),
      as: FoxConversationMessagesPayload.self
    )
  }

  func testLiveAPIUsesClosedRoutesAndBoundedMessageLimit() async throws {
    let client = FakeAuthenticatedAPIClient()
    let matchRequest = APIRequest(method: .get, path: LiveMatchDetailAPI.matchPath(for: matchID))
    let conversationRequest = APIRequest(method: .get, path: LiveMatchDetailAPI.conversationPath(for: conversationID))
    let messagesRequest = APIRequest(
      method: .get,
      path: LiveMatchDetailAPI.messagesPath(for: conversationID, limit: 100)
    )
    await client.setResponseData(matchResponse(), for: matchRequest)
    await client.setResponseData(conversationResponse(), for: conversationRequest)
    await client.setResponseData(messagesResponse(), for: messagesRequest)

    let api = LiveMatchDetailAPI(client: client)
    _ = try await api.fetchMatch(id: matchID)
    _ = try await api.fetchConversation(id: conversationID)
    let messages = try await api.fetchMessages(conversationID: conversationID, limit: 500)

    XCTAssertEqual(messages.messages.count, 1)
    let requests = await client.recordedRequests()
    XCTAssertEqual(requests.map(\.path), [
      LiveMatchDetailAPI.matchPath(for: matchID),
      LiveMatchDetailAPI.conversationPath(for: conversationID),
      LiveMatchDetailAPI.messagesPath(for: conversationID, limit: 100)
    ])
  }

  func testLiveAPIInjectedTransportDecodesRawMessagesEnvelopeAndPinsLimit() async throws {
    let auth = DetailAuthService(session: AuthSession(accessToken: "token-a"))
    let profile = DetailProfileAPI(profiles: ["token-a": "owner-a"])
    let path = LiveMatchDetailAPI.messagesPath(for: conversationID, limit: 100)
    let endpoint = "https://api.example.test\(path)"
    let transport = RoutingDetailTransport(responses: [endpoint: pagedMessagesResponse()])
    let api = try LiveMatchDetailAPI(
      baseURL: baseURL,
      ownerID: "owner-a",
      authService: auth,
      profileAPI: profile,
      transport: transport
    )

    let payload = try await api.fetchMessages(conversationID: conversationID, limit: 500)

    XCTAssertEqual(payload.messages.count, 1)
    let requests = await transport.requestsSnapshot()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.url?.path, "/api/fox-conversations/\(conversationID.uuidString.lowercased())/messages")
    XCTAssertEqual(requests.first?.url?.query, "limit=100")
  }

  func testLiveAPIStartsConversationWithBodylessRouteAndValidatesReturnedMatchID() async throws {
    let client = FakeAuthenticatedAPIClient()
    let request = APIRequest(
      method: .post,
      path: LiveMatchDetailAPI.startConversationPath(for: matchID)
    )
    await client.setResponseData(startConversationResponse(), for: request)

    let api = LiveMatchDetailAPI(client: client)
    let result = try await api.startConversation(matchID: matchID)

    XCTAssertEqual(result.matchID, matchID)
    XCTAssertEqual(result.conversationID, conversationID)
    let requests = await client.recordedRequests()
    XCTAssertEqual(requests, [request])
    XCTAssertNil(requests.first?.body)

    let wrongMatchID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    await client.setResponseData(startConversationResponse(matchID: wrongMatchID), for: request)
    do {
      _ = try await api.startConversation(matchID: matchID)
      XCTFail("A start response for another match must fail closed")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidResponse)
    }
  }

  func testLiveFactoryBindsVerifiedOwnerAndInjectsTransport() async throws {
    let auth = DetailAuthService(session: AuthSession(accessToken: "token-a"))
    let profile = DetailProfileAPI(profiles: ["token-a": "owner-a"])
    let transport = CapturingDetailTransport(responseData: matchResponse())
    let factory = LiveMatchDetailAPIFactory(
      baseURL: baseURL,
      authService: auth,
      profileAPI: profile,
      transport: transport
    )
    let api = try XCTUnwrap(factory.make(ownerID: "owner-a"))

    let detail = try await api.fetchMatch(id: matchID)

    XCTAssertEqual(detail.id, matchID)
    let requests = await transport.requestsSnapshot()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token-a")
    let profileCalls = await profile.fetchCallCount()
    XCTAssertEqual(profileCalls, 1)
  }

  func testLiveFactoryOwnerMismatchStopsBeforeTransport() async throws {
    let auth = DetailAuthService(session: AuthSession(accessToken: "token-b"))
    let profile = DetailProfileAPI(profiles: ["token-b": "owner-b"])
    let transport = CapturingDetailTransport(responseData: matchResponse())
    let factory = LiveMatchDetailAPIFactory(
      baseURL: baseURL,
      authService: auth,
      profileAPI: profile,
      transport: transport
    )
    let api = try XCTUnwrap(factory.make(ownerID: "owner-a"))

    do {
      _ = try await api.fetchMatch(id: matchID)
      XCTFail("An API created for the old owner must reject the new session")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .unauthenticated)
    }
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testLiveFactoryRejectsRecoveryPurposeBeforeProfileAndTransport() async throws {
    let auth = DetailAuthService(
      session: AuthSession(accessToken: "recovery-token", purpose: .passwordRecovery)
    )
    let profile = DetailProfileAPI(profiles: ["recovery-token": "owner-a"])
    let transport = CapturingDetailTransport(responseData: matchResponse())
    let factory = LiveMatchDetailAPIFactory(
      baseURL: baseURL,
      authService: auth,
      profileAPI: profile,
      transport: transport
    )
    let api = try XCTUnwrap(factory.make(ownerID: "owner-a"))

    do {
      _ = try await api.fetchMatch(id: matchID)
      XCTFail("Recovery sessions must not reach production match detail")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .unauthenticated)
    }
    let profileCalls = await profile.fetchCallCount()
    let requestCount = await transport.requestCount()
    XCTAssertEqual(profileCalls, 0)
    XCTAssertEqual(requestCount, 0)
  }

  func testStoreLoadsDetailAndHistoryOnlyAfterAllIDsMatch() async {
    let api = ScenarioDetailAPI(
      detail: fixtureDetail(conversationID: conversationID),
      conversation: fixtureConversation(id: conversationID, matchID: matchID),
      messages: [fixtureMessage()]
    )
    let store = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: api)

    await store.load().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.detail?.id, matchID)
    XCTAssertEqual(store.conversation?.id, conversationID)
    XCTAssertEqual(store.messages.count, 1)
  }

  func testStoreAllowsLoadedDetailWithoutConversationAndShowsEmptyHistoryState() async {
    let api = ScenarioDetailAPI(
      detail: fixtureDetail(conversationID: nil),
      conversation: nil,
      messages: []
    )
    let store = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: api)

    await store.load().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertNotNil(store.detail)
    XCTAssertNil(store.conversation)
    XCTAssertTrue(store.messages.isEmpty)
  }

  func testStoreDoesNotStartOnLoadAndReloadsHistoryOnlyAfterExplicitStart() async {
    let api = StartConversationDetailAPI(
      initialDetail: fixtureDetail(conversationID: nil),
      startedDetail: fixtureDetail(conversationID: conversationID)
    )
    let store = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: api)

    await store.load().value

    XCTAssertTrue(store.canStartConversation)
    let startCallsBeforeAction = await api.startCallCount()
    XCTAssertEqual(startCallsBeforeAction, 0)

    await store.startConversation().value

    let startCallsAfterAction = await api.startCallCount()
    XCTAssertEqual(startCallsAfterAction, 1)
    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.detail?.foxConversationID, conversationID)
    XCTAssertEqual(store.conversation?.id, conversationID)
    XCTAssertEqual(store.messages.count, 1)
    XCTAssertFalse(store.canStartConversation)
  }

  func testStoreRejectsStartResultForAnotherMatchWithoutRefreshing() async {
    let wrongMatchID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let api = StartConversationDetailAPI(
      initialDetail: fixtureDetail(conversationID: nil),
      startedDetail: fixtureDetail(conversationID: conversationID),
      startResult: FoxConversationStartResult(
        conversationID: conversationID,
        matchID: wrongMatchID
      )
    )
    let store = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: api)

    await store.load().value
    await store.startConversation().value

    XCTAssertEqual(store.startError, .invalidResponse)
    XCTAssertEqual(store.phase, .loaded)
    XCTAssertNil(store.detail?.foxConversationID)
    let fetchMatchCalls = await api.fetchMatchCallCount()
    XCTAssertEqual(fetchMatchCalls, 1)
  }

  func testStoreCancelsLateStartAndPreventsDoubleSubmission() async {
    let api = StartConversationDetailAPI(
      initialDetail: fixtureDetail(conversationID: nil),
      startedDetail: fixtureDetail(conversationID: conversationID),
      startDelayNanoseconds: 50_000_000
    )
    let store = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: api)
    await store.load().value

    let firstTask = store.startConversation()
    let startObserved = await api.waitForStart()
    XCTAssertTrue(startObserved)
    let duplicateTask = store.startConversation()
    store.cancel()

    await duplicateTask.value
    await firstTask.value

    let startCalls = await api.startCallCount()
    XCTAssertEqual(startCalls, 1)
    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.detail)
    XCTAssertNil(store.startError)
    XCTAssertFalse(store.isStartingConversation)
  }

  func testStoreMapsQuotaFailureToSafeStartState() async {
    let api = StartConversationDetailAPI(
      initialDetail: fixtureDetail(conversationID: nil),
      startedDetail: fixtureDetail(conversationID: conversationID),
      startError: .quotaExhausted(source: nil)
    )
    let store = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: api)

    await store.load().value
    await store.startConversation().value

    XCTAssertEqual(store.startError, .quotaExhausted)
    XCTAssertEqual(store.startError?.startUserMessage, "Your Ward conversation limit has been reached.")
    XCTAssertEqual(store.phase, .loaded)
    XCTAssertFalse(store.isStartingConversation)
  }

  func testStoreRefreshDuringStartCancelsOperationAndClearsSpinner() async {
    let api = StartConversationDetailAPI(
      initialDetail: fixtureDetail(conversationID: nil),
      startedDetail: fixtureDetail(conversationID: conversationID),
      deferStart: true
    )
    let store = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: api)
    await store.load().value

    let startTask = store.startConversation()
    let startObserved = await api.waitForStart()
    XCTAssertTrue(startObserved)

    let refreshTask = store.retry()
    await refreshTask.value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertNil(store.detail?.foxConversationID)
    XCTAssertTrue(store.canStartConversation)
    XCTAssertFalse(store.isStartingConversation)
    XCTAssertNil(store.startError)

    await api.releaseStart()
    await startTask.value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertNil(store.detail?.foxConversationID)
    XCTAssertTrue(store.canStartConversation)
    XCTAssertFalse(store.isStartingConversation)
  }

  func testStoreDoesNotOfferStartForNonPendingStatus() async {
    let detail = ProductionMatchDetail(
      id: matchID,
      partnerID: partnerID,
      partner: MatchDetailPartner(nickname: "Aoi"),
      status: "fox_conversation_in_progress",
      foxConversationID: nil
    )
    let api = StartConversationDetailAPI(
      initialDetail: detail,
      startedDetail: detail
    )
    let store = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: api)

    await store.load().value
    await store.startConversation().value

    XCTAssertFalse(store.canStartConversation)
    let startCalls = await api.startCallCount()
    XCTAssertEqual(startCalls, 0)
  }

  func testStoreClearsProtectedContentWhenRefreshFails() async {
    let api = ScenarioDetailAPI(
      detail: fixtureDetail(conversationID: conversationID),
      conversation: fixtureConversation(id: conversationID, matchID: matchID),
      messages: [fixtureMessage()]
    )
    let store = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: api)
    await store.load().value
    await api.setMatchError(.temporarilyUnavailable)

    await store.retry().value

    XCTAssertEqual(store.phase, .failed(.temporarilyUnavailable))
    XCTAssertNil(store.detail)
    XCTAssertNil(store.conversation)
    XCTAssertTrue(store.messages.isEmpty)
  }

  func testStorePollsPendingAndLiveUntilTerminalThenStops() async {
    let api = PollingDetailAPI(
      details: [
        fixtureDetail(conversationID: conversationID, status: "pending"),
        fixtureDetail(conversationID: conversationID, status: "fox_conversation_in_progress"),
        fixtureDetail(conversationID: conversationID, status: "fox_conversation_completed")
      ],
      conversation: fixtureConversation(id: conversationID, matchID: matchID),
      messages: [fixtureMessage()]
    )
    let store = MatchDetailStore(
      ownerID: "owner-a",
      matchID: matchID,
      api: api,
      sleeper: { _ in await Task.yield() }
    )

    await store.load().value

    let matchCalls = await api.matchCallCount()
    let conversationCalls = await api.conversationCallCount()
    let messageCalls = await api.messageCallCount()
    XCTAssertEqual(matchCalls, 3)
    XCTAssertEqual(conversationCalls, 3)
    XCTAssertEqual(messageCalls, 3)
    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.detail?.status, "fox_conversation_completed")
  }

  func testStoreStopsAfterBoundedPollingAttempts() async {
    let api = PollingDetailAPI(
      details: [fixtureDetail(conversationID: conversationID, status: "fox_conversation_in_progress")],
      conversation: fixtureConversation(id: conversationID, matchID: matchID),
      messages: [fixtureMessage()]
    )
    let store = MatchDetailStore(
      ownerID: "owner-a",
      matchID: matchID,
      api: api,
      sleeper: { _ in await Task.yield() }
    )

    await store.load().value

    let matchCalls = await api.matchCallCount()
    XCTAssertEqual(matchCalls, 21, "one initial fetch plus the twenty-attempt bound")
    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.detail?.status, "fox_conversation_in_progress")
  }

  func testStoreShowsConstantRetryMessageAndStopsAfterPollingFailure() async {
    let api = PollingDetailAPI(
      details: [fixtureDetail(conversationID: conversationID, status: "fox_conversation_in_progress")],
      conversation: fixtureConversation(id: conversationID, matchID: matchID),
      messages: [fixtureMessage()],
      errorOnMatchCall: 2
    )
    let store = MatchDetailStore(
      ownerID: "owner-a",
      matchID: matchID,
      api: api,
      sleeper: { _ in await Task.yield() }
    )

    await store.load().value

    XCTAssertEqual(store.phase, .failed(.temporarilyUnavailable))
    XCTAssertEqual(
      MatchDetailStoreError.temporarilyUnavailable.userMessage,
      "We couldn't load this match. Try again."
    )
    XCTAssertNil(store.detail)
    XCTAssertTrue(store.messages.isEmpty)
    let matchCalls = await api.matchCallCount()
    XCTAssertEqual(matchCalls, 2)
  }

  func testStoreStopsPollingWhenCancelledAndOwnerChanges() async {
    let api = PollingDetailAPI(
      details: [fixtureDetail(conversationID: conversationID, status: "fox_conversation_in_progress")],
      conversation: fixtureConversation(id: conversationID, matchID: matchID),
      messages: [fixtureMessage()]
    )
    let sleeper = PollingSleepProbe()
    let store = MatchDetailStore(
      ownerID: "owner-a",
      matchID: matchID,
      api: api,
      sleeper: { _ in
        await sleeper.markBlocked()
        try? await Task.sleep(nanoseconds: 60_000_000_000)
      }
    )

    let task = store.load()
    let sleeperBlocked = await sleeper.waitUntilBlocked()
    XCTAssertTrue(sleeperBlocked)
    store.updateOwner("owner-b")
    await task.value

    XCTAssertEqual(store.ownerID, "owner-b")
    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.detail)
    let matchCalls = await api.matchCallCount()
    XCTAssertEqual(matchCalls, 1)
  }

  func testStoreRejectsWrongDetailAndConversationIDs() async {
    let wrongDetail = ProductionMatchDetail(
      id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
      partnerID: partnerID,
      partner: MatchDetailPartner(nickname: "Aoi"),
      status: "pending",
      foxConversationID: conversationID
    )
    let detailAPI = ScenarioDetailAPI(
      detail: wrongDetail,
      conversation: fixtureConversation(id: conversationID, matchID: matchID),
      messages: [fixtureMessage()]
    )
    let detailStore = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: detailAPI)
    await detailStore.load().value
    XCTAssertEqual(detailStore.phase, .failed(.invalidResponse))
    XCTAssertNil(detailStore.detail)

    let mismatchAPI = ScenarioDetailAPI(
      detail: fixtureDetail(conversationID: conversationID),
      conversation: fixtureConversation(id: conversationID, matchID: UUID()),
      messages: [fixtureMessage()]
    )
    let mismatchStore = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: mismatchAPI)
    await mismatchStore.load().value
    XCTAssertEqual(mismatchStore.phase, .failed(.invalidResponse))
    XCTAssertTrue(mismatchStore.messages.isEmpty)

    let wrongSummaryID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    let wrongSummaryAPI = ScenarioDetailAPI(
      detail: fixtureDetail(conversationID: conversationID),
      conversation: fixtureConversation(id: wrongSummaryID, matchID: matchID),
      messages: [fixtureMessage()]
    )
    let wrongSummaryStore = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: wrongSummaryAPI)
    await wrongSummaryStore.load().value
    XCTAssertEqual(wrongSummaryStore.phase, .failed(.invalidResponse))
    XCTAssertNil(wrongSummaryStore.detail)
    XCTAssertNil(wrongSummaryStore.conversation)
    XCTAssertTrue(wrongSummaryStore.messages.isEmpty)
  }

  func testStoreDropsLateConversationFromPriorGeneration() async {
    let oldConversationID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    let newConversationID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    let api = SequencedDetailAPI(
      firstDetail: fixtureDetail(conversationID: oldConversationID),
      secondDetail: fixtureDetail(conversationID: newConversationID),
      firstConversation: fixtureConversation(id: oldConversationID, matchID: matchID),
      secondConversation: fixtureConversation(id: newConversationID, matchID: matchID)
    )
    let store = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: api)
    let oldTask = store.load()
    let firstConversationStarted = await api.waitForFirstConversationStart()
    XCTAssertTrue(firstConversationStarted)
    let newTask = store.load()

    await oldTask.value
    await newTask.value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.detail?.foxConversationID, newConversationID)
    XCTAssertEqual(store.conversation?.id, newConversationID)
  }

  func testStoreReleasesLateOldHistoryAfterRefreshedConversationID() async {
    let oldConversationID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    let newConversationID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    let oldMessage = fixtureMessage(
      id: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
      content: "old history"
    )
    let newMessage = fixtureMessage(
      id: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
      content: "new history"
    )
    let api = ControlledHistoryAPI(
      firstDetail: fixtureDetail(conversationID: oldConversationID),
      refreshedDetail: fixtureDetail(conversationID: newConversationID),
      oldConversation: fixtureConversation(id: oldConversationID, matchID: matchID),
      refreshedConversation: fixtureConversation(id: newConversationID, matchID: matchID),
      oldMessages: [oldMessage],
      refreshedMessages: [newMessage]
    )
    let store = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: api)
    let oldTask = store.load()

    let oldHistoryStarted = await api.waitForOldHistoryStart()
    XCTAssertTrue(oldHistoryStarted)
    guard oldHistoryStarted else {
      oldTask.cancel()
      await api.releaseOldHistory()
      return
    }

    await api.useRefreshedDetail()
    let refreshedTask = store.load()
    let refreshedCompleted = await waitForRefreshedContent(
      store,
      conversationID: newConversationID,
      messageID: newMessage.id
    )
    XCTAssertTrue(refreshedCompleted)
    guard refreshedCompleted else {
      refreshedTask.cancel()
      await api.releaseOldHistory()
      oldTask.cancel()
      return
    }
    XCTAssertEqual(store.conversation?.id, newConversationID)
    XCTAssertEqual(store.messages.map(\.id), [newMessage.id])
    let oldHistoryWasReleased = await api.oldHistoryWasReleased()
    XCTAssertFalse(oldHistoryWasReleased)

    await api.releaseOldHistory()
    await oldTask.value

    XCTAssertEqual(store.conversation?.id, newConversationID)
    XCTAssertEqual(store.messages.map(\.id), [newMessage.id])
    let requestIDs = await api.messageRequestIDs()
    XCTAssertEqual(requestIDs, [oldConversationID, newConversationID])
  }

  private func waitForRefreshedContent(
    _ store: MatchDetailStore,
    conversationID: UUID,
    messageID: UUID
  ) async -> Bool {
    for _ in 0..<500 {
      if store.phase == .loaded,
        store.conversation?.id == conversationID,
        store.messages.map(\.id) == [messageID]
      {
        return true
      }
      do {
        try await Task.sleep(nanoseconds: 1_000_000)
      } catch {
        return false
      }
    }
    return store.phase == .loaded
      && store.conversation?.id == conversationID
      && store.messages.map(\.id) == [messageID]
  }

  func testStoreDropsLateCancelledResultAndOwnerChange() async {
    let api = DelayedDetailAPI(detail: fixtureDetail(conversationID: nil))
    let store = MatchDetailStore(ownerID: "owner-a", matchID: matchID, api: api)
    let firstTask = store.load()
    store.cancel()
    await firstTask.value
    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.detail)

    let secondTask = store.load()
    store.updateOwner("owner-b")
    await secondTask.value
    XCTAssertEqual(store.ownerID, "owner-b")
    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.detail)
  }

  func testPartnerWardDTOsDecodeClosedDetailAndCompleteHistory() throws {
    let detail = try APIResponseDecoder.decode(
      partnerChatResponse(),
      as: PartnerFoxChatDetail.self
    )
    XCTAssertEqual(detail.id, partnerChatID)
    XCTAssertEqual(detail.matchID, matchID)
    XCTAssertEqual(detail.userID, ownerUUID)
    XCTAssertEqual(detail.partnerUserID, partnerID)
    XCTAssertEqual(detail.partner.displayName, "Aoi")

    let history = try APIResponseDecoder.decode(
      partnerMessagesResponse(),
      as: PartnerFoxMessagesPayload.self
    )
    XCTAssertEqual(history.messages.map(\.role), [.fox, .user])
    XCTAssertEqual(history.messages.map(\.content), ["hello", "Thanks for listening."])
    XCTAssertNil(history.nextCursor)
    XCTAssertFalse(history.hasMore)
  }

  func testPartnerWardHistoryRejectsOpenOrMalformedEnvelopeAndRows() {
    assertInvalidResponse(
      Data(#"{"data":[{"id":"44444444-4444-4444-8444-444444444444","role":"fox","content":"hello","created_at":"2026-01-01T00:00:00Z"}],"next_cursor":"cursor","has_more":true}"#.utf8),
      as: PartnerFoxMessagesPayload.self
    )
    assertInvalidResponse(
      Data(#"{"data":[{"id":"44444444-4444-4444-8444-444444444444","role":"other","content":"hello","created_at":"2026-01-01T00:00:00Z"}],"next_cursor":null,"has_more":false}"#.utf8),
      as: PartnerFoxMessagesPayload.self
    )
    assertInvalidResponse(
      Data(#"{"data":[{"id":"44444444-4444-4444-8444-444444444444","role":"fox","content":"hello","created_at":"2026-01-01T00:01:00Z"},{"id":"44444444-4444-4444-8444-444444444444","role":"user","content":"again","created_at":"2026-01-01T00:02:00Z"}],"next_cursor":null,"has_more":false}"#.utf8),
      as: PartnerFoxMessagesPayload.self
    )
    assertInvalidResponse(
      Data(#"{"data":[{"id":"44444444-4444-4444-8444-444444444444","role":"fox","content":"hello","created_at":"2026-01-01T00:02:00Z"},{"id":"55555555-5555-4555-8555-555555555555","role":"user","content":"earlier","created_at":"2026-01-01T00:01:00Z"}],"next_cursor":null,"has_more":false}"#.utf8),
      as: PartnerFoxMessagesPayload.self
    )
  }

  func testPartnerWardHistoryRequiresBothClosedPaginationFields() {
    let row = #"{"id":"44444444-4444-4444-8444-444444444444","role":"fox","content":"hello","created_at":"2026-01-01T00:00:00Z"}"#
    let responses = [
      #"{"data":[\#(row)],"has_more":false}"#,
      #"{"data":[\#(row)],"next_cursor":null}"#,
      #"{"data":[\#(row)],"next_cursor":null,"has_more":null}"#
    ]

    for response in responses {
      assertInvalidResponse(Data(response.utf8), as: PartnerFoxMessagesPayload.self)
    }
  }

  func testPartnerWardRowsEnforceContentBoundsAndStrictIdentifiersAndDates() throws {
    assertInvalidResponse(
      partnerSingleMessageResponse(content: ""),
      as: PartnerFoxMessagesPayload.self
    )
    assertInvalidResponse(
      partnerSingleMessageResponse(content: String(repeating: " ", count: 3)),
      as: PartnerFoxMessagesPayload.self
    )
    assertInvalidResponse(
      partnerSingleMessageResponse(content: String(repeating: "x", count: 2_001)),
      as: PartnerFoxMessagesPayload.self
    )
    assertInvalidResponse(
      partnerSingleMessageResponse(createdAt: "not-a-timestamp"),
      as: PartnerFoxMessagesPayload.self
    )

    let oneCharacter = try APIResponseDecoder.decode(
      partnerSingleMessageResponse(content: "x"),
      as: PartnerFoxMessagesPayload.self
    )
    XCTAssertEqual(oneCharacter.messages.first?.content.count, 1)

    let twoThousandCharacters = try APIResponseDecoder.decode(
      partnerSingleMessageResponse(content: String(repeating: "x", count: 2_000)),
      as: PartnerFoxMessagesPayload.self
    )
    XCTAssertEqual(twoThousandCharacters.messages.first?.content.count, 2_000)

    assertInvalidResponse(
      Data(#"{"data":{"id":"not-a-uuid","match_id":"11111111-1111-4111-8111-111111111111","user_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","partner_user_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","created_at":"2026-01-01T00:00:00Z","partner":{"nickname":"Aoi"}}}"#.utf8),
      as: PartnerFoxChatDetail.self
    )
  }

  func testLiveAPIReadsPartnerWardDetailAndCompleteHistoryWithoutWrites() async throws {
    let client = FakeAuthenticatedAPIClient()
    let detailRequest = APIRequest(
      method: .get,
      path: LiveMatchDetailAPI.partnerChatPath(for: partnerChatID)
    )
    let historyRequest = APIRequest(
      method: .get,
      path: LiveMatchDetailAPI.partnerMessagesPath(for: partnerChatID)
    )
    await client.setResponseData(partnerChatResponse(), for: detailRequest)
    await client.setResponseData(partnerMessagesResponse(), for: historyRequest)

    let api = LiveMatchDetailAPI(client: client)
    let detail = try await api.fetchPartnerChat(id: partnerChatID)
    let history = try await api.fetchPartnerMessages(chatID: partnerChatID)

    XCTAssertEqual(detail.id, partnerChatID)
    XCTAssertEqual(history.messages.count, 2)
    let requests = await client.recordedRequests()
    XCTAssertEqual(requests.map(\.method), [.get, .get])
    XCTAssertEqual(requests.map(\.path), [
      LiveMatchDetailAPI.partnerChatPath(for: partnerChatID),
      LiveMatchDetailAPI.partnerMessagesPath(for: partnerChatID)
    ])
    XCTAssertTrue(requests.allSatisfy { $0.body == nil })
  }

  func testPartnerWardStoreBindsOwnerMatchPartnerAndChatBeforeHistory() async {
    let api = PartnerWardDetailAPI(
      chat: fixturePartnerChat(),
      messages: fixturePartnerMessages()
    )
    let store = PartnerWardStore(
      ownerID: ownerUUID.uuidString,
      matchID: matchID,
      partnerID: partnerID,
      chatID: partnerChatID,
      api: api
    )

    await store.load().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.chat?.id, partnerChatID)
    XCTAssertEqual(store.messages.map(\.role), [.fox, .user])
    let detailCalls = await api.detailCallCount()
    let messageCalls = await api.messageCallCount()
    XCTAssertEqual(detailCalls, 1)
    XCTAssertEqual(messageCalls, 1)
  }

  func testPartnerWardStoreRejectsMismatchedDetailAndNeverPublishesHistory() async {
    let mismatches: [PartnerFoxChatDetail] = [
      PartnerFoxChatDetail(
        id: UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!,
        matchID: matchID,
        userID: ownerUUID,
        partnerUserID: partnerID,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        partner: MatchDetailPartner(nickname: "Aoi")
      ),
      PartnerFoxChatDetail(
        id: partnerChatID,
        matchID: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!,
        userID: ownerUUID,
        partnerUserID: partnerID,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        partner: MatchDetailPartner(nickname: "Aoi")
      ),
      PartnerFoxChatDetail(
        id: partnerChatID,
        matchID: matchID,
        userID: UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!,
        partnerUserID: partnerID,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        partner: MatchDetailPartner(nickname: "Aoi")
      ),
      PartnerFoxChatDetail(
        id: partnerChatID,
        matchID: matchID,
        userID: ownerUUID,
        partnerUserID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        partner: MatchDetailPartner(nickname: "Aoi")
      )
    ]

    for mismatch in mismatches {
      let api = PartnerWardDetailAPI(chat: mismatch, messages: fixturePartnerMessages())
      let store = PartnerWardStore(
        ownerID: ownerUUID.uuidString,
        matchID: matchID,
        partnerID: partnerID,
        chatID: partnerChatID,
        api: api
      )

      await store.load().value

      XCTAssertEqual(store.phase, .failed(.invalidResponse))
      XCTAssertNil(store.chat)
      XCTAssertTrue(store.messages.isEmpty)
      let messageCalls = await api.messageCallCount()
      XCTAssertEqual(messageCalls, 0)
    }
  }

  func testPartnerWardStoreClearsHistoryWhenCancelledOrOwnerChanges() async {
    let api = PartnerWardDetailAPI(
      chat: fixturePartnerChat(),
      messages: fixturePartnerMessages(),
      delayNanoseconds: 50_000_000
    )
    let store = PartnerWardStore(
      ownerID: ownerUUID.uuidString,
      matchID: matchID,
      partnerID: partnerID,
      chatID: partnerChatID,
      api: api
    )

    let task = store.load()
    store.cancel()
    await task.value
    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.chat)
    XCTAssertTrue(store.messages.isEmpty)

    let secondTask = store.load()
    store.updateOwner("99999999-9999-4999-8999-999999999999")
    await secondTask.value
    XCTAssertEqual(store.ownerID, "99999999-9999-4999-8999-999999999999")
    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.chat)
    XCTAssertTrue(store.messages.isEmpty)
  }

  private func assertInvalidResponse<Value: APIValidatable>(_ data: Data, as type: Value.Type) {
    do {
      _ = try APIResponseDecoder.decode(data, as: type)
      XCTFail("Malformed response must fail closed")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidResponse)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func envelope(_ data: String) -> Data {
    Data(("{\"data\":" + data + "}").utf8)
  }

  private func matchResponse() -> Data {
    envelope("""
    {
      "id":"11111111-1111-4111-8111-111111111111",
      "partner_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      "partner":{"nickname":"Aoi"},
      "status":"pending",
      "fox_conversation_id":null
    }
    """)
  }

  private func conversationResponse() -> Data {
    envelope("""
    {
      "id":"33333333-3333-4333-8333-333333333333",
      "match_id":"11111111-1111-4111-8111-111111111111",
      "status":"completed",
      "total_rounds":2,
      "current_round":2,
      "started_at":"2026-01-01T00:00:00Z",
      "completed_at":"2026-01-01T00:02:00Z",
      "conversation_analysis":{"private":"omitted"},
      "input_tokens":100
    }
    """)
  }

  private func messagesResponse() -> Data {
    envelope("""
    [{"id":"44444444-4444-4444-8444-444444444444","speaker":"my_fox","content":"hello","round_number":1,"created_at":"2026-01-01T00:00:00Z"}]
    """)
  }

  private func startConversationResponse(
    matchID: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
    conversationID: UUID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
  ) -> Data {
    envelope("""
    {
      "fox_conversation_id":"\(conversationID.uuidString.lowercased())",
      "match_id":"\(matchID.uuidString.lowercased())"
    }
    """)
  }

  private func partnerChatResponse() -> Data {
    envelope("""
    {
      "id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      "match_id":"11111111-1111-4111-8111-111111111111",
      "user_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      "partner_user_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      "created_at":"2026-01-01T00:00:00Z",
      "partner":{"nickname":"Aoi"},
      "private_field":"ignored"
    }
    """)
  }

  private func partnerMessagesResponse() -> Data {
    Data(#"{"data":[{"id":"44444444-4444-4444-8444-444444444444","role":"fox","content":"hello","created_at":"2026-01-01T00:00:00Z"},{"id":"55555555-5555-4555-8555-555555555555","role":"user","content":"Thanks for listening.","created_at":"2026-01-01T00:01:00Z"}],"next_cursor":null,"has_more":false}"#.utf8)
  }

  private func partnerSingleMessageResponse(
    content: String = "hello",
    createdAt: String = "2026-01-01T00:00:00Z"
  ) -> Data {
    Data("""
    {"data":[{"id":"66666666-6666-4666-8666-666666666666","role":"fox","content":"\(content)","created_at":"\(createdAt)"}],"next_cursor":null,"has_more":false}
    """.utf8)
  }

  private func pagedMessagesResponse() -> Data {
    Data(#"{"data":[{"id":"44444444-4444-4444-8444-444444444444","speaker":"my_fox","content":"hello","round_number":1,"created_at":"2026-01-01T00:00:00Z"}],"next_cursor":"opaque-cursor","has_more":true}"#.utf8)
  }


  private func fixtureDetail(
    conversationID: UUID?,
    status: String? = nil
  ) -> ProductionMatchDetail {
    ProductionMatchDetail(
      id: matchID,
      partnerID: partnerID,
      partner: MatchDetailPartner(nickname: "Aoi"),
      status: status ?? (conversationID == nil ? "pending" : "fox_conversation_completed"),
      foxConversationID: conversationID
    )
  }

  private func fixtureConversation(id: UUID, matchID: UUID) -> FoxConversationSummary {
    FoxConversationSummary(
      id: id,
      matchID: matchID,
      status: "completed",
      totalRounds: 2,
      currentRound: 2,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      completedAt: Date(timeIntervalSince1970: 1_700_000_120)
    )
  }

  private func fixtureMessage(
    id: UUID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
    content: String = "hello"
  ) -> FoxConversationMessage {
    FoxConversationMessage(
      id: id,
      speaker: .myFox,
      content: content,
      roundNumber: 1,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  private func fixturePartnerChat() -> PartnerFoxChatDetail {
    PartnerFoxChatDetail(
      id: partnerChatID,
      matchID: matchID,
      userID: ownerUUID,
      partnerUserID: partnerID,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      partner: MatchDetailPartner(nickname: "Aoi")
    )
  }

  private func fixturePartnerMessages() -> [PartnerFoxMessage] {
    [
      PartnerFoxMessage(
        id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
        role: .fox,
        content: "hello",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      PartnerFoxMessage(
        id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
        role: .user,
        content: "Thanks for listening.",
        createdAt: Date(timeIntervalSince1970: 1_700_000_060)
      )
    ]
  }
}

private actor PollingDetailAPI: MatchDetailAPI {
  private let details: [ProductionMatchDetail]
  private let conversation: FoxConversationSummary
  private let messages: [FoxConversationMessage]
  private let errorOnMatchCall: Int?
  private var matchCalls = 0
  private var conversationCalls = 0
  private var messageCalls = 0

  init(
    details: [ProductionMatchDetail],
    conversation: FoxConversationSummary,
    messages: [FoxConversationMessage],
    errorOnMatchCall: Int? = nil
  ) {
    self.details = details
    self.conversation = conversation
    self.messages = messages
    self.errorOnMatchCall = errorOnMatchCall
  }

  func fetchMatch(id: UUID) async throws -> ProductionMatchDetail {
    matchCalls += 1
    if matchCalls == errorOnMatchCall {
      throw APIClientError.temporarilyUnavailable
    }
    return details[min(matchCalls - 1, details.count - 1)]
  }

  func fetchConversation(id: UUID) async throws -> FoxConversationSummary {
    conversationCalls += 1
    return conversation
  }

  func fetchMessages(conversationID: UUID, limit: Int) async throws -> FoxConversationMessagesPayload {
    messageCalls += 1
    return FoxConversationMessagesPayload(messages: messages)
  }

  func startConversation(matchID: UUID) async throws -> FoxConversationStartResult {
    throw APIClientError.invalidState
  }

  func matchCallCount() -> Int { matchCalls }
  func conversationCallCount() -> Int { conversationCalls }
  func messageCallCount() -> Int { messageCalls }
}

private actor PollingSleepProbe {
  private var blocked = false

  func markBlocked() {
    blocked = true
  }

  func waitUntilBlocked() async -> Bool {
    for _ in 0..<100 {
      if blocked { return true }
      do {
        try await Task.sleep(nanoseconds: 1_000_000)
      } catch {
        return false
      }
    }
    return blocked
  }

}

private actor ScenarioDetailAPI: MatchDetailAPI {
  private var detail: ProductionMatchDetail
  private var conversation: FoxConversationSummary?
  private var messages: [FoxConversationMessage]
  private var matchError: APIClientError?

  init(
    detail: ProductionMatchDetail,
    conversation: FoxConversationSummary?,
    messages: [FoxConversationMessage]
  ) {
    self.detail = detail
    self.conversation = conversation
    self.messages = messages
  }

  func setMatchError(_ error: APIClientError?) {
    matchError = error
  }

  func fetchMatch(id: UUID) async throws -> ProductionMatchDetail {
    if let matchError { throw matchError }
    return detail
  }

  func fetchConversation(id: UUID) async throws -> FoxConversationSummary {
    guard let conversation else { throw APIClientError.notFound }
    return conversation
  }

  func fetchMessages(conversationID: UUID, limit: Int) async throws -> FoxConversationMessagesPayload {
    FoxConversationMessagesPayload(messages: messages)
  }

  func startConversation(matchID: UUID) async throws -> FoxConversationStartResult {
    throw APIClientError.invalidState
  }
}

private actor StartConversationDetailAPI: MatchDetailAPI {
  private let initialDetail: ProductionMatchDetail
  private let startedDetail: ProductionMatchDetail
  private let startResult: FoxConversationStartResult
  private let startError: APIClientError?
  private let startDelayNanoseconds: UInt64
  private let deferStart: Bool
  private var hasStarted = false
  private var startCalls = 0
  private var fetchMatchCalls = 0
  private var pendingStartContinuations: [CheckedContinuation<FoxConversationStartResult, Never>] = []

  init(
    initialDetail: ProductionMatchDetail,
    startedDetail: ProductionMatchDetail,
    startResult: FoxConversationStartResult? = nil,
    startError: APIClientError? = nil,
    startDelayNanoseconds: UInt64 = 0,
    deferStart: Bool = false
  ) {
    self.initialDetail = initialDetail
    self.startedDetail = startedDetail
    self.startResult = startResult ?? FoxConversationStartResult(
      conversationID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
      matchID: initialDetail.id
    )
    self.startError = startError
    self.startDelayNanoseconds = startDelayNanoseconds
    self.deferStart = deferStart
  }

  func fetchMatch(id: UUID) async throws -> ProductionMatchDetail {
    fetchMatchCalls += 1
    return hasStarted ? startedDetail : initialDetail
  }

  func fetchConversation(id: UUID) async throws -> FoxConversationSummary {
    FoxConversationSummary(
      id: id,
      matchID: startedDetail.id,
      status: "in_progress",
      totalRounds: 10,
      currentRound: 0
    )
  }

  func fetchMessages(conversationID: UUID, limit: Int) async throws -> FoxConversationMessagesPayload {
    FoxConversationMessagesPayload(messages: [
      FoxConversationMessage(
        id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
        speaker: .myFox,
        content: "hello",
        roundNumber: 1,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
      )
    ])
  }

  func startConversation(matchID: UUID) async throws -> FoxConversationStartResult {
    startCalls += 1
    if let startError { throw startError }
    if deferStart {
      return await withCheckedContinuation { continuation in
        pendingStartContinuations.append(continuation)
      }
    }
    if startDelayNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: startDelayNanoseconds)
    }
    hasStarted = true
    return startResult
  }

  func releaseStart() {
    guard deferStart else { return }
    hasStarted = true
    let continuations = pendingStartContinuations
    pendingStartContinuations = []
    for continuation in continuations {
      continuation.resume(returning: startResult)
    }
  }

  func startCallCount() -> Int { startCalls }
  func fetchMatchCallCount() -> Int { fetchMatchCalls }

  func waitForStart() async -> Bool {
    for _ in 0..<100 {
      if startCalls > 0 { return true }
      do {
        try await Task.sleep(nanoseconds: 1_000_000)
      } catch {
        return false
      }
    }
    return startCalls > 0
  }
}

private actor SequencedDetailAPI: MatchDetailAPI {
  private let firstDetail: ProductionMatchDetail
  private let secondDetail: ProductionMatchDetail
  private let firstConversation: FoxConversationSummary
  private let secondConversation: FoxConversationSummary
  private var matchCalls = 0
  private var firstConversationStarted = false

  init(
    firstDetail: ProductionMatchDetail,
    secondDetail: ProductionMatchDetail,
    firstConversation: FoxConversationSummary,
    secondConversation: FoxConversationSummary
  ) {
    self.firstDetail = firstDetail
    self.secondDetail = secondDetail
    self.firstConversation = firstConversation
    self.secondConversation = secondConversation
  }

  func fetchMatch(id: UUID) async throws -> ProductionMatchDetail {
    matchCalls += 1
    return matchCalls == 1 ? firstDetail : secondDetail
  }

  func fetchConversation(id: UUID) async throws -> FoxConversationSummary {
    if id == firstConversation.id {
      firstConversationStarted = true
      try? await Task.sleep(nanoseconds: 50_000_000)
      return firstConversation
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
    return secondConversation
  }

  func fetchMessages(conversationID: UUID, limit: Int) async throws -> FoxConversationMessagesPayload {
    FoxConversationMessagesPayload(messages: [])
  }

  func startConversation(matchID: UUID) async throws -> FoxConversationStartResult {
    throw APIClientError.invalidState
  }

  func waitForFirstConversationStart() async -> Bool {
    for _ in 0..<100 {
      if firstConversationStarted { return true }
      do {
        try await Task.sleep(nanoseconds: 1_000_000)
      } catch {
        return false
      }
    }
    return firstConversationStarted
  }
}

private actor ControlledHistoryAPI: MatchDetailAPI {
  private let firstDetail: ProductionMatchDetail
  private let refreshedDetail: ProductionMatchDetail
  private let oldConversation: FoxConversationSummary
  private let refreshedConversation: FoxConversationSummary
  private let oldMessages: [FoxConversationMessage]
  private let refreshedMessages: [FoxConversationMessage]
  private var usesRefreshedDetail = false
  private var oldHistoryStarted = false
  private var oldHistoryReleased = false
  private var oldHistoryContinuations: [CheckedContinuation<FoxConversationMessagesPayload, Never>] = []
  private var autoReleaseTask: Task<Void, Never>?
  private var messageIDs: [UUID] = []

  init(
    firstDetail: ProductionMatchDetail,
    refreshedDetail: ProductionMatchDetail,
    oldConversation: FoxConversationSummary,
    refreshedConversation: FoxConversationSummary,
    oldMessages: [FoxConversationMessage],
    refreshedMessages: [FoxConversationMessage]
  ) {
    self.firstDetail = firstDetail
    self.refreshedDetail = refreshedDetail
    self.oldConversation = oldConversation
    self.refreshedConversation = refreshedConversation
    self.oldMessages = oldMessages
    self.refreshedMessages = refreshedMessages
  }

  func useRefreshedDetail() {
    usesRefreshedDetail = true
  }

  func fetchMatch(id: UUID) async throws -> ProductionMatchDetail {
    usesRefreshedDetail ? refreshedDetail : firstDetail
  }

  func fetchConversation(id: UUID) async throws -> FoxConversationSummary {
    id == oldConversation.id ? oldConversation : refreshedConversation
  }

  func fetchMessages(conversationID: UUID, limit: Int) async throws -> FoxConversationMessagesPayload {
    messageIDs.append(conversationID)
    if conversationID == oldConversation.id {
      oldHistoryStarted = true
      if oldHistoryReleased {
        return FoxConversationMessagesPayload(messages: oldMessages)
      }
      scheduleAutoRelease()
      return await withCheckedContinuation { continuation in
        oldHistoryContinuations.append(continuation)
      }
    }
    return FoxConversationMessagesPayload(messages: refreshedMessages)
  }

  func startConversation(matchID: UUID) async throws -> FoxConversationStartResult {
    throw APIClientError.invalidState
  }

  func waitForOldHistoryStart() async -> Bool {
    for _ in 0..<100 {
      if oldHistoryStarted { return true }
      do {
        try await Task.sleep(nanoseconds: 1_000_000)
      } catch {
        return false
      }
    }
    return oldHistoryStarted
  }

  func oldHistoryWasReleased() -> Bool { oldHistoryReleased }

  func releaseOldHistory() {
    oldHistoryReleased = true
    autoReleaseTask?.cancel()
    autoReleaseTask = nil
    let continuations = oldHistoryContinuations
    oldHistoryContinuations = []
    let payload = FoxConversationMessagesPayload(messages: oldMessages)
    for continuation in continuations {
      continuation.resume(returning: payload)
    }
  }

  private func scheduleAutoRelease() {
    guard autoReleaseTask == nil else { return }
    autoReleaseTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }
      await self?.releaseOldHistory()
    }
  }

  func messageRequestIDs() -> [UUID] { messageIDs }
}

private actor RoutingDetailTransport: APIHTTPTransport {
  private let responses: [String: Data]
  private var requests: [URLRequest] = []

  init(responses: [String: Data]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard let url = request.url, let data = responses[url.absoluteString],
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
    else {
      throw APIClientError.invalidResponse
    }
    return (data, response)
  }

  func requestsSnapshot() -> [URLRequest] { requests }
}

private actor DelayedDetailAPI: MatchDetailAPI {
  let detail: ProductionMatchDetail

  init(detail: ProductionMatchDetail) {
    self.detail = detail
  }

  func fetchMatch(id: UUID) async throws -> ProductionMatchDetail {
    // Deliberately return after cancellation so the store's generation guard is exercised.
    try? await Task.sleep(nanoseconds: 50_000_000)
    return detail
  }

  func fetchConversation(id: UUID) async throws -> FoxConversationSummary {
    throw APIClientError.notFound
  }

  func fetchMessages(conversationID: UUID, limit: Int) async throws -> FoxConversationMessagesPayload {
    FoxConversationMessagesPayload(messages: [])
  }

  func startConversation(matchID: UUID) async throws -> FoxConversationStartResult {
    throw APIClientError.invalidState
  }
}

private actor PartnerWardDetailAPI: MatchDetailAPI {
  private let chat: PartnerFoxChatDetail
  private let messages: [PartnerFoxMessage]
  private let delayNanoseconds: UInt64
  private var detailCalls = 0
  private var messageCalls = 0

  init(
    chat: PartnerFoxChatDetail,
    messages: [PartnerFoxMessage],
    delayNanoseconds: UInt64 = 0
  ) {
    self.chat = chat
    self.messages = messages
    self.delayNanoseconds = delayNanoseconds
  }

  func fetchMatch(id: UUID) async throws -> ProductionMatchDetail {
    throw APIClientError.invalidState
  }

  func fetchConversation(id: UUID) async throws -> FoxConversationSummary {
    throw APIClientError.invalidState
  }

  func fetchMessages(conversationID: UUID, limit: Int) async throws -> FoxConversationMessagesPayload {
    throw APIClientError.invalidState
  }

  func startConversation(matchID: UUID) async throws -> FoxConversationStartResult {
    throw APIClientError.invalidState
  }

  func fetchPartnerChat(id: UUID) async throws -> PartnerFoxChatDetail {
    detailCalls += 1
    if delayNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: delayNanoseconds)
    }
    return chat
  }

  func fetchPartnerMessages(chatID: UUID) async throws -> PartnerFoxMessagesPayload {
    messageCalls += 1
    if delayNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: delayNanoseconds)
    }
    return PartnerFoxMessagesPayload(messages: messages)
  }

  func detailCallCount() -> Int { detailCalls }
  func messageCallCount() -> Int { messageCalls }
}

private actor DetailAuthService: AuthService {
  private let session: AuthSession?

  init(session: AuthSession?) {
    self.session = session
  }

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

private actor DetailProfileAPI: ProfileAPI {
  private let profiles: [String: String]
  private var calls = 0

  init(profiles: [String: String]) {
    self.profiles = profiles
  }

  func fetchProfile(accessToken: String) async throws -> UserProfile {
    calls += 1
    return UserProfile(id: profiles[accessToken], ageVerified: true)
  }

  func verifyAge(accessToken: String, birthDate: String) async throws {}
  func fetchCallCount() -> Int { calls }
}

private actor CapturingDetailTransport: APIHTTPTransport {
  private let responseData: Data
  private var requests: [URLRequest] = []

  init(responseData: Data) {
    self.responseData = responseData
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
    else {
      throw APIClientError.invalidResponse
    }
    return (responseData, response)
  }

  func requestCount() -> Int { requests.count }
  func requestsSnapshot() -> [URLRequest] { requests }
}
