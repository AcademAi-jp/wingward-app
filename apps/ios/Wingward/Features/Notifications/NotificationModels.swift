import Foundation

/// The server seeded scenarios are deliberately closed.  A push payload may
/// carry only one of these values; unknown scenarios are ignored before any
/// route or event is created.
enum WingwardNotificationScenario: String, CaseIterable, Codable, Equatable, Sendable {
  case n01 = "N-01"
  case n02 = "N-02"
  case n03 = "N-03"
  case n04 = "N-04"
  case n05 = "N-05"
  case n06 = "N-06"
  case n07 = "N-07"
  case n08 = "N-08"
  case n09 = "N-09"
  case n10 = "N-10"
  case n11 = "N-11"
  case n12 = "N-12"
  case n13 = "N-13"
}

enum WingwardNotificationEventType: String, Codable, Equatable, Sendable {
  case delivered
  case opened
  case screenViewed = "screen_viewed"
  case actionCompleted = "action_completed"
  case dismissed
}

enum WingwardNotificationAuthorization: Equatable, Sendable {
  case notDetermined
  case denied
  case authorized
  case provisional
  case ephemeral
  case unknown

  var canDeliverPush: Bool {
    switch self {
    case .authorized, .provisional, .ephemeral:
      return true
    case .notDetermined, .denied, .unknown:
      return false
    }
  }
}

/// Screen names are a closed client vocabulary.  They are sent as analytics
/// metadata only and never contain a nickname, message, or arbitrary URL.
enum WingwardNotificationScreen: String, Codable, Equatable, Sendable {
  case matches
  case matchDetail = "match_detail"
  case foxConversationResult = "fox_conversation_result"
  case partnerFoxChat = "partner_fox_chat"
  case directChat = "direct_chat"
  case chatRequests = "chat_requests"
  case meetup
  case meetupVerification = "meetup_verification"
  case meetupFeedback = "meetup_feedback"
  case meetupResult = "meetup_result"
  case foxLearned = "fox_learned"
  case availability
  case notifications
}

/// The exact body accepted by `POST /api/notification-events`.
///
/// The custom encoder keeps the server's snake_case contract and RFC3339 UTC
/// timestamp without allowing Foundation's default date strategy to drift.
struct WingwardNotificationEvent: Encodable, Equatable, Sendable {
  let notificationID: UUID
  let eventType: WingwardNotificationEventType
  let screen: WingwardNotificationScreen?
  let occurredAt: Date?
  let metadata: [String: String]?

  init(
    notificationID: UUID,
    eventType: WingwardNotificationEventType,
    screen: WingwardNotificationScreen? = nil,
    occurredAt: Date? = nil,
    metadata: [String: String]? = nil
  ) {
    self.notificationID = notificationID
    self.eventType = eventType
    self.screen = screen
    self.occurredAt = occurredAt
    self.metadata = metadata
  }

  enum CodingKeys: String, CodingKey {
    case notificationID = "notification_id"
    case eventType = "event_type"
    case screen
    case occurredAt = "occurred_at"
    case metadata
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(notificationID.uuidString.lowercased(), forKey: .notificationID)
    try container.encode(eventType.rawValue, forKey: .eventType)
    try container.encodeIfPresent(screen?.rawValue, forKey: .screen)
    if let occurredAt {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      try container.encode(formatter.string(from: occurredAt), forKey: .occurredAt)
    }
    try container.encodeIfPresent(metadata, forKey: .metadata)
  }

  /// Keeps client-created payloads inside the bounds enforced by the API.
  /// Callers receive a typed client error instead of sending an oversized
  /// analytics body that the server must reject.
  func validate() throws {
    if let screen, screen.rawValue.count > 200 {
      throw APIClientError.invalidRequest
    }
    if let metadata {
      guard metadata.count <= 20 else { throw APIClientError.invalidRequest }
      guard metadata.allSatisfy({ $0.key.count <= 100 && $0.value.count <= 500 }) else {
        throw APIClientError.invalidRequest
      }
      let encoded = try JSONEncoder().encode(metadata)
      guard encoded.count <= 4_000 else { throw APIClientError.invalidRequest }
    }
  }
}

/// The acknowledgement returned by the notification-event route.
struct WingwardNotificationEventAcknowledgement: Decodable, Equatable, Sendable, APIValidatable {
  let id: UUID

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawValue = try container.decode(String.self, forKey: .id)
    id = try APIDTOValidation.requireUUID(rawValue)
  }

  private enum CodingKeys: String, CodingKey {
    case id
  }

  static func validate(_ value: WingwardNotificationEventAcknowledgement) throws {
    _ = value.id
  }
}

/// The existing profile contract exposes the server-side notification seen
/// clock.  This acknowledgement is kept separate from event analytics so a
/// local denied-permission badge can be reconciled with the authenticated
/// owner's server state without adding profile fields to the shared auth
/// models.
struct WingwardNotificationSeenAcknowledgement: Decodable, Equatable, Sendable, APIValidatable {
  let ownerID: UUID
  let notificationSeenAt: Date

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawOwnerID = try container.decode(String.self, forKey: .ownerID)
    let rawTimestamp = try container.decode(String.self, forKey: .notificationSeenAt)
    ownerID = try APIDTOValidation.requireUUID(rawOwnerID)
    notificationSeenAt = try APIDTOValidation.requireRFC3339(rawTimestamp)
  }

  private enum CodingKeys: String, CodingKey {
    case ownerID = "id"
    case notificationSeenAt = "notification_seen_at"
  }

  static func validate(_ value: WingwardNotificationSeenAcknowledgement) throws {
    _ = value.ownerID
    _ = value.notificationSeenAt
  }
}

/// A provider-neutral projection of an APNs/OneSignal `data` payload.
/// Provider adapters may wrap `data`, but the values consumed here stay
/// exactly `scenario_id`, `notification_id`, and `deep_link`.
struct WingwardNotificationPayload: Equatable, Sendable {
  let notificationID: UUID
  let scenario: WingwardNotificationScenario
  let deepLink: String?
  let route: AppRoute?

  init(
    notificationID: UUID,
    scenario: WingwardNotificationScenario,
    deepLink: String? = nil
  ) {
    self.notificationID = notificationID
    self.scenario = scenario
    self.deepLink = deepLink
    self.route = deepLink.flatMap(AppDeepLinkParser.parse)
  }

  /// The payload is intentionally fail-closed.  A malformed deep link never
  /// becomes a SwiftUI destination; it falls back to the internal notification
  /// landing route only when the deep link is absent.
  init?(userInfo: [AnyHashable: Any]) {
    guard let data = Self.dataDictionary(from: userInfo),
      let rawNotificationID = data[AnyHashable("notification_id")] as? String,
      let notificationID = try? APIDTOValidation.requireUUID(rawNotificationID),
      let rawScenario = data[AnyHashable("scenario_id")] as? String,
      let scenario = WingwardNotificationScenario(rawValue: rawScenario)
    else {
      return nil
    }

    let rawDeepLink = data[AnyHashable("deep_link")] as? String
    if let rawDeepLink, !rawDeepLink.isEmpty, AppDeepLinkParser.parse(rawDeepLink) == nil {
      return nil
    }
    self.init(
      notificationID: notificationID,
      scenario: scenario,
      deepLink: rawDeepLink?.isEmpty == true ? nil : rawDeepLink
    )
  }

  var destinationRoute: AppRoute {
    route ?? .notificationLanding(notificationID)
  }

  private static func dataDictionary(from userInfo: [AnyHashable: Any]) -> [AnyHashable: Any]? {
    if let data = dictionary(userInfo[AnyHashable("data")]) {
      return data
    }

    // OneSignal may wrap custom data as `custom.a.data`.  This is the only
    // provider-specific unwrap kept here; the consumed fields remain the same
    // provider-neutral contract and unknown fields are discarded.
    guard let custom = dictionary(userInfo[AnyHashable("custom")]),
      let appData = dictionary(custom[AnyHashable("a")])
    else {
      return nil
    }
    return dictionary(appData[AnyHashable("data")])
  }

  private static func dictionary(_ value: Any?) -> [AnyHashable: Any]? {
    if let dictionary = value as? [AnyHashable: Any] {
      return dictionary
    }
    if let dictionary = value as? [String: Any] {
      return Dictionary(uniqueKeysWithValues: dictionary.map { (AnyHashable($0.key), $0.value) })
    }
    return nil
  }
}

struct WingwardNotificationEventKey: Hashable, Sendable {
  let notificationID: UUID
  let eventType: WingwardNotificationEventType
  let screen: WingwardNotificationScreen?
}
