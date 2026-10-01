import Foundation

protocol BillingAPI: Sendable {
  func fetchStatus() async throws -> BillingStatus
}

struct LiveBillingAPI: BillingAPI, Sendable {
  static let statusPath = "/api/billing/status"

  let client: any AuthenticatedAPIClientProtocol

  init(client: any AuthenticatedAPIClientProtocol) {
    self.client = client
  }

  init(
    baseURL: URL,
    ownerID: String,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    transport: any APIHTTPTransport = URLSession(configuration: .ephemeral)
  ) throws {
    let provider = OwnerBoundAuthSessionTokenProvider(
      expectedOwnerID: ownerID,
      authService: authService,
      profileAPI: profileAPI
    )
    let client = try AuthenticatedAPIClient(
      baseURL: baseURL,
      tokenProvider: provider,
      transport: transport
    )
    self.init(client: client)
  }

  func fetchStatus() async throws -> BillingStatus {
    try await client.get(Self.statusPath, as: BillingStatus.self)
  }
}

enum BillingClientError: Error, Equatable, Sendable {
  /// The RevenueCat/StoreKit adapter is intentionally absent until the
  /// separately approved dependency and configuration run.
  case unavailable
  case notConfigured
  case invalidPackage
  case cancelled
  case api(APIClientError)

  var userMessage: String {
    switch self {
    case .unavailable, .notConfigured:
      return "Purchases are currently unavailable."
    case .invalidPackage:
      return "That purchase option is unavailable. Try again later."
    case .cancelled:
      return ""
    case .api(let error):
      switch error {
      case .unauthenticated:
        return "Sign in again before checking billing."
      case .rateLimited:
        return "Please wait a moment, then try again."
      case .cancelled:
        return ""
      case .invalidResponse, .invalidRequest, .invalidURL, .transportFailure,
        .temporarilyUnavailable, .forbidden, .ageVerificationRequired, .notFound,
        .invalidState, .quotaExhausted:
        return "We couldn't check billing right now. Try again."
      }
    }
  }
}

protocol BillingClient: Sendable {
  func configure(publicKey: String, appUserID: String) async throws
  func offerings() async throws -> [BillingOffering]
  func purchase(packageID: String) async throws -> BillingPurchaseResult
  func restore() async throws -> BillingStatus
  func currentStatus() async throws -> BillingStatus
  func resetIdentity() async
}

/// Production adapter used before the separately approved SDK install/config
/// run.  It exposes server status but cannot claim that a purchase or restore
/// works.  Keeping those operations explicit failures prevents a fake local
/// flag from being mistaken for a RevenueCat entitlement.
struct UnavailableBillingClient: BillingClient, Sendable {
  let serverAPI: any BillingAPI

  init(serverAPI: any BillingAPI) {
    self.serverAPI = serverAPI
  }

  func configure(publicKey: String, appUserID: String) async throws {
    throw BillingClientError.unavailable
  }

  func offerings() async throws -> [BillingOffering] {
    throw BillingClientError.unavailable
  }

  func purchase(packageID: String) async throws -> BillingPurchaseResult {
    throw BillingClientError.unavailable
  }

  func restore() async throws -> BillingStatus {
    throw BillingClientError.unavailable
  }

  func currentStatus() async throws -> BillingStatus {
    do {
      return try await serverAPI.fetchStatus()
    } catch let error as APIClientError {
      throw BillingClientError.api(error)
    } catch {
      throw BillingClientError.api(.temporarilyUnavailable)
    }
  }

  func resetIdentity() async {}
}

#if DEBUG
/// Deterministic in-memory billing fake.  It is for unit/UI fixtures only and
/// never contacts a store or changes server state.
actor FakeBillingClient: BillingClient {
  private(set) var configureCallCount = 0
  private(set) var offeringsCallCount = 0
  private(set) var purchasePackageIDs: [String] = []
  private(set) var restoreCallCount = 0
  private(set) var currentStatusCallCount = 0
  private(set) var resetIdentityCallCount = 0

  var configuredOfferings: [BillingOffering]
  var currentServerStatus: BillingStatus
  var restoredVendorStatus: BillingStatus
  var purchaseResult: BillingPurchaseResult
  var configureError: BillingClientError?
  var offeringsError: BillingClientError?
  var purchaseError: BillingClientError?
  var restoreError: BillingClientError?
  var currentStatusError: BillingClientError?

  init(
    status: BillingStatus,
    offerings: [BillingOffering] = [],
    purchaseResult: BillingPurchaseResult? = nil,
    restoredVendorStatus: BillingStatus? = nil
  ) {
    configuredOfferings = offerings
    currentServerStatus = status
    self.restoredVendorStatus = restoredVendorStatus ?? status
    self.purchaseResult = purchaseResult ?? BillingPurchaseResult(
      packageID: offerings.first?.packageID ?? "fixture.package",
      outcome: .completed
    )
  }

  func configure(publicKey: String, appUserID: String) async throws {
    configureCallCount += 1
    if let configureError { throw configureError }
  }

  func offerings() async throws -> [BillingOffering] {
    offeringsCallCount += 1
    if let offeringsError { throw offeringsError }
    return configuredOfferings
  }

  func purchase(packageID: String) async throws -> BillingPurchaseResult {
    purchasePackageIDs.append(packageID)
    if let purchaseError { throw purchaseError }
    guard configuredOfferings.contains(where: { $0.packageID == packageID }) else {
      throw BillingClientError.invalidPackage
    }
    return purchaseResult
  }

  func restore() async throws -> BillingStatus {
    restoreCallCount += 1
    if let restoreError { throw restoreError }
    return restoredVendorStatus
  }

  func currentStatus() async throws -> BillingStatus {
    currentStatusCallCount += 1
    if let currentStatusError { throw currentStatusError }
    return currentServerStatus
  }

  func resetIdentity() async {
    resetIdentityCallCount += 1
  }
}
#endif
