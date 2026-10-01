import Foundation
import XCTest
@testable import Wingward

private struct StaticTokenProvider: APIAccessTokenProvider {
  let value: String?
  let shouldFail: Bool

  init(value: String?, shouldFail: Bool = false) {
    self.value = value
    self.shouldFail = shouldFail
  }

  func accessToken() async throws -> String? {
    if shouldFail { throw TokenProviderFailure() }
    return value
  }
}

private struct TokenProviderFailure: Error {}

private struct CancellationTokenProvider: APIAccessTokenProvider {
  func accessToken() async throws -> String? {
    throw CancellationError()
  }
}

private struct URLCancellationTokenProvider: APIAccessTokenProvider {
  func accessToken() async throws -> String? {
    throw URLError(.cancelled)
  }
}

private struct FixtureDTO: APIValidatable, Codable, Equatable {
  let id: String
  let avatarURL: String

  enum CodingKeys: String, CodingKey {
    case id
    case avatarURL = "avatar_url"
  }

  static func validate(_ value: FixtureDTO) throws {
    _ = try APIDTOValidation.requireUUID(value.id)
    _ = try APIDTOValidation.requireHTTPSURL(value.avatarURL)
  }
}

private struct APIClientErrorThrowingDTO: APIValidatable, Codable, Sendable {
  static func validate(_ value: APIClientErrorThrowingDTO) throws {
    throw APIClientError.forbidden
  }
}

@MainActor
final class CoreFoundationTests: XCTestCase {
  private let baseURL = URL(string: "https://api.example.test")!
  private let id = "11111111-1111-4111-8111-111111111111"

  func testNoTokenFailsBeforeTransportIsTouched() async throws {
    let transport = FakeAPIHTTPTransport(
      outcome: .response(data: validFixtureData(), statusCode: 200, headers: [:])
    )
    let client = try AuthenticatedAPIClient(
      baseURL: baseURL,
      tokenProvider: StaticTokenProvider(value: nil),
      transport: transport
    )

    do {
      _ = try await client.get("/api/matches", as: FixtureDTO.self)
      XCTFail("A request without a session token must fail closed")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .unauthenticated)
    }
    let requests = await transport.requests()
    XCTAssertEqual(requests.count, 0)
  }

  func testTokenProviderFailureDoesNotTouchTransportOrExposeProviderError() async throws {
    let transport = FakeAPIHTTPTransport()
    let client = try AuthenticatedAPIClient(
      baseURL: baseURL,
      tokenProvider: StaticTokenProvider(value: nil, shouldFail: true),
      transport: transport
    )

    do {
      _ = try await client.get("/api/matches", as: FixtureDTO.self)
      XCTFail("A session-provider failure must fail closed")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .temporarilyUnavailable)
    }
    let requests = await transport.requests()
    XCTAssertEqual(requests.count, 0)
  }

  func testValidResponseIsDecodedAndAuthorizationIsOwnedByClient() async throws {
    let transport = FakeAPIHTTPTransport(
      outcome: .response(data: validFixtureData(), statusCode: 200, headers: [:])
    )
    let client = try AuthenticatedAPIClient(
      baseURL: baseURL,
      tokenProvider: StaticTokenProvider(value: "  session-token  "),
      transport: transport
    )
    let request = APIRequest(
      method: .get,
      path: "/api/matches?limit=1"
    )

    let result = try await client.send(request, as: FixtureDTO.self)
    XCTAssertEqual(result.id, id)
    let recordedRequests = await transport.requests()
    let recorded = try XCTUnwrap(recordedRequests.first)
    XCTAssertEqual(recorded.method, "GET")
    XCTAssertEqual(recorded.url.absoluteString, "https://api.example.test/api/matches?limit=1")
    XCTAssertEqual(recorded.headers["Authorization"], "Bearer session-token")
    XCTAssertEqual(recorded.headers["Accept"], "application/json")
    XCTAssertNil(recorded.headers["X-Test"])
    XCTAssertEqual(recorded.headers.count, 2)
  }

  func testOnlyExactGenerationPostsUseBoundedLongerTimeout() async throws {
    let transport = FakeAPIHTTPTransport(
      outcome: .response(data: validFixtureData(), statusCode: 200, headers: [:])
    )
    let client = try AuthenticatedAPIClient(
      baseURL: baseURL, tokenProvider: StaticTokenProvider(value: "synthetic-token"),
      transport: transport
    )
    let cases: [(APIHTTPMethod, String, TimeInterval)] = [
      (.post, "/api/profiles/generate", 180),
      (.post, "/api/personas/wingfox/generate", 180),
      (.get, "/api/profiles/generate", 60),
      (.put, "/api/personas/wingfox/generate", 60),
      (.post, "/api/profiles/generate-extra", 60),
      (.post, "/api/profiles/generate?retry=1", 60),
      (.post, "/api/speed-dating/personas", 60),
      (.post, "/api/profiles/me/confirm", 60)
    ]
    for (method, path, _) in cases {
      _ = try await client.send(APIRequest(method: method, path: path), as: FixtureDTO.self)
    }
    let requests = await transport.requests()
    XCTAssertEqual(requests.count, cases.count)
    for (request, expected) in zip(requests, cases) {
      XCTAssertEqual(request.timeoutInterval, expected.2, expected.1)
    }
  }

  func testMalformedDTOFailsClosedAfterSuccessfulHTTPStatus() async throws {
    let malformed = Data(#"{"data":{"id":"not-a-uuid","avatar_url":"https://cdn.example.test/a.png"}}"#.utf8)
    let transport = FakeAPIHTTPTransport(
      outcome: .response(data: malformed, statusCode: 200, headers: [:])
    )
    let client = try AuthenticatedAPIClient(
      baseURL: baseURL,
      tokenProvider: StaticTokenProvider(value: "token"),
      transport: transport
    )

    do {
      _ = try await client.get("/api/matches", as: FixtureDTO.self)
      XCTFail("Invalid identifiers must not become feature data")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidResponse)
    }
  }

  func testValidatorAPIClientErrorIsNormalizedToInvalidResponse() throws {
    let data = Data(#"{"data":{}}"#.utf8)

    XCTAssertThrowsError(
      try APIResponseDecoder.decode(data, as: APIClientErrorThrowingDTO.self)
    ) { error in
      XCTAssertEqual(error as? APIClientError, .invalidResponse)
    }
  }

  func testStatusCodesMapToStableTypedErrorsWithoutReadingServerBody() async throws {
    let expected: [(Int, APIClientError)] = [
      (400, .invalidRequest),
      (401, .unauthenticated),
      (404, .notFound),
      (409, .invalidState),
      (429, .rateLimited),
      (500, .temporarilyUnavailable),
      (503, .temporarilyUnavailable),
      (418, .invalidResponse),
    ]

    for (statusCode, expectedError) in expected {
      let transport = FakeAPIHTTPTransport(
        outcome: .response(
          data: Data(#"{"error":{"message":"private server detail"}}"#.utf8),
          statusCode: statusCode,
          headers: [:]
        )
      )
      let client = try AuthenticatedAPIClient(
        baseURL: baseURL,
        tokenProvider: StaticTokenProvider(value: "token"),
        transport: transport
      )

      do {
        _ = try await client.get("/api/matches", as: FixtureDTO.self)
        XCTFail("HTTP \(statusCode) should fail")
      } catch let error as APIClientError {
        XCTAssertEqual(error, expectedError, "HTTP \(statusCode)")
      }
    }
  }

  func testAgeGate403RequiresTheExactSafeErrorCode() async throws {
    let bodies: [(String, Data, APIClientError)] = [
      (
        "lowercase machine code",
        Data(#"{"error":{"code":"age_verification_required","message":"private server detail"}}"#.utf8),
        .forbidden
      ),
      (
        "exact uppercase machine code",
        Data(#"{"error":{"code":"AGE_VERIFICATION_REQUIRED","message":"private server detail"}}"#.utf8),
        .ageVerificationRequired
      ),
      (
        "machine code with trailing whitespace",
        Data(#"{"error":{"code":"AGE_VERIFICATION_REQUIRED ","message":"private server detail"}}"#.utf8),
        .forbidden
      ),
      (
        "uppercase forbidden code",
        Data(#"{"error":{"code":"FORBIDDEN","message":"Age verification required"}}"#.utf8),
        .forbidden
      ),
      (
        "lowercase forbidden code",
        Data(#"{"error":{"code":"forbidden","message":"age_verification_required"}}"#.utf8),
        .forbidden
      ),
      (
        "message-only inference",
        Data(#"{"error":{"message":"age_verification_required"}}"#.utf8),
        .forbidden
      ),
      ("invalid body", Data(#"not-json"#.utf8), .forbidden),
    ]

    for (label, body, expected) in bodies {
      let transport = FakeAPIHTTPTransport(
        outcome: .response(data: body, statusCode: 403, headers: [:])
      )
      let client = try AuthenticatedAPIClient(
        baseURL: baseURL,
        tokenProvider: StaticTokenProvider(value: "token"),
        transport: transport
      )

      do {
        _ = try await client.get("/api/matches", as: FixtureDTO.self)
        XCTFail("HTTP 403 should fail")
      } catch let error as APIClientError {
        XCTAssertEqual(error, expected, label)
        XCTAssertFalse(String(describing: error).contains("private server detail"))
      }
    }
  }

  func testQuotaExhaustionMapsOnlyAnAllowlistedPaywallSource() async throws {
    let qualifiedBody = Data(
      #"{"error":{"code":"quota_exhausted","message":"do not display","source":"meetup_arrange"}}"#.utf8
    )
    let qualifiedTransport = FakeAPIHTTPTransport(
      outcome: .response(data: qualifiedBody, statusCode: 402, headers: [:])
    )
    let qualifiedClient = try AuthenticatedAPIClient(
      baseURL: baseURL,
      tokenProvider: StaticTokenProvider(value: "token"),
      transport: qualifiedTransport
    )
    do {
      _ = try await qualifiedClient.get("/api/meetups/arrange", as: FixtureDTO.self)
      XCTFail("A quota response should not decode as feature data")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .quotaExhausted(source: .meetupArrange))
    }

    let untrustedBody = Data(
      #"{"error":{"code":"quota_exhausted","source":"meetup_intent"}}"#.utf8
    )
    let untrustedTransport = FakeAPIHTTPTransport(
      outcome: .response(data: untrustedBody, statusCode: 402, headers: [:])
    )
    let untrustedClient = try AuthenticatedAPIClient(
      baseURL: baseURL,
      tokenProvider: StaticTokenProvider(value: "token"),
      transport: untrustedTransport
    )
    do {
      _ = try await untrustedClient.get("/api/meetups/intents", as: FixtureDTO.self)
      XCTFail("An unknown paywall source must not become a route")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .quotaExhausted(source: nil))
    }
  }

  func testUnsafePathAndInsecureBaseAreRejectedBeforeTransport() async throws {
    XCTAssertThrowsError(
      try AuthenticatedAPIClient(
        baseURL: URL(string: "http://api.example.test")!,
        tokenProvider: StaticTokenProvider(value: "token"),
        transport: FakeAPIHTTPTransport()
      )
    ) { error in
      XCTAssertEqual(error as? APIClientError, .invalidURL)
    }

    let transport = FakeAPIHTTPTransport()
    let client = try AuthenticatedAPIClient(
      baseURL: baseURL,
      tokenProvider: StaticTokenProvider(value: "token"),
      transport: transport
    )
    for path in [
      "https://evil.example/api/matches",
      "/api/../private",
      "/api/%2e%2e/private",
      "/api/%2E./private",
      "/api/.%2e/private",
      "/api/%252e%252e/private",
      "/api/%2Fprivate",
      "/api/%5Cprivate",
      "/api/%252fprivate",
      "/api/%255cprivate",
      "/not-api/matches",
    ] {
      do {
        _ = try await client.get(path, as: FixtureDTO.self)
        XCTFail("Unsafe path should be rejected: \(path)")
      } catch let error as APIClientError {
        XCTAssertEqual(error, .invalidRequest, path)
      }
    }
    let requests = await transport.requests()
    XCTAssertEqual(requests.count, 0)
  }

  func testTokenCancellationIsPreservedWithoutTouchingTransport() async throws {
    for provider in [
      CancellationTokenProvider() as any APIAccessTokenProvider,
      URLCancellationTokenProvider() as any APIAccessTokenProvider,
    ] {
      let transport = FakeAPIHTTPTransport()
      let client = try AuthenticatedAPIClient(
        baseURL: baseURL,
        tokenProvider: provider,
        transport: transport
      )

      do {
        _ = try await client.get("/api/matches", as: FixtureDTO.self)
        XCTFail("Cancellation must fail with the typed cancellation state")
      } catch let error as APIClientError {
        XCTAssertEqual(error, .cancelled)
      }
      let requests = await transport.requests()
      XCTAssertEqual(requests.count, 0)
    }
  }

  func testTransportCancellationIsPreserved() async throws {
    for outcome in [FakeAPIHTTPTransport.Outcome.cancellation, .urlCancellation] {
      let transport = FakeAPIHTTPTransport(outcome: outcome)
      let client = try AuthenticatedAPIClient(
        baseURL: baseURL,
        tokenProvider: StaticTokenProvider(value: "token"),
        transport: transport
      )

      do {
        _ = try await client.get("/api/matches", as: FixtureDTO.self)
        XCTFail("Transport cancellation must fail with the typed cancellation state")
      } catch let error as APIClientError {
        XCTAssertEqual(error, .cancelled)
      }
    }
  }

  func testFakeClientUsesTheSameEnvelopeAndDTOValidationAsLiveClient() async throws {
    let fake = FakeAuthenticatedAPIClient()
    let request = APIRequest(method: .get, path: "/api/profile")
    try await fake.setResponse(FixtureDTO(id: id, avatarURL: "https://cdn.example.test/a.png"), for: request)

    let result = try await fake.send(request, as: FixtureDTO.self)
    XCTAssertEqual(result.id, id)
    let recordedRequests = await fake.recordedRequests()
    XCTAssertEqual(recordedRequests.count, 1)

    let invalidRequest = APIRequest(method: .get, path: "/api/invalid")
    await fake.setResponseData(
      Data(#"{"data":{"id":"broken","avatar_url":"https://cdn.example.test/a.png"}}"#.utf8),
      for: invalidRequest
    )
    do {
      _ = try await fake.send(invalidRequest, as: FixtureDTO.self)
      XCTFail("Fake fixtures must be validated")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidResponse)
    }
  }

  func testValidationHelpersRejectUnsafeValuesWithoutEchoingThem() {
    XCTAssertThrowsError(try APIDTOValidation.requireUUID("private-user-id")) { error in
      XCTAssertEqual(error as? APIDTOValidationError, .invalidIdentifier)
      XCTAssertFalse(String(describing: error).contains("private-user-id"))
    }
    XCTAssertThrowsError(try APIDTOValidation.requireHTTPSURL("http://evil.example/secret")) { error in
      XCTAssertEqual(error as? APIDTOValidationError, .invalidURL)
    }
    XCTAssertThrowsError(try APIDTOValidation.requireRFC3339("not-a-date")) { error in
      XCTAssertEqual(error as? APIDTOValidationError, .invalidTimestamp)
    }
    XCTAssertThrowsError(try APIDTOValidation.requireRFC3339("2026-08-24T12:00:00+09:00")) { error in
      XCTAssertEqual(error as? APIDTOValidationError, .invalidTimestamp)
    }
  }

  func testAllowlistedDeepLinksProduceOnlyClosedRoutes() throws {
    let uuid = try XCTUnwrap(UUID(uuidString: id))
    let links: [(String, AppRoute)] = [
      ("wingward://match/\(id)/fox-result", .foxConversationResult(uuid)),
      ("wingward://chat-requests/\(id)", .chatRequest(uuid)),
      ("wingward://meetup/\(id)", .meetup(uuid)),
      ("wingward://meetup/\(id)/verify", .meetupVerification(uuid)),
      ("wingward://meetup/\(id)/feedback", .meetupFeedback(uuid)),
      ("wingward://meetup/\(id)/result", .meetupResult(uuid)),
      ("wingward://match/\(id)/fox-learned", .foxLearned(uuid)),
      ("wingward://availability", .availability),
    ]

    for (rawValue, expectedRoute) in links {
      XCTAssertEqual(AppDeepLinkParser.parse(rawValue), expectedRoute, rawValue)
    }
  }

  func testUnknownOrTamperedDeepLinksAreIgnored() throws {
    let invalidID = "not-a-uuid"
    let urls = [
      "https://meetup/\(id)",
      "wingward://unknown/\(id)",
      "wingward://notification/\(id)",
      "wingward://match/\(id)",
      "wingward://meetup/\(invalidID)",
      "wingward://meetup/\(id)/unsupported",
      "wingward://meetup/\(id)?message=private",
      "wingward://meetup/\(id)#fragment",
      "wingward://meetup/\(id)/",
      "wingward://meetup/\(id)%2Fverify",
      "wingward://match/\(id)/fox-result?redirect=https://evil.example",
      "wingward://match/\(id)/fox-result#fragment",
      "wingward://match/\(id)/fox-result/../private",
      "wingward://match/%2e%2e/fox-result",
      "wingward://login-callback/?code=auth-code",
    ]

    for rawValue in urls {
      XCTAssertNil(AppDeepLinkParser.parse(rawValue), rawValue)
    }
  }

  func testGatePrecedenceIsConfigurationStorageAuthAgeOnboardingEntitlementThenRoute() throws {
    let route = AppRoute.matches
    let base = AppGateContext(
      configurationHealthy: false,
      storageHealthy: false,
      isAuthenticated: false,
      ageVerified: false,
      onboardingCompleted: false,
      entitlement: .inactive,
      requestedRoute: route,
      premiumSource: .foxConversation
    )
    XCTAssertEqual(AppGateResolver.resolve(base), .configurationError)
    XCTAssertEqual(AppGateResolver.resolve(replacing(base, configurationHealthy: true)), .storageError)
    XCTAssertEqual(
      AppGateResolver.resolve(replacing(base, configurationHealthy: true, storageHealthy: true)),
      .authenticationRequired
    )
    XCTAssertEqual(
      AppGateResolver.resolve(replacing(base, configurationHealthy: true, storageHealthy: true, isAuthenticated: true)),
      .ageVerificationRequired
    )
    XCTAssertEqual(
      AppGateResolver.resolve(replacing(base, configurationHealthy: true, storageHealthy: true, isAuthenticated: true, ageVerified: true)),
      .onboardingRequired
    )
    XCTAssertEqual(
      AppGateResolver.resolve(
        replacing(
          base,
          configurationHealthy: true,
          storageHealthy: true,
          isAuthenticated: true,
          ageVerified: true,
          onboardingCompleted: true
        )
      ),
      .entitlementRequired(.foxConversation)
    )
    XCTAssertEqual(
      AppGateResolver.resolve(
        replacing(
          base,
          configurationHealthy: true,
          storageHealthy: true,
          isAuthenticated: true,
          ageVerified: true,
          onboardingCompleted: true,
          entitlement: .active,
          premiumSource: .foxConversation
        )
      ),
      .route(route)
    )
  }

  func testPaywallRouteDoesNotContainMeetIntentAndIsNotCreatedForIntent() {
    XCTAssertFalse(PaywallSource.allCases.map(\.rawValue).contains { $0.contains("intent") })
    let context = AppGateContext(
      isAuthenticated: true,
      ageVerified: true,
      onboardingCompleted: true,
      entitlement: .inactive,
      requestedRoute: .paywall(.meetupArrange),
      premiumSource: .meetupArrange
    )
    XCTAssertEqual(AppGateResolver.resolve(context), .route(.paywall(.meetupArrange)))
  }

  private func validFixtureData() -> Data {
    Data(#"{"data":{"id":"11111111-1111-4111-8111-111111111111","avatar_url":"https://cdn.example.test/a.png"}}"#.utf8)
  }

  private func replacing(
    _ context: AppGateContext,
    configurationHealthy: Bool? = nil,
    storageHealthy: Bool? = nil,
    isAuthenticated: Bool? = nil,
    ageVerified: Bool? = nil,
    onboardingCompleted: Bool? = nil,
    entitlement: ServerEntitlement? = nil,
    requestedRoute: AppRoute? = nil,
    premiumSource: PaywallSource? = nil
  ) -> AppGateContext {
    AppGateContext(
      configurationHealthy: configurationHealthy ?? context.configurationHealthy,
      storageHealthy: storageHealthy ?? context.storageHealthy,
      isAuthenticated: isAuthenticated ?? context.isAuthenticated,
      ageVerified: ageVerified ?? context.ageVerified,
      onboardingCompleted: onboardingCompleted ?? context.onboardingCompleted,
      entitlement: entitlement ?? context.entitlement,
      requestedRoute: requestedRoute ?? context.requestedRoute,
      premiumSource: premiumSource ?? context.premiumSource
    )
  }
}
