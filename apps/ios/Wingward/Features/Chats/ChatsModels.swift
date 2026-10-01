import Foundation

enum ChatsDTOValidationError: Error, Equatable, Sendable {
  case invalidIdentifier
  case invalidValue
  case invalidTimestamp
  case invalidStatus
}

struct DirectChatPartner: Decodable, Equatable, Sendable {
  let nickname: String?
  let avatarURL: URL?

  enum CodingKeys: String, CodingKey {
    case nickname
    case avatarURL = "avatar_url"
  }

  init(nickname: String?, avatarURL: URL? = nil) {
    self.nickname = nickname
    self.avatarURL = avatarURL
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
    if let rawURL = try container.decodeIfPresent(String.self, forKey: .avatarURL) {
      avatarURL = try APIDTOValidation.requireHTTPSURL(rawURL)
    } else {
      avatarURL = nil
    }
  }

  var displayName: String {
    let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "Wingward member" : trimmed
  }

  static func validate(_ value: DirectChatPartner) throws {
    if let nickname = value.nickname {
      guard nickname.count <= 120 else { throw ChatsDTOValidationError.invalidValue }
    }
  }
}

struct DirectChatLastMessage: Decodable, Equatable, Sendable {
  let content: String
  let createdAt: Date
  let isMine: Bool

  enum CodingKeys: String, CodingKey {
    case content
    case createdAt = "created_at"
    case isMine = "is_mine"
  }

  init(content: String, createdAt: Date, isMine: Bool) {
    self.content = content
    self.createdAt = createdAt
    self.isMine = isMine
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    content = try container.decode(String.self, forKey: .content)
    createdAt = try APIDTOValidation.requireRFC3339(
      try container.decode(String.self, forKey: .createdAt)
    )
    isMine = try container.decode(Bool.self, forKey: .isMine)
  }

  static func validate(_ value: DirectChatLastMessage) throws {
    guard !value.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.content.count <= 1_000
    else {
      throw ChatsDTOValidationError.invalidValue
    }
  }
}

/// Closed projection of `GET /api/direct-chats`. The API deliberately does
/// not return the partner's account ID in this list, so the client never
/// invents one from display data.
struct DirectChatSummary: Decodable, Equatable, Identifiable, Sendable, APIValidatable {
  let id: UUID
  let matchID: UUID
  let partner: DirectChatPartner?
  let lastMessage: DirectChatLastMessage?
  let unreadCount: Int
  let unreadCountAfterSeen: Int
  let status: String

  enum CodingKeys: String, CodingKey {
    case id
    case matchID = "match_id"
    case partner
    case lastMessage = "last_message"
    case unreadCount = "unread_count"
    case unreadCountAfterSeen = "unread_count_after_seen"
    case status
  }

  init(
    id: UUID,
    matchID: UUID,
    partner: DirectChatPartner?,
    lastMessage: DirectChatLastMessage?,
    unreadCount: Int,
    unreadCountAfterSeen: Int,
    status: String = "active"
  ) {
    self.id = id
    self.matchID = matchID
    self.partner = partner
    self.lastMessage = lastMessage
    self.unreadCount = unreadCount
    self.unreadCountAfterSeen = unreadCountAfterSeen
    self.status = status
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .id))
    matchID = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .matchID))
    partner = try container.decodeIfPresent(DirectChatPartner.self, forKey: .partner)
    lastMessage = try container.decodeIfPresent(DirectChatLastMessage.self, forKey: .lastMessage)
    unreadCount = try container.decode(Int.self, forKey: .unreadCount)
    unreadCountAfterSeen = try container.decode(Int.self, forKey: .unreadCountAfterSeen)
    status = try container.decode(String.self, forKey: .status)
  }

  static func validate(_ value: DirectChatSummary) throws {
    guard value.status == "active",
      value.unreadCount >= 0,
      value.unreadCountAfterSeen >= 0,
      value.unreadCountAfterSeen <= value.unreadCount,
      value.unreadCount <= 1_000_000
    else {
      throw ChatsDTOValidationError.invalidStatus
    }
    if let partner = value.partner { try DirectChatPartner.validate(partner) }
    if let lastMessage = value.lastMessage { try DirectChatLastMessage.validate(lastMessage) }
  }
}

struct DirectChatMessage: Decodable, Equatable, Identifiable, Sendable {
  let id: UUID
  let senderID: UUID
  let isMine: Bool
  let content: String
  let isRead: Bool
  let createdAt: Date

  enum CodingKeys: String, CodingKey {
    case id
    case senderID = "sender_id"
    case isMine = "is_mine"
    case content
    case isRead = "is_read"
    case createdAt = "created_at"
  }

  init(
    id: UUID,
    senderID: UUID,
    isMine: Bool,
    content: String,
    isRead: Bool,
    createdAt: Date
  ) {
    self.id = id
    self.senderID = senderID
    self.isMine = isMine
    self.content = content
    self.isRead = isRead
    self.createdAt = createdAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .id))
    senderID = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .senderID))
    isMine = try container.decode(Bool.self, forKey: .isMine)
    content = try container.decode(String.self, forKey: .content)
    isRead = try container.decode(Bool.self, forKey: .isRead)
    createdAt = try APIDTOValidation.requireRFC3339(
      try container.decode(String.self, forKey: .createdAt)
    )
  }

  static func validate(_ value: DirectChatMessage, ownerID: UUID? = nil) throws {
    guard !value.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.content.count <= 1_000,
      value.isMine == (ownerID.map { value.senderID == $0 } ?? value.isMine)
    else {
      throw ChatsDTOValidationError.invalidValue
    }
  }
}

/// Direct-chat history is cursor based. The route returns messages in
/// ascending order while `next_cursor` points at the first returned row.
struct DirectChatMessagesPayload: Decodable, Equatable, Sendable, APIValidatable {
  let messages: [DirectChatMessage]
  let nextCursor: String?
  let hasMore: Bool

  init(messages: [DirectChatMessage], nextCursor: String? = nil, hasMore: Bool = false) {
    self.messages = messages
    self.nextCursor = nextCursor
    self.hasMore = hasMore
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    messages = try container.decode([DirectChatMessage].self)
    nextCursor = nil
    hasMore = false
  }

  static func validate(_ value: DirectChatMessagesPayload) throws {
    try validate(value, ownerID: nil)
  }

  static func validate(_ value: DirectChatMessagesPayload, ownerID: UUID?) throws {
    guard value.messages.count <= 100,
      value.hasMore ? !(value.nextCursor?.isEmpty ?? true) : value.nextCursor == nil
    else {
      throw ChatsDTOValidationError.invalidValue
    }
    var ids = Set<UUID>()
    var previousDate: Date?
    for message in value.messages {
      guard ids.insert(message.id).inserted else {
        throw ChatsDTOValidationError.invalidValue
      }
      try DirectChatMessage.validate(message, ownerID: ownerID)
      if let previousDate, message.createdAt < previousDate {
        throw ChatsDTOValidationError.invalidValue
      }
      previousDate = message.createdAt
    }
  }

  static func validateEnvelope(
    _ value: DirectChatMessagesPayload,
    nextCursor: String?,
    hasMore: Bool?,
    includesNextCursor: Bool,
    includesHasMore: Bool
  ) throws {
    guard includesNextCursor, includesHasMore, hasMore != nil else {
      throw ChatsDTOValidationError.invalidValue
    }
    let merged = DirectChatMessagesPayload(
      messages: value.messages,
      nextCursor: nextCursor,
      hasMore: hasMore ?? false
    )
    try validate(merged)
  }
}

struct DirectChatSendResult: Decodable, Equatable, Sendable, APIValidatable {
  let id: UUID
  let content: String
  let createdAt: Date

  enum CodingKeys: String, CodingKey {
    case id
    case content
    case createdAt = "created_at"
  }

  init(id: UUID, content: String, createdAt: Date) {
    self.id = id
    self.content = content
    self.createdAt = createdAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .id))
    content = try container.decode(String.self, forKey: .content)
    createdAt = try APIDTOValidation.requireRFC3339(
      try container.decode(String.self, forKey: .createdAt)
    )
  }

  static func validate(_ value: DirectChatSendResult) throws {
    guard !value.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.content.count <= 1_000
    else {
      throw ChatsDTOValidationError.invalidValue
    }
  }
}

struct DirectChatSendRecoveryResult: Decodable, Equatable, Sendable, APIValidatable {
  enum Outcome: String, Decodable, Sendable {
    case found
    case notFound = "not_found"
    case conflict
    case missing
    case ineligible
    case invalidInput = "invalid_input"
  }

  let outcome: Outcome
  let message: DirectChatSendResult?

  enum CodingKeys: String, CodingKey {
    case outcome
    case message
  }

  init(outcome: Outcome, message: DirectChatSendResult?) {
    self.outcome = outcome
    self.message = message
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    outcome = try container.decode(Outcome.self, forKey: .outcome)
    message = try container.decodeIfPresent(DirectChatSendResult.self, forKey: .message)
  }

  static func validate(_ value: DirectChatSendRecoveryResult) throws {
    if value.outcome == .found {
      guard let message = value.message else { throw ChatsDTOValidationError.invalidValue }
      try DirectChatSendResult.validate(message)
      return
    }
    guard value.message == nil else { throw ChatsDTOValidationError.invalidValue }
  }
}

struct DirectChatReadResult: Decodable, Equatable, Sendable, APIValidatable {
  let readCount: Int

  enum CodingKeys: String, CodingKey {
    case readCount = "read_count"
  }

  init(readCount: Int) {
    self.readCount = readCount
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    readCount = try container.decode(Int.self, forKey: .readCount)
  }

  static func validate(_ value: DirectChatReadResult) throws {
    guard value.readCount >= 0 else { throw ChatsDTOValidationError.invalidValue }
  }
}

struct ChatRequestRequester: Decodable, Equatable, Sendable {
  let nickname: String?

  init(nickname: String?) { self.nickname = nickname }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
  }

  private enum CodingKeys: String, CodingKey { case nickname }

  var displayName: String {
    let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "Wingward member" : trimmed
  }
}

struct ChatRequestSummary: Decodable, Equatable, Identifiable, Sendable, APIValidatable {
  let id: UUID
  let matchID: UUID
  let requesterID: UUID
  let status: String
  let expiresAt: Date
  let createdAt: Date
  let requester: ChatRequestRequester
  let finalScore: Double?

  enum CodingKeys: String, CodingKey {
    case id
    case matchID = "match_id"
    case requesterID = "requester_id"
    case status
    case expiresAt = "expires_at"
    case createdAt = "created_at"
    case requester
    case finalScore = "final_score"
  }

  init(
    id: UUID,
    matchID: UUID,
    requesterID: UUID,
    status: String,
    expiresAt: Date,
    createdAt: Date,
    requester: ChatRequestRequester,
    finalScore: Double? = nil
  ) {
    self.id = id
    self.matchID = matchID
    self.requesterID = requesterID
    self.status = status
    self.expiresAt = expiresAt
    self.createdAt = createdAt
    self.requester = requester
    self.finalScore = finalScore
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .id))
    matchID = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .matchID))
    requesterID = try APIDTOValidation.requireUUID(
      try container.decode(String.self, forKey: .requesterID)
    )
    status = try container.decode(String.self, forKey: .status)
    expiresAt = try APIDTOValidation.requireRFC3339(
      try container.decode(String.self, forKey: .expiresAt)
    )
    createdAt = try APIDTOValidation.requireRFC3339(
      try container.decode(String.self, forKey: .createdAt)
    )
    requester = try container.decode(ChatRequestRequester.self, forKey: .requester)
    finalScore = try container.decodeIfPresent(Double.self, forKey: .finalScore)
  }

  static func validate(_ value: ChatRequestSummary) throws {
    guard value.status == "pending",
      value.expiresAt >= value.createdAt
    else {
      throw ChatsDTOValidationError.invalidStatus
    }
    if let score = value.finalScore {
      guard score.isFinite, (0...100).contains(score) else {
        throw ChatsDTOValidationError.invalidValue
      }
    }
    if let nickname = value.requester.nickname {
      guard nickname.count <= 120 else { throw ChatsDTOValidationError.invalidValue }
    }
  }
}

enum ChatRequestMatchStatus: String, Decodable, Equatable, Sendable {
  case pending
  case accepted
  case declined
  case expired
}

/// A match-scoped request state for either participant. Unlike
/// `ChatRequestSummary`, this intentionally omits requester profile data and
/// is also returned to the requester so the UI can recover after an uncertain
/// POST result.
struct ChatRequestMatchState: Decodable, Equatable, Identifiable, Sendable, APIValidatable {
  let simulatedCounterpart: Bool
  let id: UUID
  let matchID: UUID
  let requesterID: UUID
  let responderID: UUID
  let status: ChatRequestMatchStatus
  let expiresAt: Date

  enum CodingKeys: String, CodingKey {
    case simulatedCounterpart = "simulated_counterpart"
    case id
    case matchID = "match_id"
    case requesterID = "requester_id"
    case responderID = "responder_id"
    case status
    case expiresAt = "expires_at"
  }

  init(
    id: UUID,
    matchID: UUID,
    requesterID: UUID,
    responderID: UUID,
    status: ChatRequestMatchStatus,
    expiresAt: Date,
    simulatedCounterpart: Bool = false
  ) {
    self.simulatedCounterpart = simulatedCounterpart
    self.id = id
    self.matchID = matchID
    self.requesterID = requesterID
    self.responderID = responderID
    self.status = status
    self.expiresAt = expiresAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    simulatedCounterpart = try container.decodeIfPresent(Bool.self, forKey: .simulatedCounterpart) ?? false
    id = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .id))
    matchID = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .matchID))
    requesterID = try APIDTOValidation.requireUUID(
      try container.decode(String.self, forKey: .requesterID)
    )
    responderID = try APIDTOValidation.requireUUID(
      try container.decode(String.self, forKey: .responderID)
    )
    status = try container.decode(ChatRequestMatchStatus.self, forKey: .status)
    expiresAt = try APIDTOValidation.requireRFC3339(
      try container.decode(String.self, forKey: .expiresAt)
    )
  }

  static func validate(_ value: ChatRequestMatchState) throws {
    guard value.requesterID != value.responderID else {
      throw ChatsDTOValidationError.invalidValue
    }
  }
}

struct ChatRequestCreateResult: Decodable, Equatable, Sendable, APIValidatable {
  let simulatedCounterpart: Bool
  let id: UUID
  let matchID: UUID
  let status: String
  let expiresAt: Date

  enum CodingKeys: String, CodingKey {
    case simulatedCounterpart = "simulated_counterpart"
    case id
    case matchID = "match_id"
    case status
    case expiresAt = "expires_at"
  }

  init(id: UUID, matchID: UUID, status: String, expiresAt: Date, simulatedCounterpart: Bool = false) {
    self.simulatedCounterpart = simulatedCounterpart
    self.id = id
    self.matchID = matchID
    self.status = status
    self.expiresAt = expiresAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    simulatedCounterpart = try container.decodeIfPresent(Bool.self, forKey: .simulatedCounterpart) ?? false
    id = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .id))
    matchID = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .matchID))
    status = try container.decode(String.self, forKey: .status)
    expiresAt = try APIDTOValidation.requireRFC3339(
      try container.decode(String.self, forKey: .expiresAt)
    )
  }

  static func validate(_ value: ChatRequestCreateResult) throws {
    guard value.status == "pending" else { throw ChatsDTOValidationError.invalidStatus }
  }
}

struct ChatRequestDecisionResult: Decodable, Equatable, Sendable, APIValidatable {
  let requestID: UUID
  let status: String
  let directChatRoomID: UUID?

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case status
    case directChatRoomID = "direct_chat_room_id"
  }

  init(requestID: UUID, status: String, directChatRoomID: UUID? = nil) {
    self.requestID = requestID
    self.status = status
    self.directChatRoomID = directChatRoomID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    requestID = try APIDTOValidation.requireUUID(
      try container.decode(String.self, forKey: .requestID)
    )
    status = try container.decode(String.self, forKey: .status)
    if let rawRoomID = try container.decodeIfPresent(String.self, forKey: .directChatRoomID) {
      directChatRoomID = try APIDTOValidation.requireUUID(rawRoomID)
    } else {
      directChatRoomID = nil
    }
  }

  static func validate(_ value: ChatRequestDecisionResult) throws {
    guard value.status == "accepted" || value.status == "declined" else {
      throw ChatsDTOValidationError.invalidStatus
    }
    if value.status == "accepted" {
      guard value.directChatRoomID != nil else { throw ChatsDTOValidationError.invalidValue }
    } else if value.directChatRoomID != nil {
      throw ChatsDTOValidationError.invalidValue
    }
  }
}

enum ChatMeetupStatus: String, Decodable, Equatable, Sendable {
  case idle
  case intentPending = "intent_pending"
  case awaitingAvailability = "awaiting_availability"
  case timeProposed = "time_proposed"
  case awaitingLocation = "awaiting_location"
  case cafeProposed = "cafe_proposed"
  case confirmed
  case completed
  case cancelled
  case expired
  case unavailable
}

enum ChatMeetupEventKind: String, Decodable, Equatable, Sendable {
  case system
  case human
  case ward
}

enum ChatMeetupIntentValue: String, Codable, Equatable, Sendable {
  case yes
  case withdraw
}

enum ChatMeetupUnavailableReason: String, Decodable, Equatable, Sendable {
  case calendarUnavailable = "calendar_unavailable"
  case noSharedTime = "no_shared_time"
  case cafeUnavailable = "cafe_unavailable"
  case noCafe = "no_cafe"
  case migrationUnavailable = "migration_unavailable"
  case providerUnavailable = "provider_unavailable"
}

enum ChatMeetupPermissionReason: String, Decodable, Equatable, Sendable {
  case featureDisabled = "feature_disabled"
  case providerUnavailable = "provider_unavailable"
  case identityVerificationRequired = "identity_verification_required"
  case eligibilityUnavailable = "eligibility_unavailable"
  case quotaExhausted = "quota_exhausted"
  case notParticipant = "not_participant"
  case terminalState = "terminal_state"
}

struct ChatMeetupEvent: Decodable, Equatable, Identifiable, Sendable {
  let id: UUID
  let revision: Int
  let kind: ChatMeetupEventKind
  let text: String
  let createdAt: Date

  private enum CodingKeys: String, CodingKey {
    case id, revision, kind, text
    case createdAt = "created_at"
  }

  init(id: UUID, revision: Int, kind: ChatMeetupEventKind, text: String, createdAt: Date) {
    self.id = id
    self.revision = revision
    self.kind = kind
    self.text = text
    self.createdAt = createdAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(container.decode(String.self, forKey: .id))
    revision = try container.decode(Int.self, forKey: .revision)
    kind = try container.decode(ChatMeetupEventKind.self, forKey: .kind)
    text = try container.decode(String.self, forKey: .text)
    createdAt = try APIDTOValidation.requireRFC3339(container.decode(String.self, forKey: .createdAt))
  }

  static func validate(_ value: ChatMeetupEvent) throws {
    guard value.revision >= 0,
      !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.text.count <= 1_200
    else {
      throw ChatsDTOValidationError.invalidValue
    }
  }
}

struct ChatMeetupTimeCandidate: Decodable, Equatable, Identifiable, Sendable {
  let id: UUID
  let startsAt: Date
  let endsAt: Date

  private enum CodingKeys: String, CodingKey {
    case id
    case startsAt = "starts_at"
    case endsAt = "ends_at"
  }

  init(id: UUID, startsAt: Date, endsAt: Date) {
    self.id = id
    self.startsAt = startsAt
    self.endsAt = endsAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(container.decode(String.self, forKey: .id))
    startsAt = try APIDTOValidation.requireRFC3339(container.decode(String.self, forKey: .startsAt))
    endsAt = try APIDTOValidation.requireRFC3339(container.decode(String.self, forKey: .endsAt))
  }

  static func validate(_ value: ChatMeetupTimeCandidate) throws {
    guard value.startsAt < value.endsAt else { throw ChatsDTOValidationError.invalidTimestamp }
  }
}

struct ChatMeetupCafeAttribution: Decodable, Equatable, Identifiable, Sendable {
  let provider: String
  let providerURI: String?

  var id: String { provider + "|" + (providerURI ?? "") }
  var safeProviderURL: URL? { ChatMeetupCafeLinks.httpsURL(from: providerURI) }

  private enum CodingKeys: String, CodingKey {
    case provider
    case providerURI = "provider_uri"
  }

  init(provider: String, providerURI: String? = nil) {
    self.provider = provider
    self.providerURI = providerURI
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(String.self, forKey: .provider)
    providerURI = try container.decodeIfPresent(String.self, forKey: .providerURI)
  }

  static func validate(_ value: ChatMeetupCafeAttribution) throws {
    guard !value.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.provider.count <= 160,
      value.provider.utf8.count <= 512,
      !value.provider.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      value.providerURI.map({ $0.utf8.count <= 2_048 }) ?? true
    else {
      throw ChatsDTOValidationError.invalidValue
    }
  }
}

enum ChatMeetupCafeLinks {
  static func googleMapsURL(from rawValue: String?) -> URL? {
    guard let components = validatedHTTPSComponents(from: rawValue),
      let host = components.host?.lowercased()
    else { return nil }

    let path = components.path.isEmpty ? "/" : components.path.lowercased()
    let mapsPath = path == "/maps" || path.hasPrefix("/maps/")
    let isGoogleMapsPath: Bool
    switch host {
    case "maps.google.com":
      isGoogleMapsPath = path == "/" || mapsPath
    case "google.com", "www.google.com":
      isGoogleMapsPath = mapsPath
    default:
      isGoogleMapsPath = false
    }
    return isGoogleMapsPath ? components.url : nil
  }

  static func httpsURL(from rawValue: String?) -> URL? {
    guard let components = validatedHTTPSComponents(from: rawValue),
      let host = components.host,
      isPublicDNSHost(host)
    else { return nil }
    return components.url
  }

  private static func isPublicDNSHost(_ rawHost: String) -> Bool {
    let host = rawHost.lowercased()
    guard host.utf8.count <= 253,
      !host.hasSuffix("."),
      !host.contains(":"),
      !host.hasPrefix("[")
    else { return false }

    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2,
      labels.allSatisfy({ label in
        guard (1...63).contains(label.utf8.count),
          label.first != "-",
          label.last != "-"
        else { return false }
        return label.unicodeScalars.allSatisfy { scalar in
          (scalar.value >= 97 && scalar.value <= 122)
            || (scalar.value >= 48 && scalar.value <= 57)
            || scalar.value == 45
        }
      }),
      let topLevelDomain = labels.last,
      topLevelDomain.utf8.count >= 2,
      topLevelDomain.unicodeScalars.allSatisfy({ scalar in
        scalar.value >= 97 && scalar.value <= 122
      })
    else { return false }

    // Reject special-use and private DNS suffixes. Requiring a DNS-shaped
    // alphabetic public suffix also rejects IPv4/IPv6 and numeric host forms.
    let privateSuffixes: Set<String> = [
      "localhost", "local", "localdomain", "internal", "test", "invalid",
      "example", "lan", "home", "corp", "intranet", "private", "onion", "arpa",
    ]
    return !privateSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
  }

  private static func validatedHTTPSComponents(from rawValue: String?) -> URLComponents? {
    guard let rawValue, (1...2_048).contains(rawValue.utf8.count),
      !rawValue.contains("\\")
    else { return nil }
    let disallowedCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    guard !rawValue.unicodeScalars.contains(where: { disallowedCharacters.contains($0) }),
      let components = URLComponents(string: rawValue),
      components.scheme?.lowercased() == "https",
      components.host != nil,
      components.user == nil,
      components.password == nil,
      components.port == nil,
      components.fragment == nil
    else { return nil }
    return components
  }
}

struct ChatMeetupCafeCandidate: Decodable, Equatable, Identifiable, Sendable {
  /// Cafe provider IDs are opaque. They are bounded and never shown in the UI.
  let id: String
  let name: String
  let address: String
  let startsAt: Date
  let endsAt: Date
  let travelMinutesFirst: Int?
  let travelMinutesSecond: Int?
  let source: String?
  let googleMapsURI: String?
  let attributions: [ChatMeetupCafeAttribution]?

  var googleMapsAttributionLabel: String? { source == "google" ? "Google Maps" : nil }
  var googleMapsURL: URL? {
    guard googleMapsAttributionLabel != nil else { return nil }
    return ChatMeetupCafeLinks.googleMapsURL(from: googleMapsURI)
  }

  func travelTimeSummary(ja: Bool) -> String? {
    guard let travelMinutesFirst, let travelMinutesSecond else { return nil }
    return ja
      ? "\(travelMinutesFirst)分 / \(travelMinutesSecond)分"
      : "\(travelMinutesFirst) / \(travelMinutesSecond) min"
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, address, source, attributions
    case startsAt = "starts_at"
    case endsAt = "ends_at"
    case travelMinutesFirst = "travel_minutes_first"
    case travelMinutesSecond = "travel_minutes_second"
    case googleMapsURI = "google_maps_uri"
  }

  init(
    id: String,
    name: String,
    address: String,
    startsAt: Date,
    endsAt: Date,
    travelMinutesFirst: Int?,
    travelMinutesSecond: Int?,
    source: String? = nil,
    googleMapsURI: String? = nil,
    attributions: [ChatMeetupCafeAttribution]? = nil
  ) {
    self.id = id
    self.name = name
    self.address = address
    self.startsAt = startsAt
    self.endsAt = endsAt
    self.travelMinutesFirst = travelMinutesFirst
    self.travelMinutesSecond = travelMinutesSecond
    self.source = source
    self.googleMapsURI = googleMapsURI
    self.attributions = attributions
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    address = try container.decode(String.self, forKey: .address)
    startsAt = try APIDTOValidation.requireRFC3339(container.decode(String.self, forKey: .startsAt))
    endsAt = try APIDTOValidation.requireRFC3339(container.decode(String.self, forKey: .endsAt))
    travelMinutesFirst = try container.decodeIfPresent(Int.self, forKey: .travelMinutesFirst)
    travelMinutesSecond = try container.decodeIfPresent(Int.self, forKey: .travelMinutesSecond)
    source = try container.decodeIfPresent(String.self, forKey: .source)
    googleMapsURI = try container.decodeIfPresent(String.self, forKey: .googleMapsURI)
    attributions = try container.decodeIfPresent([ChatMeetupCafeAttribution].self, forKey: .attributions)
  }

  static func validate(_ value: ChatMeetupCafeCandidate) throws {
    guard (1...256).contains(value.id.utf8.count),
      !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.name.count <= 160,
      !value.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.address.count <= 400,
      value.startsAt < value.endsAt,
      value.travelMinutesFirst.map({ (0...360).contains($0) }) ?? true,
      value.travelMinutesSecond.map({ (0...360).contains($0) }) ?? true,
      value.source == nil || value.source == "google",
      value.googleMapsURI.map({ $0.utf8.count <= 2_048 }) ?? true,
      (value.attributions?.count ?? 0) <= 16
    else {
      throw ChatsDTOValidationError.invalidValue
    }
    for attribution in value.attributions ?? [] {
      try ChatMeetupCafeAttribution.validate(attribution)
    }
  }
}

struct ChatMeetupConfirmedPlan: Decodable, Equatable, Sendable {
  let startsAt: Date
  let endsAt: Date
  let cafeCandidateID: String?

  private enum CodingKeys: String, CodingKey {
    case startsAt = "starts_at"
    case endsAt = "ends_at"
    case cafeCandidateID = "cafe_candidate_id"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    startsAt = try APIDTOValidation.requireRFC3339(container.decode(String.self, forKey: .startsAt))
    endsAt = try APIDTOValidation.requireRFC3339(container.decode(String.self, forKey: .endsAt))
    cafeCandidateID = try container.decodeIfPresent(String.self, forKey: .cafeCandidateID)
  }

  func timeSummary(ja: Bool) -> String {
    let start = startsAt.formatted(date: .abbreviated, time: .shortened)
    let end = endsAt.formatted(date: .omitted, time: .shortened)
    return ja ? "確定した時間: \(start) · \(end)" : "Confirmed time: \(start) · \(end)"
  }

  static func validate(_ value: ChatMeetupConfirmedPlan) throws {
    guard value.startsAt < value.endsAt,
      value.cafeCandidateID.map({ (1...256).contains($0.utf8.count) }) ?? true
    else {
      throw ChatsDTOValidationError.invalidValue
    }
  }
}


struct ChatMeetupOwnPermissions: Decodable, Equatable, Sendable {
  let canIntent: Bool
  let canSchedule: Bool
  let canReplan: Bool
  let canCancel: Bool
  let canComplete: Bool
  let calendarConnected: Bool
  let cafeConnected: Bool
  let reason: ChatMeetupPermissionReason?

  private enum CodingKeys: String, CodingKey {
    case canIntent = "can_intent"
    case canSchedule = "can_schedule"
    case canReplan = "can_replan"
    case canCancel = "can_cancel"
    case canComplete = "can_complete"
    case calendarConnected = "calendar_connected"
    case cafeConnected = "cafe_connected"
    case reason
  }

  init(
    canIntent: Bool,
    canSchedule: Bool,
    canReplan: Bool,
    canCancel: Bool,
    canComplete: Bool,
    calendarConnected: Bool,
    cafeConnected: Bool,
    reason: ChatMeetupPermissionReason? = nil
  ) {
    self.canIntent = canIntent
    self.canSchedule = canSchedule
    self.canReplan = canReplan
    self.canCancel = canCancel
    self.canComplete = canComplete
    self.calendarConnected = calendarConnected
    self.cafeConnected = cafeConnected
    self.reason = reason
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    canIntent = try container.decode(Bool.self, forKey: .canIntent)
    canSchedule = try container.decode(Bool.self, forKey: .canSchedule)
    canReplan = try container.decode(Bool.self, forKey: .canReplan)
    canCancel = try container.decode(Bool.self, forKey: .canCancel)
    canComplete = try container.decode(Bool.self, forKey: .canComplete)
    calendarConnected = try container.decode(Bool.self, forKey: .calendarConnected)
    cafeConnected = try container.decodeIfPresent(Bool.self, forKey: .cafeConnected) ?? false
    reason = try container.decodeIfPresent(ChatMeetupPermissionReason.self, forKey: .reason)
  }

  static func validate(_ value: ChatMeetupOwnPermissions) throws {
    _ = value
  }
}

struct ChatMeetupOwnDecisions: Decodable, Equatable, Sendable {
  let intentValue: ChatMeetupIntentValue?
  let timeCandidateID: UUID?
  let cafeCandidateID: String?
  let completed: Bool
  let privateRevision: Int

  private enum CodingKeys: String, CodingKey {
    case intentValue = "intent_value"
    case timeCandidateID = "time_candidate_id"
    case cafeCandidateID = "cafe_candidate_id"
    case completed
    case privateRevision = "private_revision"
  }

  init(
    intentValue: ChatMeetupIntentValue?,
    timeCandidateID: UUID?,
    cafeCandidateID: String?,
    completed: Bool,
    privateRevision: Int = 0
  ) {
    self.intentValue = intentValue
    self.timeCandidateID = timeCandidateID
    self.cafeCandidateID = cafeCandidateID
    self.completed = completed
    self.privateRevision = privateRevision
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let value = try container.decodeIfPresent(String.self, forKey: .intentValue) {
      intentValue = try ChatMeetupIntentValue.decode(value)
    } else {
      intentValue = nil
    }
    if let value = try container.decodeIfPresent(String.self, forKey: .timeCandidateID) {
      timeCandidateID = try APIDTOValidation.requireUUID(value)
    } else {
      timeCandidateID = nil
    }
    cafeCandidateID = try container.decodeIfPresent(String.self, forKey: .cafeCandidateID)
    completed = try container.decode(Bool.self, forKey: .completed)
    privateRevision = try container.decode(Int.self, forKey: .privateRevision)
  }

  static func validate(_ value: ChatMeetupOwnDecisions) throws {
    guard value.privateRevision >= 0 else { throw ChatsDTOValidationError.invalidValue }
    if let cafeCandidateID = value.cafeCandidateID,
      !(1...256).contains(cafeCandidateID.utf8.count) {
      throw ChatsDTOValidationError.invalidValue
    }
  }
}

private extension ChatMeetupIntentValue {
  static func decode(_ rawValue: String) throws -> ChatMeetupIntentValue {
    guard let value = ChatMeetupIntentValue(rawValue: rawValue) else {
      throw ChatsDTOValidationError.invalidValue
    }
    return value
  }
}

/// A display-only server disclosure. This never grants identity verification or permissions.
struct ChatMeetupSyntheticTestAdmission: Decodable, Equatable, Sendable {
  let kind: String
  let pair: String
  let identityVerified: Bool
  let expiresAt: Date

  private enum CodingKeys: String, CodingKey {
    case kind, pair
    case identityVerified = "identity_verified"
    case expiresAt = "expires_at"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(String.self, forKey: .kind)
    pair = try container.decode(String.self, forKey: .pair)
    identityVerified = try container.decode(Bool.self, forKey: .identityVerified)
    expiresAt = try APIDTOValidation.requireRFC3339(container.decode(String.self, forKey: .expiresAt))
    try Self.validate(self)
  }

  static func validate(_ value: ChatMeetupSyntheticTestAdmission) throws {
    guard value.kind == "fictional-demo", value.pair == "demo-maya-ren", !value.identityVerified else {
      throw ChatsDTOValidationError.invalidValue
    }
  }

  func disclosureText(japanese: Bool) -> String {
    japanese ? "架空ユーザーのデモ — 本人確認は行っていません" :
      "Fictional demo — identity verification not performed"
  }
}

struct ChatMeetupState: Decodable, Equatable, Identifiable, Sendable, APIValidatable {
  let simulatedCounterpart: Bool
  let judgeMatchID: UUID?
  let roomID: UUID
  let meetupID: UUID?
  let revision: Int
  let status: ChatMeetupStatus
  let events: [ChatMeetupEvent]
  let timeCandidates: [ChatMeetupTimeCandidate]
  let cafeCandidates: [ChatMeetupCafeCandidate]
  let confirmedPlan: ChatMeetupConfirmedPlan?
  let cafeDetailsUnavailable: Bool
  let ownPermissions: ChatMeetupOwnPermissions
  let ownDecisions: ChatMeetupOwnDecisions
  let needsLocation: Bool
  let expiresAt: Date?
  let unavailableReason: ChatMeetupUnavailableReason?
  let syntheticTestAdmission: ChatMeetupSyntheticTestAdmission?

  var id: UUID { roomID }

  private enum CodingKeys: String, CodingKey {
    case simulatedCounterpart = "simulated_counterpart"
    case judgeMatchID = "judge_match_id"
    case roomID = "room_id"
    case meetupID = "meetup_id"
    case revision, status, events
    case timeCandidates = "time_candidates"
    case cafeCandidates = "cafe_candidates"
    case confirmedPlan = "confirmed_plan"
    case cafeDetailsUnavailable = "cafe_details_unavailable"
    case ownPermissions = "own_permissions"
    case ownDecisions = "own_decisions"
    case needsLocation = "needs_location"
    case expiresAt = "expires_at"
    case unavailableReason = "unavailable_reason"
    case syntheticTestAdmission = "synthetic_test_admission"
  }

  init(
    roomID: UUID,
    meetupID: UUID?,
    revision: Int,
    status: ChatMeetupStatus,
    events: [ChatMeetupEvent],
    timeCandidates: [ChatMeetupTimeCandidate],
    cafeCandidates: [ChatMeetupCafeCandidate],
    ownPermissions: ChatMeetupOwnPermissions,
    ownDecisions: ChatMeetupOwnDecisions,
    needsLocation: Bool,
    expiresAt: Date? = nil,
    unavailableReason: ChatMeetupUnavailableReason? = nil,
    confirmedPlan: ChatMeetupConfirmedPlan? = nil,
    cafeDetailsUnavailable: Bool = false,
    syntheticTestAdmission: ChatMeetupSyntheticTestAdmission? = nil,
    simulatedCounterpart: Bool = false,
    judgeMatchID: UUID? = nil
  ) {
    self.simulatedCounterpart = simulatedCounterpart
    self.judgeMatchID = judgeMatchID
    self.roomID = roomID
    self.meetupID = meetupID
    self.revision = revision
    self.status = status
    self.events = events
    self.timeCandidates = timeCandidates
    self.cafeCandidates = cafeCandidates
    self.confirmedPlan = confirmedPlan
    self.cafeDetailsUnavailable = cafeDetailsUnavailable
    self.ownPermissions = ownPermissions
    self.ownDecisions = ownDecisions
    self.needsLocation = needsLocation
    self.expiresAt = expiresAt
    self.unavailableReason = unavailableReason
    self.syntheticTestAdmission = syntheticTestAdmission
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    simulatedCounterpart = try container.decodeIfPresent(Bool.self, forKey: .simulatedCounterpart) ?? false
    judgeMatchID = try container.decodeIfPresent(String.self, forKey: .judgeMatchID).map { try APIDTOValidation.requireUUID($0) }
    roomID = try APIDTOValidation.requireUUID(container.decode(String.self, forKey: .roomID))
    if let rawMeetupID = try container.decodeIfPresent(String.self, forKey: .meetupID) {
      meetupID = try APIDTOValidation.requireUUID(rawMeetupID)
    } else {
      meetupID = nil
    }
    revision = try container.decode(Int.self, forKey: .revision)
    status = try container.decode(ChatMeetupStatus.self, forKey: .status)
    events = try container.decode([ChatMeetupEvent].self, forKey: .events)
    timeCandidates = try container.decode([ChatMeetupTimeCandidate].self, forKey: .timeCandidates)
    cafeCandidates = try container.decodeIfPresent([ChatMeetupCafeCandidate].self, forKey: .cafeCandidates) ?? []
    confirmedPlan = try container.decodeIfPresent(ChatMeetupConfirmedPlan.self, forKey: .confirmedPlan)
    cafeDetailsUnavailable = try container.decodeIfPresent(Bool.self, forKey: .cafeDetailsUnavailable) ?? false
    ownPermissions = try container.decode(ChatMeetupOwnPermissions.self, forKey: .ownPermissions)
    ownDecisions = try container.decode(ChatMeetupOwnDecisions.self, forKey: .ownDecisions)
    needsLocation = try container.decodeIfPresent(Bool.self, forKey: .needsLocation) ?? false
    if let rawExpiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt) {
      expiresAt = try APIDTOValidation.requireRFC3339(rawExpiresAt)
    } else {
      expiresAt = nil
    }
    unavailableReason = try container.decodeIfPresent(ChatMeetupUnavailableReason.self, forKey: .unavailableReason)
    syntheticTestAdmission = try container.decodeIfPresent(ChatMeetupSyntheticTestAdmission.self, forKey: .syntheticTestAdmission)
  }

  static func validate(_ value: ChatMeetupState) throws {
    guard value.simulatedCounterpart == (value.judgeMatchID != nil),
      value.revision >= 0,
      value.events.count <= 200,
      value.timeCandidates.count <= 20,
      value.cafeCandidates.count <= 20
    else {
      throw ChatsDTOValidationError.invalidValue
    }
    try ChatMeetupOwnPermissions.validate(value.ownPermissions)
    try ChatMeetupOwnDecisions.validate(value.ownDecisions)
    if let admission = value.syntheticTestAdmission { try ChatMeetupSyntheticTestAdmission.validate(admission) }
    if let confirmedPlan = value.confirmedPlan { try ChatMeetupConfirmedPlan.validate(confirmedPlan) }
    guard !value.cafeDetailsUnavailable || value.cafeCandidates.isEmpty else {
      throw ChatsDTOValidationError.invalidValue
    }

    var eventIDs = Set<UUID>()
    for event in value.events {
      try ChatMeetupEvent.validate(event)
      guard eventIDs.insert(event.id).inserted else { throw ChatsDTOValidationError.invalidValue }
    }
    var timeIDs = Set<UUID>()
    for candidate in value.timeCandidates {
      try ChatMeetupTimeCandidate.validate(candidate)
      guard timeIDs.insert(candidate.id).inserted else { throw ChatsDTOValidationError.invalidValue }
    }
    var cafeIDs = Set<String>()
    for candidate in value.cafeCandidates {
      try ChatMeetupCafeCandidate.validate(candidate)
      guard cafeIDs.insert(candidate.id).inserted else { throw ChatsDTOValidationError.invalidValue }
    }
    if value.status == .timeProposed && value.timeCandidates.isEmpty {
      throw ChatsDTOValidationError.invalidValue
    }
    if value.status == .cafeProposed && value.cafeCandidates.isEmpty {
      throw ChatsDTOValidationError.invalidValue
    }
    if let candidateID = value.ownDecisions.timeCandidateID,
      !timeIDs.contains(candidateID) && value.status == .timeProposed {
      throw ChatsDTOValidationError.invalidValue
    }
    if let candidateID = value.ownDecisions.cafeCandidateID,
      !cafeIDs.contains(candidateID) && value.status == .cafeProposed {
      throw ChatsDTOValidationError.invalidValue
    }
  }
}

enum ChatMeetupAction: Equatable, Sendable, Encodable {
  case intent(ChatMeetupIntentValue)
  case calendarAvailability(window: MeetupAvailability, busy: [MeetupAvailability])
  case manualAvailability(window: MeetupAvailability, available: [MeetupAvailability])
  case clearAvailability
  case approveTime(candidateID: UUID)
  case currentLocation(latitude: Double, longitude: Double, station: String?, nearestStation: String?, expiresAt: Date?, nearbyStations: [String])
  case stationLocation(name: String, expiresAt: Date?, nearbyStations: [String])
  case clearLocation
  case approveCafe(candidateID: String)
  case declineCafe(candidateID: String)
  case replan
  case cancel
  case completeMeeting

  private enum CodingKeys: String, CodingKey {
    case type, value, source, window, busy, available, candidateID = "candidate_id", location
  }

  private enum LocationCodingKeys: String, CodingKey {
    case kind, latitude, longitude, station, nearestStation = "nearest_station"
    case nearbyStationNames = "nearby_station_names"
    case stationName = "station_name"
    case expiresAt = "expires_at"
  }

  func encode(to encoder: Encoder) throws {
    try validate()
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .intent(value):
      try container.encode("intent", forKey: .type)
      try container.encode(value, forKey: .value)
    case let .calendarAvailability(window, busy):
      try container.encode("availability.submit", forKey: .type)
      try container.encode("calendar", forKey: .source)
      try container.encode(window, forKey: .window)
      try container.encode(busy, forKey: .busy)
    case let .manualAvailability(window, available):
      try container.encode("availability.submit", forKey: .type)
      try container.encode("manual", forKey: .source)
      try container.encode(window, forKey: .window)
      try container.encode(available, forKey: .available)
    case .clearAvailability:
      try container.encode("availability.clear", forKey: .type)
    case let .approveTime(candidateID):
      try container.encode("time.approve", forKey: .type)
      try container.encode(candidateID.uuidString.lowercased(), forKey: .candidateID)
    case let .currentLocation(latitude, longitude, station, nearestStation, expiresAt, nearbyStations):
      try container.encode("location.submit", forKey: .type)
      var location = container.nestedContainer(keyedBy: LocationCodingKeys.self, forKey: .location)
      try location.encode("coordinates", forKey: .kind)
      try location.encode(latitude, forKey: .latitude)
      try location.encode(longitude, forKey: .longitude)
      try location.encodeIfPresent(nearestStation ?? station, forKey: .nearestStation)
      try location.encode(nearbyStations, forKey: .nearbyStationNames)
    case let .stationLocation(name, expiresAt, nearbyStations):
      try container.encode("location.submit", forKey: .type)
      var location = container.nestedContainer(keyedBy: LocationCodingKeys.self, forKey: .location)
      try location.encode("station", forKey: .kind)
      try location.encode(name, forKey: .stationName)
      try location.encode(nearbyStations, forKey: .nearbyStationNames)
    case .clearLocation:
      try container.encode("location.clear", forKey: .type)
    case let .approveCafe(candidateID):
      try container.encode("cafe.approve", forKey: .type)
      try container.encode(candidateID, forKey: .candidateID)
    case let .declineCafe(candidateID):
      try container.encode("cafe.decline", forKey: .type)
      try container.encode(candidateID, forKey: .candidateID)
    case .replan:
      try container.encode("replan", forKey: .type)
    case .cancel:
      try container.encode("cancel", forKey: .type)
    case .completeMeeting:
      try container.encode("meeting.complete", forKey: .type)
    }
  }

  func validate(now: Date = Date()) throws {
    func validateWindow(_ window: MeetupAvailability) throws {
      let duration = window.endsAt.timeIntervalSince(window.startsAt)
      guard duration > 0, duration <= 21 * 24 * 60 * 60,
        window.startsAt >= now,
        window.endsAt <= now.addingTimeInterval(21 * 24 * 60 * 60),
        window.startsAt.timeIntervalSince1970.isFinite,
        window.endsAt.timeIntervalSince1970.isFinite
      else {
        throw ChatsDTOValidationError.invalidTimestamp
      }
    }
    func validateIntervals(_ intervals: [MeetupAvailability], maximum: Int) throws {
      guard intervals.count <= maximum else { throw ChatsDTOValidationError.invalidValue }
      var keys = Set<String>()
      for interval in intervals {
        guard interval.startsAt < interval.endsAt,
          interval.startsAt.timeIntervalSince1970.isFinite,
          interval.endsAt.timeIntervalSince1970.isFinite
        else { throw ChatsDTOValidationError.invalidTimestamp }
        let key = "\(MeetupTimestamp.encode(interval.startsAt))\u{0}\(MeetupTimestamp.encode(interval.endsAt))"
        guard keys.insert(key).inserted else { throw ChatsDTOValidationError.invalidValue }
      }
    }
    func validateStation(_ value: String) throws {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed == value, trimmed.count <= 120,
        !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else { throw ChatsDTOValidationError.invalidValue }
    }
    func validateStations(_ values: [String]) throws {
      guard values.count <= 8 else { throw ChatsDTOValidationError.invalidValue }
      for value in values { try validateStation(value) }
      guard
        Set(values.map { $0.lowercased() }).count == values.count
      else { throw ChatsDTOValidationError.invalidValue }
    }

    switch self {
    case .intent:
      break
    case let .calendarAvailability(window, busy):
      try validateWindow(window)
      try validateIntervals(busy, maximum: NativeBusyCalendarProjection.maximumIntervalCount)
      guard busy.allSatisfy({ $0.startsAt >= window.startsAt && $0.endsAt <= window.endsAt }) else {
        throw ChatsDTOValidationError.invalidTimestamp
      }
    case let .manualAvailability(window, available):
      try validateWindow(window)
      try validateIntervals(available, maximum: 32)
      guard available.allSatisfy({ $0.startsAt >= window.startsAt && $0.endsAt <= window.endsAt }) else {
        throw ChatsDTOValidationError.invalidTimestamp
      }
    case let .approveTime(candidateID):
      _ = candidateID
    case let .currentLocation(latitude, longitude, station, nearestStation, expiresAt, nearbyStations):
      guard latitude.isFinite, (-90...90).contains(latitude),
        longitude.isFinite, (-180...180).contains(longitude)
      else { throw ChatsDTOValidationError.invalidValue }
      guard let expiresAt,
        expiresAt > now,
        expiresAt <= now.addingTimeInterval(NativeLocationConsentPayload.maximumTTL)
      else { throw ChatsDTOValidationError.invalidTimestamp }
      if let nearestStation { try validateStation(nearestStation) }
      if let station { try validateStation(station) }
      try validateStations(nearbyStations)
    case let .stationLocation(name, expiresAt, nearbyStations):
      try validateStation(name)
      if let expiresAt {
        guard expiresAt > now, expiresAt <= now.addingTimeInterval(NativeLocationConsentPayload.maximumTTL) else {
          throw ChatsDTOValidationError.invalidTimestamp
        }
      }
      try validateStations(nearbyStations)
    case .clearAvailability, .clearLocation, .replan, .cancel, .completeMeeting:
      break
    case let .approveCafe(candidateID), let .declineCafe(candidateID):
      guard (1...256).contains(candidateID.utf8.count) else { throw ChatsDTOValidationError.invalidValue }
    }
  }
}

enum ChatMeetupReflectionTraitKey: String, Codable, CaseIterable, Sendable {
  case socialEnergy = "social_energy"
  case planningStyle = "planning_style"
  case decisionStyle = "decision_style"
  case attachmentTendency = "attachment_tendency"
  case conflictStyle = "conflict_style"
  case rhythmPreference = "rhythm_preference"
  case communicationPreference = "communication_preference"
  case priorityValue = "priority_value"
  case favoriteActivity = "favorite_activity"

  func accepts(_ value: ChatMeetupReflectionTraitValue) -> Bool {
    switch self {
    case .socialEnergy: [.introverted, .ambiverted, .extroverted].contains(value)
    case .planningStyle: [.planned, .mixed, .spontaneous].contains(value)
    case .decisionStyle: [.analytical, .balanced, .emotional].contains(value)
    case .attachmentTendency: [.secure, .anxious, .avoidant].contains(value)
    case .conflictStyle: [.dialogue, .yields, .maintains, .avoids].contains(value)
    case .rhythmPreference: [.slow, .moderate, .fast].contains(value)
    case .communicationPreference: [.concise, .balanced, .detailed].contains(value)
    case .priorityValue: [.family, .friendship, .independence, .creativity, .learning, .stability, .community].contains(value)
    case .favoriteActivity: [.arts, .music, .reading, .outdoors, .food, .technology, .sports].contains(value)
    }
  }
}

enum ChatMeetupReflectionTraitValue: String, Codable, CaseIterable, Sendable {
  case introverted, ambiverted, extroverted
  case planned, mixed, spontaneous
  case analytical, balanced, emotional
  case secure, anxious, avoidant
  case dialogue, yields, maintains, avoids
  case slow, moderate, fast
  case concise, detailed
  case family, friendship, independence, creativity, learning, stability, community
  case arts, music, reading, outdoors, food, technology, sports
}

struct ChatMeetupReflectionTrait: Codable, Equatable, Sendable {
  let key: ChatMeetupReflectionTraitKey
  let value: ChatMeetupReflectionTraitValue

  private enum CodingKeys: String, CodingKey {
    case key = "trait_key"
    case value
  }

  init(key: ChatMeetupReflectionTraitKey, value: ChatMeetupReflectionTraitValue) {
    self.key = key
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    key = try container.decode(ChatMeetupReflectionTraitKey.self, forKey: .key)
    value = try container.decode(ChatMeetupReflectionTraitValue.self, forKey: .value)
  }

  static func validate(_ value: ChatMeetupReflectionTrait) throws {
    guard value.key.accepts(value.value) else { throw ChatsDTOValidationError.invalidValue }
  }
}

struct ChatMeetupReflectionSnapshot: Decodable, Equatable, Sendable, APIValidatable {
  let meetupID: UUID
  let currentPersonaVersion: Int
  let confirmedTraits: [ChatMeetupReflectionTrait]
  let confirmedAt: Date?

  private enum CodingKeys: String, CodingKey {
    case meetupID = "meetup_id"
    case currentPersonaVersion = "current_persona_version"
    case confirmedTraits = "confirmed_traits"
    case confirmedAt = "confirmed_at"
  }

  init(meetupID: UUID, currentPersonaVersion: Int, confirmedTraits: [ChatMeetupReflectionTrait], confirmedAt: Date?) {
    self.meetupID = meetupID
    self.currentPersonaVersion = currentPersonaVersion
    self.confirmedTraits = confirmedTraits
    self.confirmedAt = confirmedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    meetupID = try APIDTOValidation.requireUUID(container.decode(String.self, forKey: .meetupID))
    currentPersonaVersion = try container.decode(Int.self, forKey: .currentPersonaVersion)
    let rawTraits = try container.decode([String: String].self, forKey: .confirmedTraits)
    confirmedTraits = try rawTraits.map { rawKey, rawValue in
      guard let key = ChatMeetupReflectionTraitKey(rawValue: rawKey),
        let value = ChatMeetupReflectionTraitValue(rawValue: rawValue)
      else { throw ChatsDTOValidationError.invalidValue }
      return ChatMeetupReflectionTrait(key: key, value: value)
    }.sorted { $0.key.rawValue < $1.key.rawValue }
    if let rawConfirmedAt = try container.decodeIfPresent(String.self, forKey: .confirmedAt) {
      confirmedAt = try APIDTOValidation.requireRFC3339(rawConfirmedAt)
    } else {
      confirmedAt = nil
    }
  }

  static func validate(_ value: ChatMeetupReflectionSnapshot) throws {
    guard value.currentPersonaVersion >= 0,
      value.confirmedTraits.count <= ChatMeetupReflectionTraitKey.allCases.count
    else { throw ChatsDTOValidationError.invalidValue }
    var keys = Set<ChatMeetupReflectionTraitKey>()
    for trait in value.confirmedTraits {
      try ChatMeetupReflectionTrait.validate(trait)
      guard keys.insert(trait.key).inserted else { throw ChatsDTOValidationError.invalidValue }
    }
  }
}

struct ChatMeetupReflectionUserStatement: Encodable, Equatable, Sendable {
  let turnID: UUID
  let text: String

  private enum CodingKeys: String, CodingKey {
    case turnID = "turn_id"
    case text
  }

  init(turnID: UUID, text: String) {
    self.turnID = turnID
    self.text = text
  }

  func validate() throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 600
    else { throw ChatsDTOValidationError.invalidValue }
  }
}

struct ChatMeetupReflectionDraftCandidate: Decodable, Equatable, Identifiable, Sendable {
  let id: UUID
  let key: ChatMeetupReflectionTraitKey
  let value: ChatMeetupReflectionTraitValue
  let sourceTurnIDs: [UUID]
  let evidenceLabel: String
  let confidenceLabel: String

  private enum CodingKeys: String, CodingKey {
    case id = "candidate_id"
    case key = "trait_key"
    case value
    case sourceTurnIDs = "source_turn_ids"
    case evidenceLabel = "evidence_label"
    case confidenceLabel = "confidence_label"
  }

  init(
    id: UUID,
    key: ChatMeetupReflectionTraitKey,
    value: ChatMeetupReflectionTraitValue,
    sourceTurnIDs: [UUID],
    evidenceLabel: String = "user_statement",
    confidenceLabel: String = "AI draft; not confirmed"
  ) {
    self.id = id
    self.key = key
    self.value = value
    self.sourceTurnIDs = sourceTurnIDs
    self.evidenceLabel = evidenceLabel
    self.confidenceLabel = confidenceLabel
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(container.decode(String.self, forKey: .id))
    key = try container.decode(ChatMeetupReflectionTraitKey.self, forKey: .key)
    value = try container.decode(ChatMeetupReflectionTraitValue.self, forKey: .value)
    sourceTurnIDs = try container.decode([String].self, forKey: .sourceTurnIDs).map(APIDTOValidation.requireUUID)
    evidenceLabel = try container.decode(String.self, forKey: .evidenceLabel)
    confidenceLabel = try container.decode(String.self, forKey: .confidenceLabel)
  }

  static func validate(_ value: ChatMeetupReflectionDraftCandidate) throws {
    try ChatMeetupReflectionTrait.validate(.init(key: value.key, value: value.value))
    guard !value.sourceTurnIDs.isEmpty,
      value.sourceTurnIDs.count <= 5,
      Set(value.sourceTurnIDs).count == value.sourceTurnIDs.count,
      value.evidenceLabel == "user_statement",
      value.confidenceLabel == "AI draft; not confirmed"
    else { throw ChatsDTOValidationError.invalidValue }
  }
}

struct ChatMeetupReflectionDraft: Decodable, Equatable, Sendable, APIValidatable {
  let expectedVersion: Int
  let candidates: [ChatMeetupReflectionDraftCandidate]

  private enum CodingKeys: String, CodingKey {
    case expectedVersion = "expected_version"
    case candidates
  }

  init(expectedVersion: Int, candidates: [ChatMeetupReflectionDraftCandidate]) {
    self.expectedVersion = expectedVersion
    self.candidates = candidates
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    expectedVersion = try container.decode(Int.self, forKey: .expectedVersion)
    candidates = try container.decode([ChatMeetupReflectionDraftCandidate].self, forKey: .candidates)
  }

  static func validate(_ value: ChatMeetupReflectionDraft) throws {
    guard value.expectedVersion >= 0, value.candidates.count <= 9 else {
      throw ChatsDTOValidationError.invalidValue
    }
    var IDs = Set<UUID>()
    for candidate in value.candidates {
      try ChatMeetupReflectionDraftCandidate.validate(candidate)
      guard IDs.insert(candidate.id).inserted else { throw ChatsDTOValidationError.invalidValue }
    }
  }

  static func validate(_ value: ChatMeetupReflectionDraft, sourceTurnIDs: Set<UUID>) throws {
    try validate(value)
    guard value.candidates.allSatisfy({ Set($0.sourceTurnIDs).isSubset(of: sourceTurnIDs) }) else {
      throw ChatsDTOValidationError.invalidValue
    }
  }
}

struct ChatMeetupReflectionConfirmation: Decodable, Equatable, Sendable, APIValidatable {
  let version: Int
  let confirmedAt: Date
  let traits: [ChatMeetupReflectionTrait]
  let replayed: Bool

  private enum CodingKeys: String, CodingKey {
    case personaVersion = "version"
    case confirmedTraits = "confirmed_traits"
    case replayed
    case confirmedAt = "confirmed_at"
  }

  init(version: Int, confirmedAt: Date, traits: [ChatMeetupReflectionTrait], replayed: Bool = false) {
    self.version = version
    self.confirmedAt = confirmedAt
    self.traits = traits
    self.replayed = replayed
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .personaVersion)
    confirmedAt = try APIDTOValidation.requireRFC3339(container.decode(String.self, forKey: .confirmedAt))
    replayed = try container.decode(Bool.self, forKey: .replayed)
    let rawTraits = try container.decode([String: String].self, forKey: .confirmedTraits)
    traits = try rawTraits.map { rawKey, rawValue in
      guard let key = ChatMeetupReflectionTraitKey(rawValue: rawKey),
        let value = ChatMeetupReflectionTraitValue(rawValue: rawValue)
      else { throw ChatsDTOValidationError.invalidValue }
      return ChatMeetupReflectionTrait(key: key, value: value)
    }.sorted { $0.key.rawValue < $1.key.rawValue }
  }

  static func validate(_ value: ChatMeetupReflectionConfirmation) throws {
    guard value.version > 0 else { throw ChatsDTOValidationError.invalidValue }
    for trait in value.traits { try ChatMeetupReflectionTrait.validate(trait) }
    guard Set(value.traits.map(\.key)).count == value.traits.count else {
      throw ChatsDTOValidationError.invalidValue
    }
  }
}

enum ChatMeetupWardSpeaker: String, Decodable, Equatable, Sendable {
  case myWard = "my_ward"
  case partnerWard = "partner_ward"
}

struct ChatMeetupWardConversationEvent: Decodable, Equatable, Identifiable, Sendable {
  let id: UUID
  let speaker: ChatMeetupWardSpeaker
  let text: String
  let round: Int
  let createdAt: Date

  private enum CodingKeys: String, CodingKey {
    case id, speaker, text, round
    case kind
    case createdAt = "created_at"
  }

  init(id: UUID, speaker: ChatMeetupWardSpeaker, text: String, round: Int, createdAt: Date) {
    self.id = id
    self.speaker = speaker
    self.text = text
    self.round = round
    self.createdAt = createdAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(container.decode(String.self, forKey: .id))
    guard try container.decode(String.self, forKey: .kind) == "ward" else {
      throw ChatsDTOValidationError.invalidValue
    }
    speaker = try container.decode(ChatMeetupWardSpeaker.self, forKey: .speaker)
    text = try container.decode(String.self, forKey: .text)
    round = try container.decode(Int.self, forKey: .round)
    createdAt = try APIDTOValidation.requireRFC3339(container.decode(String.self, forKey: .createdAt))
  }

  static func validate(_ value: ChatMeetupWardConversationEvent) throws {
    guard !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.text.count <= 1_200,
      (0...10_000).contains(value.round)
    else { throw ChatsDTOValidationError.invalidValue }
  }
}

struct ChatMeetupWardConversationPayload: Decodable, Equatable, Sendable, APIValidatable {
  let roomID: UUID
  let events: [ChatMeetupWardConversationEvent]
  let nextCursor: String?
  let hasMore: Bool

  private enum CodingKeys: String, CodingKey {
    case roomID = "room_id"
    case events
    case nextCursor = "next_cursor"
    case hasMore = "has_more"
  }

  init(roomID: UUID, events: [ChatMeetupWardConversationEvent], nextCursor: String? = nil, hasMore: Bool = false) {
    self.roomID = roomID
    self.events = events
    self.nextCursor = nextCursor
    self.hasMore = hasMore
  }

  static func validate(_ value: ChatMeetupWardConversationPayload) throws {
    try validate(value, nextCursor: value.nextCursor, hasMore: value.hasMore)
  }

  static func validateEnvelope(
    _ value: ChatMeetupWardConversationPayload,
    nextCursor: String?,
    hasMore: Bool?,
    includesNextCursor: Bool,
    includesHasMore: Bool
  ) throws {
    let merged = ChatMeetupWardConversationPayload(
      roomID: value.roomID,
      events: value.events,
      nextCursor: includesNextCursor ? nextCursor : value.nextCursor,
      hasMore: includesHasMore ? (hasMore ?? false) : value.hasMore
    )
    try validate(merged, nextCursor: merged.nextCursor, hasMore: merged.hasMore)
  }

  private static func validate(
    _ value: ChatMeetupWardConversationPayload,
    nextCursor: String?,
    hasMore: Bool
  ) throws {
    guard value.roomID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
      value.events.count <= 100,
      hasMore ? !(nextCursor?.isEmpty ?? true) : nextCursor == nil
    else { throw ChatsDTOValidationError.invalidValue }
    var IDs = Set<UUID>()
    var previous: Date?
    for event in value.events {
      try ChatMeetupWardConversationEvent.validate(event)
      guard IDs.insert(event.id).inserted,
        previous.map({ event.createdAt >= $0 }) ?? true
      else { throw ChatsDTOValidationError.invalidValue }
      previous = event.createdAt
    }
  }
}

// Server-authorized fictional counterpart actions. No peer identifier is accepted.
enum JudgeCounterpartOperation: String, Encodable, Sendable {
  case accept, intent, availability
  case timeApprove = "time_approve"
  case simulateCompletion = "simulate_completion"
}

struct JudgeCounterpartAdvanceResult: Decodable, Sendable, APIValidatable {
  let outcome: String
  let matchID: UUID
  let roomID: UUID?
  let meetupID: UUID?
  let status: String
  let revision: Int

  enum CodingKeys: String, CodingKey {
    case outcome, status, revision
    case matchID = "match_id"
    case roomID = "room_id"
    case meetupID = "meetup_id"
  }

  static func validate(_ value: Self) throws {
    guard value.revision >= 0, ["ok", "replayed"].contains(value.outcome),
      !value.status.isEmpty, value.status.count <= 80 else { throw APIClientError.invalidResponse }
  }
}
