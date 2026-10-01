import Foundation
import XCTest
@testable import Wingward

@MainActor
final class MeetupsTests: XCTestCase {
  private let ownerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  private let otherOwnerID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  private let meetupID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let matchID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  private let otherMatchID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
  private let proposalID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

  func testLiveAPIUsesFrozenPathsAndClosedRequestBodies() async throws {
    let client = FakeAuthenticatedAPIClient()
    let api = LiveMeetupsAPI(client: client)

    let intentRequest = APIRequest(method: .post, path: LiveMeetupsAPI.intentsPath)
    await client.setResponseData(Data(#"{"data":{"accepted":true}}"#.utf8), for: intentRequest)
    _ = try await api.createIntent(matchID: matchID)

    let detailRequest = APIRequest(method: .get, path: LiveMeetupsAPI.meetupPath(for: meetupID))
    await client.setResponseData(detailFixture(status: "verifying"), for: detailRequest)
    _ = try await api.fetchMeetup(id: meetupID)

    let preferences = MeetupPreferences(
      availability: [
        MeetupAvailability(
          startsAt: Date(timeIntervalSince1970: 1_800_000_000),
          endsAt: Date(timeIntervalSince1970: 1_800_003_600)
        )
      ],
      areas: ["Tokyo/Chiyoda"],
      budgetBand: .medium,
      formats: [.cafe]
    )
    let preferencesRequest = APIRequest(
      method: .put,
      path: LiveMeetupsAPI.meetupPreferencesPath(for: meetupID)
    )
    await client.setResponseData(Data(#"{"data":{"saved":true}}"#.utf8), for: preferencesRequest)
    _ = try await api.savePreferences(meetupID: meetupID, preferences: preferences)

    let arrangeRequest = APIRequest(method: .post, path: LiveMeetupsAPI.arrangePath(for: meetupID))
    await client.setResponseData(Data(#"{"data":{"accepted":true,"status":"arranging"}}"#.utf8), for: arrangeRequest)
    _ = try await api.arrange(meetupID: meetupID)

    let responseRequest = APIRequest(
      method: .post,
      path: LiveMeetupsAPI.responsePath(for: meetupID, proposalID: proposalID)
    )
    await client.setResponseData(Data(#"{"data":{"accepted":true,"status":"proposed"}}"#.utf8), for: responseRequest)
    _ = try await api.respond(
      meetupID: meetupID,
      proposalID: proposalID,
      selectedCandidateIndex: 1
    )

    let requests = await client.recordedRequests()
    XCTAssertEqual(requests.map(\.method), [.post, .get, .put, .post, .post])
    XCTAssertEqual(requests.map(\.path), [
      LiveMeetupsAPI.intentsPath,
      LiveMeetupsAPI.meetupPath(for: meetupID),
      LiveMeetupsAPI.meetupPreferencesPath(for: meetupID),
      LiveMeetupsAPI.arrangePath(for: meetupID),
      LiveMeetupsAPI.responsePath(for: meetupID, proposalID: proposalID),
    ])
    XCTAssertNil(requests[3].body)
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: requests[0].body ?? Data()) as? [String: String],
      ["match_id": matchID.uuidString.lowercased()]
    )
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: requests[4].body ?? Data()) as? [String: Int],
      ["selected_candidate_index": 1]
    )
  }

  func testLiveAPIFetchesMeetupByMatchUsingTheRecoveryPath() async throws {
    let client = FakeAuthenticatedAPIClient()
    let api = LiveMeetupsAPI(client: client)
    let request = APIRequest(method: .get, path: LiveMeetupsAPI.meetupPath(forMatchID: matchID))
    await client.setResponseData(detailFixture(status: "verifying"), for: request)

    let detail = try await api.fetchMeetup(matchID: matchID)

    XCTAssertEqual(detail.matchID, matchID)
    let requests = await client.recordedRequests()
    XCTAssertEqual(requests.map(\.method), [.get])
    XCTAssertEqual(requests.map(\.path), [LiveMeetupsAPI.meetupPath(forMatchID: matchID)])
  }

  func testMalformedMeetupIdentityAndStateFailClosed() throws {
    let malformedIdentity = Data(
      #"{"data":{"id":"11111111-1111-4111-8111-111111111111","match_id":"not-a-uuid","status":"verifying","proposal":null,"confirmed_candidate":null,"expires_at":null}}"#.utf8
    )
    XCTAssertThrowsError(try APIResponseDecoder.decode(malformedIdentity, as: MeetupDetail.self)) { error in
      XCTAssertEqual(error as? APIClientError, .invalidResponse)
    }

    let malformedCandidates = Data(
      #"{"data":{"id":"11111111-1111-4111-8111-111111111111","match_id":"22222222-2222-4222-8222-222222222222","status":"proposed","proposal":{"id":"33333333-3333-4333-8333-333333333333","candidates":[{"starts_at":"2026-09-10T10:00:00+09:00","timezone":"Asia/Tokyo","area":"Tokyo","format":"cafe","rationale":"one"}],"expires_at":null},"confirmed_candidate":null,"expires_at":null}}"#.utf8
    )
    XCTAssertThrowsError(try APIResponseDecoder.decode(malformedCandidates, as: MeetupDetail.self)) { error in
      XCTAssertEqual(error as? APIClientError, .invalidResponse)
    }
  }

  func testStoreRejectsFetchedMeetupForAnotherExpectedMatch() async {
    let api = FakeMeetupsAPI(
      detail: MeetupDetail(id: meetupID, matchID: otherMatchID, status: .verifying)
    )
    let store = MeetupStore(ownerID: ownerID, meetupID: meetupID, matchID: matchID, api: api)

    await store.load().value

    XCTAssertEqual(store.phase, .failed(.invalidResponse))
    XCTAssertNil(store.detail)
  }

  func testMeetupStoreDiscoversMutualMeetupByMatch() async {
    let api = FakeMeetupsAPI(detail: verifyingDetail())
    let store = MeetupStore(ownerID: ownerID, matchID: matchID, api: api)

    await store.load().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.meetupID, meetupID)
    XCTAssertEqual(store.detail?.matchID, matchID)
    XCTAssertTrue(store.intentAccepted)
    XCTAssertEqual(store.viewState, .verifying(.required))
  }

  func testMeetupStoreKeepsAcceptedIntentPendingWhenMatchDiscoveryIsUnavailable() async {
    let api = FakeMeetupsAPI()
    let store = MeetupStore(ownerID: ownerID, matchID: matchID, api: api)

    await store.load().value
    XCTAssertEqual(store.phase, .idle)

    await store.expressIntent().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertNil(store.meetupID)
    XCTAssertNil(store.detail)
    XCTAssertTrue(store.intentAccepted)
    XCTAssertEqual(store.viewState, .intentPending)
  }

  func testMeetupStoreRejectsMatchRecoveryForAnotherMatch() async {
    let api = FakeMeetupsAPI(
      detail: MeetupDetail(id: meetupID, matchID: otherMatchID, status: .verifying),
      allowMismatchedMatchRecovery: true
    )
    let store = MeetupStore(ownerID: ownerID, matchID: matchID, api: api)

    await store.load().value

    XCTAssertEqual(store.phase, .failed(.invalidResponse))
    XCTAssertNil(store.meetupID)
    XCTAssertNil(store.detail)
  }

  func testPartnerSafetyTargetDeliversTheMeetupMatchAndContext() {
    let target = PartnerSafetyTarget.make(matchID: matchID, context: .meetup)
    var received: (UUID, ReportContext)?

    target?.open { matchID, context in
      received = (matchID, context)
    }

    XCTAssertEqual(received?.0, matchID)
    XCTAssertEqual(received?.1, .meetup)
  }

  func testPartnerSafetyTargetFailsClosedWithoutAMatch() {
    let target = PartnerSafetyTarget.make(matchID: nil, context: .meetup)
    var didOpen = false

    target?.open { _, _ in didOpen = true }

    XCTAssertNil(target)
    XCTAssertFalse(didOpen)
  }

  func testMeetupStorePresentsVerificationGateWithoutAClientBypass() async {
    let api = FakeMeetupsAPI(detail: verifyingDetail())
    let store = MeetupStore(ownerID: ownerID, meetupID: meetupID, matchID: matchID, api: api)

    await store.load().value
    XCTAssertEqual(store.viewState, .verifying(.required))
    XCTAssertTrue(store.canArrange)

    await api.setArrangeFailure(.identity)
    await store.arrange().value

    XCTAssertEqual(store.phase, .failed(.identityVerificationRequired))
    XCTAssertEqual(store.viewState, .verifying(.required))
    XCTAssertNil(store.detail?.confirmedCandidate)
  }

  func testGenericConflictDoesNotPretendVerification() async {
    let api = FakeMeetupsAPI(detail: verifyingDetail())
    await api.setArrangeFailure(.api(.invalidState))
    let store = MeetupStore(ownerID: ownerID, meetupID: meetupID, matchID: matchID, api: api)

    await store.load().value
    await store.arrange().value

    XCTAssertEqual(store.phase, .failed(.invalidState))
    XCTAssertEqual(store.viewState, .failed(.invalidState))
  }

  func testMeetIntentNeverBecomesAQuotaPaywall() async {
    let api = FakeMeetupsAPI()
    await api.setIntentFailure(.api(.quotaExhausted(source: .meetupArrange)))
    let store = MeetupStore(ownerID: ownerID, matchID: matchID, api: api)

    await store.expressIntent().value

    XCTAssertEqual(store.phase, .failed(.invalidResponse))
    XCTAssertFalse(store.viewState == .failed(.quotaExhausted(source: .meetupArrange)))
    XCTAssertFalse(store.intentAccepted)
  }

  func testDefaultPreferenceWindowIsOrdered() {
    let start = MeetupPreferenceDefaults.start(now: Date(timeIntervalSince1970: 1_800_000_000))
    let end = MeetupPreferenceDefaults.end(now: Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertGreaterThan(end, start)
    XCTAssertNoThrow(
      try MeetupPreferences(
        availability: [MeetupAvailability(startsAt: start, endsAt: end)],
        areas: ["Tokyo/Chiyoda"],
        budgetBand: .medium,
        formats: [.cafe]
      ).validate()
    )
  }

  func testMeetupDateFormattingUsesTheCandidateTimezoneAndFailsClosed() {
    let instant = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z

    XCTAssertEqual(
      MeetupDateFormatting.dateText(for: instant, timezone: "Asia/Tokyo"),
      "2026-01-01 09:00"
    )
    XCTAssertEqual(
      MeetupDateFormatting.dateText(for: instant, timezone: "America/New_York"),
      "2025-12-31 19:00"
    )
    XCTAssertNil(MeetupDateFormatting.dateText(for: instant, timezone: "Not/AZone"))
  }

  func testConfirmedResponseUsesServerAcceptedProposalAndSelectedCandidate() async {
    let detail = proposedDetail()
    let api = FakeMeetupsAPI(detail: detail)
    await api.setResponseResult(MeetupActionResponse(accepted: true, status: .confirmed))
    let store = MeetupStore(ownerID: ownerID, meetupID: meetupID, matchID: matchID, api: api)

    await store.load().value
    await store.respond(selectedCandidateIndex: 1).value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.detail?.status, .confirmed)
    XCTAssertEqual(store.detail?.confirmedCandidate?.area, "Tokyo/Chiyoda")
    XCTAssertEqual(store.detail?.confirmedCandidate?.format, .meal)
    XCTAssertNil(store.detail?.proposal)
  }

  func testArrangeFailureCanUseTheSeparateRetryPath() async {
    let failedDetail = MeetupDetail(id: meetupID, matchID: matchID, status: .arrangeFailed)
    let api = FakeMeetupsAPI(detail: failedDetail)
    let store = MeetupStore(ownerID: ownerID, meetupID: meetupID, matchID: matchID, api: api)

    await store.load().value
    XCTAssertTrue(store.canRetryArrangement)
    await store.retryArrangement().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.detail?.status, .arranging)
  }

  func testOwnerChangeInvalidatesBoundAPIAndPreventsSubsequentRequests() async {
    let api = FakeMeetupsAPI(detail: verifyingDetail())
    let store = MeetupStore(ownerID: ownerID, meetupID: meetupID, matchID: matchID, api: api)

    store.updateOwner(otherOwnerID)
    await store.load().value
    await store.arrange().value

    XCTAssertEqual(store.phase, .failed(.unauthenticated))
    let fetchCalls = await api.fetchCallCount()
    let arrangeCalls = await api.arrangeCallCount()
    XCTAssertEqual(fetchCalls, 0)
    XCTAssertEqual(arrangeCalls, 0)
    XCTAssertNil(store.detail)
  }

  func testLateLoadCannotPublishAfterCancellation() async {
    let api = BlockingMeetupsAPI(detail: verifyingDetail())
    let store = MeetupStore(ownerID: ownerID, meetupID: meetupID, matchID: matchID, api: api)
    let task = store.load()
    await api.waitUntilFetchStarted()

    store.cancel()
    await api.releaseFetch()
    await task.value

    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.detail)
  }

  func testOwnerChangeCannotPublishLateResponseOrReuseOldBinding() async {
    let api = BlockingMeetupsAPI(detail: verifyingDetail())
    let store = MeetupStore(ownerID: ownerID, meetupID: meetupID, matchID: matchID, api: api)
    let task = store.load()
    await api.waitUntilFetchStarted()

    store.updateOwner(otherOwnerID)
    await api.releaseFetch()
    await task.value
    await store.load().value

    XCTAssertEqual(store.phase, .failed(.unauthenticated))
    XCTAssertNil(store.detail)
    let fetchCalls = await api.fetchCallCount()
    XCTAssertEqual(fetchCalls, 1)
  }

  #if DEBUG
    func testDebugFixtureFactoryBindsOnlyTheSyntheticOwnerAndBuildsRealViews() {
      for scenario in MeetupDebugScenario.allCases {
        _ = MeetupDebugFixture.makeView(scenario: scenario)
        XCTAssertNotNil(MeetupDebugAPIFactory(scenario: scenario).make(ownerID: ownerID))
      }
      XCTAssertNil(
        MeetupDebugAPIFactory(scenario: .proposed).make(ownerID: otherOwnerID)
      )
    }
  #endif

  private func verifyingDetail() -> MeetupDetail {
    MeetupDetail(id: meetupID, matchID: matchID, status: .verifying)
  }

  private func proposedDetail() -> MeetupDetail {
    MeetupDetail(
      id: meetupID,
      matchID: matchID,
      status: .proposed,
      proposal: MeetupProposal(
        id: proposalID,
        candidates: [
          MeetupCandidate(
            startsAt: Date(timeIntervalSince1970: 1_800_000_000),
            timezone: "Asia/Tokyo",
            area: "Tokyo/Chiyoda",
            format: .cafe,
            rationale: "A quiet option"
          ),
          MeetupCandidate(
            startsAt: Date(timeIntervalSince1970: 1_800_003_600),
            timezone: "Asia/Tokyo",
            area: "Tokyo/Chiyoda",
            format: .meal,
            rationale: "A flexible option"
          ),
          MeetupCandidate(
            startsAt: Date(timeIntervalSince1970: 1_800_007_200),
            timezone: "Asia/Tokyo",
            area: "Tokyo/Chiyoda",
            format: .online,
            rationale: "A low-pressure option"
          ),
        ],
        expiresAt: Date(timeIntervalSince1970: 1_800_100_000)
      )
    )
  }

  private func detailFixture(status: String) -> Data {
    Data(
      #"{"data":{"id":"11111111-1111-4111-8111-111111111111","match_id":"22222222-2222-4222-8222-222222222222","status":"\#(status)","proposal":null,"confirmed_candidate":null,"expires_at":null}}"#.utf8
    )
  }
}

private enum FakeMeetupsFailure: Error, Sendable {
  case api(APIClientError)
  case identity
}

private actor FakeMeetupsAPI: MeetupsAPI {
  private var detailValue: MeetupDetail?
  private let allowMismatchedMatchRecovery: Bool
  private var intentFailure: FakeMeetupsFailure?
  private var arrangeFailure: FakeMeetupsFailure?
  private var responseResult = MeetupActionResponse(accepted: true, status: .proposed)
  private var fetchCalls = 0
  private var arrangeCalls = 0

  init(detail: MeetupDetail? = nil, allowMismatchedMatchRecovery: Bool = false) {
    self.detailValue = detail
    self.allowMismatchedMatchRecovery = allowMismatchedMatchRecovery
  }

  func createIntent(matchID: UUID) async throws -> MeetupIntentResponse {
    if let intentFailure { try throwFailure(intentFailure) }
    return MeetupIntentResponse(accepted: true)
  }

  func fetchMeetup(id: UUID) async throws -> MeetupDetail {
    fetchCalls += 1
    guard let detailValue else { throw APIClientError.notFound }
    return detailValue
  }

  func fetchMeetup(matchID: UUID) async throws -> MeetupDetail {
    fetchCalls += 1
    guard let detailValue else { throw APIClientError.notFound }
    guard allowMismatchedMatchRecovery || detailValue.matchID == matchID else { throw APIClientError.notFound }
    return detailValue
  }

  func savePreferences(meetupID: UUID, preferences: MeetupPreferences) async throws -> MeetupPreferencesResponse {
    MeetupPreferencesResponse(saved: true)
  }

  func arrange(meetupID: UUID) async throws -> MeetupActionResponse {
    arrangeCalls += 1
    if let arrangeFailure { try throwFailure(arrangeFailure) }
    return MeetupActionResponse(accepted: true, status: .arranging)
  }

  func retry(meetupID: UUID) async throws -> MeetupActionResponse {
    try await arrange(meetupID: meetupID)
  }

  func respond(meetupID: UUID, proposalID: UUID, selectedCandidateIndex: Int) async throws -> MeetupActionResponse {
    responseResult
  }

  func setIntentFailure(_ failure: FakeMeetupsFailure?) { intentFailure = failure }
  func setArrangeFailure(_ failure: FakeMeetupsFailure?) { arrangeFailure = failure }
  func setResponseResult(_ value: MeetupActionResponse) { responseResult = value }
  func fetchCallCount() -> Int { fetchCalls }
  func arrangeCallCount() -> Int { arrangeCalls }

  private func throwFailure(_ failure: FakeMeetupsFailure) throws {
    switch failure {
    case let .api(error): throw error
    case .identity: throw MeetupAPIError.identityVerificationRequired
    }
  }
}

private actor BlockingMeetupsAPI: MeetupsAPI {
  let detailValue: MeetupDetail
  private var fetchStarted = false
  private var fetchCalls = 0
  private var release = false

  init(detail: MeetupDetail) {
    self.detailValue = detail
  }

  func createIntent(matchID: UUID) async throws -> MeetupIntentResponse {
    MeetupIntentResponse(accepted: true)
  }

  func fetchMeetup(id: UUID) async throws -> MeetupDetail {
    fetchCalls += 1
    fetchStarted = true
    while !release {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    return detailValue
  }

  func fetchMeetup(matchID: UUID) async throws -> MeetupDetail {
    guard detailValue.matchID == matchID else { throw APIClientError.notFound }
    fetchCalls += 1
    fetchStarted = true
    while !release {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    return detailValue
  }

  func savePreferences(meetupID: UUID, preferences: MeetupPreferences) async throws -> MeetupPreferencesResponse {
    MeetupPreferencesResponse(saved: true)
  }

  func arrange(meetupID: UUID) async throws -> MeetupActionResponse {
    MeetupActionResponse(accepted: true, status: .arranging)
  }

  func retry(meetupID: UUID) async throws -> MeetupActionResponse {
    MeetupActionResponse(accepted: true, status: .arranging)
  }

  func respond(meetupID: UUID, proposalID: UUID, selectedCandidateIndex: Int) async throws -> MeetupActionResponse {
    MeetupActionResponse(accepted: true, status: .proposed)
  }

  func waitUntilFetchStarted() async {
    while !fetchStarted {
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
  }

  func releaseFetch() { release = true }
  func fetchCallCount() -> Int { fetchCalls }
}


@MainActor
final class NativePrivacyAdapterTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testCalendarPayloadEncodesOnlyWindowAndBusyIntervals() throws {
    let window = MeetupAvailability(
      startsAt: now.addingTimeInterval(60),
      endsAt: now.addingTimeInterval(3_600)
    )
    let busy = MeetupAvailability(
      startsAt: now.addingTimeInterval(600),
      endsAt: now.addingTimeInterval(1_200)
    )
    let data = try JSONEncoder().encode(NativeBusyCalendarPayload(window: window, busy: [busy]))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(Set(object.keys), Set(["window", "busy"]))

    let encodedWindow = try XCTUnwrap(object["window"] as? [String: Any])
    XCTAssertEqual(Set(encodedWindow.keys), Set(["starts_at", "ends_at"]))
    let encodedBusy = try XCTUnwrap(object["busy"] as? [[String: Any]])
    XCTAssertEqual(encodedBusy.count, 1)
    XCTAssertEqual(Set(encodedBusy[0].keys), Set(["starts_at", "ends_at"]))

    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(json.contains("title"))
    XCTAssertFalse(json.contains("notes"))
    XCTAssertFalse(json.contains("location"))
    XCTAssertFalse(json.contains("attendees"))
  }

  func testCalendarProjectionReadsOnlyDateBoundariesAndClipsIntervals() throws {
    let window = MeetupAvailability(
      startsAt: now.addingTimeInterval(60),
      endsAt: now.addingTimeInterval(3_600)
    )
    let event = NativeCalendarMetadataCanary(
      startsAt: now,
      endsAt: now.addingTimeInterval(300)
    )
    var projection = try NativeBusyCalendarProjection(window: window, now: now)
    try projection.append(event) { ($0.startsAt, $0.endsAt) }

    XCTAssertFalse(event.metadataWasRead)
    XCTAssertEqual(
      projection.payload().busy,
      [MeetupAvailability(startsAt: window.startsAt, endsAt: now.addingTimeInterval(300))]
    )
  }

  func testCalendarProjectionRejectsStaleAndOverlongWindows() {
    let staleWindow = MeetupAvailability(
      startsAt: now.addingTimeInterval(-1),
      endsAt: now.addingTimeInterval(300)
    )
    XCTAssertThrowsError(try NativeBusyCalendarProjection(window: staleWindow, now: now)) {
      XCTAssertEqual($0 as? NativeCalendarPrivacyError, .invalidWindow)
    }

    let overlongWindow = MeetupAvailability(
      startsAt: now.addingTimeInterval(60),
      endsAt: now.addingTimeInterval(NativeBusyCalendarProjection.maximumLookahead + 1)
    )
    XCTAssertThrowsError(try NativeBusyCalendarProjection(window: overlongWindow, now: now)) {
      XCTAssertEqual($0 as? NativeCalendarPrivacyError, .windowExceedsLookahead)
    }
  }

  func testCalendarProjectionFailsClosedAboveIntervalLimit() throws {
    XCTAssertEqual(NativeBusyCalendarProjection.maximumIntervalCount, 128)
    let window = MeetupAvailability(
      startsAt: now.addingTimeInterval(60),
      endsAt: now.addingTimeInterval(NativeBusyCalendarProjection.maximumLookahead)
    )
    var projection = try NativeBusyCalendarProjection(window: window, now: now)
    for index in 0..<NativeBusyCalendarProjection.maximumIntervalCount {
      let start = window.startsAt.addingTimeInterval(TimeInterval(index * 120))
      try projection.append((start, start.addingTimeInterval(60))) { $0 }
    }

    let overflowStart = window.startsAt.addingTimeInterval(
      TimeInterval(NativeBusyCalendarProjection.maximumIntervalCount * 120)
    )
    XCTAssertThrowsError(
      try projection.append((overflowStart, overflowStart.addingTimeInterval(60))) { $0 }
    ) {
      XCTAssertEqual($0 as? NativeCalendarPrivacyError, .tooManyIntervals)
    }
  }

  func testCalendarProjectionRejectsMissingEventDates() throws {
    let window = MeetupAvailability(
      startsAt: now.addingTimeInterval(60),
      endsAt: now.addingTimeInterval(600)
    )
    var projection = try NativeBusyCalendarProjection(window: window, now: now)

    XCTAssertThrowsError(try projection.append(start: nil, end: window.endsAt)) {
      XCTAssertEqual($0 as? NativeCalendarPrivacyError, .invalidInterval)
    }
    XCTAssertThrowsError(try projection.append(start: window.startsAt, end: nil)) {
      XCTAssertEqual($0 as? NativeCalendarPrivacyError, .invalidInterval)
    }
  }

  func testCalendarProjectionExcludesOnlyFreeAndCancelledFlags() {
    XCTAssertFalse(NativeBusyCalendarProjection.shouldIncludeEvent(isFree: true, isCancelled: false))
    XCTAssertFalse(NativeBusyCalendarProjection.shouldIncludeEvent(isFree: false, isCancelled: true))
    XCTAssertFalse(NativeBusyCalendarProjection.shouldIncludeEvent(isFree: true, isCancelled: true))
    XCTAssertTrue(NativeBusyCalendarProjection.shouldIncludeEvent(isFree: false, isCancelled: false))
  }

  func testDeniedAndUnavailableCalendarStatesDoNotAllowBusyReads() async throws {
    XCTAssertEqual(NativeCalendarAuthorization.denied.busyReadError, .denied)
    XCTAssertEqual(NativeCalendarAuthorization.notRequested.busyReadError, .consentRequired)
    XCTAssertEqual(NativeCalendarAuthorization.unavailable.busyReadError, .unavailable)

    let provider = UnavailableNativeBusyCalendarProvider()
    let withoutConsent = await provider.requestAccess(userConfirmedSharing: false)
    let withConsent = await provider.requestAccess(userConfirmedSharing: true)
    XCTAssertEqual(withoutConsent, .notRequested)
    XCTAssertEqual(withConsent, .unavailable)

    let window = MeetupAvailability(
      startsAt: now.addingTimeInterval(60),
      endsAt: now.addingTimeInterval(600)
    )
    do {
      _ = try await provider.readBusy(window: window)
      XCTFail("Unavailable provider must fail closed")
    } catch {
      XCTAssertEqual(error as? NativeCalendarPrivacyError, .unavailable)
    }
  }

  func testLocationProjectionIsPrivateMinimalAndExpiresWithinThirtyMinutes() throws {
    let payload = try NativeLocationConsentPayload(
      station: "Shinjuku",
      latitude: 35.6938,
      longitude: 139.7034,
      nearestStation: "Shinjuku",
      capturedAt: now,
      expiresAt: now.addingTimeInterval(15 * 60)
    )
    let fields = try payload.privateRequestFields(asOf: now.addingTimeInterval(1))
    let data = try JSONEncoder().encode(fields)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys),
      Set(["station", "latitude", "longitude", "nearest_station", "expires_at"])
    )

    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(json.contains("captured_at"))
    XCTAssertFalse(json.contains("title"))
    XCTAssertThrowsError(
      try payload.privateRequestFields(asOf: now.addingTimeInterval(15 * 60))
    ) {
      XCTAssertEqual($0 as? NativeLocationPrivacyError, .stale)
    }

    XCTAssertThrowsError(
      try NativeLocationConsentPayload(
        station: "Shinjuku",
        latitude: nil,
        longitude: nil,
        nearestStation: nil,
        capturedAt: now,
        expiresAt: now.addingTimeInterval(NativeLocationConsentPayload.maximumTTL + 1)
      )
    ) {
      XCTAssertEqual($0 as? NativeLocationPrivacyError, .invalidTTL)
    }
  }

  func testLocationProviderRequiresConsentAndDefaultsUnavailable() async {
    let provider = UnavailableNativeMeetupLocationProvider()
    do {
      _ = try await provider.capture(afterUserConsent: false)
      XCTFail("Location capture must require affirmative UI consent")
    } catch {
      XCTAssertEqual(error as? NativeLocationPrivacyError, .consentRequired)
    }

    do {
      _ = try await provider.capture(afterUserConsent: true)
      XCTFail("Default location provider must remain unavailable")
    } catch {
      XCTAssertEqual(error as? NativeLocationPrivacyError, .unavailable)
    }
  }
}

@MainActor
private final class NativeCalendarMetadataCanary {
  let startsAt: Date
  let endsAt: Date
  private(set) var metadataWasRead = false

  init(startsAt: Date, endsAt: Date) {
    self.startsAt = startsAt
    self.endsAt = endsAt
  }

  var title: String {
    metadataWasRead = true
    return "CANARY_PRIVATE_EVENT_TITLE"
  }
}
