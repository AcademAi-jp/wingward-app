import Foundation
import XCTest
@testable import Wingward

final class OnboardingSettingsTests: XCTestCase {
  private let validSettings = OnboardingSettings(
    uiLocale: .ja,
    datingMarket: .JP,
    conversationLanguage: .en,
    timezone: "Asia/Tokyo",
    distanceUnit: .km,
    genderIdentity: nil,
    preferredGenders: [],
    preferenceMode: .noAnswer,
    locationMode: .notSet,
    stationID: nil,
    coarseAreaID: nil
  )

  func testSettingsEncodingUsesOnlyTheServerSnakeCaseShapeAndExplicitNulls() throws {
    let data = try JSONEncoder().encode(validSettings)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys),
      [
        "ui_locale", "dating_market", "conversation_language", "timezone", "distance_unit",
        "gender_identity", "gender_visibility", "preferred_genders", "preference_mode",
        "location_mode", "station_id", "coarse_area_id"
      ]
    )
    XCTAssertTrue(object["gender_identity"] is NSNull)
    XCTAssertTrue(object["station_id"] is NSNull)
    XCTAssertTrue(object["coarse_area_id"] is NSNull)
    XCTAssertNil(object["id"])
    XCTAssertNil(object["gender_identity_id"])
  }

  func testNullableSettingsPayloadAcceptsPreSaveNull() throws {
    let data = Data(#"{"data":null}"#.utf8)
    let payload = try APIResponseDecoder.decode(data, as: NullableOnboardingSettingsPayload.self)
    XCTAssertNil(payload.settings)
  }

  func testMalformedSettingsResponseFailsClosed() throws {
    let missingNullableKey = Data(#"{"data":{"ui_locale":"ja","dating_market":"JP","conversation_language":"ja","timezone":"Asia/Tokyo","distance_unit":"km","gender_identity":null,"gender_visibility":"private","preferred_genders":[],"preference_mode":"no_answer","location_mode":"not_set","station_id":null}}"#.utf8)
    assertInvalidResponse(missingNullableKey, as: OnboardingSettings.self)

    let invalidNoAnswer = Data(#"{"data":{"ui_locale":"ja","dating_market":"JP","conversation_language":"ja","timezone":"Asia/Tokyo","distance_unit":"km","gender_identity":null,"gender_visibility":"private","preferred_genders":["woman"],"preference_mode":"no_answer","location_mode":"not_set","station_id":null,"coarse_area_id":null}}"#.utf8)
    assertInvalidResponse(invalidNoAnswer, as: OnboardingSettings.self)

    let fixedOffset = Data(#"{"data":{"ui_locale":"ja","dating_market":"JP","conversation_language":"ja","timezone":"+09:00","distance_unit":"km","gender_identity":null,"gender_visibility":"private","preferred_genders":[],"preference_mode":"no_answer","location_mode":"not_set","station_id":null,"coarse_area_id":null}}"#.utf8)
    assertInvalidResponse(fixedOffset, as: OnboardingSettings.self)

    let mismatchedStation = Data(#"{"data":{"ui_locale":"ja","dating_market":"JP","conversation_language":"ja","timezone":"Asia/Tokyo","distance_unit":"km","gender_identity":"woman","gender_visibility":"private","preferred_genders":["woman"],"preference_mode":"selected","location_mode":"station","station_id":"us-ca-sf-powell","coarse_area_id":"us-ca-san-francisco"}}"#.utf8)
    assertInvalidResponse(mismatchedStation, as: OnboardingSettings.self)
  }

  func testOptionsResponseRequiresFixtureTermsAndValidReferences() throws {
    let data = Data(#"{"data":{"stations":[{"id":"jp-tokyo-shimokitazawa","name":"Shimokitazawa","coarse_area_id":"jp-tokyo-setagaya"}],"areas":[{"id":"jp-tokyo-setagaya","name":"Setagaya"}],"terms":{"market":"JP","status":"draft"},"catalog_status":"fixture"}}"#.utf8)
    let options = try APIResponseDecoder.decode(data, as: OnboardingOptions.self)
    XCTAssertEqual(options.terms.market, .JP)
    XCTAssertEqual(options.stations.first?.coarseAreaID, "jp-tokyo-setagaya")

    let malformed = Data(#"{"data":{"stations":[{"id":"station","name":"Station","coarse_area_id":"missing"}],"areas":[],"terms":{"market":"JP","status":"draft"},"catalog_status":"fixture"}}"#.utf8)
    assertInvalidResponse(malformed, as: OnboardingOptions.self)
  }

  func testLiveAdapterUsesExactPathsQueryAndRawPutObject() async throws {
    let client = RecordingOnboardingClient()
    let api = LiveOnboardingSettingsAPI(client: client)

    let fetchedSettings = try await api.fetchSettings()
    XCTAssertNil(fetchedSettings)
    _ = try await api.fetchOptions(market: .JP, locale: .ja)
    _ = try await api.saveSettings(validSettings)

    let requests = await client.requestsSnapshot()
    XCTAssertEqual(requests.map(\.method), [.get, .get, .put])
    XCTAssertEqual(requests[0].path, LiveOnboardingSettingsAPI.settingsPath)
    XCTAssertEqual(requests[1].path, "/api/auth/me/onboarding-options?dating_market=JP&ui_locale=ja")
    XCTAssertEqual(requests[2].path, LiveOnboardingSettingsAPI.settingsPath)
    let body = try XCTUnwrap(requests[2].body)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(object["preference_mode"] as? String, "no_answer")
    XCTAssertTrue(object["station_id"] is NSNull)
  }

  func testLiveAdapterDoesNotSendInvalidSettings() async throws {
    let client = RecordingOnboardingClient()
    let api = LiveOnboardingSettingsAPI(client: client)
    let invalid = OnboardingSettings(
      uiLocale: .ja,
      datingMarket: .JP,
      conversationLanguage: .ja,
      timezone: "Asia/Tokyo",
      distanceUnit: .km,
      genderIdentity: nil,
      preferredGenders: [.woman],
      preferenceMode: .noAnswer,
      locationMode: .notSet,
      stationID: nil,
      coarseAreaID: nil
    )

    do {
      _ = try await api.saveSettings(invalid)
      XCTFail("Invalid settings must be rejected before transport")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidRequest)
    }
    let requests = await client.requestsSnapshot()
    XCTAssertEqual(requests.count, 0)
  }

  func testCapturedOldTokenCanOnlySendAsTheOldOwnerWhileAwaiting() async throws {
    let auth = SwitchableOnboardingAuthService(session: AuthSession(accessToken: "token-a"))
    let profile = GatedOnboardingProfileAPI(profileID: "owner-a")
    let provider = OwnerBoundAuthSessionTokenProvider(
      expectedOwnerID: "owner-a", authService: auth, profileAPI: profile
    )
    let transport = CapturingOnboardingTransport()
    let client = try AuthenticatedAPIClient(
      baseURL: URL(string: "https://api.example.test")!,
      tokenProvider: provider,
      transport: transport
    )

    let requestTask = Task {
      try await client.get(LiveOnboardingSettingsAPI.settingsPath, as: NullableOnboardingSettingsPayload.self)
    }
    await profile.waitUntilStarted()
    await auth.setSession(AuthSession(accessToken: "token-b"))
    await profile.release()

    _ = try await requestTask.value
    let requests = await transport.requestsSnapshot()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token-a")
  }

  func testImmutableOldOwnerAPIRejectsNewSessionBeforePut() async throws {
    let auth = SwitchableOnboardingAuthService(session: AuthSession(accessToken: "token-a"))
    let profile = TokenMappedOnboardingProfileAPI(
      profiles: ["token-a": "owner-a", "token-b": "owner-b"]
    )
    let transport = CapturingOnboardingTransport()
    let oldAPI = try LiveOnboardingSettingsAPI(
      baseURL: URL(string: "https://api.example.test")!,
      ownerID: "owner-a",
      authService: auth,
      profileAPI: profile,
      transport: transport
    )

    await auth.setSession(AuthSession(accessToken: "token-b"))
    do {
      _ = try await oldAPI.saveSettings(validSettings)
      XCTFail("An old owner-bound API must reject a new owner's session")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .unauthenticated)
    }
    let requests = await transport.requestsSnapshot()
    XCTAssertEqual(requests.count, 0)
  }

  func testRecoveryPurposeSessionCannotCreateSettingsRequest() async throws {
    let auth = SwitchableOnboardingAuthService(
      session: AuthSession(accessToken: "recovery-token", purpose: .passwordRecovery)
    )
    let profile = CountingOnboardingProfileAPI(profileID: "owner-a")
    let transport = CapturingOnboardingTransport()
    let api = try LiveOnboardingSettingsAPI(
      baseURL: URL(string: "https://api.example.test")!,
      ownerID: "owner-a",
      authService: auth,
      profileAPI: profile,
      transport: transport
    )

    do {
      _ = try await api.saveSettings(validSettings)
      XCTFail("Recovery-purpose sessions must not reach onboarding settings")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .unauthenticated)
    }

    let requests = await transport.requestsSnapshot()
    XCTAssertEqual(requests.count, 0)
    let profileCalls = await profile.fetchProfileCallCount()
    XCTAssertEqual(profileCalls, 0)
  }

  private func assertInvalidResponse<Value: APIValidatable>(_ data: Data, as type: Value.Type) {
    do {
      _ = try APIResponseDecoder.decode(data, as: type)
      XCTFail("Malformed data should fail closed")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidResponse)
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }
}

private actor RecordingOnboardingClient: AuthenticatedAPIClientProtocol {
  private(set) var requests: [APIRequest] = []

  func send<Value: APIValidatable>(_ request: APIRequest, as type: Value.Type) async throws -> Value {
    requests.append(request)
    if type == NullableOnboardingSettingsPayload.self {
      return NullableOnboardingSettingsPayload(settings: nil) as! Value
    }
    if type == OnboardingOptions.self {
      return OnboardingOptions(
        stations: [OnboardingStation(id: "jp-tokyo-shimokitazawa", name: "Shimokitazawa", coarseAreaID: "jp-tokyo-setagaya")],
        areas: [OnboardingArea(id: "jp-tokyo-setagaya", name: "Setagaya")],
        terms: OnboardingTerms(market: .JP, status: "draft"),
        catalogStatus: "fixture"
      ) as! Value
    }
    if type == OnboardingSettings.self {
      let data = try JSONEncoder().encode(OnboardingSettings(
        uiLocale: .ja,
        datingMarket: .JP,
        conversationLanguage: .en,
        timezone: "Asia/Tokyo",
        distanceUnit: .km,
        genderIdentity: nil,
        preferredGenders: [],
        preferenceMode: .noAnswer,
        locationMode: .notSet,
        stationID: nil,
        coarseAreaID: nil
      ))
      return try JSONDecoder().decode(OnboardingSettings.self, from: data) as! Value
    }
    fatalError("Unexpected test DTO")
  }

  func requestsSnapshot() -> [APIRequest] { requests }
}

private actor SwitchableOnboardingAuthService: AuthService {
  private var session: AuthSession?

  init(session: AuthSession?) { self.session = session }
  func setSession(_ session: AuthSession?) { self.session = session }
  func currentSession() async throws -> AuthSession? { session }
  func signUp(email: String, password: String, redirectTo: URL) async throws -> AuthSession? { session }
  func signIn(email: String, password: String) async throws -> AuthSession { session! }
  func resetPasswordForEmail(email: String, redirectTo: URL) async throws {}
  func updatePassword(_ password: String) async throws {}
  func handleCallback(_ url: URL) async throws -> AuthSession { session! }
  func signOut() async throws {}
}

private actor GatedOnboardingProfileAPI: ProfileAPI {
  let profileID: String
  private var started = false
  private var released = false
  private var startWaiter: CheckedContinuation<Void, Never>?

  init(profileID: String) { self.profileID = profileID }

  func fetchProfile(accessToken: String) async throws -> UserProfile {
    started = true
    startWaiter?.resume()
    startWaiter = nil
    while !released { await Task.yield() }
    return UserProfile(id: profileID, ageVerified: true)
  }

  func verifyAge(accessToken: String, birthDate: String) async throws {}
  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      startWaiter = continuation
    }
  }
  func release() { released = true }
}

private actor TokenMappedOnboardingProfileAPI: ProfileAPI {
  let profiles: [String: String]

  init(profiles: [String: String]) { self.profiles = profiles }

  func fetchProfile(accessToken: String) async throws -> UserProfile {
    UserProfile(id: profiles[accessToken], ageVerified: true)
  }

  func verifyAge(accessToken: String, birthDate: String) async throws {}
}

private actor CountingOnboardingProfileAPI: ProfileAPI {
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

private actor CapturingOnboardingTransport: APIHTTPTransport {
  private(set) var requests: [URLRequest] = []

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
    )!
    return (Data(#"{"data":null}"#.utf8), response)
  }

  func requestsSnapshot() -> [URLRequest] { requests }
}
