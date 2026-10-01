import Foundation

struct AppConfiguration: Equatable, Sendable {
  let supabaseURL: URL
  let publishableKey: String
  let apiBaseURL: URL

  enum LoadFailure: Error, Equatable {
    case missingOrPlaceholder
    case invalidURL
  }

  static func load(bundle: Bundle = .main) -> Result<AppConfiguration, LoadFailure> {
    load(
      values: [
        "SUPABASE_URL": bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? "",
        "SUPABASE_PUBLISHABLE_KEY": bundle.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String ?? "",
        "API_BASE_URL": bundle.object(forInfoDictionaryKey: "API_BASE_URL") as? String ?? "",
      ]
    )
  }

  static func load(values: [String: String]) -> Result<AppConfiguration, LoadFailure> {
    guard
      let supabaseValue = values["SUPABASE_URL"],
      let publishableKey = values["SUPABASE_PUBLISHABLE_KEY"],
      let apiValue = values["API_BASE_URL"],
      !isPlaceholder(supabaseValue),
      !isPlaceholder(publishableKey),
      !isPlaceholder(apiValue)
    else {
      return .failure(.missingOrPlaceholder)
    }

    guard
      let supabaseURL = URL(string: supabaseValue),
      let apiBaseURL = URL(string: apiValue),
      isSecureHTTPURL(supabaseURL),
      isSecureHTTPURL(apiBaseURL),
      !publishableKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return .failure(.invalidURL)
    }

    return .success(
      AppConfiguration(
        supabaseURL: supabaseURL,
        publishableKey: publishableKey,
        apiBaseURL: apiBaseURL
      )
    )
  }

  private static func isSecureHTTPURL(_ url: URL) -> Bool {
    url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
  }

  private static func isPlaceholder(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return true }
    return [
      "$(",
      "placeholder",
      "replace_with",
      "replace-with",
      "your_",
      "your-",
      "change-me",
      "example.",
      "example-",
      "publishable-key",
      "publishable_key",
    ].contains { normalized.contains($0) }
  }
}

/// Explicit opt-in switches for live provider composition. Missing values are
/// safe defaults: native voice and vendor billing stay unavailable until a
/// build explicitly supplies the reviewed mode and key.
struct NativeFeatureLiveConfiguration: Equatable, Sendable {
  struct Billing: Equatable, Sendable {
    let enabled: Bool
    let publicKey: String?
    let testStore: Bool

    static let disabled = Billing(enabled: false, publicKey: nil, testStore: false)
  }

  let voiceEnabled: Bool
  let voiceBootstrapKind: VoiceInterviewBootstrapKind
  let billing: Billing

  static let disabled = NativeFeatureLiveConfiguration(
    voiceEnabled: false,
    voiceBootstrapKind: .legacySignedURL,
    billing: .disabled
  )

  enum LoadFailure: Error, Equatable, Sendable {
    case invalidFlag
    case invalidVoiceBootstrap
    case missingRevenueCatKey
    case invalidRevenueCatKey
  }

  static func load(bundle: Bundle = .main) -> Result<NativeFeatureLiveConfiguration, LoadFailure> {
    load(
      values: [
        "WINGWARD_NATIVE_VOICE_ENABLED": bundle.object(forInfoDictionaryKey: "WINGWARD_NATIVE_VOICE_ENABLED") as? String ?? "",
        "WINGWARD_NATIVE_VOICE_BOOTSTRAP": bundle.object(forInfoDictionaryKey: "WINGWARD_NATIVE_VOICE_BOOTSTRAP") as? String ?? "",
        "WINGWARD_REVENUECAT_ENABLED": bundle.object(forInfoDictionaryKey: "WINGWARD_REVENUECAT_ENABLED") as? String ?? "",
        "REVENUECAT_PUBLIC_KEY": bundle.object(forInfoDictionaryKey: "REVENUECAT_PUBLIC_KEY") as? String ?? "",
        "WINGWARD_REVENUECAT_TEST_STORE": bundle.object(forInfoDictionaryKey: "WINGWARD_REVENUECAT_TEST_STORE") as? String ?? "",
      ]
    )
  }

  static func loadForComposition(bundle: Bundle = .main) -> NativeFeatureLiveConfiguration {
    if case let .success(configuration) = load(bundle: bundle) { return configuration }
    return voiceOnlyComposition(values: [
      "WINGWARD_NATIVE_VOICE_ENABLED": bundle.object(forInfoDictionaryKey: "WINGWARD_NATIVE_VOICE_ENABLED") as? String ?? "",
      "WINGWARD_NATIVE_VOICE_BOOTSTRAP": bundle.object(forInfoDictionaryKey: "WINGWARD_NATIVE_VOICE_BOOTSTRAP") as? String ?? "",
    ])
  }

  // Invalid billing configuration must keep purchases closed without disabling
  // a separately validated voice configuration.
  static func voiceOnlyComposition(values: [String: String]) -> NativeFeatureLiveConfiguration {
    let voiceValues = [
      "WINGWARD_NATIVE_VOICE_ENABLED": values["WINGWARD_NATIVE_VOICE_ENABLED"] ?? "",
      "WINGWARD_NATIVE_VOICE_BOOTSTRAP": values["WINGWARD_NATIVE_VOICE_BOOTSTRAP"] ?? "",
    ]
    if case let .success(configuration) = load(values: voiceValues) { return configuration }
    return .disabled
  }

  static func load(values: [String: String]) -> Result<NativeFeatureLiveConfiguration, LoadFailure> {
    let voiceEnabled: Bool
    switch parseBoolean(values["WINGWARD_NATIVE_VOICE_ENABLED"]) {
    case .some(let value): voiceEnabled = value
    case .none: return .failure(.invalidFlag)
    }

    let voiceBootstrapKind: VoiceInterviewBootstrapKind
    switch values["WINGWARD_NATIVE_VOICE_BOOTSTRAP"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
    case nil, "", "legacySignedURL":
      voiceBootstrapKind = .legacySignedURL
    case "openAIRealtime":
      voiceBootstrapKind = .openAIRealtime
    case "nativeConversationToken":
      voiceBootstrapKind = .nativeConversationToken
    default:
      return .failure(.invalidVoiceBootstrap)
    }
    guard !voiceEnabled || voiceBootstrapKind == .nativeConversationToken || voiceBootstrapKind == .openAIRealtime else {
      return .failure(.invalidVoiceBootstrap)
    }

    let billingEnabled: Bool
    switch parseBoolean(values["WINGWARD_REVENUECAT_ENABLED"]) {
    case .some(let value): billingEnabled = value
    case .none: return .failure(.invalidFlag)
    }
    let testStore: Bool
    switch parseBoolean(values["WINGWARD_REVENUECAT_TEST_STORE"]) {
    case .some(let value): testStore = value
    case .none: return .failure(.invalidFlag)
    }

    guard billingEnabled || !testStore else {
      return .failure(.invalidRevenueCatKey)
    }

    guard billingEnabled else {
      return .success(
        NativeFeatureLiveConfiguration(
          voiceEnabled: voiceEnabled,
          voiceBootstrapKind: voiceBootstrapKind,
          billing: .disabled
        )
      )
    }

    guard let rawKey = values["REVENUECAT_PUBLIC_KEY"] else {
      return .failure(.missingRevenueCatKey)
    }
    let publicKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !publicKey.isEmpty, publicKey == rawKey else {
      return .failure(.invalidRevenueCatKey)
    }
    do {
      try RevenueCatAPIKeyPolicy.validate(publicKey: publicKey)
    } catch {
      return .failure(.invalidRevenueCatKey)
    }

#if !DEBUG
    guard !testStore, !publicKey.hasPrefix("test_") else {
      return .failure(.invalidRevenueCatKey)
    }
#else
    if testStore {
      guard publicKey.hasPrefix("test_") else {
        return .failure(.invalidRevenueCatKey)
      }
    } else {
      guard publicKey.hasPrefix("appl_") else {
        return .failure(.invalidRevenueCatKey)
      }
    }
#endif

    return .success(
      NativeFeatureLiveConfiguration(
        voiceEnabled: voiceEnabled,
        voiceBootstrapKind: voiceBootstrapKind,
        billing: Billing(enabled: true, publicKey: publicKey, testStore: testStore)
      )
    )
  }

  private static func parseBoolean(_ rawValue: String?) -> Bool? {
    switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case nil, "": return false
    case "1", "true", "yes", "on": return true
    case "0", "false", "no", "off": return false
    default: return nil
    }
  }
}
