import Foundation
import XCTest
@testable import Wingward

@MainActor
final class PartnerWardWriteTests: XCTestCase {
  private let ownerID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
  private let partnerID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
  private let matchID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let chatID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

  func testStartAndSendDTOsDecodeTheExactServerShapes() throws {
    let start = try APIResponseDecoder.decode(
      Data(#"{"data":{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","match_id":"11111111-1111-4111-8111-111111111111","partner":{"nickname":"Aoi"},"first_message":{"id":"66666666-6666-4666-8666-666666666666","role":"fox","content":"Nice to meet you.","created_at":"2026-01-01T00:00:00Z"}}}"#.utf8),
      as: PartnerFoxChatStartResult.self
    )
    XCTAssertEqual(start.id, chatID)
    XCTAssertEqual(start.matchID, matchID)
    XCTAssertEqual(start.firstMessage.role, .fox)

    let send = try APIResponseDecoder.decode(
      Data(#"{"data":{"user_message":{"id":"77777777-7777-4777-8777-777777777777","role":"user","content":"hello","created_at":"2026-01-01T00:01:00Z"},"fox_message":{"id":"88888888-8888-4888-8888-888888888888","role":"fox","content":"Hello.","created_at":"2026-01-01T00:01:01Z"}}}"#.utf8),
      as: PartnerFoxMessageSendResult.self
    )
    XCTAssertEqual(send.userMessage.role, .user)
    XCTAssertEqual(send.foxMessage.role, .fox)
  }

  func testLivePartnerWritesUsePostBodiesAndNoAutomaticRetry() async throws {
    let client = FakeAuthenticatedAPIClient()
    let startRequest = APIRequest(
      method: .post,
      path: LiveMatchDetailAPI.partnerChatsPath,
      body: Data(#"{"match_id":"11111111-1111-4111-8111-111111111111"}"#.utf8)
    )
    let idempotencyKey = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    let sendRequest = APIRequest(
      method: .post,
      path: LiveMatchDetailAPI.partnerMessagesPath(for: chatID),
      body: Data(#"{"content":"hello","idempotency_key":"99999999-9999-4999-8999-999999999999"}"#.utf8)
    )
    let contentSHA256 = MessageSendRetryReceipt.contentSHA256(for: "hello")
    let recoveryRequest = APIRequest(
      method: .post,
      path: LiveMatchDetailAPI.partnerMessageSendRecoveryPath(chatID: chatID),
      body: Data(#"{"idempotency_key":"99999999-9999-4999-8999-999999999999","content_sha256":"\#(contentSHA256)"}"#.utf8)
    )
    await client.setResponseData(startResponse(), for: startRequest)
    await client.setResponseData(sendResponse(), for: sendRequest)
    await client.setResponseData(
      Data(#"{"data":{"outcome":"completed","user_message":{"id":"77777777-7777-4777-8777-777777777777","role":"user","content":"hello","created_at":"2026-01-01T00:01:00Z"},"fox_message":{"id":"88888888-8888-4888-8888-888888888888","role":"fox","content":"Hello.","created_at":"2026-01-01T00:01:01Z"}}}"#.utf8),
      for: recoveryRequest
    )
    let api = LiveMatchDetailAPI(client: client)

    _ = try await api.startPartnerChat(matchID: matchID)
    _ = try await api.sendPartnerMessage(
      chatID: chatID,
      content: "hello",
      idempotencyKey: idempotencyKey
    )
    let recovery = try await api.recoverPartnerMessageSend(
      chatID: chatID,
      idempotencyKey: idempotencyKey,
      contentSHA256: contentSHA256
    )
    XCTAssertEqual(recovery.outcome, .completed)

    let requests = await client.recordedRequests()
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(requests[0], startRequest)
    XCTAssertEqual(requests[1].method, sendRequest.method)
    XCTAssertEqual(requests[1].path, sendRequest.path)
    XCTAssertEqual(requests[1].contentType, sendRequest.contentType)
    let actualBody = try JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].body)) as? NSDictionary
    let expectedBody = try JSONSerialization.jsonObject(with: XCTUnwrap(sendRequest.body)) as? NSDictionary
    XCTAssertEqual(actualBody, expectedBody)
    XCTAssertEqual(requests[2].method, recoveryRequest.method)
    XCTAssertEqual(requests[2].path, recoveryRequest.path)
    let actualRecoveryBody = try JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].body)) as? NSDictionary
    let expectedRecoveryBody = try JSONSerialization.jsonObject(with: XCTUnwrap(recoveryRequest.body)) as? NSDictionary
    XCTAssertEqual(actualRecoveryBody, expectedRecoveryBody)
  }

  func testStoreAppendsOnlyTheReturnedPairAndExposesAnAcknowledgement() async {
    let api = PartnerWardWriteAPI(
      ownerID: ownerID,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID
    )
    let store = PartnerWardStore(
      ownerID: ownerID.uuidString,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      api: api,
      retryReceiptStore: MemoryMessageSendRetryReceiptStore()
    )

    await store.load().value
    await store.sendMessage("hello").value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.messages.count, 3)
    XCTAssertEqual(store.messages[1].content, "hello")
    XCTAssertEqual(store.messages[2].role, .fox)
    XCTAssertNotNil(store.lastSentMessageID)
    let sendCount = await api.sendCallCount()
    XCTAssertEqual(sendCount, 1)
  }

  func testPartnerResponseLossRetryReusesKeyAndContentWithoutGeneratingAgain() async {
    let api = PartnerWardWriteAPI(
      ownerID: ownerID,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      loseResponseAfterCommit: true
    )
    let store = PartnerWardStore(
      ownerID: ownerID.uuidString,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      api: api,
      retryReceiptStore: MemoryMessageSendRetryReceiptStore()
    )
    await store.load().value

    await store.sendMessage("hello").value
    XCTAssertEqual(store.sendError, .temporarilyUnavailable)
    await store.sendMessage("different text").value
    XCTAssertEqual(store.sendError, .unresolvedSend)
    let countBeforeRetry = await api.sendCallCount()
    XCTAssertEqual(countBeforeRetry, 1)
    await store.sendMessage("hello").value

    XCTAssertEqual(store.sendError, nil)
    let userMessageCount = await api.persistedUserMessageCount()
    let foxMessageCount = await api.persistedGeneratedFoxMessageCount()
    let generationCount = await api.generationCount()
    let sentKeys = await api.sentKeys()
    let sentContents = await api.sentContents()
    XCTAssertEqual(userMessageCount, 1)
    XCTAssertEqual(foxMessageCount, 1)
    XCTAssertEqual(generationCount, 1)
    XCTAssertEqual(sentKeys.count, 2)
    XCTAssertEqual(sentKeys[0], sentKeys[1])
    XCTAssertEqual(sentContents, ["hello", "hello"])
    XCTAssertEqual(store.messages.filter { $0.role == .user }.map(\.content), ["hello"])
  }

  func testPartnerStoresCreatedBeforeSendShareTheCommittedRetryReceipt() async throws {
    let api = PartnerWardWriteAPI(
      ownerID: ownerID,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      loseResponseAfterCommit: true
    )
    let receiptStore = MemoryMessageSendRetryReceiptStore()
    let firstStore = PartnerWardStore(
      ownerID: ownerID.uuidString,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      api: api,
      retryReceiptStore: receiptStore
    )
    let secondStore = PartnerWardStore(
      ownerID: ownerID.uuidString,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      api: api,
      retryReceiptStore: receiptStore
    )
    await firstStore.load().value
    await secondStore.load().value

    await firstStore.sendMessage("hello").value
    let receipt = try XCTUnwrap(try receiptStore.load(
      kind: .partnerWard,
      ownerID: ownerID,
      conversationID: chatID
    ))
    await secondStore.sendMessage("different text").value
    XCTAssertEqual(secondStore.sendError, .unresolvedSend)
    await secondStore.sendMessage("hello").value

    XCTAssertNil(secondStore.sendError)
    let sentKeys = await api.sentKeys()
    let userRows = await api.persistedUserMessageCount()
    let generatedRows = await api.persistedGeneratedFoxMessageCount()
    let generations = await api.generationCount()
    XCTAssertEqual(sentKeys, [receipt.idempotencyKey, receipt.idempotencyKey])
    XCTAssertEqual(userRows, 1)
    XCTAssertEqual(generatedRows, 1)
    XCTAssertEqual(generations, 1)
  }

  func testPartnerResponseLossRecoversAfterStoreRecreationWithOnePersistedPairAndGeneration() async throws {
    let api = PartnerWardWriteAPI(
      ownerID: ownerID,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      loseResponseAfterCommit: true
    )
    let receiptStore = MemoryMessageSendRetryReceiptStore()
    let firstStore = PartnerWardStore(
      ownerID: ownerID.uuidString,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      api: api,
      retryReceiptStore: receiptStore
    )
    await firstStore.load().value
    await firstStore.sendMessage("hello").value
    XCTAssertEqual(firstStore.sendError, .temporarilyUnavailable)

    let savedReceipt = try XCTUnwrap(try receiptStore.load(
      kind: .partnerWard,
      ownerID: ownerID,
      conversationID: chatID
    ))
    let restartedStore = PartnerWardStore(
      ownerID: ownerID.uuidString,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      api: api,
      retryReceiptStore: receiptStore
    )
    await restartedStore.load().value

    XCTAssertEqual(restartedStore.phase, .loaded)
    XCTAssertEqual(restartedStore.messages.filter { $0.role == .user }.map(\.content), ["hello"])
    XCTAssertEqual(restartedStore.messages.filter { $0.role == .fox && $0.content == "I hear you." }.count, 1)
    let sendCount = await api.sendCallCount()
    let userRowCount = await api.persistedUserMessageCount()
    let foxRowCount = await api.persistedGeneratedFoxMessageCount()
    let generationCount = await api.generationCount()
    let recoveryCount = await api.recoveryLookupCount()
    XCTAssertEqual(sendCount, 1)
    XCTAssertEqual(userRowCount, 1)
    XCTAssertEqual(foxRowCount, 1)
    XCTAssertEqual(generationCount, 1)
    XCTAssertEqual(recoveryCount, 1)
    XCTAssertNil(try receiptStore.load(kind: .partnerWard, ownerID: ownerID, conversationID: chatID))
    XCTAssertEqual(savedReceipt.contentSHA256, MessageSendRetryReceipt.contentSHA256(for: "hello"))
  }

  func testCompetingPartnerSendsCollapseToOneRequest() async {
    let api = PartnerWardWriteAPI(
      ownerID: ownerID,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      delayNanoseconds: 30_000_000
    )
    let store = PartnerWardStore(
      ownerID: ownerID.uuidString,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      api: api,
      retryReceiptStore: MemoryMessageSendRetryReceiptStore()
    )
    await store.load().value

    let first = store.sendMessage("first")
    let second = store.sendMessage("second")
    await first.value
    await second.value

    let sendCount = await api.sendCallCount()
    XCTAssertEqual(sendCount, 1)
    XCTAssertEqual(store.messages.filter { $0.role == .user }.map(\.content), ["first"])
  }

  func testForbiddenPartnerSendClearsProtectedHistoryAndRetryCanReload() async {
    let api = PartnerWardWriteAPI(
      ownerID: ownerID,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      sendError: .forbidden
    )
    let store = PartnerWardStore(
      ownerID: ownerID.uuidString,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      api: api,
      retryReceiptStore: MemoryMessageSendRetryReceiptStore()
    )
    await store.load().value
    await store.sendMessage("hello").value

    XCTAssertEqual(store.phase, .failed(.forbidden))
    XCTAssertNil(store.chat)
    XCTAssertTrue(store.messages.isEmpty)

    await api.clearSendError()
    await store.retry().value
    XCTAssertEqual(store.phase, .loaded)
    XCTAssertNotNil(store.chat)
  }

  func testCancelledPartnerSendCannotRepopulateHistory() async {
    let sendStarted = expectation(description: "Partner send reached the API")
    let api = PartnerWardWriteAPI(
      ownerID: ownerID,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      sendStartedExpectation: sendStarted
    )
    let store = PartnerWardStore(
      ownerID: ownerID.uuidString,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      api: api,
      retryReceiptStore: MemoryMessageSendRetryReceiptStore()
    )
    await store.load().value
    let sendTask = store.sendMessage("hello")
    await fulfillment(of: [sendStarted], timeout: 3)
    store.cancel()
    await api.releaseSend()
    await sendTask.value

    let sendCount = await api.sendCallCount()
    let generationCount = await api.generationCount()
    XCTAssertEqual(sendCount, 1)
    XCTAssertEqual(generationCount, 1)
    XCTAssertEqual(store.phase, .idle)
    XCTAssertTrue(store.messages.isEmpty)
    XCTAssertNil(store.lastSentMessageID)
  }

  func testReboundPartnerStoreRejectsBeforeCallingOldOwnerBoundAPI() async {
    let api = PartnerWardWriteAPI(
      ownerID: ownerID,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID
    )
    let store = PartnerWardStore(
      ownerID: ownerID.uuidString,
      matchID: matchID,
      partnerID: partnerID,
      chatID: chatID,
      api: api,
      retryReceiptStore: MemoryMessageSendRetryReceiptStore()
    )

    store.updateOwner(partnerID.uuidString)
    await store.load().value

    XCTAssertEqual(store.phase, .failed(.unauthenticated))
    let detailCalls = await api.detailCallCount()
    let messageCalls = await api.messageCallCount()
    XCTAssertEqual(detailCalls, 0)
    XCTAssertEqual(messageCalls, 0)
  }

  private func startResponse() -> Data {
    Data(#"{"data":{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","match_id":"11111111-1111-4111-8111-111111111111","partner":{"nickname":"Aoi"},"first_message":{"id":"66666666-6666-4666-8666-666666666666","role":"fox","content":"Nice to meet you.","created_at":"2026-01-01T00:00:00Z"}}}"#.utf8)
  }

  private func sendResponse() -> Data {
    Data(#"{"data":{"user_message":{"id":"77777777-7777-4777-8777-777777777777","role":"user","content":"hello","created_at":"2026-01-01T00:01:00Z"},"fox_message":{"id":"88888888-8888-4888-8888-888888888888","role":"fox","content":"Hello.","created_at":"2026-01-01T00:01:01Z"}}}"#.utf8)
  }
}

private actor PartnerWardWriteAPI: MatchDetailAPI {
  let ownerID: UUID
  let matchID: UUID
  let partnerID: UUID
  let chatID: UUID
  let delayNanoseconds: UInt64
  private var sendError: APIClientError?
  private var loseResponseAfterCommit: Bool
  private var sendCalls = 0
  private var generationCalls = 0
  private var persistedByKey: [UUID: PartnerFoxMessageSendResult] = [:]
  private var sentIdempotencyKeys: [UUID] = []
  private var sentContent: [String] = []
  private var persistedMessages: [PartnerFoxMessage] = []
  private let sendStartedExpectation: XCTestExpectation?
  private var sendReleased = false
  private var sendContinuation: CheckedContinuation<Void, Never>?
  private var detailCalls = 0
  private var messageCalls = 0
  private var recoveryLookups = 0

  init(
    ownerID: UUID,
    matchID: UUID,
    partnerID: UUID,
    chatID: UUID,
    delayNanoseconds: UInt64 = 0,
    sendError: APIClientError? = nil,
    loseResponseAfterCommit: Bool = false,
    sendStartedExpectation: XCTestExpectation? = nil
  ) {
    self.ownerID = ownerID
    self.matchID = matchID
    self.partnerID = partnerID
    self.chatID = chatID
    self.delayNanoseconds = delayNanoseconds
    self.sendError = sendError
    self.loseResponseAfterCommit = loseResponseAfterCommit
    self.sendStartedExpectation = sendStartedExpectation
  }

  func fetchMatch(id: UUID) async throws -> ProductionMatchDetail { throw APIClientError.invalidState }
  func fetchConversation(id: UUID) async throws -> FoxConversationSummary { throw APIClientError.invalidState }
  func fetchMessages(conversationID: UUID, limit: Int) async throws -> FoxConversationMessagesPayload { throw APIClientError.invalidState }
  func startConversation(matchID: UUID) async throws -> FoxConversationStartResult { throw APIClientError.invalidState }
  func fetchPartnerChat(id: UUID) async throws -> PartnerFoxChatDetail {
    detailCalls += 1
    return PartnerFoxChatDetail(
      id: chatID,
      matchID: matchID,
      userID: ownerID,
      partnerUserID: partnerID,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      partner: MatchDetailPartner(nickname: "Aoi")
    )
  }
  func fetchPartnerMessages(chatID: UUID) async throws -> PartnerFoxMessagesPayload {
    messageCalls += 1
    if persistedMessages.isEmpty {
      persistedMessages.append(PartnerFoxMessage(
        id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
        role: .fox,
        content: "Welcome.",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
      ))
    }
    return PartnerFoxMessagesPayload(messages: persistedMessages)
  }

  func sendPartnerMessage(chatID: UUID, content: String) async throws -> PartnerFoxMessageSendResult {
    try await sendPartnerMessage(chatID: chatID, content: content, idempotencyKey: UUID())
  }

  func sendPartnerMessage(
    chatID: UUID,
    content: String,
    idempotencyKey: UUID
  ) async throws -> PartnerFoxMessageSendResult {
    sendCalls += 1
    sentIdempotencyKeys.append(idempotencyKey)
    sentContent.append(content)
    if let sendStartedExpectation {
      sendStartedExpectation.fulfill()
      if !sendReleased {
        // Return the late response only after the test has cancelled the store.
        await withCheckedContinuation { sendContinuation = $0 }
      }
    }
    if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
    if let sendError { throw sendError }
    if let existing = persistedByKey[idempotencyKey] {
      guard existing.userMessage.content == content else { throw APIClientError.invalidRequest }
      return existing
    }

    generationCalls += 1
    let result = PartnerFoxMessageSendResult(
      userMessage: PartnerFoxMessage(
        id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
        role: .user,
        content: content,
        createdAt: Date(timeIntervalSince1970: 1_700_000_060)
      ),
      foxMessage: PartnerFoxMessage(
        id: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
        role: .fox,
        content: "I hear you.",
        createdAt: Date(timeIntervalSince1970: 1_700_000_061)
      )
    )
    persistedByKey[idempotencyKey] = result
    persistedMessages.append(result.userMessage)
    persistedMessages.append(result.foxMessage)
    if loseResponseAfterCommit {
      loseResponseAfterCommit = false
      throw APIClientError.temporarilyUnavailable
    }
    return result
  }

  func recoverPartnerMessageSend(
    chatID: UUID,
    idempotencyKey: UUID,
    contentSHA256: String
  ) async throws -> PartnerFoxMessageSendRecoveryResult {
    recoveryLookups += 1
    guard let result = persistedByKey[idempotencyKey] else {
      return PartnerFoxMessageSendRecoveryResult(outcome: .notFound, userMessage: nil, foxMessage: nil)
    }
    guard MessageSendRetryReceipt.contentSHA256(for: result.userMessage.content) == contentSHA256 else {
      return PartnerFoxMessageSendRecoveryResult(outcome: .conflict, userMessage: nil, foxMessage: nil)
    }
    return PartnerFoxMessageSendRecoveryResult(
      outcome: .completed,
      userMessage: result.userMessage,
      foxMessage: result.foxMessage
    )
  }

  func sendCallCount() -> Int { sendCalls }
  func generationCount() -> Int { generationCalls }
  func persistedUserMessageCount() -> Int { persistedByKey.count }
  func persistedGeneratedFoxMessageCount() -> Int { persistedByKey.count }
  func sentKeys() -> [UUID] { sentIdempotencyKeys }
  func sentContents() -> [String] { sentContent }
  func detailCallCount() -> Int { detailCalls }
  func messageCallCount() -> Int { messageCalls }
  func recoveryLookupCount() -> Int { recoveryLookups }
  func releaseSend() {
    sendReleased = true
    sendContinuation?.resume()
    sendContinuation = nil
  }
  func clearSendError() { sendError = nil }
}
