import Foundation
import Observation

enum MatchesStoreError: Error, Equatable, Sendable {
  case unauthenticated
  case ageVerificationRequired
  case forbidden
  case notFound
  case invalidResponse
  case invalidState
  case rateLimited
  case temporarilyUnavailable
  case cancelled

  var userMessage: String {
    switch self {
    case .ageVerificationRequired:
      return "Verify your age before viewing matches."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .unauthenticated, .forbidden, .notFound, .invalidResponse, .invalidState,
      .temporarilyUnavailable, .cancelled:
      return "We couldn't load your matches. Try again."
    }
  }
}

enum MatchesStorePhase: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case failed(MatchesStoreError)
}

enum MatchesRehearsalOutcome: Equatable, Sendable {
  case started
  case startedPartial
  case alreadyExists
  case notEligible
  case expired
}

enum MatchesRehearsalPhase: Equatable, Sendable {
  case idle
  case previewing
  case previewed(RecordingRehearsalPreviewResult)
  case previewFailed
  case starting
  case refreshingResults(MatchesRehearsalOutcome)
  case finished(MatchesRehearsalOutcome)
  case resultsUnavailable(MatchesRehearsalOutcome)
  case failed
  case cancelled
}

enum DemoJudgeMatchingPhase: Equatable, Sendable {
  case idle, previewing, starting, failed, cancelled
  case previewed(Int)
  case finished(DemoJudgeStartOutcome, Int)
  case resultsUnavailable
}

@MainActor
@Observable
final class MatchesStore {
  private(set) var ownerID: String
  private(set) var phase: MatchesStorePhase = .idle
  private(set) var payload: DailyMatchesPayload?
  private(set) var discoveryPayload: DiscoveryMatchesPayload?
  private(set) var demoJudgePhase: DemoJudgeMatchingPhase = .idle
  private(set) var rehearsalPhase: MatchesRehearsalPhase = .idle

  private let api: any MatchesAPI
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var rehearsalTask: Task<Void, Never>?
  private var generation = 0
  private var rehearsalAttempted = false
  private var demoJudgeAttempted = false
  @ObservationIgnored private var demoJudgeTask: Task<Void, Never>?

  init(ownerID: String, api: any MatchesAPI) {
    self.ownerID = ownerID
    self.api = api
  }

  var supportsDemoJudgeMatching: Bool { api.demoJudgeMatchingAPI != nil }
  var displayedMatches: [ProductionMatch] { discoveryPayload?.matches ?? payload?.matches ?? [] }
  var canPreviewDemoJudgeMatching: Bool {
    supportsDemoJudgeMatching && phase == .loaded && !demoJudgeAttempted && !isDemoJudgeInProgress
  }
  var canStartDemoJudgeMatching: Bool {
    guard canPreviewDemoJudgeMatching, case let .previewed(count) = demoJudgePhase else { return false }
    return count > 0
  }
  var isDemoJudgeInProgress: Bool { demoJudgePhase == .previewing || demoJudgePhase == .starting }

  @discardableResult
  func previewDemoJudgeMatching() -> Task<Void, Never>? {
    guard canPreviewDemoJudgeMatching, let judgeAPI = api.demoJudgeMatchingAPI else { return nil }
    demoJudgePhase = .previewing
    let capturedOwner = ownerID
    let capturedGeneration = generation
    let task = Task { [weak self] in
      guard let self else { return }
      defer { if self.isCurrent(ownerID: capturedOwner, generation: capturedGeneration) { self.demoJudgeTask = nil } }
      do {
        let preview = try await judgeAPI.previewDemoJudgeMatching()
        guard self.isCurrent(ownerID: capturedOwner, generation: capturedGeneration) else { return }
        self.demoJudgePhase = .previewed(preview.count)
      } catch {
        guard self.isCurrent(ownerID: capturedOwner, generation: capturedGeneration) else { return }
        self.demoJudgePhase = .failed
      }
    }
    demoJudgeTask = task
    return task
  }

  @discardableResult
  func startDemoJudgeMatching() -> Task<Void, Never>? {
    guard canStartDemoJudgeMatching, let judgeAPI = api.demoJudgeMatchingAPI else { return nil }
    demoJudgeAttempted = true
    demoJudgePhase = .starting
    let capturedOwner = ownerID
    let capturedGeneration = generation
    let task = Task { [weak self] in
      guard let self else { return }
      defer { if self.isCurrent(ownerID: capturedOwner, generation: capturedGeneration) { self.demoJudgeTask = nil } }
      do {
        let started = try await judgeAPI.startDemoJudgeMatching()
        guard self.isCurrent(ownerID: capturedOwner, generation: capturedGeneration) else { return }
        do {
          let results = try await judgeAPI.fetchDiscoveryResults()
          guard self.isCurrent(ownerID: capturedOwner, generation: capturedGeneration) else { return }
          self.discoveryPayload = results
          self.demoJudgePhase = .finished(started.outcome, started.count)
        } catch {
          guard self.isCurrent(ownerID: capturedOwner, generation: capturedGeneration) else { return }
          self.demoJudgePhase = .resultsUnavailable
        }
      } catch {
        guard self.isCurrent(ownerID: capturedOwner, generation: capturedGeneration) else { return }
        self.demoJudgePhase = .failed
      }
    }
    demoJudgeTask = task
    return task
  }

  var supportsRecordingRehearsal: Bool {
    api.recordingRehearsalMatchingAPI != nil
  }

  var canStartRecordingRehearsal: Bool {
    supportsRecordingRehearsal
      && !rehearsalAttempted
      && !isRecordingRehearsalInProgress
      && phase == .loaded
      && payload?.matches.isEmpty == true
  }

  var canPreviewRecordingRehearsal: Bool {
    supportsRecordingRehearsal
      && !isRecordingRehearsalInProgress
      && phase == .loaded
      && payload?.matches.isEmpty == true
  }

  var isRecordingRehearsalInProgress: Bool {
    switch rehearsalPhase {
    case .previewing, .starting, .refreshingResults:
      return true
    case .idle, .previewed, .previewFailed, .finished, .resultsUnavailable, .failed, .cancelled:
      return false
    }
  }

  @discardableResult
  func previewRecordingRehearsal() -> Task<Void, Never>? {
    guard canPreviewRecordingRehearsal,
      let rehearsalAPI = api.recordingRehearsalMatchingAPI
    else { return nil }

    rehearsalPhase = .previewing
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    let task = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) {
          self.rehearsalTask = nil
        }
      }
      do {
        let preview = try await rehearsalAPI.previewRecordingRehearsal()
        guard self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        self.rehearsalPhase = .previewed(preview)
      } catch {
        guard self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        self.rehearsalPhase = .previewFailed
      }
    }
    rehearsalTask = task
    return task
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    invalidateLoad()
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    payload = nil
    discoveryPayload = nil
    phase = .loading

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

  @discardableResult
  func startRecordingRehearsal() -> Task<Void, Never>? {
    guard canStartRecordingRehearsal,
      let rehearsalAPI = api.recordingRehearsalMatchingAPI
    else { return nil }

    rehearsalAttempted = true
    rehearsalPhase = .previewing
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performRecordingRehearsal(
        using: rehearsalAPI,
        ownerID: capturedOwnerID,
        generation: capturedGeneration
      )
    }
    rehearsalTask = task
    return task
  }

  func cancel() {
    invalidateLoad()
    payload = nil
    discoveryPayload = nil
    phase = .idle
  }

  func updateOwner(_ newOwnerID: String) {
    guard ownerID != newOwnerID else { return }
    cancel()
    ownerID = newOwnerID
    rehearsalAttempted = false
    rehearsalPhase = .idle
    demoJudgeAttempted = false
    demoJudgePhase = .idle
  }

  private func invalidateLoad() {
    demoJudgeTask?.cancel()
    demoJudgeTask = nil
    demoJudgePhase = isDemoJudgeInProgress ? .cancelled : .idle
    loadTask?.cancel()
    loadTask = nil
    if rehearsalTask != nil {
      rehearsalTask?.cancel()
      rehearsalTask = nil
      if isRecordingRehearsalInProgress {
        rehearsalPhase = .cancelled
      }
    }
    generation &+= 1
  }

  private func isCurrent(ownerID: String, generation: Int) -> Bool {
    !Task.isCancelled && self.ownerID == ownerID && self.generation == generation
  }

  private func performLoad(ownerID: String, generation: Int) async {
    do {
      if let judgeAPI = api.demoJudgeMatchingAPI {
        let fetched = try await judgeAPI.fetchDiscoveryResults()
        guard isCurrent(ownerID: ownerID, generation: generation) else { return }
        discoveryPayload = fetched
      } else {
        let fetchedPayload = try await api.fetchDailyResults()
        guard isCurrent(ownerID: ownerID, generation: generation) else { return }
        payload = fetchedPayload
      }
      phase = .loaded
      loadTask = nil
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      if let clientError = error as? APIClientError {
        let mapped = Self.map(clientError)
        if mapped == .cancelled { phase = .idle } else { phase = .failed(mapped) }
      } else {
        phase = .failed(.temporarilyUnavailable)
      }
      loadTask = nil
    }
  }

  private func performRecordingRehearsal(
    using rehearsalAPI: any RecordingRehearsalMatchingAPI,
    ownerID: String,
    generation: Int
  ) async {
    defer {
      if isCurrent(ownerID: ownerID, generation: generation) {
        rehearsalTask = nil
      }
    }

    do {
      let preview = try await rehearsalAPI.previewRecordingRehearsal()
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }

      switch preview.outcome {
      case .eligible:
        rehearsalPhase = .starting
        let start = try await rehearsalAPI.startRecordingRehearsal()
        guard isCurrent(ownerID: ownerID, generation: generation) else { return }
        switch start.outcome {
        case .started:
          await refreshResultsAfterRehearsal(.started, ownerID: ownerID, generation: generation)
        case .startedPartial:
          await refreshResultsAfterRehearsal(.startedPartial, ownerID: ownerID, generation: generation)
        case .alreadyExists:
          await refreshResultsAfterRehearsal(.alreadyExists, ownerID: ownerID, generation: generation)
        case .notEligible:
          rehearsalPhase = .finished(.notEligible)
        case .expired:
          rehearsalPhase = .finished(.expired)
        }
      case .alreadyExists:
        await refreshResultsAfterRehearsal(.alreadyExists, ownerID: ownerID, generation: generation)
      case .notEligible:
        rehearsalPhase = .finished(.notEligible)
      case .expired:
        rehearsalPhase = .finished(.expired)
      }
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      rehearsalPhase = .failed
    }
  }

  private func refreshResultsAfterRehearsal(
    _ outcome: MatchesRehearsalOutcome,
    ownerID: String,
    generation: Int
  ) async {
    rehearsalPhase = .refreshingResults(outcome)
    do {
      let fetchedPayload = try await api.fetchDailyResults()
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      payload = fetchedPayload
      phase = .loaded
      rehearsalPhase = .finished(outcome)
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      rehearsalPhase = .resultsUnavailable(outcome)
    }
  }

  private static func map(_ error: APIClientError) -> MatchesStoreError {
    switch error {
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
}
