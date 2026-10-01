import Foundation
import XCTest
@testable import Wingward

@MainActor
final class ConversationInsightTests: XCTestCase {
  private let ownerID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let insightID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  private let otherOwnerID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

  func testDTODecodesOnlyTheClosedInsightSlice() throws {
    let insight = try APIResponseDecoder.decode(
      envelope("""
      {
        "id":"22222222-2222-4222-8222-222222222222",
        "user_id":"11111111-1111-4111-8111-111111111111",
        "personality_tags":["Listens carefully","Builds trust slowly"],
        "status":"ready",
        "interaction_style":{"overall_signature":"A saved conversation signature."},
        "raw_profile":{"private":"must stay server-side"},
        "numeric_scores":{"overall":0.99},
        "profile_score":0.99
      }
      """),
      as: OwnInsight.self
    )

    XCTAssertEqual(insight.id, insightID)
    XCTAssertEqual(insight.userID, ownerID)
    XCTAssertEqual(insight.personalityTags, ["Listens carefully", "Builds trust slowly"])
    XCTAssertEqual(insight.status, "ready")
    XCTAssertEqual(insight.overallSignature, "A saved conversation signature.")
  }

  func testDTORejectsUnboundedTagsAndSignature() {
    let tooManyTags = Array(repeating: "tag", count: OwnInsight.maxTagCount + 1)
      .map { "\"\($0)\"" }
      .joined(separator: ",")
    assertInvalidResponse(
      envelope("""
      {
        "id":"22222222-2222-4222-8222-222222222222",
        "user_id":"11111111-1111-4111-8111-111111111111",
        "personality_tags":[\(tooManyTags)],
        "status":"ready"
      }
      """),
      as: OwnInsight.self
    )

    assertInvalidResponse(
      envelope("""
      {
        "id":"22222222-2222-4222-8222-222222222222",
        "user_id":"11111111-1111-4111-8111-111111111111",
        "personality_tags":["\(String(repeating: "x", count: OwnInsight.maxTagLength + 1))"],
        "status":"ready"
      }
      """),
      as: OwnInsight.self
    )

    assertInvalidResponse(
      envelope("""
      {
        "id":"22222222-2222-4222-8222-222222222222",
        "user_id":"11111111-1111-4111-8111-111111111111",
        "personality_tags":[],
        "status":"ready",
        "interaction_style":{"overall_signature":"\(String(repeating: "x", count: OwnInsight.maxSignatureLength + 1))"}
      }
      """),
      as: OwnInsight.self
    )
  }

  func testDTOAcceptsOmittedAndNullSignature() throws {
    let omitted = try APIResponseDecoder.decode(
      envelope("""
      {
        "id":"22222222-2222-4222-8222-222222222222",
        "user_id":"11111111-1111-4111-8111-111111111111",
        "personality_tags":[],
        "status":"draft"
      }
      """),
      as: OwnInsight.self
    )
    let null = try APIResponseDecoder.decode(
      envelope("""
      {
        "id":"22222222-2222-4222-8222-222222222222",
        "user_id":"11111111-1111-4111-8111-111111111111",
        "personality_tags":[],
        "status":"draft",
        "interaction_style":{"overall_signature":null}
      }
      """),
      as: OwnInsight.self
    )

    XCTAssertNil(omitted.overallSignature)
    XCTAssertNil(null.overallSignature)
  }

  func testConfirmedMeetupPreferencesAppearWithoutReplacingOriginalInsight() throws {
    let insight = try decodeWithPersona("""
      {"version":1,"traits":{"rhythm_preference":"slow","priority_value":"community","communication_preference":"balanced"},"confirmed_at":"2026-09-30T16:06:37.046Z"}
      """)
    XCTAssertEqual(insight.overallSignature, "Original saved signature")
    XCTAssertEqual(insight.personalityTags, ["Original tag"])
    XCTAssertEqual(insight.latestConfirmedPersona?.version, 1)
    XCTAssertEqual(insight.latestConfirmedPersona?.traits.count, 3)
    XCTAssertEqual(insight.latestConfirmedPersona?.traits.first?.key, .communicationPreference)
    XCTAssertFalse(insight.latestConfirmedPersonaUnavailable)
  }

  func testInvalidOptionalPersonaKeepsOriginalInsightAndMarksOverlayUnavailable() throws {
    for invalid in [
      #"{"version":0,"traits":{},"confirmed_at":"2026-09-30T16:06:37Z"}"#,
      #"{"version":1,"traits":{"rhythm_preference":"community"},"confirmed_at":"2026-09-30T16:06:37Z"}"#,
      #"{"version":1,"traits":{"unknown":"slow"},"confirmed_at":"2026-09-30T16:06:37Z"}"#,
      #"{"version":1,"traits":{},"confirmed_at":"invalid"}"#
    ] {
      let insight = try decodeWithPersona(invalid)
      XCTAssertEqual(insight.overallSignature, "Original saved signature")
      XCTAssertNil(insight.latestConfirmedPersona)
      XCTAssertTrue(insight.latestConfirmedPersonaUnavailable)
    }
    let absent = try decodeWithPersona("null")
    XCTAssertNil(absent.latestConfirmedPersona)
    XCTAssertFalse(absent.latestConfirmedPersonaUnavailable)
  }

  func testCanonicalPreferencesStayVisibleWhenHistoryIsUnavailable() throws {
    let insight = try decodeWithPersona("null", canonical: #"{"rhythm_preference":"slow","priority_value":"community","communication_preference":"balanced"}"#)
    XCTAssertEqual(insight.profileVersion, 2)
    XCTAssertEqual(insight.personalityTags, ["Original tag"])
    XCTAssertEqual(insight.overallSignature, "Original saved signature")
    XCTAssertEqual(insight.currentPreferences.count, 3)
    XCTAssertNil(insight.currentPreferenceChanges)
  }

  func testCurrentPreferencesUseCanonicalSavedValuesAndOnlyMatchingChangeMetadata() throws {
    let persona = #"{"version":1,"traits":{"rhythm_preference":"slow"},"confirmed_at":"2026-09-30T16:06:37Z","changes":{"compared_to_version":null,"added_keys":["rhythm_preference"],"changed_keys":[]}}"#
    let matching = try decodeWithPersona(persona, canonical: #"{"rhythm_preference":"slow"}"#)
    XCTAssertEqual(matching.currentPreferenceChanges?.addedKeys, [.rhythmPreference])
    let newerCanonical = try decodeWithPersona(persona, canonical: #"{"rhythm_preference":"fast"}"#)
    XCTAssertEqual(newerCanonical.currentPreferences.first?.value, .fast)
    XCTAssertNil(newerCanonical.currentPreferenceChanges)
  }

  func testChangedAndUnchangedPreferencesAreDistinguishedAndInvalidComparisonIsIgnored() throws {
    let insight = try decodeWithPersona(#"{"version":2,"traits":{"rhythm_preference":"fast","priority_value":"community"},"confirmed_at":"2026-09-30T16:06:37Z","changes":{"compared_to_version":1,"added_keys":[],"changed_keys":["rhythm_preference"]}}"#)
    XCTAssertEqual(insight.currentPreferenceChanges?.changedKeys, [.rhythmPreference])
    XCTAssertEqual(insight.currentPreferenceChanges?.addedKeys, [])
    let invalid = try decodeWithPersona(#"{"version":2,"traits":{"rhythm_preference":"fast"},"confirmed_at":"2026-09-30T16:06:37Z","changes":{"compared_to_version":0,"added_keys":[],"changed_keys":["rhythm_preference"]}}"#)
    XCTAssertEqual(invalid.currentPreferences.count, 1)
    XCTAssertNil(invalid.currentPreferenceChanges)
    XCTAssertTrue(invalid.latestConfirmedPersona?.changesUnavailable == true)
  }

  private func decodeWithPersona(_ persona: String, canonical: String? = nil) throws -> OwnInsight {
    let savedPreferences = canonical.map { ",\"version\":2,\"confirmed_preferences\":\($0)" } ?? ""
    return try APIResponseDecoder.decode(envelope("""
      {"id":"22222222-2222-4222-8222-222222222222","user_id":"11111111-1111-4111-8111-111111111111",
       "personality_tags":["Original tag"],"status":"ready","interaction_style":{"overall_signature":"Original saved signature"},
       "latest_confirmed_persona":\(persona)\(savedPreferences)}
      """), as: OwnInsight.self)
  }

  func testLiveAPIReadsProfilesMeThroughTheAuthenticatedClient() async throws {
    let client = FakeAuthenticatedAPIClient()
    let request = APIRequest(method: .get, path: LiveConversationInsightAPI.profilePath)
    await client.setResponseData(insightResponse(), for: request)

    let api = LiveConversationInsightAPI(client: client)
    let insight = try await api.fetchInsight()

    XCTAssertEqual(insight.userID, ownerID)
    let requests = await client.recordedRequests()
    XCTAssertEqual(requests, [request])
  }

  func testFactoryBindsTheVerifiedOwnerBeforeTransport() async throws {
    let auth = InsightAuthService(session: AuthSession(accessToken: "owner-token"))
    let profile = InsightProfileAPI(profile: UserProfile(id: ownerID.uuidString, ageVerified: true))
    let transport = FakeAPIHTTPTransport(
      outcome: .response(data: insightResponse(), statusCode: 200, headers: [:])
    )
    let factory = LiveConversationInsightAPIFactory(
      baseURL: URL(string: "https://api.example.test")!,
      authService: auth,
      profileAPI: profile,
      transport: transport
    )
    let api = try XCTUnwrap(factory.make(ownerID: ownerID.uuidString))

    let insight = try await api.fetchInsight()

    XCTAssertEqual(insight.id, insightID)
    let requests = await transport.requests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.url.path, LiveConversationInsightAPI.profilePath)
    XCTAssertEqual(requests.first?.headers["Authorization"], "Bearer owner-token")
  }

  func testStoreRejectsAResponseForAnotherOwner() async {
    let api = SequencedInsightAPI(outcomes: [.success(fixture(userID: otherOwnerID))])
    let store = ConversationInsightStore(ownerID: ownerID.uuidString, api: api)

    await store.load().value

    XCTAssertEqual(store.phase, .failed(.ownerMismatch))
    XCTAssertNil(store.insight)
  }

  func testStoreDropsStaleGenerationAndKeepsTheNewestOwnedInsight() async {
    let oldInsight = fixture(
      id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
      signature: "old"
    )
    let newInsight = fixture(
      id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
      signature: "new"
    )
    let api = DelayedFirstInsightAPI(first: oldInsight, second: newInsight)
    let store = ConversationInsightStore(ownerID: ownerID.uuidString, api: api)

    let oldTask = store.load()
    let firstCallObserved = await api.waitForCallCount(1)
    XCTAssertTrue(firstCallObserved)
    let newTask = store.load()
    let secondCallObserved = await api.waitForCallCount(2)
    XCTAssertTrue(secondCallObserved)

    await newTask.value
    await api.releaseFirst()
    await oldTask.value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.insight?.id, newInsight.id)
    XCTAssertEqual(store.insight?.overallSignature, "new")
  }

  func testStoreCancelClearsProtectedContentAndIgnoresLateResult() async {
    let api = DelayedFirstInsightAPI(first: fixture(signature: "late"), second: fixture())
    let store = ConversationInsightStore(ownerID: ownerID.uuidString, api: api)

    let task = store.load()
    let callObserved = await api.waitForCallCount(1)
    XCTAssertTrue(callObserved)
    store.cancel()
    await api.releaseFirst()
    await task.value

    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.insight)
  }

  func testStoreFailureClearsPreviouslyLoadedInsight() async {
    let api = SequencedInsightAPI(
      outcomes: [.success(fixture()), .failure(.temporarilyUnavailable)]
    )
    let store = ConversationInsightStore(ownerID: ownerID.uuidString, api: api)

    await store.load().value
    await store.retry().value

    XCTAssertEqual(store.phase, .failed(.temporarilyUnavailable))
    XCTAssertNil(store.insight)
  }

  func testStoreExposesOwnedSuccessfulDisplayState() async {
    let insight = fixture(
      signature: "Saved signature",
      tags: ["Listens carefully", "Builds trust slowly"]
    )
    let api = SequencedInsightAPI(outcomes: [.success(insight)])
    let store = ConversationInsightStore(ownerID: ownerID.uuidString, api: api)

    await store.load().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.insight, insight)
    XCTAssertEqual(store.insight?.personalityTags, insight.personalityTags)
    XCTAssertEqual(store.insight?.overallSignature, insight.overallSignature)
  }

  private func fixture(
    id: UUID? = nil,
    userID: UUID? = nil,
    signature: String? = "Saved signature",
    tags: [String] = ["Listens carefully"]
  ) -> OwnInsight {
    OwnInsight(
      id: id ?? insightID,
      userID: userID ?? ownerID,
      personalityTags: tags,
      status: "ready",
      overallSignature: signature
    )
  }

  private func insightResponse() -> Data {
    envelope("""
    {
      "id":"22222222-2222-4222-8222-222222222222",
      "user_id":"11111111-1111-4111-8111-111111111111",
      "personality_tags":["Listens carefully"],
      "status":"ready",
      "interaction_style":{"overall_signature":"Saved signature"}
    }
    """)
  }

  private func envelope(_ data: String) -> Data {
    Data(("{\"data\":" + data + "}").utf8)
  }

  private func assertInvalidResponse<Value: APIValidatable>(
    _ data: Data,
    as type: Value.Type
  ) {
    do {
      _ = try APIResponseDecoder.decode(data, as: type)
      XCTFail("Malformed response must fail closed")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidResponse)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}

private actor SequencedInsightAPI: ConversationInsightAPI {
  enum Outcome: Sendable {
    case success(OwnInsight)
    case failure(APIClientError)
  }

  private var outcomes: [Outcome]

  init(outcomes: [Outcome]) {
    self.outcomes = outcomes
  }

  func fetchInsight() async throws -> OwnInsight {
    let outcome = outcomes.isEmpty ? .failure(.temporarilyUnavailable) : outcomes.removeFirst()
    switch outcome {
    case let .success(insight): return insight
    case let .failure(error): throw error
    }
  }
}

private actor DelayedFirstInsightAPI: ConversationInsightAPI {
  private let first: OwnInsight
  private let second: OwnInsight
  private var callCount = 0
  private var firstContinuation: CheckedContinuation<OwnInsight, Error>?

  init(first: OwnInsight, second: OwnInsight) {
    self.first = first
    self.second = second
  }

  func fetchInsight() async throws -> OwnInsight {
    let currentCall = callCount
    callCount += 1
    if currentCall == 0 {
      return try await withCheckedThrowingContinuation { continuation in
        firstContinuation = continuation
      }
    }
    return second
  }

  func waitForCallCount(_ expected: Int) async -> Bool {
    for _ in 0..<200 {
      if callCount >= expected { return true }
      do {
        try await Task.sleep(nanoseconds: 1_000_000)
      } catch {
        return false
      }
    }
    return callCount >= expected
  }

  func releaseFirst() {
    firstContinuation?.resume(returning: first)
    firstContinuation = nil
  }
}

private struct InsightAuthService: AuthService {
  let session: AuthSession?

  func currentSession() async throws -> AuthSession? { session }
  func signUp(email: String, password: String, redirectTo: URL) async throws -> AuthSession? { session }
  func signIn(email: String, password: String) async throws -> AuthSession {
    session ?? AuthSession(accessToken: "")
  }
  func resetPasswordForEmail(email: String, redirectTo: URL) async throws {}
  func updatePassword(_ password: String) async throws {}
  func handleCallback(_ url: URL) async throws -> AuthSession {
    session ?? AuthSession(accessToken: "")
  }
  func signOut() async throws {}
}

private struct InsightProfileAPI: ProfileAPI {
  let profile: UserProfile

  func fetchProfile(accessToken: String) async throws -> UserProfile { profile }
  func verifyAge(accessToken: String, birthDate: String) async throws {}
}
