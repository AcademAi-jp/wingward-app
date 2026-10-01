import Foundation

struct LiveProfileAPI: ProfileAPI, Sendable {
  let baseURL: URL
  let urlSession: URLSession

  init(baseURL: URL, urlSession: URLSession? = nil) {
    self.baseURL = baseURL
    if let urlSession {
      self.urlSession = urlSession
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = nil
      configuration.httpCookieStorage = nil
      configuration.urlCredentialStorage = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      self.urlSession = URLSession(configuration: configuration)
    }
  }

  func fetchProfile(accessToken: String) async throws -> UserProfile {
    var request = URLRequest(url: endpoint("api/auth/me"))
    request.httpMethod = "GET"
    addCommonHeaders(to: &request, accessToken: accessToken)

    let (data, response) = try await urlSession.data(for: request)
    try validate(response)
    return try JSONDecoder().decode(APIEnvelope<UserProfile>.self, from: data).data
  }

  func verifyAge(accessToken: String, birthDate: String) async throws {
    var request = URLRequest(url: endpoint("api/auth/me/age-verification"))
    request.httpMethod = "PUT"
    addCommonHeaders(to: &request, accessToken: accessToken)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(AgeVerificationBody(birthDate: birthDate))

    let (_, response) = try await urlSession.data(for: request)
    try validate(response)
  }

  private func endpoint(_ path: String) -> URL {
    baseURL.appendingPathComponent(path)
  }

  private func addCommonHeaders(to request: inout URLRequest, accessToken: String) {
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
  }

  private func validate(_ response: URLResponse) throws {
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ProfileAPIError.requestFailed
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw ProfileAPIError.requestFailedWithStatus(httpResponse.statusCode)
    }
  }
}
enum ProfileAPIError: Error, Equatable {
  case requestFailed
  case requestFailedWithStatus(Int)
}

private struct APIEnvelope<Value: Decodable>: Decodable {
  let data: Value
}

private struct AgeVerificationBody: Encodable {
  let birthDate: String

  enum CodingKeys: String, CodingKey {
    case birthDate = "birth_date"
  }
}
