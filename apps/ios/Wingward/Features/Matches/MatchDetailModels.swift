import Foundation

enum MatchDetailDTOValidationError: Error, Equatable, Sendable {
  case invalidIdentifier
  case invalidDate
  case invalidValue
  case invalidSpeaker
}

struct MatchDetailPartner: Decodable, Equatable, Sendable {
  let nickname: String?

  enum CodingKeys: String, CodingKey {
    case nickname
  }

  var displayName: String {
    let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "Wingward member" : trimmed
  }
}

/// A deliberately closed view of the matching result. Score, location, direct
/// chat, and other server fields are left out so they cannot reach UI code.
/// The public fox summary and existing partner Ward chat ID are the only
/// additional entries explicitly allowed into this projection.
struct ProductionMatchDetail: Decodable, Equatable, Identifiable, Sendable, APIValidatable {
  let id: UUID
  let partnerID: UUID
  let partner: MatchDetailPartner
  let status: String
  let foxConversationID: UUID?
  let partnerFoxChatID: UUID?
  let foxSummary: String?
  let simulatedCounterpart: Bool

  enum CodingKeys: String, CodingKey {
    case id
    case partnerID = "partner_id"
    case partner
    case status
    case foxConversationID = "fox_conversation_id"
    case partnerFoxChatID = "partner_fox_chat_id"
    case foxSummary = "fox_summary"
    case simulatedCounterpart = "simulated_counterpart"
  }

  init(
    id: UUID,
    partnerID: UUID,
    partner: MatchDetailPartner,
    status: String,
    foxConversationID: UUID?,
    partnerFoxChatID: UUID? = nil,
    foxSummary: String? = nil,
    simulatedCounterpart: Bool = false
  ) {
    self.id = id
    self.partnerID = partnerID
    self.partner = partner
    self.status = status
    self.foxConversationID = foxConversationID
    self.partnerFoxChatID = partnerFoxChatID
    self.foxSummary = foxSummary
    self.simulatedCounterpart = simulatedCounterpart
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .id))
    partnerID = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .partnerID))
    partner = try container.decode(MatchDetailPartner.self, forKey: .partner)
    status = try container.decode(String.self, forKey: .status)
    if let rawConversationID = try container.decodeIfPresent(String.self, forKey: .foxConversationID) {
      foxConversationID = try APIDTOValidation.requireUUID(rawConversationID)
    } else {
      foxConversationID = nil
    }
    if let rawPartnerFoxChatID = try container.decodeIfPresent(String.self, forKey: .partnerFoxChatID) {
      partnerFoxChatID = try APIDTOValidation.requireUUID(rawPartnerFoxChatID)
    } else {
      partnerFoxChatID = nil
    }
    foxSummary = try container.decodeIfPresent(String.self, forKey: .foxSummary)
    simulatedCounterpart = try container.decodeIfPresent(Bool.self, forKey: .simulatedCounterpart) ?? false
  }

  static func validate(_ value: ProductionMatchDetail) throws {
    if let nickname = value.partner.nickname {
      guard nickname.count <= 120 else { throw MatchDetailDTOValidationError.invalidValue }
    }
    guard !value.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.status.count <= 80
    else {
      throw MatchDetailDTOValidationError.invalidValue
    }
    if let foxSummary = value.foxSummary {
      guard foxSummary.count <= 2_000 else {
        throw MatchDetailDTOValidationError.invalidValue
      }
    }
  }
}

/// Closed projection of `GET /api/partner-fox-chats/:id`.
struct PartnerFoxChatDetail: Decodable, Equatable, Sendable, APIValidatable {
  let id: UUID
  let matchID: UUID
  let userID: UUID
  let partnerUserID: UUID
  let createdAt: Date
  let partner: MatchDetailPartner

  enum CodingKeys: String, CodingKey {
    case id
    case matchID = "match_id"
    case userID = "user_id"
    case partnerUserID = "partner_user_id"
    case createdAt = "created_at"
    case partner
  }

  init(
    id: UUID,
    matchID: UUID,
    userID: UUID,
    partnerUserID: UUID,
    createdAt: Date,
    partner: MatchDetailPartner
  ) {
    self.id = id
    self.matchID = matchID
    self.userID = userID
    self.partnerUserID = partnerUserID
    self.createdAt = createdAt
    self.partner = partner
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .id))
    matchID = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .matchID))
    userID = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .userID))
    partnerUserID = try APIDTOValidation.requireUUID(
      try container.decode(String.self, forKey: .partnerUserID)
    )
    createdAt = try APIDTOValidation.requireRFC3339(
      try container.decode(String.self, forKey: .createdAt)
    )
    partner = try container.decode(MatchDetailPartner.self, forKey: .partner)
  }

  static func validate(_ value: PartnerFoxChatDetail) throws {
    if let nickname = value.partner.nickname {
      guard nickname.count <= 120 else { throw MatchDetailDTOValidationError.invalidValue }
    }
  }
}

/// The response returned by `POST /api/partner-fox-chats`.  The server creates
/// the chat and persists the first Fox message atomically; the native client
/// therefore publishes only the identifiers and message returned here.
struct PartnerFoxChatStartResult: Decodable, Equatable, Sendable, APIValidatable {
  let id: UUID
  let matchID: UUID
  let partner: MatchDetailPartner
  let firstMessage: PartnerFoxMessage

  enum CodingKeys: String, CodingKey {
    case id
    case matchID = "match_id"
    case partner
    case firstMessage = "first_message"
  }

  init(
    id: UUID,
    matchID: UUID,
    partner: MatchDetailPartner,
    firstMessage: PartnerFoxMessage
  ) {
    self.id = id
    self.matchID = matchID
    self.partner = partner
    self.firstMessage = firstMessage
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .id))
    matchID = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .matchID))
    partner = try container.decode(MatchDetailPartner.self, forKey: .partner)
    firstMessage = try container.decode(PartnerFoxMessage.self, forKey: .firstMessage)
  }

  static func validate(_ value: PartnerFoxChatStartResult) throws {
    guard value.id != value.matchID else {
      throw MatchDetailDTOValidationError.invalidValue
    }
    if let nickname = value.partner.nickname {
      guard nickname.count <= 120 else { throw MatchDetailDTOValidationError.invalidValue }
    }
    guard value.firstMessage.role == .fox else {
      throw MatchDetailDTOValidationError.invalidSpeaker
    }
    try PartnerFoxMessage.validate(value.firstMessage)
  }
}

enum PartnerFoxMessageRole: String, Decodable, Equatable, Sendable {
  case user
  case fox
}

/// Message rows deliberately omit `chat_id`: the current history endpoint
/// binds them to the already validated chat ID in its request path.
struct PartnerFoxMessage: Decodable, Equatable, Identifiable, Sendable {
  let id: UUID
  let role: PartnerFoxMessageRole
  let content: String
  let createdAt: Date

  enum CodingKeys: String, CodingKey {
    case id
    case role
    case content
    case createdAt = "created_at"
  }

  init(id: UUID, role: PartnerFoxMessageRole, content: String, createdAt: Date) {
    self.id = id
    self.role = role
    self.content = content
    self.createdAt = createdAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .id))
    guard let decodedRole = PartnerFoxMessageRole(
      rawValue: try container.decode(String.self, forKey: .role)
    ) else {
      throw MatchDetailDTOValidationError.invalidSpeaker
    }
    role = decodedRole
    content = try container.decode(String.self, forKey: .content)
    createdAt = try APIDTOValidation.requireRFC3339(
      try container.decode(String.self, forKey: .createdAt)
    )
  }

  static func validate(_ value: PartnerFoxMessage) throws {
    guard !value.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.content.count <= 2_000
    else {
      throw MatchDetailDTOValidationError.invalidValue
    }
  }
}

/// The current endpoint returns the complete history and a closed pagination
/// state. `nextCursor` and `hasMore` are retained so fixture-backed stores
/// cannot accidentally publish a future paginated response as complete.
struct PartnerFoxMessagesPayload: Decodable, Equatable, Sendable, APIValidatable {
  let messages: [PartnerFoxMessage]
  let nextCursor: String?
  let hasMore: Bool

  init(messages: [PartnerFoxMessage], nextCursor: String? = nil, hasMore: Bool = false) {
    self.messages = messages
    self.nextCursor = nextCursor
    self.hasMore = hasMore
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    messages = try container.decode([PartnerFoxMessage].self)
    nextCursor = nil
    hasMore = false
  }

  static func validate(_ value: PartnerFoxMessagesPayload) throws {
    guard value.nextCursor == nil, !value.hasMore else {
      throw MatchDetailDTOValidationError.invalidValue
    }

    var messageIDs = Set<UUID>()
    var previousDate: Date?
    for message in value.messages {
      guard messageIDs.insert(message.id).inserted else {
        throw MatchDetailDTOValidationError.invalidValue
      }
      try PartnerFoxMessage.validate(message)
      if let previousDate, message.createdAt < previousDate {
        throw MatchDetailDTOValidationError.invalidValue
      }
      previousDate = message.createdAt
    }
  }

  static func validateEnvelope(
    _ value: PartnerFoxMessagesPayload,
    nextCursor: String?,
    hasMore: Bool?,
    includesNextCursor: Bool,
    includesHasMore: Bool
  ) throws {
    try validate(value)
    guard includesNextCursor, includesHasMore, nextCursor == nil, hasMore == false else {
      throw MatchDetailDTOValidationError.invalidValue
    }
  }
}

/// The response returned by `POST /api/partner-fox-chats/:id/messages`.
/// Both rows are server-created and must be displayed exactly as returned.
struct PartnerFoxMessageSendResult: Decodable, Equatable, Sendable, APIValidatable {
  let userMessage: PartnerFoxMessage
  let foxMessage: PartnerFoxMessage

  enum CodingKeys: String, CodingKey {
    case userMessage = "user_message"
    case foxMessage = "fox_message"
  }

  init(userMessage: PartnerFoxMessage, foxMessage: PartnerFoxMessage) {
    self.userMessage = userMessage
    self.foxMessage = foxMessage
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    userMessage = try container.decode(PartnerFoxMessage.self, forKey: .userMessage)
    foxMessage = try container.decode(PartnerFoxMessage.self, forKey: .foxMessage)
  }

  static func validate(_ value: PartnerFoxMessageSendResult) throws {
    guard value.userMessage.role == .user, value.foxMessage.role == .fox,
      value.userMessage.id != value.foxMessage.id
    else {
      throw MatchDetailDTOValidationError.invalidValue
    }
    try PartnerFoxMessage.validate(value.userMessage)
    try PartnerFoxMessage.validate(value.foxMessage)
  }
}

struct PartnerFoxMessageSendRecoveryResult: Decodable, Equatable, Sendable, APIValidatable {
  enum Outcome: String, Decodable, Sendable {
    case completed
    case processing
    case failed
    case unknown
    case missing
    case conflict
    case notFound = "not_found"
    case ineligible
    case invalidInput = "invalid_input"
  }

  let outcome: Outcome
  let userMessage: PartnerFoxMessage?
  let foxMessage: PartnerFoxMessage?

  enum CodingKeys: String, CodingKey {
    case outcome
    case userMessage = "user_message"
    case foxMessage = "fox_message"
  }

  init(outcome: Outcome, userMessage: PartnerFoxMessage?, foxMessage: PartnerFoxMessage?) {
    self.outcome = outcome
    self.userMessage = userMessage
    self.foxMessage = foxMessage
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    outcome = try container.decode(Outcome.self, forKey: .outcome)
    userMessage = try container.decodeIfPresent(PartnerFoxMessage.self, forKey: .userMessage)
    foxMessage = try container.decodeIfPresent(PartnerFoxMessage.self, forKey: .foxMessage)
  }

  static func validate(_ value: PartnerFoxMessageSendRecoveryResult) throws {
    if value.outcome == .completed {
      guard let userMessage = value.userMessage, let foxMessage = value.foxMessage else {
        throw MatchDetailDTOValidationError.invalidValue
      }
      try PartnerFoxMessageSendResult.validate(
        PartnerFoxMessageSendResult(userMessage: userMessage, foxMessage: foxMessage)
      )
      return
    }
    guard value.userMessage == nil, value.foxMessage == nil else {
      throw MatchDetailDTOValidationError.invalidValue
    }
  }
}

struct FoxConversationStartResult: Decodable, Equatable, Sendable, APIValidatable {
  let conversationID: UUID
  let matchID: UUID

  enum CodingKeys: String, CodingKey {
    case conversationID = "fox_conversation_id"
    case matchID = "match_id"
  }

  init(conversationID: UUID, matchID: UUID) {
    self.conversationID = conversationID
    self.matchID = matchID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    conversationID = try APIDTOValidation.requireUUID(
      try container.decode(String.self, forKey: .conversationID)
    )
    matchID = try APIDTOValidation.requireUUID(
      try container.decode(String.self, forKey: .matchID)
    )
  }

  static func validate(_ value: FoxConversationStartResult) throws {
    guard value.conversationID != value.matchID else {
      throw MatchDetailDTOValidationError.invalidValue
    }
  }
}

struct FoxConversationSummary: Decodable, Equatable, Sendable, APIValidatable {
  let id: UUID
  let matchID: UUID
  let status: String
  let totalRounds: Int
  let currentRound: Int
  let startedAt: Date?
  let completedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id
    case matchID = "match_id"
    case status
    case totalRounds = "total_rounds"
    case currentRound = "current_round"
    case startedAt = "started_at"
    case completedAt = "completed_at"
  }

  init(
    id: UUID,
    matchID: UUID,
    status: String,
    totalRounds: Int,
    currentRound: Int,
    startedAt: Date? = nil,
    completedAt: Date? = nil
  ) {
    self.id = id
    self.matchID = matchID
    self.status = status
    self.totalRounds = totalRounds
    self.currentRound = currentRound
    self.startedAt = startedAt
    self.completedAt = completedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .id))
    matchID = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .matchID))
    status = try container.decode(String.self, forKey: .status)
    totalRounds = try container.decode(Int.self, forKey: .totalRounds)
    currentRound = try container.decode(Int.self, forKey: .currentRound)
    startedAt = try Self.decodeDate(container, forKey: .startedAt)
    completedAt = try Self.decodeDate(container, forKey: .completedAt)
  }

  static func validate(_ value: FoxConversationSummary) throws {
    guard !value.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.status.count <= 80,
      value.totalRounds >= 0,
      value.currentRound >= 0,
      value.currentRound <= value.totalRounds
    else {
      throw MatchDetailDTOValidationError.invalidValue
    }
  }

  private static func decodeDate(
    _ container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> Date? {
    guard let rawValue = try container.decodeIfPresent(String.self, forKey: key) else {
      return nil
    }
    return try APIDTOValidation.requireRFC3339(rawValue)
  }
}

enum FoxConversationSpeaker: String, Codable, Equatable, Sendable {
  case myFox = "my_fox"
  case partnerFox = "partner_fox"
}

struct FoxConversationMessage: Decodable, Equatable, Identifiable, Sendable {
  let id: UUID
  let speaker: FoxConversationSpeaker
  let content: String
  let roundNumber: Int
  let createdAt: Date

  enum CodingKeys: String, CodingKey {
    case id
    case speaker
    case content
    case roundNumber = "round_number"
    case createdAt = "created_at"
  }

  init(
    id: UUID,
    speaker: FoxConversationSpeaker,
    content: String,
    roundNumber: Int,
    createdAt: Date
  ) {
    self.id = id
    self.speaker = speaker
    self.content = content
    self.roundNumber = roundNumber
    self.createdAt = createdAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .id))
    guard let decodedSpeaker = FoxConversationSpeaker(
      rawValue: try container.decode(String.self, forKey: .speaker)
    ) else {
      throw MatchDetailDTOValidationError.invalidSpeaker
    }
    speaker = decodedSpeaker
    content = try container.decode(String.self, forKey: .content)
    roundNumber = try container.decode(Int.self, forKey: .roundNumber)
    createdAt = try APIDTOValidation.requireRFC3339(
      try container.decode(String.self, forKey: .createdAt)
    )
  }

  static func validate(_ value: FoxConversationMessage) throws {
    let trimmed = value.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, value.content.count <= 8_000, value.roundNumber >= 1 else {
      throw MatchDetailDTOValidationError.invalidValue
    }
  }
}

struct FoxConversationMessagesPayload: Decodable, Equatable, Sendable, APIValidatable {
  let messages: [FoxConversationMessage]

  init(messages: [FoxConversationMessage]) {
    self.messages = messages
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    messages = try container.decode([FoxConversationMessage].self)
  }

  static func validate(_ value: FoxConversationMessagesPayload) throws {
    guard value.messages.count <= 100 else { throw MatchDetailDTOValidationError.invalidValue }
    var messageIDs = Set<UUID>()
    for message in value.messages {
      guard messageIDs.insert(message.id).inserted else {
        throw MatchDetailDTOValidationError.invalidValue
      }
      try FoxConversationMessage.validate(message)
    }
  }
}
