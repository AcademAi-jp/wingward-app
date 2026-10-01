#if DEBUG
import Foundation
import SwiftUI

/// Synthetic billing screens for local UI review. These factories never use a
/// live API, store account, RevenueCat SDK, or real purchase.
public enum BillingDebugFixtureScenario: String, CaseIterable, Sendable {
  case purchasesUnavailable
  case inactive
  case active
}

public enum BillingDebugFixture {
  public static let ownerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

  public static func view(
    ownerID: String = BillingDebugFixture.ownerID,
    scenario: BillingDebugFixtureScenario = .inactive
  ) -> AnyView {
    switch scenario {
    case .purchasesUnavailable:
      let api = DebugBillingStatusAPI(status: inactiveStatus)
      return AnyView(
        BillingView(
          ownerID: ownerID,
          client: UnavailableBillingClient(serverAPI: api)
        )
      )
    case .inactive:
      return AnyView(
        BillingView(
          ownerID: ownerID,
          client: FakeBillingClient(
            status: inactiveStatus,
            offerings: [monthlyOffering],
            purchaseResult: BillingPurchaseResult(
              packageID: monthlyOffering.packageID,
              outcome: .completed
            ),
            restoredVendorStatus: activeStatus
          )
        )
      )
    case .active:
      return AnyView(
        BillingView(
          ownerID: ownerID,
          client: FakeBillingClient(
            status: activeStatus,
            offerings: [monthlyOffering],
            purchaseResult: BillingPurchaseResult(
              packageID: monthlyOffering.packageID,
              outcome: .completed
            ),
            restoredVendorStatus: activeStatus
          )
        )
      )
    }
  }

  private static let monthlyOffering = BillingOffering(
    packageID: "fixture.premium.monthly",
    productID: "fixture_premium_monthly",
    title: "Premium fixture",
    localizedPrice: "Fixture price"
  )

  private static let inactiveStatus = BillingStatus(
    isActive: false,
    productID: nil,
    store: nil,
    currentPeriodEnd: nil,
    consumableCredits: 0
  )

  private static let activeStatus = BillingStatus(
    isActive: true,
    productID: "fixture_premium_monthly",
    store: "FIXTURE",
    currentPeriodEnd: Date(timeIntervalSince1970: 1_800_000_000),
    consumableCredits: 1
  )
}

private struct DebugBillingStatusAPI: BillingAPI {
  let status: BillingStatus

  func fetchStatus() async throws -> BillingStatus { status }
}
#endif
