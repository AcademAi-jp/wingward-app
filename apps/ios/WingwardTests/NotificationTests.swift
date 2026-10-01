import Foundation
import XCTest
@testable import Wingward

@MainActor
final class NotificationTests: XCTestCase {
  private let notificationID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let matchID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

  func testPayloadAcceptsOnlyTheClosedDataContractAndAllowlistedRoute() throws {
    let payload = try XCTUnwrap(
      WingwardNotificationPayload(
        userInfo: [
          "data": [
            "scenario_id": "N-01",
            "notification_id": notificationID.uuidString,
            "deep_link": "wingward://match/\(matchID.uuidString)/fox-result",
            "private_message": "must be ignored",
          ],
        ]
      )
    )

    XCTAssertEqual(payload.notificationID, notificationID)
    XCTAssertEqual(payload.scenario, .n01)
    XCTAssertEqual(payload.route, .foxConversationResult(matchID))
    XCTAssertEqual(payload.destinationRoute, .foxConversationResult(matchID))
  }

  func testPayloadRejectsUnknownScenarioMissingIdentityAndTamperedDeepLink() {
    let cases: [[AnyHashable: Any]] = [
      ["data": ["scenario_id": "N-99", "notification_id": notificationID.uuidString]],
      ["data": ["scenario_id": "N-01"]],
      [
        "data": [
          "scenario_id": "N-01",
          "notification_id": notificationID.uuidString,
          "deep_link": "https://evil.example/steal",
        ],
      ],
      [
        "data": [
          "scenario_id": "N-01",
          "notification_id": notificationID.uuidString,
          "deep_link": "wingward://notification/\(notificationID.uuidString)",
        ],
      ],
    ]

    for userInfo in cases {
      XCTAssertNil(WingwardNotificationPayload(userInfo: userInfo))
    }
  }

  func testPayloadSupportsOneSignalStyleWrapperWithoutTrustingOtherFields() throws {
    let payload = try XCTUnwrap(
      WingwardNotificationPayload(
        userInfo: [
          "custom": [
            "a": [
              "data": [
                "scenario_id": "N-03",
                "notification_id": notificationID.uuidString,
              ],
              "url": "https://evil.example/ignored",
            ],
          ],
        ]
      )
    )

    XCTAssertEqual(payload.scenario, .n03)
    XCTAssertEqual(payload.destinationRoute, .notificationLanding(notificationID))
  }

  func testEventBodyUsesServerSnakeCaseAndBoundedFields() throws {
    let occurredAt = Date(timeIntervalSince1970: 1_789_000_000.123)
    let event = WingwardNotificationEvent(
      notificationID: notificationID,
      eventType: .screenViewed,
      screen: .foxConversationResult,
      occurredAt: occurredAt,
      metadata: ["scenario": "N-01"]
    )

    let data = try JSONEncoder().encode(event)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["notification_id"] as? String, notificationID.uuidString.lowercased())
    XCTAssertEqual(json["event_type"] as? String, "screen_viewed")
    XCTAssertEqual(json["screen"] as? String, "fox_conversation_result")
    XCTAssertEqual(json["metadata"] as? [String: String], ["scenario": "N-01"])
    XCTAssertTrue((json["occurred_at"] as? String)?.hasSuffix("Z") == true)
    XCTAssertNil(json["private_message"])
  }

  func testLiveEventsAPIUsesAuthenticatedNotificationEventsRoute() async throws {
    let client = FakeAuthenticatedAPIClient()
    let event = WingwardNotificationEvent(notificationID: notificationID, eventType: .opened)
    let request = try APIRequest.json(
      method: .post,
      path: LiveWingwardNotificationEventsAPI.eventsPath,
      body: event
    )
    await client.setResponseData(
      Data(#"{"data":{"id":"33333333-3333-4333-8333-333333333333"}}"#.utf8),
      for: request
    )

    let api = LiveWingwardNotificationEventsAPI(client: client, expectedOwnerID: "owner-a")
    try await api.record(event)

    let requests = await client.recordedRequests()
    XCTAssertEqual(requests.count, 1)
    let actual = try XCTUnwrap(requests.first)
    XCTAssertEqual(actual.method, request.method)
    XCTAssertEqual(actual.path, request.path)
    XCTAssertEqual(actual.contentType, request.contentType)
    // JSON object key order is not part of the API contract.
    let actualBody = try JSONSerialization.jsonObject(with: XCTUnwrap(actual.body)) as? NSDictionary
    let expectedBody = try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? NSDictionary
    XCTAssertEqual(try XCTUnwrap(actualBody), try XCTUnwrap(expectedBody))
  }

  func testLiveEventsAPIRejectsAChangedOwnerBeforeTransport() async throws {
    let auth = NotificationAuthService(session: AuthSession(accessToken: "token-a"))
    let profile = NotificationProfileAPI(profiles: ["token-a": "owner-a", "token-b": "owner-b"])
    let transport = NotificationTransport(
      responseData: Data(#"{"data":{"id":"33333333-3333-4333-8333-333333333333"}}"#.utf8)
    )
    let api = try LiveWingwardNotificationEventsAPI(
      baseURL: URL(string: "https://api.example.test")!,
      ownerID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      authService: auth,
      profileAPI: profile,
      transport: transport
    )
    let event = WingwardNotificationEvent(notificationID: notificationID, eventType: .opened)

    await auth.setSession(AuthSession(accessToken: "token-b"))
    do {
      try await api.record(event)
      XCTFail("A notification API must reject a different signed-in owner")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .unauthenticated)
    }
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testReporterDeduplicatesEachEventButRetriesAfterFailure() async throws {
    let api = RecordingNotificationEventsAPI()
    let reporter = WingwardNotificationEventReporter(api: api)
    let event = WingwardNotificationEvent(
      notificationID: notificationID,
      eventType: .opened
    )

    try await reporter.record(event)
    try await reporter.record(event)
    let firstEvents = await api.events()
    XCTAssertEqual(firstEvents, [event])

    await api.setFailure(true)
    do {
      try await reporter.record(
        WingwardNotificationEvent(notificationID: notificationID, eventType: .screenViewed, screen: .notifications)
      )
      XCTFail("The injected failure must be visible to the reporter")
    } catch {
      // The event key is removed on failure so a later report can retry.
    }
    await api.setFailure(false)
    let retry = WingwardNotificationEvent(
      notificationID: notificationID,
      eventType: .screenViewed,
      screen: .notifications
    )
    try await reporter.record(retry)
    let retriedEvents = await api.events()
    XCTAssertEqual(retriedEvents, [event, retry])
  }

  func testPermissionModelPromptsAtFirstFoxResultAndShowsDeniedFallbackBadge() async {
    let permission = NotificationPermissionClientFixture(status: .notDetermined)
    let persistence = NotificationBadgePersistenceFixture()
    let seenAPI = RecordingNotificationSeenAPI()
    let model = WingwardNotificationPermissionModel(
      ownerID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      permissionClient: permission,
      badgePersistence: persistence,
      seenAPI: seenAPI
    )

    await model.prepareForFirstFoxResult()
    XCTAssertTrue(model.didOfferFirstFoxResultPrompt)
    XCTAssertTrue(model.isPromptPresented)
    let callsBeforePromptAccept = await permission.requestCalls()
    XCTAssertEqual(callsBeforePromptAccept, 0)

    await model.acceptPrompt()
    let callsAfterPromptAccept = await permission.requestCalls()
    XCTAssertEqual(callsAfterPromptAccept, 1)
    XCTAssertEqual(model.authorization, .denied)
    XCTAssertTrue(model.shouldShowFallbackBadge)
    XCTAssertEqual(model.pendingBadgeCount, 1)

    await model.markPendingResultsSeen()
    XCTAssertFalse(model.shouldShowFallbackBadge)
    let clearedCount = await persistence.count(ownerID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    XCTAssertEqual(clearedCount, 0)
  }

  func testDeniedBadgeIsOwnerScopedAcrossAccountChanges() async {
    let permission = NotificationPermissionClientFixture(status: .denied)
    let persistence = NotificationBadgePersistenceFixture()
    let ownerA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let ownerB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    let firstOwnerModel = WingwardNotificationPermissionModel(
      ownerID: ownerA,
      permissionClient: permission,
      badgePersistence: persistence
    )
    await firstOwnerModel.prepareForFirstFoxResult()
    XCTAssertEqual(firstOwnerModel.pendingBadgeCount, 1)

    let secondOwnerModel = WingwardNotificationPermissionModel(
      ownerID: ownerB,
      permissionClient: permission,
      badgePersistence: persistence
    )
    XCTAssertEqual(secondOwnerModel.pendingBadgeCount, 0)
    XCTAssertFalse(secondOwnerModel.shouldShowFallbackBadge)
  }

  func testLiveSeenAPIUsesAuthenticatedOwnerAndServerSeenClock() async throws {
    let client = FakeAuthenticatedAPIClient()
    let request = APIRequest(method: .post, path: LiveWingwardNotificationSeenAPI.seenPath)
    await client.setResponseData(
      Data(#"{"data":{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","notification_seen_at":"2026-09-22T00:00:00Z"}}"#.utf8),
      for: request
    )

    let api = try LiveWingwardNotificationSeenAPI(
      client: client,
      expectedOwnerID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    )
    let seenAt = try await api.markSeen()
    let expectedSeenAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-22T00:00:00Z"))
    XCTAssertEqual(seenAt, expectedSeenAt)
    let requests = await client.recordedRequests()
    XCTAssertEqual(requests, [request])
  }

  func testCoordinatorReportsOpenedScreenViewedAndActionForTheSameNotification() async throws {
    let api = RecordingNotificationEventsAPI()
    let reporter = WingwardNotificationEventReporter(api: api)
    let routeRecorder = RouteRecorder()
    let seenAPI = RecordingNotificationSeenAPI()
    let seenRecorder = SeenRecorder()
    let coordinator = WingwardNotificationCoordinator(
      ownerID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      reporter: reporter,
      onRoute: { route in routeRecorder.routes.append(route) },
      seenAPI: seenAPI,
      onNotificationSeen: { seenRecorder.count += 1 },
      queuePersistence: NotificationQueuePersistenceFixture()
    )
    let userInfo: [AnyHashable: Any] = [
      "data": [
        "scenario_id": "N-01",
        "notification_id": notificationID.uuidString,
        "deep_link": "wingward://match/\(matchID.uuidString)/fox-result",
      ],
    ]

    coordinator.handleNotificationTap(userInfo: userInfo)
    try await Task.sleep(nanoseconds: 20_000_000)
    coordinator.recordScreenViewed(for: .foxConversationResult(matchID))
    coordinator.recordActionCompleted(screen: .matchDetail)
    coordinator.recordActionCompleted(screen: .foxConversationResult)
    try await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertEqual(routeRecorder.routes, [.foxConversationResult(matchID)])
    let events = await api.events()
    XCTAssertEqual(events.map(\.eventType), [.opened, .screenViewed, .actionCompleted])
    XCTAssertTrue(events.allSatisfy { $0.notificationID == notificationID })
    XCTAssertEqual(seenRecorder.count, 1)
    let seenCalls = await seenAPI.calls()
    XCTAssertEqual(seenCalls, 1)
  }

  func testColdStartTapWaitsForOwnerBindingAndDoesNotRouteAfterOwnerCheckFails() async throws {
    let api = RecordingNotificationEventsAPI()
    let reporter = WingwardNotificationEventReporter(api: api)
    let routeRecorder = RouteRecorder()
    let coordinator = WingwardNotificationCoordinator(
      onRoute: { route in routeRecorder.routes.append(route) },
      queuePersistence: NotificationQueuePersistenceFixture()
    )
    let userInfo: [AnyHashable: Any] = [
      "data": [
        "scenario_id": "N-01",
        "notification_id": notificationID.uuidString,
        "deep_link": "wingward://match/\(matchID.uuidString)/fox-result",
      ],
    ]

    coordinator.handleNotificationTap(userInfo: userInfo)
    try await Task.sleep(nanoseconds: 10_000_000)
    XCTAssertTrue(routeRecorder.routes.isEmpty)

    await api.setFailure(true)
    coordinator.bind(ownerID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", reporter: reporter)
    try await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertTrue(routeRecorder.routes.isEmpty)

    await api.setFailure(false)
    coordinator.bind(ownerID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", reporter: reporter)
    try await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(routeRecorder.routes, [.foxConversationResult(matchID)])
  }

  func testFailedEventIsPersistedAndRetriedAfterCoordinatorRecreation() async throws {
    let ownerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let queue = NotificationQueuePersistenceFixture()
    let failedAPI = RecordingNotificationEventsAPI()
    await failedAPI.setFailure(true)
    let firstCoordinator = WingwardNotificationCoordinator(
      ownerID: ownerID,
      reporter: WingwardNotificationEventReporter(api: failedAPI),
      queuePersistence: queue
    )
    let userInfo: [AnyHashable: Any] = [
      "data": [
        "scenario_id": "N-01",
        "notification_id": notificationID.uuidString,
      ],
    ]

    firstCoordinator.handleForegroundNotification(userInfo: userInfo)
    try await Task.sleep(nanoseconds: 20_000_000)
    let persistedAfterFailure = try queue.load(ownerID: ownerID)
    XCTAssertEqual(persistedAfterFailure.events.map(\.eventType), [.delivered])

    let otherOwnerAPI = RecordingNotificationEventsAPI()
    let otherOwnerCoordinator = WingwardNotificationCoordinator(
      ownerID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      reporter: WingwardNotificationEventReporter(api: otherOwnerAPI),
      queuePersistence: queue
    )
    _ = otherOwnerCoordinator
    try await Task.sleep(nanoseconds: 10_000_000)
    let otherOwnerEvents = await otherOwnerAPI.events()
    XCTAssertTrue(otherOwnerEvents.isEmpty)
    XCTAssertEqual(try queue.load(ownerID: ownerID).events.map(\.eventType), [.delivered])

    let retryAPI = RecordingNotificationEventsAPI()
    let retryCoordinator = WingwardNotificationCoordinator(
      ownerID: ownerID,
      reporter: WingwardNotificationEventReporter(api: retryAPI),
      queuePersistence: queue
    )
    _ = retryCoordinator
    try await Task.sleep(nanoseconds: 20_000_000)

    let retriedEvents = await retryAPI.events()
    XCTAssertEqual(retriedEvents.map(\.eventType), [.delivered])
    XCTAssertTrue(try queue.load(ownerID: ownerID).events.isEmpty)
  }

  func testPendingTapSurvivesCoordinatorRecreationUntilOpenedIsAcknowledged() async throws {
    let ownerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let queue = NotificationQueuePersistenceFixture()
    let failedAPI = RecordingNotificationEventsAPI()
    await failedAPI.setFailure(true)
    let firstCoordinator = WingwardNotificationCoordinator(
      ownerID: ownerID,
      reporter: WingwardNotificationEventReporter(api: failedAPI),
      queuePersistence: queue
    )
    let userInfo: [AnyHashable: Any] = [
      "data": [
        "scenario_id": "N-01",
        "notification_id": notificationID.uuidString,
        "deep_link": "wingward://match/\(matchID.uuidString)/fox-result",
      ],
    ]

    firstCoordinator.handleNotificationTap(userInfo: userInfo)
    try await Task.sleep(nanoseconds: 20_000_000)
    let persistedTap = try queue.load(ownerID: ownerID).pendingTap
    XCTAssertEqual(persistedTap?.notificationID, notificationID)

    let routeRecorder = RouteRecorder()
    let retryAPI = RecordingNotificationEventsAPI()
    let retryCoordinator = WingwardNotificationCoordinator(
      ownerID: ownerID,
      reporter: WingwardNotificationEventReporter(api: retryAPI),
      onRoute: { route in routeRecorder.routes.append(route) },
      queuePersistence: queue
    )
    _ = retryCoordinator
    try await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertEqual(routeRecorder.routes, [.foxConversationResult(matchID)])
    let clearedTap = try queue.load(ownerID: ownerID).pendingTap
    XCTAssertNil(clearedTap)
    let retriedEvents = await retryAPI.events()
    XCTAssertEqual(retriedEvents.map(\.eventType), [.opened])
  }

  func testKeychainQueueCodecDropsFreeTextAndCanonicalizesPersistedRoutes() throws {
    let ownerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let storage = NotificationQueueKeychainStorageFixture()
    let persistence = WingwardKeychainNotificationQueuePersistence(storage: storage)
    let event = WingwardNotificationEvent(
      notificationID: notificationID,
      eventType: .delivered,
      metadata: [
        "scenario": "N-01",
        "conversation_body": "private conversation and credential text",
      ]
    )
    let validPayload = WingwardNotificationPayload(
      notificationID: notificationID,
      scenario: .n01,
      deepLink: "wingward://match/\(matchID.uuidString.uppercased())/fox-result"
    )
    let secretQueryPayload = WingwardNotificationPayload(
      notificationID: notificationID,
      scenario: .n01,
      deepLink: "wingward://match/\(matchID.uuidString)/fox-result?access_token=not-for-storage"
    )

    try persistence.save(
      WingwardNotificationPendingWork(events: [event], pendingTap: validPayload),
      ownerID: ownerID
    )
    let restored = try persistence.load(ownerID: ownerID)
    XCTAssertEqual(restored.events.first?.metadata, ["scenario": "N-01"])
    XCTAssertEqual(
      restored.pendingTap?.deepLink,
      "wingward://match/\(matchID.uuidString.lowercased())/fox-result"
    )

    try persistence.save(
      WingwardNotificationPendingWork(pendingTap: secretQueryPayload),
      ownerID: ownerID
    )
    let restoredSecretQuery = try persistence.load(ownerID: ownerID).pendingTap
    XCTAssertNil(restoredSecretQuery?.deepLink)
    XCTAssertEqual(restoredSecretQuery?.destinationRoute, .notificationLanding(notificationID))
  }

  func testKeychainQueueCodecRejectsCapacityOverflowAndPreservesPreviousSpool() throws {
    let ownerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let storage = NotificationQueueKeychainStorageFixture()
    let persistence = WingwardKeychainNotificationQueuePersistence(storage: storage)
    let events = (0..<500).map { index in
      WingwardNotificationEvent(
        notificationID: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!,
        eventType: .delivered
      )
    }
    try persistence.save(WingwardNotificationPendingWork(events: events), ownerID: ownerID)
    XCTAssertEqual(try persistence.load(ownerID: ownerID).events.count, 500)
    let nextEvent = WingwardNotificationEvent(
      notificationID: UUID(uuidString: "00000000-0000-4000-8000-000000000500")!,
      eventType: .delivered
    )

    XCTAssertThrowsError(
      try persistence.save(
        WingwardNotificationPendingWork(events: events + [nextEvent]),
        ownerID: ownerID
      )
    )
    XCTAssertEqual(try persistence.load(ownerID: ownerID).events, events)

    let coordinator = WingwardNotificationCoordinator(
      ownerID: ownerID,
      queuePersistence: persistence
    )
    let accepted = coordinator.handleForegroundNotification(userInfo: [
      "data": [
        "scenario_id": "N-01",
        "notification_id": nextEvent.notificationID.uuidString,
      ],
    ])
    XCTAssertFalse(accepted)
    XCTAssertEqual(try persistence.load(ownerID: ownerID).events, events)
  }

  func testPersistedSpoolSurvivesCoordinatorRecreationAndDrainsInBatches() async throws {
    let ownerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let storage = NotificationQueueKeychainStorageFixture()
    let initialQueue = WingwardKeychainNotificationQueuePersistence(storage: storage)
    let failedAPI = RecordingNotificationEventsAPI()
    await failedAPI.setFailure(true)
    let failedReporter = WingwardNotificationEventReporter(api: failedAPI)
    let firstCoordinator = WingwardNotificationCoordinator(
      ownerID: ownerID,
      queuePersistence: initialQueue
    )

    for index in 0..<101 {
      let notificationID = UUID(
        uuidString: String(format: "00000000-0000-4000-8000-%012d", index)
      )!
      XCTAssertTrue(firstCoordinator.handleForegroundNotification(userInfo: [
        "data": [
          "scenario_id": "N-01",
          "notification_id": notificationID.uuidString,
        ],
      ]))
    }
    XCTAssertEqual(try initialQueue.load(ownerID: ownerID).events.count, 101)

    firstCoordinator.bind(reporter: failedReporter)
    for _ in 0..<100 {
      if await failedAPI.attemptCount() == 100 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let failedAttemptCount = await failedAPI.attemptCount()
    XCTAssertEqual(failedAttemptCount, 100)
    XCTAssertEqual(try initialQueue.load(ownerID: ownerID).events.count, 101)

    let restartedQueue = WingwardKeychainNotificationQueuePersistence(storage: storage)
    let retryAPI = RecordingNotificationEventsAPI()
    let retryReporter = WingwardNotificationEventReporter(api: retryAPI)
    let restartedCoordinator = WingwardNotificationCoordinator(
      ownerID: ownerID,
      reporter: retryReporter,
      queuePersistence: restartedQueue
    )
    _ = restartedCoordinator

    for _ in 0..<200 {
      if await retryAPI.events().count == 101 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    let acknowledgedEvents = await retryAPI.events()
    XCTAssertEqual(acknowledgedEvents.count, 101)
    XCTAssertTrue(try restartedQueue.load(ownerID: ownerID).events.isEmpty)
  }

  func testOpenedTapCountsTowardTheOneHundredRequestBatchLimit() async throws {
    let ownerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let queue = NotificationQueuePersistenceFixture()
    let api = HoldingNotificationEventsAPI()
    let coordinator = WingwardNotificationCoordinator(
      ownerID: ownerID,
      reporter: WingwardNotificationEventReporter(api: api),
      queuePersistence: queue
    )

    for index in 0..<99 {
      let notificationID = UUID(
        uuidString: String(format: "10000000-0000-4000-8000-%012d", index)
      )!
      XCTAssertTrue(coordinator.handleForegroundNotification(userInfo: [
        "data": [
          "scenario_id": "N-01",
          "notification_id": notificationID.uuidString,
        ],
      ]))
    }
    for _ in 0..<100 {
      if await api.metrics().startedCount == 99 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let foregroundMetrics = await api.metrics()
    XCTAssertEqual(foregroundMetrics.startedCount, 99)

    let tapPayload: [AnyHashable: Any] = [
      "data": [
        "scenario_id": "N-01",
        "notification_id": "22222222-2222-4222-8222-222222222222",
      ],
    ]
    XCTAssertTrue(coordinator.handleNotificationTap(userInfo: tapPayload))
    for _ in 0..<100 {
      if await api.metrics().startedCount == 100 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(coordinator.recordDismissed())
    try await Task.sleep(nanoseconds: 20_000_000)

    let fullBatchMetrics = await api.metrics()
    XCTAssertEqual(fullBatchMetrics.startedCount, 100)
    XCTAssertEqual(fullBatchMetrics.activeCount, 100)

    await api.releaseAll()
    for _ in 0..<200 {
      let metrics = await api.metrics()
      let remainingWork = try queue.load(ownerID: ownerID)
      if metrics.startedCount == 101,
        metrics.activeCount == 0,
        remainingWork.events.isEmpty,
        remainingWork.pendingTap == nil
      {
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    let drainedMetrics = await api.metrics()
    let remainingWork = try queue.load(ownerID: ownerID)
    XCTAssertEqual(drainedMetrics.startedCount, 101)
    XCTAssertLessThanOrEqual(drainedMetrics.maximumActiveCount, 100)
    XCTAssertTrue(remainingWork.events.isEmpty)
    XCTAssertNil(remainingWork.pendingTap)
  }

  func testSeenAPIFailureKeepsBadgeAndRetryClearsOnlyAfterAcknowledgement() async throws {
    let ownerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let persistence = NotificationBadgePersistenceFixture()
    persistence.save(count: 1, ownerID: ownerID)
    let seenAPI = RecordingNotificationSeenAPI()
    await seenAPI.setFailure(true)
    let model = WingwardNotificationPermissionModel(
      ownerID: ownerID,
      permissionClient: NotificationPermissionClientFixture(status: .denied),
      badgePersistence: persistence,
      seenAPI: seenAPI
    )

    await model.markPendingResultsSeen()
    XCTAssertEqual(model.pendingBadgeCount, 1)
    XCTAssertNotNil(model.seenError)
    XCTAssertEqual(persistence.count(ownerID: ownerID), 1)

    await seenAPI.setFailure(false)
    await model.markPendingResultsSeen()
    XCTAssertEqual(model.pendingBadgeCount, 0)
    XCTAssertNil(model.seenError)
    XCTAssertEqual(persistence.count(ownerID: ownerID), 0)
    let seenAttempts = await seenAPI.calls()
    XCTAssertEqual(seenAttempts, 2)
  }
}

@MainActor
private final class NotificationPermissionClientFixture: WingwardNotificationPermissionClient {
  private(set) var status: WingwardNotificationAuthorization
  private var calls = 0

  init(status: WingwardNotificationAuthorization) {
    self.status = status
  }

  func authorizationStatus() async -> WingwardNotificationAuthorization { status }

  func requestAuthorization() async -> WingwardNotificationAuthorization {
    calls += 1
    status = .denied
    return status
  }

  func openSettings() {}

  func requestCalls() -> Int { calls }
}

@MainActor
private final class NotificationBadgePersistenceFixture: WingwardNotificationBadgePersistence {
  private var values: [String: Int] = [:]

  func count(ownerID: String) -> Int { values[ownerID] ?? 0 }

  func save(count: Int, ownerID: String) { values[ownerID] = count }
}

@MainActor
private final class NotificationQueuePersistenceFixture: WingwardNotificationQueuePersistence {
  private var values: [String: WingwardNotificationPendingWork] = [:]

  func load(ownerID: String) throws -> WingwardNotificationPendingWork {
    values[ownerID] ?? .init()
  }

  func save(_ work: WingwardNotificationPendingWork, ownerID: String) throws {
    guard work.events.count <= WingwardKeychainNotificationQueuePersistence.maximumEventCount else {
      throw APIClientError.invalidRequest
    }
    values[ownerID] = work
  }
}

@MainActor
private final class NotificationQueueKeychainStorageFixture: WingwardNotificationQueueKeychainStorage {
  private var values: [String: Data] = [:]

  func store(key: String, value: Data) throws { values[key] = value }
  func retrieve(key: String) throws -> Data? { values[key] }
  func remove(key: String) throws { values.removeValue(forKey: key) }
}

private actor RecordingNotificationEventsAPI: WingwardNotificationEventsAPI {
  private var recordedEvents: [WingwardNotificationEvent] = []
  private var shouldFail = false
  private var attemptedEventCount = 0

  func record(_ event: WingwardNotificationEvent) async throws {
    attemptedEventCount += 1
    if shouldFail { throw APIClientError.temporarilyUnavailable }
    recordedEvents.append(event)
  }

  func setFailure(_ value: Bool) { shouldFail = value }

  func events() -> [WingwardNotificationEvent] { recordedEvents }
  func attemptCount() -> Int { attemptedEventCount }
}

private actor RecordingNotificationSeenAPI: WingwardNotificationSeenAPI {
  private var seenCalls = 0
  private var shouldFail = false

  func markSeen() async throws -> Date {
    seenCalls += 1
    if shouldFail { throw APIClientError.temporarilyUnavailable }
    return Date(timeIntervalSince1970: 1_789_027_200)
  }

  func setFailure(_ value: Bool) { shouldFail = value }
  func calls() -> Int { seenCalls }
}

private actor HoldingNotificationEventsAPI: WingwardNotificationEventsAPI {
  struct Metrics: Sendable {
    let startedCount: Int
    let activeCount: Int
    let maximumActiveCount: Int
  }

  private var startedCount = 0
  private var activeCount = 0
  private var maximumActiveCount = 0
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func record(_ event: WingwardNotificationEvent) async throws {
    startedCount += 1
    activeCount += 1
    maximumActiveCount = max(maximumActiveCount, activeCount)
    if !released {
      await withCheckedContinuation { waiters.append($0) }
    }
    activeCount -= 1
  }

  func releaseAll() {
    released = true
    let pendingWaiters = waiters
    waiters.removeAll()
    pendingWaiters.forEach { $0.resume() }
  }

  func metrics() -> Metrics {
    Metrics(
      startedCount: startedCount,
      activeCount: activeCount,
      maximumActiveCount: maximumActiveCount
    )
  }
}

@MainActor
private final class RouteRecorder {
  var routes: [AppRoute] = []
}

@MainActor
private final class SeenRecorder {
  var count = 0
}

private actor NotificationAuthService: AuthService {
  private var session: AuthSession?

  init(session: AuthSession?) {
    self.session = session
  }

  func currentSession() async throws -> AuthSession? { session }
  func setSession(_ value: AuthSession?) { session = value }
  func signUp(email: String, password: String, redirectTo: URL) async throws -> AuthSession? { throw AuthServiceError.unavailable }
  func signIn(email: String, password: String) async throws -> AuthSession { throw AuthServiceError.unavailable }
  func resetPasswordForEmail(email: String, redirectTo: URL) async throws { throw AuthServiceError.unavailable }
  func updatePassword(_ password: String) async throws { throw AuthServiceError.unavailable }
  func handleCallback(_ url: URL) async throws -> AuthSession { throw AuthServiceError.unavailable }
  func signOut() async throws { session = nil }
}

private struct NotificationProfileAPI: ProfileAPI {
  let profiles: [String: String]

  func fetchProfile(accessToken: String) async throws -> UserProfile {
    guard let id = profiles[accessToken] else { throw ProfileAPIError.requestFailed }
    return UserProfile(id: id, ageVerified: true, onboardingStatus: "confirmed")
  }

  func verifyAge(accessToken: String, birthDate: String) async throws {}
}

private actor NotificationTransport: APIHTTPTransport {
  struct RecordedRequest: Sendable {
    let path: String
    let authorization: String?
  }

  private let responseData: Data
  private var requests: [RecordedRequest] = []

  init(responseData: Data) {
    self.responseData = responseData
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(
      RecordedRequest(
        path: request.url?.path ?? "",
        authorization: request.value(forHTTPHeaderField: "Authorization")
      )
    )
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: 201,
        httpVersion: "HTTP/2",
        headerFields: nil
      )
    else {
      throw APIClientError.invalidResponse
    }
    return (responseData, response)
  }

  func requestCount() -> Int { requests.count }
}
