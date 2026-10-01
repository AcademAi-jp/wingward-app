import Foundation
import XCTest
@testable import Wingward

@MainActor
final class RevenueCatBillingClientTests: XCTestCase {
  private let ownerA = "11111111-1111-4111-8111-111111111111"
  private let ownerB = "22222222-2222-4222-8222-222222222222"
  private let packageID = "wingward.premium.monthly"

  func testConfigureIsIdempotentForTheSameOwner() async throws {
    let bridge = RecordingRevenueCatStoreBridge()
    let coordinator = RevenueCatBillingConfigurationCoordinator()
    let isolatedClient = RevenueCatBillingClient(
      ownerID: ownerA,
      serverAPI: RecordingBillingAPI(status: inactiveStatus()),
      identityAPI: FixedBillingIdentityAPI(profileID: ownerA, appUserID: ownerA),
      bridge: bridge,
      coordinator: coordinator
    )

    try await isolatedClient.configure(publicKey: testPublicKey, appUserID: ownerA)
    try await isolatedClient.configure(publicKey: testPublicKey, appUserID: ownerA)

    let snapshot = await bridge.snapshot()
    XCTAssertEqual(snapshot.configureCallCount, 1)
    XCTAssertEqual(snapshot.loginIDs, [])
    XCTAssertEqual(snapshot.logoutCallCount, 0)
  }

  func testChangingOwnerLogsOutBeforeLoggingInTheNextOwner() async throws {
    let bridge = RecordingRevenueCatStoreBridge()
    let coordinator = RevenueCatBillingConfigurationCoordinator()
    let clientA = makeClient(ownerID: ownerA, bridge: bridge, coordinator: coordinator)
    let clientB = makeClient(ownerID: ownerB, bridge: bridge, coordinator: coordinator)

    try await clientA.configure(publicKey: testPublicKey, appUserID: ownerA)
    try await clientB.configure(publicKey: testPublicKey, appUserID: ownerB)

    let snapshot = await bridge.snapshot()
    XCTAssertEqual(snapshot.configureCallCount, 1)
    XCTAssertEqual(snapshot.logoutCallCount, 1)
    XCTAssertEqual(snapshot.loginIDs, [ownerB])
    XCTAssertEqual(snapshot.operations, ["configure", "logout", "login"])
  }

  func testResetIdentityIsIdempotentAndAllowsAReLogin() async throws {
    let bridge = RecordingRevenueCatStoreBridge()
    let coordinator = RevenueCatBillingConfigurationCoordinator()
    let clientA = makeClient(ownerID: ownerA, bridge: bridge, coordinator: coordinator)
    let clientB = makeClient(ownerID: ownerB, bridge: bridge, coordinator: coordinator)

    try await clientA.configure(publicKey: testPublicKey, appUserID: ownerA)
    await clientA.resetIdentity()
    await clientA.resetIdentity()
    try await clientB.configure(publicKey: testPublicKey, appUserID: ownerB)

    let snapshot = await bridge.snapshot()
    XCTAssertEqual(snapshot.configureCallCount, 1)
    XCTAssertEqual(snapshot.logoutCallCount, 1)
    XCTAssertEqual(snapshot.loginIDs, [ownerB])
    XCTAssertEqual(snapshot.operations, ["configure", "logout", "login"])
  }

  func testFailedLoginInvalidatesThePreviousOwnerUntilExplicitReconfigure() async throws {
    let bridge = RecordingRevenueCatStoreBridge(packages: [allowedPackage()])
    let coordinator = RevenueCatBillingConfigurationCoordinator()
    let clientA = makeClient(ownerID: ownerA, bridge: bridge, coordinator: coordinator)
    let clientB = makeClient(ownerID: ownerB, bridge: bridge, coordinator: coordinator)

    try await clientA.configure(publicKey: testPublicKey, appUserID: ownerA)
    await bridge.setLoginError(.unavailable)

    do {
      try await clientB.configure(publicKey: testPublicKey, appUserID: ownerB)
      XCTFail("A failed login must not report an owner switch")
    } catch let error as BillingClientError {
      XCTAssertEqual(error, .unavailable)
    }

    do {
      _ = try await clientA.purchase(packageID: packageID)
      XCTFail("The previous owner must be blocked after an uncertain login")
    } catch let error as BillingClientError {
      XCTAssertEqual(error, .notConfigured)
    }
    let blockedSnapshot = await bridge.snapshot()
    XCTAssertEqual(blockedSnapshot.purchasePackageIDs, [])
    XCTAssertFalse(blockedSnapshot.operations.contains("offerings"))

    await bridge.setLoginError(nil)
    try await clientA.configure(publicKey: testPublicKey, appUserID: ownerA)
    _ = try await clientA.purchase(packageID: packageID)
    let recoveredSnapshot = await bridge.snapshot()
    XCTAssertEqual(recoveredSnapshot.loginIDs, [ownerB, ownerA])
    XCTAssertEqual(recoveredSnapshot.purchasePackageIDs, [packageID])
  }

  func testFailedLogoutBlocksSdkOperationsUntilExplicitReconfigure() async throws {
    let bridge = RecordingRevenueCatStoreBridge(packages: [allowedPackage()])
    let client = makeClient(bridge: bridge)

    try await client.configure(publicKey: testPublicKey, appUserID: ownerA)
    await bridge.setLogoutError(.unavailable)
    await client.resetIdentity()

    do {
      _ = try await client.offerings()
      XCTFail("An uncertain logout must block offerings")
    } catch let error as BillingClientError {
      XCTAssertEqual(error, .notConfigured)
    }
    let blockedSnapshot = await bridge.snapshot()
    XCTAssertEqual(blockedSnapshot.purchasePackageIDs, [])
    XCTAssertFalse(blockedSnapshot.operations.contains("offerings"))

    await bridge.setLogoutError(nil)
    try await client.configure(publicKey: testPublicKey, appUserID: ownerA)
    let offerings = try await client.offerings()
    XCTAssertEqual(offerings.count, 1)
    let recoveredSnapshot = await bridge.snapshot()
    XCTAssertEqual(recoveredSnapshot.loginIDs, [ownerA])
  }

  func testOwnerSwitchWaitsForAnInFlightPurchaseAndRejectsTheStaleClient() async throws {
    let gate = RevenueCatPurchaseGate()
    let bridge = GatedRevenueCatStoreBridge(gate: gate, packages: [allowedPackage()])
    let coordinator = RevenueCatBillingConfigurationCoordinator()
    let clientA = makeClient(ownerID: ownerA, bridge: bridge, coordinator: coordinator)
    let clientB = makeClient(ownerID: ownerB, bridge: bridge, coordinator: coordinator)

    try await clientA.configure(publicKey: testPublicKey, appUserID: ownerA)
    let purchaseTask = Task { try await clientA.purchase(packageID: packageID) }
    await gate.waitUntilPurchaseStarted()

    let switchTask = Task { try await clientB.configure(publicKey: testPublicKey, appUserID: ownerB) }
    await Task.yield()
    let beforeRelease = await bridge.operationsSnapshot()
    XCTAssertEqual(beforeRelease, ["configure:\(ownerA)", "offerings", "purchase:\(packageID)"])

    await gate.releasePurchase()
    _ = try await purchaseTask.value
    try await switchTask.value

    let afterSwitch = await bridge.operationsSnapshot()
    XCTAssertEqual(
      afterSwitch,
      [
        "configure:\(ownerA)",
        "offerings",
        "purchase:\(packageID)",
        "logout",
        "login:\(ownerB)",
      ]
    )

    do {
      _ = try await clientA.offerings()
      XCTFail("A client from the previous owner must not read the new owner's offerings")
    } catch let error as BillingClientError {
      XCTAssertEqual(error, .notConfigured)
    }
    let finalOperations = await bridge.operationsSnapshot()
    XCTAssertEqual(finalOperations, afterSwitch)
  }

  func testResetWaitsForAnInFlightPurchaseAndMakesTheClientStale() async throws {
    let gate = RevenueCatPurchaseGate()
    let bridge = GatedRevenueCatStoreBridge(gate: gate, packages: [allowedPackage()])
    let client = makeClient(ownerID: ownerA, bridge: bridge)

    try await client.configure(publicKey: testPublicKey, appUserID: ownerA)
    let purchaseTask = Task { try await client.purchase(packageID: packageID) }
    await gate.waitUntilPurchaseStarted()

    let resetTask = Task { await client.resetIdentity() }
    await Task.yield()
    let beforeRelease = await bridge.operationsSnapshot()
    XCTAssertEqual(beforeRelease, ["configure:\(ownerA)", "offerings", "purchase:\(packageID)"])

    await gate.releasePurchase()
    _ = try await purchaseTask.value
    await resetTask.value

    let afterReset = await bridge.operationsSnapshot()
    XCTAssertEqual(
      afterReset,
      ["configure:\(ownerA)", "offerings", "purchase:\(packageID)", "logout"]
    )
    do {
      _ = try await client.offerings()
      XCTFail("A reset client must not read offerings until it is configured again")
    } catch let error as BillingClientError {
      XCTAssertEqual(error, .notConfigured)
    }
    let finalOperations = await bridge.operationsSnapshot()
    XCTAssertEqual(finalOperations, afterReset)
  }

  func testAnInvalidKeyCannotReachTheStoreBridge() async throws {
    let bridge = RecordingRevenueCatStoreBridge()
    let client = makeClient(bridge: bridge)

    do {
      try await client.configure(publicKey: "secret_key_like_value", appUserID: ownerA)
      XCTFail("A non-public SDK key must be rejected")
    } catch let error as BillingClientError {
      XCTAssertEqual(error, .notConfigured)
    }

    let snapshot = await bridge.snapshot()
    XCTAssertEqual(snapshot.configureCallCount, 0)
  }

  func testClientCannotConfigureAnUnexpectedOwner() async throws {
    let bridge = RecordingRevenueCatStoreBridge()
    let client = makeClient(ownerID: ownerA, bridge: bridge)

    do {
      try await client.configure(publicKey: testPublicKey, appUserID: ownerB)
      XCTFail("A client must stay bound to its captured owner")
    } catch let error as BillingClientError {
      XCTAssertEqual(error, .notConfigured)
    }

    let snapshot = await bridge.snapshot()
    XCTAssertEqual(snapshot.configureCallCount, 0)
  }

  func testProfileOwnerAndRevenueCatAuthIDAreDistinctCanonicalValues() async throws {
    let authID = "33333333-3333-4333-8333-333333333333"
    let bridge = RecordingRevenueCatStoreBridge()
    let client = makeClient(ownerID: ownerA, bridge: bridge, sdkAuthID: authID)

    try await client.configure(publicKey: testPublicKey, appUserID: authID)

    let snapshot = await bridge.snapshot()
    XCTAssertEqual(snapshot.configureAppUserIDs, [authID])
  }

  func testIdentityForAnotherProfileCannotConfigureThisOwner() async throws {
    let authID = "44444444-4444-4444-8444-444444444444"
    let bridge = RecordingRevenueCatStoreBridge()
    let client = makeClient(
      ownerID: ownerA,
      bridge: bridge,
      identityAPI: FixedBillingIdentityAPI(profileID: ownerB, appUserID: authID)
    )

    do {
      try await client.configure(publicKey: testPublicKey, appUserID: authID)
      XCTFail("A mismatched profile identity must not configure RevenueCat")
    } catch let error as BillingClientError {
      XCTAssertEqual(error, .notConfigured)
    }

    let snapshot = await bridge.snapshot()
    XCTAssertEqual(snapshot.configureCallCount, 0)
  }

  func testIdentityResolutionIsSerializedBeforeAnSdkOwnerSwitch() async throws {
    let authA = "55555555-5555-4555-8555-555555555555"
    let authB = "66666666-6666-4666-8666-666666666666"
    let identityA = DeferredBillingIdentityAPI()
    let identityB = DeferredBillingIdentityAPI()
    let bridge = RecordingRevenueCatStoreBridge()
    let coordinator = RevenueCatBillingConfigurationCoordinator()
    let clientA = makeClient(
      ownerID: ownerA,
      bridge: bridge,
      coordinator: coordinator,
      identityAPI: identityA
    )
    let clientB = makeClient(
      ownerID: ownerB,
      bridge: bridge,
      coordinator: coordinator,
      identityAPI: identityB
    )

    let configureA = Task { try await clientA.configure(publicKey: testPublicKey) }
    await identityA.waitUntilRequested()
    let configureB = Task { try await clientB.configure(publicKey: testPublicKey) }
    await Task.yield()
    let bWasRequestedBeforeAResolved = await identityB.wasRequested()
    XCTAssertFalse(bWasRequestedBeforeAResolved)

    await identityA.resolve(BillingIdentity(profileID: ownerA, appUserID: authA))
    try await configureA.value
    await identityB.waitUntilRequested()
    await identityB.resolve(BillingIdentity(profileID: ownerB, appUserID: authB))
    try await configureB.value

    let snapshot = await bridge.snapshot()
    XCTAssertEqual(snapshot.configureAppUserIDs, [authA])
    XCTAssertEqual(snapshot.loginIDs, [authB])
  }

  func testOfferingsFilterToTheClosedServerProductSetAndKeepStoreMetadata() async throws {
    let bridge = RecordingRevenueCatStoreBridge(
      packages: [
        RevenueCatStorePackage(
          packageID: packageID,
          productID: RevenueCatBillingProduct.premiumSubscriptionID,
          title: "Premium",
          localizedPrice: "$14.99"
        ),
        RevenueCatStorePackage(
          packageID: "unapproved.package",
          productID: "unapproved_product",
          title: "Should not display",
          localizedPrice: "$0.01"
        ),
      ]
    )
    let client = makeClient(bridge: bridge)
    try await client.configure(publicKey: testPublicKey, appUserID: ownerA)

    let offerings = try await client.offerings()

    XCTAssertEqual(
      offerings,
      [
        BillingOffering(
          packageID: packageID,
          productID: RevenueCatBillingProduct.premiumSubscriptionID,
          title: "Premium",
          localizedPrice: "$14.99"
        ),
      ]
    )
  }

  func testPurchaseMapsPendingWithoutReadingOrGrantingServerEntitlement() async throws {
    let bridge = RecordingRevenueCatStoreBridge(
      packages: [allowedPackage()],
      purchaseOutcome: .pending
    )
    let api = RecordingBillingAPI(status: inactiveStatus())
    let client = RevenueCatBillingClient(
      ownerID: ownerA,
      serverAPI: api,
      identityAPI: FixedBillingIdentityAPI(profileID: ownerA, appUserID: ownerA),
      bridge: bridge,
      coordinator: RevenueCatBillingConfigurationCoordinator()
    )
    try await client.configure(publicKey: testPublicKey, appUserID: ownerA)

    let result = try await client.purchase(packageID: packageID)

    XCTAssertEqual(result, BillingPurchaseResult(packageID: packageID, outcome: .pending))
    let serverFetchCount = await api.fetchCount()
    XCTAssertEqual(serverFetchCount, 0)
    let snapshot = await bridge.snapshot()
    XCTAssertEqual(snapshot.purchasePackageIDs, [packageID])
  }

  func testCancelledPurchaseIsSurfacedAsCancellation() async throws {
    let bridge = RecordingRevenueCatStoreBridge(
      packages: [allowedPackage()],
      purchaseOutcome: .cancelled
    )
    let client = makeClient(bridge: bridge)
    try await client.configure(publicKey: testPublicKey, appUserID: ownerA)

    do {
      _ = try await client.purchase(packageID: packageID)
      XCTFail("Cancellation must not be a successful purchase")
    } catch let error as BillingClientError {
      XCTAssertEqual(error, .cancelled)
    }
  }

  func testUnapprovedPurchaseIsRejectedBeforeTheBridgeCanPurchase() async throws {
    let bridge = RecordingRevenueCatStoreBridge(
      packages: [
        RevenueCatStorePackage(
          packageID: packageID,
          productID: "unapproved_product",
          title: "Unapproved",
          localizedPrice: "$1.00"
        ),
      ]
    )
    let client = makeClient(bridge: bridge)
    try await client.configure(publicKey: testPublicKey, appUserID: ownerA)

    do {
      _ = try await client.purchase(packageID: packageID)
      XCTFail("A product outside the server contract must not be purchased")
    } catch let error as BillingClientError {
      XCTAssertEqual(error, .invalidPackage)
    }

    let snapshot = await bridge.snapshot()
    XCTAssertEqual(snapshot.purchasePackageIDs, [])
  }

  func testAmbiguousPackageIdentifierFailsClosed() async throws {
    let bridge = RecordingRevenueCatStoreBridge(
      packages: [
        allowedPackage(),
        RevenueCatStorePackage(
          packageID: packageID,
          productID: RevenueCatBillingProduct.meetupCreditID,
          title: "Meetup credit",
          localizedPrice: "$4.99"
        ),
      ]
    )
    let client = makeClient(bridge: bridge)
    try await client.configure(publicKey: testPublicKey, appUserID: ownerA)

    do {
      _ = try await client.purchase(packageID: packageID)
      XCTFail("An ambiguous package ID must not be purchased")
    } catch let error as BillingClientError {
      XCTAssertEqual(error, .invalidPackage)
    }

    let snapshot = await bridge.snapshot()
    XCTAssertEqual(snapshot.purchasePackageIDs, [])
  }

  func testRestoreUsesTheVendorOnlyAsASignalThenReturnsServerStatus() async throws {
    let bridge = RecordingRevenueCatStoreBridge()
    let active = BillingStatus(
      isActive: true,
      productID: RevenueCatBillingProduct.premiumSubscriptionID,
      store: "TEST_STORE",
      currentPeriodEnd: Date(timeIntervalSince1970: 1_800_000_000),
      consumableCredits: 1
    )
    let api = RecordingBillingAPI(status: active)
    let client = RevenueCatBillingClient(
      ownerID: ownerA,
      serverAPI: api,
      identityAPI: FixedBillingIdentityAPI(profileID: ownerA, appUserID: ownerA),
      bridge: bridge,
      coordinator: RevenueCatBillingConfigurationCoordinator()
    )
    try await client.configure(publicKey: testPublicKey, appUserID: ownerA)

    let status = try await client.restore()

    XCTAssertEqual(status, active)
    let serverFetchCount = await api.fetchCount()
    XCTAssertEqual(serverFetchCount, 1)
    let snapshot = await bridge.snapshot()
    XCTAssertEqual(snapshot.restoreCallCount, 1)
  }

  func testCurrentStatusRemainsAvailableBeforeSdkConfiguration() async throws {
    let status = inactiveStatus()
    let client = RevenueCatBillingClient(
      ownerID: ownerA,
      serverAPI: RecordingBillingAPI(status: status),
      bridge: RecordingRevenueCatStoreBridge(),
      coordinator: RevenueCatBillingConfigurationCoordinator()
    )

    let currentStatus = try await client.currentStatus()
    XCTAssertEqual(currentStatus, status)
  }

  func testTestStoreKeyIsDebugOnly() {
#if DEBUG
    XCTAssertNoThrow(try RevenueCatAPIKeyPolicy.validate(publicKey: "test_public_key"))
#else
    XCTAssertThrowsError(try RevenueCatAPIKeyPolicy.validate(publicKey: "test_public_key"))
#endif
  }

  private var testPublicKey: String {
#if DEBUG
    "test_public_key"
#else
    "appl_public_key"
#endif
  }

  private func makeClient(
    ownerID: String = "11111111-1111-4111-8111-111111111111",
    bridge: any RevenueCatStoreBridge,
    coordinator: RevenueCatBillingConfigurationCoordinator = RevenueCatBillingConfigurationCoordinator(),
    serverAPI: (any BillingAPI)? = nil,
    sdkAuthID: String? = nil,
    identityAPI: (any BillingIdentityAPI)? = nil
  ) -> RevenueCatBillingClient {
    RevenueCatBillingClient(
      ownerID: ownerID,
      serverAPI: serverAPI ?? RecordingBillingAPI(status: inactiveStatus()),
      identityAPI: identityAPI ?? FixedBillingIdentityAPI(profileID: ownerID, appUserID: sdkAuthID ?? ownerID),
      bridge: bridge,
      coordinator: coordinator
    )
  }

  private func allowedPackage() -> RevenueCatStorePackage {
    RevenueCatStorePackage(
      packageID: packageID,
      productID: RevenueCatBillingProduct.premiumSubscriptionID,
      title: "Premium",
      localizedPrice: "$14.99"
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
}

private struct FixedBillingIdentityAPI: BillingIdentityAPI {
  let identity: BillingIdentity

  init(profileID: String, appUserID: String) {
    identity = BillingIdentity(profileID: profileID, appUserID: appUserID)
  }

  func fetchIdentity() async throws -> BillingIdentity {
    identity
  }
}

private actor DeferredBillingIdentityAPI: BillingIdentityAPI {
  private var requested = false
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []
  private var pending: CheckedContinuation<BillingIdentity, Never>?

  func fetchIdentity() async throws -> BillingIdentity {
    requested = true
    let waiters = requestWaiters
    requestWaiters.removeAll()
    waiters.forEach { $0.resume() }
    return await withCheckedContinuation { continuation in
      pending = continuation
    }
  }

  func waitUntilRequested() async {
    if requested { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append(continuation)
    }
  }

  func wasRequested() -> Bool {
    requested
  }

  func resolve(_ identity: BillingIdentity) {
    pending?.resume(returning: identity)
    pending = nil
  }
}

private struct RevenueCatBridgeSnapshot: Equatable, Sendable {
  let configureCallCount: Int
  let configureAppUserIDs: [String]
  let loginIDs: [String]
  let logoutCallCount: Int
  let operations: [String]
  let purchasePackageIDs: [String]
  let restoreCallCount: Int
}

private actor RecordingRevenueCatStoreBridge: RevenueCatStoreBridge {
  private var configureCallCount = 0
  private var configureAppUserIDs: [String] = []
  private var loginIDs: [String] = []
  private var logoutCallCount = 0
  private var operations: [String] = []
  private var purchasePackageIDs: [String] = []
  private var restoreCallCount = 0
  private var loginError: BillingClientError?
  private var logoutError: BillingClientError?

  private let packages: [RevenueCatStorePackage]
  private let purchaseOutcome: RevenueCatStorePurchaseOutcome

  init(
    packages: [RevenueCatStorePackage] = [],
    purchaseOutcome: RevenueCatStorePurchaseOutcome = .completed
  ) {
    self.packages = packages
    self.purchaseOutcome = purchaseOutcome
  }

  func configure(publicKey: String, appUserID: String) async throws {
    configureCallCount += 1
    configureAppUserIDs.append(appUserID)
    operations.append("configure")
  }

  func logIn(appUserID: String) async throws {
    loginIDs.append(appUserID)
    operations.append("login")
    if let loginError { throw loginError }
  }

  func logOut() async throws {
    logoutCallCount += 1
    operations.append("logout")
    if let logoutError { throw logoutError }
  }

  func currentPackages() async throws -> [RevenueCatStorePackage] {
    packages
  }

  func purchase(package: RevenueCatStorePackage) async throws -> RevenueCatStorePurchaseOutcome {
    purchasePackageIDs.append(package.packageID)
    return purchaseOutcome
  }

  func restore() async throws {
    restoreCallCount += 1
  }

  func snapshot() -> RevenueCatBridgeSnapshot {
    RevenueCatBridgeSnapshot(
      configureCallCount: configureCallCount,
      configureAppUserIDs: configureAppUserIDs,
      loginIDs: loginIDs,
      logoutCallCount: logoutCallCount,
      operations: operations,
      purchasePackageIDs: purchasePackageIDs,
      restoreCallCount: restoreCallCount
    )
  }

  func setLoginError(_ error: BillingClientError?) {
    loginError = error
  }

  func setLogoutError(_ error: BillingClientError?) {
    logoutError = error
  }
}

private actor RevenueCatPurchaseGate {
  private var purchaseStarted = false
  private var purchaseReleased = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func markPurchaseStarted() {
    purchaseStarted = true
    let waiters = startWaiters
    startWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func waitUntilPurchaseStarted() async {
    if purchaseStarted { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func releasePurchase() {
    purchaseReleased = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func waitUntilReleased() async {
    if purchaseReleased { return }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }
}

private actor GatedRevenueCatStoreBridge: RevenueCatStoreBridge {
  private let gate: RevenueCatPurchaseGate
  private let packages: [RevenueCatStorePackage]
  private var operations: [String] = []

  init(gate: RevenueCatPurchaseGate, packages: [RevenueCatStorePackage]) {
    self.gate = gate
    self.packages = packages
  }

  func configure(publicKey: String, appUserID: String) async throws {
    operations.append("configure:\(appUserID)")
  }

  func logIn(appUserID: String) async throws {
    operations.append("login:\(appUserID)")
  }

  func logOut() async throws {
    operations.append("logout")
  }

  func currentPackages() async throws -> [RevenueCatStorePackage] {
    operations.append("offerings")
    return packages
  }

  func purchase(package: RevenueCatStorePackage) async throws -> RevenueCatStorePurchaseOutcome {
    operations.append("purchase:\(package.packageID)")
    await gate.markPurchaseStarted()
    await gate.waitUntilReleased()
    return .completed
  }

  func restore() async throws {}

  func operationsSnapshot() -> [String] {
    operations
  }
}

private actor RecordingBillingAPI: BillingAPI {
  private let status: BillingStatus
  private var calls = 0

  init(status: BillingStatus) {
    self.status = status
  }

  func fetchStatus() async throws -> BillingStatus {
    calls += 1
    return status
  }

  func fetchCount() -> Int {
    calls
  }
}
