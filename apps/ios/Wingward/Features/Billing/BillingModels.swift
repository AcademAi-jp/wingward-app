import Foundation

/// The server-owned subscription mirror returned by `/api/billing/status`.
///
/// RevenueCat/StoreKit state is deliberately not represented here.  This DTO
/// is the only status a feature may use to decide whether premium access is
/// available.
struct BillingStatus: APIValidatable, Codable, Equatable, Sendable {
  let isActive: Bool
  let productID: String?
  let store: String?
  let currentPeriodEnd: Date?
  let consumableCredits: Int

  private enum CodingKeys: String, CodingKey {
    case isActive = "is_active"
    case productID = "product_id"
    case store
    case currentPeriodEnd = "current_period_end"
    case consumableCredits = "consumable_credits"
  }

  init(
    isActive: Bool,
    productID: String?,
    store: String?,
    currentPeriodEnd: Date?,
    consumableCredits: Int
  ) {
    self.isActive = isActive
    self.productID = productID
    self.store = store
    self.currentPeriodEnd = currentPeriodEnd
    self.consumableCredits = consumableCredits
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      isActive: try container.decode(Bool.self, forKey: .isActive),
      productID: try container.decodeIfPresent(String.self, forKey: .productID),
      store: try container.decodeIfPresent(String.self, forKey: .store),
      currentPeriodEnd: try BillingStatus.decodeTimestamp(
        container.decodeIfPresent(String.self, forKey: .currentPeriodEnd)
      ),
      consumableCredits: try container.decode(Int.self, forKey: .consumableCredits)
    )
    try Self.validate(self)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(isActive, forKey: .isActive)
    try container.encodeIfPresent(productID, forKey: .productID)
    try container.encodeIfPresent(store, forKey: .store)
    if let currentPeriodEnd {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      try container.encode(formatter.string(from: currentPeriodEnd), forKey: .currentPeriodEnd)
    } else {
      try container.encodeNil(forKey: .currentPeriodEnd)
    }
    try container.encode(consumableCredits, forKey: .consumableCredits)
  }

  static func validate(_ value: BillingStatus) throws {
    guard value.consumableCredits >= 0, value.consumableCredits <= 1_000_000 else {
      throw BillingDTOValidationError.invalidCreditBalance
    }

    if let productID = value.productID {
      try APIDTOValidation.requireNonEmpty(productID)
      guard productID.count <= 255 else { throw BillingDTOValidationError.valueTooLong }
    }
    if let store = value.store {
      try APIDTOValidation.requireNonEmpty(store)
      guard store.count <= 64 else { throw BillingDTOValidationError.valueTooLong }
    }

    // An active mirror without the product that granted it is not safe to
    // present as premium.  Inactive rows may omit all subscription fields.
    if value.isActive, value.productID == nil {
      throw BillingDTOValidationError.activeStatusMissingProduct
    }
  }

  private static func decodeTimestamp(_ rawValue: String?) throws -> Date? {
    guard let rawValue else { return nil }
    return try APIDTOValidation.requireRFC3339(rawValue)
  }

}

enum BillingDTOValidationError: Error, Equatable, Sendable {
  case activeStatusMissingProduct
  case invalidCreditBalance
  case valueTooLong
}

/// A price and package identity supplied by the configured store adapter.
/// The app never invents price text; a real adapter must provide the localized
/// value returned by StoreKit/RevenueCat.
struct BillingOffering: Equatable, Hashable, Identifiable, Sendable {
  let packageID: String
  let productID: String
  let title: String
  let localizedPrice: String

  var id: String { packageID }

  init(packageID: String, productID: String, title: String, localizedPrice: String) {
    self.packageID = packageID
    self.productID = productID
    self.title = title
    self.localizedPrice = localizedPrice
  }
}

enum BillingPurchaseOutcome: String, Codable, Equatable, Sendable {
  case completed
  case pending
}

/// A purchase result is intentionally vendor-neutral.  The store refreshes
/// `BillingStatus` from the server after receiving this value, so this result
/// alone can never grant access.
struct BillingPurchaseResult: Codable, Equatable, Sendable {
  let packageID: String
  let outcome: BillingPurchaseOutcome

  private enum CodingKeys: String, CodingKey {
    case packageID = "package_id"
    case outcome
  }

  init(packageID: String, outcome: BillingPurchaseOutcome) {
    self.packageID = packageID
    self.outcome = outcome
  }
}
