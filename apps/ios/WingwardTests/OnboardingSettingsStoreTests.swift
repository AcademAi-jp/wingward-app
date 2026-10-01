import Foundation
import XCTest
@testable import Wingward

@MainActor
final class OnboardingSettingsStoreTests: XCTestCase {
  func testPreSaveNullHasNoInferredDefaultsOrSavedClaim() async {
    let api = StoreTestAPI(settings: nil)
    let store = OnboardingSettingsStore(ownerID: "owner-a", api: api)

    await store.load().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertNil(store.draft.uiLocale)
    XCTAssertNil(store.draft.conversationLanguage)
    XCTAssertNil(store.draft.datingMarket)
    XCTAssertNil(store.draft.timezone)
    XCTAssertNil(store.draft.distanceUnit)
    XCTAssertEqual(store.draft.genderIdentity, .unselected)
    XCTAssertNil(store.draft.preferenceMode)
    XCTAssertEqual(store.draft.preferredGenders, [])
    XCTAssertNil(store.draft.locationMode)
    XCTAssertFalse(store.didConfirmSave)
  }

  func testNoAnswerClearsPreferredGenders() async {
    let store = OnboardingSettingsStore(ownerID: "owner-a", api: StoreTestAPI(settings: nil))
    await store.load().value

    store.togglePreferredGender(.woman)
    XCTAssertEqual(store.draft.preferredGenders, [.woman])
    store.setPreferenceMode(.noAnswer)

    XCTAssertEqual(store.draft.preferenceMode, .noAnswer)
    XCTAssertEqual(store.draft.preferredGenders, [])
  }

  func testFailedSaveKeepsDraftAndDoesNotClaimSuccess() async {
    let api = StoreTestAPI(settings: StoreTestAPI.fixtureSettings)
    await api.setSaveError(.temporarilyUnavailable)
    let store = OnboardingSettingsStore(ownerID: "owner-a", api: api)
    await store.load().value
    store.setDistanceUnit(.mi)

    await store.save().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertEqual(store.saveError, .temporarilyUnavailable)
    XCTAssertFalse(store.didConfirmSave)
    XCTAssertEqual(store.draft.distanceUnit, .mi)
    let saveCalls = await api.saveCallCount()
    XCTAssertEqual(saveCalls, 1)
  }

  func testPassiveLoadCancellationIsRetryableAndRetrySucceeds() async {
    let api = StoreTestAPI(settings: nil)
    await api.setFetchError(.cancelled)
    let store = OnboardingSettingsStore(ownerID: "owner-a", api: api)

    await store.load().value

    XCTAssertEqual(store.phase, .failed(.cancelled))
    XCTAssertEqual(store.loadError, .cancelled)

    await api.setFetchError(nil)
    await store.retry().value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertNil(store.loadError)
  }

  func testExplicitCancelledLoadAfterStoreCancelIsSilent() async {
    let api = StoreTestAPI(settings: nil)
    await api.setFetchGated(true)
    let store = OnboardingSettingsStore(ownerID: "owner-a", api: api)

    let loadTask = store.load()
    await api.waitForFetchStart()
    store.cancel()

    await api.releaseFetch(error: .cancelled)
    await loadTask.value

    XCTAssertEqual(store.phase, .loaded)
    XCTAssertNil(store.loadError)
    XCTAssertNil(store.optionsError)
  }

  func testPassiveOptionsCancellationShowsUnavailableAndPreservesCurrentOptions() async {
    let api = StoreTestAPI(settings: StoreTestAPI.fixtureSettings)
    let store = OnboardingSettingsStore(ownerID: "owner-a", api: api)

    await store.load().value
    let currentOptions = store.options
    XCTAssertNotNil(currentOptions)

    await api.setOptionsGated(.JP, true)
    store.setUILocale(.en)
    await api.waitForOptionsStart(.JP)
    await api.releaseOptions(.JP, error: .cancelled)
    await waitUntil { store.optionsError == .cancelled }

    XCTAssertEqual(store.options, currentOptions)
    XCTAssertEqual(store.optionsError, .cancelled)
  }

  func testOptionsFetchFailureCanBeRetriedWithoutLosingTheDraft() async {
    let api = StoreTestAPI(settings: StoreTestAPI.fixtureSettings)
    let store = OnboardingSettingsStore(ownerID: "owner-a", api: api)
    await store.load().value
    XCTAssertNotNil(store.options)

    await api.setOptionsError(.JP, .temporarilyUnavailable)
    store.setUILocale(.en)
    await waitUntil { store.optionsError == .temporarilyUnavailable }
    XCTAssertNil(store.options)
    XCTAssertEqual(store.draft.stationID, StoreTestAPI.fixtureSettings.stationID)

    let failedDraft = store.draft
    await api.setOptionsError(.JP, nil)
    guard let retryTask = store.retryOptions() else {
      XCTFail("A failed options request should expose a retry")
      return
    }
    await retryTask.value

    XCTAssertEqual(store.options?.terms.market, .JP)
    XCTAssertNil(store.optionsError)
    XCTAssertEqual(store.draft, failedDraft)
  }

  func testStaleOptionsCancellationAfterMarketChangeIsSilent() async {
    let api = StoreTestAPI(settings: nil)
    await api.setOptionsGated(.JP, true)
    let store = OnboardingSettingsStore(ownerID: "owner-a", api: api)

    await store.load().value
    store.setUILocale(.ja)
    store.setDatingMarket(.JP)
    await api.waitForOptionsStart(.JP)

    store.setDatingMarket(.US)
    await waitUntil { store.options?.terms.market == .US }
    await api.releaseOptions(.JP, error: .cancelled)

    for _ in 0..<20 {
      await Task.yield()
      XCTAssertEqual(store.options?.terms.market, .US)
      XCTAssertNil(store.optionsError)
    }
  }

  func testChangedOwnerIgnoresStaleSaveResult() async {
    let api = StoreTestAPI(settings: StoreTestAPI.fixtureSettings)
    await api.setSaveGated(true)
    let store = OnboardingSettingsStore(ownerID: "owner-a", api: api)
    await store.load().value
    store.setDistanceUnit(.mi)

    let saveTask = store.save()
    await api.waitForSaveStart()
    store.updateOwner("owner-b")
    await api.releaseSave()
    await saveTask.value

    XCTAssertEqual(store.ownerID, "owner-b")
    XCTAssertEqual(store.phase, .idle)
    XCTAssertEqual(store.draft, .empty)
    XCTAssertFalse(store.didConfirmSave)
    XCTAssertNil(store.saveError)
  }

  func testStaleOptionsCannotReplaceCurrentMarket() async {
    let api = StoreTestAPI(settings: nil)
    await api.setOptionsGated(.JP, true)
    await api.setOptionsGated(.US, true)
    let store = OnboardingSettingsStore(ownerID: "owner-a", api: api)
    await store.load().value
    store.setUILocale(.ja)
    store.setDatingMarket(.JP)
    await api.waitForOptionsStart(.JP)

    store.setDatingMarket(.US)
    await api.waitForOptionsStart(.US)
    await api.releaseOptions(.JP)
    await api.releaseOptions(.US)

    await waitUntil { store.options?.terms.market == .US }
    XCTAssertEqual(store.options?.terms.market, .US)
  }

  func testOldInitialOptionsFailureCannotEraseNewMarketOptions() async {
    let api = StoreTestAPI(settings: StoreTestAPI.fixtureSettings)
    await api.setOptionsGated(.JP, true)
    let store = OnboardingSettingsStore(ownerID: "owner-a", api: api)
    let loadTask = store.load()
    await api.waitForOptionsStart(.JP)

    store.setDatingMarket(.US)
    await waitUntil { store.options?.terms.market == .US }
    XCTAssertEqual(store.options?.terms.market, .US)

    await api.releaseOptions(.JP, error: .temporarilyUnavailable)
    await loadTask.value
    XCTAssertEqual(store.options?.terms.market, .US)
    XCTAssertNil(store.optionsError)
  }

  func testMalformedLoadResponseFailsClosedWithoutRawError() async {
    let api = StoreTestAPI(settings: nil)
    await api.setFetchError(.invalidResponse)
    let store = OnboardingSettingsStore(ownerID: "owner-a", api: api)

    await store.load().value

    XCTAssertEqual(store.phase, .failed(.malformedResponse))
    XCTAssertEqual(store.loadError, .malformedResponse)
  }

  private func waitUntil(
    _ condition: () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<100 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Timed out waiting for store state", file: file, line: line)
  }
}

private actor StoreTestAPI: OnboardingSettingsAPI {
  static let fixtureSettings = OnboardingSettings(
    uiLocale: .ja,
    datingMarket: .JP,
    conversationLanguage: .en,
    timezone: "Asia/Tokyo",
    distanceUnit: .km,
    genderIdentity: .woman,
    preferredGenders: [.woman],
    preferenceMode: .selected,
    locationMode: .station,
    stationID: "jp-tokyo-shimokitazawa",
    coarseAreaID: "jp-tokyo-setagaya"
  )

  private var settings: OnboardingSettings?
  private var fetchError: APIClientError?
  private var fetchGated = false
  private var fetchStarted = false
  private var fetchContinuations: [CheckedContinuation<OnboardingSettings?, Error>] = []
  private var fetchStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var saveError: APIClientError?
  private var saveGated = false
  private var saveStarted = false
  private var saveContinuations: [CheckedContinuation<OnboardingSettings, Never>] = []
  private var saveStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var saveCalls = 0
  private var gatedMarkets: Set<OnboardingDatingMarket> = []
  private var optionsErrors: [OnboardingDatingMarket: APIClientError] = [:]
  private var startedMarkets: Set<OnboardingDatingMarket> = []
  private var optionsContinuations: [OnboardingDatingMarket: [CheckedContinuation<OnboardingOptions, Error>]] = [:]
  private var optionsStartWaiters: [OnboardingDatingMarket: [CheckedContinuation<Void, Never>]] = [:]

  init(settings: OnboardingSettings?) {
    self.settings = settings
  }

  func fetchSettings() async throws -> OnboardingSettings? {
    if fetchGated {
      fetchStarted = true
      fetchStartWaiters.forEach { $0.resume() }
      fetchStartWaiters.removeAll()
      return try await withCheckedThrowingContinuation { continuation in
        fetchContinuations.append(continuation)
      }
    }
    if let fetchError { throw fetchError }
    return settings
  }

  func fetchOptions(market: OnboardingDatingMarket, locale: OnboardingLanguage) async throws -> OnboardingOptions {
    if let error = optionsErrors[market] { throw error }
    if gatedMarkets.contains(market) {
      startedMarkets.insert(market)
      optionsStartWaiters[market, default: []].forEach { $0.resume() }
      optionsStartWaiters[market] = []
      return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OnboardingOptions, Error>) in
        optionsContinuations[market, default: []].append(continuation)
      }
    }
    return options(for: market)
  }

  func saveSettings(_ settings: OnboardingSettings) async throws -> OnboardingSettings {
    saveCalls += 1
    if let saveError { throw saveError }
    if saveGated {
      saveStarted = true
      saveStartWaiters.forEach { $0.resume() }
      saveStartWaiters.removeAll()
      return await withCheckedContinuation { continuation in
        saveContinuations.append(continuation)
      }
    }
    return settings
  }

  func setFetchError(_ error: APIClientError?) { fetchError = error }
  func setFetchGated(_ value: Bool) { fetchGated = value }
  func setSaveError(_ error: APIClientError?) { saveError = error }
  func setSaveGated(_ value: Bool) { saveGated = value }

  func waitForFetchStart() async {
    if fetchStarted { return }
    await withCheckedContinuation { continuation in
      fetchStartWaiters.append(continuation)
    }
  }

  func releaseFetch(error: APIClientError? = nil) {
    for continuation in fetchContinuations {
      if let error {
        continuation.resume(throwing: error)
      } else {
        continuation.resume(returning: settings)
      }
    }
    fetchContinuations.removeAll()
  }

  func saveCallCount() -> Int { saveCalls }

  func waitForSaveStart() async {
    if saveStarted { return }
    await withCheckedContinuation { continuation in
      saveStartWaiters.append(continuation)
    }
  }

  func releaseSave() {
    for continuation in saveContinuations {
      continuation.resume(returning: Self.fixtureSettings)
    }
    saveContinuations.removeAll()
  }

  func setOptionsGated(_ market: OnboardingDatingMarket, _ value: Bool) {
    if value { gatedMarkets.insert(market) } else { gatedMarkets.remove(market) }
  }

  func setOptionsError(_ market: OnboardingDatingMarket, _ error: APIClientError?) {
    optionsErrors[market] = error
  }

  func waitForOptionsStart(_ market: OnboardingDatingMarket) async {
    if startedMarkets.contains(market) { return }
    await withCheckedContinuation { continuation in
      optionsStartWaiters[market, default: []].append(continuation)
    }
  }

  func releaseOptions(_ market: OnboardingDatingMarket, error: APIClientError? = nil) {
    let value = options(for: market)
    for continuation in optionsContinuations[market, default: []] {
      if let error {
        continuation.resume(throwing: error)
      } else {
        continuation.resume(returning: value)
      }
    }
    optionsContinuations[market] = []
  }

  private func options(for market: OnboardingDatingMarket) -> OnboardingOptions {
    switch market {
    case .JP:
      return OnboardingOptions(
        stations: [OnboardingStation(id: "jp-tokyo-shimokitazawa", name: "Shimokitazawa", coarseAreaID: "jp-tokyo-setagaya")],
        areas: [OnboardingArea(id: "jp-tokyo-setagaya", name: "Setagaya")],
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
}
