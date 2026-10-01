import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor
protocol WingwardNotificationPermissionClient: AnyObject {
  func authorizationStatus() async -> WingwardNotificationAuthorization
  func requestAuthorization() async -> WingwardNotificationAuthorization
  func openSettings()
}

/// The only system permission adapter.  There is deliberately no OneSignal
/// SDK or provider key in the native target; a provider can later feed the
/// same payload/event seams without changing the permission UX.
@MainActor
final class SystemWingwardNotificationPermissionClient: WingwardNotificationPermissionClient {
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  func authorizationStatus() async -> WingwardNotificationAuthorization {
    await withCheckedContinuation { continuation in
      center.getNotificationSettings { settings in
        continuation.resume(returning: Self.map(settings.authorizationStatus))
      }
    }
  }

  func requestAuthorization() async -> WingwardNotificationAuthorization {
    do {
      _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
    } catch {
      // Read the resulting status after a cancellation, simulator denial, or
      // system error.  The UI receives a stable state and never a raw error.
    }
    return await authorizationStatus()
  }

  func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  private static func map(_ status: UNAuthorizationStatus) -> WingwardNotificationAuthorization {
    switch status {
    case .notDetermined: return .notDetermined
    case .denied: return .denied
    case .authorized: return .authorized
    case .provisional: return .provisional
    case .ephemeral: return .ephemeral
    @unknown default: return .unknown
    }
  }
}

@MainActor
protocol WingwardNotificationBadgePersistence {
  func count(ownerID: String) -> Int
  func save(count: Int, ownerID: String)
}

/// Badge state is local fallback state only. It is keyed by the canonical
/// signed-in owner's UUID and contains no notification body, token, or
/// personal text. Keychain keeps the state out of the app's preferences and
/// prevents a stale value from being treated as another owner's badge.
@MainActor
struct WingwardKeychainNotificationBadgePersistence: WingwardNotificationBadgePersistence {
  private static let keyPrefix = "com.wingward.notification.badge."
  private static let service = "com.wingward.notifications"

  let storage: KeychainAuthLocalStorage

  init(storage: KeychainAuthLocalStorage = KeychainAuthLocalStorage(service: Self.service)) {
    self.storage = storage
  }

  func count(ownerID: String) -> Int {
    guard let canonicalOwnerID = Self.canonicalOwnerID(ownerID) else { return 0 }
    guard let data = try? storage.retrieve(key: Self.key(ownerID: canonicalOwnerID)) else {
      return 0
    }
    return max(0, Int(String(decoding: data, as: UTF8.self)) ?? 0)
  }

  func save(count: Int, ownerID: String) {
    guard let canonicalOwnerID = Self.canonicalOwnerID(ownerID) else { return }
    let key = Self.key(ownerID: canonicalOwnerID)
    if count <= 0 {
      try? storage.remove(key: key)
      return
    }
    try? storage.store(key: key, value: Data(String(count).utf8))
  }

  private static func canonicalOwnerID(_ ownerID: String) -> String? {
    guard let uuid = UUID(uuidString: ownerID) else { return nil }
    return uuid.uuidString.lowercased()
  }

  private static func key(ownerID: String) -> String {
    "\(keyPrefix)\(ownerID)"
  }
}

struct WingwardNotificationPendingWork: Equatable, Sendable {
  var events: [WingwardNotificationEvent]
  var pendingTap: WingwardNotificationPayload?

  init(events: [WingwardNotificationEvent] = [], pendingTap: WingwardNotificationPayload? = nil) {
    self.events = events
    self.pendingTap = pendingTap
  }
}

@MainActor
protocol WingwardNotificationQueuePersistence {
  func load(ownerID: String) throws -> WingwardNotificationPendingWork
  func save(_ work: WingwardNotificationPendingWork, ownerID: String) throws
}

@MainActor
protocol WingwardNotificationQueueKeychainStorage {
  func store(key: String, value: Data) throws
  func retrieve(key: String) throws -> Data?
  func remove(key: String) throws
}

extension KeychainAuthLocalStorage: WingwardNotificationQueueKeychainStorage {}

/// Persists only notification IDs, allowlisted routes, and bounded event
/// metadata. Entries are isolated by the authenticated owner's UUID.
@MainActor
struct WingwardKeychainNotificationQueuePersistence: WingwardNotificationQueuePersistence {
  private static let keyPrefix = "com.wingward.notification.queue."
  private static let service = "com.wingward.notifications"
  static let maximumEventCount = 500
  static let maximumSubmissionBatchCount = 100
  private static let maximumEncodedBytes = 64_000

  let storage: any WingwardNotificationQueueKeychainStorage

  init(
    storage: any WingwardNotificationQueueKeychainStorage = KeychainAuthLocalStorage(service: Self.service)
  ) {
    self.storage = storage
  }

  func load(ownerID: String) throws -> WingwardNotificationPendingWork {
    guard let canonicalOwnerID = Self.canonicalOwnerID(ownerID) else { return .init() }
    let key = Self.key(ownerID: canonicalOwnerID)
    guard let data = try storage.retrieve(key: key) else { return .init() }
    guard data.count <= Self.maximumEncodedBytes,
      let stored = try? JSONDecoder().decode(StoredWork.self, from: data),
      stored.events.count <= Self.maximumEventCount
    else {
      try? storage.remove(key: key)
      return .init()
    }

    let events = stored.events.compactMap { item -> WingwardNotificationEvent? in
      let event = item.event
      return (try? event.validate()) == nil ? nil : event
    }
    return WingwardNotificationPendingWork(
      events: events,
      pendingTap: stored.pendingTap?.payload
    )
  }

  func save(_ work: WingwardNotificationPendingWork, ownerID: String) throws {
    guard let canonicalOwnerID = Self.canonicalOwnerID(ownerID) else {
      throw APIClientError.invalidRequest
    }
    guard work.events.count <= Self.maximumEventCount else {
      throw APIClientError.invalidRequest
    }
    let key = Self.key(ownerID: canonicalOwnerID)
    let stored = StoredWork(
      events: work.events.map(StoredEvent.init),
      pendingTap: work.pendingTap.map(StoredPayload.init)
    )
    guard !stored.events.isEmpty || stored.pendingTap != nil else {
      try storage.remove(key: key)
      return
    }
    let data = try JSONEncoder().encode(stored)
    guard data.count <= Self.maximumEncodedBytes else { throw APIClientError.invalidRequest }
    try storage.store(key: key, value: data)
  }

  private static func canonicalOwnerID(_ ownerID: String) -> String? {
    guard let uuid = UUID(uuidString: ownerID) else { return nil }
    return uuid.uuidString.lowercased()
  }

  private static func key(ownerID: String) -> String {
    "\(keyPrefix)\(ownerID)"
  }

  private struct StoredWork: Codable {
    let events: [StoredEvent]
    let pendingTap: StoredPayload?
  }

  private struct StoredEvent: Codable {
    let notificationID: UUID
    let eventType: WingwardNotificationEventType
    let screen: WingwardNotificationScreen?
    let occurredAt: Date?
    let metadata: [String: String]?

    init(_ event: WingwardNotificationEvent) {
      notificationID = event.notificationID
      eventType = event.eventType
      screen = event.screen
      occurredAt = event.occurredAt
      metadata = Self.persistableMetadata(event.metadata)
    }

    var event: WingwardNotificationEvent {
      WingwardNotificationEvent(
        notificationID: notificationID,
        eventType: eventType,
        screen: screen,
        occurredAt: occurredAt,
        metadata: Self.persistableMetadata(metadata)
      )
    }

    private static func persistableMetadata(_ metadata: [String: String]?) -> [String: String]? {
      guard let scenario = metadata?["scenario"],
        WingwardNotificationScenario(rawValue: scenario) != nil
      else { return nil }
      return ["scenario": scenario]
    }
  }

  private struct StoredPayload: Codable {
    let notificationID: UUID
    let scenario: WingwardNotificationScenario
    let deepLink: String?

    init(_ payload: WingwardNotificationPayload) {
      notificationID = payload.notificationID
      scenario = payload.scenario
      deepLink = Self.canonicalDeepLink(for: payload.route)
    }

    var payload: WingwardNotificationPayload? {
      guard deepLink == nil || AppDeepLinkParser.parse(deepLink ?? "") != nil else { return nil }
      return WingwardNotificationPayload(
        notificationID: notificationID,
        scenario: scenario,
        deepLink: deepLink
      )
    }

    private static func canonicalDeepLink(for route: AppRoute?) -> String? {
      guard let route else { return nil }
      switch route {
      case let .meetup(id):
        return "\(AppDeepLinkParser.scheme)://meetup/\(id.uuidString.lowercased())"
      case let .meetupVerification(id):
        return "\(AppDeepLinkParser.scheme)://meetup/\(id.uuidString.lowercased())/verify"
      case let .meetupFeedback(id):
        return "\(AppDeepLinkParser.scheme)://meetup/\(id.uuidString.lowercased())/feedback"
      case let .meetupResult(id):
        return "\(AppDeepLinkParser.scheme)://meetup/\(id.uuidString.lowercased())/result"
      case let .chatRequest(id):
        return "\(AppDeepLinkParser.scheme)://chat-requests/\(id.uuidString.lowercased())"
      case let .foxConversationResult(id):
        return "\(AppDeepLinkParser.scheme)://match/\(id.uuidString.lowercased())/fox-result"
      case let .foxLearned(id):
        return "\(AppDeepLinkParser.scheme)://match/\(id.uuidString.lowercased())/fox-learned"
      case .availability:
        return "\(AppDeepLinkParser.scheme)://availability"
      default:
        return nil
      }
    }
  }
}

@MainActor
@Observable
final class WingwardNotificationPermissionModel {
  private(set) var authorization: WingwardNotificationAuthorization = .unknown
  private(set) var pendingBadgeCount: Int
  private(set) var isPromptPresented = false
  private(set) var didOfferFirstFoxResultPrompt = false
  private(set) var isMarkingSeen = false
  private(set) var seenError: String?

  @ObservationIgnored private let ownerID: String
  @ObservationIgnored private let permissionClient: any WingwardNotificationPermissionClient
  @ObservationIgnored private let badgePersistence: any WingwardNotificationBadgePersistence
  @ObservationIgnored private let seenAPI: (any WingwardNotificationSeenAPI)?

  init(
    ownerID: String,
    permissionClient: (any WingwardNotificationPermissionClient)? = nil,
    badgePersistence: (any WingwardNotificationBadgePersistence)? = nil,
    seenAPI: (any WingwardNotificationSeenAPI)? = nil
  ) {
    self.ownerID = ownerID
    let resolvedPermissionClient = permissionClient ?? SystemWingwardNotificationPermissionClient()
    let resolvedBadgePersistence = badgePersistence ?? WingwardKeychainNotificationBadgePersistence()
    self.permissionClient = resolvedPermissionClient
    self.badgePersistence = resolvedBadgePersistence
    self.seenAPI = seenAPI
    pendingBadgeCount = resolvedBadgePersistence.count(ownerID: ownerID)
  }

  var shouldShowFallbackBadge: Bool {
    pendingBadgeCount > 0 && !authorization.canDeliverPush
  }

  /// Call this once when the first Fox result becomes available.  The custom
  /// explanation sheet is presented only then; the app never asks on launch.
  func prepareForFirstFoxResult() async {
    guard !didOfferFirstFoxResultPrompt else { return }
    didOfferFirstFoxResultPrompt = true
    await refresh()
    if authorization == .notDetermined {
      isPromptPresented = true
    } else if !authorization.canDeliverPush {
      markPendingResult()
    }
  }

  func refresh() async {
    authorization = await permissionClient.authorizationStatus()
  }

  func acceptPrompt() async {
    isPromptPresented = false
    authorization = await permissionClient.requestAuthorization()
    if !authorization.canDeliverPush {
      markPendingResult()
    }
  }

  func deferPrompt() {
    isPromptPresented = false
    // “Not now” is a valid local opt-out for this result.  Keep the result
    // visible in the app until the user visits it or re-enables permissions.
    markPendingResult()
  }

  func dismissPrompt() {
    isPromptPresented = false
  }

  func openSettings() {
    permissionClient.openSettings()
  }

  func markPendingResult() {
    guard pendingBadgeCount < Int.max else { return }
    pendingBadgeCount += 1
    badgePersistence.save(count: pendingBadgeCount, ownerID: ownerID)
  }

  private func clearPendingResults() {
    pendingBadgeCount = 0
    badgePersistence.save(count: 0, ownerID: ownerID)
  }

  func markPendingResultsSeen() async {
    guard pendingBadgeCount > 0, !isMarkingSeen else { return }
    guard let seenAPI else {
      seenError = "Could not update notification status. Try again later."
      return
    }

    isMarkingSeen = true
    seenError = nil
    defer { isMarkingSeen = false }
    do {
      _ = try await seenAPI.markSeen()
      clearPendingResults()
    } catch {
      seenError = "Could not update notification status. Try again."
    }
  }
}

protocol WingwardNotificationEventReporting: Sendable {
  func record(_ event: WingwardNotificationEvent) async throws
}

/// Serializes event reporting and de-duplicates repeated delegate/view
/// callbacks for one notification.  A failed request is removed from the
/// in-memory set so a later foreground/open can retry it.
actor WingwardNotificationEventReporter: WingwardNotificationEventReporting {
  private let api: any WingwardNotificationEventsAPI
  private var recorded: Set<WingwardNotificationEventKey> = []

  init(api: any WingwardNotificationEventsAPI) {
    self.api = api
  }

  func record(_ event: WingwardNotificationEvent) async throws {
    let key = WingwardNotificationEventKey(
      notificationID: event.notificationID,
      eventType: event.eventType,
      screen: event.screen
    )
    guard recorded.insert(key).inserted else { return }
    do {
      try await api.record(event)
    } catch {
      recorded.remove(key)
      throw error
    }
  }
}

/// Coordinates provider callbacks with the closed `AppRoute` enum.  The
/// route handler belongs to the app entry point; this feature never creates a
/// SwiftUI view from a payload string.
@MainActor
final class WingwardNotificationCoordinator {
  typealias RouteHandler = @MainActor (AppRoute) -> Void
  typealias SeenHandler = @MainActor () -> Void

  private var reporter: (any WingwardNotificationEventReporting)?
  private var seenAPI: (any WingwardNotificationSeenAPI)?
  private let queuePersistence: any WingwardNotificationQueuePersistence
  private var boundOwnerID: UUID?
  private var pendingTapPayload: WingwardNotificationPayload?
  private var pendingEvents: [WingwardNotificationEvent] = []
  private var pendingEventKeys: Set<WingwardNotificationEventKey> = []
  private var durableEventKeys: Set<WingwardNotificationEventKey> = []
  private var inFlightEventKeys: Set<WingwardNotificationEventKey> = []
  private var pendingTapInFlight: WingwardNotificationPayload?
  private var restoredQueueOwnerID: UUID?
  private var bindingGeneration = 0
  private var markedSeenNotificationIDs: Set<UUID> = []
  private var openedNotificationID: UUID?
  private(set) var activePayload: WingwardNotificationPayload?
  var onRoute: RouteHandler?
  var onNotificationSeen: SeenHandler?

  private var inFlightRequestCount: Int {
    inFlightEventKeys.count + (pendingTapInFlight == nil ? 0 : 1)
  }

  init(
    ownerID: String? = nil,
    reporter: (any WingwardNotificationEventReporting)? = nil,
    onRoute: RouteHandler? = nil,
    seenAPI: (any WingwardNotificationSeenAPI)? = nil,
    onNotificationSeen: SeenHandler? = nil,
    queuePersistence: (any WingwardNotificationQueuePersistence)? = nil
  ) {
    let resolvedOwnerID = ownerID.flatMap { try? APIDTOValidation.requireUUID($0) }
    boundOwnerID = resolvedOwnerID
    self.reporter = reporter
    self.seenAPI = seenAPI
    self.onRoute = onRoute
    self.onNotificationSeen = onNotificationSeen
    self.queuePersistence = queuePersistence ?? WingwardKeychainNotificationQueuePersistence()
    if let resolvedOwnerID {
      _ = restorePendingWork(ownerID: resolvedOwnerID)
    }
    flushPendingWork()
  }

  func bind(reporter: (any WingwardNotificationEventReporting)?) {
    self.reporter = reporter
    if let boundOwnerID, restoredQueueOwnerID != boundOwnerID {
      _ = restorePendingWork(ownerID: boundOwnerID)
    }
    flushPendingWork()
  }

  func bind(seenAPI: (any WingwardNotificationSeenAPI)?) {
    self.seenAPI = seenAPI
  }

  /// Binds all notification work to the currently authenticated owner. A
  /// cold-start tap may arrive before auth bootstrap; it remains pending until
  /// this method receives a verified owner and an owner-bound event reporter.
  /// Each owner's queued work stays in that owner's Keychain namespace. An
  /// account change never sends the previous owner's work with a new token.
  func bind(
    ownerID: String?,
    reporter: (any WingwardNotificationEventReporting)?,
    seenAPI: (any WingwardNotificationSeenAPI)? = nil
  ) {
    let nextOwnerID = ownerID.flatMap { try? APIDTOValidation.requireUUID($0) }
    if nextOwnerID != boundOwnerID {
      let hadOwner = boundOwnerID != nil
      if let boundOwnerID {
        _ = persistPendingWork(ownerID: boundOwnerID)
      }
      bindingGeneration &+= 1
      boundOwnerID = nextOwnerID
      restoredQueueOwnerID = nil
      activePayload = nil
      openedNotificationID = nil
      markedSeenNotificationIDs.removeAll()
      inFlightEventKeys.removeAll()
      pendingTapInFlight = nil
      if hadOwner {
        pendingTapPayload = nil
        pendingEvents.removeAll()
        pendingEventKeys.removeAll()
        durableEventKeys.removeAll()
      }
      if let nextOwnerID {
        _ = restorePendingWork(ownerID: nextOwnerID)
      }
    }
    self.reporter = reporter
    self.seenAPI = seenAPI
    if let boundOwnerID, restoredQueueOwnerID != boundOwnerID {
      _ = restorePendingWork(ownerID: boundOwnerID)
    }
    flushPendingWork()
  }

  @discardableResult
  func handleForegroundNotification(userInfo: [AnyHashable: Any]) -> Bool {
    guard let payload = WingwardNotificationPayload(userInfo: userInfo) else { return false }
    activePayload = payload
    return submitOrQueue(
      WingwardNotificationEvent(
        notificationID: payload.notificationID,
        eventType: .delivered
      )
    )
  }

  @discardableResult
  func handleNotificationTap(userInfo: [AnyHashable: Any]) -> Bool {
    guard let payload = WingwardNotificationPayload(userInfo: userInfo) else { return false }
    let previousTapPayload = pendingTapPayload
    pendingTapPayload = payload
    pendingTapInFlight = nil
    activePayload = nil
    openedNotificationID = nil
    if boundOwnerID != nil, !persistPendingWork() {
      pendingTapPayload = previousTapPayload
      return false
    }
    flushPendingWork()
    return true
  }

  @discardableResult
  func recordScreenViewed(for route: AppRoute) -> Bool {
    guard
      let payload = activePayload,
      openedNotificationID == payload.notificationID,
      route == payload.destinationRoute
    else { return false }
    onNotificationSeen?()
    let accepted = submitOrQueue(
      WingwardNotificationEvent(
        notificationID: payload.notificationID,
        eventType: .screenViewed,
        screen: WingwardNotificationScreen(route: route)
      )
    )
    markServerSeen(for: payload.notificationID)
    return accepted
  }

  @discardableResult
  func recordActionCompleted(screen: WingwardNotificationScreen) -> Bool {
    guard let payload = activePayload, openedNotificationID == payload.notificationID else { return false }
    guard WingwardNotificationScreen(route: payload.destinationRoute) == screen else { return false }
    return submitOrQueue(
      WingwardNotificationEvent(
        notificationID: payload.notificationID,
        eventType: .actionCompleted,
        screen: screen
      )
    )
  }

  @discardableResult
  func recordDismissed(screen: WingwardNotificationScreen? = nil) -> Bool {
    guard let payload = activePayload else { return false }
    if let screen, WingwardNotificationScreen(route: payload.destinationRoute) != screen { return false }
    return submitOrQueue(
      WingwardNotificationEvent(
        notificationID: payload.notificationID,
        eventType: .dismissed,
        screen: screen
      )
    )
  }

  @discardableResult
  private func submitOrQueue(_ event: WingwardNotificationEvent) -> Bool {
    guard enqueue(event) else {
      flushPendingWork()
      return false
    }
    flushPendingWork()
    return true
  }

  private func submit(
    _ event: WingwardNotificationEvent,
    reporter: any WingwardNotificationEventReporting,
    key: WingwardNotificationEventKey,
    generation: Int
  ) {
    Task { [weak self] in
      do {
        try await reporter.record(event)
        guard let self, self.bindingGeneration == generation else { return }
        self.inFlightEventKeys.remove(key)
        self.pendingEvents.removeAll { Self.eventKey(for: $0) == key }
        self.pendingEventKeys.remove(key)
        _ = self.persistPendingWork()
        self.flushPendingWork()
      } catch {
        guard let self, self.bindingGeneration == generation else { return }
        self.inFlightEventKeys.remove(key)
      }
    }
  }

  private func enqueue(_ event: WingwardNotificationEvent) -> Bool {
    let key = Self.eventKey(for: event)
    guard pendingEventKeys.insert(key).inserted else { return true }
    pendingEvents.append(event)
    if boundOwnerID == nil {
      pendingEvents.removeAll { Self.eventKey(for: $0) == key }
      pendingEventKeys.remove(key)
      return false
    }
    guard persistPendingWork() else {
      pendingEvents.removeAll { Self.eventKey(for: $0) == key }
      pendingEventKeys.remove(key)
      return false
    }
    return true
  }

  private func flushPendingWork() {
    guard let ownerID = boundOwnerID,
      restoredQueueOwnerID == ownerID,
      let reporter,
      persistPendingWork(ownerID: ownerID)
    else { return }
    let generation = bindingGeneration
    for event in pendingEvents {
      let key = Self.eventKey(for: event)
      guard durableEventKeys.contains(key) else { continue }
      guard inFlightRequestCount < WingwardKeychainNotificationQueuePersistence.maximumSubmissionBatchCount else {
        break
      }
      guard inFlightEventKeys.insert(key).inserted else { continue }
      submit(event, reporter: reporter, key: key, generation: generation)
    }

    guard let payload = pendingTapPayload else { return }
    guard inFlightRequestCount < WingwardKeychainNotificationQueuePersistence.maximumSubmissionBatchCount else {
      return
    }
    guard pendingTapInFlight != payload else { return }
    pendingTapInFlight = payload
    activePayload = payload
    openedNotificationID = nil
    let opened = WingwardNotificationEvent(
      notificationID: payload.notificationID,
      eventType: .opened
    )
    Task { [weak self] in
      do {
        try await reporter.record(opened)
        guard let self,
          self.bindingGeneration == generation,
          self.boundOwnerID != nil,
          self.activePayload == payload
        else { return }
        self.pendingTapPayload = nil
        self.pendingTapInFlight = nil
        self.openedNotificationID = payload.notificationID
        _ = self.persistPendingWork()
        self.onRoute?(payload.destinationRoute)
        self.flushPendingWork()
      } catch {
        guard let self,
          self.bindingGeneration == generation,
          self.activePayload == payload
        else { return }
        self.pendingTapInFlight = nil
        self.activePayload = nil
        self.openedNotificationID = nil
        _ = self.persistPendingWork()
      }
    }
  }

  private static func eventKey(for event: WingwardNotificationEvent) -> WingwardNotificationEventKey {
    WingwardNotificationEventKey(
      notificationID: event.notificationID,
      eventType: event.eventType,
      screen: event.screen
    )
  }

  @discardableResult
  private func restorePendingWork(ownerID: UUID) -> Bool {
    guard let stored = try? queuePersistence.load(ownerID: ownerID.uuidString.lowercased()) else {
      restoredQueueOwnerID = nil
      return false
    }

    let transientEvents = pendingEvents
    let transientTap = pendingTapPayload
    pendingEvents.removeAll()
    pendingEventKeys.removeAll()
    durableEventKeys.removeAll()
    inFlightEventKeys.removeAll()
    for event in stored.events + transientEvents {
      let key = Self.eventKey(for: event)
      guard pendingEventKeys.insert(key).inserted else { continue }
      pendingEvents.append(event)
    }
    pendingTapPayload = transientTap ?? stored.pendingTap
    restoredQueueOwnerID = ownerID
    return persistPendingWork(ownerID: ownerID)
  }

  @discardableResult
  private func persistPendingWork(ownerID: UUID? = nil) -> Bool {
    guard let ownerID = ownerID ?? boundOwnerID,
      restoredQueueOwnerID == ownerID
    else { return false }
    do {
      try queuePersistence.save(
        WingwardNotificationPendingWork(events: pendingEvents, pendingTap: pendingTapPayload),
        ownerID: ownerID.uuidString.lowercased()
      )
      durableEventKeys = Set(pendingEvents.map(Self.eventKey(for:)))
      return true
    } catch {
      return false
    }
  }

  private func markServerSeen(for notificationID: UUID) {
    guard
      boundOwnerID != nil,
      let seenAPI,
      markedSeenNotificationIDs.insert(notificationID).inserted
    else { return }
    let generation = bindingGeneration
    Task { [weak self, seenAPI] in
      do {
        _ = try await seenAPI.markSeen()
      } catch {
        guard let self, self.bindingGeneration == generation else { return }
        self.markedSeenNotificationIDs.remove(notificationID)
      }
    }
  }
}

extension WingwardNotificationScreen {
  init(route: AppRoute) {
    switch route {
    case .matches:
      self = .matches
    case .matchDetail:
      self = .matchDetail
    case .foxConversation, .foxConversationResult:
      self = .foxConversationResult
    case .partnerFoxChat:
      self = .partnerFoxChat
    case .directChat:
      self = .directChat
    case .chatRequest:
      self = .chatRequests
    case .meetup:
      self = .meetup
    case .meetupVerification:
      self = .meetupVerification
    case .meetupFeedback:
      self = .meetupFeedback
    case .meetupResult:
      self = .meetupResult
    case .foxLearned:
      self = .foxLearned
    case .availability:
      self = .availability
    case .notificationLanding:
      self = .notifications
    case .authentication, .ageGate, .onboarding, .settings, .report, .paywall:
      self = .notifications
    }
  }
}

/// Native delegate bridge.  It does not assume OneSignal is installed; APNs
/// payloads and a future provider adapter use the same data contract.
final class WingwardNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
  private let coordinator: WingwardNotificationCoordinator

  init(coordinator: WingwardNotificationCoordinator) {
    self.coordinator = coordinator
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo
    Task { @MainActor [coordinator] in
      coordinator.handleForegroundNotification(userInfo: userInfo)
    }
    completionHandler([.banner, .badge, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    Task { @MainActor [coordinator] in
      coordinator.handleNotificationTap(userInfo: userInfo)
      completionHandler()
    }
  }
}

@MainActor
final class WingwardNotificationRuntime {
  let coordinator: WingwardNotificationCoordinator
  let delegate: WingwardNotificationCenterDelegate

  init(
    ownerID: String? = nil,
    reporter: (any WingwardNotificationEventReporting)? = nil,
    onRoute: WingwardNotificationCoordinator.RouteHandler? = nil,
    seenAPI: (any WingwardNotificationSeenAPI)? = nil,
    onNotificationSeen: WingwardNotificationCoordinator.SeenHandler? = nil,
    queuePersistence: (any WingwardNotificationQueuePersistence)? = nil
  ) {
    coordinator = WingwardNotificationCoordinator(
      ownerID: ownerID,
      reporter: reporter,
      onRoute: onRoute,
      seenAPI: seenAPI,
      onNotificationSeen: onNotificationSeen,
      queuePersistence: queuePersistence
    )
    delegate = WingwardNotificationCenterDelegate(coordinator: coordinator)
  }

  func install() {
    UNUserNotificationCenter.current().delegate = delegate
  }

  func bind(
    ownerID: String?,
    reporter: (any WingwardNotificationEventReporting)?,
    seenAPI: (any WingwardNotificationSeenAPI)? = nil
  ) {
    coordinator.bind(ownerID: ownerID, reporter: reporter, seenAPI: seenAPI)
  }
}
