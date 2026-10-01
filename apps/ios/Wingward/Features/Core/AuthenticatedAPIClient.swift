import Foundation

/// The only transport methods exposed to feature code.  Keeping this closed
/// prevents a feature from accidentally constructing an unauthenticated
/// request or inventing a second HTTP client.
enum APIHTTPMethod: String, Hashable, Sendable {
  case get = "GET"
  case post = "POST"
  case put = "PUT"
  case delete = "DELETE"
}

/// A relative API request.  Paths are checked again by
/// `AuthenticatedAPIClient` before they are combined with the configured
/// origin, so a path cannot replace the host or scheme.
struct APIRequest: Equatable, Sendable {
  let method: APIHTTPMethod
  let path: String
  let body: Data?
  let contentType: String?
  /// This narrowly scoped bearer value is accepted only by the two account
  /// deletion mutation paths, never copied into a URL or request body.
  let accountDeletionReceipt: String?

  init(
    method: APIHTTPMethod,
    path: String,
    body: Data? = nil,
    contentType: String? = nil,
    accountDeletionReceipt: String? = nil
  ) {
    self.method = method
    self.path = path
    self.body = body
    self.contentType = contentType
    self.accountDeletionReceipt = accountDeletionReceipt
  }

  static func json<Body: Encodable>(
    method: APIHTTPMethod,
    path: String,
    body: Body,
    encoder: JSONEncoder = JSONEncoder()
  ) throws -> APIRequest {
    APIRequest(
      method: method,
      path: path,
      body: try encoder.encode(body)
    )
  }
}

/// Stable, non-sensitive client errors.  No case carries a server message,
/// response body, URL, token, or database/vendor detail.
enum APIClientError: Error, Equatable, Sendable {
  case invalidURL
  case invalidRequest
  case invalidResponse
  case transportFailure
  case cancelled
  case unauthenticated
  case forbidden
  case ageVerificationRequired
  case notFound
  case invalidState
  case quotaExhausted(source: PaywallSource?)
  case rateLimited
  case temporarilyUnavailable
}

/// Feature DTOs must implement post-decode validation.  Keeping validation a
/// required protocol method prevents a new live DTO from silently opting out
/// of the fail-closed response boundary.
protocol APIValidatable: Decodable, Sendable {
  static func validate(_ value: Self) throws

  /// Validates fields that live alongside the standard `data` value in an API
  /// response envelope. Most endpoints do not have envelope metadata, so the
  /// default implementation keeps their existing closed DTO validation.
  static func validateEnvelope(
    _ value: Self,
    nextCursor: String?,
    hasMore: Bool?,
    includesNextCursor: Bool,
    includesHasMore: Bool
  ) throws
}

extension APIValidatable {
  static func validateEnvelope(
    _ value: Self,
    nextCursor: String?,
    hasMore: Bool?,
    includesNextCursor: Bool,
    includesHasMore: Bool
  ) throws {
    try validate(value)
  }
}

/// Validation failures do not preserve the invalid value.  This is useful for
/// both safe UI errors and tests that verify malformed server data fails closed.
enum APIDTOValidationError: Error, Equatable, Sendable {
  case invalidIdentifier
  case invalidURL
  case invalidTimestamp
  case emptyRequiredValue
}

enum APIDTOValidation {
  static func requireUUID(_ rawValue: String) throws -> UUID {
    // UUID(uuidString:) is permissive on some SDKs.  Keep API identifiers in
    // the canonical 36-character form before converting them to UUID values.
    let bytes = Array(rawValue.utf8)
    guard bytes.count == 36 else { throw APIDTOValidationError.invalidIdentifier }
    let hyphenPositions: Set<Int> = [8, 13, 18, 23]
    for (index, byte) in bytes.enumerated() {
      if hyphenPositions.contains(index) {
        guard byte == 45 else { throw APIDTOValidationError.invalidIdentifier }
      } else {
        let isHex = (byte >= 48 && byte <= 57)
          || (byte >= 65 && byte <= 70)
          || (byte >= 97 && byte <= 102)
        guard isHex else { throw APIDTOValidationError.invalidIdentifier }
      }
    }
    guard let uuid = UUID(uuidString: rawValue) else {
      throw APIDTOValidationError.invalidIdentifier
    }
    return uuid
  }

  static func requireHTTPSURL(_ rawValue: String) throws -> URL {
    guard
      let url = URL(string: rawValue),
      url.scheme?.lowercased() == "https",
      url.host != nil,
      url.user == nil,
      url.password == nil,
      url.fragment == nil
    else {
      throw APIDTOValidationError.invalidURL
    }
    return url
  }

  static func requireRFC3339(_ rawValue: String) throws -> Date {
    let isUTC = rawValue.hasSuffix("Z")
      || rawValue.hasSuffix("z")
      || rawValue.hasSuffix("+00:00")
      || rawValue.hasSuffix("-00:00")
    guard isUTC else { throw APIDTOValidationError.invalidTimestamp }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: rawValue) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: rawValue) else {
      throw APIDTOValidationError.invalidTimestamp
    }
    return date
  }

  static func requireNonEmpty(_ rawValue: String) throws {
    guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw APIDTOValidationError.emptyRequiredValue
    }
  }
}

struct AuthenticatedAPIResponseEnvelope<Value: Decodable>: Decodable {
  let data: Value
  let nextCursor: String?
  let hasMore: Bool?
  let includesNextCursor: Bool
  let includesHasMore: Bool

  private enum CodingKeys: String, CodingKey {
    case data
    case nextCursor = "next_cursor"
    case hasMore = "has_more"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    data = try container.decode(Value.self, forKey: .data)
    includesNextCursor = container.contains(.nextCursor)
    includesHasMore = container.contains(.hasMore)
    nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
  }
}

private struct EncodableAPIEnvelope<Value: Encodable>: Encodable {
  let data: Value
}

private struct APIErrorEnvelope: Decodable {
  let error: APIErrorPayload
}

private struct APIErrorPayload: Decodable {
  let code: String?
  let source: String?
}

enum APIResponseDecoder {
  static func decode<Value: APIValidatable>(
    _ data: Data,
    as type: Value.Type,
    decoder: JSONDecoder = JSONDecoder()
  ) throws -> Value {
    do {
      let envelope = try decoder.decode(AuthenticatedAPIResponseEnvelope<Value>.self, from: data)
      try Value.validateEnvelope(
        envelope.data,
        nextCursor: envelope.nextCursor,
        hasMore: envelope.hasMore,
        includesNextCursor: envelope.includesNextCursor,
        includesHasMore: envelope.includesHasMore
      )
      return envelope.data
    } catch {
      throw APIClientError.invalidResponse
    }
  }
}

/// The auth service is backed by Keychain storage.  The adapter keeps feature
/// clients independent from Supabase while ensuring the client asks the
/// auth/session boundary for a token on every request.
protocol APIAccessTokenProvider: Sendable {
  func accessToken() async throws -> String?
}

struct AuthSessionTokenProvider: APIAccessTokenProvider, Sendable {
  let authService: any AuthService

  init(authService: any AuthService) {
    self.authService = authService
  }

  func accessToken() async throws -> String? {
    try await authService.currentSession()?.accessToken
  }
}

protocol APIHTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: APIHTTPTransport {}

protocol AuthenticatedAPIClientProtocol: Sendable {
  func send<Value: APIValidatable>(
    _ request: APIRequest,
    as type: Value.Type
  ) async throws -> Value
}

extension AuthenticatedAPIClientProtocol {
  func get<Value: APIValidatable>(
    _ path: String,
    as type: Value.Type
  ) async throws -> Value {
    try await send(APIRequest(method: .get, path: path), as: type)
  }

  func post<Value: APIValidatable>(
    _ path: String,
    body: Data? = nil,
    accountDeletionReceipt: String? = nil,
    as type: Value.Type
  ) async throws -> Value {
    try await send(
      APIRequest(method: .post, path: path, body: body, accountDeletionReceipt: accountDeletionReceipt),
      as: type
    )
  }

  func put<Value: APIValidatable>(
    _ path: String,
    body: Data? = nil,
    as type: Value.Type
  ) async throws -> Value {
    try await send(APIRequest(method: .put, path: path, body: body), as: type)
  }

  func delete<Value: APIValidatable>(
    _ path: String,
    body: Data? = nil,
    accountDeletionReceipt: String? = nil,
    as type: Value.Type
  ) async throws -> Value {
    try await send(
      APIRequest(method: .delete, path: path, body: body, accountDeletionReceipt: accountDeletionReceipt),
      as: type
    )
  }
}

/// One actor owns the URLSession boundary, auth header, response decoding, and
/// status mapping.  Feature stores should depend only on
/// `AuthenticatedAPIClientProtocol`.
actor AuthenticatedAPIClient: AuthenticatedAPIClientProtocol {
  private let baseURL: URL
  private let tokenProvider: any APIAccessTokenProvider
  private let transport: any APIHTTPTransport
  private let decoder: JSONDecoder

  private static let maxErrorBodyBytes = 16_384

  init(
    baseURL: URL,
    tokenProvider: any APIAccessTokenProvider,
    transport: any APIHTTPTransport = URLSession(configuration: .ephemeral)
  ) throws {
    guard Self.isValidBaseURL(baseURL) else {
      throw APIClientError.invalidURL
    }
    self.baseURL = baseURL
    self.tokenProvider = tokenProvider
    self.transport = transport
    self.decoder = JSONDecoder()
  }

  func send<Value: APIValidatable>(
    _ request: APIRequest,
    as type: Value.Type
  ) async throws -> Value {
    let token: String?
    do {
      token = try await tokenProvider.accessToken()
    } catch let error as APIClientError {
      throw error
    } catch {
      if Self.isCancellation(error) {
        throw APIClientError.cancelled
      }
      throw APIClientError.temporarilyUnavailable
    }
    guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      // In particular, do not create a URLRequest or touch the transport when
      // the auth session has no token.
      throw APIClientError.unauthenticated
    }

    let url = try endpointURL(for: request.path)
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method.rawValue
    // These endpoints perform multiple sequential AI calls before responding.
    // Keep a finite wait and leave every other request's default unchanged.
    if request.method == .post && ["/api/profiles/generate", "/api/personas/wingfox/generate"].contains(request.path) {
      urlRequest.timeoutInterval = 180
    }
    urlRequest.httpBody = request.body
    urlRequest.httpShouldHandleCookies = false
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    if request.body != nil {
      urlRequest.setValue(
        request.contentType ?? "application/json",
        forHTTPHeaderField: "Content-Type"
      )
    }
    urlRequest.setValue(
      "Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))",
      forHTTPHeaderField: "Authorization"
    )
    if let receipt = request.accountDeletionReceipt {
      guard
        ["/api/auth/me/deletion-intent", "/api/auth/me", "/api/auth/account"].contains(request.path),
        AccountDeletionReceipt.isValid(receipt)
      else {
        throw APIClientError.invalidRequest
      }
      urlRequest.setValue(receipt, forHTTPHeaderField: "X-Account-Deletion-Receipt")
    }

    let responseData: Data
    let response: URLResponse
    do {
      (responseData, response) = try await transport.data(for: urlRequest)
    } catch {
      if Self.isCancellation(error) {
        throw APIClientError.cancelled
      }
      throw APIClientError.temporarilyUnavailable
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw APIClientError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw Self.map(statusCode: httpResponse.statusCode, body: responseData)
    }

    return try APIResponseDecoder.decode(responseData, as: type, decoder: decoder)
  }

  private func endpointURL(for path: String) throws -> URL {
    guard
      path.hasPrefix("/api/"),
      path.count > "/api/".count,
      !path.contains(".."),
      !path.contains("\\"),
      !path.contains("\n"),
      !path.contains("\r")
    else {
      throw APIClientError.invalidRequest
    }

    guard let relative = URLComponents(string: path) else {
      throw APIClientError.invalidRequest
    }
    guard
      relative.scheme == nil,
      relative.host == nil,
      relative.user == nil,
      relative.password == nil,
      relative.fragment == nil,
      relative.path.hasPrefix("/api/"),
      !relative.path.contains("//")
    else {
      throw APIClientError.invalidRequest
    }

    // Reject dot and separator characters at every percent-decoding layer.
    // Foundation exposes a decoded `path`, while URL construction can still
    // retain encoded bytes in `percentEncodedPath`; checking both prevents an
    // encoded traversal from being normalized into a different endpoint.
    guard !Self.hasUnsafePathEncoding(relative.percentEncodedPath) else {
      throw APIClientError.invalidRequest
    }

    guard var combined = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw APIClientError.invalidURL
    }
    let originPath = combined.path.hasSuffix("/") ? String(combined.path.dropLast()) : combined.path
    combined.path = originPath + relative.path
    combined.query = relative.query
    combined.fragment = nil
    guard let url = combined.url else { throw APIClientError.invalidURL }
    return url
  }

  private static func isValidBaseURL(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https"
      && url.host != nil
      && url.user == nil
      && url.password == nil
      && url.fragment == nil
  }

  private static func hasUnsafePathEncoding(_ encodedPath: String) -> Bool {
    var candidate = encodedPath

    while true {
      let normalized = candidate.lowercased()
      guard !normalized.contains("%2e"),
        !normalized.contains("%2f"),
        !normalized.contains("%5c")
      else {
        return true
      }

      // A malformed or incomplete percent escape is not a route we can
      // safely reason about.  Fail closed rather than letting URLComponents
      // or URLRequest interpret it differently later.
      guard candidate.contains("%") else { break }
      guard let decoded = candidate.removingPercentEncoding else { return true }
      guard decoded != candidate else { break }
      candidate = decoded
    }

    // Plain dot segments and literal traversal remain unsafe even when no
    // percent encoding is involved.  Keep the historical broad `..` check as
    // well, so a route cannot rely on platform-specific path normalization.
    if candidate.contains("..") || candidate.split(separator: "/").contains(".") {
      return true
    }
    return false
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
      return true
    }
    if let urlError = error as? URLError, urlError.code == .cancelled {
      return true
    }
    return false
  }

  private static func map(statusCode: Int, body: Data) -> APIClientError {
    switch statusCode {
    case 400: return .invalidRequest
    case 401: return .unauthenticated
    case 403:
      return Self.isAgeVerificationRequired(from: body)
        ? .ageVerificationRequired
        : .forbidden
    case 404: return .notFound
    case 409: return .invalidState
    case 402: return .quotaExhausted(source: paywallSource(from: body))
    case 429: return .rateLimited
    case 500...599: return .temporarilyUnavailable
    default: return .invalidResponse
    }
  }

  private static func paywallSource(from body: Data) -> PaywallSource? {
    // A malformed or oversized error body is simply an unqualified paywall;
    // no server message is surfaced to feature code or logs.
    guard body.count <= Self.maxErrorBodyBytes else { return nil }
    guard let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: body) else {
      return nil
    }
    let normalizedCode = envelope.error.code?.lowercased()
    guard normalizedCode == "quota_exhausted" || normalizedCode == "payment_required" else {
      return nil
    }
    guard let rawSource = envelope.error.source else { return nil }
    return PaywallSource(rawValue: rawSource)
  }

  private static func isAgeVerificationRequired(from body: Data) -> Bool {
    guard body.count <= Self.maxErrorBodyBytes,
      let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: body)
    else {
      return false
    }
    // The code is an exact, case-sensitive machine-code contract.  In
    // particular, do not infer an age gate from a status alone or from the
    // server's human-readable message.
    return envelope.error.code == "AGE_VERIFICATION_REQUIRED"
  }
}

/// A deterministic actor fake for feature stores.  It still decodes the same
/// `{ "data": ... }` envelope and runs DTO validation, so a fake cannot hide a
/// malformed fixture that the live client would reject.
actor FakeAuthenticatedAPIClient: AuthenticatedAPIClientProtocol {
  private var responses: [String: Result<Data, APIClientError>]
  private var requests: [APIRequest] = []

  init(responses: [String: Result<Data, APIClientError>] = [:]) {
    self.responses = responses
  }

  func send<Value: APIValidatable>(
    _ request: APIRequest,
    as type: Value.Type
  ) async throws -> Value {
    requests.append(request)
    let key = Self.key(for: request)
    guard let result = responses[key] else {
      throw APIClientError.temporarilyUnavailable
    }
    switch result {
    case let .success(data):
      return try APIResponseDecoder.decode(data, as: type)
    case let .failure(error):
      throw error
    }
  }

  func setResponseData(_ data: Data, for request: APIRequest) {
    responses[Self.key(for: request)] = .success(data)
  }

  func setError(_ error: APIClientError, for request: APIRequest) {
    responses[Self.key(for: request)] = .failure(error)
  }

  func setResponse<Value: Encodable>(_ value: Value, for request: APIRequest) throws {
    let data = try JSONEncoder().encode(EncodableAPIEnvelope(data: value))
    setResponseData(data, for: request)
  }

  func recordedRequests() -> [APIRequest] {
    requests
  }

  private static func key(for request: APIRequest) -> String {
    "\(request.method.rawValue) \(request.path)"
  }
}

private struct FakeTransportError: Error {}

/// URLSession-level fake used to prove the no-token path performs no network
/// call and to exercise HTTP status mapping without real network access.
actor FakeAPIHTTPTransport: APIHTTPTransport {
  enum Outcome: Sendable {
    case response(data: Data, statusCode: Int, headers: [String: String])
    case failure
    case cancellation
    case urlCancellation
  }

  struct RecordedRequest: Equatable, Sendable {
    let url: URL
    let method: String?
    let headers: [String: String]
    let body: Data?
    let timeoutInterval: TimeInterval
  }

  private var outcome: Outcome
  private var recorded: [RecordedRequest] = []

  init(outcome: Outcome = .response(data: Data(), statusCode: 200, headers: [:])) {
    self.outcome = outcome
  }

  func setOutcome(_ outcome: Outcome) {
    self.outcome = outcome
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    recorded.append(
      RecordedRequest(
        url: request.url ?? URL(string: "https://invalid.example")!,
        method: request.httpMethod,
        headers: request.allHTTPHeaderFields ?? [:],
        body: request.httpBody,
        timeoutInterval: request.timeoutInterval
      )
    )
    switch outcome {
    case let .response(data, statusCode, headers):
      guard let url = request.url else { throw FakeTransportError() }
      guard let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/2",
        headerFields: headers
      ) else {
        throw FakeTransportError()
      }
      return (data, response)
    case .failure:
      throw FakeTransportError()
    case .cancellation:
      throw CancellationError()
    case .urlCancellation:
      throw URLError(.cancelled)
    }
  }

  func requests() -> [RecordedRequest] {
    recorded
  }
}
