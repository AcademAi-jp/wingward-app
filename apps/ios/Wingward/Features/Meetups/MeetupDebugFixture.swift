#if DEBUG
import Foundation
import SwiftUI

/// Bounded, local-only meetup scenarios used by the DEBUG journey and UI
/// tests. The factory accepts one synthetic owner and never creates a live
/// authenticated client or touches a network service.
enum MeetupDebugScenario: String, CaseIterable, Sendable {
  case verifying
  case verificationRequired
  case preferences
  case arrange
  case quotaExhausted
  case proposed
  case respondConfirmed
  case intent
}

enum MeetupDebugFixture {
  static let ownerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  static let meetupID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  static let matchID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  static let proposalID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

  /// Returns the real production MeetupView with a synthetic API behind it.
  /// The intent scenario intentionally has no meetup ID, matching the
  /// non-disclosing first-intent response shape.
  static func makeView(
    scenario: MeetupDebugScenario,
    matchID: UUID = MeetupDebugFixture.matchID,
    callbacks: NativeFeatureCallbacks = .empty
  ) -> MeetupView {
    let api = MeetupDebugAPI(scenario: scenario, matchID: matchID)
    return MeetupView(
      ownerID: ownerID,
      meetupID: scenario == .intent ? nil : meetupID,
      matchID: matchID,
      api: api,
      pilotPolicy: .publicDefault,
      onOpenVerification: callbacks.onOpenVerification,
      onOpenPaywall: callbacks.onOpenPaywall,
      onOpenReportForMatch: callbacks.onOpenReportForMatch
    )
  }
}

struct MeetupDebugAPIFactory: MeetupsAPIFactory, Sendable {
  let scenario: MeetupDebugScenario

  init(scenario: MeetupDebugScenario) {
    self.scenario = scenario
  }

  func make(ownerID: String) -> (any MeetupsAPI)? {
    guard ownerID == MeetupDebugFixture.ownerID else { return nil }
    return MeetupDebugAPI(scenario: scenario)
  }
}

private actor MeetupDebugAPI: MeetupsAPI {
  private let scenario: MeetupDebugScenario
  private let matchID: UUID
  private var detail: MeetupDetail?

  init(scenario: MeetupDebugScenario, matchID: UUID = MeetupDebugFixture.matchID) {
    self.scenario = scenario
    self.matchID = matchID
    switch scenario {
    case .intent:
      detail = nil
    case .verifying, .preferences, .arrange, .quotaExhausted:
      detail = MeetupDetail(
        id: MeetupDebugFixture.meetupID,
        matchID: matchID,
        status: .verifying
      )
    case .verificationRequired:
      detail = MeetupDetail(
        id: MeetupDebugFixture.meetupID,
        matchID: matchID,
        status: .arrangeFailed
      )
    case .proposed, .respondConfirmed:
      detail = Self.proposedDetail(matchID: matchID)
    }
  }

  func createIntent(matchID: UUID) async throws -> MeetupIntentResponse {
    guard matchID == self.matchID else {
      throw APIClientError.notFound
    }
    if scenario == .intent {
      detail = MeetupDetail(
        id: MeetupDebugFixture.meetupID,
        matchID: matchID,
        status: .intentPending,
        expiresAt: Date().addingTimeInterval(172_800)
      )
    }
    return MeetupIntentResponse(accepted: true)
  }

  func fetchMeetup(id: UUID) async throws -> MeetupDetail {
    guard id == MeetupDebugFixture.meetupID, let detail else {
      throw APIClientError.notFound
    }
    return detail
  }

  func fetchMeetup(matchID: UUID) async throws -> MeetupDetail {
    guard matchID == self.matchID, let detail else {
      throw APIClientError.notFound
    }
    return detail
  }

  func savePreferences(
    meetupID: UUID,
    preferences: MeetupPreferences
  ) async throws -> MeetupPreferencesResponse {
    guard meetupID == MeetupDebugFixture.meetupID else {
      throw APIClientError.notFound
    }
    try preferences.validate()
    return MeetupPreferencesResponse(saved: true)
  }

  func arrange(meetupID: UUID) async throws -> MeetupActionResponse {
    guard meetupID == MeetupDebugFixture.meetupID else {
      throw APIClientError.notFound
    }
    if scenario == .verifying {
      throw MeetupAPIError.identityVerificationRequired
    }
    if scenario == .verificationRequired {
      throw MeetupAPIError.identityVerificationRequired
    }
    if scenario == .quotaExhausted {
      throw APIClientError.quotaExhausted(source: .meetupArrange)
    }
    detail = Self.proposedDetail(matchID: matchID)
    return MeetupActionResponse(accepted: true, status: .arranging)
  }

  func retry(meetupID: UUID) async throws -> MeetupActionResponse {
    try await arrange(meetupID: meetupID)
  }

  func respond(
    meetupID: UUID,
    proposalID: UUID,
    selectedCandidateIndex: Int
  ) async throws -> MeetupActionResponse {
    guard meetupID == MeetupDebugFixture.meetupID,
      proposalID == MeetupDebugFixture.proposalID,
      (0...2).contains(selectedCandidateIndex)
    else {
      throw APIClientError.invalidRequest
    }
    detail = Self.confirmedDetail(matchID: matchID)
    return MeetupActionResponse(accepted: true, status: .confirmed)
  }

  private static func proposedDetail(matchID: UUID) -> MeetupDetail {
    MeetupDetail(
      id: MeetupDebugFixture.meetupID,
      matchID: matchID,
      status: .proposed,
      proposal: MeetupProposal(
        id: MeetupDebugFixture.proposalID,
        candidates: [
          MeetupCandidate(
            startsAt: Date(timeIntervalSince1970: 1_800_000_000),
            timezone: "Asia/Tokyo",
            area: "Tokyo/Chiyoda",
            format: .cafe,
            rationale: "A quiet first option with a simple route."
          ),
          MeetupCandidate(
            startsAt: Date(timeIntervalSince1970: 1_800_003_600),
            timezone: "Asia/Tokyo",
            area: "Tokyo/Chiyoda",
            format: .meal,
            rationale: "A flexible option for a longer conversation."
          ),
          MeetupCandidate(
            startsAt: Date(timeIntervalSince1970: 1_800_007_200),
            timezone: "Asia/Tokyo",
            area: "Tokyo/Chiyoda",
            format: .online,
            rationale: "A lower-pressure option if plans change."
          ),
        ],
        expiresAt: Date(timeIntervalSince1970: 1_800_100_000)
      ),
      expiresAt: Date(timeIntervalSince1970: 1_800_100_000)
    )
  }

  private static func confirmedDetail(matchID: UUID) -> MeetupDetail {
    MeetupDetail(
      id: MeetupDebugFixture.meetupID,
      matchID: matchID,
      status: .confirmed,
      confirmedCandidate: MeetupConfirmedCandidate(
        startsAt: Date(timeIntervalSince1970: 1_800_003_600),
        timezone: "Asia/Tokyo",
        area: "Tokyo/Chiyoda",
        format: .meal
      )
    )
  }
}
#endif
