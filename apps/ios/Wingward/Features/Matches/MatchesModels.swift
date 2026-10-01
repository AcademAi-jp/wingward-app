import Foundation

enum MatchesDTOValidationError: Error, Equatable, Sendable {
  case invalidIdentifier
  case invalidURL
  case invalidDate
  case invalidValue
}

enum RecordingRehearsalPreviewOutcome: String, Decodable, Equatable, Sendable {
  case eligible
  case notEligible = "not_eligible"
  case alreadyExists = "already_exists"
  case expired
}

enum RecordingRehearsalStartOutcome: String, Decodable, Equatable, Sendable {
  case started
  case startedPartial = "started_partial"
  case notEligible = "not_eligible"
  case alreadyExists = "already_exists"
  case expired
}

struct RecordingRehearsalPreviewResult: Decodable, Equatable, Sendable, APIValidatable {
  let outcome: RecordingRehearsalPreviewOutcome
  let count: Int

  init(outcome: RecordingRehearsalPreviewOutcome, count: Int) {
    self.outcome = outcome
    self.count = count
  }

  init(from decoder: Decoder) throws {
    let container = try MatchesStrictCoding.container(from: decoder)
    outcome = try container.decode(
      RecordingRehearsalPreviewOutcome.self,
      forKey: MatchesStrictCoding.key("outcome")
    )
    count = try container.decode(Int.self, forKey: MatchesStrictCoding.key("count"))
  }

  static func validate(_ value: RecordingRehearsalPreviewResult) throws {
    let expectedCount = value.outcome == .eligible ? 1 : 0
    guard value.count == expectedCount else {
      throw MatchesDTOValidationError.invalidValue
    }
  }
}

struct RecordingRehearsalStartResult: Decodable, Equatable, Sendable, APIValidatable {
  let outcome: RecordingRehearsalStartOutcome
  let count: Int

  init(outcome: RecordingRehearsalStartOutcome, count: Int) {
    self.outcome = outcome
    self.count = count
  }

  init(from decoder: Decoder) throws {
    let container = try MatchesStrictCoding.container(from: decoder)
    outcome = try container.decode(
      RecordingRehearsalStartOutcome.self,
      forKey: MatchesStrictCoding.key("outcome")
    )
    count = try container.decode(Int.self, forKey: MatchesStrictCoding.key("count"))
  }

  static func validate(_ value: RecordingRehearsalStartResult) throws {
    let expectedCount: Int
    switch value.outcome {
    case .started, .startedPartial:
      expectedCount = 1
    case .notEligible, .alreadyExists, .expired:
      expectedCount = 0
    }
    guard value.count == expectedCount else {
      throw MatchesDTOValidationError.invalidValue
    }
  }
}

enum DemoJudgeStartOutcome: String, Decodable, Equatable, Sendable {
  case started
  case startedPartial = "started_partial"
}

struct DemoJudgePreviewResult: Decodable, Equatable, Sendable, APIValidatable {
  let source: String
  let outcome: String
  let count: Int

  static func validate(_ value: Self) throws {
    guard value.source == "ordinary-discovery", value.outcome == "eligible", (0...10).contains(value.count) else {
      throw MatchesDTOValidationError.invalidValue
    }
  }
}

struct DemoJudgeStartResult: Decodable, Equatable, Sendable, APIValidatable {
  let source: String
  let outcome: DemoJudgeStartOutcome
  let count: Int

  static func validate(_ value: Self) throws {
    guard value.source == "ordinary-discovery", (0...10).contains(value.count) else {
      throw MatchesDTOValidationError.invalidValue
    }
  }
}

/// Persisted ordinary-discovery matches; no daily batch or conversation history is invented.
struct DiscoveryMatchesPayload: Decodable, Equatable, Sendable, APIValidatable {
  let source: String
  let matches: [ProductionMatch]
  let totalMatches: Int

  enum CodingKeys: String, CodingKey {
    case source, matches
    case totalMatches = "total_matches"
  }

  static func validate(_ value: Self) throws {
    guard value.source == "ordinary-discovery", value.totalMatches == value.matches.count,
      value.matches.count <= 20 else { throw MatchesDTOValidationError.invalidValue }
    var ids = Set<UUID>()
    var partners = Set<UUID>()
    for match in value.matches {
      guard ids.insert(match.id).inserted, partners.insert(match.partnerID).inserted else {
        throw MatchesDTOValidationError.invalidValue
      }
      try ProductionMatch.validate(match)
    }
  }
}

/// Development-only build binding survives a Home-icon launch. It grants no server authorization.
enum RecordingRehearsalMatchingConfiguration {
  static let infoKey = "WINGWARD_RECORDING_REHEARSAL_MATCHING"

  static func enabled(info: [String: Any], arguments: [String], allowDevelopmentMode: Bool) throws -> Bool {
    let configured: Bool
    if let raw = info[infoKey] {
      guard let text = raw as? String, text == "YES" || text == "NO" else {
        throw APIClientError.invalidState
      }
      configured = text == "YES"
    } else {
      configured = false
    }
    guard allowDevelopmentMode || !configured else { throw APIClientError.invalidState }
    return allowDevelopmentMode && (configured || arguments.contains("--wingward-recording-matching"))
  }
}

/// Non-secret build binding. Absent means ordinary mode; invalid or conflicting settings close the factory.
enum DemoJudgeMatchingConfiguration {
  static let infoKey = "WINGWARD_DEMO_JUDGE_MATCHING"
  static func enabled(info: [String: Any], arguments: [String], allowLaunchArgument: Bool) throws -> Bool {
    let configured: Bool
    if let raw = info[infoKey] {
      guard let text = raw as? String, text == "YES" || text == "NO" else {
        throw APIClientError.invalidState
      }
      configured = text == "YES"
    } else {
      configured = false
    }
    let requested = configured || (allowLaunchArgument && arguments.contains("--wingward-demo-judge-matching"))
    let recordingConfigured = info[RecordingRehearsalMatchingConfiguration.infoKey] as? String == "YES"
    guard !(requested && (recordingConfigured || arguments.contains("--wingward-recording-matching"))) else {
      throw APIClientError.invalidState
    }
    return requested
  }
}

private enum MatchesStrictCoding {
  static func container(from decoder: Decoder) throws
    -> KeyedDecodingContainer<MatchesDynamicCodingKey>
  {
    let container = try decoder.container(keyedBy: MatchesDynamicCodingKey.self)
    let keys = Set(container.allKeys.map(\.stringValue))
    guard keys == ["outcome", "count"] else {
      throw MatchesDTOValidationError.invalidValue
    }
    return container
  }

  static func key(_ value: String) -> MatchesDynamicCodingKey {
    MatchesDynamicCodingKey(stringValue: value)!
  }
}

private struct MatchesDynamicCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}

/// The statuses are intentionally kept as server strings. A new server status
/// must not make the client unable to show the rest of an otherwise valid list.
/// The view maps only the statuses it understands to copy.
struct ProductionMatch: Decodable, Equatable, Identifiable, Sendable {
  let id: UUID
  let partnerID: UUID
  let partner: Partner
  let status: String
  let foxConversationID: UUID?

  struct Partner: Decodable, Equatable, Sendable {
    let nickname: String?
    let avatarURL: URL?
    let personaIconURL: URL?

    enum CodingKeys: String, CodingKey {
      case nickname
      case avatarURL = "avatar_url"
      case personaIconURL = "persona_icon_url"
    }

    var displayName: String {
      let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return trimmed.isEmpty ? "Wingward member" : trimmed
    }
  }

  enum CodingKeys: String, CodingKey {
    case id
    case partnerID = "partner_id"
    case partner
    case status
    case foxConversationID = "fox_conversation_id"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawID = try container.decode(String.self, forKey: .id)
    let rawPartnerID = try container.decode(String.self, forKey: .partnerID)
    id = try APIDTOValidation.requireUUID(rawID)
    partnerID = try APIDTOValidation.requireUUID(rawPartnerID)
    partner = try container.decode(Partner.self, forKey: .partner)
    status = try container.decode(String.self, forKey: .status)
    if let rawFoxConversationID = try container.decodeIfPresent(String.self, forKey: .foxConversationID) {
      foxConversationID = try APIDTOValidation.requireUUID(rawFoxConversationID)
    } else {
      foxConversationID = nil
    }
  }

  static func validate(_ value: ProductionMatch) throws {
    if let nickname = value.partner.nickname {
      guard nickname.count <= 120 else {
        throw MatchesDTOValidationError.invalidValue
      }
    }
    try validateURL(value.partner.avatarURL)
    try validateURL(value.partner.personaIconURL)
    guard !value.status.isEmpty, value.status.count <= 80 else {
      throw MatchesDTOValidationError.invalidValue
    }
  }

  private static func validateURL(_ value: URL?) throws {
    guard let value else { return }
    guard value.scheme?.lowercased() == "https",
      value.host != nil,
      value.user == nil,
      value.password == nil,
      value.fragment == nil
    else {
      throw MatchesDTOValidationError.invalidURL
    }
  }
}

struct DailyMatchesPayload: Decodable, Equatable, Sendable, APIValidatable {
  var simulatedCounterpart: Bool? = nil
  let batchDate: String
  let batchStatus: String
  let matches: [ProductionMatch]
  let isNew: Bool
  let conversationsCompleted: Int
  let conversationsFailed: Int
  let totalMatches: Int

  enum CodingKeys: String, CodingKey {
    case simulatedCounterpart = "simulated_counterpart"
    case batchDate = "batch_date"
    case batchStatus = "batch_status"
    case matches
    case isNew = "is_new"
    case conversationsCompleted = "conversations_completed"
    case conversationsFailed = "conversations_failed"
    case totalMatches = "total_matches"
  }

  static func validate(_ value: DailyMatchesPayload) throws {
    try validateBatchDate(value.batchDate)
    guard !value.batchStatus.isEmpty, value.batchStatus.count <= 40 else {
      throw MatchesDTOValidationError.invalidValue
    }
    guard value.conversationsCompleted >= 0,
      value.conversationsFailed >= 0,
      value.totalMatches >= 0,
      value.totalMatches == value.matches.count,
      value.conversationsCompleted <= value.totalMatches,
      value.conversationsFailed <= value.totalMatches,
      value.conversationsCompleted <= value.totalMatches - value.conversationsFailed
    else {
      throw MatchesDTOValidationError.invalidValue
    }
    var matchIDs = Set<UUID>()
    var partnerIDs = Set<UUID>()
    for match in value.matches {
      guard matchIDs.insert(match.id).inserted,
        partnerIDs.insert(match.partnerID).inserted
      else {
        throw MatchesDTOValidationError.invalidValue
      }
      try ProductionMatch.validate(match)
    }
  }

  private static func validateBatchDate(_ value: String) throws {
    let bytes = Array(value.utf8)
    guard bytes.count == 10,
      bytes[4] == 45,
      bytes[7] == 45,
      bytes.enumerated().allSatisfy({ index, byte in
        index == 4 || index == 7 || (byte >= 48 && byte <= 57)
      })
    else {
      throw MatchesDTOValidationError.invalidDate
    }

    let year = Int(String(value.prefix(4))) ?? 0
    let month = Int(value.dropFirst(5).prefix(2)) ?? 0
    let day = Int(value.dropFirst(8).prefix(2)) ?? 0
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = year
    components.month = month
    components.day = day
    guard year >= 2000, let date = calendar.date(from: components) else {
      throw MatchesDTOValidationError.invalidDate
    }
    let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
    guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
      throw MatchesDTOValidationError.invalidDate
    }
  }
}
