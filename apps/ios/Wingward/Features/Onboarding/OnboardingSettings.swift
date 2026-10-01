import Foundation

enum OnboardingLanguage: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case ja
  case en
}

enum OnboardingDatingMarket: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case JP
  case US
}

enum OnboardingDistanceUnit: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case km
  case mi
}

enum OnboardingGenderCategory: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case woman
  case man
  case nonbinary
}

enum OnboardingGenderVisibility: String, Codable, Equatable, Hashable, Sendable {
  case privateValue = "private"
}

enum OnboardingPreferenceMode: String, Codable, Equatable, Hashable, Sendable {
  case selected
  case noAnswer = "no_answer"
}

enum OnboardingLocationMode: String, Codable, Equatable, Hashable, Sendable {
  case station
  case noTransit = "no_transit"
  case notSet = "not_set"
}

enum OnboardingDTOValidationError: Error, Equatable, Sendable {
  case invalidValue
  case emptyValue
  case duplicateValue
}

private enum OnboardingCatalog {
  static let stationArea: [String: String] = [
    "jp-tokyo-shimokitazawa": "jp-tokyo-setagaya",
    "jp-tokyo-shibuya": "jp-tokyo-shibuya",
    "us-ca-sf-powell": "us-ca-san-francisco"
  ]

  static let stationMarkets: [String: OnboardingDatingMarket] = [
    "jp-tokyo-shimokitazawa": .JP,
    "jp-tokyo-shibuya": .JP,
    "us-ca-sf-powell": .US
  ]

  static let areaMarkets: [String: OnboardingDatingMarket] = [
    "jp-tokyo-setagaya": .JP,
    "jp-tokyo-shibuya": .JP,
    "us-ca-san-francisco": .US
  ]

  static func isIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 100 else { return false }
    return value.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil
  }
}

enum OnboardingTimeZoneCatalog {
  static let common: [String] = [
    "Asia/Tokyo",
    "America/Los_Angeles",
    "America/New_York",
    "America/Chicago",
    "Europe/London",
    "Europe/Paris",
    "Australia/Sydney",
    "UTC"
  ]

  static func choices(including savedValue: String? = nil) -> [String] {
    guard let savedValue, !savedValue.isEmpty, !common.contains(savedValue) else {
      return common
    }
    return [savedValue] + common
  }

  static func isValid(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 100 else { return false }
    // The API accepts IANA zone IDs and rejects fixed numeric offsets.
    guard value.range(of: "^[+-][0-9]{1,2}(?::?[0-9]{2})?$", options: .regularExpression) == nil else {
      return false
    }
    return TimeZone(identifier: value) != nil
  }
}

struct OnboardingSettings: Codable, Equatable, Sendable, APIValidatable {
  let uiLocale: OnboardingLanguage
  let datingMarket: OnboardingDatingMarket
  let conversationLanguage: OnboardingLanguage
  let timezone: String
  let distanceUnit: OnboardingDistanceUnit
  let genderIdentity: OnboardingGenderCategory?
  let genderVisibility: OnboardingGenderVisibility
  let preferredGenders: [OnboardingGenderCategory]
  let preferenceMode: OnboardingPreferenceMode
  let locationMode: OnboardingLocationMode
  let stationID: String?
  let coarseAreaID: String?

  enum CodingKeys: String, CodingKey {
    case uiLocale = "ui_locale"
    case datingMarket = "dating_market"
    case conversationLanguage = "conversation_language"
    case timezone
    case distanceUnit = "distance_unit"
    case genderIdentity = "gender_identity"
    case genderVisibility = "gender_visibility"
    case preferredGenders = "preferred_genders"
    case preferenceMode = "preference_mode"
    case locationMode = "location_mode"
    case stationID = "station_id"
    case coarseAreaID = "coarse_area_id"
  }

  init(
    uiLocale: OnboardingLanguage,
    datingMarket: OnboardingDatingMarket,
    conversationLanguage: OnboardingLanguage,
    timezone: String,
    distanceUnit: OnboardingDistanceUnit,
    genderIdentity: OnboardingGenderCategory?,
    genderVisibility: OnboardingGenderVisibility = .privateValue,
    preferredGenders: [OnboardingGenderCategory],
    preferenceMode: OnboardingPreferenceMode,
    locationMode: OnboardingLocationMode,
    stationID: String?,
    coarseAreaID: String?
  ) {
    self.uiLocale = uiLocale
    self.datingMarket = datingMarket
    self.conversationLanguage = conversationLanguage
    self.timezone = timezone
    self.distanceUnit = distanceUnit
    self.genderIdentity = genderIdentity
    self.genderVisibility = genderVisibility
    self.preferredGenders = preferredGenders
    self.preferenceMode = preferenceMode
    self.locationMode = locationMode
    self.stationID = stationID
    self.coarseAreaID = coarseAreaID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    uiLocale = try container.decode(OnboardingLanguage.self, forKey: .uiLocale)
    datingMarket = try container.decode(OnboardingDatingMarket.self, forKey: .datingMarket)
    conversationLanguage = try container.decode(OnboardingLanguage.self, forKey: .conversationLanguage)
    timezone = try container.decode(String.self, forKey: .timezone)
    distanceUnit = try container.decode(OnboardingDistanceUnit.self, forKey: .distanceUnit)
    guard container.contains(.genderIdentity), container.contains(.stationID), container.contains(.coarseAreaID) else {
      throw OnboardingDTOValidationError.invalidValue
    }
    genderIdentity = try container.decode(OnboardingGenderCategory?.self, forKey: .genderIdentity)
    genderVisibility = try container.decode(OnboardingGenderVisibility.self, forKey: .genderVisibility)
    preferredGenders = try container.decode([OnboardingGenderCategory].self, forKey: .preferredGenders)
    preferenceMode = try container.decode(OnboardingPreferenceMode.self, forKey: .preferenceMode)
    locationMode = try container.decode(OnboardingLocationMode.self, forKey: .locationMode)
    stationID = try container.decode(String?.self, forKey: .stationID)
    coarseAreaID = try container.decode(String?.self, forKey: .coarseAreaID)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(uiLocale, forKey: .uiLocale)
    try container.encode(datingMarket, forKey: .datingMarket)
    try container.encode(conversationLanguage, forKey: .conversationLanguage)
    try container.encode(timezone, forKey: .timezone)
    try container.encode(distanceUnit, forKey: .distanceUnit)
    try container.encode(genderIdentity, forKey: .genderIdentity)
    try container.encode(genderVisibility, forKey: .genderVisibility)
    try container.encode(preferredGenders, forKey: .preferredGenders)
    try container.encode(preferenceMode, forKey: .preferenceMode)
    try container.encode(locationMode, forKey: .locationMode)
    try container.encode(stationID, forKey: .stationID)
    try container.encode(coarseAreaID, forKey: .coarseAreaID)
  }

  static func validate(_ value: OnboardingSettings) throws {
    guard OnboardingTimeZoneCatalog.isValid(value.timezone) else {
      throw OnboardingDTOValidationError.invalidValue
    }
    guard value.genderVisibility == .privateValue else {
      throw OnboardingDTOValidationError.invalidValue
    }
    guard value.preferredGenders.count <= 3,
      Set(value.preferredGenders).count == value.preferredGenders.count
    else { throw OnboardingDTOValidationError.invalidValue }

    switch value.preferenceMode {
    case .selected:
      guard !value.preferredGenders.isEmpty else { throw OnboardingDTOValidationError.invalidValue }
    case .noAnswer:
      guard value.preferredGenders.isEmpty else { throw OnboardingDTOValidationError.invalidValue }
    }

    switch value.locationMode {
    case .notSet:
      guard value.stationID == nil, value.coarseAreaID == nil else {
        throw OnboardingDTOValidationError.invalidValue
      }
    case .noTransit:
      guard value.datingMarket == .US, value.stationID == nil, let area = value.coarseAreaID,
        OnboardingCatalog.isIdentifier(area), OnboardingCatalog.areaMarkets[area] == .US
      else { throw OnboardingDTOValidationError.invalidValue }
    case .station:
      guard let station = value.stationID, let area = value.coarseAreaID,
        OnboardingCatalog.isIdentifier(station), OnboardingCatalog.isIdentifier(area),
        OnboardingCatalog.stationMarkets[station] == value.datingMarket,
        OnboardingCatalog.areaMarkets[area] == value.datingMarket,
        OnboardingCatalog.stationArea[station] == area
      else { throw OnboardingDTOValidationError.invalidValue }
    }
  }
}

struct OnboardingStation: Codable, Equatable, Sendable {
  let id: String
  let name: String
  let coarseAreaID: String

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case coarseAreaID = "coarse_area_id"
  }
}

struct OnboardingArea: Codable, Equatable, Sendable {
  let id: String
  let name: String
}

struct OnboardingTerms: Codable, Equatable, Sendable {
  let market: OnboardingDatingMarket
  let status: String
}

struct OnboardingOptions: Codable, Equatable, Sendable, APIValidatable {
  let stations: [OnboardingStation]
  let areas: [OnboardingArea]
  let terms: OnboardingTerms
  let catalogStatus: String

  enum CodingKeys: String, CodingKey {
    case stations
    case areas
    case terms
    case catalogStatus = "catalog_status"
  }

  static func validate(_ value: OnboardingOptions) throws {
    guard value.terms.status == "draft", value.catalogStatus == "fixture" else {
      throw OnboardingDTOValidationError.invalidValue
    }
    let areaIDs = Set(value.areas.map(\.id))
    guard areaIDs.count == value.areas.count else { throw OnboardingDTOValidationError.invalidValue }
    for area in value.areas {
      guard OnboardingCatalog.isIdentifier(area.id), !area.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw OnboardingDTOValidationError.invalidValue
      }
    }
    let stationIDs = Set(value.stations.map(\.id))
    guard stationIDs.count == value.stations.count else { throw OnboardingDTOValidationError.invalidValue }
    for station in value.stations {
      guard OnboardingCatalog.isIdentifier(station.id),
        areaIDs.contains(station.coarseAreaID),
        !station.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw OnboardingDTOValidationError.invalidValue }
    }
  }
}

/// The server returns `{data:null}` before the first confirmed save.
struct NullableOnboardingSettingsPayload: Codable, Equatable, Sendable, APIValidatable {
  let settings: OnboardingSettings?

  init(settings: OnboardingSettings?) {
    self.settings = settings
  }

  init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    settings = value.decodeNil() ? nil : try value.decode(OnboardingSettings.self)
  }

  func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    if let settings {
      try value.encode(settings)
    } else {
      try value.encodeNil()
    }
  }

  static func validate(_ value: NullableOnboardingSettingsPayload) throws {
    if let settings = value.settings { try OnboardingSettings.validate(settings) }
  }
}

/// Captures one ordinary token, verifies the owner through `/api/auth/me`
/// with that same token, and returns only the verified captured token.
actor OwnerBoundAuthSessionTokenProvider: APIAccessTokenProvider {
  private let authService: any AuthService
  private let profileAPI: any ProfileAPI
  private let expectedOwnerID: String

  init(expectedOwnerID: String, authService: any AuthService, profileAPI: any ProfileAPI) {
    self.expectedOwnerID = expectedOwnerID
    self.authService = authService
    self.profileAPI = profileAPI
  }

  func accessToken() async throws -> String? {
    guard !expectedOwnerID.isEmpty else {
      throw APIClientError.unauthenticated
    }

    let session: AuthSession?
    do {
      session = try await authService.currentSession()
    } catch {
      if OnboardingCancellation.isCancellation(error) { throw APIClientError.cancelled }
      throw APIClientError.temporarilyUnavailable
    }
    guard let session, session.purpose == .ordinary, !session.accessToken.isEmpty else {
      throw APIClientError.unauthenticated
    }
    let capturedToken = session.accessToken

    let profile: UserProfile
    do {
      profile = try await profileAPI.fetchProfile(accessToken: capturedToken)
    } catch {
      if OnboardingCancellation.isCancellation(error) { throw APIClientError.cancelled }
      throw APIClientError.temporarilyUnavailable
    }
    guard profile.id == expectedOwnerID else { throw APIClientError.unauthenticated }
    return capturedToken
  }
}

protocol OnboardingSettingsAPI: Sendable {
  func fetchSettings() async throws -> OnboardingSettings?
  func fetchOptions(market: OnboardingDatingMarket, locale: OnboardingLanguage) async throws -> OnboardingOptions
  func saveSettings(_ settings: OnboardingSettings) async throws -> OnboardingSettings
}

struct LiveOnboardingSettingsAPI: OnboardingSettingsAPI, Sendable {
  static let settingsPath = "/api/auth/me/onboarding-settings"
  static let optionsPath = "/api/auth/me/onboarding-options"

  let client: any AuthenticatedAPIClientProtocol
  let ownerID: String?

  init(
    client: any AuthenticatedAPIClientProtocol,
    ownerID: String? = nil
  ) {
    self.client = client
    self.ownerID = ownerID
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
    let client = try AuthenticatedAPIClient(baseURL: baseURL, tokenProvider: provider, transport: transport)
    self.init(client: client, ownerID: ownerID)
  }

  func fetchSettings() async throws -> OnboardingSettings? {
    let payload = try await client.get(Self.settingsPath, as: NullableOnboardingSettingsPayload.self)
    return payload.settings
  }

  func fetchOptions(market: OnboardingDatingMarket, locale: OnboardingLanguage) async throws -> OnboardingOptions {
    let path = "\(Self.optionsPath)?dating_market=\(market.rawValue)&ui_locale=\(locale.rawValue)"
    let options = try await client.get(path, as: OnboardingOptions.self)
    guard options.terms.market == market else { throw APIClientError.invalidResponse }
    return options
  }

  func saveSettings(_ settings: OnboardingSettings) async throws -> OnboardingSettings {
    do {
      try OnboardingSettings.validate(settings)
    } catch {
      throw APIClientError.invalidRequest
    }
    let request = try APIRequest.json(method: .put, path: Self.settingsPath, body: settings)
    return try await client.send(request, as: OnboardingSettings.self)
  }
}

enum OnboardingCancellation {
  static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    if let clientError = error as? APIClientError, clientError == .cancelled { return true }
    return false
  }
}

#if DEBUG
private actor DebugOnboardingOptionsRetryState {
  private var didFailInitialRequest = false

  func shouldFailInitialRequest() -> Bool {
    guard !didFailInitialRequest else { return false }
    didFailInitialRequest = true
    return true
  }
}

struct DebugOnboardingSettingsAPI: OnboardingSettingsAPI, Sendable {
  let scenario: DebugOnboardingSettingsFixtureScenario
  let ownerID: String
  private let optionsRetryState: DebugOnboardingOptionsRetryState

  static let fixture = OnboardingSettings(
    uiLocale: .ja,
    datingMarket: .JP,
    conversationLanguage: .ja,
    timezone: "Asia/Tokyo",
    distanceUnit: .km,
    genderIdentity: .woman,
    preferredGenders: [.woman],
    preferenceMode: .selected,
    locationMode: .station,
    stationID: "jp-tokyo-shimokitazawa",
    coarseAreaID: "jp-tokyo-setagaya"
  )

  init(
    scenario: DebugOnboardingSettingsFixtureScenario = .standard,
    ownerID: String = UserProfile.fixture.id ?? ""
  ) {
    self.scenario = scenario
    self.ownerID = ownerID
    optionsRetryState = DebugOnboardingOptionsRetryState()
  }

  func fetchSettings() async throws -> OnboardingSettings? {
    try validateRetryFixtureOwner()
    return Self.fixture
  }

  func fetchOptions(market: OnboardingDatingMarket, locale: OnboardingLanguage) async throws -> OnboardingOptions {
    try validateRetryFixtureOwner()
    if scenario == .optionsRetry, await optionsRetryState.shouldFailInitialRequest() {
      throw APIClientError.temporarilyUnavailable
    }

    switch market {
    case .JP:
      let usesJapaneseNames = scenario == .optionsRetry && locale == .ja
      return OnboardingOptions(
        stations: [
          OnboardingStation(
            id: "jp-tokyo-shimokitazawa",
            name: usesJapaneseNames ? "下北沢" : "Shimokitazawa",
            coarseAreaID: "jp-tokyo-setagaya"
          ),
          OnboardingStation(
            id: "jp-tokyo-shibuya",
            name: usesJapaneseNames ? "渋谷" : "Shibuya",
            coarseAreaID: "jp-tokyo-shibuya"
          )
        ],
        areas: [
          OnboardingArea(
            id: "jp-tokyo-setagaya",
            name: usesJapaneseNames ? "世田谷" : "Setagaya"
          ),
          OnboardingArea(
            id: "jp-tokyo-shibuya",
            name: usesJapaneseNames ? "渋谷" : "Shibuya"
          )
        ],
        terms: OnboardingTerms(market: .JP, status: "draft"),
        catalogStatus: "fixture"
      )
    case .US:
      return OnboardingOptions(
        stations: [OnboardingStation(id: "us-ca-sf-powell", name: "Powell Street", coarseAreaID: "us-ca-san-francisco")],
        areas: [OnboardingArea(id: "us-ca-san-francisco", name: "San Francisco")],
        terms: OnboardingTerms(market: .US, status: "draft"),
        catalogStatus: "fixture"
      )
    }
  }

  func saveSettings(_ settings: OnboardingSettings) async throws -> OnboardingSettings {
    try validateRetryFixtureOwner()
    return settings
  }

  private func validateRetryFixtureOwner() throws {
    guard scenario != .optionsRetry || ownerID == UserProfile.fixture.id else {
      throw APIClientError.unauthenticated
    }
  }
}
#endif
