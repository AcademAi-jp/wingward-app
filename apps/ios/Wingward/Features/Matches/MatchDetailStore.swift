import Foundation
import Observation

enum MatchDetailStoreError: Error, Equatable, Sendable {
  case unauthenticated
  case ageVerificationRequired
  case forbidden
  case notFound
  case invalidResponse
  case invalidState
  case conversationNotEligible
  case quotaExhausted
  case rateLimited
  case temporarilyUnavailable
  case cancelled

  var userMessage: String {
    switch self {
    case .ageVerificationRequired:
      return "Verify your age before viewing this match."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .conversationNotEligible:
      return "This Ward conversation is no longer available to start."
    case .quotaExhausted:
      return "Your Ward conversation limit has been reached."
    case .unauthenticated, .forbidden, .notFound, .invalidResponse, .invalidState,
      .temporarilyUnavailable, .cancelled:
      return "We couldn't load this match. Try again."
    }
  }

  var startUserMessage: String {
    switch self {
    case .ageVerificationRequired:
      return "Verify your age before starting this Ward conversation."
    case .conversationNotEligible:
      return "This Ward conversation is no longer available to start."
    case .quotaExhausted:
      return "Your Ward conversation limit has been reached."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .unauthenticated, .forbidden, .notFound, .invalidResponse, .invalidState,
      .temporarilyUnavailable, .cancelled:
      return "We couldn't start this Ward conversation. Try again."
    }
  }
}

enum MatchDetailStorePhase: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case failed(MatchDetailStoreError)
}

@MainActor
@Observable
final class MatchDetailStore {
  private struct LoadedSnapshot: Sendable {
    let detail: ProductionMatchDetail
    let conversation: FoxConversationSummary?
    let messages: [FoxConversationMessage]
    let conversationID: UUID?
  }

  private static let pollingIntervalNanoseconds: UInt64 = 3_000_000_000
  private static let maxPollingAttempts = 20

  private(set) var ownerID: String
  private let apiOwnerID: String
  let matchID: UUID
  private(set) var phase: MatchDetailStorePhase = .idle
  private(set) var detail: ProductionMatchDetail?
  private(set) var conversation: FoxConversationSummary?
  private(set) var messages: [FoxConversationMessage] = []

  private let api: any MatchDetailAPI
  private let sleeper: @Sendable (UInt64) async -> Void
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var startTask: Task<Void, Never>?
  @ObservationIgnored private var partnerStartTask: Task<Void, Never>?
  private var generation = 0
  private var activeConversationID: UUID?
  private(set) var isStartingConversation = false
  private(set) var startError: MatchDetailStoreError?
  private(set) var isStartingPartnerChat = false
  private(set) var partnerStartError: PartnerWardStoreError?

  var canStartConversation: Bool {
    guard phase == .loaded, let detail else { return false }
    return detail.status == "pending" && detail.foxConversationID == nil
  }

  /// Partner Ward can be started only after the compatibility Ward has
  /// completed. The server remains authoritative for pair access and races;
  /// this is only a presentation guard for the loaded detail.
  var canStartPartnerChat: Bool {
    guard phase == .loaded, let detail else { return false }
    guard detail.partnerFoxChatID == nil else { return false }
    return detail.status == "fox_conversation_completed"
      || detail.status == "partner_chat_started"
      || detail.status == "direct_chat_requested"
      || detail.status == "direct_chat_active"
      || detail.status == "meetup_intent"
      || detail.status == "meetup_confirmed"
  }

  init(
    ownerID: String,
    matchID: UUID,
    api: any MatchDetailAPI,
    sleeper: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
      try? await Task.sleep(nanoseconds: nanoseconds)
    }
  ) {
    self.ownerID = ownerID
    self.apiOwnerID = ownerID
    self.matchID = matchID
    self.api = api
    self.sleeper = sleeper
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    cancelStartOperation()
    cancelPartnerStartOperation()
    guard ownerID == apiOwnerID else {
      clearProtectedContent()
      phase = .failed(.unauthenticated)
      return Task {}
    }
    return beginLoad()
  }

  @discardableResult
  private func beginLoad() -> Task<Void, Never> {
    invalidateLoad()
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    clearProtectedContent()
    startError = nil
    partnerStartError = nil
    phase = .loading

    let task = Task { [weak self] in
      guard let self else { return }
      guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
      await self.performLoad(ownerID: capturedOwnerID, generation: capturedGeneration)
    }
    loadTask = task
    return task
  }

  @discardableResult
  func retry() -> Task<Void, Never> {
    load()
  }

  @discardableResult
  func startConversation() -> Task<Void, Never> {
    guard ownerID == apiOwnerID, !isStartingConversation, canStartConversation else {
      return Task {}
    }

    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    isStartingConversation = true
    startError = nil

    let task = Task { [weak self] in
      guard let self else { return }
      guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }

      do {
        let result = try await api.startConversation(matchID: matchID)
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else {
          return
        }
        guard result.matchID == matchID else {
          throw APIClientError.invalidResponse
        }

        let refreshTask = beginLoad()
        let refreshGeneration = generation
        await refreshTask.value

        guard ownerID == capturedOwnerID,
          generation == refreshGeneration,
          !Task.isCancelled
        else { return }
        isStartingConversation = false
        startTask = nil
      } catch {
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else {
          return
        }
        let mapped = Self.mapStart(error)
        if mapped != .cancelled {
          startError = mapped
        }
        isStartingConversation = false
        startTask = nil
      }
    }
    startTask = task
    return task
  }

  @discardableResult
  func startPartnerChat() -> Task<Void, Never> {
    guard ownerID == apiOwnerID, !isStartingPartnerChat, canStartPartnerChat else {
      return Task {}
    }

    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    isStartingPartnerChat = true
    partnerStartError = nil

    let task = Task { [weak self] in
      guard let self else { return }
      guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }

      do {
        let result = try await api.startPartnerChat(matchID: matchID)
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else {
          return
        }
        guard result.matchID == matchID,
          result.partner.displayName == detail?.partner.displayName,
          result.firstMessage.role == .fox
        else {
          throw APIClientError.invalidResponse
        }

        let refreshTask = beginLoad()
        let refreshGeneration = generation
        await refreshTask.value

        guard ownerID == capturedOwnerID,
          generation == refreshGeneration,
          !Task.isCancelled
        else { return }
        isStartingPartnerChat = false
        partnerStartTask = nil
      } catch {
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else {
          return
        }
        let mapped = PartnerWardStore.map(error)
        if mapped != .cancelled {
          partnerStartError = mapped
        }
        isStartingPartnerChat = false
        partnerStartTask = nil
      }
    }
    partnerStartTask = task
    return task
  }

  func cancel() {
    invalidateLoad()
    cancelStartOperation()
    cancelPartnerStartOperation()
    clearProtectedContent()
    phase = .idle
  }

  func updateOwner(_ newOwnerID: String) {
    guard ownerID != newOwnerID else { return }
    cancel()
    ownerID = newOwnerID
  }

  private func clearProtectedContent() {
    detail = nil
    conversation = nil
    messages = []
    activeConversationID = nil
  }

  private func cancelStartOperation() {
    startTask?.cancel()
    startTask = nil
    isStartingConversation = false
    startError = nil
  }

  private func cancelPartnerStartOperation() {
    partnerStartTask?.cancel()
    partnerStartTask = nil
    isStartingPartnerChat = false
    partnerStartError = nil
  }

  private func invalidateLoad() {
    loadTask?.cancel()
    loadTask = nil
    generation &+= 1
  }

  private func isCurrent(
    ownerID: String,
    generation: Int,
    conversationID: UUID? = nil
  ) -> Bool {
    guard !Task.isCancelled, self.ownerID == ownerID, self.ownerID == apiOwnerID,
      self.generation == generation
    else {
      return false
    }
    if let conversationID, self.activeConversationID != conversationID {
      return false
    }
    return true
  }

  private func performLoad(ownerID: String, generation: Int) async {
    do {
      guard var snapshot = try await fetchSnapshot(ownerID: ownerID, generation: generation)
      else { return }
      guard publish(snapshot, ownerID: ownerID, generation: generation) else { return }

      var attempts = 0
      while Self.shouldPoll(snapshot.detail), attempts < Self.maxPollingAttempts {
        await sleeper(Self.pollingIntervalNanoseconds)
        guard isCurrent(ownerID: ownerID, generation: generation) else { return }
        attempts += 1
        guard let refreshedSnapshot = try await fetchSnapshot(
          ownerID: ownerID,
          generation: generation
        ) else { return }
        snapshot = refreshedSnapshot
        guard publish(snapshot, ownerID: ownerID, generation: generation) else { return }
      }

      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      loadTask = nil
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      clearProtectedContent()
      let mapped = Self.map(error)
      phase = mapped == .cancelled ? .idle : .failed(mapped)
      loadTask = nil
    }
  }

  private func fetchSnapshot(
    ownerID: String,
    generation: Int
  ) async throws -> LoadedSnapshot? {
    let fetchedDetail = try await api.fetchMatch(id: matchID)
    guard isCurrent(ownerID: ownerID, generation: generation) else { return nil }
    guard fetchedDetail.id == matchID else { throw APIClientError.invalidResponse }

    guard let conversationID = fetchedDetail.foxConversationID else {
      activeConversationID = nil
      return LoadedSnapshot(
        detail: fetchedDetail,
        conversation: nil,
        messages: [],
        conversationID: nil
      )
    }

    activeConversationID = conversationID
    let fetchedConversation = try await api.fetchConversation(id: conversationID)
    guard isCurrent(ownerID: ownerID, generation: generation) else { return nil }
    guard fetchedConversation.id == conversationID,
      fetchedConversation.matchID == matchID
    else {
      throw APIClientError.invalidResponse
    }

    let fetchedMessages = try await api.fetchMessages(conversationID: conversationID, limit: 100)
    guard isCurrent(
      ownerID: ownerID, generation: generation, conversationID: conversationID
    ) else { return nil }
    return LoadedSnapshot(
      detail: fetchedDetail,
      conversation: fetchedConversation,
      messages: fetchedMessages.messages,
      conversationID: conversationID
    )
  }

  private func publish(
    _ snapshot: LoadedSnapshot,
    ownerID: String,
    generation: Int
  ) -> Bool {
    guard isCurrent(
      ownerID: ownerID,
      generation: generation,
      conversationID: snapshot.conversationID
    ) else {
      return false
    }
    detail = snapshot.detail
    conversation = snapshot.conversation
    messages = snapshot.messages
    phase = .loaded
    return true
  }

  private static func shouldPoll(_ detail: ProductionMatchDetail) -> Bool {
    guard detail.foxConversationID != nil else { return false }
    return detail.status == "pending" || detail.status == "fox_conversation_in_progress"
  }

  private static func map(_ error: Error) -> MatchDetailStoreError {
    guard let clientError = error as? APIClientError else {
      return .temporarilyUnavailable
    }
    switch clientError {
    case .unauthenticated: return .unauthenticated
    case .ageVerificationRequired: return .ageVerificationRequired
    case .forbidden: return .forbidden
    case .notFound: return .notFound
    case .invalidResponse, .invalidRequest, .invalidURL: return .invalidResponse
    case .invalidState: return .invalidState
    case .rateLimited: return .rateLimited
    case .cancelled: return .cancelled
    case .transportFailure, .temporarilyUnavailable, .quotaExhausted:
      return .temporarilyUnavailable
    }
  }

  private static func mapStart(_ error: Error) -> MatchDetailStoreError {
    guard let clientError = error as? APIClientError else {
      return .temporarilyUnavailable
    }
    switch clientError {
    case .unauthenticated: return .unauthenticated
    case .ageVerificationRequired: return .ageVerificationRequired
    case .forbidden: return .forbidden
    case .notFound: return .notFound
    case .invalidResponse, .invalidRequest, .invalidURL: return .invalidResponse
    case .invalidState: return .conversationNotEligible
    case .quotaExhausted: return .quotaExhausted
    case .rateLimited: return .rateLimited
    case .cancelled: return .cancelled
    case .transportFailure, .temporarilyUnavailable:
      return .temporarilyUnavailable
    }
  }
}

enum PartnerWardStoreError: Error, Equatable, Sendable {
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
      return "Verify your age before viewing this Partner Ward conversation."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .invalidRequest:
      return "Enter a message before sending."
    case .unauthenticated, .forbidden, .notFound, .invalidResponse, .invalidState,
      .unresolvedSend,
      .temporarilyUnavailable, .cancelled:
      return "We couldn't load this conversation. Try again."
    }
  }

  var sendUserMessage: String {
    switch self {
    case .invalidRequest:
      return "Enter a message up to 2,000 characters."
    case .unresolvedSend:
      return "Retry the pending message with the same text before sending another one."
    case .ageVerificationRequired:
      return "Verify your age before sending a message."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .unauthenticated, .forbidden, .notFound, .invalidResponse, .invalidState,
      .temporarilyUnavailable, .cancelled:
      return "We couldn't send your message. Try again."
    }
  }

  var startUserMessage: String {
    switch self {
    case .ageVerificationRequired:
      return "Verify your age before starting Partner Ward."
    case .invalidState:
      return "Partner Ward is not available for this match yet."
    case .notFound, .forbidden, .unauthenticated, .invalidResponse,
      .invalidRequest, .unresolvedSend, .temporarilyUnavailable, .cancelled:
      return "We couldn't start Partner Ward. Try again."
    case .rateLimited:
      return "Please wait a moment, then try again."
    }
  }
}

enum PartnerWardStorePhase: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case failed(PartnerWardStoreError)
}

/// Partner Ward history and writes. The selected match and partner IDs are
/// captured by the route and rechecked against the chat detail before any
/// history or message response is published.
private struct PartnerWardPendingSend {
  let content: String
  let idempotencyKey: UUID
}

@MainActor
@Observable
final class PartnerWardStore {
  private(set) var ownerID: String
  private let apiOwnerID: String
  let matchID: UUID
  let partnerID: UUID
  let chatID: UUID
  private(set) var phase: PartnerWardStorePhase = .idle
  private(set) var chat: PartnerFoxChatDetail?
  private(set) var messages: [PartnerFoxMessage] = []

  private let api: any MatchDetailAPI
  private let retryReceiptStore: any MessageSendRetryReceiptStoring
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var sendTask: Task<Void, Never>?
  private var generation = 0
  private var pendingSend: PartnerWardPendingSend?
  private var retryReceipt: MessageSendRetryReceipt?
  private(set) var isSending = false
  private(set) var sendError: PartnerWardStoreError?
  private(set) var lastSentMessageID: UUID?

  var canSendMessage: Bool {
    phase == .loaded && chat != nil && !isSending
  }

  init(
    ownerID: String,
    matchID: UUID,
    partnerID: UUID,
    chatID: UUID,
    api: any MatchDetailAPI,
    retryReceiptStore: (any MessageSendRetryReceiptStoring)? = nil
  ) {
    self.ownerID = ownerID
    self.apiOwnerID = ownerID
    self.matchID = matchID
    self.partnerID = partnerID
    self.chatID = chatID
    self.api = api
    self.retryReceiptStore = retryReceiptStore ?? KeychainMessageSendRetryReceiptStore()
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    cancelSendOperation()
    invalidateLoad()
    guard ownerID == apiOwnerID else {
      clearProtectedContent()
      phase = .failed(.unauthenticated)
      return Task {}
    }
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    clearProtectedContent()
    sendError = nil
    phase = .loading

    let task = Task { [weak self] in
      guard let self else { return }
      guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
      await self.performLoad(ownerID: capturedOwnerID, generation: capturedGeneration)
    }
    loadTask = task
    return task
  }

  @discardableResult
  func retry() -> Task<Void, Never> {
    load()
  }

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

  private func clearProtectedContent() {
    chat = nil
    messages = []
  }

  @discardableResult
  func sendMessage(_ content: String) -> Task<Void, Never> {
    guard !isSending else { return Task {} }
    lastSentMessageID = nil
    guard ownerID == apiOwnerID else {
      sendError = .unauthenticated
      phase = .failed(.unauthenticated)
      clearProtectedContent()
      return Task {}
    }
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      content.count <= 2_000
    else {
      sendError = .invalidRequest
      return Task {}
    }
    guard phase == .loaded, chat != nil else {
      sendError = .invalidState
      return Task {}
    }

    let attempt: PartnerWardPendingSend
    do {
      let ownerUUID = try APIDTOValidation.requireUUID(ownerID)
      if let receipt = try retryReceiptStore.load(
        kind: .partnerWard,
        ownerID: ownerUUID,
        conversationID: chatID
      ) {
        guard receipt.matches(kind: .partnerWard, ownerID: ownerUUID, conversationID: chatID),
          receipt.contentSHA256 == MessageSendRetryReceipt.contentSHA256(for: content)
        else {
          retryReceipt = receipt
          sendError = .unresolvedSend
          return Task {}
        }
        retryReceipt = receipt
        attempt = PartnerWardPendingSend(content: content, idempotencyKey: receipt.idempotencyKey)
      } else {
        let receipt = MessageSendRetryReceipt(
          kind: .partnerWard,
          ownerID: ownerUUID,
          conversationID: chatID,
          idempotencyKey: UUID(),
          contentSHA256: MessageSendRetryReceipt.contentSHA256(for: content)
        )
        try retryReceiptStore.save(receipt)
        retryReceipt = receipt
        attempt = PartnerWardPendingSend(content: content, idempotencyKey: receipt.idempotencyKey)
      }
      pendingSend = attempt
    } catch {
      sendError = .temporarilyUnavailable
      return Task {}
    }

    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    let capturedChatID = chatID
    isSending = true
    sendError = nil

    let task = Task { [weak self] in
      guard let self else { return }
      guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
      do {
        let result = try await api.sendPartnerMessage(
          chatID: capturedChatID,
          content: attempt.content,
          idempotencyKey: attempt.idempotencyKey
        )
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else {
          return
        }
        try PartnerFoxMessageSendResult.validate(result)
        guard result.userMessage.content == content else {
          throw APIClientError.invalidResponse
        }

        if let existingUser = messages.first(where: { $0.id == result.userMessage.id }),
          existingUser != result.userMessage {
          throw APIClientError.invalidResponse
        }
        if let existingFox = messages.first(where: { $0.id == result.foxMessage.id }),
          existingFox != result.foxMessage {
          throw APIClientError.invalidResponse
        }

        let currentHistory = try? await api.fetchPartnerMessages(chatID: capturedChatID)
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else {
          return
        }
        if let currentHistory,
          (try? PartnerFoxMessagesPayload.validate(currentHistory)) != nil,
          currentHistory.messages.contains(where: { $0.id == result.userMessage.id }),
          currentHistory.messages.contains(where: { $0.id == result.foxMessage.id }) {
          messages = currentHistory.messages
        } else {
          if !messages.contains(where: { $0.id == result.userMessage.id }) {
            messages.append(result.userMessage)
          }
          if !messages.contains(where: { $0.id == result.foxMessage.id }) {
            messages.append(result.foxMessage)
          }
        }
        clearRetryReceipt(ownerID: try APIDTOValidation.requireUUID(capturedOwnerID))
        lastSentMessageID = result.foxMessage.id
        isSending = false
        sendTask = nil
      } catch {
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else {
          return
        }
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

  private func performLoad(ownerID: String, generation: Int) async {
    do {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      let expectedOwnerID = try APIDTOValidation.requireUUID(ownerID)
      let loadedReceipt = try retryReceiptStore.load(
        kind: .partnerWard,
        ownerID: expectedOwnerID,
        conversationID: chatID
      )
      if let loadedReceipt,
        !loadedReceipt.matches(kind: .partnerWard, ownerID: expectedOwnerID, conversationID: chatID) {
        throw KeychainStorageError.invalidData
      }
      retryReceipt = loadedReceipt
      let fetchedChat = try await api.fetchPartnerChat(id: chatID)
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      guard fetchedChat.id == chatID,
        fetchedChat.matchID == matchID,
        fetchedChat.userID == expectedOwnerID,
        fetchedChat.partnerUserID == partnerID
      else {
        throw APIClientError.invalidResponse
      }

      let fetchedMessages = try await api.fetchPartnerMessages(chatID: chatID)
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      do {
        try PartnerFoxMessagesPayload.validate(fetchedMessages)
      } catch {
        throw APIClientError.invalidResponse
      }

      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      chat = fetchedChat
      messages = fetchedMessages.messages
      phase = .loaded
      loadTask = nil
      if let loadedReceipt {
        await recoverPendingSend(
          loadedReceipt,
          ownerID: ownerID,
          ownerUUID: expectedOwnerID,
          generation: generation
        )
      }
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      clearProtectedContent()
      let mapped = Self.map(error)
      phase = mapped == .cancelled ? .idle : .failed(mapped)
      loadTask = nil
    }
  }

  private func recoverPendingSend(
    _ receipt: MessageSendRetryReceipt,
    ownerID: String,
    ownerUUID: UUID,
    generation: Int
  ) async {
    let result: PartnerFoxMessageSendRecoveryResult
    do {
      result = try await api.recoverPartnerMessageSend(
        chatID: chatID,
        idempotencyKey: receipt.idempotencyKey,
        contentSHA256: receipt.contentSHA256
      )
    } catch {
      // A missing or unavailable lookup can race the original POST. Keep the
      // receipt and its key; only a completed authoritative pair clears it.
      return
    }
    guard isCurrent(ownerID: ownerID, generation: generation) else { return }
    do {
      try PartnerFoxMessageSendRecoveryResult.validate(result)
      guard result.outcome == .completed,
        let userMessage = result.userMessage,
        let foxMessage = result.foxMessage,
        userMessage.role == .user,
        foxMessage.role == .fox,
        MessageSendRetryReceipt.contentSHA256(for: userMessage.content) == receipt.contentSHA256
      else { return }
      guard userMessage.id != foxMessage.id else { throw APIClientError.invalidResponse }
      for recovered in [userMessage, foxMessage] {
        if let existing = messages.first(where: { $0.id == recovered.id }) {
          guard existing == recovered else { throw APIClientError.invalidResponse }
        } else {
          messages.append(recovered)
        }
      }
      messages.sort { $0.createdAt < $1.createdAt }
      clearRetryReceipt(ownerID: ownerUUID)
      lastSentMessageID = foxMessage.id
    } catch {
      sendError = .invalidResponse
    }
  }

  private func clearRetryReceipt(ownerID: UUID) {
    do {
      try retryReceiptStore.clear(kind: .partnerWard, ownerID: ownerID, conversationID: chatID)
      retryReceipt = nil
      pendingSend = nil
    } catch {
      // Keep the receipt on local storage failure so later recovery cannot
      // accidentally mint a second user message or AI generation.
    }
  }

  static func map(_ error: Error) -> PartnerWardStoreError {
    if error is APIDTOValidationError || error is MatchDetailDTOValidationError {
      return .invalidResponse
    }
    guard let clientError = error as? APIClientError else {
      return .temporarilyUnavailable
    }
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

  private static func isAuthorizationFailure(_ error: PartnerWardStoreError) -> Bool {
    switch error {
    case .unauthenticated, .ageVerificationRequired, .forbidden, .notFound:
      return true
    case .invalidRequest, .invalidResponse, .invalidState, .unresolvedSend, .rateLimited,
      .temporarilyUnavailable, .cancelled:
      return false
    }
  }
}
