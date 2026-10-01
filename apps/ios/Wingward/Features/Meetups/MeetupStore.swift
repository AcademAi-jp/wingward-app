import Foundation
import Observation

@MainActor
@Observable
final class MeetupStore {
  private(set) var ownerID: String
  private let apiOwnerID: String
  private(set) var meetupID: UUID?
  private(set) var expectedMatchID: UUID?
  private(set) var phase: MeetupStorePhase
  private(set) var detail: MeetupDetail?
  private(set) var intentAccepted = false
  private(set) var preferencesSaved = false
  private(set) var verificationGate: MeetupVerificationGateState?

  private let api: any MeetupsAPI
  @ObservationIgnored private var activeTask: Task<Void, Never>?
  private var generation = 0
  private var ownerBindingValid: Bool

  init(
    ownerID: String,
    meetupID: UUID? = nil,
    matchID: UUID? = nil,
    api: any MeetupsAPI
  ) {
    self.ownerID = ownerID
    self.apiOwnerID = ownerID
    self.meetupID = meetupID
    self.expectedMatchID = matchID
    self.api = api
    let bindingValid = (try? APIDTOValidation.requireUUID(ownerID)) != nil
    self.ownerBindingValid = bindingValid
    self.phase = bindingValid ? .idle : .failed(.unauthenticated)
  }

  var viewState: MeetupViewState {
    if case let .failed(error) = phase {
      if error == .identityVerificationRequired {
        return .verifying(verificationGate ?? .required)
      }
      return .failed(error)
    }

    switch phase {
    case .idle:
      return meetupID == nil && !intentAccepted ? .intentAvailable : .idle
    case .loading:
      return .loading
    case .expressingIntent:
      return .intentAvailable
    case .savingPreferences:
      return stateForDetail()
    case .arranging:
      return .arranging
    case .responding:
      return stateForDetail()
    case .loaded:
      if detail == nil {
        return intentAccepted ? .intentPending : .intentAvailable
      }
      return stateForDetail()
    case .failed:
      return .failed(.temporarilyUnavailable)
    }
  }

  var isBusy: Bool {
    switch phase {
    case .loading, .expressingIntent, .savingPreferences, .arranging, .responding:
      return true
    case .idle, .loaded, .failed:
      return false
    }
  }

  /// This action is always free. No local entitlement or paywall check is
  /// consulted; the API remains the authority for idempotency and access.
  var canExpressIntent: Bool {
    ownerBindingValid && matchIDForIntent != nil && !isBusy
  }

  var canSavePreferences: Bool {
    ownerBindingValid && meetupID != nil && !isBusy && detail?.status.isTerminal == false
  }

  var canArrange: Bool {
    ownerBindingValid && meetupID != nil && !isBusy && detail?.status == .verifying
  }

  var canRetryArrangement: Bool {
    ownerBindingValid && meetupID != nil && !isBusy
      && (detail?.status == .proposed || detail?.status == .arrangeFailed)
  }

  var canRespond: Bool {
    ownerBindingValid && meetupID != nil && !isBusy
      && detail?.status == .proposed
      && detail?.proposal?.candidates.count == 3
  }

  private var matchIDForIntent: UUID? {
    expectedMatchID ?? detail?.matchID
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    guard canUseBoundAPI else {
      phase = .failed(.unauthenticated)
      return Task {}
    }
    let currentMeetupID = meetupID
    let matchID = expectedMatchID
    guard currentMeetupID != nil || matchID != nil else {
      phase = intentAccepted ? .loaded : .idle
      return Task {}
    }

    invalidateActiveTask(clearProtectedContent: true)
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    phase = .loading
    verificationGate = nil

    let task = Task { [weak self] in
      guard let self else { return }
      if let meetupID = currentMeetupID {
        await self.performLoad(
          meetupID: meetupID,
          ownerID: capturedOwnerID,
          generation: capturedGeneration
        )
      } else if let matchID {
        await self.performMatchLoad(
          matchID: matchID,
          ownerID: capturedOwnerID,
          generation: capturedGeneration
        )
      }
    }
    activeTask = task
    return task
  }

  @discardableResult
  func retry() -> Task<Void, Never> {
    load()
  }

  @discardableResult
  func expressIntent() -> Task<Void, Never> {
    guard canUseBoundAPI, let matchID = matchIDForIntent else {
      phase = .failed(ownerBindingValid ? .invalidRequest : .unauthenticated)
      return Task {}
    }

    invalidateActiveTask(clearProtectedContent: false)
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    phase = .expressingIntent
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await self.api.createIntent(matchID: matchID)
        guard result.accepted,
          self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration)
        else {
          throw APIClientError.invalidResponse
        }
        intentAccepted = true

        // The intent endpoint deliberately does not disclose the meetup ID or
        // the counterpart's action. The follow-up match-bound read returns
        // only the caller's current, authorized meetup after mutual intent;
        // one-sided pending state remains local to this store.
        if let meetupID = self.meetupID {
          let fetched = try await self.api.fetchMeetup(id: meetupID)
          guard self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
          try self.accept(fetched, requestedMeetupID: meetupID)
          detail = fetched
        } else if let matchID = self.expectedMatchID {
          let fetched = try await self.api.fetchMeetup(matchID: matchID)
          guard self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
          try self.accept(fetched, requestedMeetupID: fetched.id)
          meetupID = fetched.id
          detail = fetched
        }
        phase = .loaded
        activeTask = nil
      } catch {
        guard self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        let mapped = Self.map(error, operation: .intent)
        if mapped == .cancelled {
          phase = .idle
        } else if mapped == .notFound, self.meetupID == nil {
          // A non-disclosing discovery miss after an accepted intent remains
          // a pending local state. It must never be presented as a failed
          // or confirmed meetup.
          phase = .loaded
        } else {
          phase = .failed(mapped)
        }
        activeTask = nil
      }
    }
    activeTask = task
    return task
  }

  @discardableResult
  func savePreferences(_ preferences: MeetupPreferences) -> Task<Void, Never> {
    guard canUseBoundAPI, let meetupID else {
      phase = .failed(ownerBindingValid ? .invalidRequest : .unauthenticated)
      return Task {}
    }
    do {
      try preferences.validate()
    } catch {
      phase = .failed(.invalidRequest)
      return Task {}
    }

    invalidateActiveTask(clearProtectedContent: false)
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    phase = .savingPreferences
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await self.api.savePreferences(meetupID: meetupID, preferences: preferences)
        guard result.saved,
          self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration)
        else {
          throw APIClientError.invalidResponse
        }
        preferencesSaved = true
        phase = .loaded
        activeTask = nil
      } catch {
        guard self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        let mapped = Self.map(error, operation: .preferences)
        phase = mapped == .cancelled ? .idle : .failed(mapped)
        activeTask = nil
      }
    }
    activeTask = task
    return task
  }

  @discardableResult
  func arrange() -> Task<Void, Never> {
    performArrangement(retry: false)
  }

  @discardableResult
  func retryArrangement() -> Task<Void, Never> {
    performArrangement(retry: true)
  }

  @discardableResult
  private func performArrangement(retry: Bool) -> Task<Void, Never> {
    guard canUseBoundAPI, let meetupID else {
      phase = .failed(ownerBindingValid ? .invalidRequest : .unauthenticated)
      return Task {}
    }

    invalidateActiveTask(clearProtectedContent: false)
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    phase = .arranging
    verificationGate = nil

    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let result: MeetupActionResponse
        if retry {
          result = try await self.api.retry(meetupID: meetupID)
        } else {
          result = try await self.api.arrange(meetupID: meetupID)
        }
        guard result.accepted,
          result.status == .arranging,
          self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration)
        else {
          throw APIClientError.invalidResponse
        }
        if let detail {
          self.detail = MeetupDetail.replacing(detail, status: .arranging)
        }
        phase = .loaded
        activeTask = nil
      } catch {
        guard self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        let mapped = Self.map(error, operation: retry ? .retry : .arrange)
        verificationGate = mapped == .identityVerificationRequired ? .required : nil
        phase = mapped == .cancelled ? .idle : .failed(mapped)
        activeTask = nil
      }
    }
    activeTask = task
    return task
  }

  @discardableResult
  func respond(selectedCandidateIndex: Int) -> Task<Void, Never> {
    guard canRespond,
      let meetupID,
      let proposal = detail?.proposal,
      (0..<proposal.candidates.count).contains(selectedCandidateIndex)
    else {
      phase = .failed(ownerBindingValid ? .invalidRequest : .unauthenticated)
      return Task {}
    }

    invalidateActiveTask(clearProtectedContent: false)
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    phase = .responding
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await self.api.respond(
          meetupID: meetupID,
          proposalID: proposal.id,
          selectedCandidateIndex: selectedCandidateIndex
        )
        guard result.accepted,
          self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration)
        else {
          throw APIClientError.invalidResponse
        }
        switch result.status {
        case .proposed:
          phase = .loaded
        case .confirmed:
          // The server has confirmed that both participants selected the same
          // current proposal. The selected candidate comes from that exact
          // proposal ID; no client-side confirmation is used to authorize it.
          guard let selected = proposal.candidates[safe: selectedCandidateIndex] else {
            throw APIClientError.invalidResponse
          }
          guard let matchID = self.detail?.matchID ?? self.expectedMatchID else {
            throw APIClientError.invalidResponse
          }
          detail = MeetupDetail(
            id: meetupID,
            matchID: matchID,
            status: .confirmed,
            confirmedCandidate: MeetupConfirmedCandidate(
              startsAt: selected.startsAt,
              timezone: selected.timezone,
              area: selected.area,
              format: selected.format
            )
          )
          phase = .loaded
        case .arranging:
          throw APIClientError.invalidResponse
        }
        activeTask = nil
      } catch {
        guard self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        let mapped = Self.map(error, operation: .respond)
        phase = mapped == .cancelled ? .idle : .failed(mapped)
        activeTask = nil
      }
    }
    activeTask = task
    return task
  }

  func cancel() {
    invalidateActiveTask(clearProtectedContent: true)
    phase = .idle
    intentAccepted = false
    preferencesSaved = false
    verificationGate = nil
  }

  /// A store's API is created for one owner-bound session. Reusing it for a
  /// different owner would let a late response from the first actor populate
  /// the second actor's view, so the store becomes unusable and fails closed.
  func updateOwner(_ newOwnerID: String) {
    guard ownerID != newOwnerID else { return }
    invalidateActiveTask(clearProtectedContent: true)
    ownerID = newOwnerID
    ownerBindingValid = false
    phase = .failed(.unauthenticated)
    intentAccepted = false
    preferencesSaved = false
    verificationGate = nil
  }

  private var canUseBoundAPI: Bool {
    ownerBindingValid && ownerID == apiOwnerID
  }

  private func performLoad(meetupID: UUID, ownerID: String, generation: Int) async {
    do {
      let fetched = try await api.fetchMeetup(id: meetupID)
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      try accept(fetched, requestedMeetupID: meetupID)
      detail = fetched
      phase = .loaded
      activeTask = nil
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      detail = nil
      let mapped = Self.map(error, operation: .load)
      verificationGate = nil
      phase = mapped == .cancelled ? .idle : .failed(mapped)
      activeTask = nil
    }
  }

  private func performMatchLoad(matchID: UUID, ownerID: String, generation: Int) async {
    do {
      let fetched = try await api.fetchMeetup(matchID: matchID)
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      try accept(fetched, requestedMeetupID: fetched.id)
      meetupID = fetched.id
      detail = fetched
      intentAccepted = true
      phase = .loaded
      activeTask = nil
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      detail = nil
      meetupID = nil
      let mapped = Self.map(error, operation: .load)
      verificationGate = nil
      // A missing match-bound meetup is the expected state before either
      // participant expresses intent. Keep the first-intent surface closed
      // to the counterpart without turning that absence into an error.
      if mapped == .cancelled {
        phase = .idle
      } else if mapped == .notFound {
        phase = intentAccepted ? .loaded : .idle
      } else {
        phase = .failed(mapped)
      }
      activeTask = nil
    }
  }

  private func accept(_ fetched: MeetupDetail, requestedMeetupID: UUID) throws {
    guard fetched.id == requestedMeetupID,
      expectedMatchID == nil || expectedMatchID == fetched.matchID
    else {
      throw APIClientError.invalidResponse
    }
    try MeetupDetail.validate(fetched)
    if expectedMatchID == nil { expectedMatchID = fetched.matchID }
  }

  private func stateForDetail() -> MeetupViewState {
    guard let detail else {
      return intentAccepted ? .intentPending : .intentAvailable
    }
    switch detail.status {
    case .intentPending:
      return .intentPending
    case .verifying:
      return .verifying(verificationGate ?? .required)
    case .arranging:
      return .arranging
    case .proposed:
      return .proposed
    case .arrangeFailed:
      return .arrangeFailed
    case .confirmed:
      return .confirmed
    case .expired:
      return .expired
    case .cancelled:
      return .cancelled
    }
  }

  private func invalidateActiveTask(clearProtectedContent: Bool) {
    activeTask?.cancel()
    activeTask = nil
    generation &+= 1
    if clearProtectedContent {
      detail = nil
    }
  }

  private func isCurrent(ownerID: String, generation: Int) -> Bool {
    !Task.isCancelled && canUseBoundAPI && self.ownerID == ownerID && self.generation == generation
  }

  private enum Operation {
    case load
    case intent
    case preferences
    case arrange
    case retry
    case respond
  }

  private static func map(
    _ error: Error,
    operation: Operation
  ) -> MeetupStoreError {
    if let meetupError = error as? MeetupAPIError {
      switch meetupError {
      case .identityVerificationRequired:
        return .identityVerificationRequired
      }
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
    case .invalidResponse, .invalidURL, .transportFailure: return .invalidResponse
    case .invalidState:
      // The shared transport intentionally maps 409 to a neutral state. Do
      // not infer identity status from a prior client snapshot: a concurrent
      // close, expiry, or superseded proposal is also a valid 409 outcome.
      return .invalidState
    case let .quotaExhausted(source):
      return operation == .intent ? .invalidResponse : .quotaExhausted(source: source)
    case .rateLimited: return .rateLimited
    case .temporarilyUnavailable: return .temporarilyUnavailable
    case .cancelled: return .cancelled
    }
  }

}

private extension Array {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

private extension MeetupDetail {
  static func replacing(_ detail: MeetupDetail, status: MeetupStatus) -> MeetupDetail {
    MeetupDetail(
      id: detail.id,
      matchID: detail.matchID,
      status: status,
      proposal: status == .proposed ? detail.proposal : nil,
      confirmedCandidate: status == .confirmed ? detail.confirmedCandidate : nil,
      expiresAt: status == .intentPending || status == .proposed ? detail.expiresAt : nil
    )
  }
}
