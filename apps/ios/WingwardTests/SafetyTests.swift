import Foundation
import XCTest
@testable import Wingward

@MainActor
final class SafetyTests: XCTestCase {
  private let ownerID = "11111111-1111-4111-8111-111111111111"
  private let authUserID = "99999999-9999-4999-8999-999999999999"
  private let targetID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

  func testLiveAccountDeletionRegistersReceiptBeforeDeleteAndKeepsItForLocalCleanup() async throws {
    let timeline = DeletionTestTimeline()
    let client = RecordingDeletionAPIClient(timeline: timeline)
    await client.enqueue(.success(intentResponse()), for: .post, path: LiveAccountLifecycleAPI.intentPath)
    await client.enqueue(.success(Data(#"{"data":{"deleted":true}}"#.utf8)), for: .delete, path: LiveAccountLifecycleAPI.deletionPath)
    let storage = InMemoryDeletionReceiptStorage(timeline: timeline)
    let checker = ScriptedDeletionStatusChecker([.success(.pending)])
    let api = LiveAccountLifecycleAPI(
      client: client,
      ownerID: ownerID,
      authService: DeletionTestAuthService(session: AuthSession(accessToken: "synthetic-token", authUserID: authUserID)),
      profileAPI: DeletionTestProfileAPI(profile: UserProfile(id: ownerID, ageVerified: true)),
      receiptStorage: storage,
      statusChecker: checker,
      receiptGenerator: FixedDeletionReceiptGenerator(receipt: fixtureReceipt())
    )

    let response = try await api.deleteAccount()
    XCTAssertTrue(response.deleted)
    let record = try storage.load(ownerProfileID: ownerID)
    XCTAssertEqual(record?.receipt, fixtureReceipt())
    let requests = await client.requests()
    XCTAssertEqual(requests.map(\.method), [.post, .delete])
    XCTAssertEqual(requests.map(\.path), [LiveAccountLifecycleAPI.intentPath, LiveAccountLifecycleAPI.deletionPath])
    XCTAssertEqual(requests.map(\.accountDeletionReceipt), [fixtureReceipt(), fixtureReceipt()])
    XCTAssertTrue(requests.allSatisfy { $0.body == nil })
    XCTAssertEqual(timeline.events(), ["store", "POST", "store", "DELETE"])
  }

  func testLostDeleteResponseUsesReceiptStatusAndDoesNotInventPendingSuccess() async throws {
    let client = RecordingDeletionAPIClient()
    await client.enqueue(.success(intentResponse()), for: .post, path: LiveAccountLifecycleAPI.intentPath)
    await client.enqueue(.failure(.temporarilyUnavailable), for: .delete, path: LiveAccountLifecycleAPI.deletionPath)
    let storage = InMemoryDeletionReceiptStorage()
    let checker = ScriptedDeletionStatusChecker([.success(.pending), .success(.deleted)])
    let api = makeLiveDeletionAPI(client: client, storage: storage, checker: checker)

    let response = try await api.deleteAccount()

    XCTAssertTrue(response.deleted)
    XCTAssertNotNil(try storage.load(ownerProfileID: ownerID), "The receipt remains until the auth boundary clears the local session.")
    let statusCalls = await checker.callCount()
    XCTAssertEqual(statusCalls, 2)
  }

  func testPendingDeletionNeverReturnsSuccessAndKeepsReceiptForRetry() async throws {
    let client = RecordingDeletionAPIClient()
    await client.enqueue(.success(intentResponse()), for: .post, path: LiveAccountLifecycleAPI.intentPath)
    await client.enqueue(.success(Data(#"{"data":{"deleted":false}}"#.utf8)), for: .delete, path: LiveAccountLifecycleAPI.deletionPath)
    let storage = InMemoryDeletionReceiptStorage()
    let checker = ScriptedDeletionStatusChecker([.success(.pending), .success(.pending)])
    let api = makeLiveDeletionAPI(client: client, storage: storage, checker: checker)

    do {
      _ = try await api.deleteAccount()
      XCTFail("Pending must never be treated as successful deletion.")
    } catch {
      XCTAssertEqual(error as? AccountDeletionError, .notAcknowledged)
    }
    XCTAssertNotNil(try storage.load(ownerProfileID: ownerID))
  }

  func testLostIntentResponsesCanRecoverOnlyFromDeletedReceiptStatus() async throws {
    let client = RecordingDeletionAPIClient()
    await client.enqueue(.failure(.temporarilyUnavailable), for: .post, path: LiveAccountLifecycleAPI.intentPath)
    await client.enqueue(.failure(.temporarilyUnavailable), for: .post, path: LiveAccountLifecycleAPI.intentPath)
    let storage = InMemoryDeletionReceiptStorage()
    let checker = ScriptedDeletionStatusChecker([.success(.deleted)])
    let api = makeLiveDeletionAPI(client: client, storage: storage, checker: checker)

    let response = try await api.deleteAccount()

    XCTAssertTrue(response.deleted)
    let requests = await client.requests()
    XCTAssertEqual(requests.map(\.method), [.post, .post])
    XCTAssertNotNil(try storage.load(ownerProfileID: ownerID))
  }

  func testSameInstanceRetryChecksDeletedReceiptBeforeProfileFetch() async throws {
    let client = RecordingDeletionAPIClient()
    let storage = InMemoryDeletionReceiptStorage()
    try storage.store(storedReceipt())
    let profile = DeletionTestProfileAPI(profile: nil, fetchError: AccountDeletionError.temporarilyUnavailable)
    let checker = ScriptedDeletionStatusChecker([.success(.deleted)])
    let api = LiveAccountLifecycleAPI(
      client: client,
      ownerID: ownerID,
      authService: DeletionTestAuthService(session: AuthSession(accessToken: "synthetic-token", authUserID: authUserID)),
      profileAPI: profile,
      receiptStorage: storage,
      statusChecker: checker,
      receiptGenerator: FixedDeletionReceiptGenerator(receipt: fixtureReceipt())
    )

    let response = try await api.deleteAccount()

    XCTAssertTrue(response.deleted)
    XCTAssertEqual(profile.fetchCallCount, 0)
    let requests = await client.requests()
    XCTAssertTrue(requests.isEmpty)
    XCTAssertNotNil(try storage.load(ownerProfileID: ownerID))
  }

  func testSameInstanceRetryCanRecoverAfterAuthSessionIsRevoked() async throws {
    let client = RecordingDeletionAPIClient()
    let storage = InMemoryDeletionReceiptStorage()
    try storage.store(storedReceipt())
    let profile = DeletionTestProfileAPI(profile: nil, fetchError: AccountDeletionError.temporarilyUnavailable)
    let checker = ScriptedDeletionStatusChecker([.success(.deleted)])
    let api = LiveAccountLifecycleAPI(
      client: client,
      ownerID: ownerID,
      authService: DeletionTestAuthService(session: nil),
      profileAPI: profile,
      receiptStorage: storage,
      statusChecker: checker,
      receiptGenerator: FixedDeletionReceiptGenerator(receipt: fixtureReceipt())
    )

    let response = try await api.deleteAccount()

    XCTAssertTrue(response.deleted)
    XCTAssertEqual(profile.fetchCallCount, 0)
    let requests = await client.requests()
    XCTAssertTrue(requests.isEmpty)
    XCTAssertNotNil(try storage.load(ownerProfileID: ownerID))
  }

  func testSameInstanceRetryChecksServerBeforeDiscardingReceiptForFutureDeviceClock() async throws {
    let client = RecordingDeletionAPIClient()
    let storage = InMemoryDeletionReceiptStorage()
    try storage.store(storedReceipt())
    let profile = DeletionTestProfileAPI(profile: nil, fetchError: AccountDeletionError.temporarilyUnavailable)
    let checker = ScriptedDeletionStatusChecker([.success(.deleted)])
    let futureNow = Date().addingTimeInterval(8 * 24 * 60 * 60)
    let api = LiveAccountLifecycleAPI(
      client: client,
      ownerID: ownerID,
      authService: DeletionTestAuthService(session: nil),
      profileAPI: profile,
      receiptStorage: storage,
      statusChecker: checker,
      receiptGenerator: FixedDeletionReceiptGenerator(receipt: fixtureReceipt()),
      now: { futureNow }
    )

    let response = try await api.deleteAccount()

    XCTAssertTrue(response.deleted)
    XCTAssertNotNil(try storage.load(ownerProfileID: ownerID))
    XCTAssertEqual(profile.fetchCallCount, 0)
    let requests = await client.requests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testSameInstancePendingStatusPreservesReceiptAfterFutureDeviceClock() async throws {
    let client = RecordingDeletionAPIClient()
    let storage = InMemoryDeletionReceiptStorage()
    let record = storedReceipt()
    try storage.store(record)
    let profile = DeletionTestProfileAPI(profile: nil, fetchError: AccountDeletionError.temporarilyUnavailable)
    let checker = ScriptedDeletionStatusChecker([.success(.pending)])
    let futureNow = Date().addingTimeInterval(8 * 24 * 60 * 60)
    let api = LiveAccountLifecycleAPI(
      client: client,
      ownerID: ownerID,
      authService: DeletionTestAuthService(session: nil),
      profileAPI: profile,
      receiptStorage: storage,
      statusChecker: checker,
      receiptGenerator: FixedDeletionReceiptGenerator(receipt: fixtureReceipt()),
      now: { futureNow }
    )

    do {
      _ = try await api.deleteAccount()
      XCTFail("Pending server state must not become a local expiry or success.")
    } catch {
      XCTAssertEqual(error as? AccountDeletionError, .unauthenticated)
    }
    XCTAssertEqual(try storage.load(ownerProfileID: ownerID), record)
    XCTAssertEqual(profile.fetchCallCount, 0)
    let requests = await client.requests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testSameInstanceRetryDoesNotUseReceiptAfterAuthIdentityChanges() async throws {
    let client = RecordingDeletionAPIClient()
    let storage = InMemoryDeletionReceiptStorage()
    try storage.store(storedReceipt())
    let checker = ScriptedDeletionStatusChecker([.success(.deleted)])
    let api = LiveAccountLifecycleAPI(
      client: client,
      ownerID: ownerID,
      authService: DeletionTestAuthService(
        session: AuthSession(accessToken: "other-synthetic-token", authUserID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
      ),
      profileAPI: DeletionTestProfileAPI(profile: nil),
      receiptStorage: storage,
      statusChecker: checker,
      receiptGenerator: FixedDeletionReceiptGenerator(receipt: fixtureReceipt())
    )

    do {
      _ = try await api.deleteAccount()
      XCTFail("A receipt bound to another Auth identity cannot acknowledge deletion.")
    } catch {
      XCTAssertEqual(error as? AccountDeletionError, .ownerMismatch)
    }
    let statusCalls = await checker.callCount()
    let requests = await client.requests()
    XCTAssertEqual(statusCalls, 0)
    XCTAssertTrue(requests.isEmpty)
    XCTAssertNotNil(try storage.load(ownerProfileID: ownerID))
  }

  func testAccountDeletionDoesNotCleanUpBeforeTrueServerAcknowledgement() async {
    let timeline = Timeline()
    let api = ScriptedAccountAPI(response: AccountDeletionResponse(deleted: false), timeline: timeline)
    let cleanup = RecordingCleanup(timeline: timeline)
    let coordinator = AccountDeletionCoordinator(ownerID: ownerID, api: api, cleanup: cleanup)

    await coordinator.deleteAccount().value

    XCTAssertEqual(coordinator.phase, .failed(.notAcknowledged))
    let cleanupCalls = await cleanup.callCount()
    let events = await timeline.events()
    XCTAssertEqual(cleanupCalls, 0)
    XCTAssertEqual(events, ["server"])
  }

  func testAccountDeletionCleansUpOnlyAfterServerAcknowledgement() async {
    let timeline = Timeline()
    let api = ScriptedAccountAPI(response: AccountDeletionResponse(deleted: true), timeline: timeline)
    let cleanup = RecordingCleanup(timeline: timeline)
    let coordinator = AccountDeletionCoordinator(ownerID: ownerID, api: api, cleanup: cleanup)

    await coordinator.deleteAccount().value

    XCTAssertEqual(coordinator.phase, .deleted)
    let events = await timeline.events()
    XCTAssertEqual(events, ["server", "cleanup"])
    let cleanupOwnerIDs = await cleanup.ownerIDs()
    XCTAssertEqual(cleanupOwnerIDs, [ownerID])
  }

  func testCancelledDeletionCannotCleanUpAfterOwnerSwitch() async {
    let api = DeferredAccountAPI()
    let cleanup = RecordingCleanup(timeline: Timeline())
    let coordinator = AccountDeletionCoordinator(ownerID: ownerID, api: api, cleanup: cleanup)

    let task = coordinator.deleteAccount()
    await api.waitForCall()
    coordinator.cancel()
    coordinator.updateOwner("33333333-3333-4333-8333-333333333333")
    await api.resolve(AccountDeletionResponse(deleted: true))
    await task.value

    XCTAssertEqual(coordinator.phase, .idle)
    let cleanupCalls = await cleanup.callCount()
    let deletionCalls = await api.callCount()
    XCTAssertEqual(cleanupCalls, 0)
    XCTAssertEqual(deletionCalls, 1)
  }

  func testReboundDeletionCoordinatorCannotCallTheOldOwnersAPI() async {
    let timeline = Timeline()
    let api = ScriptedAccountAPI(response: AccountDeletionResponse(deleted: true), timeline: timeline)
    let cleanup = RecordingCleanup(timeline: timeline)
    let coordinator = AccountDeletionCoordinator(ownerID: ownerID, api: api, cleanup: cleanup)

    coordinator.updateOwner("33333333-3333-4333-8333-333333333333")
    await coordinator.deleteAccount().value

    XCTAssertEqual(coordinator.phase, .failed(.ownerMismatch))
    let apiCalls = await api.callCount()
    let cleanupCalls = await cleanup.callCount()
    XCTAssertEqual(apiCalls, 0)
    XCTAssertEqual(cleanupCalls, 0)
  }

  func testReportTrimsDescriptionAndPublishesHumanReviewState() async {
    let api = ScriptedSafetyAPI()
    let messageID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    let store = SafetyStore(
      ownerID: ownerID,
      targetID: targetID,
      context: .directChat,
      messageID: messageID,
      api: api
    )

    await store.submitReport(
      reason: .harassment,
      description: "  unwanted contact  "
    ).value

    XCTAssertEqual(store.phase, .reportSubmitted)
    let request = await api.lastReport()
    XCTAssertEqual(request?.description, "unwanted contact")
    XCTAssertEqual(request?.userID, targetID)
    XCTAssertEqual(request?.messageID, messageID)
  }

  func testBlockFailureKeepsContentHiddenForPartialCommitReconciliation() async {
    let api = ScriptedSafetyAPI()
    await api.setBlockError(.temporarilyUnavailable)
    let store = SafetyStore(
      ownerID: ownerID,
      targetID: targetID,
      context: .match,
      api: api
    )

    await store.block().value

    XCTAssertEqual(store.phase, .failed(.temporarilyUnavailable))
    XCTAssertTrue(store.isContentHidden)
    XCTAssertTrue(store.canRetryBlock)

    store.cancel()
    XCTAssertTrue(store.isContentHidden)

    await api.setBlockError(nil)
    await store.block().value
    XCTAssertEqual(store.phase, .blocked)
    XCTAssertTrue(store.isContentHidden)
  }

  func testBlockOwnerRebindDoesNotPublishTheOldResult() async {
    let api = ScriptedSafetyAPI()
    await api.setBlockDelayNanoseconds(100_000_000)
    let store = SafetyStore(
      ownerID: ownerID,
      targetID: targetID,
      context: .partnerFoxChat,
      api: api
    )

    let task = store.block()
    await api.waitForBlockStart()
    store.updateOwner("33333333-3333-4333-8333-333333333333")
    await task.value

    XCTAssertEqual(store.phase, .idle)
    XCTAssertFalse(store.isContentHidden)
    let firstBlockCalls = await api.blockCallCount()
    XCTAssertEqual(firstBlockCalls, 1)

    await store.block().value
    XCTAssertEqual(store.phase, .failed(.ownerMismatch))
    let secondBlockCalls = await api.blockCallCount()
    XCTAssertEqual(secondBlockCalls, 1)
  }

  func testMalformedReportResponseFailsClosedAtDTOBoundary() {
    let malformed = Data(#"{"data":{"report_id":"not-an-id","status":"pending"}}"#.utf8)
    XCTAssertThrowsError(try APIResponseDecoder.decode(malformed, as: ModerationReportResponse.self)) { error in
      XCTAssertEqual(error as? APIClientError, .invalidResponse)
    }

    let wrongStatus = Data(
      #"{"data":{"report_id":"55555555-5555-4555-8555-555555555555","status":"resolved"}}"#.utf8
    )
    XCTAssertThrowsError(try APIResponseDecoder.decode(wrongStatus, as: ModerationReportResponse.self)) { error in
      XCTAssertEqual(error as? APIClientError, .invalidResponse)
    }
  }

  func testModerationAcknowledgementsAreOperationSpecific() {
    let wrongBlock = Data(#"{"data":{"message":"User unblocked"}}"#.utf8)
    XCTAssertThrowsError(try APIResponseDecoder.decode(wrongBlock, as: ModerationBlockResponse.self)) { error in
      XCTAssertEqual(error as? APIClientError, .invalidResponse)
    }

    let wrongUnblock = Data(#"{"data":{"message":"User blocked"}}"#.utf8)
    XCTAssertThrowsError(try APIResponseDecoder.decode(wrongUnblock, as: ModerationUnblockResponse.self)) { error in
      XCTAssertEqual(error as? APIClientError, .invalidResponse)
    }
  }

  func testReceiptUsesASeparateKeychainNamespaceAndStrictWireShape() {
    XCTAssertNotEqual(KeychainAccountDeletionReceiptStorage.service, "com.wingward.auth")
    XCTAssertNotEqual(KeychainAccountDeletionReceiptStorage.service, KeychainAuthLocalStorage.storageKey)
    XCTAssertTrue(AccountDeletionReceipt.isValid(fixtureReceipt()))
    XCTAssertFalse(AccountDeletionReceipt.isValid(fixtureReceipt() + "="))
    XCTAssertFalse(AccountDeletionReceipt.isValid("not-a-receipt"))
  }

  func testPublicStatusRequestCarriesOnlyReceiptHeaderAndRejectsExtraStatusFields() async throws {
    let receipt = fixtureReceipt()
    let transport = RecordingStatusTransport(
      data: Data(#"{"data":{"status":"pending"}}"#.utf8),
      statusCode: 200
    )
    let checker = try LiveAccountDeletionStatusChecker(
      baseURL: URL(string: "https://api.example.test")!,
      transport: transport
    )

    let status = try await checker.status(receipt: receipt)
    XCTAssertEqual(status, .pending)
    let request = await transport.request()
    XCTAssertEqual(request?.httpMethod, "GET")
    XCTAssertEqual(request?.url?.path, LiveAccountLifecycleAPI.statusPath)
    XCTAssertNil(request?.url?.query)
    XCTAssertNil(request?.httpBody)
    XCTAssertEqual(request?.value(forHTTPHeaderField: "X-Account-Deletion-Receipt"), receipt)
    XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))

    let oversizedShape = RecordingStatusTransport(
      data: Data(#"{"data":{"status":"deleted","owner_profile_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}"#.utf8),
      statusCode: 200
    )
    let strictChecker = try LiveAccountDeletionStatusChecker(
      baseURL: URL(string: "https://api.example.test")!,
      transport: oversizedShape
    )
    do {
      _ = try await strictChecker.status(receipt: receipt)
      XCTFail("Status data must not expose account identifiers.")
    } catch {
      XCTAssertEqual(error as? AccountDeletionError, .invalidResponse)
    }
  }

  func testRecoveryPreservesReceiptWhenGeneralizedStatusIsNotFound() async throws {
    let storage = InMemoryDeletionReceiptStorage()
    try storage.store(storedReceipt())
    let checker = ScriptedDeletionStatusChecker([.failure(.notFound)])
    let recovery = LiveAccountDeletionRecovery(storage: storage, checker: checker)

    let outcome = await recovery.check(authUserID: authUserID)

    XCTAssertEqual(outcome, .unavailable)
    XCTAssertNotNil(try storage.load(ownerProfileID: ownerID))
  }

  func testRecoveryKeepsDeletedReceiptUntilControllerExplicitlyClearsIt() async throws {
    let storage = InMemoryDeletionReceiptStorage()
    try storage.store(storedReceipt())
    let checker = ScriptedDeletionStatusChecker([.success(.deleted)])
    let recovery = LiveAccountDeletionRecovery(storage: storage, checker: checker)

    let outcome = await recovery.check(authUserID: authUserID)
    XCTAssertEqual(outcome, .deleted(ownerProfileID: ownerID, authUserID: authUserID))
    XCTAssertNotNil(try storage.load(ownerProfileID: ownerID))

    try await recovery.clearDeletedReceipt(ownerProfileID: ownerID)
    XCTAssertNil(try storage.load(ownerProfileID: ownerID))
  }

  func testRestartRecoveryChecksServerBeforeFutureClockExpiryForDeletedAndPending() async throws {
    let futureNow = Date().addingTimeInterval(8 * 24 * 60 * 60)
    for (serverStatus, expectedOutcome) in [
      (AccountDeletionServerStatus.deleted, AccountDeletionRecoveryOutcome.deleted(ownerProfileID: ownerID, authUserID: authUserID)),
      (.pending, .pending),
    ] {
      let storage = InMemoryDeletionReceiptStorage()
      try storage.store(storedReceipt())
      let checker = ScriptedDeletionStatusChecker([.success(serverStatus)])
      let recovery = LiveAccountDeletionRecovery(storage: storage, checker: checker, now: { futureNow })

      let outcome = await recovery.check(authUserID: nil)

      XCTAssertEqual(outcome, expectedOutcome)
      XCTAssertNotNil(try storage.load(ownerProfileID: ownerID))
    }
  }

  func testRestartRecoveryMayCleanUpOnlyAfterExpiredReceiptGetsServer404() async throws {
    let futureNow = Date().addingTimeInterval(8 * 24 * 60 * 60)
    let expiredStorage = InMemoryDeletionReceiptStorage()
    try expiredStorage.store(storedReceipt())
    let expiredRecovery = LiveAccountDeletionRecovery(
      storage: expiredStorage,
      checker: ScriptedDeletionStatusChecker([.failure(.notFound)]),
      now: { futureNow }
    )

    let expiredOutcome = await expiredRecovery.check(authUserID: nil)

    XCTAssertEqual(expiredOutcome, .none)
    XCTAssertNil(try expiredStorage.load(ownerProfileID: ownerID))

    let activeStorage = InMemoryDeletionReceiptStorage()
    try activeStorage.store(storedReceipt())
    let activeRecovery = LiveAccountDeletionRecovery(
      storage: activeStorage,
      checker: ScriptedDeletionStatusChecker([.failure(.notFound)])
    )
    let activeOutcome = await activeRecovery.check(authUserID: nil)
    XCTAssertEqual(activeOutcome, .unavailable)
    XCTAssertNotNil(try activeStorage.load(ownerProfileID: ownerID))
  }

  func testDeletionIntentDTORejectsUnknownReceiptFields() {
    let malformed = Data(#"{"data":{"status":"pending","expires_at":"2026-09-27T12:00:00.000Z","receipt":"synthetic-secret"}}"#.utf8)

    XCTAssertThrowsError(try APIResponseDecoder.decode(malformed, as: AccountDeletionIntentResponse.self)) { error in
      XCTAssertEqual(error as? APIClientError, .invalidResponse)
    }
  }

  private func makeLiveDeletionAPI(
    client: RecordingDeletionAPIClient,
    storage: InMemoryDeletionReceiptStorage,
    checker: ScriptedDeletionStatusChecker
  ) -> LiveAccountLifecycleAPI {
    LiveAccountLifecycleAPI(
      client: client,
      ownerID: ownerID,
      authService: DeletionTestAuthService(session: AuthSession(accessToken: "synthetic-token", authUserID: authUserID)),
      profileAPI: DeletionTestProfileAPI(profile: UserProfile(id: ownerID, ageVerified: true)),
      receiptStorage: storage,
      statusChecker: checker,
      receiptGenerator: FixedDeletionReceiptGenerator(receipt: fixtureReceipt())
    )
  }

  private func fixtureReceipt() -> String {
    "33333333-3333-4333-8333-333333333333." + String(repeating: "A", count: 43)
  }

  private func storedReceipt() -> StoredAccountDeletionReceipt {
    let now = Date()
    return StoredAccountDeletionReceipt(
      ownerProfileID: ownerID,
      authUserID: authUserID,
      receipt: fixtureReceipt(),
      createdAt: now,
      expiresAt: now.addingTimeInterval(86_400)
    )
  }

  private func intentResponse() -> Data {
    let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(24 * 60 * 60))
    return Data(#"{"data":{"status":"pending","expires_at":"\#(expiresAt)"}}"#.utf8)
  }
}

private final class DeletionTestTimeline: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []

  func append(_ value: String) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }

  func events() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

private actor RecordingDeletionAPIClient: AuthenticatedAPIClientProtocol {
  private struct Key: Hashable, Sendable {
    let method: APIHTTPMethod
    let path: String
  }

  private var responses: [Key: [Result<Data, APIClientError>]] = [:]
  private var recordedRequests: [APIRequest] = []
  private let timeline: DeletionTestTimeline?

  init(timeline: DeletionTestTimeline? = nil) {
    self.timeline = timeline
  }

  func enqueue(_ response: Result<Data, APIClientError>, for method: APIHTTPMethod, path: String) {
    responses[Key(method: method, path: path), default: []].append(response)
  }

  func send<Value: APIValidatable>(_ request: APIRequest, as type: Value.Type) async throws -> Value {
    recordedRequests.append(request)
    timeline?.append(request.method.rawValue)
    let key = Key(method: request.method, path: request.path)
    guard var queue = responses[key], !queue.isEmpty else {
      throw APIClientError.temporarilyUnavailable
    }
    let result = queue.removeFirst()
    responses[key] = queue
    switch result {
    case let .success(data): return try APIResponseDecoder.decode(data, as: type)
    case let .failure(error): throw error
    }
  }

  func requests() -> [APIRequest] { recordedRequests }
}

private final class InMemoryDeletionReceiptStorage: AccountDeletionReceiptStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var records: [String: StoredAccountDeletionReceipt] = [:]
  private let timeline: DeletionTestTimeline?

  init(timeline: DeletionTestTimeline? = nil) {
    self.timeline = timeline
  }

  func load(ownerProfileID: String) throws -> StoredAccountDeletionReceipt? {
    lock.lock()
    defer { lock.unlock() }
    return records[ownerProfileID]
  }

  func loadAll() throws -> [StoredAccountDeletionReceipt] {
    lock.lock()
    defer { lock.unlock() }
    return Array(records.values)
  }

  func store(_ receipt: StoredAccountDeletionReceipt) throws {
    lock.lock()
    records[receipt.ownerProfileID] = receipt
    lock.unlock()
    timeline?.append("store")
  }

  func remove(ownerProfileID: String) throws {
    lock.lock()
    records.removeValue(forKey: ownerProfileID)
    lock.unlock()
  }
}

private struct FixedDeletionReceiptGenerator: AccountDeletionReceiptGenerating {
  let receipt: String

  func makeReceipt() throws -> String { receipt }
}

private actor ScriptedDeletionStatusChecker: AccountDeletionStatusChecking {
  private var outcomes: [Result<AccountDeletionServerStatus, AccountDeletionError>]
  private var calls = 0

  init(_ outcomes: [Result<AccountDeletionServerStatus, AccountDeletionError>]) {
    self.outcomes = outcomes
  }

  func status(receipt: String) async throws -> AccountDeletionServerStatus {
    calls += 1
    guard !outcomes.isEmpty else { throw AccountDeletionError.temporarilyUnavailable }
    switch outcomes.removeFirst() {
    case let .success(status): return status
    case let .failure(error): throw error
    }
  }

  func callCount() -> Int { calls }
}

private actor RecordingStatusTransport: APIHTTPTransport {
  private let responseData: Data
  private let statusCode: Int
  private var lastRequest: URLRequest?

  init(data: Data, statusCode: Int) {
    self.responseData = data
    self.statusCode = statusCode
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    lastRequest = request
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Cache-Control": "no-store"]
    )!
    return (responseData, response)
  }

  func request() -> URLRequest? { lastRequest }
}

private struct DeletionTestAuthService: AuthService {
  let session: AuthSession?

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

private final class DeletionTestProfileAPI: ProfileAPI, @unchecked Sendable {
  let profile: UserProfile?
  let fetchError: Error?
  private let lock = NSLock()
  private var fetchCalls = 0

  init(profile: UserProfile?, fetchError: Error? = nil) {
    self.profile = profile
    self.fetchError = fetchError
  }

  var fetchCallCount: Int {
    lock.withLock { fetchCalls }
  }

  func fetchProfile(accessToken: String) async throws -> UserProfile {
    lock.withLock { fetchCalls += 1 }
    if let fetchError { throw fetchError }
    guard let profile else { throw AccountDeletionError.temporarilyUnavailable }
    return profile
  }

  func verifyAge(accessToken: String, birthDate: String) async throws {}
}

private actor Timeline {
  private var values: [String] = []

  func append(_ value: String) { values.append(value) }
  func events() -> [String] { values }
}

private actor RecordingCleanup: SessionCleanup {
  private let timeline: Timeline
  private var calls = 0
  private var recordedOwnerIDs: [String] = []

  init(timeline: Timeline) { self.timeline = timeline }

  func clearAfterServerDeletion(ownerID: String) async {
    calls += 1
    recordedOwnerIDs.append(ownerID)
    await timeline.append("cleanup")
  }

  func callCount() -> Int { calls }
  func ownerIDs() -> [String] { recordedOwnerIDs }
}

private actor ScriptedAccountAPI: AccountLifecycleAPI {
  private let response: AccountDeletionResponse
  private let timeline: Timeline
  private var calls = 0

  init(response: AccountDeletionResponse, timeline: Timeline) {
    self.response = response
    self.timeline = timeline
  }

  func deleteAccount() async throws -> AccountDeletionResponse {
    calls += 1
    await timeline.append("server")
    return response
  }

  func callCount() -> Int { calls }
}

private actor DeferredAccountAPI: AccountLifecycleAPI {
  private var continuation: CheckedContinuation<AccountDeletionResponse, Never>?
  private var calls = 0

  func deleteAccount() async throws -> AccountDeletionResponse {
    calls += 1
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitForCall() async {
    while calls == 0 {
      await Task.yield()
    }
  }

  func resolve(_ response: AccountDeletionResponse) {
    continuation?.resume(returning: response)
    continuation = nil
  }

  func callCount() -> Int { calls }
}

private actor ScriptedSafetyAPI: SafetyAPI {
  private var report: ModerationReportRequest?
  private var blockError: APIClientError?
  private var blockDelayNanoseconds: UInt64 = 0
  private var blockCalls = 0
  private var blockStartedContinuation: CheckedContinuation<Void, Never>?

  func report(_ request: ModerationReportRequest) async throws -> ModerationReportResponse {
    report = request
    return ModerationReportResponse(
      reportID: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
      status: "pending"
    )
  }

  func block(userID: UUID) async throws -> ModerationBlockResponse {
    blockCalls += 1
    blockStartedContinuation?.resume()
    blockStartedContinuation = nil
    if blockDelayNanoseconds > 0 {
      do { try await Task.sleep(nanoseconds: blockDelayNanoseconds) } catch {}
    }
    if let blockError { throw blockError }
    return ModerationBlockResponse(message: "User blocked")
  }

  func unblock(userID: UUID) async throws -> ModerationUnblockResponse {
    ModerationUnblockResponse(message: "User unblocked")
  }

  func lastReport() -> ModerationReportRequest? { report }
  func setBlockError(_ error: APIClientError?) { blockError = error }
  func setBlockDelayNanoseconds(_ value: UInt64) { blockDelayNanoseconds = value }
  func blockCallCount() -> Int { blockCalls }

  func waitForBlockStart() async {
    if blockCalls > 0 { return }
    await withCheckedContinuation { continuation in
      blockStartedContinuation = continuation
    }
  }
}
