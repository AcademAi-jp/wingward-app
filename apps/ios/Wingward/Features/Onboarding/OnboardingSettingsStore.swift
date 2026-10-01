import Foundation
import Observation

enum OnboardingGenderIdentitySelection: Equatable, Hashable, Sendable {
  case unselected
  case noAnswer
  case selected(OnboardingGenderCategory)
}

enum OnboardingSettingsDraftIssue: Error, Equatable, Sendable {
  case uiLocaleRequired
  case conversationLanguageRequired
  case datingMarketRequired
  case timezoneRequired
  case distanceUnitRequired
  case genderIdentityRequired
  case preferenceModeRequired
  case preferredGendersRequired
  case locationModeRequired
  case stationRequired
  case areaRequired
  case invalidSettings

  var userMessage: String {
    switch self {
    case .uiLocaleRequired: return "Choose a display language."
    case .conversationLanguageRequired: return "Choose a conversation language."
    case .datingMarketRequired: return "Choose a dating market."
    case .timezoneRequired: return "Choose a time zone."
    case .distanceUnitRequired: return "Choose a distance unit."
    case .genderIdentityRequired: return "Choose an identity or prefer not to say."
    case .preferenceModeRequired: return "Choose whether to answer this preference."
    case .preferredGendersRequired: return "Choose at least one preferred gender."
    case .locationModeRequired: return "Choose a location option."
    case .stationRequired: return "Choose a station."
    case .areaRequired: return "Choose an area."
    case .invalidSettings: return "Review the settings and try again."
    }
  }
}

struct OnboardingSettingsDraft: Equatable, Sendable {
  var uiLocale: OnboardingLanguage?
  var conversationLanguage: OnboardingLanguage?
  var datingMarket: OnboardingDatingMarket?
  var timezone: String?
  var distanceUnit: OnboardingDistanceUnit?
  var genderIdentity: OnboardingGenderIdentitySelection = .unselected
  var genderVisibility: OnboardingGenderVisibility = .privateValue
  var preferredGenders: [OnboardingGenderCategory] = []
  var preferenceMode: OnboardingPreferenceMode?
  var locationMode: OnboardingLocationMode?
  var stationID: String?
  var coarseAreaID: String?

  static let empty = OnboardingSettingsDraft()

  init() {}

  init(settings: OnboardingSettings) {
    uiLocale = settings.uiLocale
    conversationLanguage = settings.conversationLanguage
    datingMarket = settings.datingMarket
    timezone = settings.timezone
    distanceUnit = settings.distanceUnit
    genderIdentity = settings.genderIdentity.map(OnboardingGenderIdentitySelection.selected) ?? .noAnswer
    genderVisibility = settings.genderVisibility
    preferredGenders = settings.preferredGenders
    preferenceMode = settings.preferenceMode
    locationMode = settings.locationMode
    stationID = settings.stationID
    coarseAreaID = settings.coarseAreaID
  }

  func materialized() -> Result<OnboardingSettings, OnboardingSettingsDraftIssue> {
    guard let uiLocale else { return .failure(.uiLocaleRequired) }
    guard let conversationLanguage else { return .failure(.conversationLanguageRequired) }
    guard let datingMarket else { return .failure(.datingMarketRequired) }
    guard let timezone, !timezone.isEmpty else { return .failure(.timezoneRequired) }
    guard let distanceUnit else { return .failure(.distanceUnitRequired) }

    let genderIdentityValue: OnboardingGenderCategory?
    switch genderIdentity {
    case .unselected:
      return .failure(.genderIdentityRequired)
    case .noAnswer:
      genderIdentityValue = nil
    case let .selected(value):
      genderIdentityValue = value
    }

    guard let preferenceMode else { return .failure(.preferenceModeRequired) }
    if preferenceMode == .selected, preferredGenders.isEmpty {
      return .failure(.preferredGendersRequired)
    }
    if preferenceMode == .noAnswer, !preferredGenders.isEmpty {
      return .failure(.invalidSettings)
    }

    guard let locationMode else { return .failure(.locationModeRequired) }
    switch locationMode {
    case .notSet:
      guard stationID == nil, coarseAreaID == nil else { return .failure(.invalidSettings) }
    case .station:
      guard stationID != nil else { return .failure(.stationRequired) }
      guard coarseAreaID != nil else { return .failure(.areaRequired) }
    case .noTransit:
      guard datingMarket == .US, stationID == nil, coarseAreaID != nil else {
        return .failure(.invalidSettings)
      }
    }

    let settings = OnboardingSettings(
      uiLocale: uiLocale,
      datingMarket: datingMarket,
      conversationLanguage: conversationLanguage,
      timezone: timezone,
      distanceUnit: distanceUnit,
      genderIdentity: genderIdentityValue,
      genderVisibility: genderVisibility,
      preferredGenders: preferredGenders,
      preferenceMode: preferenceMode,
      locationMode: locationMode,
      stationID: stationID,
      coarseAreaID: coarseAreaID
    )
    do {
      try OnboardingSettings.validate(settings)
      return .success(settings)
    } catch {
      return .failure(.invalidSettings)
    }
  }
}

enum OnboardingSettingsStoreError: Error, Equatable, Sendable {
  case unauthenticated
  case forbidden
  case ageVerificationRequired
  case notFound
  case invalidState
  case rateLimited
  case temporarilyUnavailable
  case malformedResponse
  case cancelled

  var userMessage: String {
    "We couldn't load your settings. Try again."
  }
}

enum OnboardingSettingsStorePhase: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case saving
  case failed(OnboardingSettingsStoreError)
}

protocol OnboardingSettingsAPIFactory: Sendable {
  var isDebugFixture: Bool { get }
  func make(ownerID: String) -> (any OnboardingSettingsAPI)?
}

struct LiveOnboardingSettingsAPIFactory: OnboardingSettingsAPIFactory, Sendable {
  let baseURL: URL
  let authService: any AuthService
  let profileAPI: any ProfileAPI

  var isDebugFixture: Bool { false }

  init(baseURL: URL, authService: any AuthService, profileAPI: any ProfileAPI) {
    self.baseURL = baseURL
    self.authService = authService
    self.profileAPI = profileAPI
  }

  func make(ownerID: String) -> (any OnboardingSettingsAPI)? {
    try? LiveOnboardingSettingsAPI(
      baseURL: baseURL,
      ownerID: ownerID,
      authService: authService,
      profileAPI: profileAPI
    )
  }
}

#if DEBUG
enum DebugOnboardingSettingsFixtureScenario: Equatable, Sendable {
  case standard
  case optionsRetry

  static var requested: Self {
    ProcessInfo.processInfo.arguments.contains("--wingward-onboarding-options-retry")
      ? .optionsRetry
      : .standard
  }
}

struct DebugOnboardingSettingsAPIFactory: OnboardingSettingsAPIFactory, Sendable {
  let scenario: DebugOnboardingSettingsFixtureScenario

  init(scenario: DebugOnboardingSettingsFixtureScenario = .requested) {
    self.scenario = scenario
  }

  var isDebugFixture: Bool { true }

  func make(ownerID: String) -> (any OnboardingSettingsAPI)? {
    DebugOnboardingSettingsAPI(scenario: scenario, ownerID: ownerID)
  }
}
#endif

@MainActor
@Observable
final class OnboardingSettingsStore {
  private(set) var ownerID: String
  private(set) var phase: OnboardingSettingsStorePhase = .idle
  private(set) var draft: OnboardingSettingsDraft = .empty
  private(set) var options: OnboardingOptions?
  private(set) var loadError: OnboardingSettingsStoreError?
  private(set) var saveError: OnboardingSettingsStoreError?
  private(set) var optionsError: OnboardingSettingsStoreError?
  private(set) var validationError: OnboardingSettingsDraftIssue?
  private(set) var didConfirmSave = false
  private(set) var serverConfirmedCompletion = false
  private(set) var isSaving = false

  private let api: any OnboardingSettingsAPI
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var optionsTask: Task<Void, Never>?
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  private var generation = 0
  private var optionsGeneration = 0

  init(ownerID: String, api: any OnboardingSettingsAPI) {
    self.ownerID = ownerID
    self.api = api
  }

  var isBusy: Bool {
    phase == .loading || phase == .saving || isSaving
  }

  var canSave: Bool {
    guard phase == .loaded, !isSaving else { return false }
    guard case .success = draft.materialized() else { return false }
    return true
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    invalidateTasks()
    let capturedGeneration = generation
    let capturedOwnerID = ownerID
    phase = .loading
    loadError = nil
    saveError = nil
    optionsError = nil
    validationError = nil
    didConfirmSave = false
    serverConfirmedCompletion = false
    isSaving = false

    let task = Task { [weak self] in
      guard let self else { return }
      await self.performLoad(ownerID: capturedOwnerID, generation: capturedGeneration)
    }
    loadTask = task
    return task
  }

  @discardableResult
  func save() -> Task<Void, Never> {
    guard phase == .loaded, !isSaving else { return Task {} }
    let materialized = draft.materialized()
    guard case let .success(settings) = materialized else {
      validationError = materialized.failure
      return Task {}
    }

    invalidateTasks()
    let capturedGeneration = generation
    let capturedOwnerID = ownerID
    phase = .saving
    isSaving = true
    saveError = nil
    validationError = nil
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performSave(settings: settings, ownerID: capturedOwnerID, generation: capturedGeneration)
    }
    saveTask = task
    return task
  }

  @discardableResult
  func retry() -> Task<Void, Never> {
    load()
  }

  @discardableResult
  func retryOptions() -> Task<Void, Never>? {
    guard phase == .loaded, optionsError != nil else { return nil }
    refreshOptionsIfPossible()
    return optionsTask
  }

  func cancel() {
    invalidateTasks()
    isSaving = false
    if phase == .loading || phase == .saving { phase = .loaded }
  }

  func updateOwner(_ newOwnerID: String) {
    guard ownerID != newOwnerID else { return }
    cancel()
    ownerID = newOwnerID
    phase = .idle
    draft = .empty
    options = nil
    loadError = nil
    saveError = nil
    optionsError = nil
    validationError = nil
    didConfirmSave = false
    serverConfirmedCompletion = false
  }

  func setUILocale(_ value: OnboardingLanguage) {
    guard !isSaving else { return }
    guard draft.uiLocale != value else { return }
    draft.uiLocale = value
    clearTransientErrors()
    refreshOptionsIfPossible()
  }

  func setConversationLanguage(_ value: OnboardingLanguage) {
    guard !isSaving else { return }
    draft.conversationLanguage = value
    clearTransientErrors()
  }

  func setDatingMarket(_ value: OnboardingDatingMarket) {
    guard !isSaving else { return }
    guard draft.datingMarket != value else { return }
    draft.datingMarket = value
    draft.locationMode = nil
    draft.stationID = nil
    draft.coarseAreaID = nil
    options = nil
    clearTransientErrors()
    refreshOptionsIfPossible()
  }

  func setTimezone(_ value: String) {
    guard !isSaving else { return }
    draft.timezone = value
    clearTransientErrors()
  }

  func setDistanceUnit(_ value: OnboardingDistanceUnit) {
    guard !isSaving else { return }
    draft.distanceUnit = value
    clearTransientErrors()
  }

  func setGenderIdentity(_ value: OnboardingGenderIdentitySelection) {
    guard !isSaving else { return }
    draft.genderIdentity = value
    clearTransientErrors()
  }

  func setPreferenceMode(_ value: OnboardingPreferenceMode) {
    guard !isSaving else { return }
    draft.preferenceMode = value
    if value == .noAnswer { draft.preferredGenders.removeAll() }
    clearTransientErrors()
  }

  func togglePreferredGender(_ value: OnboardingGenderCategory) {
    guard !isSaving else { return }
    guard draft.preferenceMode != .noAnswer else { return }
    draft.preferenceMode = .selected
    if let index = draft.preferredGenders.firstIndex(of: value) {
      draft.preferredGenders.remove(at: index)
    } else if draft.preferredGenders.count < 3 {
      draft.preferredGenders.append(value)
    }
    clearTransientErrors()
  }

  func setLocationMode(_ value: OnboardingLocationMode) {
    guard !isSaving else { return }
    draft.locationMode = value
    switch value {
    case .notSet:
      draft.stationID = nil
      draft.coarseAreaID = nil
    case .noTransit:
      draft.stationID = nil
    case .station:
      break
    }
    clearTransientErrors()
  }

  func setStationID(_ value: String?) {
    guard !isSaving else { return }
    draft.stationID = value
    if let value, let station = options?.stations.first(where: { $0.id == value }) {
      draft.coarseAreaID = station.coarseAreaID
    }
    clearTransientErrors()
  }

  func setCoarseAreaID(_ value: String?) {
    guard !isSaving else { return }
    draft.coarseAreaID = value
    if draft.locationMode == .station,
      let stationID = draft.stationID,
      options?.stations.first(where: { $0.id == stationID })?.coarseAreaID != value
    {
      draft.stationID = nil
    }
    clearTransientErrors()
  }

  private func clearTransientErrors() {
    validationError = nil
    saveError = nil
    didConfirmSave = false
  }

  private func invalidateTasks() {
    loadTask?.cancel()
    optionsTask?.cancel()
    saveTask?.cancel()
    loadTask = nil
    optionsTask = nil
    saveTask = nil
    generation &+= 1
    optionsGeneration &+= 1
  }

  private func isCurrent(ownerID: String, generation: Int) -> Bool {
    !Task.isCancelled && self.ownerID == ownerID && self.generation == generation
  }

  private func performLoad(ownerID: String, generation: Int) async {
    do {
      let savedSettings = try await api.fetchSettings()
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      if let savedSettings {
        draft = OnboardingSettingsDraft(settings: savedSettings)
        didConfirmSave = true
        serverConfirmedCompletion = true
        phase = .loaded
        await fetchOptions(ownerID: ownerID, generation: generation)
        guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      } else {
        draft = .empty
        options = nil
        didConfirmSave = false
        serverConfirmedCompletion = false
        phase = .loaded
      }
      if self.generation == generation { loadTask = nil }
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      let mappedError = map(error)
      loadError = mappedError
      phase = .failed(mappedError)
      loadTask = nil
    }
  }

  private func performSave(settings: OnboardingSettings, ownerID: String, generation: Int) async {
    do {
      let savedSettings = try await api.saveSettings(settings)
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      draft = OnboardingSettingsDraft(settings: savedSettings)
      didConfirmSave = true
      serverConfirmedCompletion = true
      isSaving = false
      saveError = nil
      phase = .loaded
      saveTask = nil
      refreshOptionsIfPossible()
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      guard !OnboardingCancellation.isCancellation(error) else {
        isSaving = false
        phase = .loaded
        saveTask = nil
        return
      }
      isSaving = false
      phase = .loaded
      saveError = map(error)
      saveTask = nil
    }
  }

  private func fetchOptions(ownerID: String, generation: Int) async {
    guard let market = draft.datingMarket, let locale = draft.uiLocale else {
      options = nil
      return
    }
    let capturedOptionsGeneration = optionsGeneration
    do {
      let fetchedOptions = try await api.fetchOptions(market: market, locale: locale)
      guard isCurrent(ownerID: ownerID, generation: generation),
        optionsGeneration == capturedOptionsGeneration
      else { return }
      guard draft.datingMarket == market, draft.uiLocale == locale else { return }
      options = fetchedOptions
      optionsError = nil
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation),
        optionsGeneration == capturedOptionsGeneration,
        draft.datingMarket == market,
        draft.uiLocale == locale
      else { return }
      if OnboardingCancellation.isCancellation(error) {
        optionsError = map(error)
        return
      }
      options = nil
      optionsError = map(error)
    }
  }

  private func refreshOptionsIfPossible() {
    optionsTask?.cancel()
    optionsGeneration &+= 1
    guard phase == .loaded, let market = draft.datingMarket, let locale = draft.uiLocale else {
      options = nil
      return
    }
    let capturedOptionsGeneration = optionsGeneration
    let capturedGeneration = generation
    let capturedOwnerID = ownerID
    optionsError = nil
    let task = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.optionsGeneration == capturedOptionsGeneration { self.optionsTask = nil }
      }
      do {
        let fetchedOptions = try await self.api.fetchOptions(market: market, locale: locale)
        guard self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration),
          self.optionsGeneration == capturedOptionsGeneration,
          self.draft.datingMarket == market,
          self.draft.uiLocale == locale
        else { return }
        self.options = fetchedOptions
        self.optionsError = nil
      } catch {
        guard self.isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration),
          self.optionsGeneration == capturedOptionsGeneration
        else { return }
        if OnboardingCancellation.isCancellation(error) {
          self.optionsError = self.map(error)
          return
        }
        self.options = nil
        self.optionsError = self.map(error)
      }
    }
    optionsTask = task
  }

  private func map(_ error: Error) -> OnboardingSettingsStoreError {
    guard let error = error as? APIClientError else { return .temporarilyUnavailable }
    switch error {
    case .unauthenticated: return .unauthenticated
    case .forbidden: return .forbidden
    case .ageVerificationRequired: return .ageVerificationRequired
    case .notFound: return .notFound
    case .invalidState: return .invalidState
    case .rateLimited, .quotaExhausted: return .rateLimited
    case .cancelled: return .cancelled
    case .invalidResponse, .invalidRequest: return .malformedResponse
    case .invalidURL, .transportFailure, .temporarilyUnavailable: return .temporarilyUnavailable
    }
  }
}
