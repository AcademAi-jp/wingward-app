import Foundation
import XCTest
@testable import Wingward

@MainActor
final class ChatsTests: XCTestCase {
  private let ownerID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
  private let partnerID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
  private let matchID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let roomID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
  private let messageID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!

  func testDirectChatAndRequestDTOsDecodeClosedServerProjections() throws {
    let chats = try APIResponseDecoder.decode(
      Data(#"{"data":[{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","match_id":"11111111-1111-4111-8111-111111111111","partner":{"nickname":"Aoi","avatar_url":null},"last_message":{"content":"hello","created_at":"2026-01-01T00:00:00Z","is_mine":false},"unread_count":2,"unread_count_after_seen":1,"status":"active"}]}"#.utf8),
      as: TestDirectChatListPayload.self
    )
    XCTAssertEqual(chats.chats.first?.id, roomID)
    XCTAssertEqual(chats.chats.first?.partner?.displayName, "Aoi")

    let messages = try APIResponseDecoder.decode(
      Data(#"{"data":[{"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","sender_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","is_mine":false,"content":"hello","is_read":false,"created_at":"2026-01-01T00:00:00Z"}],"next_cursor":null,"has_more":false}"#.utf8),
      as: DirectChatMessagesPayload.self
    )
    XCTAssertEqual(messages.messages.first?.senderID, partnerID)
    XCTAssertFalse(messages.messages.first?.isMine ?? true)

    let request = try APIResponseDecoder.decode(
      Data(#"{"data":{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","match_id":"11111111-1111-4111-8111-111111111111","status":"pending","expires_at":"2026-01-03T00:00:00Z"}}"#.utf8),
      as: ChatRequestCreateResult.self
    )
    XCTAssertEqual(request.matchID, matchID)
    XCTAssertEqual(request.status, "pending")
  }

  func testSendRetryReceiptStoresOnlyOwnerConversationKeyAndContentDigest() throws {
    let receipt = MessageSendRetryReceipt(
      kind: .directChat,
      ownerID: ownerID,
      conversationID: roomID,
      idempotencyKey: messageID,
      contentSHA256: MessageSendRetryReceipt.contentSHA256(for: "private message body")
    )
    let data = try JSONEncoder().encode(receipt)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(Set(json.keys), Set(["kind", "ownerID", "conversationID", "idempotencyKey", "contentSHA256"]))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private message body"))
    XCTAssertTrue(receipt.matches(kind: .directChat, ownerID: ownerID, conversationID: roomID))
    XCTAssertFalse(receipt.matches(kind: .partnerWard, ownerID: ownerID, conversationID: roomID))
    XCTAssertFalse(receipt.matches(kind: .directChat, ownerID: ownerID, conversationID: partnerID))
  }

  func testLiveDirectChatAPIUsesExactPathsBodiesAndCursor() async throws {
    let client = FakeAuthenticatedAPIClient()
    let chatsRequest = APIRequest(method: .get, path: LiveDirectChatsAPI.directChatsPath)
    let messagesRequest = APIRequest(
      method: .get,
      path: LiveDirectChatsAPI.directMessagesPath(for: roomID, limit: 50) + "&cursor=2026-01-01T00%3A00%3A00Z"
    )
    let idempotencyKey = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    let sendRequest = APIRequest(
      method: .post,
      path: LiveDirectChatsAPI.directMessagesPath(for: roomID, limit: nil),
      body: Data(#"{"content":"hello","idempotency_key":"99999999-9999-4999-8999-999999999999"}"#.utf8)
    )
    let contentSHA256 = MessageSendRetryReceipt.contentSHA256(for: "hello")
    let recoveryRequest = APIRequest(
      method: .post,
      path: LiveDirectChatsAPI.directMessageSendRecoveryPath(roomID: roomID),
      body: Data(#"{"idempotency_key":"99999999-9999-4999-8999-999999999999","content_sha256":"\#(contentSHA256)"}"#.utf8)
    )
    let requestStateRequest = APIRequest(
      method: .get,
      path: LiveDirectChatsAPI.chatRequestMatchPath(for: matchID)
    )
    await client.setResponseData(Data(#"{"data":[]}"#.utf8), for: chatsRequest)
    await client.setResponseData(Data(#"{"data":[],"next_cursor":null,"has_more":false}"#.utf8), for: messagesRequest)
    await client.setResponseData(Data(#"{"data":{"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","content":"hello","created_at":"2026-01-01T00:00:00Z"}}"#.utf8), for: sendRequest)
    await client.setResponseData(
      Data(#"{"data":{"outcome":"found","message":{"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","content":"hello","created_at":"2026-01-01T00:00:00Z"}}}"#.utf8),
      for: recoveryRequest
    )
    await client.setResponseData(
      Data(#"{"data":{"request":{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","match_id":"11111111-1111-4111-8111-111111111111","requester_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","responder_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","status":"pending","expires_at":"2026-01-03T00:00:00Z"}}}"#.utf8),
      for: requestStateRequest
    )
    let api = LiveDirectChatsAPI(client: client)

    _ = try await api.fetchDirectChats()
    _ = try await api.fetchDirectMessages(roomID: roomID, limit: 50, cursor: "2026-01-01T00:00:00Z")
    _ = try await api.sendDirectMessage(roomID: roomID, content: "hello", idempotencyKey: idempotencyKey)
    let recovery = try await api.recoverDirectMessageSend(
      roomID: roomID,
      idempotencyKey: idempotencyKey,
      contentSHA256: contentSHA256
    )
    XCTAssertEqual(recovery.outcome, .found)
    let requestState = try await api.fetchChatRequestState(matchID: matchID)
    XCTAssertEqual(requestState?.requesterID, ownerID)
    XCTAssertEqual(requestState?.status, .pending)

    let requests = await client.recordedRequests()
    XCTAssertEqual(requests.count, 5)
    XCTAssertEqual(requests[0], chatsRequest)
    XCTAssertEqual(requests[1], messagesRequest)
    XCTAssertEqual(requests[4], requestStateRequest)
    XCTAssertEqual(requests[2].method, sendRequest.method)
    XCTAssertEqual(requests[2].path, sendRequest.path)
    XCTAssertEqual(requests[2].contentType, sendRequest.contentType)
    let actualBody = try JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].body)) as? NSDictionary
    let expectedBody = try JSONSerialization.jsonObject(with: XCTUnwrap(sendRequest.body)) as? NSDictionary
    XCTAssertEqual(actualBody, expectedBody)
    XCTAssertEqual(requests[3].method, recoveryRequest.method)
    XCTAssertEqual(requests[3].path, recoveryRequest.path)
    let actualRecoveryBody = try JSONSerialization.jsonObject(with: XCTUnwrap(requests[3].body)) as? NSDictionary
    let expectedRecoveryBody = try JSONSerialization.jsonObject(with: XCTUnwrap(recoveryRequest.body)) as? NSDictionary
    XCTAssertEqual(actualRecoveryBody, expectedRecoveryBody)
  }

  func testDirectChatStoreAppendsServerAcknowledgementAndProtectsDraftFlow() async {
    let api = DirectChatsTestAPI(ownerID: ownerID, roomID: roomID, partnerID: partnerID, matchID: matchID)
    let store = DirectChatStore(ownerID: ownerID.uuidString, roomID: roomID, api: api, retryReceiptStore: MemoryMessageSendRetryReceiptStore())
    await store.load().value
    await store.sendMessage("hello").value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.messages.count, 2)
    XCTAssertEqual(store.messages.last?.content, "hello")
    XCTAssertNotNil(store.lastSentMessageID)
    let sendCount = await api.sendCount()
    XCTAssertEqual(sendCount, 1)
  }

  func testDirectChatResponseLossRetryReusesKeyAndContentWithoutAddingAnotherRow() async {
    let api = DirectChatsTestAPI(
      ownerID: ownerID,
      roomID: roomID,
      partnerID: partnerID,
      matchID: matchID,
      loseResponseAfterCommit: true
    )
    let store = DirectChatStore(ownerID: ownerID.uuidString, roomID: roomID, api: api, retryReceiptStore: MemoryMessageSendRetryReceiptStore())
    await store.load().value

    await store.sendMessage("hello").value
    XCTAssertEqual(store.sendError, .temporarilyUnavailable)
    await store.sendMessage("different text").value
    XCTAssertEqual(store.sendError, .unresolvedSend)
    let countBeforeRetry = await api.sendCount()
    XCTAssertEqual(countBeforeRetry, 1)
    await store.sendMessage("hello").value

    XCTAssertEqual(store.sendError, nil)
    XCTAssertEqual(store.messages.filter(\.isMine).map(\.content), ["hello"])
    let persistedCount = await api.persistedMessageCount()
    let sentKeys = await api.sentKeys()
    let sentContents = await api.sentContents()
    XCTAssertEqual(persistedCount, 1)
    XCTAssertEqual(sentKeys.count, 2)
    XCTAssertEqual(sentKeys[0], sentKeys[1])
    XCTAssertEqual(sentContents, ["hello", "hello"])
  }

  func testDirectStoresCreatedBeforeSendShareTheCommittedRetryReceipt() async throws {
    let api = DirectChatsTestAPI(
      ownerID: ownerID,
      roomID: roomID,
      partnerID: partnerID,
      matchID: matchID,
      loseResponseAfterCommit: true
    )
    let receiptStore = MemoryMessageSendRetryReceiptStore()
    let firstStore = DirectChatStore(
      ownerID: ownerID.uuidString,
      roomID: roomID,
      api: api,
      retryReceiptStore: receiptStore
    )
    let secondStore = DirectChatStore(
      ownerID: ownerID.uuidString,
      roomID: roomID,
      api: api,
      retryReceiptStore: receiptStore
    )
    await firstStore.load().value
    await secondStore.load().value

    await firstStore.sendMessage("hello").value
    let receipt = try XCTUnwrap(try receiptStore.load(
      kind: .directChat,
      ownerID: ownerID,
      conversationID: roomID
    ))
    await secondStore.sendMessage("different text").value
    XCTAssertEqual(secondStore.sendError, .unresolvedSend)
    await secondStore.sendMessage("hello").value

    XCTAssertNil(secondStore.sendError)
    let sentKeys = await api.sentKeys()
    let persistedCount = await api.persistedMessageCount()
    XCTAssertEqual(sentKeys, [receipt.idempotencyKey, receipt.idempotencyKey])
    XCTAssertEqual(persistedCount, 1)
  }

  func testDirectResponseLossRecoversAfterStoreRecreationWithoutAnotherPost() async throws {
    let api = DirectChatsTestAPI(
      ownerID: ownerID,
      roomID: roomID,
      partnerID: partnerID,
      matchID: matchID,
      loseResponseAfterCommit: true
    )
    let receiptStore = MemoryMessageSendRetryReceiptStore()
    let firstStore = DirectChatStore(
      ownerID: ownerID.uuidString,
      roomID: roomID,
      api: api,
      retryReceiptStore: receiptStore
    )
    await firstStore.load().value
    await firstStore.sendMessage("hello").value
    XCTAssertEqual(firstStore.sendError, .temporarilyUnavailable)

    let savedReceipt = try XCTUnwrap(try receiptStore.load(
      kind: .directChat,
      ownerID: ownerID,
      conversationID: roomID
    ))
    let restartedStore = DirectChatStore(
      ownerID: ownerID.uuidString,
      roomID: roomID,
      api: api,
      retryReceiptStore: receiptStore
    )
    await restartedStore.load().value

    XCTAssertEqual(restartedStore.phase, .loaded)
    XCTAssertEqual(restartedStore.messages.filter(\.isMine).map(\.content), ["hello"])
    let sendCount = await api.sendCount()
    let persistedCount = await api.persistedMessageCount()
    let recoveryCount = await api.recoveryLookupCount()
    XCTAssertEqual(sendCount, 1)
    XCTAssertEqual(persistedCount, 1)
    XCTAssertEqual(recoveryCount, 1)
    XCTAssertNil(try receiptStore.load(kind: .directChat, ownerID: ownerID, conversationID: roomID))
    XCTAssertEqual(savedReceipt.contentSHA256, MessageSendRetryReceipt.contentSHA256(for: "hello"))
  }

  func testDirectMissingRecoveryLookupDoesNotReplaceKeyWhileOriginalPostIsStillRunning() async throws {
    let api = DirectChatsTestAPI(
      ownerID: ownerID,
      roomID: roomID,
      partnerID: partnerID,
      matchID: matchID,
      loseResponseAfterCommit: true,
      suspendFirstSendBeforeCommit: true
    )
    let receiptStore = MemoryMessageSendRetryReceiptStore()
    let originalStore = DirectChatStore(
      ownerID: ownerID.uuidString,
      roomID: roomID,
      api: api,
      retryReceiptStore: receiptStore
    )
    await originalStore.load().value
    let originalPost = originalStore.sendMessage("hello")
    let suspended = await api.waitForFirstSendSuspension()
    XCTAssertTrue(suspended)
    let originalReceipt = try XCTUnwrap(try receiptStore.load(
      kind: .directChat,
      ownerID: ownerID,
      conversationID: roomID
    ))

    let restartedStore = DirectChatStore(
      ownerID: ownerID.uuidString,
      roomID: roomID,
      api: api,
      retryReceiptStore: receiptStore
    )
    await restartedStore.load().value
    let lookupCount = await api.recoveryLookupCount()
    XCTAssertEqual(lookupCount, 1)
    XCTAssertEqual(try receiptStore.load(kind: .directChat, ownerID: ownerID, conversationID: roomID), originalReceipt)

    await api.resumeFirstSend()
    await originalPost.value
    XCTAssertEqual(originalStore.sendError, .temporarilyUnavailable)
    await restartedStore.sendMessage("hello").value

    let persistedCount = await api.persistedMessageCount()
    let sendCount = await api.sendCount()
    let sentKeys = await api.sentKeys()
    XCTAssertEqual(persistedCount, 1)
    XCTAssertEqual(sendCount, 2)
    XCTAssertEqual(sentKeys, [originalReceipt.idempotencyKey, originalReceipt.idempotencyKey])
    XCTAssertEqual(restartedStore.messages.filter(\.isMine).map(\.content), ["hello"])
  }

  func testDirectChatCompetingSendAndForbiddenRecovery() async {
    let api = DirectChatsTestAPI(
      ownerID: ownerID,
      roomID: roomID,
      partnerID: partnerID,
      matchID: matchID,
      sendError: .forbidden,
      delayNanoseconds: 30_000_000
    )
    let store = DirectChatStore(ownerID: ownerID.uuidString, roomID: roomID, api: api, retryReceiptStore: MemoryMessageSendRetryReceiptStore())
    await store.load().value
    let first = store.sendMessage("first")
    let second = store.sendMessage("second")
    await first.value
    await second.value

    XCTAssertEqual(store.phase, .failed(.forbidden))
    XCTAssertTrue(store.messages.isEmpty)
    let sendCount = await api.sendCount()
    XCTAssertEqual(sendCount, 1)

    await api.clearSendError()
    await store.retry().value
    XCTAssertEqual(store.phase, .loaded)
  }

  func testReceivedChatRequestAcceptsServerPercentageScoresAndRejectsOutOfRange() throws {
    for score in [0.0, 50.0, 100.0, -0.1, 100.1] {
      let data = Data("""
        {"data":{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","match_id":"11111111-1111-4111-8111-111111111111","requester_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","status":"pending","expires_at":"2026-01-03T00:00:00Z","created_at":"2026-01-01T00:00:00Z","requester":{"nickname":"Synthetic partner"},"final_score":\(score)}}
        """.utf8)
      if (0...100).contains(score) {
        let request = try APIResponseDecoder.decode(data, as: ChatRequestSummary.self)
        XCTAssertEqual(request.finalScore, score)
      } else {
        XCTAssertThrowsError(try APIResponseDecoder.decode(data, as: ChatRequestSummary.self))
      }
    }
  }

  func testChatRequestAcceptPublishesOnlyReturnedRoom() async {
    let api = DirectChatsTestAPI(ownerID: ownerID, roomID: roomID, partnerID: partnerID, matchID: matchID)
    let store = ChatRequestsStore(ownerID: ownerID.uuidString, api: api)
    await store.load().value
    guard let request = store.requests.first else {
      XCTFail("fixture request missing")
      return
    }

    await store.respond(to: request, action: .accept).value

    XCTAssertTrue(store.requests.isEmpty)
    XCTAssertEqual(store.lastAcceptedRoomID, roomID)
  }

  func testPartnerSafetyTargetDeliversTheChatRequestMatchAndContext() {
    let target = PartnerSafetyTarget.make(matchID: matchID, context: .directChat)
    var received: (UUID, ReportContext)?

    target?.open { matchID, context in
      received = (matchID, context)
    }

    XCTAssertEqual(received?.0, matchID)
    XCTAssertEqual(received?.1, .directChat)
  }

  func testReboundChatStoresRejectBeforeCallingTheOldOwnerBoundAPI() async {
    let api = DirectChatsTestAPI(ownerID: ownerID, roomID: roomID, partnerID: partnerID, matchID: matchID)

    let listStore = DirectChatsStore(ownerID: ownerID.uuidString, api: api)
    listStore.updateOwner(partnerID.uuidString)
    await listStore.load().value
    XCTAssertEqual(listStore.phase, .failed(.unauthenticated))

    let roomStore = DirectChatStore(ownerID: ownerID.uuidString, roomID: roomID, api: api, retryReceiptStore: MemoryMessageSendRetryReceiptStore())
    roomStore.updateOwner(partnerID.uuidString)
    await roomStore.load().value
    XCTAssertEqual(roomStore.phase, .failed(.unauthenticated))

    let requestsStore = ChatRequestsStore(ownerID: ownerID.uuidString, api: api)
    requestsStore.updateOwner(partnerID.uuidString)
    await requestsStore.load().value
    XCTAssertEqual(requestsStore.phase, .failed(.unauthenticated))
    await requestsStore.loadRequestState(matchID: matchID).value
    XCTAssertEqual(requestsStore.requestStatePhase, .failed(.unauthenticated))

    let counts = await api.readCounts()
    XCTAssertEqual(counts.directChats, 0)
    XCTAssertEqual(counts.messages, 0)
    XCTAssertEqual(counts.requests, 0)
    let requestStateFetchCount = await api.requestStateFetchCount()
    XCTAssertEqual(requestStateFetchCount, 0)
  }

  func testChatRequestStateLoadsMatchBoundPendingStatus() async {
    let api = DirectChatsTestAPI(ownerID: ownerID, roomID: roomID, partnerID: partnerID, matchID: matchID)
    let store = ChatRequestsStore(ownerID: ownerID.uuidString, api: api)

    await store.loadRequestState(matchID: matchID).value

    XCTAssertEqual(store.requestStatePhase, .loaded)
    XCTAssertEqual(store.requestStateMatchID, matchID)
    XCTAssertEqual(store.requestState?.requesterID, partnerID)
    XCTAssertEqual(store.requestState?.responderID, ownerID)
  }

  func testLateChatRequestStateForPreviousOwnerIsDiscarded() async {
    let api = DirectChatsTestAPI(
      ownerID: ownerID,
      roomID: roomID,
      partnerID: partnerID,
      matchID: matchID,
      suspendsRequestStateFetches: true
    )
    let store = ChatRequestsStore(ownerID: ownerID.uuidString, api: api)
    let request = store.loadRequestState(matchID: matchID)

    guard await waitForRequestStateFetchCount(1, api: api) else {
      XCTFail("request state fetch did not start")
      store.cancel()
      return
    }
    store.updateOwner(partnerID.uuidString)
    await api.resolveRequestStateFetch(matchID: matchID)
    await request.value

    XCTAssertEqual(store.requestStatePhase, .idle)
    XCTAssertNil(store.requestState)
    XCTAssertNil(store.requestStateMatchID)
  }

  func testLateChatRequestStateForPreviousMatchIsDiscarded() async {
    let otherMatchID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let api = DirectChatsTestAPI(
      ownerID: ownerID,
      roomID: roomID,
      partnerID: partnerID,
      matchID: matchID,
      suspendsRequestStateFetches: true
    )
    let store = ChatRequestsStore(ownerID: ownerID.uuidString, api: api)
    let firstRequest = store.loadRequestState(matchID: matchID)

    guard await waitForRequestStateFetchCount(1, api: api) else {
      XCTFail("first request state fetch did not start")
      store.cancel()
      return
    }
    let secondRequest = store.loadRequestState(matchID: otherMatchID)
    guard await waitForRequestStateFetchCount(2, api: api) else {
      XCTFail("second request state fetch did not start")
      store.cancel()
      await api.resolveRequestStateFetch(matchID: matchID)
      return
    }

    await api.resolveRequestStateFetch(matchID: matchID)
    await firstRequest.value
    XCTAssertEqual(store.requestStatePhase, .loading)
    XCTAssertEqual(store.requestStateMatchID, otherMatchID)
    XCTAssertNil(store.requestState)

    await api.resolveRequestStateFetch(matchID: otherMatchID)
    await secondRequest.value
    XCTAssertEqual(store.requestStatePhase, .loaded)
    XCTAssertEqual(store.requestStateMatchID, otherMatchID)
    XCTAssertEqual(store.requestState?.matchID, otherMatchID)
  }

  func testCancelledChatRequestStateCannotPublishLateResponse() async {
    let api = DirectChatsTestAPI(
      ownerID: ownerID,
      roomID: roomID,
      partnerID: partnerID,
      matchID: matchID,
      suspendsRequestStateFetches: true
    )
    let store = ChatRequestsStore(ownerID: ownerID.uuidString, api: api)
    let request = store.loadRequestState(matchID: matchID)

    guard await waitForRequestStateFetchCount(1, api: api) else {
      XCTFail("request state fetch did not start")
      store.cancel()
      return
    }
    store.cancel()
    await api.resolveRequestStateFetch(matchID: matchID)
    await request.value

    XCTAssertEqual(store.requestStatePhase, .idle)
    XCTAssertNil(store.requestState)
    XCTAssertNil(store.requestStateMatchID)
  }

#if DEBUG
  func testDebugChatFixtureRetainsCreatedAndAcceptedStateAcrossRefreshes() async throws {
    let api = DebugChatsAPI(ownerID: ChatsDebugFixture.ownerID)

    let created = try await api.createChatRequest(matchID: DebugChatsAPI.outgoingMatchID)
    let createdState = try await api.fetchChatRequestState(matchID: DebugChatsAPI.outgoingMatchID)
    XCTAssertEqual(createdState?.id, created.id)
    XCTAssertEqual(createdState?.status, .pending)
    XCTAssertEqual(createdState?.requesterID, ownerID)

    let incomingRequests = try await api.fetchChatRequests()
    let incomingRequest = try XCTUnwrap(
      incomingRequests.first(where: { $0.matchID == DebugChatsAPI.incomingMatchID })
    )
    let decision = try await api.respondToChatRequest(
      requestID: incomingRequest.id,
      action: .accept
    )
    let acceptedState = try await api.fetchChatRequestState(
      matchID: DebugChatsAPI.incomingMatchID
    )
    let refreshedRequests = try await api.fetchChatRequests()

    XCTAssertEqual(decision.status, "accepted")
    XCTAssertEqual(decision.directChatRoomID, roomID)
    XCTAssertEqual(acceptedState?.status, .accepted)
    XCTAssertFalse(refreshedRequests.contains(where: { $0.id == incomingRequest.id }))
  }
#endif


  func testChatMeetupAPIUsesOwnerPrivateRevisionAndExactActionBody() async throws {
    let client = FakeAuthenticatedAPIClient()
    let read = APIRequest(method: .get, path: LiveDirectChatsAPI.chatMeetupPath(roomID: roomID))
    let post = APIRequest(method: .post, path: LiveDirectChatsAPI.chatMeetupActionsPath(roomID: roomID))
    await client.setResponseData(chatMeetupEnvelope(privateRevision: 0, status: "idle"), for: read)
    await client.setResponseData(
      chatMeetupEnvelope(privateRevision: 1, status: "awaiting_availability", intent: "yes"),
      for: post
    )
    let api = LiveDirectChatsAPI(client: client)

    let current = try await api.fetchChatMeetup(roomID: roomID)
    XCTAssertEqual(current.revision, 0)
    XCTAssertEqual(current.ownDecisions.privateRevision, 0)

    let key = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    let updated = try await api.performChatMeetupAction(
      roomID: roomID,
      expectedRevision: current.revision,
      expectedOwnRevision: current.ownDecisions.privateRevision,
      action: .intent(.yes),
      idempotencyKey: key
    )
    XCTAssertEqual(updated.revision, 0, "A private intent must not increment the shared revision.")
    XCTAssertEqual(updated.ownDecisions.privateRevision, 1)

    let requests = await client.recordedRequests()
    XCTAssertEqual(requests.map(\.path), [read.path, post.path])
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].body)) as? [String: Any]
    )
    XCTAssertEqual(Set(body.keys), Set(["idempotency_key", "expected_revision", "expected_own_revision", "action"]))
    XCTAssertEqual(body["idempotency_key"] as? String, key.uuidString.lowercased())
    XCTAssertEqual(body["expected_revision"] as? Int, 0)
    XCTAssertEqual(body["expected_own_revision"] as? Int, 0)
    let action = try XCTUnwrap(body["action"] as? [String: String])
    XCTAssertEqual(action, ["type": "intent", "value": "yes"])
  }

  func testChatMeetupDecodesCafeProposalEnvelopeWithOwnerPrivateFields() throws {
    let state = try APIResponseDecoder.decode(
      Data(#"{"data":{"room_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","meetup_id":"55555555-5555-4555-8555-555555555555","revision":7,"status":"cafe_proposed","events":[{"id":"23232323-2323-4323-8323-232323232323","revision":7,"kind":"ward","text":"A café option is ready.","created_at":"2026-09-26T10:00:00Z"}],"time_candidates":[{"id":"24242424-2424-4424-8424-242424242424","starts_at":"2026-09-27T06:00:00Z","ends_at":"2026-09-27T07:30:00Z"}],"cafe_candidates":[{"id":"provider-place:central-01","name":"Central Kissa","address":"1 Example Street","starts_at":"2026-09-27T06:00:00Z","ends_at":"2026-09-27T07:30:00Z","opening_interval":{"starts_at":"2026-09-27T00:00:00Z","ends_at":"2026-09-27T13:00:00Z"},"travel_minutes_first":18,"travel_minutes_second":22}],"own_permissions":{"can_intent":false,"can_schedule":true,"can_replan":false,"can_cancel":true,"can_complete":false,"calendar_connected":false,"cafe_connected":true,"reason":null},"own_decisions":{"intent_value":"yes","time_candidate_id":"24242424-2424-4424-8424-242424242424","cafe_candidate_id":null,"completed":false,"private_revision":3},"needs_location":false,"expires_at":"2026-09-28T06:00:00Z","unavailable_reason":null}}"#.utf8),
      as: ChatMeetupState.self
    )
    try ChatMeetupState.validate(state)
    XCTAssertEqual(state.roomID, roomID)
    XCTAssertEqual(state.status, .cafeProposed)
    XCTAssertEqual(state.events.first?.kind, .ward)
    XCTAssertEqual(state.timeCandidates.first?.id.uuidString.lowercased(), "24242424-2424-4424-8424-242424242424")
    XCTAssertEqual(state.cafeCandidates.first?.id, "provider-place:central-01")
    XCTAssertEqual(state.cafeCandidates.first?.startsAt, state.timeCandidates.first?.startsAt)
    XCTAssertEqual(state.cafeCandidates.first?.travelMinutesFirst, 18)
    XCTAssertEqual(state.ownDecisions.intentValue, .yes)
    XCTAssertEqual(state.ownDecisions.privateRevision, 3)
  }

  func testMeetupReflectionAPIUsesExactDraftAndOwnerConfirmationBodies() async throws {
    let meetupID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    let turnID = UUID(uuidString: "18181818-1818-4818-8818-181818181818")!
    let candidateID = UUID(uuidString: "21212121-2121-4121-8121-212121212121")!
    let idempotencyKey = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    let draftRequest = APIRequest(
      method: .post,
      path: LiveDirectChatsAPI.meetupReflectionDraftPath(meetupID: meetupID)
    )
    let confirmRequest = APIRequest(
      method: .post,
      path: LiveDirectChatsAPI.meetupReflectionConfirmPath(meetupID: meetupID)
    )
    let client = FakeAuthenticatedAPIClient()
    await client.setResponseData(
      Data(#"{"data":{"expected_version":2,"candidates":[{"candidate_id":"21212121-2121-4121-8121-212121212121","trait_key":"favorite_activity","value":"outdoors","source_turn_ids":["18181818-1818-4818-8818-181818181818"],"evidence_label":"user_statement","confidence_label":"AI draft; not confirmed"}]}}"#.utf8),
      for: draftRequest
    )
    await client.setResponseData(
      Data(#"{"data":{"version":3,"confirmed_at":"2026-09-26T10:00:00Z","confirmed_traits":{"favorite_activity":"outdoors"},"replayed":false}}"#.utf8),
      for: confirmRequest
    )
    let api = LiveDirectChatsAPI(client: client)
    let statements = [ChatMeetupReflectionUserStatement(turnID: turnID, text: "I enjoy being outdoors.")]
    let draft = try await api.draftMeetupReflection(meetupID: meetupID, statements: statements)
    XCTAssertEqual(draft.expectedVersion, 2)
    XCTAssertEqual(draft.candidates.map(\.id), [candidateID])
    let saved = try await api.confirmMeetupReflection(
      meetupID: meetupID,
      expectedVersion: draft.expectedVersion,
      traits: [ChatMeetupReflectionTrait(key: .favoriteActivity, value: .outdoors)],
      idempotencyKey: idempotencyKey
    )
    XCTAssertEqual(saved.version, 3)
    XCTAssertEqual(saved.traits, [ChatMeetupReflectionTrait(key: .favoriteActivity, value: .outdoors)])

    let requests = await client.recordedRequests()
    XCTAssertEqual(requests.map(\.path), [draftRequest.path, confirmRequest.path])
    let draftBody = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].body)) as? [String: Any]
    )
    XCTAssertEqual(Set(draftBody.keys), Set(["statements"]))
    let sentStatements = try XCTUnwrap(draftBody["statements"] as? [[String: String]])
    XCTAssertEqual(sentStatements, [["turn_id": turnID.uuidString.lowercased(), "text": "I enjoy being outdoors."]])

    let confirmBody = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].body)) as? [String: Any]
    )
    XCTAssertEqual(
      Set(confirmBody.keys),
      Set(["idempotency_key", "expected_version", "owner_confirmed", "traits"])
    )
    XCTAssertEqual(confirmBody["idempotency_key"] as? String, idempotencyKey.uuidString.lowercased())
    XCTAssertEqual(confirmBody["expected_version"] as? Int, 2)
    XCTAssertEqual(confirmBody["owner_confirmed"] as? Bool, true)
    let traits = try XCTUnwrap(confirmBody["traits"] as? [[String: String]])
    XCTAssertEqual(traits, [["trait_key": "favorite_activity", "value": "outdoors"]])

    let tooManyStatements = (0..<25).map {
      ChatMeetupReflectionUserStatement(turnID: UUID(), text: "Statement \($0)")
    }
    do {
      _ = try await api.draftMeetupReflection(meetupID: meetupID, statements: tooManyStatements)
      XCTFail("The API client must enforce the server's 24-turn limit.")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidRequest)
    }
    let finalRequests = await client.recordedRequests()
    XCTAssertEqual(finalRequests.count, 2)
  }

  func testMeetupLocationActionSendsOnlyPrivateRequestFieldsWithoutConsentExpiry() throws {
    let expiry = Date().addingTimeInterval(300)
    let action = ChatMeetupAction.currentLocation(
      latitude: 35.6812,
      longitude: 139.7671,
      station: nil,
      nearestStation: "Tokyo",
      expiresAt: expiry,
      nearbyStations: []
    )
    let data = try JSONEncoder().encode(action)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["type"] as? String, "location.submit")
    let location = try XCTUnwrap(json["location"] as? [String: Any])
    XCTAssertEqual(location["kind"] as? String, "coordinates")
    XCTAssertEqual(location["nearest_station"] as? String, "Tokyo")
    XCTAssertNil(location["expires_at"])
    XCTAssertNil(location["station"])
    XCTAssertEqual(Set(location.keys), Set(["kind", "latitude", "longitude", "nearest_station", "nearby_station_names"]))
  }

  func testMeetupReflectionDecodesServerVersionAndRejectsUnknownSourceTurns() throws {
    let response = try APIResponseDecoder.decode(
      Data(#"{"data":{"version":3,"confirmed_at":"2026-09-26T10:00:00Z","confirmed_traits":{"social_energy":"ambiverted"},"replayed":false}}"#.utf8),
      as: ChatMeetupReflectionConfirmation.self
    )
    XCTAssertEqual(response.version, 3)
    XCTAssertEqual(response.traits, [ChatMeetupReflectionTrait(key: .socialEnergy, value: .ambiverted)])

    let source = UUID(uuidString: "18181818-1818-4818-8818-181818181818")!
    let unknown = UUID(uuidString: "19191919-1919-4919-8919-191919191919")!
    let candidate = ChatMeetupReflectionDraftCandidate(
      id: UUID(uuidString: "20202020-2020-4020-8020-202020202020")!,
      key: .socialEnergy,
      value: .ambiverted,
      sourceTurnIDs: [unknown]
    )
    let draft = ChatMeetupReflectionDraft(expectedVersion: 0, candidates: [candidate])
    XCTAssertThrowsError(try ChatMeetupReflectionDraft.validate(draft, sourceTurnIDs: [source]))

    let valid = ChatMeetupReflectionDraftCandidate(
      id: UUID(uuidString: "21212121-2121-4121-8121-212121212121")!,
      key: .favoriteActivity,
      value: .outdoors,
      sourceTurnIDs: [source]
    )
    try ChatMeetupReflectionDraft.validate(
      ChatMeetupReflectionDraft(expectedVersion: 0, candidates: [valid]),
      sourceTurnIDs: [source]
    )
  }

  func testWardConversationResponseIsRoomBoundAndUsesWardOnlyProjection() throws {
    let payload = try APIResponseDecoder.decode(
      Data(#"{"data":{"room_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","events":[{"id":"22222222-2222-4222-8222-222222222222","kind":"ward","speaker":"my_ward","text":"A quiet café could suit the pace.","round":1,"created_at":"2026-09-26T10:00:00Z"}],"next_cursor":null,"has_more":false}}"#.utf8),
      as: ChatMeetupWardConversationPayload.self
    )
    XCTAssertEqual(payload.roomID, roomID)
    XCTAssertEqual(payload.events.count, 1)
    XCTAssertEqual(payload.events[0].speaker, .myWard)
    XCTAssertThrowsError(try ChatMeetupWardConversationPayload.validate(
      ChatMeetupWardConversationPayload(roomID: roomID, events: [], nextCursor: nil, hasMore: true)
    ))
    XCTAssertThrowsError(try ChatMeetupWardConversationEvent.validate(
      ChatMeetupWardConversationEvent(
        id: UUID(),
        speaker: .partnerWard,
        text: " ",
        round: 1,
        createdAt: Date()
      )
    ))
  }

  func testCafeCandidateKeepsLegacyPayloadsAndGoogleAttributionTransient() throws {
    let legacy = try JSONDecoder().decode(
      ChatMeetupCafeCandidate.self,
      from: Data(#"{"id":"legacy-cafe-id","name":"Legacy café","address":"1 Test Lane","starts_at":"2026-09-30T09:00:00Z","ends_at":"2026-09-30T10:00:00Z","travel_minutes_first":14,"travel_minutes_second":18}"#.utf8)
    )
    try ChatMeetupCafeCandidate.validate(legacy)
    XCTAssertNil(legacy.googleMapsAttributionLabel)
    XCTAssertNil(legacy.googleMapsURL)
    XCTAssertEqual(legacy.travelTimeSummary(ja: false), "14 / 18 min")

    // Explicit mock contract fixture only; this does not represent a live Places result.
    let mockGoogle = try JSONDecoder().decode(
      ChatMeetupCafeCandidate.self,
      from: Data(#"{"id":"mock-google-place-id","name":"Mock café","address":"1 Test Lane","starts_at":"2026-09-30T09:00:00Z","ends_at":"2026-09-30T10:00:00Z","travel_minutes_first":null,"travel_minutes_second":null,"source":"google","google_maps_uri":"https://maps.google.com/?cid=12345","attributions":[{"provider":"Mock public data provider","provider_uri":"https://provider.example.com/place"}]}"#.utf8)
    )
    try ChatMeetupCafeCandidate.validate(mockGoogle)
    XCTAssertEqual(mockGoogle.googleMapsAttributionLabel, "Google Maps")
    XCTAssertEqual(mockGoogle.googleMapsURL?.host, "maps.google.com")
    XCTAssertNil(mockGoogle.travelTimeSummary(ja: false))
    XCTAssertEqual(mockGoogle.attributions?.first?.provider, "Mock public data provider")
    XCTAssertEqual(mockGoogle.attributions?.first?.safeProviderURL?.host, "provider.example.com")

    let unsafeMapCandidate = ChatMeetupCafeCandidate(
      id: "mock-google-place-id",
      name: "Mock café",
      address: "1 Test Lane",
      startsAt: mockGoogle.startsAt,
      endsAt: mockGoogle.endsAt,
      travelMinutesFirst: nil,
      travelMinutesSecond: nil,
      source: "google",
      googleMapsURI: "https://maps.google.com.evil.test/maps/place"
    )
    XCTAssertEqual(unsafeMapCandidate.googleMapsAttributionLabel, "Google Maps")
    XCTAssertNil(unsafeMapCandidate.googleMapsURL)
  }

  func testCafeAttributionLinksRejectUnsafeSchemesHostsAndRedirectPaths() {
    XCTAssertNotNil(ChatMeetupCafeLinks.googleMapsURL(from: "https://maps.google.com/?cid=123"))
    XCTAssertNotNil(ChatMeetupCafeLinks.googleMapsURL(from: "https://www.google.com/maps/place/example"))
    let unsafeMapURLs = [
      "http://maps.google.com/?cid=123",
      "https://maps.google.com.evil.test/maps/place/example",
      "https://www.google.com/url?q=https%3A%2F%2Fevil.test",
      "https://www.google.com/search?q=mock+cafe",
      "https://maps.google.com@evil.test/maps",
      "https://user@maps.google.com/maps",
      "https://maps.google.com:443/maps",
      "https://maps.google.com/maps#fragment",
      "javascript:alert(1)",
    ]
    for value in unsafeMapURLs {
      XCTAssertNil(ChatMeetupCafeLinks.googleMapsURL(from: value), value)
    }

    XCTAssertNotNil(ChatMeetupCafeLinks.httpsURL(from: "https://provider.example.com/place"))
    let unsafeProviderURLs = [
      "http://provider.example.com/place",
      "javascript:alert(1)",
      "https://user:secret@provider.example.com/place",
      "https://provider.example.com:8443/place",
      " https://provider.example.com/place",
      "https://localhost/place",
      "https://service.local/place",
      "https://service.internal/place",
      "https://service.example/place",
      "https://service.test/place",
      "https://127.0.0.1/place",
      "https://10.1.2.3/place",
      "https://169.254.169.254/place",
      "https://192.168.1.20/place",
      "https://172.16.0.1/place",
      "https://172.31.255.254/place",
      "https://[::1]/place",
      "https://2130706433/place",
    ]
    for value in unsafeProviderURLs {
      XCTAssertNil(ChatMeetupCafeLinks.httpsURL(from: value), value)
    }
  }

  func testTimeOnlyConfirmedPlanDecodesWithoutVenueFieldsAndPreservesPermissions() throws {
    let plan = [
      "starts_at": "2026-10-01T00:00:00Z",
      "ends_at": "2026-10-01T01:00:00Z",
    ]
    let envelope = try JSONSerialization.jsonObject(with: chatMeetupEnvelope(
      privateRevision: 2, status: "confirmed", confirmedPlan: plan
    )) as! [String: Any]
    var stateJSON = try XCTUnwrap(envelope["data"] as? [String: Any])
    for key in ["cafe_candidates", "cafe_details_unavailable", "needs_location"] {
      stateJSON.removeValue(forKey: key)
    }
    var permissions = try XCTUnwrap(stateJSON["own_permissions"] as? [String: Any])
    permissions.removeValue(forKey: "cafe_connected")
    permissions["can_complete"] = false
    stateJSON["own_permissions"] = permissions
    var decisions = try XCTUnwrap(stateJSON["own_decisions"] as? [String: Any])
    decisions.removeValue(forKey: "cafe_candidate_id")
    stateJSON["own_decisions"] = decisions
    let state = try APIResponseDecoder.decode(
      JSONSerialization.data(withJSONObject: ["data": stateJSON]), as: ChatMeetupState.self
    )
    XCTAssertEqual(state.status, .confirmed)
    XCTAssertEqual(state.ownDecisions.privateRevision, 2)
    XCTAssertFalse(state.ownPermissions.canComplete)
    XCTAssertFalse(state.needsLocation)
    XCTAssertTrue(state.cafeCandidates.isEmpty)
    XCTAssertNil(state.confirmedPlan?.cafeCandidateID)
    XCTAssertTrue(try XCTUnwrap(state.confirmedPlan).timeSummary(ja: false).hasPrefix("Confirmed time:"))
    XCTAssertEqual(try XCTUnwrap(state.confirmedPlan).endsAt.timeIntervalSince(state.confirmedPlan!.startsAt), 3600)
    var invalidPlan = plan
    invalidPlan["ends_at"] = plan["starts_at"]
    stateJSON["confirmed_plan"] = invalidPlan
    XCTAssertThrowsError(try APIResponseDecoder.decode(
      JSONSerialization.data(withJSONObject: ["data": stateJSON]), as: ChatMeetupState.self
    ))
  }

  func testConfirmedPlanSurvivesUnavailableCafeHydrationAndLegacyDefaults() throws {
    let plan = [
      "starts_at": "2026-09-30T09:00:00Z",
      "ends_at": "2026-09-30T10:00:00Z",
      "cafe_candidate_id": "mock-google-place-id",
    ]
    let unavailable = try APIResponseDecoder.decode(
      chatMeetupEnvelope(
        privateRevision: 0,
        status: "confirmed",
        confirmedPlan: plan,
        cafeDetailsUnavailable: true
      ),
      as: ChatMeetupState.self
    )
    XCTAssertTrue(unavailable.cafeDetailsUnavailable)
    XCTAssertTrue(unavailable.cafeCandidates.isEmpty)
    XCTAssertEqual(unavailable.confirmedPlan?.cafeCandidateID, "mock-google-place-id")
    XCTAssertEqual(
      try XCTUnwrap(unavailable.confirmedPlan).startsAt,
      try APIDTOValidation.requireRFC3339("2026-09-30T09:00:00Z")
    )
    XCTAssertLessThan(
      try XCTUnwrap(unavailable.confirmedPlan).startsAt,
      try XCTUnwrap(unavailable.confirmedPlan).endsAt
    )

    let legacy = try APIResponseDecoder.decode(
      chatMeetupEnvelope(privateRevision: 0, status: "idle"),
      as: ChatMeetupState.self
    )
    XCTAssertFalse(legacy.cafeDetailsUnavailable)
    XCTAssertNil(legacy.confirmedPlan)
  }

  func testSyntheticTestAdmissionDisclosesNoIdentityVerificationWithoutGrantingPermissions() throws {
    let legacy = try APIResponseDecoder.decode(
      chatMeetupEnvelope(privateRevision: 0, status: "idle"),
      as: ChatMeetupState.self
    )
    let admission: [String: Any] = [
      "kind": "fictional-demo",
      "pair": "demo-maya-ren",
      "identity_verified": false,
      "expires_at": "2026-09-30T12:00:00Z",
    ]
    let state = try APIResponseDecoder.decode(
      chatMeetupEnvelope(privateRevision: 0, status: "idle", syntheticTestAdmission: admission),
      as: ChatMeetupState.self
    )
    try ChatMeetupState.validate(state)
    let disclosure = try XCTUnwrap(state.syntheticTestAdmission)
    XCTAssertNil(legacy.syntheticTestAdmission)
    XCTAssertFalse(disclosure.identityVerified)
    XCTAssertEqual(disclosure.expiresAt, try APIDTOValidation.requireRFC3339("2026-09-30T12:00:00Z"))
    XCTAssertEqual(disclosure.disclosureText(japanese: false), "Fictional demo — identity verification not performed")
    XCTAssertEqual(disclosure.disclosureText(japanese: true), "架空ユーザーのデモ — 本人確認は行っていません")
    XCTAssertEqual(state.ownPermissions, legacy.ownPermissions)
    XCTAssertFalse(state.ownPermissions.canSchedule)
    XCTAssertFalse(state.ownPermissions.canComplete)
  }

  func testSyntheticTestAdmissionRejectsVerifiedClaimsUnknownScopeAndInvalidExpiry() throws {
    let admission: [String: Any] = [
      "kind": "fictional-demo",
      "pair": "demo-maya-ren",
      "identity_verified": false,
      "expires_at": "2026-09-30T12:00:00Z",
    ]
    for (key, invalidValue) in [
      ("kind", "verified" as Any),
      ("pair", "other-pair" as Any),
      ("identity_verified", true as Any),
      ("identity_verified", "false" as Any),
      ("expires_at", "invalid" as Any),
      ("expires_at", NSNull() as Any),
    ] {
      var invalidAdmission = admission
      invalidAdmission[key] = invalidValue
      XCTAssertThrowsError(try APIResponseDecoder.decode(
        chatMeetupEnvelope(privateRevision: 0, status: "idle", syntheticTestAdmission: invalidAdmission),
        as: ChatMeetupState.self
      ), "The display-only admission must reject \(key).")
    }
  }

  func testChatMeetupCancelClearsTransientCafeProviderContent() async throws {
    // Explicit mock DTO fixture only; no live provider call or proof is involved.
    let candidate = try JSONDecoder().decode(
      ChatMeetupCafeCandidate.self,
      from: Data(#"{"id":"mock-google-place-id","name":"Mock café","address":"1 Test Lane","starts_at":"2026-09-30T09:00:00Z","ends_at":"2026-09-30T10:00:00Z","travel_minutes_first":null,"travel_minutes_second":null,"source":"google","google_maps_uri":"https://maps.google.com/?cid=12345"}"#.utf8)
    )
    let api = ChatMeetupStoreTestAPI(
      state: testMeetupState(roomID: roomID, status: .confirmed, cafeCandidates: [candidate])
    )
    let store = ChatMeetupStore(ownerID: ownerID.uuidString, roomID: roomID, api: api)

    await store.load().value
    XCTAssertEqual(store.state?.cafeCandidates.first?.googleMapsAttributionLabel, "Google Maps")

    store.cancel()

    XCTAssertNil(store.state)
  }

  func testStaleCalendarConsentAfterRefreshCannotSubmitAvailability() async {
    let api = ChatMeetupStoreTestAPI(state: testMeetupState(roomID: roomID, status: .awaitingAvailability))
    let provider = PausedChatCalendarProvider()
    let store = ChatMeetupStore(ownerID: ownerID.uuidString, roomID: roomID, api: api, calendarProvider: provider)
    await store.load().value
    let now = Date()
    let window = MeetupAvailability(startsAt: now.addingTimeInterval(3_600), endsAt: now.addingTimeInterval(86_400))
    let pendingShare = Task { await store.shareCalendarAvailability(window: window) }

    let accessStarted = await provider.waitForRequest()
    XCTAssertTrue(accessStarted)
    await store.refresh()
    provider.resolveAccess(.granted)
    await pendingShare.value

    let actions = await api.performedActions()
    XCTAssertTrue(actions.isEmpty, "A provider result from an older card generation must not submit.")
    XCTAssertGreaterThan(provider.revokeCount, 0)
  }

  func testStaleLocationConsentAfterRefreshCannotSubmitLocation() async throws {
    let initial = testMeetupState(roomID: roomID, status: .awaitingLocation, needsLocation: true)
    let api = ChatMeetupStoreTestAPI(state: initial)
    let provider = PausedChatMeetupLocationProvider()
    let store = ChatMeetupStore(ownerID: ownerID.uuidString, roomID: roomID, api: api, locationProvider: provider)
    await store.load().value
    let pendingCapture = Task { await store.submitCurrentLocation() }

    let captureStarted = await provider.waitForCapture()
    XCTAssertTrue(captureStarted)
    await store.refresh()
    let now = Date()
    let consent = try NativeLocationConsentPayload(
      station: "Tokyo",
      latitude: nil,
      longitude: nil,
      nearestStation: nil,
      capturedAt: now,
      expiresAt: now.addingTimeInterval(300)
    )
    provider.resolveCapture(consent)
    await pendingCapture.value

    let actions = await api.performedActions()
    XCTAssertTrue(actions.isEmpty, "A stale consent result must not submit a new private location.")
    XCTAssertGreaterThan(provider.revokeCount, 0)
  }

  func testChatMeetupStoreKeepsIntentOwnerPrivateAndRefreshesStaleState() async {
    let initial = testMeetupState(roomID: roomID)
    let api = ChatMeetupStoreTestAPI(state: initial)
    let store = ChatMeetupStore(ownerID: ownerID.uuidString, roomID: roomID, api: api)
    await store.load().value
    await store.perform(.intent(.yes))

    XCTAssertEqual(store.state?.revision, 0)
    XCTAssertEqual(store.state?.events, [])
    XCTAssertEqual(store.state?.ownDecisions.intentValue, .yes)
    XCTAssertEqual(store.state?.ownDecisions.privateRevision, 1)

    let newRoomState = testMeetupState(roomID: roomID, revision: 1, status: .awaitingAvailability)
    await api.setStaleState(newRoomState)
    await store.perform(.manualAvailability(
      window: MeetupAvailability(startsAt: Date().addingTimeInterval(3_600), endsAt: Date().addingTimeInterval(86_400)),
      available: [MeetupAvailability(startsAt: Date().addingTimeInterval(7_200), endsAt: Date().addingTimeInterval(10_800))]
    ))
    XCTAssertEqual(store.state?.revision, 1)
    XCTAssertTrue(store.noticeMessage?.contains("meetup changed") == true)
    XCTAssertNil(store.errorMessage)

    let reopened = ChatMeetupStore(ownerID: ownerID.uuidString, roomID: roomID, api: api)
    await reopened.load().value
    XCTAssertEqual(reopened.state?.revision, 1, "A new view restores the server-owned state.")
  }

  func testJudgeAcceptanceRecoveryOnlyAdvancesOwnersOutgoingMarkedRequest() async {
    for (simulated, requester) in [(true, ownerID), (false, ownerID), (true, partnerID)] {
      let api = PendingJudgeRequestAPI(matchID: matchID, roomID: roomID,
        requesterID: requester, responderID: requester == ownerID ? partnerID : ownerID,
        simulatedCounterpart: simulated)
      let store = ChatRequestsStore(ownerID: ownerID.uuidString, api: api)
      await store.loadRequestState(matchID: matchID).value
      let count = await api.advanceCount()
      if simulated && requester == ownerID {
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.requestState?.status, .accepted)
        XCTAssertEqual(store.lastAcceptedRoomID, roomID)
      } else {
        XCTAssertEqual(count, 0)
        XCTAssertEqual(store.requestState?.status, .pending)
        XCTAssertNil(store.lastAcceptedRoomID)
      }
    }
  }

  func testJudgeCounterpartMetadataRequiresExactBoundPair() throws {
    let legacy = try APIResponseDecoder.decode(chatMeetupEnvelope(privateRevision: 0, status: "idle"), as: ChatMeetupState.self)
    XCTAssertFalse(legacy.simulatedCounterpart)
    XCTAssertNil(legacy.judgeMatchID)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: chatMeetupEnvelope(privateRevision: 0, status: "idle")) as? [String: Any])
    var data = try XCTUnwrap(json["data"] as? [String: Any])
    data["simulated_counterpart"] = true
    json["data"] = data
    XCTAssertThrowsError(try APIResponseDecoder.decode(JSONSerialization.data(withJSONObject: json), as: ChatMeetupState.self))
    data["judge_match_id"] = matchID.uuidString
    json["data"] = data
    let bound = try APIResponseDecoder.decode(JSONSerialization.data(withJSONObject: json), as: ChatMeetupState.self)
    XCTAssertEqual(bound.judgeMatchID, matchID)
  }

  func testJudgeCounterpartAdvancesOnlyAfterOwnIntentAndRetriesSamePeerAction() async {
    let initial = testMeetupState(roomID: roomID, simulatedCounterpart: true, judgeMatchID: matchID)
    let api = ChatMeetupStoreTestAPI(state: initial)
    await api.failNextCounterpart()
    let store = ChatMeetupStore(ownerID: ownerID.uuidString, roomID: roomID, api: api)
    await store.load().value
    let before = await api.counterpartCalls()
    XCTAssertTrue(before.isEmpty)
    await store.perform(.intent(.yes))
    XCTAssertNotNil(store.errorMessage)
    await store.retryPendingAction()
    XCTAssertNil(store.errorMessage)
    let own = await api.performedActions()
    let calls = await api.counterpartCalls()
    XCTAssertEqual(own, [.intent(.yes)])
    XCTAssertEqual(calls.count, 2)
    XCTAssertEqual(calls.map { $0.0 }, [.intent, .intent])
    XCTAssertEqual(calls.first?.1, calls.last?.1)
  }

  func testOrdinaryMeetupNeverRunsJudgeCounterpartOrSimulation() async {
    let api = ChatMeetupStoreTestAPI(state: testMeetupState(roomID: roomID))
    let store = ChatMeetupStore(ownerID: ownerID.uuidString, roomID: roomID, api: api)
    await store.load().value
    await store.perform(.intent(.yes))
    await store.simulateMeeting()
    let calls = await api.counterpartCalls()
    XCTAssertTrue(calls.isEmpty)
  }

  func testJudgeSimulatedCompletionRequiresExplicitConfirmedAction() async {
    let api = ChatMeetupStoreTestAPI(state: testMeetupState(roomID: roomID, status: .confirmed,
      simulatedCounterpart: true, judgeMatchID: matchID))
    let store = ChatMeetupStore(ownerID: ownerID.uuidString, roomID: roomID, api: api)
    await store.load().value
    let before = await api.counterpartCalls()
    XCTAssertTrue(before.isEmpty)
    await store.simulateMeeting()
    let after = await api.counterpartCalls()
    XCTAssertEqual(after.map { $0.0 }, [.simulateCompletion])
    XCTAssertEqual(store.noticeMessage, "Simulated meetup completed. No real meeting took place.")
  }

  private func chatMeetupEnvelope(
    privateRevision: Int,
    status: String,
    intent: String? = nil,
    confirmedPlan: [String: Any]? = nil,
    cafeDetailsUnavailable: Bool? = nil,
    syntheticTestAdmission: [String: Any]? = nil
  ) -> Data {
    var value: [String: Any] = [
      "room_id": roomID.uuidString.lowercased(),
      "meetup_id": NSNull(),
      "revision": 0,
      "status": status,
      "events": [],
      "time_candidates": [],
      "cafe_candidates": [],
      "own_permissions": [
        "can_intent": true,
        "can_schedule": status == "awaiting_availability",
        "can_replan": false,
        "can_cancel": false,
        "can_complete": false,
        "calendar_connected": false,
        "cafe_connected": false
      ],
      "own_decisions": [
        "intent_value": intent as Any? ?? NSNull(),
        "time_candidate_id": NSNull(),
        "cafe_candidate_id": NSNull(),
        "completed": false,
        "private_revision": privateRevision
      ],
      "needs_location": false,
      "expires_at": NSNull(),
      "unavailable_reason": NSNull()
    ]
    if let confirmedPlan { value["confirmed_plan"] = confirmedPlan }
    if let cafeDetailsUnavailable { value["cafe_details_unavailable"] = cafeDetailsUnavailable }
    if let syntheticTestAdmission { value["synthetic_test_admission"] = syntheticTestAdmission }
    return try! JSONSerialization.data(withJSONObject: ["data": value])
  }

  private func testMeetupState(
    roomID: UUID,
    revision: Int = 0,
    status: ChatMeetupStatus = .idle,
    needsLocation: Bool = false,
    cafeCandidates: [ChatMeetupCafeCandidate] = [],
    confirmedPlan: ChatMeetupConfirmedPlan? = nil,
    cafeDetailsUnavailable: Bool = false,
    simulatedCounterpart: Bool = false,
    judgeMatchID: UUID? = nil
  ) -> ChatMeetupState {
    ChatMeetupState(
      roomID: roomID,
      meetupID: nil,
      revision: revision,
      status: status,
      events: [],
      timeCandidates: [],
      cafeCandidates: cafeCandidates,
      ownPermissions: ChatMeetupOwnPermissions(
        canIntent: true,
        canSchedule: true,
        canReplan: false,
        canCancel: false,
        canComplete: false,
        calendarConnected: false,
        cafeConnected: false
      ),
      ownDecisions: ChatMeetupOwnDecisions(
        intentValue: nil,
        timeCandidateID: nil,
        cafeCandidateID: nil,
        completed: false
      ),
      needsLocation: needsLocation,
      confirmedPlan: confirmedPlan,
      cafeDetailsUnavailable: cafeDetailsUnavailable,
      simulatedCounterpart: simulatedCounterpart,
      judgeMatchID: judgeMatchID
    )
  }

  private func waitForRequestStateFetchCount(
    _ expectedCount: Int,
    api: DirectChatsTestAPI
  ) async -> Bool {
    for _ in 0..<200 {
      if await api.requestStateFetchCount() >= expectedCount { return true }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
  }

  private struct TestDirectChatListPayload: Decodable, Sendable, APIValidatable {
    let chats: [DirectChatSummary]

    init(from decoder: Decoder) throws {
      chats = try decoder.singleValueContainer().decode([DirectChatSummary].self)
    }

    static func validate(_ value: TestDirectChatListPayload) throws {
      for chat in value.chats { try DirectChatSummary.validate(chat) }
    }
  }
}


private actor PendingJudgeRequestAPI: DirectChatsAPI {
  private var request: ChatRequestMatchState
  private let roomID: UUID
  private var advances = 0
  init(matchID: UUID, roomID: UUID, requesterID: UUID, responderID: UUID, simulatedCounterpart: Bool) {
    self.roomID = roomID
    request = ChatRequestMatchState(id: UUID(), matchID: matchID, requesterID: requesterID,
      responderID: responderID, status: .pending, expiresAt: Date().addingTimeInterval(60),
      simulatedCounterpart: simulatedCounterpart)
  }
  func advanceCount() -> Int { advances }
  func fetchChatRequestState(matchID: UUID) async throws -> ChatRequestMatchState? { request }
  func advanceJudgeCounterpart(matchID: UUID, operation: JudgeCounterpartOperation, expectedRevision: Int, idempotencyKey: UUID) async throws -> JudgeCounterpartAdvanceResult {
    guard operation == .accept, expectedRevision == 0, idempotencyKey == request.id else { throw APIClientError.invalidRequest }
    advances += 1
    request = ChatRequestMatchState(id: request.id, matchID: request.matchID, requesterID: request.requesterID,
      responderID: request.responderID, status: .accepted, expiresAt: request.expiresAt,
      simulatedCounterpart: request.simulatedCounterpart)
    return JudgeCounterpartAdvanceResult(outcome: "ok", matchID: matchID, roomID: roomID,
      meetupID: nil, status: "accepted", revision: 0)
  }
  func fetchDirectChats() async throws -> [DirectChatSummary] { [] }
  func fetchDirectMessages(roomID: UUID, limit: Int, cursor: String?) async throws -> DirectChatMessagesPayload { DirectChatMessagesPayload(messages: []) }
  func sendDirectMessage(roomID: UUID, content: String) async throws -> DirectChatSendResult { throw APIClientError.invalidState }
  func markDirectMessageRead(roomID: UUID, messageID: UUID) async throws -> DirectChatReadResult { throw APIClientError.invalidState }
  func fetchChatRequests() async throws -> [ChatRequestSummary] { [] }
  func createChatRequest(matchID: UUID) async throws -> ChatRequestCreateResult { throw APIClientError.invalidState }
  func respondToChatRequest(requestID: UUID, action: ChatRequestAction) async throws -> ChatRequestDecisionResult { throw APIClientError.invalidState }
}

private actor ChatMeetupStoreTestAPI: DirectChatsAPI {
  private var state: ChatMeetupState
  private var staleState: ChatMeetupState?
  private var actions: [ChatMeetupAction] = []
  private var counterpart: [(JudgeCounterpartOperation, UUID)] = []
  private var failCounterpart = false

  init(state: ChatMeetupState) { self.state = state }

  func setStaleState(_ value: ChatMeetupState) { staleState = value }
  func performedActions() -> [ChatMeetupAction] { actions }
  func failNextCounterpart() { failCounterpart = true }
  func counterpartCalls() -> [(JudgeCounterpartOperation, UUID)] { counterpart }
  func advanceJudgeCounterpart(matchID: UUID, operation: JudgeCounterpartOperation, expectedRevision: Int, idempotencyKey: UUID) async throws -> JudgeCounterpartAdvanceResult {
    counterpart.append((operation, idempotencyKey))
    if failCounterpart { failCounterpart = false; throw APIClientError.temporarilyUnavailable }
    return JudgeCounterpartAdvanceResult(outcome: "ok", matchID: matchID, roomID: state.roomID,
      meetupID: state.meetupID, status: state.status.rawValue, revision: state.revision)
  }

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

  func fetchChatMeetup(roomID: UUID) async throws -> ChatMeetupState {
    guard roomID == state.roomID else { throw APIClientError.notFound }
    return state
  }

  func performChatMeetupAction(
    roomID: UUID,
    expectedRevision: Int,
    expectedOwnRevision: Int,
    action: ChatMeetupAction,
    idempotencyKey: UUID
  ) async throws -> ChatMeetupState {
    guard roomID == state.roomID else { throw APIClientError.notFound }
    if let staleState {
      state = staleState
      self.staleState = nil
      throw APIClientError.invalidState
    }
    guard state.revision == expectedRevision,
      state.ownDecisions.privateRevision == expectedOwnRevision
    else { throw APIClientError.invalidState }
    actions.append(action)
    if case .intent(.yes) = action {
      state = ChatMeetupState(
        roomID: state.roomID,
        meetupID: state.meetupID,
        revision: state.revision,
        status: .awaitingAvailability,
        events: state.events,
        timeCandidates: state.timeCandidates,
        cafeCandidates: state.cafeCandidates,
        ownPermissions: state.ownPermissions,
        ownDecisions: ChatMeetupOwnDecisions(
          intentValue: .yes,
          timeCandidateID: state.ownDecisions.timeCandidateID,
          cafeCandidateID: state.ownDecisions.cafeCandidateID,
          completed: state.ownDecisions.completed,
          privateRevision: state.ownDecisions.privateRevision + 1
        ),
        needsLocation: state.needsLocation,
        simulatedCounterpart: state.simulatedCounterpart,
        judgeMatchID: state.judgeMatchID
      )
    }
    return state
  }
}

private final class PausedChatCalendarProvider: NativeBusyCalendarProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var accessContinuation: CheckedContinuation<NativeCalendarAuthorization, Never>?
  private var requestStarted = false
  private var revokeTotal = 0

  func requestAccess(userConfirmedSharing: Bool) async -> NativeCalendarAuthorization {
    guard userConfirmedSharing else { return .notRequested }
    return await withCheckedContinuation { continuation in
      lock.lock()
      accessContinuation = continuation
      requestStarted = true
      lock.unlock()
    }
  }

  func readBusy(window: MeetupAvailability) async throws -> NativeBusyCalendarPayload {
    NativeBusyCalendarPayload(window: window, busy: [])
  }

  func revoke() {
    lock.lock()
    revokeTotal += 1
    lock.unlock()
  }

  func wasRequested() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return requestStarted
  }

  func waitForRequest() async -> Bool {
    for _ in 0..<200 {
      if wasRequested() { return true }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
  }

  func resolveAccess(_ result: NativeCalendarAuthorization) {
    lock.lock()
    let continuation = accessContinuation
    accessContinuation = nil
    lock.unlock()
    continuation?.resume(returning: result)
  }

  var revokeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return revokeTotal
  }
}

private final class PausedChatMeetupLocationProvider: NativeMeetupLocationProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var captureContinuation: CheckedContinuation<NativeLocationConsentPayload, Error>?
  private var captureStarted = false
  private var revokeTotal = 0

  func capture(afterUserConsent: Bool) async throws -> NativeLocationConsentPayload {
    guard afterUserConsent else { throw NativeLocationPrivacyError.consentRequired }
    return try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      captureContinuation = continuation
      captureStarted = true
      lock.unlock()
    }
  }

  func revoke() {
    lock.lock()
    revokeTotal += 1
    lock.unlock()
  }

  func wasCaptureStarted() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return captureStarted
  }

  func waitForCapture() async -> Bool {
    for _ in 0..<200 {
      if wasCaptureStarted() { return true }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
  }

  func resolveCapture(_ payload: NativeLocationConsentPayload) {
    lock.lock()
    let continuation = captureContinuation
    captureContinuation = nil
    lock.unlock()
    continuation?.resume(returning: payload)
  }

  var revokeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return revokeTotal
  }
}

private actor DirectChatsTestAPI: DirectChatsAPI {
  let ownerID: UUID
  let roomID: UUID
  let partnerID: UUID
  let matchID: UUID
  private let messageID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
  let delayNanoseconds: UInt64
  private var sendError: APIClientError?
  private var loseResponseAfterCommit: Bool
  private var persistedByKey: [UUID: DirectChatSendResult] = [:]
  private var sentIdempotencyKeys: [UUID] = []
  private var sentContent: [String] = []
  private var sends = 0
  private var directChatFetches = 0
  private var messageFetches = 0
  private var requestFetches = 0
  private let suspendsRequestStateFetches: Bool
  private var requestStateFetches = 0
  private var recoveryLookups = 0
  private let suspendFirstSendBeforeCommit: Bool
  private var firstSendIsSuspended = false
  private var firstSendContinuation: CheckedContinuation<Void, Never>?
  private var requestStateContinuations: [UUID: CheckedContinuation<ChatRequestMatchState?, Never>] = [:]

  init(
    ownerID: UUID,
    roomID: UUID,
    partnerID: UUID,
    matchID: UUID,
    sendError: APIClientError? = nil,
    delayNanoseconds: UInt64 = 0,
    suspendsRequestStateFetches: Bool = false,
    loseResponseAfterCommit: Bool = false,
    suspendFirstSendBeforeCommit: Bool = false
  ) {
    self.ownerID = ownerID
    self.roomID = roomID
    self.partnerID = partnerID
    self.matchID = matchID
    self.sendError = sendError
    self.delayNanoseconds = delayNanoseconds
    self.suspendsRequestStateFetches = suspendsRequestStateFetches
    self.loseResponseAfterCommit = loseResponseAfterCommit
    self.suspendFirstSendBeforeCommit = suspendFirstSendBeforeCommit
  }

  func fetchDirectChats() async throws -> [DirectChatSummary] {
    directChatFetches += 1
    return [DirectChatSummary(
      id: roomID,
      matchID: matchID,
      partner: DirectChatPartner(nickname: "Aoi"),
      lastMessage: nil,
      unreadCount: 0,
      unreadCountAfterSeen: 0
    )]
  }

  func fetchDirectMessages(roomID: UUID, limit: Int, cursor: String?) async throws -> DirectChatMessagesPayload {
    messageFetches += 1
    return DirectChatMessagesPayload(messages: [
      DirectChatMessage(
        id: messageID,
        senderID: partnerID,
        isMine: false,
        content: "Welcome.",
        isRead: false,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
      )
    ])
  }

  func sendDirectMessage(roomID: UUID, content: String) async throws -> DirectChatSendResult {
    try await sendDirectMessage(roomID: roomID, content: content, idempotencyKey: UUID())
  }

  func sendDirectMessage(
    roomID: UUID,
    content: String,
    idempotencyKey: UUID
  ) async throws -> DirectChatSendResult {
    sends += 1
    sentIdempotencyKeys.append(idempotencyKey)
    sentContent.append(content)
    if suspendFirstSendBeforeCommit && sends == 1 {
      await withCheckedContinuation { continuation in
        firstSendContinuation = continuation
        firstSendIsSuspended = true
      }
    }
    if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
    if let sendError { throw sendError }
    if let existing = persistedByKey[idempotencyKey] {
      guard existing.content == content else { throw APIClientError.invalidRequest }
      return existing
    }
    let result = DirectChatSendResult(
      id: UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!,
      content: content,
      createdAt: Date(timeIntervalSince1970: 1_700_000_060)
    )
    persistedByKey[idempotencyKey] = result
    if loseResponseAfterCommit {
      loseResponseAfterCommit = false
      throw APIClientError.temporarilyUnavailable
    }
    return result
  }

  func recoverDirectMessageSend(
    roomID: UUID,
    idempotencyKey: UUID,
    contentSHA256: String
  ) async throws -> DirectChatSendRecoveryResult {
    recoveryLookups += 1
    guard let message = persistedByKey[idempotencyKey] else {
      return DirectChatSendRecoveryResult(outcome: .notFound, message: nil)
    }
    guard MessageSendRetryReceipt.contentSHA256(for: message.content) == contentSHA256 else {
      return DirectChatSendRecoveryResult(outcome: .conflict, message: nil)
    }
    return DirectChatSendRecoveryResult(outcome: .found, message: message)
  }

  func markDirectMessageRead(roomID: UUID, messageID: UUID) async throws -> DirectChatReadResult {
    DirectChatReadResult(readCount: 1)
  }

  func fetchChatRequests() async throws -> [ChatRequestSummary] {
    requestFetches += 1
    return [ChatRequestSummary(
      id: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!,
      matchID: matchID,
      requesterID: partnerID,
      status: "pending",
      expiresAt: Date(timeIntervalSince1970: 1_700_100_000),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      requester: ChatRequestRequester(nickname: "Aoi")
    )]
  }

  func fetchChatRequestState(matchID: UUID) async throws -> ChatRequestMatchState? {
    requestStateFetches += 1
    if suspendsRequestStateFetches {
      return await withCheckedContinuation { continuation in
        requestStateContinuations[matchID] = continuation
      }
    }
    return makeRequestState(matchID: matchID)
  }

  private func makeRequestState(matchID: UUID) -> ChatRequestMatchState {
    ChatRequestMatchState(
      id: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!,
      matchID: matchID,
      requesterID: partnerID,
      responderID: ownerID,
      status: .pending,
      expiresAt: Date(timeIntervalSince1970: 1_700_100_000)
    )
  }

  func resolveRequestStateFetch(matchID: UUID) {
    requestStateContinuations.removeValue(forKey: matchID)?.resume(
      returning: makeRequestState(matchID: matchID)
    )
  }

  func requestStateFetchCount() -> Int { requestStateFetches }

  func createChatRequest(matchID: UUID) async throws -> ChatRequestCreateResult {
    ChatRequestCreateResult(
      id: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!,
      matchID: matchID,
      status: "pending",
      expiresAt: Date(timeIntervalSince1970: 1_700_100_000)
    )
  }

  func respondToChatRequest(
    requestID: UUID,
    action: ChatRequestAction
  ) async throws -> ChatRequestDecisionResult {
    ChatRequestDecisionResult(
      requestID: requestID,
      status: action == .accept ? "accepted" : "declined",
      directChatRoomID: action == .accept ? roomID : nil
    )
  }

  func sendCount() -> Int { sends }
  func recoveryLookupCount() -> Int { recoveryLookups }
  func persistedMessageCount() -> Int { persistedByKey.count }
  func sentKeys() -> [UUID] { sentIdempotencyKeys }
  func sentContents() -> [String] { sentContent }
  func readCounts() -> (directChats: Int, messages: Int, requests: Int) {
    (directChatFetches, messageFetches, requestFetches)
  }
  func clearSendError() { sendError = nil }
  func waitForFirstSendSuspension() async -> Bool {
    for _ in 0..<200 {
      if firstSendIsSuspended { return true }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return firstSendIsSuspended
  }
  func resumeFirstSend() {
    firstSendContinuation?.resume()
    firstSendContinuation = nil
  }
}

@MainActor
final class MemoryMessageSendRetryReceiptStore: MessageSendRetryReceiptStoring {
  private var receipts: [String: MessageSendRetryReceipt] = [:]

  func load(kind: MessageSendRetryReceiptKind, ownerID: UUID, conversationID: UUID) throws -> MessageSendRetryReceipt? {
    receipts[Self.key(kind: kind, ownerID: ownerID, conversationID: conversationID)]
  }

  func save(_ receipt: MessageSendRetryReceipt) throws {
    let key = Self.key(kind: receipt.kind, ownerID: receipt.ownerID, conversationID: receipt.conversationID)
    if let existing = receipts[key], existing != receipt { throw KeychainStorageError.invalidData }
    receipts[key] = receipt
  }

  func clear(kind: MessageSendRetryReceiptKind, ownerID: UUID, conversationID: UUID) throws {
    receipts.removeValue(forKey: Self.key(kind: kind, ownerID: ownerID, conversationID: conversationID))
  }

  private static func key(kind: MessageSendRetryReceiptKind, ownerID: UUID, conversationID: UUID) -> String {
    "\(kind.rawValue).\(ownerID.uuidString.lowercased()).\(conversationID.uuidString.lowercased())"
  }
}
