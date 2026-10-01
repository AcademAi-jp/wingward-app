import Foundation
import XCTest
@testable import Wingward

@MainActor
final class BillingTests: XCTestCase {
  private let ownerID = "11111111-1111-4111-8111-111111111111"
  private let packageID = "wingward.premium.monthly"

  func testBillingStatusDecodesOnlyAValidServerMirror() throws {
    let data = Data(
      #"{"data":{"is_active":true,"product_id":"wingward_premium_monthly","store":"APP_STORE","current_period_end":"2026-10-04T08:00:00.000Z","consumable_credits":2}}"#.utf8
    )
    let status = try APIResponseDecoder.decode(data, as: BillingStatus.self)

    XCTAssertTrue(status.isActive)
    XCTAssertEqual(status.productID, "wingward_premium_monthly")
    XCTAssertEqual(status.store, "APP_STORE")
    XCTAssertEqual(status.consumableCredits, 2)
    XCTAssertNotNil(status.currentPeriodEnd)
  }

  func testActiveStatusWithoutProductFailsClosed() {
    let data = Data(
      #"{"data":{"is_active":true,"product_id":null,"store":null,"current_period_end":null,"consumable_credits":0}}"#.utf8
    )

    XCTAssertThrowsError(try APIResponseDecoder.decode(data, as: BillingStatus.self)) { error in
      XCTAssertEqual(error as? APIClientError, .invalidResponse)
    }
  }

  func testLiveBillingAPIUsesTheAuthenticatedStatusRoute() async throws {
    let client = FakeAuthenticatedAPIClient()
    let request = APIRequest(method: .get, path: LiveBillingAPI.statusPath)
    await client.setResponseData(
      Data(#"{"data":{"is_active":false,"product_id":null,"store":null,"current_period_end":null,"consumable_credits":0}}"#.utf8),
      for: request
    )

    let status = try await LiveBillingAPI(client: client).fetchStatus()
    XCTAssertFalse(status.isActive)
    let requests = await client.recordedRequests()
    XCTAssertEqual(requests, [request])
  }

  func testUnavailableAdapterExposesStatusButCannotClaimPurchaseOrRestore() async throws {
    let status = inactiveStatus()
    let adapter = UnavailableBillingClient(serverAPI: FixedBillingAPI(status: status))
    let fetchedStatus = try await adapter.currentStatus()
    XCTAssertEqual(fetchedStatus, status)

    do {
      _ = try await adapter.purchase(packageID: packageID)
      XCTFail("The unavailable adapter must not claim a purchase")
    } catch let error as BillingClientError {
      XCTAssertEqual(error, .unavailable)
    }

    do {
      _ = try await adapter.restore()
      XCTFail("The unavailable adapter must not claim a restore")
    } catch let error as BillingClientError {
      XCTAssertEqual(error, .unavailable)
    }
  }

  func testPurchaseRefreshesServerStatusInsteadOfTrustingVendorResult() async throws {
    let client = ScriptedBillingClient(
      statuses: [inactiveStatus(), inactiveStatus()],
      offerings: [offering()],
      purchaseResult: BillingPurchaseResult(packageID: packageID, outcome: .completed)
    )
    let store = BillingStore(ownerID: ownerID, client: client)

    await store.load().value
    await store.purchase(packageID: packageID).value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.status, inactiveStatus())
    XCTAssertEqual(store.notice, .purchaseAwaitingServer)
    let purchaseCalls = await client.purchaseCalls()
    let statusCalls = await client.currentStatusCalls()
    XCTAssertEqual(purchaseCalls, [packageID])
    XCTAssertEqual(statusCalls, 2)
  }

  func testMismatchedVendorPackageFailsBeforeServerRefresh() async throws {
    let client = ScriptedBillingClient(
      statuses: [inactiveStatus()],
      offerings: [offering()],
      purchaseResult: BillingPurchaseResult(packageID: "other.package", outcome: .completed)
    )
    let store = BillingStore(ownerID: ownerID, client: client)

    await store.load().value
    await store.purchase(packageID: packageID).value

    XCTAssertEqual(store.phase, .failed(.invalidResponse))
    XCTAssertNil(store.status)
    let statusCalls = await client.currentStatusCalls()
    XCTAssertEqual(statusCalls, 1)
  }

  func testRestoreRefreshesTheServerMirrorInsteadOfTrustingVendorStatus() async throws {
    let client = ScriptedBillingClient(
      statuses: [inactiveStatus(), inactiveStatus()],
      offerings: [offering()],
      restoredVendorStatus: activeStatus()
    )
    let store = BillingStore(ownerID: ownerID, client: client)

    await store.load().value
    await store.restore().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.status, inactiveStatus())
    XCTAssertEqual(store.notice, .restoreNoActivePlan)
    let restoreCalls = await client.restoreCalls()
    XCTAssertEqual(restoreCalls, 1)
  }

  func testRestoreCanBeRetriedAfterFailureAndUsesServerConfirmation() async throws {
    let client = RetryOnceRestoreBillingClient(status: inactiveStatus(), offering: offering())
    let store = BillingStore(ownerID: ownerID, client: client)

    await store.load().value
    await store.restore().value
    XCTAssertEqual(store.phase, .failed(.purchasesUnavailable))

    await store.restore().value
    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.status, inactiveStatus())
    XCTAssertEqual(store.notice, .restoreNoActivePlan)
    let restoreCalls = await client.restoreCalls()
    XCTAssertEqual(restoreCalls, 2)
  }

  func testCancelledPurchaseClearsPreviouslyLoadedStatus() async throws {
    let client = ScriptedBillingClient(
      statuses: [Result.success(activeStatus()), .failure(.cancelled)],
      offerings: [offering()],
      purchaseResult: BillingPurchaseResult(packageID: packageID, outcome: .completed)
    )
    let store = BillingStore(ownerID: ownerID, client: client)

    await store.load().value
    XCTAssertNotNil(store.status)
    await store.purchase(packageID: packageID).value

    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.status)
  }

  func testRebindingStoreCannotReuseTheOriginalOwnersClient() async throws {
    let client = ScriptedBillingClient(statuses: [inactiveStatus()], offerings: [offering()])
    let store = BillingStore(ownerID: ownerID, client: client)

    store.updateOwner("22222222-2222-4222-8222-222222222222")
    await store.load().value

    XCTAssertEqual(store.phase, .failed(.ownerMismatch))
    let statusCalls = await client.currentStatusCalls()
    let offeringCalls = await client.offeringsCalls()
    XCTAssertEqual(statusCalls, 0)
    XCTAssertEqual(offeringCalls, 0)
  }

  func testPaywallSourcesNeverIncludeMeetIntent() {
    XCTAssertFalse(PaywallSource.allCases.contains { $0.rawValue.contains("meet") && $0 != .meetupArrange && $0 != .arrangeRetry })
    XCTAssertEqual(Set(PaywallSource.allCases), [.foxConversation, .meetupArrange, .arrangeRetry])
  }

  private func offering() -> BillingOffering {
    BillingOffering(
      packageID: packageID,
      productID: "wingward_premium_monthly",
      title: "Premium",
      localizedPrice: "store supplied price"
    )
  }

  private func inactiveStatus() -> BillingStatus {
    BillingStatus(
      isActive: false,
      productID: nil,
      store: nil,
      currentPeriodEnd: nil,
      consumableCredits: 0
    )
  }

  private func activeStatus() -> BillingStatus {
    BillingStatus(
      isActive: true,
      productID: "wingward_premium_monthly",
      store: "APP_STORE",
      currentPeriodEnd: Date(timeIntervalSince1970: 1_800_000_000),
      consumableCredits: 0
    )
  }
}

private struct FixedBillingAPI: BillingAPI {
  let status: BillingStatus

  func fetchStatus() async throws -> BillingStatus { status }
}

private actor RetryOnceRestoreBillingClient: BillingClient {
  private let status: BillingStatus
  private let offering: BillingOffering
  private var restoreAttemptCount = 0

  init(status: BillingStatus, offering: BillingOffering) {
    self.status = status
    self.offering = offering
  }

  func configure(publicKey: String, appUserID: String) async throws {}
  func offerings() async throws -> [BillingOffering] { [offering] }
  func purchase(packageID: String) async throws -> BillingPurchaseResult {
    BillingPurchaseResult(packageID: packageID, outcome: .completed)
  }

  func restore() async throws -> BillingStatus {
    restoreAttemptCount += 1
    if restoreAttemptCount == 1 { throw BillingClientError.unavailable }
    return status
  }

  func currentStatus() async throws -> BillingStatus { status }
  func resetIdentity() async {}
  func restoreCalls() -> Int { restoreAttemptCount }
}

private actor ScriptedBillingClient: BillingClient {
  private var statuses: [Result<BillingStatus, BillingClientError>]
  private var offeringsValue: [BillingOffering]
  private var purchaseResult: BillingPurchaseResult
  private var purchaseIDs: [String] = []
  private var statusCalls = 0
  private var offeringCalls = 0
  private var restoreStatus: BillingStatus
  private var restoreCallCount = 0

  init(
    statuses: [Result<BillingStatus, BillingClientError>],
    offerings: [BillingOffering],
    purchaseResult: BillingPurchaseResult = BillingPurchaseResult(
      packageID: "fixture.package",
      outcome: .completed
    ),
    restoredVendorStatus: BillingStatus? = nil
  ) {
    self.statuses = statuses
    self.offeringsValue = offerings
    self.purchaseResult = purchaseResult
    self.restoreStatus = restoredVendorStatus ?? BillingStatus(
      isActive: false,
      productID: nil,
      store: nil,
      currentPeriodEnd: nil,
      consumableCredits: 0
    )
  }

  init(
    statuses: [BillingStatus],
    offerings: [BillingOffering],
    purchaseResult: BillingPurchaseResult = BillingPurchaseResult(
      packageID: "fixture.package",
      outcome: .completed
    ),
    restoredVendorStatus: BillingStatus? = nil
  ) {
    self.init(
      statuses: statuses.map(Result.success),
      offerings: offerings,
      purchaseResult: purchaseResult,
      restoredVendorStatus: restoredVendorStatus
    )
  }

  func configure(publicKey: String, appUserID: String) async throws {}

  func offerings() async throws -> [BillingOffering] {
    offeringCalls += 1
    return offeringsValue
  }

  func purchase(packageID: String) async throws -> BillingPurchaseResult {
    purchaseIDs.append(packageID)
    return purchaseResult
  }

  func restore() async throws -> BillingStatus {
    restoreCallCount += 1
    return restoreStatus
  }

  func currentStatus() async throws -> BillingStatus {
    statusCalls += 1
    return try nextStatus()
  }

  func resetIdentity() async {}

  func purchaseCalls() -> [String] { purchaseIDs }
  func currentStatusCalls() -> Int { statusCalls }
  func offeringsCalls() -> Int { offeringCalls }
  func restoreCalls() -> Int { restoreCallCount }

  private func nextStatus() throws -> BillingStatus {
    guard !statuses.isEmpty else { throw BillingClientError.api(.temporarilyUnavailable) }
    return try statuses.removeFirst().get()
  }
}
