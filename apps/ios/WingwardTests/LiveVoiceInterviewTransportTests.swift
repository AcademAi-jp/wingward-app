import Foundation
import XCTest
@testable import Wingward
#if canImport(ElevenLabs)
@testable import ElevenLabs
#endif

@MainActor
final class LiveVoiceInterviewTransportTests: XCTestCase {
  private var vadDisabled: [String: Any] {
    ["session": ["audio": ["input": ["turn_detection": NSNull()]]]]
  }

  func testAutomaticStopWaitsForDisabledVADBeforeFinalCommit() throws {
    var input = RealtimeInputCommit()
    XCTAssertNil(input.sessionUpdated(vadDisabled))
    let update = try XCTUnwrap(input.beginShutdown())
    XCTAssertEqual(update["type"] as? String, "session.update")
    XCTAssertNil(input.beginShutdown())
    // An automatic commit already queued before the update is not the final one.
    input.committed()
    XCTAssertFalse(input.isSettled)
    XCTAssertNil(input.sessionUpdated(["session": ["audio": ["input": ["turn_detection": ["type": "server_vad"]]]]]))
    XCTAssertNil(input.sessionUpdated(["session": ["audio": ["input": [:]]]]))
    let command = try XCTUnwrap(input.sessionUpdated(vadDisabled))
    XCTAssertEqual(command["type"], "input_audio_buffer.commit")
    XCTAssertNil(input.sessionUpdated(vadDisabled))
    XCTAssertFalse(input.isSettled)
    input.committed()
    XCTAssertTrue(input.isSettled)
  }

  func testAutomaticStopRetainsFinalTurnUntilItsDelayedTranscription() throws {
    var input = RealtimeInputCommit()
    var log = RealtimeInterviewLog()
    try log.add(id: "prior", role: "user")
    try log.finalize(id: "prior", text: "I enjoy books.")
    _ = input.beginShutdown()
    _ = try XCTUnwrap(input.sessionUpdated(vadDisabled))
    // A stale speech-start notification cannot replace the final commit barrier.
    XCTAssertFalse(input.isSettled)
    try log.ensureUserItem(id: "final")
    input.committed()
    XCTAssertTrue(input.isSettled)
    XCTAssertFalse(log.isSettled)
    XCTAssertThrowsError(try log.entries())
    try log.finalize(id: "final", text: "And quiet walks.")
    XCTAssertTrue(input.isSettled && log.isSettled)
    XCTAssertEqual(try log.entries().map(\.message), ["I enjoy books.", "And quiet walks."])
  }

  func testSilentStopRequiresOwnEmptyCommitAcknowledgement() throws {
    var input = RealtimeInputCommit()
    _ = input.beginShutdown()
    let command = try XCTUnwrap(input.sessionUpdated(vadDisabled))
    XCTAssertFalse(input.acceptsEmptyBuffer(code: "input_audio_buffer_commit_empty", eventID: "unrelated"))
    XCTAssertFalse(input.isSettled)
    XCTAssertTrue(input.acceptsEmptyBuffer(code: "input_audio_buffer_commit_empty", eventID: command["event_id"]))
    XCTAssertTrue(input.isSettled)
    XCTAssertNil(input.sessionUpdated(vadDisabled))
    XCTAssertNil(input.command())
  }

  func testEmptyCommitDoesNotDiscardAnEarlierPendingTranscription() throws {
    var input = RealtimeInputCommit()
    var log = RealtimeInterviewLog()
    _ = input.beginShutdown()
    try log.ensureUserItem(id: "automatic-final")
    input.committed()
    let command = try XCTUnwrap(input.sessionUpdated(vadDisabled))
    XCTAssertTrue(input.acceptsEmptyBuffer(code: "input_audio_buffer_commit_empty", eventID: command["event_id"]))
    XCTAssertTrue(input.isSettled)
    XCTAssertFalse(log.isSettled)
    try log.finalize(id: "automatic-final", text: "A synthetic final answer.")
    XCTAssertTrue(log.isSettled)
    XCTAssertEqual(try log.entries().count, 1)
  }

  func testFinalAudioCommitWaitsForTranscriptionEvenBeforeItemCreated() throws {
    var log = RealtimeInterviewLog()
    try log.ensureUserItem(id: "final-user")
    XCTAssertFalse(log.isSettled)
    try log.add(id: "final-user", role: "user")
    XCTAssertEqual(log.items.count, 1)
    try log.finalize(id: "final-user", text: "I like quiet evenings.")
    XCTAssertTrue(log.isSettled)
    XCTAssertEqual(try log.entries().count, 1)
  }

  func testEmptyFinalCommitErrorMustMatchOwnCommandAndKnownCode() throws {
    var commit = RealtimeInputCommit()
    let command = try XCTUnwrap(commit.command())
    XCTAssertNil(commit.command())
    XCTAssertFalse(commit.acceptsEmptyBuffer(code: "input_audio_buffer_commit_empty", eventID: "other"))
    XCTAssertFalse(commit.acceptsEmptyBuffer(code: "invalid_request_error", eventID: command["event_id"]))
    XCTAssertTrue(commit.acceptsEmptyBuffer(code: "input_audio_buffer_commit_empty", eventID: command["event_id"]))
    XCTAssertFalse(commit.acceptsEmptyBuffer(code: "input_audio_buffer_commit_empty", eventID: command["event_id"]))
  }

  func testStopAcceptsCorrelatedCancellationAfterServerAlreadyCompletedResponse() throws {
    var state = RealtimeResponseLifecycle()
    state.started("response1")
    let event = try XCTUnwrap(state.cancellation(for: "response1"))
    XCTAssertEqual(event["response_id"], "response1")
    XCTAssertNil(state.cancellation(for: "response1"))
    state.finished("response1")
    XCTAssertTrue(state.acceptsAlreadyFinished(code: "response_cancel_not_active", eventID: event["event_id"]))
    XCTAssertTrue(state.activeIDs.isEmpty)
    XCTAssertFalse(state.acceptsAlreadyFinished(code: "response_cancel_not_active", eventID: event["event_id"]))
  }

  func testLateCancellationDoesNotFinishAnotherResponseOrDiscardFinalUserTurn() throws {
    var state = RealtimeResponseLifecycle()
    state.started("old")
    let event = try XCTUnwrap(state.cancellation(for: "old"))
    state.started("new")
    state.finished("old")
    XCTAssertTrue(state.acceptsAlreadyFinished(code: "response_cancel_not_active", eventID: event["event_id"]))
    XCTAssertEqual(state.activeIDs, ["new"])
    var log = RealtimeInterviewLog()
    try log.add(id: "user", role: "user")
    XCTAssertFalse(log.isSettled)
    try log.finalize(id: "user", text: "I enjoy quiet walks and trying new teas.")
    state.finished("new")
    XCTAssertTrue(state.activeIDs.isEmpty)
    XCTAssertEqual(try log.entries().count, 1)
  }

  func testStopRejectsUnrelatedOrUnknownProviderErrors() throws {
    var state = RealtimeResponseLifecycle()
    state.started("response1")
    let event = try XCTUnwrap(state.cancellation(for: "response1"))
    XCTAssertFalse(state.acceptsAlreadyFinished(code: "response_cancel_not_active", eventID: "unrelated"))
    XCTAssertFalse(state.acceptsAlreadyFinished(code: "invalid_api_key", eventID: event["event_id"]))
    XCTAssertFalse(state.acceptsAlreadyFinished(code: nil, eventID: event["event_id"]))
    XCTAssertEqual(state.activeIDs, ["response1"])
  }

  func testStoppingDuringAudioOmitsOnlyLastAssistantAndRetainsUser() throws {
    var log = RealtimeInterviewLog()
    try log.add(id: "user", role: "user")
    try log.finalize(id: "user", text: "Synthetic user answer")
    try log.add(id: "assistant", role: "assistant")
    log.omitLastAssistant()
    XCTAssertTrue(log.isSettled)
    XCTAssertEqual(try log.entries().map(\.message), ["Synthetic user answer"])
  }

  func testRealtimeLogPreservesTurnOrderWhenTranscriptionArrivesLate() throws {
    var log = RealtimeInterviewLog()
    try log.add(id: "user1", role: "user")
    try log.add(id: "ai1", role: "assistant")
    try log.finalize(id: "ai1", text: "What did you enjoy?")
    XCTAssertFalse(log.isSettled)
    XCTAssertThrowsError(try log.entries())
    try log.finalize(id: "user1", text: "I went hiking.")
    XCTAssertEqual(try log.entries().map(\.source), [.user, .ai])
  }

  func testRealtimeLogOmitsInterruptedAudioAndDeduplicatesFinals() throws {
    var log = RealtimeInterviewLog()
    try log.add(id: "ai1", role: "assistant")
    try log.add(id: "ai1", role: "assistant")
    try log.finalize(id: "ai1", text: "An unheard long response.")
    log.omit(id: "ai1")
    try log.add(id: "user1", role: "user")
    try log.finalize(id: "user1", text: "I prefer not to answer.")
    try log.finalize(id: "user1", text: "I prefer not to answer.")
    XCTAssertEqual(try log.entries(), [.init(source: .user, message: "I prefer not to answer.")])
    XCTAssertThrowsError(try log.finalize(id: "user1", text: "Invented replacement"))
    XCTAssertThrowsError(try log.finalize(id: "unknown", text: "Unbound text"))
  }

  func testRealtimeCredentialsRejectLongLivedKeysAndExpiredTokens() throws {
    let now = Date().timeIntervalSince1970
    try RealtimeVoiceBootstrap.validateSecret("ek_synthetic", expiresAt: now + 120)
    for value in ["sk_synthetic", "ek_bad\nheader", "ek_", " ek_synthetic"] {
      XCTAssertThrowsError(try RealtimeVoiceBootstrap.validateSecret(value, expiresAt: now + 120))
    }
    for expiry in [now - 1, now + 500, Double.infinity] {
      XCTAssertThrowsError(try RealtimeVoiceBootstrap.validateSecret("ek_synthetic", expiresAt: expiry))
    }
    XCTAssertEqual(RealtimeVoice.allCases.map(\.rawValue), ["cedar", "marin", "ash"])
    XCTAssertFalse(LiveVoiceInterviewTransportFactory(bootstrapKind: .openAIRealtime, enabled: false).make().isAvailable)
    XCTAssertTrue(LiveVoiceInterviewTransportFactory(bootstrapKind: .openAIRealtime, enabled: true).make().isAvailable)
  }

  func testServerBoundedBootstrapNeverAcceptsProviderCredentialOrExtendedLimit() throws {
    func payload(mode: String = "server_bounded", limit: Int = 180, secret: String? = nil) throws -> Data {
      var value: [String: Any] = ["session_id": "22222222-2222-4222-8222-222222222222", "mode": mode,
        "expires_at": Date().timeIntervalSince1970 + 120, "model": "gpt-realtime-2.1-mini", "max_duration_seconds": limit,
        "overrides": ["agent": ["prompt": ["prompt": "Synthetic interview"], "language": "en"], "tts": ["voiceId": "cedar"]]]
      if let secret { value["client_secret"] = secret }
      return try JSONSerialization.data(withJSONObject: ["data": value])
    }
    let valid = try XCTUnwrap(tryDecode(try payload(), as: RealtimeVoiceBootstrap.self))
    XCTAssertTrue(valid.serverBounded)
    XCTAssertEqual(valid.clientSecret, "")
    XCTAssertEqual(valid.maxDurationSeconds, 180)
    XCTAssertNil(tryDecode(try payload(secret: "ek_synthetic"), as: RealtimeVoiceBootstrap.self))
    XCTAssertNil(tryDecode(try payload(limit: 181), as: RealtimeVoiceBootstrap.self))
    XCTAssertNil(tryDecode(try payload(mode: "untrusted"), as: RealtimeVoiceBootstrap.self))
    XCTAssertThrowsError(try VoiceInterviewCredential.validate(.serverBoundedRealtime(maxSeconds: 181)))
  }

  func testBoundedSDPAnswerRejectsInvalidAndOversizedProviderPayload() throws {
    let valid = try JSONSerialization.data(withJSONObject: ["data": ["sdp": "v=0\r\na=synthetic\r\n", "max_duration_seconds": 179]])
    XCTAssertNotNil(tryDecode(valid, as: BoundedRealtimeCallAnswer.self))
    for sdp in ["private", "v=0\0bad", "v=0" + String(repeating: "x", count: 65_536)] {
      let bad = try JSONSerialization.data(withJSONObject: ["data": ["sdp": sdp, "max_duration_seconds": 179]])
      XCTAssertNil(tryDecode(bad, as: BoundedRealtimeCallAnswer.self))
    }
  }

  private let sessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

  func testNativeBootstrapRequiresBoundSessionAndOpaqueToken() {
    let valid = nativeBootstrapData(
      sessionID: sessionID.uuidString,
      token: "synthetic-conversation-token"
    )
    XCTAssertNotNil(tryDecode(valid, as: NativeVoiceBootstrap.self))

    for token in ["", " token", "token ", String(repeating: "x", count: NativeVoiceBootstrap.maxConversationTokenLength + 1)] {
      XCTAssertNil(
        tryDecode(
          nativeBootstrapData(sessionID: sessionID.uuidString, token: token),
          as: NativeVoiceBootstrap.self
        ),
        "invalid token must fail closed"
      )
    }

    let malformedSession = nativeBootstrapData(
      sessionID: "66666666-6666-4666-8666-666666666666",
      token: "synthetic-conversation-token"
    )
    XCTAssertNotNil(tryDecode(malformedSession, as: NativeVoiceBootstrap.self))
    let decoded = tryDecode(malformedSession, as: NativeVoiceBootstrap.self)!
    XCTAssertNotEqual(decoded.sessionID, sessionID)
  }

  func testRequestCredentialIsClosedAndNeverNeedsPlaceholderURL() throws {
    let overrides = VoiceInterviewOverrides(
      prompt: "Synthetic prompt",
      firstMessage: "Synthetic greeting",
      language: .en,
      voiceID: "synthetic-voice"
    )
    let request = VoiceInterviewRequest(
      sessionID: sessionID,
      credential: .conversationToken("synthetic-conversation-token"),
      overrides: overrides
    )

    if case .conversationToken = request.credential {
      // The native path carries no URL at all.
    } else {
      XCTFail("native request must carry a conversation token")
    }
    XCTAssertNoThrow(try VoiceInterviewRequest.validate(request))
  }

  func testLegacyCompatibilityInitializerStillUsesSignedURLCredential() {
    let request = VoiceInterviewRequest(
      sessionID: sessionID,
      signedURL: URL(string: "wss://api.elevenlabs.io/v1/convai/conversation?conversation_signature=synthetic")!,
      overrides: VoiceInterviewOverrides(
        prompt: "Synthetic prompt",
        firstMessage: "Synthetic greeting",
        language: .en,
        voiceID: "synthetic-voice"
      )
    )

    guard case .signedURL = request.credential else {
      return XCTFail("legacy fixture must retain signed URL credential")
    }
  }

  func testDefaultFactoryKeepsLiveTransportUnavailable() async {
    let transport = LiveVoiceInterviewTransportFactory().make()
    XCTAssertFalse(transport.isAvailable)
    await transport.stop()
  }

#if canImport(ElevenLabs)
  func testSDKEventSerializerEmitsOnlyAllowedProviderOverrideLeaves() throws {
    let configuration = LiveVoiceInterviewTransport.configurationForTesting(
      overrides: VoiceInterviewOverrides(
        prompt: "Synthetic prompt",
        firstMessage: "Synthetic greeting",
        language: .ja,
        voiceID: "synthetic-voice"
      )
    )
    let event = ConversationInitEvent(config: configuration)
    let data = try EventSerializer.serializeOutgoingEvent(.conversationInit(event))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(Set(json.keys), Set(["type", "conversation_config_override", "source_info"]))
    XCTAssertEqual(json["type"] as? String, "conversation_initiation_client_data")

    let configOverride = try XCTUnwrap(
      json["conversation_config_override"] as? [String: Any]
    )
    XCTAssertEqual(Set(configOverride.keys), Set(["agent", "tts"]))

    let agent = try XCTUnwrap(configOverride["agent"] as? [String: Any])
    XCTAssertEqual(Set(agent.keys), Set(["prompt", "first_message", "language"]))
    let prompt = try XCTUnwrap(agent["prompt"] as? [String: Any])
    XCTAssertEqual(Set(prompt.keys), Set(["prompt"]))
    XCTAssertEqual(prompt["prompt"] as? String, "Synthetic prompt")
    XCTAssertEqual(agent["first_message"] as? String, "Synthetic greeting")
    XCTAssertEqual(agent["language"] as? String, "ja")

    let tts = try XCTUnwrap(configOverride["tts"] as? [String: Any])
    XCTAssertEqual(Set(tts.keys), Set(["voice_id"]))
    XCTAssertEqual(tts["voice_id"] as? String, "synthetic-voice")

    // `source_info` is SDK-managed metadata; it is intentionally present and
    // does not contain app profile IDs, prompts, or provider credentials.
    let sourceInfo = try XCTUnwrap(json["source_info"] as? [String: Any])
    XCTAssertEqual(Set(sourceInfo.keys), Set(["source", "version"]))
  }

  func testSDKInitiationConfigContainsOnlyFourProviderOverrideFields() {
    let configuration = LiveVoiceInterviewTransport.configurationForTesting(
      overrides: VoiceInterviewOverrides(
        prompt: "Synthetic prompt",
        firstMessage: "Synthetic greeting",
        language: .ja,
        voiceID: "synthetic-voice"
      )
    )

    XCTAssertEqual(configuration.agentOverrides?.prompt, "Synthetic prompt")
    XCTAssertEqual(configuration.agentOverrides?.firstMessage, "Synthetic greeting")
    XCTAssertEqual(configuration.agentOverrides?.language?.rawValue, "ja")
    XCTAssertEqual(configuration.ttsOverrides?.voiceId, "synthetic-voice")
    XCTAssertNil(configuration.ttsOverrides?.stability)
    XCTAssertNil(configuration.ttsOverrides?.speed)
    XCTAssertNil(configuration.ttsOverrides?.similarityBoost)
    XCTAssertNil(configuration.conversationOverrides)
    XCTAssertNil(configuration.customLlmExtraBody)
    XCTAssertNil(configuration.dynamicVariables)
    XCTAssertNil(configuration.userId)
    XCTAssertNil(configuration.environment)
  }
#endif

  #if !canImport(ElevenLabs)
  func testNativeTransportRejectsWithoutSDKEvenWhenEnabled() async {
    let transport = LiveVoiceInterviewTransport(enabled: true)
    XCTAssertFalse(transport.isAvailable)

    let request = VoiceInterviewRequest(
      sessionID: sessionID,
      credential: .conversationToken("synthetic-conversation-token"),
      overrides: VoiceInterviewOverrides(
        prompt: "Synthetic prompt",
        firstMessage: "Synthetic greeting",
        language: .en,
        voiceID: "synthetic-voice"
      )
    )

    do {
      _ = try await transport.start(request)
      XCTFail("A build without ElevenLabs must fail closed")
    } catch let error as VoiceInterviewTransportError {
      XCTAssertEqual(error, .unavailable)
    } catch {
      XCTFail("Unexpected transport error: \(error)")
    }
  }
  #endif

  private func nativeBootstrapData(sessionID: String, token: String) -> Data {
    envelope("""
    {
      "session_id":"\(sessionID)",
      "conversation_token":"\(token)",
      "overrides":{"agent":{"prompt":{"prompt":"Keep it kind."},"firstMessage":"Hello!","language":"en"},"tts":{"voiceId":"voice-en"}}
    }
    """)
  }

  private func envelope(_ data: String) -> Data {
    Data(("{\"data\":" + data + "}").utf8)
  }

  private func tryDecode<Value: APIValidatable>(_ data: Data, as type: Value.Type) -> Value? {
    try? APIResponseDecoder.decode(data, as: type)
  }
}
