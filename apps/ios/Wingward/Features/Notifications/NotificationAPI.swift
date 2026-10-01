import Foundation

/// The notification client is intentionally provider-neutral.  OneSignal (or
/// APNs) only delivers the push; event evidence always goes through Wingward's
/// authenticated API.
protocol WingwardNotificationEventsAPI: Sendable {
  func record(_ event: WingwardNotificationEvent) async throws
}

/// Marks the authenticated owner's server notification clock. This is the
/// existing `/api/auth/me/notification-seen` contract; it is separate from
/// per-notification analytics events and carries no notification content.
protocol WingwardNotificationSeenAPI: Sendable {
  func markSeen() async throws -> Date
}

struct LiveWingwardNotificationEventsAPI: WingwardNotificationEventsAPI, Sendable {
  static let eventsPath = "/api/notification-events"

  let client: any AuthenticatedAPIClientProtocol
  let expectedOwnerID: String

  init(client: any AuthenticatedAPIClientProtocol, expectedOwnerID: String? = nil) {
    self.client = client
    self.expectedOwnerID = expectedOwnerID ?? ""
  }

  init(
    baseURL: URL,
    ownerID: String,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    transport: any APIHTTPTransport = URLSession(configuration: .ephemeral)
  ) throws {
    guard !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      (try? APIDTOValidation.requireUUID(ownerID)) != nil
    else {
      throw APIClientError.unauthenticated
    }

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
    self.init(client: client, expectedOwnerID: ownerID)
  }

  func record(_ event: WingwardNotificationEvent) async throws {
    try event.validate()
    let request = try APIRequest.json(
      method: .post,
      path: Self.eventsPath,
      body: event
    )
    _ = try await client.send(request, as: WingwardNotificationEventAcknowledgement.self)
  }
}

struct LiveWingwardNotificationSeenAPI: WingwardNotificationSeenAPI, Sendable {
  static let seenPath = "/api/auth/me/notification-seen"

  let client: any AuthenticatedAPIClientProtocol
  let expectedOwnerID: UUID?

  init(client: any AuthenticatedAPIClientProtocol, expectedOwnerID: String? = nil) throws {
    if let expectedOwnerID {
      self.expectedOwnerID = try APIDTOValidation.requireUUID(expectedOwnerID)
    } else {
      self.expectedOwnerID = nil
    }
    self.client = client
  }

  init(
    baseURL: URL,
    ownerID: String,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    transport: any APIHTTPTransport = URLSession(configuration: .ephemeral)
  ) throws {
    let ownerUUID = try APIDTOValidation.requireUUID(ownerID)
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
    self.client = client
    self.expectedOwnerID = ownerUUID
  }

  func markSeen() async throws -> Date {
    let acknowledgement = try await client.send(
      APIRequest(method: .post, path: Self.seenPath),
      as: WingwardNotificationSeenAcknowledgement.self
    )
    if let expectedOwnerID, expectedOwnerID != acknowledgement.ownerID {
      throw APIClientError.unauthenticated
    }
    return acknowledgement.notificationSeenAt
  }
}

protocol WingwardNotificationSeenAPIFactory: Sendable {
  func make(ownerID: String) -> (any WingwardNotificationSeenAPI)?
}

struct LiveWingwardNotificationSeenAPIFactory: WingwardNotificationSeenAPIFactory, Sendable {
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

  func make(ownerID: String) -> (any WingwardNotificationSeenAPI)? {
    try? LiveWingwardNotificationSeenAPI(
      baseURL: baseURL,
      ownerID: ownerID,
      authService: authService,
      profileAPI: profileAPI,
      transport: transport
    )
  }
}

protocol WingwardNotificationEventsAPIFactory: Sendable {
  func make(ownerID: String) -> (any WingwardNotificationEventsAPI)?
}

struct LiveWingwardNotificationEventsAPIFactory: WingwardNotificationEventsAPIFactory, Sendable {
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

  func make(ownerID: String) -> (any WingwardNotificationEventsAPI)? {
    try? LiveWingwardNotificationEventsAPI(
      baseURL: baseURL,
      ownerID: ownerID,
      authService: authService,
      profileAPI: profileAPI,
      transport: transport
    )
  }
}
