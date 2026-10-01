import Foundation

enum ModerationReason: String, CaseIterable, Codable, Hashable, Sendable {
  case harassment
  case inappropriate
  case spam
  case other

  var userMessage: String {
    switch self {
    case .harassment: return "Harassment"
    case .inappropriate: return "Inappropriate content"
    case .spam: return "Spam"
    case .other: return "Other"
    }
  }
}

struct ModerationReportRequest: Codable, Equatable, Sendable {
  static let maxDescriptionLength = 1_000

  let userID: UUID
  let reason: ModerationReason
  let description: String?
  let messageID: UUID?

  init(
    userID: UUID,
    reason: ModerationReason,
    description: String? = nil,
    messageID: UUID? = nil
  ) throws {
    if let description {
      let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.count <= Self.maxDescriptionLength else {
        throw ModerationValidationError.descriptionTooLong
      }
      self.description = trimmed.isEmpty ? nil : trimmed
    } else {
      self.description = nil
    }
    self.userID = userID
    self.reason = reason
    self.messageID = messageID
  }

  private enum CodingKeys: String, CodingKey {
    case userID = "user_id"
    case reason
    case description
    case messageID = "message_id"
  }
}

struct ModerationReportResponse: APIValidatable, Codable, Equatable, Sendable {
  let reportID: UUID
  let status: String

  private enum CodingKeys: String, CodingKey {
    case reportID = "report_id"
    case status
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let reportID = try APIDTOValidation.requireUUID(
      container.decode(String.self, forKey: .reportID)
    )
    self.reportID = reportID
    self.status = try container.decode(String.self, forKey: .status)
    try Self.validate(self)
  }

  init(reportID: UUID, status: String) {
    self.reportID = reportID
    self.status = status
  }

  static func validate(_ value: ModerationReportResponse) throws {
    try APIDTOValidation.requireNonEmpty(value.status)
    guard value.status == "pending" else { throw ModerationValidationError.invalidReportStatus }
  }
}

struct ModerationBlockResponse: APIValidatable, Codable, Equatable, Sendable {
  let message: String

  static func validate(_ value: ModerationBlockResponse) throws {
    guard value.message == "User blocked" else { throw ModerationValidationError.invalidBlockAcknowledgement }
  }
}

struct ModerationUnblockResponse: APIValidatable, Codable, Equatable, Sendable {
  let message: String

  static func validate(_ value: ModerationUnblockResponse) throws {
    guard value.message == "User unblocked" else {
      throw ModerationValidationError.invalidUnblockAcknowledgement
    }
  }
}

/// `/api/auth/me` returns this acknowledgement only after the server has
/// durably deleted the account.  A false value is valid JSON but is never
/// treated as successful deletion by the coordinator.
struct AccountDeletionResponse: APIValidatable, Codable, Equatable, Sendable {
  let deleted: Bool

  static func validate(_ value: AccountDeletionResponse) throws {}
}

enum ModerationValidationError: Error, Equatable, Sendable {
  case descriptionTooLong
  case invalidReportStatus
  case invalidBlockAcknowledgement
  case invalidUnblockAcknowledgement
}
