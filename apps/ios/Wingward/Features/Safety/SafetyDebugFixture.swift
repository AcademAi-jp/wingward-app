#if DEBUG
import Foundation
import SwiftUI

public enum SafetyDebugFixtureScenario: String, CaseIterable, Sendable {
  case success
  case reportFailure
  case blockFailure
}

public enum AccountDeletionDebugFixtureScenario: String, CaseIterable, Sendable {
  case success
  case notAcknowledged
  case failure
}

/// Synthetic safety/account screens for local UI review. The adapters below
/// are in-memory and never call the moderation or auth services.
public enum SafetyDebugFixture {
  public static let ownerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  public static let targetID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

  static func actionView(
    ownerID: String = SafetyDebugFixture.ownerID,
    scenario: SafetyDebugFixtureScenario = .success,
    context: ReportContext = .match,
    onBlocked: @escaping () -> Void = {},
    onBlockNeedsReconciliation: @escaping () -> Void = {}
  ) -> AnyView {
    AnyView(
      SafetyActionView(
        ownerID: ownerID,
        targetID: targetID,
        context: context,
        api: DebugSafetyAPI(scenario: scenario),
        onBlocked: onBlocked,
        onBlockNeedsReconciliation: onBlockNeedsReconciliation
      )
    )
  }

  public static func accountDeletionView(
    ownerID: String = SafetyDebugFixture.ownerID,
    scenario: AccountDeletionDebugFixtureScenario = .success
  ) -> AnyView {
    AnyView(
      AccountDeletionView(
        ownerID: ownerID,
        api: DebugAccountDeletionAPI(scenario: scenario),
        cleanup: DebugSessionCleanup()
      )
    )
  }

  public static func combinedView(
    ownerID: String = SafetyDebugFixture.ownerID,
    safetyScenario: SafetyDebugFixtureScenario = .success,
    deletionScenario: AccountDeletionDebugFixtureScenario = .success
  ) -> AnyView {
    AnyView(
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Text("DEBUG FIXTURE · synthetic safety and account")
            .font(.caption.weight(.semibold))
          actionView(ownerID: ownerID, scenario: safetyScenario)
          accountDeletionView(ownerID: ownerID, scenario: deletionScenario)
        }
        .padding(20)
      }
      .navigationTitle("Safety fixture")
    )
  }
}

private actor DebugSafetyAPI: SafetyAPI {
  let scenario: SafetyDebugFixtureScenario

  init(scenario: SafetyDebugFixtureScenario) {
    self.scenario = scenario
  }

  func report(_ request: ModerationReportRequest) async throws -> ModerationReportResponse {
    if scenario == .reportFailure {
      throw APIClientError.temporarilyUnavailable
    }
    return ModerationReportResponse(
      reportID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
      status: "pending"
    )
  }

  func block(userID: UUID) async throws -> ModerationBlockResponse {
    if scenario == .blockFailure {
      throw APIClientError.temporarilyUnavailable
    }
    return ModerationBlockResponse(message: "User blocked")
  }

  func unblock(userID: UUID) async throws -> ModerationUnblockResponse {
    ModerationUnblockResponse(message: "User unblocked")
  }
}

private struct DebugAccountDeletionAPI: AccountLifecycleAPI {
  let scenario: AccountDeletionDebugFixtureScenario

  func deleteAccount() async throws -> AccountDeletionResponse {
    switch scenario {
    case .success:
      return AccountDeletionResponse(deleted: true)
    case .notAcknowledged:
      return AccountDeletionResponse(deleted: false)
    case .failure:
      throw APIClientError.temporarilyUnavailable
    }
  }
}

private actor DebugSessionCleanup: SessionCleanup {
  func clearAfterServerDeletion(ownerID: String) async {}
}
#endif
