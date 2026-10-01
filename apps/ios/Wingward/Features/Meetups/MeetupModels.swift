import Foundation

enum MeetupDTOValidationError: Error, Equatable, Sendable {
  case invalidIdentifier
  case invalidTimestamp
  case invalidTimezone
  case invalidStatus
  case invalidFormat
  case invalidArea
  case invalidRationale
  case invalidValue
  case invalidStateShape
}

enum MeetupTimestamp {
  private static let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#

  static func decode(_ rawValue: String) throws -> Date {
    guard rawValue.range(of: pattern, options: .regularExpression) != nil else {
      throw MeetupDTOValidationError.invalidTimestamp
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: rawValue), date.timeIntervalSince1970.isFinite {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: rawValue), date.timeIntervalSince1970.isFinite else {
      throw MeetupDTOValidationError.invalidTimestamp
    }
    return date
  }

  static func encode(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

enum MeetupDateFormatting {
  /// Formats an instant in the meetup's validated IANA timezone. Returning
  /// nil for an invalid identifier is intentional: a device-local fallback
  /// could show a user the wrong meeting time.
  static func dateText(for date: Date, timezone: String) -> String? {
    guard let timeZone = TimeZone(identifier: timezone) else { return nil }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
  }
}

enum MeetupStatus: String, Codable, CaseIterable, Equatable, Sendable {
  case intentPending = "intent_pending"
  case verifying
  case arranging
  case proposed
  case confirmed
  case arrangeFailed = "arrange_failed"
  case expired
  case cancelled

  var isTerminal: Bool {
    switch self {
    case .confirmed, .expired, .cancelled:
      return true
    case .intentPending, .verifying, .arranging, .proposed, .arrangeFailed:
      return false
    }
  }
}

enum MeetupFormat: String, Codable, CaseIterable, Equatable, Sendable {
  case cafe
  case meal
  case activity
  case online

  var displayName: String {
    switch self {
    case .cafe: return "Café"
    case .meal: return "Meal"
    case .activity: return "Activity"
    case .online: return "Online"
    }
  }
}

enum MeetupBudgetBand: String, Codable, CaseIterable, Equatable, Sendable {
  case low
  case medium
  case high
}

enum MeetupVerificationStatus: String, Codable, CaseIterable, Equatable, Sendable {
  case none
  case pending
  case verified
  case failed
  case expired
}

enum MeetupVerificationGateState: Equatable, Sendable {
  case required
  case pending
  case failed
  case expired

  var title: String {
    switch self {
    case .required: return "Identity verification required"
    case .pending: return "Verification is in progress"
    case .failed: return "Verification needs attention"
    case .expired: return "Verification has expired"
    }
  }

  var message: String {
    switch self {
    case .required:
      return "Both people must be verified before Wingward can arrange a meetup."
    case .pending:
      return "Scheduling will become available after Wingward confirms verification."
    case .failed:
      return "Scheduling stays paused until verification is completed successfully."
    case .expired:
      return "Please complete verification again before arranging a meetup."
    }
  }
}

struct MeetupAvailability: Equatable, Sendable, Codable {
  let startsAt: Date
  let endsAt: Date

  init(startsAt: Date, endsAt: Date) {
    self.startsAt = startsAt
    self.endsAt = endsAt
  }

  enum CodingKeys: String, CodingKey {
    case startsAt = "starts_at"
    case endsAt = "ends_at"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    startsAt = try MeetupTimestamp.decode(try container.decode(String.self, forKey: .startsAt))
    endsAt = try MeetupTimestamp.decode(try container.decode(String.self, forKey: .endsAt))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(MeetupTimestamp.encode(startsAt), forKey: .startsAt)
    try container.encode(MeetupTimestamp.encode(endsAt), forKey: .endsAt)
  }
}

/// The preference request is deliberately narrower than the backend's JSON
/// column. Free-form text is not accepted here, which prevents names, chat
/// excerpts, and precise addresses from becoming scheduling input.
struct MeetupPreferences: Equatable, Sendable, Codable {
  var availability: [MeetupAvailability]
  var areas: [String]
  var budgetBand: MeetupBudgetBand
  var formats: [MeetupFormat]
  var constraints: [String: String]

  static let empty = MeetupPreferences(
    availability: [],
    areas: [],
    budgetBand: .medium,
    formats: [],
    constraints: [:]
  )

  init(
    availability: [MeetupAvailability],
    areas: [String],
    budgetBand: MeetupBudgetBand,
    formats: [MeetupFormat],
    constraints: [String: String] = [:]
  ) {
    self.availability = availability
    self.areas = areas
    self.budgetBand = budgetBand
    self.formats = formats
    self.constraints = constraints
  }

  enum CodingKeys: String, CodingKey {
    case availability
    case areas
    case budgetBand = "budget_band"
    case formats
    case constraints
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    availability = try container.decode([MeetupAvailability].self, forKey: .availability)
    areas = try container.decode([String].self, forKey: .areas)
    budgetBand = try container.decode(MeetupBudgetBand.self, forKey: .budgetBand)
    formats = try container.decode([MeetupFormat].self, forKey: .formats)
    constraints = try container.decode([String: String].self, forKey: .constraints)
  }

  func encode(to encoder: Encoder) throws {
    try validate()
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(availability, forKey: .availability)
    try container.encode(areas, forKey: .areas)
    try container.encode(budgetBand, forKey: .budgetBand)
    try container.encode(formats, forKey: .formats)
    try container.encode(constraints, forKey: .constraints)
  }

  func validate() throws {
    guard availability.count <= 32 else { throw MeetupDTOValidationError.invalidValue }
    var availabilityKeys = Set<String>()
    for interval in availability {
      guard interval.startsAt.timeIntervalSince1970.isFinite,
        interval.endsAt.timeIntervalSince1970.isFinite,
        interval.startsAt < interval.endsAt
      else {
        throw MeetupDTOValidationError.invalidTimestamp
      }
      let key = "\(MeetupTimestamp.encode(interval.startsAt))\u{0}\(MeetupTimestamp.encode(interval.endsAt))"
      guard availabilityKeys.insert(key).inserted else {
        throw MeetupDTOValidationError.invalidValue
      }
    }

    guard areas.count <= 8 else { throw MeetupDTOValidationError.invalidArea }
    var areaValues = Set<String>()
    for area in areas {
      guard Self.isSafeText(area, maxLength: 160), area == area.trimmingCharacters(in: .whitespacesAndNewlines),
        areaValues.insert(area).inserted
      else {
        throw MeetupDTOValidationError.invalidArea
      }
    }

    guard formats.count <= 4 else { throw MeetupDTOValidationError.invalidFormat }
    var formatValues = Set<MeetupFormat>()
    for format in formats {
      guard formatValues.insert(format).inserted else { throw MeetupDTOValidationError.invalidFormat }
    }

    guard constraints.count <= 16 else { throw MeetupDTOValidationError.invalidValue }
    for (key, value) in constraints {
      guard Self.isSafeText(key, maxLength: 64), Self.isSafeText(value, maxLength: 256),
        key == key.trimmingCharacters(in: .whitespacesAndNewlines)
      else {
        throw MeetupDTOValidationError.invalidValue
      }
    }
    guard let encoded = try? JSONEncoder().encode(constraints), encoded.count <= 2_000 else {
      throw MeetupDTOValidationError.invalidValue
    }
  }

  private static func isSafeText(_ value: String, maxLength: Int) -> Bool {
    guard !value.isEmpty, value.count <= maxLength else { return false }
    return !value.unicodeScalars.contains { scalar in
      scalar.value == 0 || scalar.value < 0x20 || scalar.value == 0x7F
        || scalar.value == 0x2028 || scalar.value == 0x2029
    }
  }
}

enum MeetupPreferenceDefaults {
  static func start(now: Date = Date()) -> Date {
    Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
  }

  static func end(now: Date = Date()) -> Date {
    let start = start(now: now)
    return Calendar.current.date(byAdding: .hour, value: 2, to: start) ?? start
  }
}

struct MeetupCandidate: Equatable, Identifiable, Sendable {
  let id: String
  let startsAt: Date
  let timezone: String
  let area: String
  let format: MeetupFormat
  let rationale: String?

  init(
    startsAt: Date,
    timezone: String,
    area: String,
    format: MeetupFormat,
    rationale: String? = nil
  ) {
    self.id = "\(MeetupTimestamp.encode(startsAt))|\(timezone)|\(area)|\(format.rawValue)"
    self.startsAt = startsAt
    self.timezone = timezone
    self.area = area
    self.format = format
    self.rationale = rationale
  }

  enum CodingKeys: String, CodingKey {
    case startsAt = "starts_at"
    case timezone
    case area
    case format
    case rationale
  }
}

extension MeetupCandidate: Decodable {
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let startsAt = try MeetupTimestamp.decode(try container.decode(String.self, forKey: .startsAt))
    let timezone = try container.decode(String.self, forKey: .timezone)
    let area = try container.decode(String.self, forKey: .area)
    let format = try container.decode(MeetupFormat.self, forKey: .format)
    let rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
    self.init(startsAt: startsAt, timezone: timezone, area: area, format: format, rationale: rationale)
  }
}

struct MeetupProposal: Equatable, Sendable {
  let id: UUID
  let candidates: [MeetupCandidate]
  let expiresAt: Date?

  init(id: UUID, candidates: [MeetupCandidate], expiresAt: Date?) {
    self.id = id
    self.candidates = candidates
    self.expiresAt = expiresAt
  }
}

struct MeetupConfirmedCandidate: Equatable, Sendable {
  let startsAt: Date
  let timezone: String
  let area: String
  let format: MeetupFormat
}

struct MeetupDetail: Equatable, Identifiable, Sendable, APIValidatable {
  let id: UUID
  let matchID: UUID
  let status: MeetupStatus
  let proposal: MeetupProposal?
  let confirmedCandidate: MeetupConfirmedCandidate?
  let expiresAt: Date?

  init(
    id: UUID,
    matchID: UUID,
    status: MeetupStatus,
    proposal: MeetupProposal? = nil,
    confirmedCandidate: MeetupConfirmedCandidate? = nil,
    expiresAt: Date? = nil
  ) {
    self.id = id
    self.matchID = matchID
    self.status = status
    self.proposal = proposal
    self.confirmedCandidate = confirmedCandidate
    self.expiresAt = expiresAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case matchID = "match_id"
    case status
    case proposal
    case confirmedCandidate = "confirmed_candidate"
    case expiresAt = "expires_at"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .id))
    matchID = try APIDTOValidation.requireUUID(try container.decode(String.self, forKey: .matchID))
    guard let status = MeetupStatus(rawValue: try container.decode(String.self, forKey: .status)) else {
      throw MeetupDTOValidationError.invalidStatus
    }
    self.status = status
    proposal = try Self.decodeProposal(container.decodeIfPresent(RawMeetupProposal.self, forKey: .proposal))
    confirmedCandidate = try Self.decodeConfirmedCandidate(
      container.decodeIfPresent(RawConfirmedCandidate.self, forKey: .confirmedCandidate)
    )
    if let rawExpiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt) {
      expiresAt = try MeetupTimestamp.decode(rawExpiresAt)
    } else {
      expiresAt = nil
    }
  }

  static func validate(_ value: MeetupDetail) throws {
    guard value.id != value.matchID else { throw MeetupDTOValidationError.invalidIdentifier }
    if let expiresAt = value.expiresAt, !expiresAt.timeIntervalSince1970.isFinite {
      throw MeetupDTOValidationError.invalidTimestamp
    }

    switch value.status {
    case .proposed:
      guard let proposal = value.proposal else { throw MeetupDTOValidationError.invalidStateShape }
      try validate(proposal)
      guard value.confirmedCandidate == nil else { throw MeetupDTOValidationError.invalidStateShape }
    case .confirmed:
      guard value.proposal == nil, let candidate = value.confirmedCandidate else {
        throw MeetupDTOValidationError.invalidStateShape
      }
      try validate(candidate)
    case .intentPending, .verifying, .arranging, .arrangeFailed, .expired, .cancelled:
      guard value.proposal == nil, value.confirmedCandidate == nil else {
        throw MeetupDTOValidationError.invalidStateShape
      }
    }
  }

  private static func validate(_ proposal: MeetupProposal) throws {
    guard proposal.candidates.count == 3 else { throw MeetupDTOValidationError.invalidStateShape }
    var candidateKeys = Set<String>()
    for candidate in proposal.candidates {
      try validate(candidate, requiresRationale: true)
      guard candidateKeys.insert(candidate.id).inserted else {
        throw MeetupDTOValidationError.invalidValue
      }
    }
    if let expiresAt = proposal.expiresAt, !expiresAt.timeIntervalSince1970.isFinite {
      throw MeetupDTOValidationError.invalidTimestamp
    }
  }

  private static func validate(_ candidate: MeetupCandidate, requiresRationale: Bool) throws {
    guard candidate.startsAt.timeIntervalSince1970.isFinite else {
      throw MeetupDTOValidationError.invalidTimestamp
    }
    guard TimeZone(identifier: candidate.timezone) != nil else {
      throw MeetupDTOValidationError.invalidTimezone
    }
    guard isCityWardArea(candidate.area) else { throw MeetupDTOValidationError.invalidArea }
    if requiresRationale {
      guard let rationale = candidate.rationale,
        !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        rationale.count <= 500,
        isSafeText(rationale)
      else {
        throw MeetupDTOValidationError.invalidRationale
      }
    }
  }

  private static func validate(_ candidate: MeetupConfirmedCandidate) throws {
    guard candidate.startsAt.timeIntervalSince1970.isFinite,
      TimeZone(identifier: candidate.timezone) != nil,
      isCityWardArea(candidate.area)
    else {
      throw MeetupDTOValidationError.invalidValue
    }
  }

  private static func isCityWardArea(_ value: String) -> Bool {
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      value.count <= 160,
      isSafeText(value)
    else { return false }
    let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
    guard pieces.count == 2 else { return false }
    return pieces.allSatisfy { piece in
      let value = String(piece)
      return !value.isEmpty && value.count <= 80 && !value.contains(",") && !value.contains(";")
    }
  }

  private static func isSafeText(_ value: String) -> Bool {
    !value.unicodeScalars.contains { scalar in
      scalar.value == 0 || scalar.value < 0x20 || scalar.value == 0x7F
        || scalar.value == 0x2028 || scalar.value == 0x2029
    }
  }

  private static func decodeProposal(
    _ raw: RawMeetupProposal?
  ) throws -> MeetupProposal? {
    guard let raw else { return nil }
    let id = try APIDTOValidation.requireUUID(raw.id)
    let candidates = try raw.candidates.map { candidate in
      MeetupCandidate(
        startsAt: try MeetupTimestamp.decode(candidate.startsAt),
        timezone: candidate.timezone,
        area: candidate.area,
        format: candidate.format,
        rationale: candidate.rationale
      )
    }
    let expiresAt = try raw.expiresAt.map(MeetupTimestamp.decode)
    return MeetupProposal(id: id, candidates: candidates, expiresAt: expiresAt)
  }

  private static func decodeConfirmedCandidate(
    _ raw: RawConfirmedCandidate?
  ) throws -> MeetupConfirmedCandidate? {
    guard let raw else { return nil }
    return MeetupConfirmedCandidate(
      startsAt: try MeetupTimestamp.decode(raw.startsAt),
      timezone: raw.timezone,
      area: raw.area,
      format: raw.format
    )
  }

  private struct RawMeetupProposal: Decodable {
    let id: String
    let candidates: [RawCandidate]
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
      case id
      case candidates
      case expiresAt = "expires_at"
    }
  }

  private struct RawCandidate: Decodable {
    let startsAt: String
    let timezone: String
    let area: String
    let format: MeetupFormat
    let rationale: String?

    enum CodingKeys: String, CodingKey {
      case startsAt = "starts_at"
      case timezone
      case area
      case format
      case rationale
    }
  }

  private struct RawConfirmedCandidate: Decodable {
    let startsAt: String
    let timezone: String
    let area: String
    let format: MeetupFormat

    enum CodingKeys: String, CodingKey {
      case startsAt = "starts_at"
      case timezone
      case area
      case format
    }
  }
}

/// S2 scheduling is a public product surface. S3 check-in and post-meetup
/// features remain disabled unless the integration owner supplies an explicit
/// invitation/build flag; this type intentionally exposes no S3 routes or
/// payloads to a public build.
struct MeetupPilotPolicy: Equatable, Sendable {
  let schedulingEnabled: Bool
  let closedPilotInvitation: Bool
  let s3EnabledForBuild: Bool

  static let publicDefault = MeetupPilotPolicy(
    schedulingEnabled: true,
    closedPilotInvitation: false,
    s3EnabledForBuild: false
  )

  var canSchedule: Bool { schedulingEnabled }
  var canUseClosedPilotSurfaces: Bool {
    s3EnabledForBuild && closedPilotInvitation
  }
}

enum MeetupViewState: Equatable, Sendable {
  case idle
  case loading
  case intentAvailable
  case intentPending
  case verifying(MeetupVerificationGateState)
  case arranging
  case proposed
  case arrangeFailed
  case confirmed
  case expired
  case cancelled
  case failed(MeetupStoreError)
}

enum MeetupStorePhase: Equatable, Sendable {
  case idle
  case loading
  case expressingIntent
  case savingPreferences
  case arranging
  case responding
  case loaded
  case failed(MeetupStoreError)
}

enum MeetupStoreError: Error, Equatable, Sendable {
  case unauthenticated
  case ageVerificationRequired
  case forbidden
  case notFound
  case invalidRequest
  case invalidResponse
  case invalidState
  case identityVerificationRequired
  case quotaExhausted(source: PaywallSource?)
  case rateLimited
  case temporarilyUnavailable
  case cancelled

  var userMessage: String {
    switch self {
    case .identityVerificationRequired:
      return "Both people must complete identity verification before scheduling."
    case .quotaExhausted:
      return "Meetup arrangement is unavailable right now."
    case .ageVerificationRequired:
      return "Verify your age before using meetup scheduling."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .unauthenticated, .forbidden, .notFound, .invalidRequest, .invalidResponse,
      .invalidState, .temporarilyUnavailable, .cancelled:
      return "We couldn't update this meetup. Try again."
    }
  }
}

// Native calendar sharing is a separate, explicit user action. Only interval
// boundaries cross the adapter boundary; event content is never retained.
enum NativeCalendarAuthorization: String, Equatable, Sendable {
  case notRequested
  case granted
  case denied
  case unavailable

  var busyReadError: NativeCalendarPrivacyError? {
    switch self {
    case .notRequested: return .consentRequired
    case .granted: return nil
    case .denied: return .denied
    case .unavailable: return .unavailable
    }
  }
}

enum NativeCalendarPrivacyError: Error, Equatable, Sendable {
  case consentRequired
  case denied
  case unavailable
  case consentRevoked
  case invalidWindow
  case windowExceedsLookahead
  case invalidInterval
  case tooManyIntervals
}

struct NativeBusyCalendarPayload: Equatable, Sendable, Encodable {
  let window: MeetupAvailability
  let busy: [MeetupAvailability]

  init(window: MeetupAvailability, busy: [MeetupAvailability]) {
    self.window = window
    self.busy = busy
  }

  private enum CodingKeys: String, CodingKey {
    case window
    case busy
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(window, forKey: .window)
    try container.encode(busy, forKey: .busy)
  }
}

protocol NativeBusyCalendarProvider: Sendable {
  /// The caller must invoke this only after showing the sharing disclosure and
  /// receiving an affirmative in-app choice.
  func requestAccess(userConfirmedSharing: Bool) async -> NativeCalendarAuthorization
  func readBusy(window: MeetupAvailability) async throws -> NativeBusyCalendarPayload
  /// Revokes local sharing consent immediately. The OS permission itself is
  /// managed by Settings and cannot be revoked by an app.
  func revoke()
}

struct UnavailableNativeBusyCalendarProvider: NativeBusyCalendarProvider {
  func requestAccess(userConfirmedSharing: Bool) async -> NativeCalendarAuthorization {
    userConfirmedSharing ? .unavailable : .notRequested
  }

  func readBusy(window: MeetupAvailability) async throws -> NativeBusyCalendarPayload {
    throw NativeCalendarPrivacyError.unavailable
  }

  func revoke() {}
}

/// Validates a future-only, bounded calendar request and projects event-like
/// values through a closure that can expose only their date boundaries.
struct NativeBusyCalendarProjection {
  static let maximumIntervalCount = 128
  static let maximumLookahead: TimeInterval = 21 * 24 * 60 * 60

  let window: MeetupAvailability
  private var intervals: [MeetupAvailability] = []

  init(window: MeetupAvailability, now: Date = Date()) throws {
    guard now.timeIntervalSince1970.isFinite,
      window.startsAt.timeIntervalSince1970.isFinite,
      window.endsAt.timeIntervalSince1970.isFinite,
      window.startsAt < window.endsAt
    else {
      throw NativeCalendarPrivacyError.invalidWindow
    }
    guard window.startsAt >= now else {
      throw NativeCalendarPrivacyError.invalidWindow
    }
    guard window.endsAt <= now.addingTimeInterval(Self.maximumLookahead) else {
      throw NativeCalendarPrivacyError.windowExceedsLookahead
    }
    self.window = window
  }

  mutating func append<Event>(
    _ event: Event,
    dateInterval: (Event) -> (Date, Date)
  ) throws {
    guard !Task.isCancelled else { throw CancellationError() }

    let (eventStart, eventEnd) = dateInterval(event)
    guard eventStart.timeIntervalSince1970.isFinite,
      eventEnd.timeIntervalSince1970.isFinite,
      eventStart < eventEnd
    else {
      throw NativeCalendarPrivacyError.invalidInterval
    }

    let clippedStart = max(eventStart, window.startsAt)
    let clippedEnd = min(eventEnd, window.endsAt)
    guard clippedStart < clippedEnd else { return }
    guard intervals.count < Self.maximumIntervalCount else {
      throw NativeCalendarPrivacyError.tooManyIntervals
    }

    intervals.append(MeetupAvailability(startsAt: clippedStart, endsAt: clippedEnd))
  }

  mutating func append(start: Date?, end: Date?) throws {
    guard let start, let end else {
      throw NativeCalendarPrivacyError.invalidInterval
    }
    try append((start, end)) { $0 }
  }

  static func shouldIncludeEvent(isFree: Bool, isCancelled: Bool) -> Bool {
    !isFree && !isCancelled
  }

  func payload() -> NativeBusyCalendarPayload {
    let ordered = intervals.sorted {
      if $0.startsAt == $1.startsAt { return $0.endsAt < $1.endsAt }
      return $0.startsAt < $1.startsAt
    }
    var merged: [MeetupAvailability] = []
    for interval in ordered {
      if let last = merged.last, interval.startsAt <= last.endsAt {
        merged[merged.count - 1] = MeetupAvailability(
          startsAt: last.startsAt,
          endsAt: max(last.endsAt, interval.endsAt)
        )
      } else {
        merged.append(interval)
      }
    }
    return NativeBusyCalendarPayload(window: window, busy: merged)
  }
}

enum NativeLocationPrivacyError: Error, Equatable, Sendable {
  case consentRequired
  case unavailable
  case invalidLocation
  case invalidTTL
  case stale
}

/// In-memory consent data. It intentionally is not Codable; callers must
/// explicitly request the private-request-only projection below.
struct NativeLocationConsentPayload: Equatable, Sendable {
  let station: String?
  let latitude: Double?
  let longitude: Double?
  let nearestStation: String?
  let capturedAt: Date
  let expiresAt: Date

  static let maximumTTL: TimeInterval = 30 * 60
  private static let maximumStationLength = 120

  init(
    station: String?,
    latitude: Double?,
    longitude: Double?,
    nearestStation: String?,
    capturedAt: Date,
    expiresAt: Date
  ) throws {
    let normalizedStation = try Self.validatedStation(station)
    let normalizedNearestStation = try Self.validatedStation(nearestStation)
    let hasLatitude = latitude != nil
    let hasLongitude = longitude != nil
    guard hasLatitude == hasLongitude else {
      throw NativeLocationPrivacyError.invalidLocation
    }
    if let latitude, let longitude {
      guard latitude.isFinite, longitude.isFinite,
        (-90.0...90.0).contains(latitude),
        (-180.0...180.0).contains(longitude)
      else {
        throw NativeLocationPrivacyError.invalidLocation
      }
    }
    guard normalizedStation != nil || hasLatitude else {
      throw NativeLocationPrivacyError.invalidLocation
    }

    let ttl = expiresAt.timeIntervalSince(capturedAt)
    guard capturedAt.timeIntervalSince1970.isFinite,
      expiresAt.timeIntervalSince1970.isFinite,
      ttl > 0,
      ttl <= Self.maximumTTL
    else {
      throw NativeLocationPrivacyError.invalidTTL
    }

    self.station = normalizedStation
    self.latitude = latitude
    self.longitude = longitude
    self.nearestStation = normalizedNearestStation
    self.capturedAt = capturedAt
    self.expiresAt = expiresAt
  }

  func isValid(at now: Date) -> Bool {
    now.timeIntervalSince1970.isFinite &&
      capturedAt.timeIntervalSince1970.isFinite &&
      expiresAt.timeIntervalSince1970.isFinite &&
      capturedAt <= now &&
      expiresAt > now &&
      expiresAt.timeIntervalSince(capturedAt) <= Self.maximumTTL
  }

  func privateRequestFields(asOf now: Date = Date()) throws -> NativeMeetupPrivateRequestLocationFields {
    guard isValid(at: now) else {
      if expiresAt <= now { throw NativeLocationPrivacyError.stale }
      throw NativeLocationPrivacyError.invalidLocation
    }
    return NativeMeetupPrivateRequestLocationFields(
      station: station,
      latitude: latitude,
      longitude: longitude,
      nearestStation: nearestStation,
      expiresAt: expiresAt
    )
  }

  private static func validatedStation(_ value: String?) throws -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
      normalized == value,
      normalized.count <= maximumStationLength,
      !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw NativeLocationPrivacyError.invalidLocation
    }
    return normalized
  }
}

/// This is the only encodable location shape and is named for its private
/// request destination. It is not a peer-chat message type.
struct NativeMeetupPrivateRequestLocationFields: Equatable, Sendable, Encodable {
  let station: String?
  let latitude: Double?
  let longitude: Double?
  let nearestStation: String?
  let expiresAt: Date

  private enum CodingKeys: String, CodingKey {
    case station
    case latitude
    case longitude
    case nearestStation = "nearest_station"
    case expiresAt = "expires_at"
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(station, forKey: .station)
    try container.encodeIfPresent(latitude, forKey: .latitude)
    try container.encodeIfPresent(longitude, forKey: .longitude)
    try container.encodeIfPresent(nearestStation, forKey: .nearestStation)
    try container.encode(MeetupTimestamp.encode(expiresAt), forKey: .expiresAt)
  }
}

protocol NativeMeetupLocationProvider: Sendable {
  /// Consent must come from a visible, affirmative UI action before a location
  /// provider may access a system location service.
  func capture(afterUserConsent: Bool) async throws -> NativeLocationConsentPayload
  func revoke()
}

struct UnavailableNativeMeetupLocationProvider: NativeMeetupLocationProvider {
  func capture(afterUserConsent: Bool) async throws -> NativeLocationConsentPayload {
    guard afterUserConsent else { throw NativeLocationPrivacyError.consentRequired }
    throw NativeLocationPrivacyError.unavailable
  }

  func revoke() {}
}

#if canImport(EventKit)
import EventKit

/// iOS 17 full-access EventKit adapter. The availability flag must stay false
/// unless the app target contains NSCalendarsFullAccessUsageDescription and the
/// app has shown its own calendar-sharing disclosure. EventKit permission does
/// not provide free/busy-only access, so this adapter reads only event dates.
@available(iOS 17.0, macOS 14.0, *)
actor NativeEventKitBusyCalendarProvider: NativeBusyCalendarProvider {
  nonisolated private let consentLease = NativeCalendarConsentLease()
  private let isUsageDescriptionAvailable: Bool
  private let eventStore = EKEventStore()
  private var authorization: NativeCalendarAuthorization = .notRequested

  init(isUsageDescriptionAvailable: Bool = false) {
    self.isUsageDescriptionAvailable = isUsageDescriptionAvailable
  }

  func requestAccess(userConfirmedSharing: Bool) async -> NativeCalendarAuthorization {
    guard userConfirmedSharing else {
      consentLease.revoke()
      authorization = .notRequested
      return .notRequested
    }
    guard isUsageDescriptionAvailable else {
      consentLease.revoke()
      authorization = .unavailable
      return .unavailable
    }

    let generation = consentLease.begin()
    let result: NativeCalendarAuthorization
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess:
      result = .granted
    case .writeOnly, .denied, .restricted:
      result = .denied
    case .notDetermined:
      do {
        result = try await eventStore.requestFullAccessToEvents() ? .granted : .denied
      } catch {
        result = .denied
      }
    @unknown default:
      result = .unavailable
    }

    guard !Task.isCancelled, consentLease.isActive(generation) else {
      consentLease.revoke()
      authorization = .notRequested
      return .notRequested
    }
    if result != .granted {
      consentLease.revoke()
    }
    authorization = result
    return result
  }

  func readBusy(window: MeetupAvailability) async throws -> NativeBusyCalendarPayload {
    guard isUsageDescriptionAvailable else {
      throw NativeCalendarPrivacyError.unavailable
    }
    if let accessError = authorization.busyReadError {
      throw accessError
    }
    guard let generation = consentLease.currentGeneration() else {
      throw NativeCalendarPrivacyError.consentRequired
    }
    try ensureSystemFullAccess()
    guard consentLease.isActive(generation) else {
      throw NativeCalendarPrivacyError.consentRevoked
    }
    guard !Task.isCancelled else { throw CancellationError() }

    var projection = try NativeBusyCalendarProjection(window: window, now: Date())
    let predicate = eventStore.predicateForEvents(
      withStart: window.startsAt,
      end: window.endsAt,
      calendars: nil
    )
    let lease = consentLease
    var enumerationError: Error?
    eventStore.enumerateEvents(matching: predicate) { event, stop in
      if enumerationError != nil {
        stop.pointee = true
        return
      }
      guard !Task.isCancelled else {
        enumerationError = CancellationError()
        stop.pointee = true
        return
      }
      guard lease.isActive(generation) else {
        enumerationError = NativeCalendarPrivacyError.consentRevoked
        stop.pointee = true
        return
      }
      // These EventKit flags contain no event text or participant details.
      guard NativeBusyCalendarProjection.shouldIncludeEvent(
        isFree: event.availability == .free,
        isCancelled: event.status == .canceled
      ) else { return }
      do {
        // Date properties are optional in EventKit; nil fails closed.
        try projection.append(start: event.startDate, end: event.endDate)
      } catch {
        enumerationError = error
        stop.pointee = true
      }
    }

    try ensureSystemFullAccess()
    if let enumerationError { throw enumerationError }
    guard !Task.isCancelled else { throw CancellationError() }
    guard lease.isActive(generation) else {
      throw NativeCalendarPrivacyError.consentRevoked
    }
    return projection.payload()
  }

  private func ensureSystemFullAccess() throws {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
      authorization = .denied
      consentLease.revoke()
      throw NativeCalendarPrivacyError.denied
    }
  }

  nonisolated func revoke() {
    consentLease.revoke()
  }
}

private final class NativeCalendarConsentLease: @unchecked Sendable {
  private let lock = NSLock()
  private var generation = 0
  private var activeGeneration: Int?

  func begin() -> Int {
    lock.lock()
    defer { lock.unlock() }
    generation += 1
    activeGeneration = generation
    return generation
  }

  func currentGeneration() -> Int? {
    lock.lock()
    defer { lock.unlock() }
    return activeGeneration
  }

  func isActive(_ expected: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return activeGeneration == expected
  }

  func revoke() {
    lock.lock()
    defer { lock.unlock() }
    generation += 1
    activeGeneration = nil
  }
}
#endif
