#if DEBUG
import Foundation
import SwiftUI

/// Fixture-only launcher for the native journey. It uses the real direct-chat
/// and Partner Ward views/stores with deterministic in-memory responses; no
/// network client, account session, purchase, or cloud state is involved.
enum ChatsDebugFixture {
  static let ownerID = UserProfile.fixture.id ?? "fixture-owner"

  static func ownerView(
    ownerID: String,
    callbacks: NativeFeatureCallbacks = .empty
  ) -> AnyView? {
    guard ownerID == Self.ownerID else { return nil }
    let api = DebugChatsAPI.shared
    return AnyView(
      DebugChatsFixtureView(
        ownerID: ownerID,
        api: api,
        callbacks: callbacks
      )
    )
  }
}

@MainActor
private final class DebugMessageSendRetryReceiptStore: MessageSendRetryReceiptStoring {
  private var receipts: [String: MessageSendRetryReceipt] = [:]

  func load(
    kind: MessageSendRetryReceiptKind,
    ownerID: UUID,
    conversationID: UUID
  ) throws -> MessageSendRetryReceipt? {
    guard let receipt = receipts[Self.key(kind: kind, ownerID: ownerID, conversationID: conversationID)] else {
      return nil
    }
    guard receipt.matches(kind: kind, ownerID: ownerID, conversationID: conversationID) else {
      throw KeychainStorageError.invalidData
    }
    return receipt
  }

  func save(_ receipt: MessageSendRetryReceipt) throws {
    guard receipt.matches(
      kind: receipt.kind,
      ownerID: receipt.ownerID,
      conversationID: receipt.conversationID
    ) else {
      throw KeychainStorageError.invalidData
    }
    if let current = try load(
      kind: receipt.kind,
      ownerID: receipt.ownerID,
      conversationID: receipt.conversationID
    ), current != receipt {
      throw KeychainStorageError.invalidData
    }
    receipts[Self.key(
      kind: receipt.kind,
      ownerID: receipt.ownerID,
      conversationID: receipt.conversationID
    )] = receipt
  }

  func clear(
    kind: MessageSendRetryReceiptKind,
    ownerID: UUID,
    conversationID: UUID
  ) throws {
    receipts.removeValue(forKey: Self.key(kind: kind, ownerID: ownerID, conversationID: conversationID))
  }

  private static func key(
    kind: MessageSendRetryReceiptKind,
    ownerID: UUID,
    conversationID: UUID
  ) -> String {
    "\(kind.rawValue):\(ownerID.uuidString.lowercased()):\(conversationID.uuidString.lowercased())"
  }
}

private enum DebugChatsSheet: Identifiable {
  case request(UUID)
  case requests

  var id: String {
    switch self {
    case let .request(matchID): "request-\(matchID.uuidString)"
    case .requests: "requests"
    }
  }
}

private struct DebugChatsFixtureView: View {
  let ownerID: String
  let api: DebugChatsAPI
  let callbacks: NativeFeatureCallbacks
  @Environment(\.dismiss) private var dismiss
  @State private var showsSafety = false
  @State private var presentedChatSheet: DebugChatsSheet?
  @State private var requestStateLabel = "Request state not refreshed"
  @State private var retryReceiptStore = DebugMessageSendRetryReceiptStore()

  private let matchID = DebugChatsAPI.outgoingMatchID
  private let partnerID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
  private let chatID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Button {
          dismiss()
        } label: {
          Label("Back to features", systemImage: "chevron.left")
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chatsDebugFixture.backToHub")
        Spacer(minLength: 8)
        Text("DEBUG FIXTURE")
          .font(.caption.weight(.bold))
          .tracking(1.2)
      }
      .padding(.horizontal, 16)
      .foregroundStyle(ReferencePalette.ink)

      Text("Synthetic chats · no account changes")
        .font(.caption.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 36)
        .foregroundStyle(ReferencePalette.ink)
        .background(ReferencePalette.yellowSoft)
        .accessibilityIdentifier("chatsDebugFixture.banner")

      Text(requestStateLabel)
        .font(.caption.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 32)
        .foregroundStyle(ReferencePalette.ink)
        .accessibilityIdentifier("chatsDebugFixture.requestState")

      Button {
        showsSafety = true
      } label: {
        Label("Open synthetic report and block", systemImage: "exclamationmark.shield")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(ReferenceOutlineButtonStyle())
      .padding(.horizontal, 16)
      .accessibilityIdentifier("chatsDebugFixture.report")

      NavigationLink {
        PartnerWardChatView(
          ownerID: ownerID,
          matchID: matchID,
          partnerID: partnerID,
          chatID: chatID,
          api: api,
          onOpenSettings: callbacks.onOpenSettings,
          onOpenReport: callbacks.onOpenReport ?? { _, _ in showsSafety = true },
          onOpenMeetup: callbacks.onOpenMeetup,
          onOpenChatRequest: { selectedMatchID in
            presentedChatSheet = .request(selectedMatchID)
          },
          retryReceiptStore: retryReceiptStore
        )
      } label: {
        Label("Open Partner Ward fixture", systemImage: "message.and.waveform")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(ReferenceOutlineButtonStyle())
      .padding(.horizontal, 16)
      .accessibilityIdentifier("chatsDebugFixture.partnerWard")

      DirectChatsView(
        ownerID: ownerID,
        api: api,
        onOpenSettings: callbacks.onOpenSettings,
        onOpenReport: callbacks.onOpenReport,
        onOpenReportForMatch: { _, _ in showsSafety = true },
        onOpenChatRequests: { presentedChatSheet = .requests },
        calendarProvider: DebugNativeBusyCalendarProvider(authorization: .denied),
        locationProvider: UnavailableNativeMeetupLocationProvider(),
        reflectionTransport: DebugVoiceInterviewTransport(),
        voicePermissionClient: DebugVoicePermissionClient(status: .granted),
        retryReceiptStore: retryReceiptStore
      )
    }
    .background(ReferencePalette.cream)
    .tint(ReferencePalette.ink)
    .preferredColorScheme(.light)
    // The embedded request list and its modal review use the same controls.
    // Only the presented sheet should remain available to accessibility.
    .accessibilityHidden(presentedChatSheet != nil || showsSafety)
    .sheet(isPresented: $showsSafety) {
      SafetyDebugFixture.actionView(ownerID: ownerID)
        .presentationDetents([.medium, .large])
    }
    .sheet(item: $presentedChatSheet) { sheet in
      NavigationStack {
        switch sheet {
        case let .request(selectedMatchID):
          DirectChatRequestView(
            ownerID: ownerID,
            matchID: selectedMatchID,
            api: api,
            onCompleted: { result in
              Task {
                let state = try? await api.fetchChatRequestState(matchID: result.matchID)
                requestStateLabel = state.map { "Request state: \($0.status.rawValue)" }
                  ?? "Request state: none"
                presentedChatSheet = nil
              }
            }
          )
        case .requests:
          ChatRequestsView(
            ownerID: ownerID,
            api: api,
            onAccepted: { _ in
              Task {
                let state = try? await api.fetchChatRequestState(
                  matchID: DebugChatsAPI.incomingMatchID
                )
                requestStateLabel = state.map { "Request state: \($0.status.rawValue)" }
                  ?? "Request state: none"
                presentedChatSheet = nil
              }
            }
          )
        }
      }
      .presentationDetents([.large])
    }
  }
}

actor DebugChatsAPI: DirectChatsAPI, MatchDetailAPI {
  static let shared = DebugChatsAPI(ownerID: ChatsDebugFixture.ownerID)
  static let outgoingMatchID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  static let incomingMatchID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  static let incomingRequestID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

  private let ownerID: String
  private let ownerUUID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
  private let partnerUUID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
  private let matchUUID = DebugChatsAPI.outgoingMatchID
  private let roomUUID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
  private let fixtureDate = Date()
  private var partnerMessages: [PartnerFoxMessage]
  private var directMessages: [DirectChatMessage]
  private var chatRequestStates: [UUID: ChatRequestMatchState] = [:]
  private var partnerSendSequence = 0
  private var directSendSequence = 0
  private var meetupEvents: [ChatMeetupEvent] = []
  private var meetupTimeCandidates: [ChatMeetupTimeCandidate] = []
  private var meetupCafeCandidates: [ChatMeetupCafeCandidate] = []
  private var meetupRevision = 0
  private var meetupPrivateRevision = 0
  private var meetupStatus: ChatMeetupStatus = .idle
  private var meetupIntent: ChatMeetupIntentValue?
  private var meetupTimeChoice: UUID?
  private var meetupCafeChoice: String?
  private var meetupNeedsLocation = false
  private var meetupCompleted = false
  private let judgeCounterpartFixture = ProcessInfo.processInfo.arguments.contains("--wingward-judge-counterpart-fixture")
  private var meetupIdempotency: [UUID: ChatMeetupState] = [:]
  private var staleMeetupActionOnce = ProcessInfo.processInfo.arguments.contains("--wingward-chat-meetup-stale-once")
  private var reflectionVersion = 0
  private var reflectionTraits: [ChatMeetupReflectionTrait] = []

  private var meetupID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

  init(ownerID: String) {
    self.ownerID = ownerID
    chatRequestStates[Self.incomingMatchID] = ChatRequestMatchState(
      id: Self.incomingRequestID,
      matchID: Self.incomingMatchID,
      requesterID: partnerUUID,
      responderID: ownerUUID,
      status: .pending,
      expiresAt: fixtureDate.addingTimeInterval(172_800)
    )
    partnerMessages = [
      PartnerFoxMessage(
        id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
        role: .fox,
        content: "あなたのペースで話していきましょう。",
        createdAt: Date(timeIntervalSince1970: 1_788_451_200)
      )
    ]
    directMessages = [
      DirectChatMessage(
        id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
        senderID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
        isMine: false,
        content: "今日はゆっくり話せそうです。",
        isRead: false,
        createdAt: Date(timeIntervalSince1970: 1_788_451_200)
      )
    ]
  }

  private func currentMeetupState() -> ChatMeetupState {
    let canIntent = meetupStatus == .idle || meetupStatus == .intentPending || meetupStatus == .awaitingAvailability
    let canSchedule = meetupStatus == .awaitingAvailability || meetupStatus == .timeProposed
      || meetupStatus == .awaitingLocation || meetupStatus == .cafeProposed || meetupStatus == .confirmed
    let permissions = ChatMeetupOwnPermissions(
      canIntent: canIntent,
      canSchedule: canSchedule,
      canReplan: meetupStatus == .confirmed || meetupStatus == .cafeProposed,
      canCancel: meetupStatus == .awaitingAvailability || meetupStatus == .timeProposed
        || meetupStatus == .awaitingLocation || meetupStatus == .cafeProposed || meetupStatus == .confirmed,
      canComplete: meetupStatus == .confirmed && !meetupCompleted,
      calendarConnected: false,
      cafeConnected: false,
      reason: nil
    )
    return ChatMeetupState(
      roomID: roomUUID,
      meetupID: meetupID,
      revision: meetupRevision,
      status: meetupStatus,
      events: meetupEvents,
      timeCandidates: meetupTimeCandidates,
      cafeCandidates: meetupCafeCandidates,
      ownPermissions: permissions,
      ownDecisions: ChatMeetupOwnDecisions(
        intentValue: meetupIntent,
        timeCandidateID: meetupTimeChoice,
        cafeCandidateID: meetupCafeChoice,
        completed: meetupCompleted,
        privateRevision: meetupPrivateRevision
      ),
      needsLocation: meetupNeedsLocation,
      expiresAt: fixtureDate.addingTimeInterval(86_400),
      unavailableReason: nil,
      simulatedCounterpart: judgeCounterpartFixture, judgeMatchID: judgeCounterpartFixture ? matchUUID : nil
    )
  }

  private func addFixtureEvent(_ text: String, kind: ChatMeetupEventKind = .ward) {
    meetupRevision += 1
    meetupEvents.append(ChatMeetupEvent(
      id: UUID(),
      revision: meetupRevision,
      kind: kind,
      text: "DEBUG FIXTURE ONLY · \(text)",
      createdAt: Date()
    ))
  }

  // MARK: Direct chat meetup fixture

  func advanceJudgeCounterpart(matchID: UUID, operation: JudgeCounterpartOperation, expectedRevision: Int, idempotencyKey: UUID) async throws -> JudgeCounterpartAdvanceResult {
    guard judgeCounterpartFixture, matchID == matchUUID, expectedRevision == meetupRevision else { throw APIClientError.invalidState }
    if operation == .simulateCompletion {
      guard meetupStatus == .confirmed else { throw APIClientError.invalidState }
      meetupCompleted = true
      meetupPrivateRevision += 1
      meetupRevision += 1
    }
    return JudgeCounterpartAdvanceResult(outcome: "ok", matchID: matchID, roomID: roomUUID,
      meetupID: meetupID, status: meetupStatus.rawValue, revision: meetupRevision)
  }

  func fetchChatMeetup(roomID: UUID) async throws -> ChatMeetupState {
    guard ownerID == ChatsDebugFixture.ownerID, roomID == roomUUID else { throw APIClientError.notFound }
    return currentMeetupState()
  }

  func performChatMeetupAction(
    roomID: UUID,
    expectedRevision: Int,
    expectedOwnRevision: Int,
    action: ChatMeetupAction,
    idempotencyKey: UUID
  ) async throws -> ChatMeetupState {
    guard ownerID == ChatsDebugFixture.ownerID, roomID == roomUUID else { throw APIClientError.notFound }
    if let replay = meetupIdempotency[idempotencyKey] { return replay }
    guard expectedRevision == meetupRevision, expectedOwnRevision == meetupPrivateRevision else {
      throw APIClientError.invalidState
    }
    try action.validate()
    if staleMeetupActionOnce {
      staleMeetupActionOnce = false
      meetupRevision += 1
      meetupEvents.append(ChatMeetupEvent(
        id: UUID(), revision: meetupRevision, kind: .system,
        text: "DEBUG FIXTURE ONLY · A concurrent synthetic change requires a refresh.",
        createdAt: Date()
      ))
      throw APIClientError.invalidState
    }
    switch action {
    case .intent(.yes):
      meetupIntent = .yes
      meetupPrivateRevision += 1
      meetupStatus = .awaitingAvailability
      addFixtureEvent("The fixture simulates the other participant's private intent.")
    case .intent(.withdraw):
      meetupIntent = .withdraw
      meetupPrivateRevision += 1
      meetupStatus = .idle
    case let .manualAvailability(window, available):
      guard meetupStatus == .awaitingAvailability, let first = available.first else {
        throw APIClientError.invalidState
      }
      let start = max(first.startsAt, Date().addingTimeInterval(3_600))
      let end = min(first.endsAt, start.addingTimeInterval(90 * 60))
      guard start < end, start >= window.startsAt, end <= window.endsAt else { throw APIClientError.invalidRequest }
      meetupPrivateRevision += 1
      meetupTimeCandidates = [
        ChatMeetupTimeCandidate(
          id: UUID(uuidString: "12121212-1212-4212-8212-121212121212")!,
          startsAt: start,
          endsAt: end
        )
      ]
      meetupStatus = .timeProposed
      addFixtureEvent("A synthetic Ward prepared a candidate after synthetic peer approval.")
    case let .calendarAvailability(window, busy):
      guard meetupStatus == .awaitingAvailability, window.startsAt < window.endsAt, busy.count <= 128 else {
        throw APIClientError.invalidState
      }
      meetupPrivateRevision += 1
      let start = max(window.startsAt, Date().addingTimeInterval(3_600))
      meetupTimeCandidates = [
        ChatMeetupTimeCandidate(
          id: UUID(uuidString: "12121212-1212-4212-8212-121212121212")!,
          startsAt: start,
          endsAt: min(window.endsAt, start.addingTimeInterval(90 * 60))
        )
      ]
      meetupStatus = .timeProposed
      addFixtureEvent("Calendar availability is fixture-only; no real events were read.")
    case .clearAvailability:
      guard meetupStatus == .awaitingAvailability else { throw APIClientError.invalidState }
      meetupPrivateRevision += 1
    case let .approveTime(candidateID):
      guard meetupTimeCandidates.contains(where: { $0.id == candidateID }) else { throw APIClientError.invalidRequest }
      meetupTimeChoice = candidateID
      meetupPrivateRevision += 1
      meetupNeedsLocation = false
      meetupStatus = .confirmed
      addFixtureEvent("Both fictional participants approved this future time; no venue or booking was requested.")
    case let .currentLocation(_, _, station, nearest, _, _):
      meetupPrivateRevision += 1
      meetupNeedsLocation = false
      meetupCafeCandidates = [fixtureCafe(station: station ?? nearest ?? "Central Station")]
      meetupStatus = .cafeProposed
      addFixtureEvent("A synthetic public-listing café was generated; no provider was queried.")
    case let .stationLocation(name, _, _):
      meetupPrivateRevision += 1
      meetupNeedsLocation = false
      meetupCafeCandidates = [fixtureCafe(station: name)]
      meetupStatus = .cafeProposed
      addFixtureEvent("A synthetic public-listing café was generated near the entered station.")
    case .clearLocation:
      meetupPrivateRevision += 1
      meetupNeedsLocation = true
      meetupCafeCandidates = []
      meetupStatus = .awaitingLocation
    case let .approveCafe(candidateID):
      guard meetupCafeCandidates.contains(where: { $0.id == candidateID }) else { throw APIClientError.invalidRequest }
      meetupCafeChoice = candidateID
      meetupPrivateRevision += 1
      meetupStatus = .confirmed
      addFixtureEvent("The fixture advanced time to simulate a confirmed plan; no booking was made.")
    case .declineCafe:
      meetupPrivateRevision += 1
      meetupNeedsLocation = true
      meetupStatus = .awaitingLocation
      meetupCafeCandidates = []
    case .replan:
      meetupRevision += 1
      meetupStatus = .awaitingAvailability
      meetupNeedsLocation = false
      meetupTimeCandidates = []
      meetupCafeCandidates = []
      meetupTimeChoice = nil
      meetupCafeChoice = nil
      meetupEvents.append(ChatMeetupEvent(id: UUID(), revision: meetupRevision, kind: .system,
        text: "DEBUG FIXTURE ONLY · Plan reopened for another availability choice.", createdAt: Date()))
    case .cancel:
      meetupRevision += 1
      meetupStatus = .cancelled
      meetupNeedsLocation = false
      meetupTimeCandidates = []
      meetupCafeCandidates = []
      meetupEvents.append(ChatMeetupEvent(id: UUID(), revision: meetupRevision, kind: .system,
        text: "DEBUG FIXTURE ONLY · Meetup cancelled.", createdAt: Date()))
    case .completeMeeting:
      guard meetupStatus == .confirmed else { throw APIClientError.invalidState }
      meetupCompleted = true
      meetupPrivateRevision += 1
      // Completion and reflection eligibility belong to this fixture owner;
      // no peer completion state is represented in the UI.
    }
    let state = currentMeetupState()
    meetupIdempotency[idempotencyKey] = state
    return state
  }

  private func fixtureCafe(station: String) -> ChatMeetupCafeCandidate {
    // Mock projection for UI contract coverage only. No Google provider call.
    let mockGoogle = ProcessInfo.processInfo.arguments.contains("--wingward-chat-meetup-mock-google")
    let interval = meetupTimeCandidates.first.map { ($0.startsAt, $0.endsAt) }
      ?? (Date().addingTimeInterval(7_200), Date().addingTimeInterval(10_800))
    return ChatMeetupCafeCandidate(
      id: "debug-cafe-central",
      name: "Kissa Wingward (synthetic)",
      address: "1-2-3 Chiyoda · near \(station)",
      startsAt: interval.0,
      endsAt: interval.1,
      travelMinutesFirst: mockGoogle ? nil : 14,
      travelMinutesSecond: mockGoogle ? nil : 18,
      source: mockGoogle ? "google" : nil,
      googleMapsURI: mockGoogle ? "https://maps.google.com/?cid=12345" : nil,
      attributions: mockGoogle ? [ChatMeetupCafeAttribution(
        provider: "Mock public data provider", providerURI: "https://provider.example.com/place"
      )] : nil
    )
  }

  func fetchWardConversation(roomID: UUID, limit: Int, cursor: String?) async throws -> ChatMeetupWardConversationPayload {
    guard ownerID == ChatsDebugFixture.ownerID, roomID == roomUUID else { throw APIClientError.notFound }
    let events = [
      ChatMeetupWardConversationEvent(
        id: UUID(uuidString: "13131313-1313-4313-8313-131313131313")!,
        speaker: .myWard,
        text: "DEBUG FIXTURE ONLY · You both enjoy a calm first conversation.",
        round: 1,
        createdAt: fixtureDate
      ),
      ChatMeetupWardConversationEvent(
        id: UUID(uuidString: "14141414-1414-4414-8414-141414141414")!,
        speaker: .partnerWard,
        text: "DEBUG FIXTURE ONLY · A quiet café could suit the pace.",
        round: 1,
        createdAt: fixtureDate.addingTimeInterval(2)
      )
    ]
    return ChatMeetupWardConversationPayload(roomID: roomUUID, events: events)
  }

  func fetchMeetupReflection(meetupID: UUID) async throws -> ChatMeetupReflectionSnapshot {
    guard ownerID == ChatsDebugFixture.ownerID,
      meetupID == self.meetupID, meetupCompleted else { throw APIClientError.notFound }
    return ChatMeetupReflectionSnapshot(
      meetupID: meetupID, currentPersonaVersion: reflectionVersion,
      confirmedTraits: reflectionTraits, confirmedAt: reflectionTraits.isEmpty ? nil : Date()
    )
  }

  func bootstrapMeetupReflection(meetupID: UUID, voice: RealtimeVoice) async throws -> RealtimeVoiceBootstrap {
    guard ownerID == ChatsDebugFixture.ownerID,
      meetupID == self.meetupID, meetupCompleted else { throw APIClientError.notFound }
    let expiry = Date().timeIntervalSince1970 + 60
    let fixture = """
    {"session_id":"15151515-1515-4515-8515-151515151515","client_secret":"ek_debug_fixture_only","expires_at":\(expiry),"model":"gpt-realtime-2.1-mini","overrides":{"agent":{"prompt":{"prompt":"Synthetic private self reflection only."},"firstMessage":"What would you like to learn about yourself?","language":"en"},"tts":{"voiceId":"cedar"}}}
    """
    return try JSONDecoder().decode(RealtimeVoiceBootstrap.self, from: Data(fixture.utf8))
  }

  func draftMeetupReflection(meetupID: UUID, statements: [ChatMeetupReflectionUserStatement]) async throws -> ChatMeetupReflectionDraft {
    guard meetupID == self.meetupID, meetupCompleted, !statements.isEmpty else { throw APIClientError.invalidState }
    for statement in statements { try statement.validate() }
    let ids = statements.map(\.turnID)
    let candidates = [
      ChatMeetupReflectionDraftCandidate(id: UUID(uuidString: "16161616-1616-4616-8616-161616161616")!,
        key: .socialEnergy, value: .ambiverted, sourceTurnIDs: Array(ids.prefix(1))),
      ChatMeetupReflectionDraftCandidate(id: UUID(uuidString: "17171717-1717-4717-8717-171717171717")!,
        key: .favoriteActivity, value: .outdoors, sourceTurnIDs: Array(ids.prefix(1)))
    ]
    return ChatMeetupReflectionDraft(expectedVersion: reflectionVersion, candidates: candidates)
  }

  func confirmMeetupReflection(meetupID: UUID, expectedVersion: Int, traits: [ChatMeetupReflectionTrait],
                               idempotencyKey: UUID) async throws -> ChatMeetupReflectionConfirmation {
    guard meetupID == self.meetupID, meetupCompleted, expectedVersion == reflectionVersion else {
      throw APIClientError.invalidState
    }
    guard !traits.isEmpty, Set(traits.map(\.key)).count == traits.count else { throw APIClientError.invalidRequest }
    reflectionVersion += 1
    reflectionTraits = traits
    return ChatMeetupReflectionConfirmation(version: reflectionVersion, confirmedAt: Date(), traits: traits)
  }

  // MARK: Direct chats

  func fetchDirectChats() async throws -> [DirectChatSummary] {
    guard ownerID == ChatsDebugFixture.ownerID else { throw APIClientError.unauthenticated }
    return [
      DirectChatSummary(
        id: roomUUID,
        matchID: matchUUID,
        partner: DirectChatPartner(nickname: "Aoi"),
        lastMessage: DirectChatLastMessage(
          content: directMessages.last?.content ?? "",
          createdAt: directMessages.last?.createdAt ?? fixtureDate,
          isMine: directMessages.last?.isMine ?? false
        ),
        unreadCount: directMessages.filter { !$0.isMine && !$0.isRead }.count,
        unreadCountAfterSeen: directMessages.filter { !$0.isMine && !$0.isRead }.count
      )
    ]
  }

  func fetchDirectMessages(roomID: UUID, limit: Int, cursor: String?) async throws -> DirectChatMessagesPayload {
    guard roomID == self.roomUUID else { throw APIClientError.notFound }
    return DirectChatMessagesPayload(messages: directMessages)
  }

  func sendDirectMessage(roomID: UUID, content: String) async throws -> DirectChatSendResult {
    guard roomID == self.roomUUID else { throw APIClientError.notFound }
    directSendSequence += 1
    let result = DirectChatSendResult(
      id: UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-\(String(format: "%012d", directSendSequence))")!,
      content: content,
      createdAt: Date(timeIntervalSince1970: 1_788_451_260)
    )
    directMessages.append(
      DirectChatMessage(
        id: result.id,
        senderID: ownerUUID,
        isMine: true,
        content: content,
        isRead: true,
        createdAt: result.createdAt
      )
    )
    return result
  }

  func markDirectMessageRead(roomID: UUID, messageID: UUID) async throws -> DirectChatReadResult {
    guard roomID == self.roomUUID else { throw APIClientError.notFound }
    directMessages = directMessages.map { message in
      guard message.id == messageID else { return message }
      return DirectChatMessage(
        id: message.id,
        senderID: message.senderID,
        isMine: message.isMine,
        content: message.content,
        isRead: true,
        createdAt: message.createdAt
      )
    }
    return DirectChatReadResult(readCount: 1)
  }

  func fetchChatRequests() async throws -> [ChatRequestSummary] {
    guard ownerID == ChatsDebugFixture.ownerID else { throw APIClientError.unauthenticated }
    return chatRequestStates.values
      .filter {
        $0.responderID == ownerUUID && $0.requesterID == partnerUUID
          && $0.status == .pending && $0.expiresAt > fixtureDate
      }
      .sorted { $0.matchID.uuidString < $1.matchID.uuidString }
      .map {
        ChatRequestSummary(
          id: $0.id,
          matchID: $0.matchID,
          requesterID: $0.requesterID,
          status: $0.status.rawValue,
          expiresAt: $0.expiresAt,
          createdAt: fixtureDate,
          requester: ChatRequestRequester(nickname: "Aoi")
        )
      }
  }

  func fetchChatRequestState(matchID: UUID) async throws -> ChatRequestMatchState? {
    guard ownerID == ChatsDebugFixture.ownerID else { throw APIClientError.unauthenticated }
    guard matchID == Self.outgoingMatchID || matchID == Self.incomingMatchID else {
      throw APIClientError.notFound
    }
    return chatRequestStates[matchID]
  }

  func createChatRequest(matchID: UUID) async throws -> ChatRequestCreateResult {
    guard ownerID == ChatsDebugFixture.ownerID,
      matchID == Self.outgoingMatchID,
      chatRequestStates[matchID] == nil
    else { throw APIClientError.invalidState }
    let requestID = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
    let expiresAt = fixtureDate.addingTimeInterval(172_800)
    chatRequestStates[matchID] = ChatRequestMatchState(
      id: requestID,
      matchID: matchID,
      requesterID: ownerUUID,
      responderID: partnerUUID,
      status: .pending,
      expiresAt: expiresAt
    )
    return ChatRequestCreateResult(
      id: requestID,
      matchID: matchID,
      status: "pending",
      expiresAt: expiresAt
    )
  }

  func respondToChatRequest(
    requestID: UUID,
    action: ChatRequestAction
  ) async throws -> ChatRequestDecisionResult {
    guard ownerID == ChatsDebugFixture.ownerID else { throw APIClientError.unauthenticated }
    guard let (matchID, state) = chatRequestStates.first(where: { $0.value.id == requestID }),
      state.status == .pending,
      state.responderID == ownerUUID
    else { throw APIClientError.notFound }
    let status: ChatRequestMatchStatus = action == .accept ? .accepted : .declined
    chatRequestStates[matchID] = ChatRequestMatchState(
      id: state.id,
      matchID: state.matchID,
      requesterID: state.requesterID,
      responderID: state.responderID,
      status: status,
      expiresAt: state.expiresAt
    )
    return ChatRequestDecisionResult(
      requestID: requestID,
      status: status.rawValue,
      directChatRoomID: action == .accept ? roomUUID : nil
    )
  }

  // MARK: Partner Ward

  func fetchMatch(id: UUID) async throws -> ProductionMatchDetail {
    ProductionMatchDetail(
      id: matchUUID,
      partnerID: partnerUUID,
      partner: MatchDetailPartner(nickname: "Aoi"),
      status: "partner_chat_started",
      foxConversationID: nil,
      partnerFoxChatID: roomUUID
    )
  }

  func fetchConversation(id: UUID) async throws -> FoxConversationSummary {
    throw APIClientError.invalidState
  }

  func fetchMessages(conversationID: UUID, limit: Int) async throws -> FoxConversationMessagesPayload {
    throw APIClientError.invalidState
  }

  func startConversation(matchID: UUID) async throws -> FoxConversationStartResult {
    throw APIClientError.invalidState
  }

  func fetchPartnerChat(id: UUID) async throws -> PartnerFoxChatDetail {
    guard id == roomUUID else { throw APIClientError.notFound }
    return PartnerFoxChatDetail(
      id: roomUUID,
      matchID: matchUUID,
      userID: ownerUUID,
      partnerUserID: partnerUUID,
      createdAt: fixtureDate,
      partner: MatchDetailPartner(nickname: "Aoi")
    )
  }

  func fetchPartnerMessages(chatID: UUID) async throws -> PartnerFoxMessagesPayload {
    guard chatID == roomUUID else { throw APIClientError.notFound }
    return PartnerFoxMessagesPayload(messages: partnerMessages)
  }

  func startPartnerChat(matchID: UUID) async throws -> PartnerFoxChatStartResult {
    guard matchID == matchUUID else { throw APIClientError.notFound }
    return PartnerFoxChatStartResult(
      id: roomUUID,
      matchID: matchUUID,
      partner: MatchDetailPartner(nickname: "Aoi"),
      firstMessage: partnerMessages[0]
    )
  }

  func sendPartnerMessage(chatID: UUID, content: String) async throws -> PartnerFoxMessageSendResult {
    guard chatID == roomUUID else { throw APIClientError.notFound }
    partnerSendSequence += 1
    let user = PartnerFoxMessage(
      id: UUID(uuidString: "99999999-9999-4999-8999-\(String(format: "%012d", partnerSendSequence))")!,
      role: .user,
      content: content,
      createdAt: fixtureDate.addingTimeInterval(60)
    )
    let fox = PartnerFoxMessage(
      id: UUID(uuidString: "88888888-8888-4888-8888-\(String(format: "%012d", partnerSendSequence))")!,
      role: .fox,
      content: "その気持ちをもう少し聞かせてください。",
      createdAt: fixtureDate.addingTimeInterval(61)
    )
    partnerMessages.append(contentsOf: [user, fox])
    return PartnerFoxMessageSendResult(userMessage: user, foxMessage: fox)
  }
}

struct DebugNativeBusyCalendarProvider: NativeBusyCalendarProvider {
  let authorization: NativeCalendarAuthorization

  func requestAccess(userConfirmedSharing: Bool) async -> NativeCalendarAuthorization {
    userConfirmedSharing ? authorization : .notRequested
  }

  func readBusy(window: MeetupAvailability) async throws -> NativeBusyCalendarPayload {
    guard authorization == .granted else { throw NativeCalendarPrivacyError.denied }
    return NativeBusyCalendarPayload(window: window, busy: [])
  }

  func revoke() {}
}
#endif
