import Foundation
import Observation

enum QuizStoreError: Error, Equatable, Sendable {
  case unauthenticated
  case ageVerificationRequired
  case forbidden
  case notFound
  case ownerMismatch
  case invalidResponse
  case invalidState
  case incompleteAnswers
  case invalidSelection
  case duplicateSelection
  case readbackMismatch
  case rateLimited
  case temporarilyUnavailable
  case cancelled

  var userMessage: String {
    switch self {
    case .incompleteAnswers:
      return "Answer every question before saving."
    case .invalidSelection, .duplicateSelection:
      return "Review your answers and try again."
    case .ageVerificationRequired:
      return "Verify your age before saving your answers."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .unauthenticated, .forbidden, .notFound, .ownerMismatch, .invalidResponse,
      .invalidState, .readbackMismatch, .temporarilyUnavailable, .cancelled:
      return "We couldn't save your answers. Try again."
    }
  }
}

enum QuizStorePhase: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case saving
  case failed(QuizStoreError)
}

@MainActor
@Observable
final class QuizStore {
  private(set) var ownerID: String
  private(set) var phase: QuizStorePhase = .idle
  private(set) var questions: [QuizQuestion] = []
  private(set) var draftAnswers: [String: [String]] = [:]
  private(set) var savedAnswers: [String: [String]] = [:]
  private(set) var loadError: QuizStoreError?
  private(set) var saveError: QuizStoreError?
  private(set) var isSaving = false
  private(set) var didSave = false
  private(set) var successRevision = 0

  private let api: any QuizAPI
  private let apiOwnerID: String
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  private var generation = 0

  init(ownerID: String, api: any QuizAPI) {
    self.ownerID = ownerID
    self.apiOwnerID = ownerID
    self.api = api
  }

  var isBusy: Bool {
    phase == .loading || phase == .saving || isSaving
  }

  var canSave: Bool {
    guard ownerID == apiOwnerID, phase == .loaded, !isSaving else { return false }
    do {
      try validateDraft()
      return true
    } catch {
      return false
    }
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    invalidateTasks()
    guard ownerID == apiOwnerID else {
      clearContent()
      loadError = .ownerMismatch
      saveError = nil
      isSaving = false
      phase = .failed(.ownerMismatch)
      return Task {}
    }
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    clearContent()
    phase = .loading
    loadError = nil
    saveError = nil
    isSaving = false
    didSave = false
    successRevision = 0

    let task = Task { [weak self] in
      guard let self else { return }
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
    invalidateTasks()
    clearContent()
    loadError = nil
    saveError = nil
    isSaving = false
    didSave = false
    successRevision = 0
    phase = .idle
  }

  func updateOwner(_ newOwnerID: String) {
    guard ownerID != newOwnerID else { return }
    cancel()
    ownerID = newOwnerID
  }

  func setAnswer(questionID: String, selected: [String]) {
    guard phase == .loaded, !isSaving, let question = question(for: questionID) else { return }
    guard let validationError = validateSelection(selected, for: question) else {
      saveError = nil
      didSave = false
      successRevision = 0
      draftAnswers[questionID] = selected
      return
    }
    saveError = validationError
  }

  func toggleSelection(questionID: String, optionValue: String) {
    guard phase == .loaded, !isSaving, let question = question(for: questionID) else { return }
    guard question.options.contains(where: { $0.value == optionValue }) else {
      saveError = .invalidSelection
      return
    }

    let current = draftAnswers[questionID] ?? []
    if question.allowMultiple {
      var next = current
      if let index = next.firstIndex(of: optionValue) {
        next.remove(at: index)
      } else {
        next.append(optionValue)
      }
      setAnswer(questionID: questionID, selected: next)
    } else {
      setAnswer(questionID: questionID, selected: [optionValue])
    }
  }

  @discardableResult
  func save() -> Task<Void, Never> {
    guard ownerID == apiOwnerID, phase == .loaded, !isSaving else {
      if ownerID != apiOwnerID {
        saveError = .ownerMismatch
      }
      return Task {}
    }
    do {
      try validateDraft()
    } catch let error as QuizStoreError {
      saveError = error
      return Task {}
    } catch {
      saveError = .invalidState
      return Task {}
    }

    invalidateTasks()
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    let answers = materializedAnswers()
    phase = .saving
    isSaving = true
    saveError = nil
    didSave = false
    successRevision = 0

    let task = Task { [weak self] in
      guard let self else { return }
      await self.performSave(
        answers: answers,
        ownerID: capturedOwnerID,
        generation: capturedGeneration
      )
    }
    saveTask = task
    return task
  }

  private func clearContent() {
    questions = []
    draftAnswers = [:]
    savedAnswers = [:]
  }

  private func invalidateTasks() {
    loadTask?.cancel()
    saveTask?.cancel()
    loadTask = nil
    saveTask = nil
    generation &+= 1
  }

  private func isCurrent(ownerID: String, generation: Int) -> Bool {
    !Task.isCancelled && self.ownerID == ownerID && self.generation == generation
  }

  private func question(for questionID: String) -> QuizQuestion? {
    questions.first { $0.id == questionID }
  }

  private func validateSelection(_ selected: [String], for question: QuizQuestion) -> QuizStoreError? {
    do {
      try QuizAnswer.validate(QuizAnswer(questionID: question.id, selected: selected))
      return nil
    } catch QuizDTOValidationError.duplicateSelection {
      return .duplicateSelection
    } catch QuizDTOValidationError.invalidSelection {
      return .invalidSelection
    } catch {
      return .invalidResponse
    }
  }

  private func validateDraft() throws {
    guard questions.count == QuizCatalog.requiredIDs.count else {
      throw QuizStoreError.invalidState
    }
    let questionIDs = Set(questions.map(\.id))
    guard questionIDs == QuizCatalog.requiredIDs else {
      throw QuizStoreError.invalidState
    }
    guard Set(draftAnswers.keys) == questionIDs else {
      throw QuizStoreError.incompleteAnswers
    }

    for question in questions {
      guard let selected = draftAnswers[question.id], !selected.isEmpty else {
        throw QuizStoreError.incompleteAnswers
      }
      do {
        try QuizAnswer.validate(QuizAnswer(questionID: question.id, selected: selected))
      } catch QuizDTOValidationError.duplicateSelection {
        throw QuizStoreError.duplicateSelection
      } catch QuizDTOValidationError.invalidSelection {
        throw QuizStoreError.invalidSelection
      } catch {
        throw QuizStoreError.invalidResponse
      }
    }
  }

  private func materializedAnswers() -> [QuizAnswer] {
    questions.sorted { $0.sortOrder < $1.sortOrder }.compactMap { question in
      guard let selected = draftAnswers[question.id] else { return nil }
      return QuizAnswer(questionID: question.id, selected: selected)
    }
  }

  private func validateLoadedQuestions(_ fetchedQuestions: [QuizQuestion]) throws {
    try QuizQuestionsPayload.validate(QuizQuestionsPayload(questions: fetchedQuestions))
  }

  private func validateFetchedAnswers(
    _ fetchedAnswers: [QuizAnswer],
    questions: [QuizQuestion],
    requireComplete: Bool
  ) throws {
    try QuizAnswersPayload.validate(QuizAnswersPayload(answers: fetchedAnswers))
    let questionIDs = Set(questions.map(\.id))
    let answerIDs = Set(fetchedAnswers.map(\.questionID))
    guard answerIDs.isSubset(of: questionIDs) else {
      throw QuizDTOValidationError.unknownQuestion
    }
    if requireComplete {
      guard answerIDs == questionIDs,
        fetchedAnswers.allSatisfy({ !$0.selected.isEmpty })
      else {
        throw QuizStoreError.readbackMismatch
      }
    }
  }

  private func answerMap(_ answers: [QuizAnswer]) -> [String: [String]] {
    Dictionary(uniqueKeysWithValues: answers.map { ($0.questionID, $0.selected) })
  }

  private func performLoad(ownerID: String, generation: Int) async {
    do {
      let fetchedQuestions = try await api.fetchQuestions()
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      try validateLoadedQuestions(fetchedQuestions)

      let fetchedAnswers = try await api.fetchAnswers()
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      try validateFetchedAnswers(fetchedAnswers, questions: fetchedQuestions, requireComplete: false)

      questions = fetchedQuestions.sorted { $0.sortOrder < $1.sortOrder }
      let answerMap = answerMap(fetchedAnswers)
      savedAnswers = answerMap
      draftAnswers = answerMap
      phase = .loaded
      loadError = nil
      loadTask = nil
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      clearContent()
      let mapped = Self.map(error)
      if isCancellation(error) {
        loadError = nil
        phase = .idle
      } else {
        loadError = mapped
        phase = .failed(mapped)
      }
      loadTask = nil
    }
  }

  private func performSave(
    answers: [QuizAnswer],
    ownerID: String,
    generation: Int
  ) async {
    do {
      _ = try await api.saveAnswers(answers)
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }

      let readback = try await api.fetchAnswers()
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      try validateFetchedAnswers(readback, questions: questions, requireComplete: true)
      let submitted = answerMap(answers)
      guard answerMap(readback) == submitted else {
        throw QuizStoreError.readbackMismatch
      }

      savedAnswers = submitted
      draftAnswers = submitted
      isSaving = false
      saveError = nil
      didSave = true
      successRevision = 1
      phase = .loaded
      saveTask = nil
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      isSaving = false
      if isCancellation(error) {
        saveTask = nil
        phase = .loaded
        return
      }
      saveError = Self.map(error)
      phase = .loaded
      saveTask = nil
    }
  }

  private static func map(_ error: Error) -> QuizStoreError {
    if let storeError = error as? QuizStoreError {
      return storeError
    }
    if error is QuizDTOValidationError || error is APIDTOValidationError {
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
    case .invalidResponse, .invalidRequest, .invalidURL: return .invalidResponse
    case .invalidState: return .invalidState
    case .rateLimited: return .rateLimited
    case .cancelled: return .cancelled
    case .transportFailure, .temporarilyUnavailable, .quotaExhausted:
      return .temporarilyUnavailable
    }
  }

  private func isCancellation(_ error: Error) -> Bool {
    if let clientError = error as? APIClientError {
      return clientError == .cancelled
    }
    return error is CancellationError || Task.isCancelled
  }
}
