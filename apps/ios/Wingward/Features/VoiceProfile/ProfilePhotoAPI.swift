import Foundation

/// The server receives only the on-device watercolor PNG.  The original photo
/// is never part of this API and is not retained by the client store.
protocol ProfilePhotoAPI: Sendable {
  func fetchSavedAvatarURL() async throws -> URL?
  func saveWatercolorProfilePhoto(_ pngData: Data) async throws -> ProfilePhotoSaveResult
}

struct ProfilePhotoReadResult: Decodable, Sendable, APIValidatable {
  let id: UUID
  let avatarURL: URL?

  private enum CodingKeys: String, CodingKey {
    case id
    case avatarURL = "avatar_url"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    guard container.contains(.avatarURL) else { throw APIClientError.invalidResponse }
    if try container.decodeNil(forKey: .avatarURL) {
      avatarURL = nil
    } else {
      let rawURL = try container.decode(String.self, forKey: .avatarURL)
      avatarURL = try APIDTOValidation.requireHTTPSURL(rawURL)
    }
    try Self.validate(self)
  }

  static func validate(_ value: ProfilePhotoReadResult) throws {
    if let avatarURL = value.avatarURL, avatarURL.absoluteString.count > 4_096 {
      throw APIDTOValidationError.invalidURL
    }
  }
}

struct ProfilePhotoSaveResult: Decodable, Equatable, Sendable, APIValidatable {
  let avatarURL: URL

  private enum CodingKeys: String, CodingKey {
    case avatarURL = "avatar_url"
  }

  init(avatarURL: URL) {
    self.avatarURL = avatarURL
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawURL = try container.decode(String.self, forKey: .avatarURL)
    self.init(avatarURL: try APIDTOValidation.requireHTTPSURL(rawURL))
    try Self.validate(self)
  }

  static func validate(_ value: ProfilePhotoSaveResult) throws {
    guard value.avatarURL.absoluteString.count <= 4_096 else {
      throw APIDTOValidationError.invalidURL
    }
  }
}

struct UnavailableProfilePhotoAPI: ProfilePhotoAPI, Sendable {
  func fetchSavedAvatarURL() async throws -> URL? {
    throw APIClientError.temporarilyUnavailable
  }

  func saveWatercolorProfilePhoto(_: Data) async throws -> ProfilePhotoSaveResult {
    throw APIClientError.temporarilyUnavailable
  }
}

struct LiveProfilePhotoAPI: ProfilePhotoAPI, Sendable {
  static let photoPath = "/api/auth/me/photo"
  static let currentProfilePath = "/api/auth/me"
  static let maxPNGBytes = 5 * 1024 * 1024

  let client: any AuthenticatedAPIClientProtocol
  let expectedOwnerID: UUID

  init(client: any AuthenticatedAPIClientProtocol, expectedOwnerID: UUID) {
    self.client = client
    self.expectedOwnerID = expectedOwnerID
  }

  func fetchSavedAvatarURL() async throws -> URL? {
    let profile = try await client.get(Self.currentProfilePath, as: ProfilePhotoReadResult.self)
    guard profile.id == expectedOwnerID else { throw APIClientError.invalidResponse }
    return profile.avatarURL
  }

  func saveWatercolorProfilePhoto(_ pngData: Data) async throws -> ProfilePhotoSaveResult {
    guard !pngData.isEmpty, pngData.count <= Self.maxPNGBytes else {
      throw APIClientError.invalidRequest
    }

    let request = APIRequest(
      method: .post,
      path: Self.photoPath,
      body: pngData,
      contentType: "image/png"
    )
    return try await client.send(request, as: ProfilePhotoSaveResult.self)
  }
}

protocol ProfilePhotoAPIFactory: Sendable {
  func make(ownerID: String) -> (any ProfilePhotoAPI)?
}

struct LiveProfilePhotoAPIFactory: ProfilePhotoAPIFactory, Sendable {
  let baseURL: URL
  let authService: any AuthService
  let profileAPI: any ProfileAPI
  let transport: any APIHTTPTransport

  init(
    baseURL: URL,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    transport: any APIHTTPTransport = URLSession(configuration: .ephemeral)
  ) {
    self.baseURL = baseURL
    self.authService = authService
    self.profileAPI = profileAPI
    self.transport = transport
  }

  func make(ownerID: String) -> (any ProfilePhotoAPI)? {
    let normalizedOwnerID = ownerID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let expectedOwnerID = UUID(uuidString: normalizedOwnerID) else {
      return nil
    }
    do {
      let provider = OwnerBoundAuthSessionTokenProvider(
        expectedOwnerID: normalizedOwnerID,
        authService: authService,
        profileAPI: profileAPI
      )
      let client = try AuthenticatedAPIClient(
        baseURL: baseURL,
        tokenProvider: provider,
        transport: transport
      )
      return LiveProfilePhotoAPI(client: client, expectedOwnerID: expectedOwnerID)
    } catch {
      return nil
    }
  }
}
