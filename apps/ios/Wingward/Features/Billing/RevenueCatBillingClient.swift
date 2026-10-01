import Foundation

#if canImport(RevenueCat)
import RevenueCat
#endif

/// Product identifiers that the server webhook normalizer accepts.
///
/// The client deliberately uses the same closed set. A product configured in a
/// RevenueCat offering is not automatically safe to sell to this app.
enum RevenueCatBillingProduct {
  static let premiumSubscriptionID = "wingward_premium_monthly"
  static let meetupCreditID = "wingward_meetup_credit"

  static let allowedProductIDs: Set<String> = [
    premiumSubscriptionID,
    meetupCreditID,
  ]

  static func isAllowed(_ productID: String) -> Bool {
    allowedProductIDs.contains(productID)
  }
}

enum RevenueCatStorePurchaseOutcome: Equatable, Sendable {
  case completed
  case pending
  case cancelled
}

/// A small value type that keeps RevenueCat types out of the feature layer and
/// makes the adapter testable before the SDK package is installed.
struct RevenueCatStorePackage: Equatable, Sendable {
  let packageID: String
  let productID: String
  let title: String
  let localizedPrice: String

  init(packageID: String, productID: String, title: String, localizedPrice: String) {
    self.packageID = packageID
    self.productID = productID
    self.title = title
    self.localizedPrice = localizedPrice
  }
}

/// Canonical identity returned by the authenticated billing route. The
/// profile owner is the API's user_profiles.id; appUserID is the Supabase
/// auth.users.id used as RevenueCat's app user ID. They are intentionally
/// separate values.
struct BillingIdentity: APIValidatable, Codable, Equatable, Sendable {
  let profileID: String
  let appUserID: String

  private enum CodingKeys: String, CodingKey {
    case profileID = "profile_id"
    case appUserID = "app_user_id"
  }

  init(profileID: String, appUserID: String) {
    self.profileID = profileID
    self.appUserID = appUserID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      profileID: try container.decode(String.self, forKey: .profileID),
      appUserID: try container.decode(String.self, forKey: .appUserID)
    )
    try Self.validate(self)
  }

  static func validate(_ value: BillingIdentity) throws {
    _ = try APIDTOValidation.requireUUID(value.profileID)
    _ = try APIDTOValidation.requireUUID(value.appUserID)
  }
}

protocol BillingIdentityAPI: Sendable {
  func fetchIdentity() async throws -> BillingIdentity
}

private struct UnavailableBillingIdentityAPI: BillingIdentityAPI {
  func fetchIdentity() async throws -> BillingIdentity {
    throw BillingClientError.notConfigured
  }
}

struct LiveBillingIdentityAPI: BillingIdentityAPI, Sendable {
  static let identityPath = "/api/billing/identity"

  let client: any AuthenticatedAPIClientProtocol

  init(client: any AuthenticatedAPIClientProtocol) {
    self.client = client
  }

  func fetchIdentity() async throws -> BillingIdentity {
    try await client.get(Self.identityPath, as: BillingIdentity.self)
  }
}

protocol RevenueCatStoreBridge: Sendable {
  func configure(publicKey: String, appUserID: String) async throws
  func logIn(appUserID: String) async throws
  func logOut() async throws
  func currentPackages() async throws -> [RevenueCatStorePackage]
  func purchase(package: RevenueCatStorePackage) async throws -> RevenueCatStorePurchaseOutcome
  func restore() async throws
}

/// Build-time policy for the two RevenueCat key classes used by this app.
/// Test Store keys are accepted only in debug builds; a Release build can only
/// be configured with the iOS platform key.
enum RevenueCatAPIKeyPolicy {
  static func validate(publicKey: String) throws {
    let trimmed = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed == publicKey,
          trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw BillingClientError.notConfigured
    }

#if DEBUG
    guard trimmed.hasPrefix("test_") || trimmed.hasPrefix("appl_") else {
      throw BillingClientError.notConfigured
    }
#else
    guard trimmed.hasPrefix("appl_") else {
      throw BillingClientError.notConfigured
    }
#endif
  }

  static func validate(appUserID: String) throws {
    let trimmed = appUserID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed == appUserID,
          trimmed.count <= 255,
          trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw BillingClientError.notConfigured
    }
  }
}

/// Serializes the process-wide RevenueCat singleton and identity changes.
/// `Purchases.configure` is intentionally called at most once by this state
/// machine. Signing out keeps the configured SDK alive and logs in the next
/// owner instead of attempting a second SDK configuration.
actor RevenueCatAsyncLock {
  private var isLocked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !isLocked {
      isLocked = true
      return
    }

    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    if waiters.isEmpty {
      isLocked = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

actor RevenueCatBillingConfigurationCoordinator {
  static let shared = RevenueCatBillingConfigurationCoordinator()

  private enum IdentityState: Equatable {
    case unconfigured
    case active(profileOwnerID: String, sdkAuthUserID: String)
    case anonymous
    /// A logout/login operation was interrupted or failed. No operation may
    /// assume which RevenueCat user the process singleton currently has.
    case needsReconciliation
  }

  // Actor isolation alone is re-entrant across `await`. This separate async
  // lock keeps a configure, identity change, purchase, restore, or offerings
  // lookup together while the SDK is suspended on StoreKit/network work.
  private let sdkLock = RevenueCatAsyncLock()
  private var configuredPublicKey: String?
  private var identityState: IdentityState = .unconfigured
  private var configuredBridge: (any RevenueCatStoreBridge)?

  func configure(
    publicKey: String,
    profileOwnerID: String,
    identityAPI: any BillingIdentityAPI,
    requestedSDKAuthUserID: String?,
    bridge: any RevenueCatStoreBridge
  ) async throws {
    try RevenueCatAPIKeyPolicy.validate(publicKey: publicKey)

    await sdkLock.acquire()
    do {
      try Task.checkCancellation()

      // Resolve identity while the SDK lock is held. A delayed response for
      // an old owner must not arrive after another owner configured the
      // singleton and then switch it back.
      let identity: BillingIdentity
      do {
        identity = try await identityAPI.fetchIdentity()
        try BillingIdentity.validate(identity)
      } catch let error as BillingClientError {
        throw error
      } catch let error as APIClientError {
        throw BillingClientError.api(error)
      } catch {
        throw BillingClientError.notConfigured
      }
      guard identity.profileID == profileOwnerID,
            requestedSDKAuthUserID == nil || requestedSDKAuthUserID == identity.appUserID
      else {
        throw BillingClientError.notConfigured
      }
      let sdkAuthUserID = identity.appUserID
      try RevenueCatAPIKeyPolicy.validate(appUserID: sdkAuthUserID)

      if let configuredPublicKey {
        guard let configuredBridge else {
          throw BillingClientError.notConfigured
        }
        guard configuredPublicKey == publicKey else {
          // The SDK is a process singleton. Replacing its API key in a
          // running app could mix Test Store and real-store state, so fail
          // closed.
          throw BillingClientError.notConfigured
        }

        if case .active(let activeProfileOwnerID, let activeSDKAuthUserID) = identityState,
           activeProfileOwnerID == profileOwnerID {
          guard activeSDKAuthUserID == sdkAuthUserID else {
            throw BillingClientError.notConfigured
          }
          await sdkLock.release()
          return
        }

        // Invalidate the old owner before the first identity-changing await.
        // If either call fails, the SDK may be anonymous or otherwise
        // uncertain; the old owner must never remain authorized locally.
        let shouldLogout = identityState != .anonymous
        identityState = .needsReconciliation
        do {
          if shouldLogout {
            try await configuredBridge.logOut()
          }
          try await configuredBridge.logIn(appUserID: sdkAuthUserID)
          identityState = .active(profileOwnerID: profileOwnerID, sdkAuthUserID: sdkAuthUserID)
          await sdkLock.release()
          return
        } catch {
          identityState = .needsReconciliation
          throw error
        }
      }

      try await bridge.configure(publicKey: publicKey, appUserID: sdkAuthUserID)
      configuredPublicKey = publicKey
      configuredBridge = bridge
      identityState = .active(profileOwnerID: profileOwnerID, sdkAuthUserID: sdkAuthUserID)
      await sdkLock.release()
    } catch {
      await sdkLock.release()
      throw error
    }
  }

  func resetIdentity(expectedOwnerID: String) async {
    await sdkLock.acquire()
    guard configuredPublicKey != nil,
          isActiveOwner(expectedOwnerID),
          let configuredBridge
    else {
      await sdkLock.release()
      return
    }

    // Invalidate the owner before awaiting logout. A thrown logout may still
    // have changed the SDK identity, so retaining the old owner would allow a
    // stale purchase or restore to run under an unknown account.
    identityState = .needsReconciliation
    do {
      try await configuredBridge.logOut()
      identityState = .anonymous
    } catch {
      // BillingClient.resetIdentity cannot report an error. Keep the local
      // state as uncertain; an explicit configure must reconcile it.
    }
    await sdkLock.release()
  }

  func withCurrentOwner<T: Sendable>(
    expectedOwnerID: String,
    operation: @escaping @Sendable (any RevenueCatStoreBridge) async throws -> T
  ) async throws -> T {
    await sdkLock.acquire()
    do {
      try Task.checkCancellation()
      guard isActiveOwner(expectedOwnerID),
            let configuredBridge
      else {
        throw BillingClientError.notConfigured
      }
      let result = try await operation(configuredBridge)
      await sdkLock.release()
      return result
    } catch {
      await sdkLock.release()
      throw error
    }
  }

  func withStatusAccess<T: Sendable>(
    expectedOwnerID: String,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    await sdkLock.acquire()
    do {
      try Task.checkCancellation()
      // A status read is allowed before the first SDK configure so the UI can
      // show the server mirror while the store is unavailable. After a
      // configure/reset boundary it is bound to the active owner.
      if configuredPublicKey != nil {
        guard isActiveOwner(expectedOwnerID) else {
          throw BillingClientError.notConfigured
        }
      }
      let result = try await operation()
      await sdkLock.release()
      return result
    } catch {
      await sdkLock.release()
      throw error
    }
  }

  private func isActiveOwner(_ expectedOwnerID: String) -> Bool {
    guard case .active(let profileOwnerID, _) = identityState else { return false }
    return profileOwnerID == expectedOwnerID
  }
}

/// RevenueCat-backed implementation of the app's vendor-neutral billing
/// protocol. The server mirror remains authoritative for entitlement status.
/// Each instance is bound to the owner that created its authenticated API
/// client; construct a new instance after an auth account switch.
///
/// When the RevenueCat package is not linked, the default bridge is an explicit
/// unavailable adapter. This file therefore compiles in the current worktree,
/// but it does not claim that SDK calls have been built or verified.
struct RevenueCatBillingClient: BillingClient, Sendable {
  private let expectedOwnerID: String
  private let serverAPI: any BillingAPI
  private let identityAPI: any BillingIdentityAPI
  private let bridge: any RevenueCatStoreBridge
  private let coordinator: RevenueCatBillingConfigurationCoordinator

  init(
    ownerID: String,
    serverAPI: any BillingAPI,
    identityAPI: any BillingIdentityAPI = UnavailableBillingIdentityAPI(),
    bridge: any RevenueCatStoreBridge = RevenueCatStoreBridgeFactory.make(),
    coordinator: RevenueCatBillingConfigurationCoordinator = .shared
  ) {
    self.expectedOwnerID = ownerID
    self.serverAPI = serverAPI
    self.identityAPI = identityAPI
    self.bridge = bridge
    self.coordinator = coordinator
  }

  func configure(publicKey: String, appUserID: String) async throws {
    try await coordinator.configure(
      publicKey: publicKey,
      profileOwnerID: expectedOwnerID,
      identityAPI: identityAPI,
      requestedSDKAuthUserID: appUserID,
      bridge: bridge
    )
  }

  /// Owner-bound convenience used by the live app factory. The auth ID comes
  /// only from the authenticated identity route, never from caller state.
  func configure(publicKey: String) async throws {
    try await coordinator.configure(
      publicKey: publicKey,
      profileOwnerID: expectedOwnerID,
      identityAPI: identityAPI,
      requestedSDKAuthUserID: nil,
      bridge: bridge
    )
  }

  func offerings() async throws -> [BillingOffering] {
    try await coordinator.withCurrentOwner(
      expectedOwnerID: expectedOwnerID
    ) { bridge in
      let packages = try await bridge.currentPackages()
      return try Self.makeOfferings(from: packages)
    }
  }

  func purchase(packageID: String) async throws -> BillingPurchaseResult {
    try await coordinator.withCurrentOwner(
      expectedOwnerID: expectedOwnerID
    ) { bridge in
      let packages = try await bridge.currentPackages()
      let matchingPackages = packages.filter {
        $0.packageID == packageID && RevenueCatBillingProduct.isAllowed($0.productID)
      }
      guard matchingPackages.count == 1, let package = matchingPackages.first else {
        throw BillingClientError.invalidPackage
      }

      switch try await bridge.purchase(package: package) {
      case .completed:
        return BillingPurchaseResult(packageID: packageID, outcome: .completed)
      case .pending:
        // Pending is a real store state. The caller must wait for the server
        // webhook mirror and must not unlock from this local signal.
        return BillingPurchaseResult(packageID: packageID, outcome: .pending)
      case .cancelled:
        throw BillingClientError.cancelled
      }
    }
  }

  func restore() async throws -> BillingStatus {
    let serverAPI = self.serverAPI
    return try await coordinator.withCurrentOwner(
      expectedOwnerID: expectedOwnerID
    ) { bridge in
      // The SDK result is only a signal that the store was queried. The
      // return value comes from the authenticated server mirror below.
      try await bridge.restore()
      return try await Self.readServerStatus(from: serverAPI)
    }
  }

  func currentStatus() async throws -> BillingStatus {
    let serverAPI = self.serverAPI
    return try await coordinator.withStatusAccess(expectedOwnerID: expectedOwnerID) {
      try await Self.readServerStatus(from: serverAPI)
    }
  }

  func resetIdentity() async {
    await coordinator.resetIdentity(expectedOwnerID: expectedOwnerID)
  }

  private static func makeOfferings(from packages: [RevenueCatStorePackage]) throws -> [BillingOffering] {
    var seenPackageIDs = Set<String>()
    var offerings: [BillingOffering] = []
    offerings.reserveCapacity(packages.count)

    for package in packages {
      guard !package.packageID.isEmpty,
            RevenueCatBillingProduct.isAllowed(package.productID)
      else {
        continue
      }

      guard seenPackageIDs.insert(package.packageID).inserted else {
        // Two packages with the same identifier would make a purchase request
        // ambiguous. Do not display or purchase either one.
        throw BillingClientError.api(.invalidResponse)
      }

      offerings.append(
        BillingOffering(
          packageID: package.packageID,
          productID: package.productID,
          title: package.title,
          localizedPrice: package.localizedPrice
        )
      )
    }

    return offerings
  }

  private static func readServerStatus(from serverAPI: any BillingAPI) async throws -> BillingStatus {
    do {
      let status = try await serverAPI.fetchStatus()
      try BillingStatus.validate(status)
      return status
    } catch let error as BillingClientError {
      throw error
    } catch let error as APIClientError {
      throw BillingClientError.api(error)
    } catch let error as BillingDTOValidationError {
      throw error
    } catch {
      throw BillingClientError.api(.temporarilyUnavailable)
    }
  }
}

private enum RevenueCatStoreBridgeFactory {
  static func make() -> any RevenueCatStoreBridge {
#if canImport(RevenueCat)
    RevenueCatPurchasesStoreBridge()
#else
    UnavailableRevenueCatStoreBridge()
#endif
  }
}

private struct UnavailableRevenueCatStoreBridge: RevenueCatStoreBridge {
  func configure(publicKey: String, appUserID: String) async throws {
    throw BillingClientError.unavailable
  }

  func logIn(appUserID: String) async throws {
    throw BillingClientError.unavailable
  }

  func logOut() async throws {
    throw BillingClientError.unavailable
  }

  func currentPackages() async throws -> [RevenueCatStorePackage] {
    throw BillingClientError.unavailable
  }

  func purchase(package: RevenueCatStorePackage) async throws -> RevenueCatStorePurchaseOutcome {
    throw BillingClientError.unavailable
  }

  func restore() async throws {
    throw BillingClientError.unavailable
  }
}

#if canImport(RevenueCat)
private struct RevenueCatPurchasesStoreBridge: RevenueCatStoreBridge {
  func configure(publicKey: String, appUserID: String) async throws {
    if Purchases.isConfigured {
      // The SDK does not expose its configured API key. Reusing an instance
      // configured by another layer could silently mix Test Store and
      // real-store state, so the adapter owns the first configure call.
      throw BillingClientError.notConfigured
    }

    _ = Purchases.configure(withAPIKey: publicKey, appUserID: appUserID)
  }

  func logIn(appUserID: String) async throws {
    guard Purchases.isConfigured else { throw BillingClientError.notConfigured }
    guard Purchases.shared.appUserID != appUserID else { return }
    if !Purchases.shared.isAnonymous {
      _ = try await Purchases.shared.logOut()
    }
    _ = try await Purchases.shared.logIn(appUserID)
  }

  func logOut() async throws {
    guard Purchases.isConfigured, !Purchases.shared.isAnonymous else { return }
    _ = try await Purchases.shared.logOut()
  }

  func currentPackages() async throws -> [RevenueCatStorePackage] {
    guard Purchases.isConfigured else { throw BillingClientError.notConfigured }
    let offerings = try await Purchases.shared.offerings()
    guard let currentOffering = offerings.current else { return [] }

    return currentOffering.availablePackages.map { package in
      RevenueCatStorePackage(
        packageID: package.identifier,
        productID: package.storeProduct.productIdentifier,
        title: package.storeProduct.localizedTitle,
        localizedPrice: package.storeProduct.localizedPriceString
      )
    }
  }

  func purchase(package: RevenueCatStorePackage) async throws -> RevenueCatStorePurchaseOutcome {
    guard Purchases.isConfigured else { throw BillingClientError.notConfigured }

    // Resolve the package from the current offering immediately before the
    // purchase. Offering configuration can change after the paywall loaded.
    let offerings = try await Purchases.shared.offerings()
    guard let currentOffering = offerings.current,
          let sdkPackage = currentOffering.availablePackages.first(where: {
            $0.identifier == package.packageID
              && $0.storeProduct.productIdentifier == package.productID
              && RevenueCatBillingProduct.isAllowed($0.storeProduct.productIdentifier)
          })
    else {
      throw BillingClientError.invalidPackage
    }

    do {
      let result = try await Purchases.shared.purchase(package: sdkPackage)
      return result.userCancelled ? .cancelled : .completed
    } catch {
      let code = (error as NSError).code
      if code == ErrorCode.purchaseCancelledError.rawValue {
        return .cancelled
      }
      if code == ErrorCode.paymentPendingError.rawValue {
        return .pending
      }
      throw error
    }
  }

  func restore() async throws {
    guard Purchases.isConfigured else { throw BillingClientError.notConfigured }
    _ = try await Purchases.shared.restorePurchases()
  }
}
#endif
