import Foundation
import Observation
import CryptoKit

enum MessageSendRetryReceiptKind: String, Codable, Sendable {
  case directChat = "direct_chat"
  case partnerWard = "partner_ward"
}

/// A restart-safe receipt stores only identifiers and a content digest. The
/// message body stays in the user's draft/UI memory and is never written here.
struct MessageSendRetryReceipt: Codable, Equatable, Sendable {
  let kind: MessageSendRetryReceiptKind
  let ownerID: UUID
  let conversationID: UUID
  let idempotencyKey: UUID
  let contentSHA256: String

  static func contentSHA256(for content: String) -> String {
    SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  func matches(kind: MessageSendRetryReceiptKind, ownerID: UUID, conversationID: UUID) -> Bool {
    self.kind == kind && self.ownerID == ownerID && self.conversationID == conversationID
      && contentSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
  }
}

@MainActor
protocol MessageSendRetryReceiptStoring {
  func load(kind: MessageSendRetryReceiptKind, ownerID: UUID, conversationID: UUID) throws -> MessageSendRetryReceipt?
  func save(_ receipt: MessageSendRetryReceipt) throws
  func clear(kind: MessageSendRetryReceiptKind, ownerID: UUID, conversationID: UUID) throws
}

@MainActor
struct KeychainMessageSendRetryReceiptStore: MessageSendRetryReceiptStoring {
  private static let service = "com.wingward.message-send-receipts"
  private static let maximumEncodedBytes = 1_024
  private let storage: KeychainAuthLocalStorage

  init(storage: KeychainAuthLocalStorage = KeychainAuthLocalStorage(service: Self.service)) {
    self.storage = storage
  }

  func load(
    kind: MessageSendRetryReceiptKind,
    ownerID: UUID,
    conversationID: UUID
  ) throws -> MessageSendRetryReceipt? {
    guard let data = try storage.retrieve(key: Self.storageKey(kind: kind, ownerID: ownerID, conversationID: conversationID)) else {
      return nil
    }
    guard data.count <= Self.maximumEncodedBytes,
      let receipt = try? JSONDecoder().decode(MessageSendRetryReceipt.self, from: data),
      receipt.matches(kind: kind, ownerID: ownerID, conversationID: conversationID)
    else {
      throw KeychainStorageError.invalidData
    }
    return receipt
  }

  func save(_ receipt: MessageSendRetryReceipt) throws {
    guard receipt.matches(kind: receipt.kind, ownerID: receipt.ownerID, conversationID: receipt.conversationID),
      let data = try? JSONEncoder().encode(receipt), data.count <= Self.maximumEncodedBytes
    else {
      throw KeychainStorageError.invalidData
    }
    if let current = try load(
      kind: receipt.kind,
      ownerID: receipt.ownerID,
      conversationID: receipt.conversationID
    ), current != receipt {
      throw KeychainStorageError.invalidData
    }
    try storage.store(
      key: Self.storageKey(kind: receipt.kind, ownerID: receipt.ownerID, conversationID: receipt.conversationID),
      value: data
    )
  }

  func clear(kind: MessageSendRetryReceiptKind, ownerID: UUID, conversationID: UUID) throws {
    try storage.remove(key: Self.storageKey(kind: kind, ownerID: ownerID, conversationID: conversationID))
  }

  private static func storageKey(
    kind: MessageSendRetryReceiptKind,
    ownerID: UUID,
    conversationID: UUID
  ) -> String {
    "\(service).\(kind.rawValue).\(ownerID.uuidString.lowercased()).\(conversationID.uuidString.lowercased())"
  }
}

enum DirectChatsStoreError: Error, Equatable, Sendable {
  case unauthenticated
  case ageVerificationRequired
  case forbidden
  case notFound
  case invalidRequest
  case invalidResponse
  case invalidState
  case unresolvedSend
  case rateLimited
  case temporarilyUnavailable
  case cancelled

  var userMessage: String {
    switch self {
    case .ageVerificationRequired:
      return "Verify your age before viewing direct chats."
    case .invalidRequest:
      return "Enter a message up to 1,000 characters."
    case .invalidState:
      return "This chat is no longer available."
    case .unresolvedSend:
      return "Retry the pending message with the same text before sending another one."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .unauthenticated, .forbidden, .notFound, .invalidResponse,
      .temporarilyUnavailable, .cancelled:
      return "We couldn't load direct chats. Try again."
    }
  }

  var sendUserMessage: String {
    switch self {
    case .ageVerificationRequired:
      return "Verify your age before sending a message."
    case .invalidRequest:
      return "Enter a message up to 1,000 characters."
    case .unresolvedSend:
      return "Retry the pending message with the same text before sending another one."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .unauthenticated, .forbidden, .notFound, .invalidResponse,
      .invalidState, .temporarilyUnavailable, .cancelled:
      return "We couldn't send your message. Try again."
    }
  }
}

enum DirectChatsStorePhase: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case failed(DirectChatsStoreError)
}

@MainActor
@Observable
final class DirectChatsStore {
  private(set) var ownerID: String
  private let apiOwnerID: String
  private(set) var phase: DirectChatsStorePhase = .idle
  private(set) var chats: [DirectChatSummary] = []

  private let api: any DirectChatsAPI
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  private var generation = 0

  init(ownerID: String, api: any DirectChatsAPI) {
    self.ownerID = ownerID
    self.apiOwnerID = ownerID
    self.api = api
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    invalidateLoad()
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    chats = []
    guard ownerID == apiOwnerID else {
      phase = .failed(.unauthenticated)
      return Task {}
    }
    phase = .loading

    let task = Task { [weak self] in
      guard let self else { return }
      guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
      do {
        let value = try await api.fetchDirectChats()
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        var IDs = Set<UUID>()
        for chat in value {
          try DirectChatSummary.validate(chat)
          guard IDs.insert(chat.id).inserted else { throw APIClientError.invalidResponse }
        }
        chats = value
        phase = .loaded
        loadTask = nil
      } catch {
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        let mapped = Self.map(error)
        phase = mapped == .cancelled ? .idle : .failed(mapped)
        chats = []
        loadTask = nil
      }
    }
    loadTask = task
    return task
  }

  @discardableResult
  func retry() -> Task<Void, Never> { load() }

  func cancel() {
    invalidateLoad()
    chats = []
    phase = .idle
  }

  func updateOwner(_ newOwnerID: String) {
    guard ownerID != newOwnerID else { return }
    cancel()
    ownerID = newOwnerID
  }

  private func invalidateLoad() {
    loadTask?.cancel()
    loadTask = nil
    generation &+= 1
  }

  private func isCurrent(ownerID: String, generation: Int) -> Bool {
    !Task.isCancelled && self.ownerID == ownerID && self.ownerID == apiOwnerID
      && self.generation == generation
  }

  fileprivate static func map(_ error: Error) -> DirectChatsStoreError {
    if error is APIDTOValidationError || error is ChatsDTOValidationError {
      return .invalidResponse
    }
    guard let clientError = error as? APIClientError else { return .temporarilyUnavailable }
    switch clientError {
    case .unauthenticated: return .unauthenticated
    case .ageVerificationRequired: return .ageVerificationRequired
    case .forbidden: return .forbidden
    case .notFound: return .notFound
    case .invalidRequest: return .invalidRequest
    case .invalidResponse, .invalidURL: return .invalidResponse
    case .invalidState: return .invalidState
    case .rateLimited: return .rateLimited
    case .cancelled: return .cancelled
    case .transportFailure, .temporarilyUnavailable, .quotaExhausted:
      return .temporarilyUnavailable
    }
  }
}

enum DirectChatStorePhase: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case failed(DirectChatsStoreError)
}

/// Owns one direct-chat transcript. Every request captures both the signed-in
/// owner and a generation so a late response cannot repopulate a new room or
/// account after cancellation, logout, or a denied refresh.
private struct DirectChatPendingSend {
  let content: String
  let idempotencyKey: UUID
}

@MainActor
@Observable
final class DirectChatStore {
  private(set) var ownerID: String
  private let apiOwnerID: String
  let roomID: UUID
  private(set) var phase: DirectChatStorePhase = .idle
  private(set) var messages: [DirectChatMessage] = []
  private(set) var nextCursor: String?
  private(set) var hasMore = false
  private(set) var isSending = false
  private(set) var isLoadingMore = false
  private(set) var sendError: DirectChatsStoreError?
  private(set) var lastSentMessageID: UUID?
  private(set) var loadError: DirectChatsStoreError?

  private let api: any DirectChatsAPI
  private let retryReceiptStore: any MessageSendRetryReceiptStoring
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var sendTask: Task<Void, Never>?
  private var generation = 0
  private var pendingSend: DirectChatPendingSend?
  private var retryReceipt: MessageSendRetryReceipt?

  init(
    ownerID: String,
    roomID: UUID,
    api: any DirectChatsAPI,
    retryReceiptStore: (any MessageSendRetryReceiptStoring)? = nil
  ) {
    self.ownerID = ownerID
    self.apiOwnerID = ownerID
    self.roomID = roomID
    self.api = api
    self.retryReceiptStore = retryReceiptStore ?? KeychainMessageSendRetryReceiptStore()
  }

  var canSendMessage: Bool {
    phase == .loaded && !isSending
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    invalidateLoad()
    cancelSendOperation()
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    clearProtectedContent()
    loadError = nil
    guard ownerID == apiOwnerID else {
      loadError = .unauthenticated
      phase = .failed(.unauthenticated)
      return Task {}
    }
    phase = .loading

    let task = Task { [weak self] in
      guard let self else { return }
      guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
      do {
        let ownerUUID = try APIDTOValidation.requireUUID(capturedOwnerID)
        let loadedReceipt = try retryReceiptStore.load(
          kind: .directChat,
          ownerID: ownerUUID,
          conversationID: roomID
        )
        if let loadedReceipt,
          !loadedReceipt.matches(kind: .directChat, ownerID: ownerUUID, conversationID: roomID) {
          throw KeychainStorageError.invalidData
        }
        retryReceipt = loadedReceipt
        let value = try await api.fetchDirectMessages(roomID: roomID, limit: 50, cursor: nil)
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        try validate(value, ownerID: capturedOwnerID)
        messages = value.messages
        nextCursor = value.nextCursor
        hasMore = value.hasMore
        phase = .loaded
        loadTask = nil
        if let loadedReceipt {
          await recoverPendingSend(
            loadedReceipt,
            ownerID: capturedOwnerID,
            ownerUUID: ownerUUID,
            generation: capturedGeneration
          )
        }
      } catch {
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        let mapped = Self.map(error)
        clearProtectedContent()
        loadError = mapped
        phase = mapped == .cancelled ? .idle : .failed(mapped)
        loadTask = nil
      }
    }
    loadTask = task
    return task
  }

  @discardableResult
  func loadMore() -> Task<Void, Never> {
    guard !isLoadingMore, phase == .loaded, hasMore, let cursor = nextCursor else {
      return Task {}
    }
    guard ownerID == apiOwnerID else {
      clearProtectedContent()
      phase = .failed(.unauthenticated)
      return Task {}
    }
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    isLoadingMore = true

    let task = Task { [weak self] in
      guard let self else { return }
      guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
      do {
        let value = try await api.fetchDirectMessages(roomID: roomID, limit: 50, cursor: cursor)
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        try validate(value, ownerID: capturedOwnerID)
        let existingIDs = Set(messages.map(\.id))
        guard value.messages.allSatisfy({ !existingIDs.contains($0.id) }) else {
          throw APIClientError.invalidResponse
        }
        messages = value.messages + messages
        nextCursor = value.nextCursor
        hasMore = value.hasMore
        isLoadingMore = false
      } catch {
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        isLoadingMore = false
        let mapped = Self.map(error)
        if Self.isAuthorizationFailure(mapped) {
          pendingSend = nil
          clearProtectedContent()
          phase = .failed(mapped)
        } else if mapped != .cancelled {
          loadError = mapped
        }
      }
    }
    return task
  }

  @discardableResult
  func sendMessage(_ content: String) -> Task<Void, Never> {
    guard !isSending else { return Task {} }
    lastSentMessageID = nil
    guard ownerID == apiOwnerID else {
      sendError = .unauthenticated
      clearProtectedContent()
      phase = .failed(.unauthenticated)
      return Task {}
    }
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      content.count <= 1_000
    else {
      sendError = .invalidRequest
      return Task {}
    }
    guard phase == .loaded else {
      sendError = .invalidState
      return Task {}
    }

    let attempt: DirectChatPendingSend
    do {
      let ownerUUID = try APIDTOValidation.requireUUID(ownerID)
      if let receipt = try retryReceiptStore.load(
        kind: .directChat,
        ownerID: ownerUUID,
        conversationID: roomID
      ) {
        guard receipt.matches(kind: .directChat, ownerID: ownerUUID, conversationID: roomID),
          receipt.contentSHA256 == MessageSendRetryReceipt.contentSHA256(for: content)
        else {
          retryReceipt = receipt
          sendError = .unresolvedSend
          return Task {}
        }
        retryReceipt = receipt
        attempt = DirectChatPendingSend(content: content, idempotencyKey: receipt.idempotencyKey)
      } else {
        let receipt = MessageSendRetryReceipt(
          kind: .directChat,
          ownerID: ownerUUID,
          conversationID: roomID,
          idempotencyKey: UUID(),
          contentSHA256: MessageSendRetryReceipt.contentSHA256(for: content)
        )
        try retryReceiptStore.save(receipt)
        retryReceipt = receipt
        attempt = DirectChatPendingSend(content: content, idempotencyKey: receipt.idempotencyKey)
      }
      pendingSend = attempt
    } catch {
      sendError = .temporarilyUnavailable
      return Task {}
    }

    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    isSending = true
    sendError = nil
    let task = Task { [weak self] in
      guard let self else { return }
      guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
      do {
        let result = try await api.sendDirectMessage(
          roomID: roomID,
          content: attempt.content,
          idempotencyKey: attempt.idempotencyKey
        )
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        try DirectChatSendResult.validate(result)
        guard result.content == content else { throw APIClientError.invalidResponse }
        let ownerUUID = try APIDTOValidation.requireUUID(capturedOwnerID)
        if let existing = messages.first(where: { $0.id == result.id }) {
          guard existing.senderID == ownerUUID,
            existing.isMine,
            existing.content == result.content
          else {
            throw APIClientError.invalidResponse
          }
        } else {
          messages.append(
            DirectChatMessage(
              id: result.id,
              senderID: ownerUUID,
              isMine: true,
              content: result.content,
              isRead: true,
              createdAt: result.createdAt
            )
          )
        }
        messages.sort { $0.createdAt < $1.createdAt }
        clearRetryReceipt(ownerID: try APIDTOValidation.requireUUID(capturedOwnerID))
        lastSentMessageID = result.id
        isSending = false
        sendTask = nil
      } catch {
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        let mapped = Self.map(error)
        if Self.isAuthorizationFailure(mapped) {
          pendingSend = nil
          clearProtectedContent()
          phase = .failed(mapped)
        } else if mapped != .cancelled {
          sendError = mapped
        }
        isSending = false
        sendTask = nil
      }
    }
    sendTask = task
    return task
  }

  @discardableResult
  func send(_ content: String) -> Task<Void, Never> {
    sendMessage(content)
  }

  @discardableResult
  func markRead(_ message: DirectChatMessage) -> Task<Void, Never> {
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    guard ownerID == apiOwnerID else {
      clearProtectedContent()
      phase = .failed(.unauthenticated)
      return Task {}
    }
    return Task { [weak self] in
      guard let self else { return }
      guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
      do {
        let result = try await api.markDirectMessageRead(roomID: roomID, messageID: message.id)
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        guard result.readCount >= 0 else { throw APIClientError.invalidResponse }
        messages = messages.map { row in
          guard row.id == message.id else { return row }
          return DirectChatMessage(
            id: row.id,
            senderID: row.senderID,
            isMine: row.isMine,
            content: row.content,
            isRead: true,
            createdAt: row.createdAt
          )
        }
      } catch {
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        let mapped = Self.map(error)
        if Self.isAuthorizationFailure(mapped) {
          clearProtectedContent()
          phase = .failed(mapped)
        }
      }
    }
  }

  @discardableResult
  func retry() -> Task<Void, Never> { load() }

  func cancel() {
    invalidateLoad()
    cancelSendOperation()
    clearProtectedContent()
    phase = .idle
  }

  func updateOwner(_ newOwnerID: String) {
    guard ownerID != newOwnerID else { return }
    cancel()
    pendingSend = nil
    ownerID = newOwnerID
  }

  private func validate(_ value: DirectChatMessagesPayload, ownerID: String) throws {
    let ownerUUID = try APIDTOValidation.requireUUID(ownerID)
    try DirectChatMessagesPayload.validate(value, ownerID: ownerUUID)
  }

  private func recoverPendingSend(
    _ receipt: MessageSendRetryReceipt,
    ownerID: String,
    ownerUUID: UUID,
    generation: Int
  ) async {
    let result: DirectChatSendRecoveryResult
    do {
      result = try await api.recoverDirectMessageSend(
        roomID: roomID,
        idempotencyKey: receipt.idempotencyKey,
        contentSHA256: receipt.contentSHA256
      )
    } catch {
      // An absent/unavailable lookup never proves that an earlier POST did
      // not commit. Keep the receipt so the same key is reused on retry.
      return
    }
    guard isCurrent(ownerID: ownerID, generation: generation) else { return }
    do {
      try DirectChatSendRecoveryResult.validate(result)
      guard result.outcome == .found, let recovered = result.message else { return }
      guard MessageSendRetryReceipt.contentSHA256(for: recovered.content) == receipt.contentSHA256 else {
        throw APIClientError.invalidResponse
      }
      if let existing = messages.first(where: { $0.id == recovered.id }) {
        guard existing.senderID == ownerUUID, existing.isMine, existing.content == recovered.content else {
          throw APIClientError.invalidResponse
        }
      } else {
        messages.append(DirectChatMessage(
          id: recovered.id,
          senderID: ownerUUID,
          isMine: true,
          content: recovered.content,
          isRead: true,
          createdAt: recovered.createdAt
        ))
      }
      messages.sort { $0.createdAt < $1.createdAt }
      clearRetryReceipt(ownerID: ownerUUID)
      lastSentMessageID = recovered.id
    } catch {
      loadError = .invalidResponse
    }
  }

  private func clearRetryReceipt(ownerID: UUID) {
    do {
      try retryReceiptStore.clear(kind: .directChat, ownerID: ownerID, conversationID: roomID)
      retryReceipt = nil
      pendingSend = nil
    } catch {
      // Retaining a stale receipt is safe: recovery or a same-key replay will
      // clear it later. Dropping it here could permit a duplicate send.
    }
  }

  private func clearProtectedContent() {
    messages = []
    nextCursor = nil
    hasMore = false
  }

  private func cancelSendOperation() {
    sendTask?.cancel()
    sendTask = nil
    isSending = false
    sendError = nil
    lastSentMessageID = nil
  }

  private func invalidateLoad() {
    loadTask?.cancel()
    loadTask = nil
    generation &+= 1
  }

  private func isCurrent(ownerID: String, generation: Int) -> Bool {
    !Task.isCancelled && self.ownerID == ownerID && self.ownerID == apiOwnerID
      && self.generation == generation
  }

  private static func isAuthorizationFailure(_ error: DirectChatsStoreError) -> Bool {
    switch error {
    case .unauthenticated, .ageVerificationRequired, .forbidden, .notFound:
      return true
    case .invalidRequest, .invalidResponse, .invalidState, .rateLimited,
      .unresolvedSend, .temporarilyUnavailable, .cancelled:
      return false
    }
  }

  fileprivate static func map(_ error: Error) -> DirectChatsStoreError {
    DirectChatsStore.map(error)
  }
}

enum ChatRequestsStorePhase: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case failed(DirectChatsStoreError)
}

enum ChatRequestStatePhase: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case failed(DirectChatsStoreError)
}

@MainActor
@Observable
final class ChatRequestsStore {
  private(set) var ownerID: String
  private let apiOwnerID: String
  private(set) var phase: ChatRequestsStorePhase = .idle
  private(set) var requestStatePhase: ChatRequestStatePhase = .idle
  private(set) var requestStateMatchID: UUID?
  private(set) var requestState: ChatRequestMatchState?
  private(set) var requests: [ChatRequestSummary] = []
  private(set) var isCreating = false
  private(set) var creatingError: DirectChatsStoreError?
  private(set) var lastCreatedRequest: ChatRequestCreateResult?
  private(set) var actionRequestIDs: Set<UUID> = []
  private(set) var actionErrors: [UUID: DirectChatsStoreError] = [:]
  private(set) var lastAcceptedRoomID: UUID?

  private let api: any DirectChatsAPI
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var requestStateTask: Task<Void, Never>?
  private var generation = 0

  init(ownerID: String, api: any DirectChatsAPI) {
    self.ownerID = ownerID
    self.apiOwnerID = ownerID
    self.api = api
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    loadTask?.cancel()
    loadTask = nil
    requestStateTask?.cancel()
    requestStateTask = nil
    generation &+= 1
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    requests = []
    requestStateMatchID = nil
    requestState = nil
    requestStatePhase = .idle
    lastAcceptedRoomID = nil
    guard ownerID == apiOwnerID else {
      phase = .failed(.unauthenticated)
      return Task {}
    }
    phase = .loading
    let task = Task { [weak self] in
      guard let self else { return }
      guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
      do {
        let value = try await api.fetchChatRequests()
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        var IDs = Set<UUID>()
        for request in value {
          try ChatRequestSummary.validate(request)
          guard IDs.insert(request.id).inserted else { throw APIClientError.invalidResponse }
        }
        requests = value
        phase = .loaded
        loadTask = nil
      } catch {
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        let mapped = DirectChatsStore.map(error)
        requests = []
        phase = mapped == .cancelled ? .idle : .failed(mapped)
        loadTask = nil
      }
    }
    loadTask = task
    return task
  }

  @discardableResult
  func loadRequestState(matchID: UUID) -> Task<Void, Never> {
    requestStateTask?.cancel()
    requestStateTask = nil
    requestStateMatchID = matchID
    requestState = nil
    guard ownerID == apiOwnerID, let expectedOwnerID = UUID(uuidString: ownerID) else {
      requestStatePhase = .failed(.unauthenticated)
      return Task {}
    }
    requestStatePhase = .loading
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    let task = Task { [weak self] in
      guard let self else { return }
      guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
      do {
        var value = try await api.fetchChatRequestState(matchID: matchID)
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration),
          requestStateMatchID == matchID
        else { return }
        if let value {
          try ChatRequestMatchState.validate(value)
          guard value.matchID == matchID,
            value.requesterID == expectedOwnerID || value.responderID == expectedOwnerID
          else {
            throw APIClientError.invalidResponse
          }
        }
        if let pending = value, pending.simulatedCounterpart,
          pending.status == .pending, pending.requesterID == expectedOwnerID {
          let advanced = try await api.advanceJudgeCounterpart(matchID: matchID, operation: .accept,
            expectedRevision: 0, idempotencyKey: pending.id)
          guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration), requestStateMatchID == matchID else { return }
          try JudgeCounterpartAdvanceResult.validate(advanced)
          guard advanced.matchID == matchID, let room = advanced.roomID else { throw APIClientError.invalidResponse }
          value = try await api.fetchChatRequestState(matchID: matchID)
          guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration), requestStateMatchID == matchID else { return }
          guard let accepted = value, accepted.matchID == matchID,
            accepted.requesterID == expectedOwnerID, accepted.status == .accepted else { throw APIClientError.invalidResponse }
          try ChatRequestMatchState.validate(accepted)
          lastAcceptedRoomID = room
        }
        requestState = value
        if value != nil { creatingError = nil }
        requestStatePhase = .loaded
        requestStateTask = nil
      } catch {
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration),
          requestStateMatchID == matchID
        else { return }
        let mapped = DirectChatsStore.map(error)
        requestState = nil
        requestStatePhase = mapped == .cancelled ? .idle : .failed(mapped)
        requestStateTask = nil
      }
    }
    requestStateTask = task
    return task
  }

  @discardableResult
  func createRequest(matchID: UUID) -> Task<Void, Never> {
    guard !isCreating else { return Task {} }
    guard ownerID == apiOwnerID else {
      creatingError = .unauthenticated
      return Task {}
    }
    isCreating = true
    creatingError = nil
    lastCreatedRequest = nil
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    let task = Task { [weak self] in
      guard let self else { return }
      guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
      do {
        let result = try await api.createChatRequest(matchID: matchID)
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        guard result.matchID == matchID else { throw APIClientError.invalidResponse }
        lastCreatedRequest = result
        if result.simulatedCounterpart {
          let advanced = try await api.advanceJudgeCounterpart(matchID: matchID, operation: .accept,
            expectedRevision: 0, idempotencyKey: result.id)
          guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
          try JudgeCounterpartAdvanceResult.validate(advanced)
          guard advanced.matchID == matchID, let roomID = advanced.roomID else { throw APIClientError.invalidResponse }
          lastAcceptedRoomID = roomID
        }
        isCreating = false
      } catch {
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        creatingError = DirectChatsStore.map(error)
        isCreating = false
      }
    }
    return task
  }

  @discardableResult
  func respond(to request: ChatRequestSummary, action: ChatRequestAction) -> Task<Void, Never> {
    guard !actionRequestIDs.contains(request.id) else { return Task {} }
    guard ownerID == apiOwnerID else {
      actionErrors[request.id] = .unauthenticated
      return Task {}
    }
    actionRequestIDs.insert(request.id)
    actionErrors[request.id] = nil
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    let task = Task { [weak self] in
      guard let self else { return }
      guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
      do {
        let result = try await api.respondToChatRequest(requestID: request.id, action: action)
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        guard result.requestID == request.id else { throw APIClientError.invalidResponse }
        if action == .accept {
          lastAcceptedRoomID = result.directChatRoomID
        }
        requests.removeAll { $0.id == request.id }
        actionRequestIDs.remove(request.id)
      } catch {
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        actionErrors[request.id] = DirectChatsStore.map(error)
        actionRequestIDs.remove(request.id)
      }
    }
    return task
  }

  @discardableResult
  func retry() -> Task<Void, Never> { load() }

  func cancel() {
    loadTask?.cancel()
    loadTask = nil
    requestStateTask?.cancel()
    requestStateTask = nil
    generation &+= 1
    requests = []
    requestStateMatchID = nil
    requestState = nil
    requestStatePhase = .idle
    actionRequestIDs = []
    actionErrors = [:]
    lastAcceptedRoomID = nil
    isCreating = false
    creatingError = nil
    lastCreatedRequest = nil
    phase = .idle
  }

  func updateOwner(_ newOwnerID: String) {
    guard ownerID != newOwnerID else { return }
    cancel()
    ownerID = newOwnerID
  }

  private func isCurrent(ownerID: String, generation: Int) -> Bool {
    !Task.isCancelled && self.ownerID == ownerID && self.ownerID == apiOwnerID
      && self.generation == generation
  }
}

// MARK: - Chat meetup cards

private struct PendingJudgeCounterpartAction: Sendable {
  let matchID: UUID
  let operation: JudgeCounterpartOperation
  let revision: Int
  let idempotencyKey: UUID
}

private struct PendingChatMeetupAction: Sendable {
  let action: ChatMeetupAction
  let idempotencyKey: UUID
  let expectedRevision: Int
  let expectedOwnRevision: Int
}

@MainActor
@Observable
final class ChatMeetupStore {
  let roomID: UUID
  private(set) var ownerID: String
  private let apiOwnerID: String
  private let api: any DirectChatsAPI
  private let calendarProvider: any NativeBusyCalendarProvider
  private let locationProvider: any NativeMeetupLocationProvider
  private(set) var state: ChatMeetupState?
  private(set) var isLoading = false
  private(set) var isActing = false
  private(set) var errorMessage: String?
  private(set) var noticeMessage: String?
  private(set) var calendarMessage: String?
  private(set) var wardEvents: [ChatMeetupWardConversationEvent] = []
  private(set) var wardHistoryHasMore = false
  private(set) var wardHistoryError: String?
  private(set) var wardHistoryExpanded = false
  private(set) var isLoadingWardHistory = false
  private var wardCursor: String?
  @ObservationIgnored private var pendingJudgeAction: PendingJudgeCounterpartAction?
  @ObservationIgnored private var pendingAction: PendingChatMeetupAction?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var generation = 0

  init(
    ownerID: String,
    roomID: UUID,
    api: any DirectChatsAPI,
    calendarProvider: any NativeBusyCalendarProvider = UnavailableNativeBusyCalendarProvider(),
    locationProvider: any NativeMeetupLocationProvider = UnavailableNativeMeetupLocationProvider()
  ) {
    self.ownerID = ownerID
    self.apiOwnerID = ownerID
    self.roomID = roomID
    self.api = api
    self.calendarProvider = calendarProvider
    self.locationProvider = locationProvider
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    loadTask?.cancel()
    generation &+= 1
    let capturedGeneration = generation
    let capturedOwner = ownerID
    guard capturedOwner == apiOwnerID else {
      errorMessage = "This chat is unavailable."
      return Task {}
    }
    isLoading = true
    errorMessage = nil
    noticeMessage = nil
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let value = try await api.fetchChatMeetup(roomID: roomID)
        guard isCurrent(owner: capturedOwner, generation: capturedGeneration) else { return }
        try ChatMeetupState.validate(value)
        guard value.roomID == roomID else { throw APIClientError.invalidResponse }
        state = value
        isLoading = false
        loadTask = nil
      } catch {
        guard isCurrent(owner: capturedOwner, generation: capturedGeneration) else { return }
        state = nil
        isLoading = false
        errorMessage = Self.safeMessage(error)
        loadTask = nil
      }
    }
    loadTask = task
    return task
  }

  func refresh() async {
    pendingAction = nil
    await load().value
  }

  func perform(_ action: ChatMeetupAction) async {
    guard let state, actionIsAllowed(action, state: state) else {
      errorMessage = state?.ownPermissions.reason?.userMessage ?? "Meetup scheduling is unavailable here."
      return
    }
    guard pendingAction == nil && pendingJudgeAction == nil else {
      errorMessage = "Refresh the meetup card before starting another change."
      return
    }
    do { try action.validate() } catch {
      errorMessage = "That choice could not be used."
      return
    }
    let pending = PendingChatMeetupAction(
      action: action,
      idempotencyKey: UUID(),
      expectedRevision: state.revision,
      expectedOwnRevision: state.ownDecisions.privateRevision
    )
    pendingAction = pending
    await send(pending)
  }

  func retryPendingAction() async {
    if let pendingJudgeAction { await advanceCounterpart(pendingJudgeAction); return }
    guard let pendingAction else { return }
    await send(pendingAction)
  }

  func submitRoughAvailability(weekdays: Bool) async {
    let calendar = Calendar(identifier: .gregorian)
    let now = Date()
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
      let end = calendar.date(byAdding: .day, value: 14, to: tomorrow)
    else {
      errorMessage = "Choose availability again in a moment."
      return
    }
    var slots: [MeetupAvailability] = []
    for dayOffset in 0..<14 {
      guard let date = calendar.date(byAdding: .day, value: dayOffset, to: tomorrow) else { continue }
      let weekday = calendar.component(.weekday, from: date)
      let isWeekend = weekday == 1 || weekday == 7
      guard weekdays ? !isWeekend : isWeekend else { continue }
      let hour = weekdays ? 18 : 13
      let duration = weekdays ? 2 : 3
      guard let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date),
        let finish = calendar.date(byAdding: .hour, value: duration, to: start)
      else { continue }
      slots.append(MeetupAvailability(startsAt: start, endsAt: finish))
    }
    guard !slots.isEmpty else {
      errorMessage = "No rough time blocks were available to share."
      return
    }
    let window = MeetupAvailability(startsAt: tomorrow, endsAt: end)
    await perform(.manualAvailability(window: window, available: slots))
  }

  func clearAvailability() async {
    calendarProvider.revoke()
    let previousRevision = state?.ownDecisions.privateRevision
    await perform(.clearAvailability)
    if errorMessage == nil,
      let previousRevision,
      (state?.ownDecisions.privateRevision ?? previousRevision) > previousRevision {
      calendarMessage = "Your private calendar availability was cleared."
    } else if errorMessage == nil {
      calendarMessage = "Local calendar access was stopped. Refresh to confirm private availability was removed."
    }
  }

  func shareCalendarAvailability(window: MeetupAvailability) async {
    guard let capturedState = state,
      capturedState.status == .awaitingAvailability,
      capturedState.ownPermissions.canSchedule
    else { return }
    let capturedOwner = ownerID
    let capturedGeneration = generation
    let capturedRoom = roomID
    let capturedRevision = capturedState.revision
    let capturedOwnRevision = capturedState.ownDecisions.privateRevision
    calendarMessage = "Calendar sharing includes only busy/free time blocks. Event names, notes and attendees are not sent."
    let authorization = await calendarProvider.requestAccess(userConfirmedSharing: true)
    guard isCurrentRequest(
      owner: capturedOwner, generation: capturedGeneration, room: capturedRoom,
      revision: capturedRevision, ownRevision: capturedOwnRevision
    ) else {
      calendarProvider.revoke()
      return
    }
    guard authorization == .granted else {
      if authorization == .denied {
        calendarMessage = "Calendar access is off. Use the rough availability choices instead."
      } else {
        calendarMessage = "Calendar is not connected here. Use the rough availability choices instead."
      }
      return
    }
    do {
      let payload = try await calendarProvider.readBusy(window: window)
      guard isCurrentRequest(
        owner: capturedOwner, generation: capturedGeneration, room: capturedRoom,
        revision: capturedRevision, ownRevision: capturedOwnRevision
      ) else {
        calendarProvider.revoke()
        return
      }
      guard payload.window == window else { throw NativeCalendarPrivacyError.invalidWindow }
      var projection = try NativeBusyCalendarProjection(window: window)
      for interval in payload.busy {
        try projection.append(interval) { ($0.startsAt, $0.endsAt) }
      }
      let safePayload = projection.payload()
      guard isCurrentRequest(
        owner: capturedOwner, generation: capturedGeneration, room: capturedRoom,
        revision: capturedRevision, ownRevision: capturedOwnRevision
      ) else {
        calendarProvider.revoke()
        return
      }
      await perform(.calendarAvailability(window: safePayload.window, busy: safePayload.busy))
      if errorMessage == nil,
        (state?.ownDecisions.privateRevision ?? capturedOwnRevision) > capturedOwnRevision {
        calendarMessage = "Only busy/free blocks were shared with the private scheduler."
      } else if errorMessage == nil {
        calendarMessage = "Availability was read locally. Refresh the card to confirm the scheduler update."
      }
    } catch {
      guard isCurrentRequest(
        owner: capturedOwner, generation: capturedGeneration, room: capturedRoom,
        revision: capturedRevision, ownRevision: capturedOwnRevision
      ) else {
        calendarProvider.revoke()
        return
      }
      calendarMessage = "Calendar availability could not be read. Use the rough availability choices instead."
    }
  }

  func submitCurrentLocation() async {
    guard let capturedState = state,
      capturedState.needsLocation,
      capturedState.ownPermissions.canSchedule
    else { return }
    let capturedOwner = ownerID
    let capturedGeneration = generation
    let capturedRoom = roomID
    let capturedRevision = capturedState.revision
    let capturedOwnRevision = capturedState.ownDecisions.privateRevision
    do {
      let consent = try await locationProvider.capture(afterUserConsent: true)
      guard isCurrentRequest(
        owner: capturedOwner, generation: capturedGeneration, room: capturedRoom,
        revision: capturedRevision, ownRevision: capturedOwnRevision
      ) else {
        locationProvider.revoke()
        return
      }
      let fields = try consent.privateRequestFields(asOf: Date())
      guard isCurrentRequest(
        owner: capturedOwner, generation: capturedGeneration, room: capturedRoom,
        revision: capturedRevision, ownRevision: capturedOwnRevision
      ) else {
        locationProvider.revoke()
        return
      }
      if let latitude = fields.latitude, let longitude = fields.longitude {
        await perform(.currentLocation(
          latitude: latitude,
          longitude: longitude,
          station: fields.station,
          nearestStation: fields.nearestStation,
          expiresAt: fields.expiresAt,
          nearbyStations: []
        ))
      } else if let station = fields.station {
        await perform(.stationLocation(name: station, expiresAt: fields.expiresAt, nearbyStations: []))
      } else {
        errorMessage = "A current location could not be shared."
      }
      locationProvider.revoke()
    } catch {
      locationProvider.revoke()
      guard isCurrentRequest(
        owner: capturedOwner, generation: capturedGeneration, room: capturedRoom,
        revision: capturedRevision, ownRevision: capturedOwnRevision
      ) else { return }
      errorMessage = "Location is unavailable here. You can enter a nearby station instead."
    }
  }

  func shareStation(_ value: String) async {
    let station = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !station.isEmpty, station.count <= 120 else {
      errorMessage = "Enter a nearby station name up to 120 characters."
      return
    }
    await perform(.stationLocation(name: station, expiresAt: nil, nearbyStations: []))
  }

  func clearLocation() async {
    locationProvider.revoke()
    await perform(.clearLocation)
  }

  func toggleWardHistory() async {
    wardHistoryExpanded.toggle()
    if wardHistoryExpanded && wardEvents.isEmpty { await loadWardHistory(reset: true) }
  }

  func loadMoreWardHistory() async {
    guard wardHistoryHasMore, !isLoadingWardHistory else { return }
    await loadWardHistory(reset: false)
  }

  func retryWardHistory() async {
    await loadWardHistory(reset: true)
  }

  func simulateMeeting() async {
    guard let state, state.simulatedCounterpart, state.status == .confirmed,
      let matchID = state.judgeMatchID, !isActing, pendingAction == nil else { return }
    let pending = pendingJudgeAction ?? PendingJudgeCounterpartAction(matchID: matchID,
      operation: .simulateCompletion, revision: state.revision, idempotencyKey: UUID())
    pendingJudgeAction = pending
    await advanceCounterpart(pending)
  }

  func completeMeeting() async {
    await perform(.completeMeeting)
  }

  func cancel() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    pendingAction = nil
    pendingJudgeAction = nil
    isLoading = false
    isActing = false
    state = nil
    errorMessage = nil
    noticeMessage = nil
    calendarMessage = nil
    wardEvents = []
    wardCursor = nil
    wardHistoryHasMore = false
    wardHistoryError = nil
    wardHistoryExpanded = false
    isLoadingWardHistory = false
    locationProvider.revoke()
    calendarProvider.revoke()
  }

  private func send(_ pending: PendingChatMeetupAction) async {
    guard !isActing, let current = state else { return }
    let capturedOwner = ownerID
    let capturedGeneration = generation
    isActing = true
    errorMessage = nil
    noticeMessage = nil
    do {
      let value = try await api.performChatMeetupAction(
        roomID: roomID,
        expectedRevision: pending.expectedRevision,
        expectedOwnRevision: pending.expectedOwnRevision,
        action: pending.action,
        idempotencyKey: pending.idempotencyKey
      )
      guard isCurrent(owner: capturedOwner, generation: capturedGeneration) else { return }
      try ChatMeetupState.validate(value)
      guard value.roomID == roomID,
        value.revision >= pending.expectedRevision,
        value.ownDecisions.privateRevision >= pending.expectedOwnRevision
      else { throw APIClientError.invalidResponse }
      state = value
      pendingAction = nil
      isActing = false
      if pending.action == .cancel { noticeMessage = "Meetup cancelled for both people." }
      if value.simulatedCounterpart, let matchID = value.judgeMatchID {
        let operation: JudgeCounterpartOperation?
        switch pending.action {
        case .intent(.yes): operation = .intent
        case .manualAvailability, .calendarAvailability: operation = .availability
        case .approveTime: operation = .timeApprove
        default: operation = nil
        }
        if let operation {
          let peer = PendingJudgeCounterpartAction(matchID: matchID, operation: operation,
            revision: value.revision, idempotencyKey: pending.idempotencyKey)
          pendingJudgeAction = peer
          await advanceCounterpart(peer)
        }
      }
    } catch let error as APIClientError where error == .invalidState {
      guard isCurrent(owner: capturedOwner, generation: capturedGeneration) else { return }
      pendingAction = nil
      isActing = false
      do {
        let refreshed = try await api.fetchChatMeetup(roomID: roomID)
        guard isCurrent(owner: capturedOwner, generation: capturedGeneration) else { return }
        try ChatMeetupState.validate(refreshed)
        guard refreshed.roomID == roomID else { throw APIClientError.invalidResponse }
        state = refreshed
        noticeMessage = "The meetup changed. The latest private state has been refreshed. Review it before trying again."
      } catch {
        errorMessage = "The meetup changed. Refresh this card before trying again."
      }
    } catch {
      guard isCurrent(owner: capturedOwner, generation: capturedGeneration) else { return }
      isActing = false
      errorMessage = "That change could not be saved. Retry the same choice or refresh this card."
    }
    _ = current
  }

  private func advanceCounterpart(_ pending: PendingJudgeCounterpartAction) async {
    guard !isActing, let before = state, before.simulatedCounterpart,
      before.judgeMatchID == pending.matchID else { return }
    let capturedOwner = ownerID
    let capturedGeneration = generation
    isActing = true
    errorMessage = nil
    do {
      let result = try await api.advanceJudgeCounterpart(matchID: pending.matchID,
        operation: pending.operation, expectedRevision: pending.revision, idempotencyKey: pending.idempotencyKey)
      guard isCurrent(owner: capturedOwner, generation: capturedGeneration) else { return }
      try JudgeCounterpartAdvanceResult.validate(result)
      guard result.matchID == pending.matchID, result.roomID == roomID,
        result.revision >= pending.revision,
        before.meetupID == nil || before.meetupID == result.meetupID else { throw APIClientError.invalidResponse }
      let latest = try await api.fetchChatMeetup(roomID: roomID)
      guard isCurrent(owner: capturedOwner, generation: capturedGeneration) else { return }
      try ChatMeetupState.validate(latest)
      guard latest.roomID == roomID, latest.simulatedCounterpart,
        latest.judgeMatchID == pending.matchID, latest.revision >= result.revision else { throw APIClientError.invalidResponse }
      state = latest
      pendingJudgeAction = nil
      noticeMessage = pending.operation == .simulateCompletion
        ? "Simulated meetup completed. No real meeting took place."
        : "The fictional counterpart responded for this judge experience."
    } catch {
      guard isCurrent(owner: capturedOwner, generation: capturedGeneration) else { return }
      errorMessage = "The fictional counterpart could not advance. Retry the same choice or refresh."
    }
    isActing = false
  }

  private func loadWardHistory(reset: Bool) async {
    guard !isLoadingWardHistory else { return }
    let capturedOwner = ownerID
    let capturedGeneration = generation
    isLoadingWardHistory = true
    if reset { wardEvents = []; wardCursor = nil; wardHistoryHasMore = false; wardHistoryError = nil }
    do {
      let payload = try await api.fetchWardConversation(roomID: roomID, limit: 50, cursor: wardCursor)
      guard isCurrent(owner: capturedOwner, generation: capturedGeneration) else { return }
      try ChatMeetupWardConversationPayload.validate(payload)
      guard payload.roomID == roomID else { throw APIClientError.invalidResponse }
      let existing = Set(wardEvents.map(\.id))
      wardEvents.append(contentsOf: payload.events.filter { !existing.contains($0.id) })
      wardCursor = payload.nextCursor
      wardHistoryHasMore = payload.hasMore
      wardHistoryError = nil
    } catch {
      guard isCurrent(owner: capturedOwner, generation: capturedGeneration) else { return }
      if reset { wardEvents = [] }
      wardHistoryHasMore = false
      if let apiError = error as? APIClientError, apiError == .notFound {
        wardHistoryError = nil
      } else {
        wardHistoryError = "Ward conversation is unavailable right now. Retry to check again."
      }
    }
    isLoadingWardHistory = false
  }

  private func actionIsAllowed(_ action: ChatMeetupAction, state: ChatMeetupState) -> Bool {
    switch action {
    case .intent:
      return state.ownPermissions.canIntent
    case .calendarAvailability, .manualAvailability:
      return state.ownPermissions.canSchedule && state.status == .awaitingAvailability
    case .clearAvailability:
      return state.ownPermissions.canSchedule && state.status == .awaitingAvailability
    case .approveTime, .currentLocation, .stationLocation, .clearLocation, .approveCafe, .declineCafe:
      return state.ownPermissions.canSchedule
    case .replan:
      return state.ownPermissions.canReplan
    case .cancel:
      return state.ownPermissions.canCancel
    case .completeMeeting:
      return state.ownPermissions.canComplete
    }
  }

  private func isCurrent(owner: String, generation: Int) -> Bool {
    !Task.isCancelled && ownerID == owner && ownerID == apiOwnerID && self.generation == generation
  }

  private func isCurrentRequest(
    owner: String,
    generation: Int,
    room: UUID,
    revision: Int,
    ownRevision: Int
  ) -> Bool {
    isCurrent(owner: owner, generation: generation)
      && roomID == room
      && state?.revision == revision
      && state?.ownDecisions.privateRevision == ownRevision
  }

  private static func safeMessage(_ error: Error) -> String {
    if let apiError = error as? APIClientError {
      switch apiError {
      case .ageVerificationRequired: return "Age verification is required before scheduling."
      case .forbidden: return "This chat is not eligible for meetup scheduling."
      case .notFound, .invalidState: return "Meetup scheduling is not available for this chat."
      case .quotaExhausted: return "Meetup scheduling is temporarily unavailable."
      default: break
      }
    }
    return "Meetup planning is not connected or its status could not be loaded. Human chat is still available."
  }
}

private extension ChatMeetupPermissionReason {
  var userMessage: String {
    switch self {
    case .featureDisabled, .providerUnavailable: "Meetup scheduling is not connected here yet."
    case .identityVerificationRequired: "Age or identity verification is required before scheduling."
    case .eligibilityUnavailable: "This chat is not eligible for meetup scheduling."
    case .quotaExhausted: "Meetup scheduling is temporarily unavailable."
    case .notParticipant, .terminalState: "Meetup scheduling is not available for this chat."
    }
  }
}

// MARK: - Owner-private Ward reflection

private enum ChatMeetupReflectionFinishReason {
  case ended
  case timeLimit
  case failed
}

enum ChatMeetupReflectionPhase: Equatable, Sendable {
  case idle
  case bootstrapping
  case interviewing
  case drafting
  case readyToConfirm
  case saving
  case finished
}

@MainActor
@Observable
final class ChatMeetupReflectionStore {
  private(set) var ownerID: String
  private let apiOwnerID: String
  let meetupID: UUID
  private let api: any DirectChatsAPI
  private let transport: any VoiceInterviewTransport
  private let permissionClient: any VoicePermissionClient
  private(set) var phase: ChatMeetupReflectionPhase = .idle
  private(set) var snapshot: ChatMeetupReflectionSnapshot?
  private(set) var draft: ChatMeetupReflectionDraft?
  private(set) var selectedCandidateIDs: Set<UUID> = []
  private(set) var userStatements: [ChatMeetupReflectionUserStatement] = []
  private(set) var errorMessage: String?
  private(set) var statusMessage: String?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var interviewTask: Task<Void, Never>?
  @ObservationIgnored private var interviewDeadlineTask: Task<Void, Never>?
  @ObservationIgnored private var startAttemptInFlight = false
  @ObservationIgnored private var transportStopOperations = 0
  @ObservationIgnored private var pendingConfirmation: (version: Int, traits: [ChatMeetupReflectionTrait], key: UUID)?
  private let deadlineSleeper: @Sendable (Duration) async -> Void

  init(
    ownerID: String,
    meetupID: UUID,
    api: any DirectChatsAPI,
    transport: any VoiceInterviewTransport = UnavailableVoiceInterviewTransport(),
    permissionClient: any VoicePermissionClient = SystemVoicePermissionClient(),
    deadlineSleeper: @escaping @Sendable (Duration) async -> Void = { duration in
      try? await ContinuousClock().sleep(for: duration)
    }
  ) {
    self.ownerID = ownerID
    self.apiOwnerID = ownerID
    self.meetupID = meetupID
    self.api = api
    self.transport = transport is OpenAIRealtimeTransport
      ? OpenAIRealtimeTransport(enabled: transport.isAvailable, serverAPI: BoundedMeetupReflectionCallAPI(api: api, meetupID: meetupID))
      : transport
    self.permissionClient = permissionClient
    self.deadlineSleeper = deadlineSleeper
  }

  func load() async {
    guard ownerID == apiOwnerID else { errorMessage = "Reflection is unavailable."; return }
    let owner = ownerID
    let capturedGeneration = generation
    do {
      let value = try await api.fetchMeetupReflection(meetupID: meetupID)
      guard isCurrent(owner: owner, generation: capturedGeneration) else { return }
      try ChatMeetupReflectionSnapshot.validate(value)
      guard value.meetupID == meetupID else { throw APIClientError.invalidResponse }
      snapshot = value
      errorMessage = nil
    } catch {
      guard isCurrent(owner: owner, generation: capturedGeneration) else { return }
      errorMessage = "Private reflection is unavailable."
    }
  }

  func start() async {
    guard transport.isAvailable else {
      errorMessage = "Private voice reflection is not connected here yet."
      return
    }
    guard phase != .interviewing && phase != .bootstrapping,
      !startAttemptInFlight, transportStopOperations == 0
    else { return }
    startAttemptInFlight = true
    generation &+= 1
    let owner = ownerID
    let capturedGeneration = generation
    let permission = await permissionClient.requestMicrophonePermission()
    guard isCurrent(owner: owner, generation: capturedGeneration) else {
      startAttemptInFlight = false
      return
    }
    guard permission == .granted else {
      startAttemptInFlight = false
      errorMessage = "Microphone access is off. You can leave the reflection card without saving anything."
      return
    }
    phase = .bootstrapping
    errorMessage = nil
    statusMessage = "Starting a private Ward reflection…"
    do {
      let bootstrap = try await api.bootstrapMeetupReflection(meetupID: meetupID, voice: .cedar)
      guard isCurrent(owner: owner, generation: capturedGeneration) else {
        startAttemptInFlight = false
        return
      }
      try RealtimeVoiceBootstrap.validate(bootstrap)
      let request = VoiceInterviewRequest(
        sessionID: bootstrap.sessionID,
        credential: bootstrap.serverBounded ? .serverBoundedRealtime(maxSeconds: bootstrap.maxDurationSeconds)
          : .realtimeSecret(bootstrap.clientSecret, expiresAt: bootstrap.expiresAt),
        overrides: bootstrap.overrides
      )
      try VoiceInterviewRequest.validate(request)

      scheduleInterviewDeadline(owner: owner, generation: capturedGeneration)
      let stream: AsyncThrowingStream<VoiceInterviewEvent, Error>
      do {
        stream = try await transport.start(request)
      } catch {
        cancelInterviewDeadline()
        transportStopOperations += 1
        await transport.stop()
        transportStopOperations -= 1
        startAttemptInFlight = false
        guard isCurrent(owner: owner, generation: capturedGeneration) else { return }
        phase = .idle
        errorMessage = "Private voice reflection could not start."
        return
      }

      guard isCurrent(owner: owner, generation: capturedGeneration) else {
        cancelInterviewDeadline()
        transportStopOperations += 1
        await transport.stop()
        transportStopOperations -= 1
        startAttemptInFlight = false
        return
      }
      startAttemptInFlight = false
      phase = .interviewing
      statusMessage = "Only your finalized spoken turns stay temporarily on this screen."
      interviewTask = Task { [weak self] in
        guard let self else { return }
        do {
          for try await event in stream {
            guard isCurrent(owner: owner, generation: capturedGeneration) else { return }
            switch event {
            case .connected:
              statusMessage = "Ward reflection is connected."
            case .speaking:
              break
            case let .transcript(entry):
              try VoiceTranscriptEntry.validate(entry)
              if entry.source == .user {
                guard !userStatements.contains(where: { $0.text == entry.message }) else { continue }
                guard userStatements.count < 24 else {
                  throw VoiceProfileDTOValidationError.invalidTranscript
                }
                let statement = ChatMeetupReflectionUserStatement(turnID: UUID(), text: entry.message)
                try statement.validate()
                guard userStatements.reduce(entry.message.utf8.count) { $0 + $1.text.utf8.count } <= 8_000 else {
                  throw VoiceProfileDTOValidationError.invalidTranscript
                }
                userStatements.append(statement)
              }
            case .ended:
              await finishInterview(
                owner: owner,
                generation: capturedGeneration,
                reason: .ended,
                cancelInterviewTask: false
              )
              return
            }
          }
          guard isCurrent(owner: owner, generation: capturedGeneration) else { return }
          if phase == .interviewing {
            await finishInterview(
              owner: owner,
              generation: capturedGeneration,
              reason: .ended,
              cancelInterviewTask: false
            )
          }
        } catch {
          guard isCurrent(owner: owner, generation: capturedGeneration) else { return }
          await finishInterview(
            owner: owner,
            generation: capturedGeneration,
            reason: .failed,
            cancelInterviewTask: false
          )
        }
      }
    } catch {
      if isCurrent(owner: owner, generation: capturedGeneration) {
        phase = .idle
        errorMessage = "Private voice reflection could not start."
      }
      startAttemptInFlight = false
    }
  }

  func stopAndClear() async {
    generation &+= 1
    cancelInterviewDeadline()
    interviewTask?.cancel()
    interviewTask = nil
    transportStopOperations += 1
    await transport.stop()
    transportStopOperations -= 1
    userStatements = []
    draft = nil
    selectedCandidateIDs = []
    pendingConfirmation = nil
    phase = .idle
    statusMessage = "Private voice notes were cleared from this screen."
  }

  func draftSuggestions() async {
    guard phase != .interviewing, (1...24).contains(userStatements.count),
      Set(userStatements.map(\.turnID)).count == userStatements.count,
      userStatements.reduce(0, { $0 + $1.text.utf8.count }) <= 8_000
    else {
      errorMessage = "Finish speaking before drafting suggestions."
      return
    }
    guard userStatements.allSatisfy({ (try? $0.validate()) != nil }) else {
      userStatements = []
      errorMessage = "The temporary voice notes were cleared because they could not be validated."
      return
    }
    let owner = ownerID
    let capturedGeneration = generation
    phase = .drafting
    errorMessage = nil
    do {
      let sourceTurnIDs = Set(userStatements.map(\.turnID))
      let value = try await api.draftMeetupReflection(meetupID: meetupID, statements: userStatements)
      guard isCurrent(owner: owner, generation: capturedGeneration) else { return }
      try ChatMeetupReflectionDraft.validate(value, sourceTurnIDs: sourceTurnIDs)
      userStatements = []
      draft = value
      selectedCandidateIDs = []
      phase = .readyToConfirm
      statusMessage = "AI suggestions are drafts only. Choose what you want to confirm."
    } catch {
      guard isCurrent(owner: owner, generation: capturedGeneration) else { return }
      userStatements = []
      phase = .idle
      errorMessage = "Draft suggestions were unavailable. Your temporary voice notes were cleared."
    }
  }

  func toggle(_ candidate: ChatMeetupReflectionDraftCandidate) {
    guard let draft else { return }
    if selectedCandidateIDs.contains(candidate.id) {
      selectedCandidateIDs.remove(candidate.id)
    } else {
      let selectedKeys = Set(draft.candidates.filter { selectedCandidateIDs.contains($0.id) }.map(\.key))
      guard !selectedKeys.contains(candidate.key) else { return }
      selectedCandidateIDs.insert(candidate.id)
    }
  }

  func confirmSelected() async {
    guard let draft else { return }
    let choices = draft.candidates.filter { selectedCandidateIDs.contains($0.id) }
    guard !choices.isEmpty else { errorMessage = "Choose at least one draft to confirm."; return }
    let traits = choices.map { ChatMeetupReflectionTrait(key: $0.key, value: $0.value) }
    guard Set(traits.map(\.key)).count == traits.count else { errorMessage = "Choose at most one value per trait."; return }
    let owner = ownerID
    let capturedGeneration = generation
    if let pendingConfirmation,
      pendingConfirmation.version != draft.expectedVersion || pendingConfirmation.traits != traits {
      self.pendingConfirmation = nil
    }
    let pending = pendingConfirmation ?? (draft.expectedVersion, traits, UUID())
    pendingConfirmation = pending
    phase = .saving
    errorMessage = nil
    do {
      let result = try await api.confirmMeetupReflection(
        meetupID: meetupID,
        expectedVersion: pending.version,
        traits: pending.traits,
        idempotencyKey: pending.key
      )
      guard isCurrent(owner: owner, generation: capturedGeneration) else { return }
      try ChatMeetupReflectionConfirmation.validate(result)
      self.draft = nil
      selectedCandidateIDs = []
      pendingConfirmation = nil
      phase = .finished
      statusMessage = "Your chosen reflection was confirmed for you only."
      await load()
    } catch {
      guard isCurrent(owner: owner, generation: capturedGeneration) else { return }
      phase = .readyToConfirm
      errorMessage = "Reflection changed or could not be saved. Refresh before choosing again."
    }
  }

  func cancel() async {
    await stopAndClear()
    generation &+= 1
    snapshot = nil
  }

  private func cancelInterviewDeadline() {
    interviewDeadlineTask?.cancel()
    interviewDeadlineTask = nil
  }

  private func scheduleInterviewDeadline(owner: String, generation: Int) {
    let sleep = deadlineSleeper
    interviewDeadlineTask = Task { [weak self] in
      await sleep(Self.reflectionDurationLimit)
      guard !Task.isCancelled, let self else { return }
      await self.interviewDeadlineReached(owner: owner, generation: generation)
    }
  }

  private func interviewDeadlineReached(owner: String, generation: Int) async {
    guard isCurrent(owner: owner, generation: generation) else { return }
    interviewDeadlineTask = nil
    await finishInterview(
      owner: owner,
      generation: generation,
      reason: .timeLimit,
      cancelInterviewTask: true
    )
  }

  private func finishInterview(
    owner: String,
    generation: Int,
    reason: ChatMeetupReflectionFinishReason,
    cancelInterviewTask: Bool
  ) async {
    guard isCurrent(owner: owner, generation: generation) else { return }
    self.generation &+= 1
    let finishingGeneration = self.generation
    cancelInterviewDeadline()
    if cancelInterviewTask { interviewTask?.cancel() }
    interviewTask = nil

    transportStopOperations += 1
    await transport.stop()
    transportStopOperations -= 1

    guard ownerID == owner, self.generation == finishingGeneration else { return }
    phase = .idle
    switch reason {
    case .ended:
      errorMessage = nil
      statusMessage = "Voice ended. You can draft suggestions from your own words or leave without saving."
    case .timeLimit:
      errorMessage = nil
      statusMessage = "Voice reflection reached its time limit. You can draft suggestions from your own words or leave without saving."
    case .failed:
      errorMessage = "Voice reflection ended. You can retry or leave without saving."
    }
  }

  /// Local monotonic UX ceiling; provider-enforced session limits remain authoritative.
  private static let reflectionDurationLimit = Duration.seconds(180)

  private func isCurrent(owner: String, generation: Int) -> Bool {
    !Task.isCancelled && ownerID == owner && ownerID == apiOwnerID && self.generation == generation
  }
}
