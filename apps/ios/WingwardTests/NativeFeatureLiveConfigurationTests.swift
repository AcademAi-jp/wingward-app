import XCTest
@testable import Wingward

final class NativeFeatureLiveConfigurationTests: XCTestCase {
  func testVoiceCompositionRemainsAvailableWhenBillingConfigurationIsInvalid() {
    let values = [
      "WINGWARD_NATIVE_VOICE_ENABLED": "YES",
      "WINGWARD_NATIVE_VOICE_BOOTSTRAP": "openAIRealtime",
      "WINGWARD_REVENUECAT_ENABLED": "true",
      "WINGWARD_REVENUECAT_TEST_STORE": "true",
    ]
    XCTAssertEqual(NativeFeatureLiveConfiguration.load(values: values), .failure(.missingRevenueCatKey))
    let configuration = NativeFeatureLiveConfiguration.voiceOnlyComposition(values: values)
    XCTAssertTrue(configuration.voiceEnabled)
    XCTAssertEqual(configuration.voiceBootstrapKind, .openAIRealtime)
    XCTAssertEqual(configuration.billing, .disabled)
  }

  func testVoiceCompositionRejectsInvalidVoiceConfigurationAndLeavesBillingDisabled() {
    for values in [
      ["WINGWARD_NATIVE_VOICE_ENABLED": "unexpected", "WINGWARD_NATIVE_VOICE_BOOTSTRAP": "openAIRealtime"],
      ["WINGWARD_NATIVE_VOICE_ENABLED": "YES", "WINGWARD_NATIVE_VOICE_BOOTSTRAP": "legacySignedURL"],
      ["WINGWARD_NATIVE_VOICE_ENABLED": "YES", "WINGWARD_NATIVE_VOICE_BOOTSTRAP": "unexpected"],
      [:],
    ] {
      XCTAssertEqual(NativeFeatureLiveConfiguration.voiceOnlyComposition(values: values), .disabled)
    }
  }

  func testExplicitRealtimeVoiceConfigurationIsAccepted() throws {
    let config = try NativeFeatureLiveConfiguration.load(values: [
      "WINGWARD_NATIVE_VOICE_ENABLED": "true", "WINGWARD_NATIVE_VOICE_BOOTSTRAP": "openAIRealtime"
    ]).get()
    XCTAssertTrue(config.voiceEnabled)
    XCTAssertEqual(config.voiceBootstrapKind, .openAIRealtime)
  }

  func testMissingProviderFlagsKeepLiveCompositionDisabled() {
    let result = NativeFeatureLiveConfiguration.load(values: [:])

    XCTAssertEqual(result, .success(.disabled))
  }

  func testVoiceRequiresNativeBootstrapWhenExplicitlyEnabled() {
    let result = NativeFeatureLiveConfiguration.load(values: [
      "WINGWARD_NATIVE_VOICE_ENABLED": "true",
      "WINGWARD_NATIVE_VOICE_BOOTSTRAP": "legacySignedURL",
    ])

    XCTAssertEqual(result, .failure(.invalidVoiceBootstrap))
  }

  func testExplicitNativeVoiceAndDebugTestStoreConfigurationIsAccepted() {
    let result = NativeFeatureLiveConfiguration.load(values: [
      "WINGWARD_NATIVE_VOICE_ENABLED": "true",
      "WINGWARD_NATIVE_VOICE_BOOTSTRAP": "nativeConversationToken",
      "WINGWARD_REVENUECAT_ENABLED": "true",
      "WINGWARD_REVENUECAT_TEST_STORE": "true",
      "REVENUECAT_PUBLIC_KEY": "test_public_key_fixture",
    ])

#if DEBUG
    guard case let .success(configuration) = result else {
      return XCTFail("Debug Test Store configuration should be accepted")
    }
    XCTAssertTrue(configuration.voiceEnabled)
    XCTAssertEqual(configuration.voiceBootstrapKind, .nativeConversationToken)
    XCTAssertTrue(configuration.billing.enabled)
    XCTAssertTrue(configuration.billing.testStore)
#else
    XCTAssertEqual(result, .failure(.invalidRevenueCatKey))
#endif
  }

  func testTestStoreFlagAndPublicKeyPrefixMustMatch() {
    let testKeyWithProductionFlag = NativeFeatureLiveConfiguration.load(values: [
      "WINGWARD_REVENUECAT_ENABLED": "true",
      "WINGWARD_REVENUECAT_TEST_STORE": "false",
      "REVENUECAT_PUBLIC_KEY": "test_public_key_fixture",
    ])
    let productionKeyWithTestFlag = NativeFeatureLiveConfiguration.load(values: [
      "WINGWARD_REVENUECAT_ENABLED": "true",
      "WINGWARD_REVENUECAT_TEST_STORE": "true",
      "REVENUECAT_PUBLIC_KEY": "appl_public_key_fixture",
    ])

    XCTAssertEqual(testKeyWithProductionFlag, .failure(.invalidRevenueCatKey))
    XCTAssertEqual(productionKeyWithTestFlag, .failure(.invalidRevenueCatKey))
  }

  func testTestStoreFlagCannotBeEnabledWithoutBilling() {
    let result = NativeFeatureLiveConfiguration.load(values: [
      "WINGWARD_REVENUECAT_ENABLED": "false",
      "WINGWARD_REVENUECAT_TEST_STORE": "true",
      "REVENUECAT_PUBLIC_KEY": "test_public_key_fixture",
    ])

    XCTAssertEqual(result, .failure(.invalidRevenueCatKey))
  }

  func testEnabledBillingWithoutAKeyFailsClosed() {
    let result = NativeFeatureLiveConfiguration.load(values: [
      "WINGWARD_REVENUECAT_ENABLED": "true",
    ])

    XCTAssertEqual(result, .failure(.missingRevenueCatKey))
  }
}
