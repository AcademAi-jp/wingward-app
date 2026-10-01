import Foundation

protocol MatchDetailAPI: Sendable {
  func fetchMatch(id: UUID) async throws -> ProductionMatchDetail
  func fetchConversation(id: UUID) async throws -> FoxConversationSummary
  func fetchMessages(conversationID: UUID, limit: Int) async throws -> FoxConversationMessagesPayload
  func startConversation(matchID: UUID) async throws -> FoxConversationStartResult
  func fetchPartnerChat(id: UUID) async throws -> PartnerFoxChatDetail
  func fetchPartnerMessages(chatID: UUID) async throws -> PartnerFoxMessagesPayload
  func startPartnerChat(matchID: UUID) async throws -> PartnerFoxChatStartResult
  func sendPartnerMessage(chatID: UUID, content: String) async throws -> PartnerFoxMessageSendResult
  func sendPartnerMessage(
    chatID: UUID,
    content: String,
    idempotencyKey: UUID
  ) async throws -> PartnerFoxMessageSendResult
  func recoverPartnerMessageSend(
    chatID: UUID,
    idempotencyKey: UUID,
    contentSHA256: String
  ) async throws -> PartnerFoxMessageSendRecoveryResult
}

extension MatchDetailAPI {
  func sendPartnerMessage(
    chatID: UUID,
    content: String,
    idempotencyKey: UUID
  ) async throws -> PartnerFoxMessageSendResult {
    try await sendPartnerMessage(chatID: chatID, content: content)
  }

  func recoverPartnerMessageSend(
    chatID: UUID,
    idempotencyKey: UUID,
    contentSHA256: String
  ) async throws -> PartnerFoxMessageSendRecoveryResult {
    throw APIClientError.invalidState
  }

  /// Existing compatibility-Ward fixtures can opt into the Partner Ward
  /// surface without gaining a write path. The production implementation
  /// below provides the two read-only routes explicitly.
  func fetchPartnerChat(id: UUID) async throws -> PartnerFoxChatDetail {
    throw APIClientError.invalidState
  }

  func fetchPartnerMessages(chatID: UUID) async throws -> PartnerFoxMessagesPayload {
    throw APIClientError.invalidState
  }

  func startPartnerChat(matchID: UUID) async throws -> PartnerFoxChatStartResult {
    throw APIClientError.invalidState
  }

  func sendPartnerMessage(chatID: UUID, content: String) async throws -> PartnerFoxMessageSendResult {
    throw APIClientError.invalidState
  }

  func startPartnerWard(matchID: UUID) async throws -> PartnerFoxChatStartResult {
    try await startPartnerChat(matchID: matchID)
  }

  func sendPartnerWardMessage(chatID: UUID, content: String) async throws -> PartnerFoxMessageSendResult {
    try await sendPartnerMessage(chatID: chatID, content: content)
  }
}

struct LiveMatchDetailAPI: MatchDetailAPI, Sendable {
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

  func fetchMatch(id: UUID) async throws -> ProductionMatchDetail {
    try await client.get(Self.matchPath(for: id), as: ProductionMatchDetail.self)
  }

  func fetchConversation(id: UUID) async throws -> FoxConversationSummary {
    try await client.get(Self.conversationPath(for: id), as: FoxConversationSummary.self)
  }

  func fetchMessages(conversationID: UUID, limit: Int) async throws -> FoxConversationMessagesPayload {
    let boundedLimit = min(max(limit, 1), 100)
    return try await client.get(
      Self.messagesPath(for: conversationID, limit: boundedLimit),
      as: FoxConversationMessagesPayload.self
    )
  }

  func startConversation(matchID: UUID) async throws -> FoxConversationStartResult {
    let result = try await client.post(
      Self.startConversationPath(for: matchID),
      as: FoxConversationStartResult.self
    )
    guard result.matchID == matchID else {
      throw APIClientError.invalidResponse
    }
    return result
  }

  func fetchPartnerChat(id: UUID) async throws -> PartnerFoxChatDetail {
    try await client.get(Self.partnerChatPath(for: id), as: PartnerFoxChatDetail.self)
  }

  func fetchPartnerMessages(chatID: UUID) async throws -> PartnerFoxMessagesPayload {
    try await client.get(Self.partnerMessagesPath(for: chatID), as: PartnerFoxMessagesPayload.self)
  }

  func startPartnerChat(matchID: UUID) async throws -> PartnerFoxChatStartResult {
    let body = try APIRequest.json(
      method: .post,
      path: Self.partnerChatsPath,
      body: PartnerFoxChatStartRequest(matchID: matchID)
    )
    let result = try await client.send(body, as: PartnerFoxChatStartResult.self)
    guard result.matchID == matchID else {
      throw APIClientError.invalidResponse
    }
    return result
  }

  func sendPartnerMessage(chatID: UUID, content: String) async throws -> PartnerFoxMessageSendResult {
    try await sendPartnerMessage(chatID: chatID, content: content, idempotencyKey: UUID())
  }

  func sendPartnerMessage(
    chatID: UUID,
    content: String,
    idempotencyKey: UUID
  ) async throws -> PartnerFoxMessageSendResult {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, content.count <= 2_000 else {
      throw APIClientError.invalidRequest
    }
    let body = try APIRequest.json(
      method: .post,
      path: Self.partnerMessagesPath(for: chatID),
      body: PartnerFoxMessageSendRequest(
        content: content,
        idempotencyKey: idempotencyKey.uuidString.lowercased()
      )
    )
    return try await client.send(body, as: PartnerFoxMessageSendResult.self)
  }

  func recoverPartnerMessageSend(
    chatID: UUID,
    idempotencyKey: UUID,
    contentSHA256: String
  ) async throws -> PartnerFoxMessageSendRecoveryResult {
    guard contentSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
      throw APIClientError.invalidRequest
    }
    let request = try APIRequest.json(
      method: .post,
      path: Self.partnerMessageSendRecoveryPath(chatID: chatID),
      body: PartnerFoxMessageSendRecoveryRequest(
        idempotencyKey: idempotencyKey.uuidString.lowercased(),
        contentSHA256: contentSHA256
      )
    )
    let result = try await client.send(request, as: PartnerFoxMessageSendRecoveryResult.self)
    try PartnerFoxMessageSendRecoveryResult.validate(result)
    return result
  }

  static func matchPath(for id: UUID) -> String {
    "/api/matching/results/\(id.uuidString.lowercased())"
  }

  static func conversationPath(for id: UUID) -> String {
    "/api/fox-conversations/\(id.uuidString.lowercased())"
  }

  static func messagesPath(for id: UUID, limit: Int) -> String {
    "/api/fox-conversations/\(id.uuidString.lowercased())/messages?limit=\(limit)"
  }

  static func startConversationPath(for id: UUID) -> String {
    "/api/matches/\(id.uuidString.lowercased())/fox-conversation"
  }

  static func partnerChatPath(for id: UUID) -> String {
    "/api/partner-fox-chats/\(id.uuidString.lowercased())"
  }

  static let partnerChatsPath = "/api/partner-fox-chats"
  static let startPartnerChatPath = partnerChatsPath

  static func partnerMessagesPath(for id: UUID) -> String {
    "/api/partner-fox-chats/\(id.uuidString.lowercased())/messages"
  }

  static func partnerMessageSendRecoveryPath(chatID: UUID) -> String {
    "/api/partner-fox-chats/\(chatID.uuidString.lowercased())/messages/send-recovery"
  }

  static func sendPartnerMessagePath(for id: UUID) -> String {
    partnerMessagesPath(for: id)
  }
}

private struct PartnerFoxChatStartRequest: Encodable, Sendable {
  let matchID: UUID

  enum CodingKeys: String, CodingKey {
    case matchID = "match_id"
  }
}

private struct PartnerFoxMessageSendRequest: Encodable, Sendable {
  let content: String
  let idempotencyKey: String

  enum CodingKeys: String, CodingKey {
    case content
    case idempotencyKey = "idempotency_key"
  }
}

private struct PartnerFoxMessageSendRecoveryRequest: Encodable, Sendable {
  let idempotencyKey: String
  let contentSHA256: String

  enum CodingKeys: String, CodingKey {
    case idempotencyKey = "idempotency_key"
    case contentSHA256 = "content_sha256"
  }
}

protocol MatchDetailAPIFactory: Sendable {
  func make(ownerID: String) -> (any MatchDetailAPI)?
}

struct LiveMatchDetailAPIFactory: MatchDetailAPIFactory, Sendable {
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

  func make(ownerID: String) -> (any MatchDetailAPI)? {
    try? LiveMatchDetailAPI(
      baseURL: baseURL,
      ownerID: ownerID,
      authService: authService,
      profileAPI: profileAPI,
      transport: transport
    )
  }
}

#if DEBUG
struct DebugMatchDetailAPIFactory: MatchDetailAPIFactory, Sendable {
  private let api: DebugMatchDetailAPI

  init(scenario: DebugMatchesScenario) {
    api = DebugMatchDetailAPI(scenario: scenario)
  }

  func make(ownerID: String) -> (any MatchDetailAPI)? {
    guard ownerID == UserProfile.fixture.id else { return nil }
    return api
  }
}

private actor DebugMatchDetailAPI: MatchDetailAPI {
  private let scenario: DebugMatchesScenario
  private var requestCount = 0
  private var currentMatchID: UUID?
  private var startedMatchIDs: Set<UUID> = []

  init(scenario: DebugMatchesScenario) {
    self.scenario = scenario
  }

  func fetchMatch(id: UUID) async throws -> ProductionMatchDetail {
    requestCount += 1
    switch scenario {
    case .retry where requestCount == 1:
      throw APIClientError.temporarilyUnavailable
    case .loading:
      try await Task.sleep(nanoseconds: 600_000_000_000)
      throw APIClientError.cancelled
    default:
      currentMatchID = id
      let firstMatchID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
      let hasConversation: Bool
      switch scenario {
      case .empty:
        hasConversation = false
      case .pending:
        hasConversation = startedMatchIDs.contains(id)
      default:
        hasConversation = id == firstMatchID
      }
      let statusOverride: String?
      if scenario == .pending {
        statusOverride = hasConversation ? "fox_conversation_in_progress" : "pending"
      } else {
        statusOverride = nil
      }
      return Self.detail(
        id: id,
        hasConversation: hasConversation,
        statusOverride: statusOverride
      )
    }
  }

  func fetchConversation(id: UUID) async throws -> FoxConversationSummary {
    guard let currentMatchID else { throw APIClientError.invalidState }
    return FoxConversationSummary(
      id: id,
      matchID: currentMatchID,
      status: scenario == .pending ? "in_progress" : "completed",
      totalRounds: 2,
      currentRound: scenario == .pending ? 0 : 2,
      startedAt: Self.fixtureDate,
      completedAt: scenario == .pending ? nil : Self.fixtureDate.addingTimeInterval(120)
    )
  }

  func fetchMessages(conversationID: UUID, limit: Int) async throws -> FoxConversationMessagesPayload {
    guard limit <= 100 else { throw APIClientError.invalidRequest }
    return FoxConversationMessagesPayload(messages: [
      FoxConversationMessage(
        id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
        speaker: .myFox,
        content: "今日はどんな時間を過ごしたい？",
        roundNumber: 1,
        createdAt: Self.fixtureDate
      ),
      FoxConversationMessage(
        id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
        speaker: .partnerFox,
        content: "ゆっくり話せる場所を見つけたいです。",
        roundNumber: 2,
        createdAt: Self.fixtureDate.addingTimeInterval(60)
      )
    ])
  }

  func fetchPartnerChat(id: UUID) async throws -> PartnerFoxChatDetail {
    let firstMatchID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    guard scenario != .empty, id == Self.partnerChatID, currentMatchID == firstMatchID else {
      throw APIClientError.notFound
    }
    let ownerID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    let partnerID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    return PartnerFoxChatDetail(
      id: id,
      matchID: firstMatchID,
      userID: ownerID,
      partnerUserID: partnerID,
      createdAt: Self.fixtureDate,
      partner: MatchDetailPartner(nickname: "Aoi")
    )
  }

  func fetchPartnerMessages(chatID: UUID) async throws -> PartnerFoxMessagesPayload {
    guard chatID == Self.partnerChatID else { throw APIClientError.notFound }
    return PartnerFoxMessagesPayload(messages: [
      PartnerFoxMessage(
        id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
        role: .fox,
        content: "ゆっくり話せる場所を見つけたいです。",
        createdAt: Self.fixtureDate
      ),
      PartnerFoxMessage(
        id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
        role: .user,
        content: "私も落ち着いて話せる時間が好きです。",
        createdAt: Self.fixtureDate.addingTimeInterval(60)
      )
    ])
  }

  func startConversation(matchID: UUID) async throws -> FoxConversationStartResult {
    guard scenario == .pending, matchID == currentMatchID else {
      throw APIClientError.invalidState
    }
    startedMatchIDs.insert(matchID)
    return FoxConversationStartResult(
      conversationID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
      matchID: matchID
    )
  }

  func sendPartnerMessage(chatID: UUID, content: String) async throws -> PartnerFoxMessageSendResult {
    _ = try await fetchPartnerChat(id: chatID)
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      content.count <= 2_000
    else { throw APIClientError.invalidRequest }
    return PartnerFoxMessageSendResult(
      userMessage: PartnerFoxMessage(
        id: UUID(), role: .user, content: content, createdAt: Self.fixtureDate
      ),
      foxMessage: PartnerFoxMessage(
        id: UUID(), role: .fox, content: "その気持ちをもう少し聞かせてください。",
        createdAt: Self.fixtureDate.addingTimeInterval(1)
      )
    )
  }

  private static func detail(
    id: UUID,
    hasConversation: Bool,
    statusOverride: String? = nil
  ) -> ProductionMatchDetail {
    let firstMatchID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let isFirst = id == firstMatchID
    return ProductionMatchDetail(
      id: id,
      partnerID: UUID(
        uuidString: isFirst
          ? "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
          : "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      )!,
      partner: MatchDetailPartner(nickname: isFirst ? "Aoi" : "Mina"),
      status: statusOverride ?? (isFirst ? "fox_conversation_completed" : "fox_conversation_in_progress"),
      foxConversationID: hasConversation
        ? UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        : nil,
      partnerFoxChatID: isFirst && hasConversation ? Self.partnerChatID : nil,
      foxSummary: isFirst
        ? "Both Wards value calm, thoughtful conversations."
        : nil
    )
  }

  private static let partnerChatID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

  private static var fixtureDate: Date {
    Date(timeIntervalSince1970: 1_788_451_200)
  }
}
#endif
