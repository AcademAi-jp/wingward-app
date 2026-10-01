import Foundation

enum MeetupAPIError: Error, Equatable, Sendable {
  /// This is kept separate from a generic invalid state so an integration
  /// layer can present the provider-neutral gate without ever bypassing it.
  case identityVerificationRequired
}

protocol MeetupsAPI: Sendable {
  func createIntent(matchID: UUID) async throws -> MeetupIntentResponse
  func fetchMeetup(id: UUID) async throws -> MeetupDetail
  func fetchMeetup(matchID: UUID) async throws -> MeetupDetail
  func savePreferences(meetupID: UUID, preferences: MeetupPreferences) async throws -> MeetupPreferencesResponse
  func arrange(meetupID: UUID) async throws -> MeetupActionResponse
  func retry(meetupID: UUID) async throws -> MeetupActionResponse
  func respond(meetupID: UUID, proposalID: UUID, selectedCandidateIndex: Int) async throws -> MeetupActionResponse
}

struct MeetupIntentResponse: Decodable, Equatable, Sendable, APIValidatable {
  let accepted: Bool

  static func validate(_ value: MeetupIntentResponse) throws {
    guard value.accepted else { throw MeetupDTOValidationError.invalidValue }
  }
}

struct MeetupPreferencesResponse: Decodable, Equatable, Sendable, APIValidatable {
  let saved: Bool

  static func validate(_ value: MeetupPreferencesResponse) throws {
    guard value.saved else { throw MeetupDTOValidationError.invalidValue }
  }
}

struct MeetupActionResponse: Decodable, Equatable, Sendable, APIValidatable {
  let accepted: Bool
  let status: MeetupActionStatus

  enum MeetupActionStatus: String, Decodable, Equatable, Sendable {
    case arranging
    case proposed
    case confirmed
  }

  enum CodingKeys: String, CodingKey {
    case accepted
    case status
  }

  static func validate(_ value: MeetupActionResponse) throws {
    guard value.accepted else { throw MeetupDTOValidationError.invalidValue }
  }
}

struct LiveMeetupsAPI: MeetupsAPI, Sendable {
  static let intentsPath = "/api/meetups/intents"

  let client: any AuthenticatedAPIClientProtocol

  init(client: any AuthenticatedAPIClientProtocol) {
    self.client = client
  }

  init(
    baseURL: URL,
    ownerID: String,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    transport: any APIHTTPTransport = URLSession(configuration: .ephemeral)
  ) throws {
    guard !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw APIClientError.unauthenticated
    }
    // Keep the factory owner-bound to a canonical server identity. The token
    // provider repeats the server-side `/api/auth/me` binding for each call.
    _ = try APIDTOValidation.requireUUID(ownerID)
    let provider = OwnerBoundAuthSessionTokenProvider(
      expectedOwnerID: ownerID,
      authService: authService,
      profileAPI: profileAPI
    )
    let client = try AuthenticatedAPIClient(
      baseURL: baseURL,
      tokenProvider: provider,
      transport: transport
    )
    self.init(client: client)
  }

  func createIntent(matchID: UUID) async throws -> MeetupIntentResponse {
    let request = try APIRequest.json(
      method: .post,
      path: Self.intentsPath,
      body: IntentRequest(matchID: matchID.uuidString.lowercased())
    )
    return try await client.send(request, as: MeetupIntentResponse.self)
  }

  func fetchMeetup(id: UUID) async throws -> MeetupDetail {
    try await client.get(Self.meetupPath(for: id), as: MeetupDetail.self)
  }

  func fetchMeetup(matchID: UUID) async throws -> MeetupDetail {
    try await client.get(Self.meetupPath(forMatchID: matchID), as: MeetupDetail.self)
  }

  func savePreferences(meetupID: UUID, preferences: MeetupPreferences) async throws -> MeetupPreferencesResponse {
    do {
      try preferences.validate()
    } catch {
      throw APIClientError.invalidRequest
    }
    let request = try APIRequest.json(
      method: .put,
      path: Self.meetupPreferencesPath(for: meetupID),
      body: preferences
    )
    return try await client.send(request, as: MeetupPreferencesResponse.self)
  }

  func arrange(meetupID: UUID) async throws -> MeetupActionResponse {
    try await client.post(Self.arrangePath(for: meetupID), as: MeetupActionResponse.self)
  }

  func retry(meetupID: UUID) async throws -> MeetupActionResponse {
    try await client.post(Self.retryPath(for: meetupID), as: MeetupActionResponse.self)
  }

  func respond(
    meetupID: UUID,
    proposalID: UUID,
    selectedCandidateIndex: Int
  ) async throws -> MeetupActionResponse {
    guard (0...2).contains(selectedCandidateIndex) else {
      throw APIClientError.invalidRequest
    }
    let request = try APIRequest.json(
      method: .post,
      path: Self.responsePath(for: meetupID, proposalID: proposalID),
      body: ProposalResponseRequest(selectedCandidateIndex: selectedCandidateIndex)
    )
    return try await client.send(request, as: MeetupActionResponse.self)
  }

  static func meetupPath(for id: UUID) -> String {
    "/api/meetups/\(id.uuidString.lowercased())"
  }

  static func meetupPath(forMatchID id: UUID) -> String {
    "/api/meetups/by-match/\(id.uuidString.lowercased())"
  }

  static func meetupPreferencesPath(for id: UUID) -> String {
    "\(meetupPath(for: id))/preferences"
  }

  static func arrangePath(for id: UUID) -> String {
    "\(meetupPath(for: id))/arrange"
  }

  static func retryPath(for id: UUID) -> String {
    "\(meetupPath(for: id))/retry"
  }

  static func responsePath(for meetupID: UUID, proposalID: UUID) -> String {
    "\(meetupPath(for: meetupID))/proposals/\(proposalID.uuidString.lowercased())/responses"
  }

  private struct IntentRequest: Encodable, Sendable {
    let matchID: String

    enum CodingKeys: String, CodingKey {
      case matchID = "match_id"
    }
  }

  private struct ProposalResponseRequest: Encodable, Sendable {
    let selectedCandidateIndex: Int

    enum CodingKeys: String, CodingKey {
      case selectedCandidateIndex = "selected_candidate_index"
    }
  }
}

protocol MeetupsAPIFactory: Sendable {
  func make(ownerID: String) -> (any MeetupsAPI)?
}

struct LiveMeetupsAPIFactory: MeetupsAPIFactory, Sendable {
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

  func make(ownerID: String) -> (any MeetupsAPI)? {
    try? LiveMeetupsAPI(
      baseURL: baseURL,
      ownerID: ownerID,
      authService: authService,
      profileAPI: profileAPI,
      transport: transport
    )
  }
}
