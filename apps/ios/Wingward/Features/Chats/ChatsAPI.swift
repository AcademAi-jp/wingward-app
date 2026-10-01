import Foundation

protocol DirectChatsAPI: Sendable {
  func advanceJudgeCounterpart(matchID: UUID, operation: JudgeCounterpartOperation, expectedRevision: Int, idempotencyKey: UUID) async throws -> JudgeCounterpartAdvanceResult
  func fetchDirectChats() async throws -> [DirectChatSummary]
  func fetchDirectMessages(
    roomID: UUID,
    limit: Int,
    cursor: String?
  ) async throws -> DirectChatMessagesPayload
  func sendDirectMessage(roomID: UUID, content: String) async throws -> DirectChatSendResult
  func sendDirectMessage(roomID: UUID, content: String, idempotencyKey: UUID) async throws -> DirectChatSendResult
  func recoverDirectMessageSend(
    roomID: UUID,
    idempotencyKey: UUID,
    contentSHA256: String
  ) async throws -> DirectChatSendRecoveryResult
  func markDirectMessageRead(roomID: UUID, messageID: UUID) async throws -> DirectChatReadResult

  func fetchChatRequests() async throws -> [ChatRequestSummary]
  func fetchChatRequestState(matchID: UUID) async throws -> ChatRequestMatchState?
  func createChatRequest(matchID: UUID) async throws -> ChatRequestCreateResult
  func respondToChatRequest(
    requestID: UUID,
    action: ChatRequestAction
  ) async throws -> ChatRequestDecisionResult

  func fetchChatMeetup(roomID: UUID) async throws -> ChatMeetupState
  func performChatMeetupAction(
    roomID: UUID,
    expectedRevision: Int,
    expectedOwnRevision: Int,
    action: ChatMeetupAction,
    idempotencyKey: UUID
  ) async throws -> ChatMeetupState
  func fetchWardConversation(roomID: UUID, limit: Int, cursor: String?) async throws -> ChatMeetupWardConversationPayload
  func fetchMeetupReflection(meetupID: UUID) async throws -> ChatMeetupReflectionSnapshot
  func bootstrapMeetupReflection(meetupID: UUID, voice: RealtimeVoice) async throws -> RealtimeVoiceBootstrap
  func fetchMeetupReflectionCall(meetupID: UUID, sdp: String, voice: RealtimeVoice) async throws -> BoundedRealtimeCallAnswer
  func stopMeetupReflectionCall(meetupID: UUID) async throws
  func draftMeetupReflection(meetupID: UUID, statements: [ChatMeetupReflectionUserStatement]) async throws -> ChatMeetupReflectionDraft
  func confirmMeetupReflection(
    meetupID: UUID,
    expectedVersion: Int,
    traits: [ChatMeetupReflectionTrait],
    idempotencyKey: UUID
  ) async throws -> ChatMeetupReflectionConfirmation
}

extension DirectChatsAPI {
  func advanceJudgeCounterpart(matchID: UUID, operation: JudgeCounterpartOperation, expectedRevision: Int, idempotencyKey: UUID) async throws -> JudgeCounterpartAdvanceResult { throw APIClientError.invalidState }
  func fetchMeetupReflectionCall(meetupID: UUID, sdp: String, voice: RealtimeVoice) async throws -> BoundedRealtimeCallAnswer { throw APIClientError.invalidState }
  func stopMeetupReflectionCall(meetupID: UUID) async throws { throw APIClientError.invalidState }
  func sendDirectMessage(
    roomID: UUID,
    content: String,
    idempotencyKey: UUID
  ) async throws -> DirectChatSendResult {
    try await sendDirectMessage(roomID: roomID, content: content)
  }

  func recoverDirectMessageSend(
    roomID: UUID,
    idempotencyKey: UUID,
    contentSHA256: String
  ) async throws -> DirectChatSendRecoveryResult {
    throw APIClientError.invalidState
  }

  /// Existing non-live fixtures can compile without silently claiming there
  /// is no request. A caller that needs to make a request must fail closed
  /// until its API implements this state lookup.
  func fetchChatRequestState(matchID: UUID) async throws -> ChatRequestMatchState? {
    throw APIClientError.invalidResponse
  }

  func fetchChatMeetup(roomID: UUID) async throws -> ChatMeetupState {
    throw APIClientError.invalidState
  }

  func performChatMeetupAction(
    roomID: UUID,
    expectedRevision: Int,
    expectedOwnRevision: Int,
    action: ChatMeetupAction,
    idempotencyKey: UUID
  ) async throws -> ChatMeetupState {
    throw APIClientError.invalidState
  }

  func fetchWardConversation(roomID: UUID, limit: Int, cursor: String?) async throws -> ChatMeetupWardConversationPayload {
    throw APIClientError.invalidState
  }

  func fetchMeetupReflection(meetupID: UUID) async throws -> ChatMeetupReflectionSnapshot {
    throw APIClientError.invalidState
  }

  func bootstrapMeetupReflection(meetupID: UUID, voice: RealtimeVoice) async throws -> RealtimeVoiceBootstrap {
    throw APIClientError.invalidState
  }

  func draftMeetupReflection(meetupID: UUID, statements: [ChatMeetupReflectionUserStatement]) async throws -> ChatMeetupReflectionDraft {
    throw APIClientError.invalidState
  }

  func confirmMeetupReflection(
    meetupID: UUID,
    expectedVersion: Int,
    traits: [ChatMeetupReflectionTrait],
    idempotencyKey: UUID
  ) async throws -> ChatMeetupReflectionConfirmation {
    throw APIClientError.invalidState
  }
}

enum ChatRequestAction: String, Encodable, Sendable {
  case accept
  case decline
}

struct LiveDirectChatsAPI: DirectChatsAPI, Sendable {
  let client: any AuthenticatedAPIClientProtocol

  static let directChatsPath = "/api/direct-chats"
  static let chatRequestsPath = "/api/chat-requests"

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

  func fetchDirectChats() async throws -> [DirectChatSummary] {
    let payload = try await client.get(Self.directChatsPath, as: DirectChatListPayload.self)
    return payload.chats
  }

  func fetchDirectMessages(
    roomID: UUID,
    limit: Int = 50,
    cursor: String? = nil
  ) async throws -> DirectChatMessagesPayload {
    let boundedLimit = min(max(limit, 1), 100)
    var path = Self.directMessagesPath(for: roomID, limit: boundedLimit)
    if let cursor, !cursor.isEmpty {
      guard let encodedCursor = Self.encodeQueryValue(cursor) else {
        throw APIClientError.invalidRequest
      }
      path += "&cursor=\(encodedCursor)"
    }
    return try await client.get(path, as: DirectChatMessagesPayload.self)
  }

  func sendDirectMessage(roomID: UUID, content: String) async throws -> DirectChatSendResult {
    try await sendDirectMessage(roomID: roomID, content: content, idempotencyKey: UUID())
  }

  func sendDirectMessage(
    roomID: UUID,
    content: String,
    idempotencyKey: UUID
  ) async throws -> DirectChatSendResult {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      content.count <= 1_000
    else {
      throw APIClientError.invalidRequest
    }
    let request = try APIRequest.json(
      method: .post,
      path: Self.directMessagesPath(for: roomID, limit: nil),
      body: DirectMessageRequest(
        content: content,
        idempotencyKey: idempotencyKey.uuidString.lowercased()
      )
    )
    return try await client.send(request, as: DirectChatSendResult.self)
  }

  func recoverDirectMessageSend(
    roomID: UUID,
    idempotencyKey: UUID,
    contentSHA256: String
  ) async throws -> DirectChatSendRecoveryResult {
    guard contentSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
      throw APIClientError.invalidRequest
    }
    let request = try APIRequest.json(
      method: .post,
      path: Self.directMessageSendRecoveryPath(roomID: roomID),
      body: DirectMessageSendRecoveryRequest(
        idempotencyKey: idempotencyKey.uuidString.lowercased(),
        contentSHA256: contentSHA256
      )
    )
    let result = try await client.send(request, as: DirectChatSendRecoveryResult.self)
    try DirectChatSendRecoveryResult.validate(result)
    return result
  }

  func markDirectMessageRead(roomID: UUID, messageID: UUID) async throws -> DirectChatReadResult {
    try await client.put(
      Self.directMessageReadPath(roomID: roomID, messageID: messageID),
      as: DirectChatReadResult.self
    )
  }

  func fetchChatRequests() async throws -> [ChatRequestSummary] {
    let payload = try await client.get(Self.chatRequestsPath, as: ChatRequestListPayload.self)
    return payload.requests
  }

  func fetchChatRequestState(matchID: UUID) async throws -> ChatRequestMatchState? {
    let payload = try await client.get(
      Self.chatRequestMatchPath(for: matchID),
      as: ChatRequestMatchStatePayload.self
    )
    guard payload.request == nil || payload.request?.matchID == matchID else {
      throw APIClientError.invalidResponse
    }
    return payload.request
  }

  func createChatRequest(matchID: UUID) async throws -> ChatRequestCreateResult {
    let request = try APIRequest.json(
      method: .post,
      path: Self.chatRequestsPath,
      body: MatchIDRequest(matchID: matchID)
    )
    let result = try await client.send(request, as: ChatRequestCreateResult.self)
    guard result.matchID == matchID else { throw APIClientError.invalidResponse }
    return result
  }

  func respondToChatRequest(
    requestID: UUID,
    action: ChatRequestAction
  ) async throws -> ChatRequestDecisionResult {
    let request = try APIRequest.json(
      method: .put,
      path: Self.chatRequestPath(for: requestID),
      body: ChatRequestActionRequest(action: action)
    )
    let result = try await client.send(request, as: ChatRequestDecisionResult.self)
    guard result.requestID == requestID else { throw APIClientError.invalidResponse }
    return result
  }

  func advanceJudgeCounterpart(matchID: UUID, operation: JudgeCounterpartOperation, expectedRevision: Int, idempotencyKey: UUID) async throws -> JudgeCounterpartAdvanceResult {
    guard expectedRevision >= 0 else { throw APIClientError.invalidRequest }
    struct Body: Encodable {
      let match_id: String
      let operation: JudgeCounterpartOperation
      let expected_revision: Int
      let idempotency_key: String
    }
    let request = try APIRequest.json(method: .post, path: "/api/judge/counterpart/advance",
      body: Body(match_id: matchID.uuidString.lowercased(), operation: operation,
        expected_revision: expectedRevision, idempotency_key: idempotencyKey.uuidString.lowercased()))
    let value = try await client.send(request, as: JudgeCounterpartAdvanceResult.self)
    guard value.matchID == matchID, value.revision >= expectedRevision else { throw APIClientError.invalidResponse }
    return value
  }

  func fetchChatMeetup(roomID: UUID) async throws -> ChatMeetupState {
    let state = try await client.get(Self.chatMeetupPath(roomID: roomID), as: ChatMeetupState.self)
    guard state.roomID == roomID else { throw APIClientError.invalidResponse }
    return state
  }

  func performChatMeetupAction(
    roomID: UUID,
    expectedRevision: Int,
    expectedOwnRevision: Int,
    action: ChatMeetupAction,
    idempotencyKey: UUID
  ) async throws -> ChatMeetupState {
    guard expectedRevision >= 0, expectedOwnRevision >= 0 else { throw APIClientError.invalidRequest }
    try action.validate()
    let request = try APIRequest.json(
      method: .post,
      path: Self.chatMeetupActionsPath(roomID: roomID),
      body: ChatMeetupActionRequest(
        idempotencyKey: idempotencyKey.uuidString.lowercased(),
        expectedRevision: expectedRevision,
        expectedOwnRevision: expectedOwnRevision,
        action: action
      )
    )
    let state = try await client.send(request, as: ChatMeetupState.self)
    guard state.roomID == roomID,
      state.revision >= expectedRevision,
      state.ownDecisions.privateRevision >= expectedOwnRevision
    else { throw APIClientError.invalidResponse }
    return state
  }

  func fetchWardConversation(roomID: UUID, limit: Int = 30, cursor: String? = nil) async throws -> ChatMeetupWardConversationPayload {
    let boundedLimit = min(max(limit, 1), 100)
    var path = Self.wardConversationPath(roomID: roomID, limit: boundedLimit)
    if let cursor, !cursor.isEmpty {
      guard let encodedCursor = Self.encodeQueryValue(cursor) else { throw APIClientError.invalidRequest }
      path += "&cursor=\(encodedCursor)"
    }
    let payload = try await client.get(path, as: ChatMeetupWardConversationPayload.self)
    guard payload.roomID == roomID else { throw APIClientError.invalidResponse }
    return payload
  }

  func fetchMeetupReflection(meetupID: UUID) async throws -> ChatMeetupReflectionSnapshot {
    let snapshot = try await client.get(Self.meetupReflectionPath(meetupID: meetupID), as: ChatMeetupReflectionSnapshot.self)
    guard snapshot.meetupID == meetupID else { throw APIClientError.invalidResponse }
    return snapshot
  }

  func bootstrapMeetupReflection(meetupID: UUID, voice: RealtimeVoice = .cedar) async throws -> RealtimeVoiceBootstrap {
    let request = try APIRequest.json(
      method: .post,
      path: Self.meetupReflectionBootstrapPath(meetupID: meetupID),
      body: ReflectionBootstrapRequest(voice: voice.rawValue)
    )
    return try await client.send(request, as: RealtimeVoiceBootstrap.self)
  }

  func fetchMeetupReflectionCall(meetupID: UUID, sdp: String, voice: RealtimeVoice) async throws -> BoundedRealtimeCallAnswer {
    struct Body: Encodable { let sdp: String; let voice: RealtimeVoice }
    let request = try APIRequest.json(method: .post,
      path: "/api/meetup-reflections/\(meetupID.uuidString.lowercased())/realtime-call", body: Body(sdp: sdp, voice: voice))
    return try await client.send(request, as: BoundedRealtimeCallAnswer.self)
  }
  func stopMeetupReflectionCall(meetupID: UUID) async throws {
    struct Result: Decodable, Sendable, APIValidatable {
      let closed: Bool
      static func validate(_ value: Self) throws { guard value.closed else { throw APIClientError.invalidResponse } }
    }
    let request = APIRequest(method: .post, path: "/api/meetup-reflections/\(meetupID.uuidString.lowercased())/realtime-stop")
    _ = try await client.send(request, as: Result.self)
  }

  func draftMeetupReflection(meetupID: UUID, statements: [ChatMeetupReflectionUserStatement]) async throws -> ChatMeetupReflectionDraft {
    guard (1...24).contains(statements.count),
      Set(statements.map(\.turnID)).count == statements.count,
      statements.reduce(0, { $0 + $1.text.utf8.count }) <= 8_000
    else { throw APIClientError.invalidRequest }
    for statement in statements { try statement.validate() }
    let request = try APIRequest.json(
      method: .post,
      path: Self.meetupReflectionDraftPath(meetupID: meetupID),
      body: ReflectionDraftRequest(statements: statements)
    )
    return try await client.send(request, as: ChatMeetupReflectionDraft.self)
  }

  func confirmMeetupReflection(
    meetupID: UUID,
    expectedVersion: Int,
    traits: [ChatMeetupReflectionTrait],
    idempotencyKey: UUID
  ) async throws -> ChatMeetupReflectionConfirmation {
    guard expectedVersion >= 0, !traits.isEmpty,
      traits.count <= ChatMeetupReflectionTraitKey.allCases.count,
      Set(traits.map(\.key)).count == traits.count
    else { throw APIClientError.invalidRequest }
    for trait in traits { try ChatMeetupReflectionTrait.validate(trait) }
    let request = try APIRequest.json(
      method: .post,
      path: Self.meetupReflectionConfirmPath(meetupID: meetupID),
      body: ReflectionConfirmRequest(
        idempotencyKey: idempotencyKey.uuidString.lowercased(),
        expectedVersion: expectedVersion,
        ownerConfirmed: true,
        traits: traits
      )
    )
    return try await client.send(request, as: ChatMeetupReflectionConfirmation.self)
  }

  static func chatMeetupPath(roomID: UUID) -> String {
    "/api/chat-meetups/rooms/\(roomID.uuidString.lowercased())"
  }

  static func chatMeetupActionsPath(roomID: UUID) -> String {
    "\(chatMeetupPath(roomID: roomID))/actions"
  }

  static func wardConversationPath(roomID: UUID, limit: Int) -> String {
    "\(chatMeetupPath(roomID: roomID))/ward-conversation?limit=\(min(max(limit, 1), 100))"
  }

  static func meetupReflectionPath(meetupID: UUID) -> String {
    "/api/meetup-reflections/\(meetupID.uuidString.lowercased())"
  }

  static func meetupReflectionBootstrapPath(meetupID: UUID) -> String {
    "\(meetupReflectionPath(meetupID: meetupID))/bootstrap"
  }

  static func meetupReflectionDraftPath(meetupID: UUID) -> String {
    "\(meetupReflectionPath(meetupID: meetupID))/drafts"
  }

  static func meetupReflectionConfirmPath(meetupID: UUID) -> String {
    "\(meetupReflectionPath(meetupID: meetupID))/confirm"
  }

  private struct ChatMeetupActionRequest: Encodable, Sendable {
    let idempotencyKey: String
    let expectedRevision: Int
    let expectedOwnRevision: Int
    let action: ChatMeetupAction
    enum CodingKeys: String, CodingKey {
      case idempotencyKey = "idempotency_key"
      case expectedRevision = "expected_revision"
      case expectedOwnRevision = "expected_own_revision"
      case action
    }
  }

  private struct ReflectionBootstrapRequest: Encodable, Sendable {
    let voice: String
  }

  private struct ReflectionDraftRequest: Encodable, Sendable {
    let statements: [ChatMeetupReflectionUserStatement]
  }

  private struct ReflectionConfirmRequest: Encodable, Sendable {
    let idempotencyKey: String
    let expectedVersion: Int
    let ownerConfirmed: Bool
    let traits: [ChatMeetupReflectionTrait]
    enum CodingKeys: String, CodingKey {
      case idempotencyKey = "idempotency_key"
      case expectedVersion = "expected_version"
      case ownerConfirmed = "owner_confirmed"
      case traits
    }
  }

  static func directMessagesPath(for roomID: UUID, limit: Int?) -> String {
    let base = "/api/direct-chats/\(roomID.uuidString.lowercased())/messages"
    guard let limit else { return base }
    return "\(base)?limit=\(limit)"
  }

  static func directMessageSendRecoveryPath(roomID: UUID) -> String {
    "/api/direct-chats/\(roomID.uuidString.lowercased())/messages/send-recovery"
  }

  static func directMessageReadPath(roomID: UUID, messageID: UUID) -> String {
    "/api/direct-chats/\(roomID.uuidString.lowercased())/messages/\(messageID.uuidString.lowercased())/read"
  }

  static func chatRequestPath(for requestID: UUID) -> String {
    "\(Self.chatRequestsPath)/\(requestID.uuidString.lowercased())"
  }

  static func chatRequestMatchPath(for matchID: UUID) -> String {
    "\(Self.chatRequestsPath)/by-match/\(matchID.uuidString.lowercased())"
  }

  private static func encodeQueryValue(_ value: String) -> String? {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed)
  }
}

private struct DirectChatListPayload: Decodable, Sendable, APIValidatable {
  let chats: [DirectChatSummary]

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    chats = try container.decode([DirectChatSummary].self)
  }

  static func validate(_ value: DirectChatListPayload) throws {
    var IDs = Set<UUID>()
    for chat in value.chats {
      guard IDs.insert(chat.id).inserted else { throw ChatsDTOValidationError.invalidValue }
      try DirectChatSummary.validate(chat)
    }
  }
}

private struct ChatRequestListPayload: Decodable, Sendable, APIValidatable {
  let requests: [ChatRequestSummary]

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    requests = try container.decode([ChatRequestSummary].self)
  }

  static func validate(_ value: ChatRequestListPayload) throws {
    var IDs = Set<UUID>()
    for request in value.requests {
      guard IDs.insert(request.id).inserted else { throw ChatsDTOValidationError.invalidValue }
      try ChatRequestSummary.validate(request)
    }
  }
}

private struct ChatRequestMatchStatePayload: Decodable, Sendable, APIValidatable {
  let request: ChatRequestMatchState?

  enum CodingKeys: String, CodingKey { case request }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    request = try container.decode(ChatRequestMatchState?.self, forKey: .request)
  }

  static func validate(_ value: ChatRequestMatchStatePayload) throws {
    if let request = value.request {
      try ChatRequestMatchState.validate(request)
    }
  }
}

private struct MatchIDRequest: Encodable, Sendable {
  let matchID: UUID

  enum CodingKeys: String, CodingKey {
    case matchID = "match_id"
  }
}

private struct DirectMessageRequest: Encodable, Sendable {
  let content: String
  let idempotencyKey: String

  enum CodingKeys: String, CodingKey {
    case content
    case idempotencyKey = "idempotency_key"
  }
}

private struct DirectMessageSendRecoveryRequest: Encodable, Sendable {
  let idempotencyKey: String
  let contentSHA256: String

  enum CodingKeys: String, CodingKey {
    case idempotencyKey = "idempotency_key"
    case contentSHA256 = "content_sha256"
  }
}

private struct ChatRequestActionRequest: Encodable, Sendable {
  let action: ChatRequestAction
}

protocol DirectChatsAPIFactory: Sendable {
  func make(ownerID: String) -> (any DirectChatsAPI)?
}

struct LiveDirectChatsAPIFactory: DirectChatsAPIFactory, Sendable {
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

  func make(ownerID: String) -> (any DirectChatsAPI)? {
    try? LiveDirectChatsAPI(
      baseURL: baseURL,
      ownerID: ownerID,
      authService: authService,
      profileAPI: profileAPI,
      transport: transport
    )
  }
}

// Short aliases keep the feature name ergonomic for shared navigation while
// preserving the explicit DirectChats names used by the route contract.
typealias ChatsAPI = DirectChatsAPI
typealias ChatsAPIFactory = DirectChatsAPIFactory
typealias LiveChatsAPI = LiveDirectChatsAPI
typealias LiveChatsAPIFactory = LiveDirectChatsAPIFactory

struct BoundedMeetupReflectionCallAPI: BoundedRealtimeCallAPI {
  let api: any DirectChatsAPI
  let meetupID: UUID
  func fetchRealtimeCall(sessionID: UUID, sdp: String, voice: RealtimeVoice) async throws -> BoundedRealtimeCallAnswer {
    guard sessionID == meetupID else { throw APIClientError.invalidResponse }
    return try await api.fetchMeetupReflectionCall(meetupID: meetupID, sdp: sdp, voice: voice)
  }
  func stopRealtimeCall(sessionID: UUID) async throws {
    guard sessionID == meetupID else { throw APIClientError.invalidResponse }
    try await api.stopMeetupReflectionCall(meetupID: meetupID)
  }
}
