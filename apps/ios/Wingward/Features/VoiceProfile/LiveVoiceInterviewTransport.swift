import Foundation

#if canImport(ElevenLabs)
import ElevenLabs
#endif

/// Adapts the ElevenLabs native voice SDK to the frozen
/// `VoiceInterviewTransport` contract.
///
/// v3.2.2's `signedWebSocketURL` entry point is text-only. Voice sessions must
/// use `conversationToken`, which the backend obtains with its private API key.
/// Until the package, native bootstrap route, and explicit enable flag are
/// configured, this adapter is deliberately unavailable and never attempts to
/// open the signed URL.
actor LiveVoiceInterviewTransport: VoiceInterviewTransport {
  nonisolated let isEnabled: Bool
  private var activeSession: (any VoiceInterviewSessionController)?

  init(enabled: Bool = false) {
    self.isEnabled = enabled
  }

  nonisolated var isAvailable: Bool {
    #if canImport(ElevenLabs)
    isEnabled
    #else
    false
    #endif
  }

  func start(_ request: VoiceInterviewRequest) async throws -> AsyncThrowingStream<VoiceInterviewEvent, Error> {
    guard isAvailable else {
      throw VoiceInterviewTransportError.unavailable
    }

    await stopActiveSession()
    guard !Task.isCancelled else {
      throw VoiceInterviewTransportError.cancelled
    }

    guard case let .conversationToken(token) = request.credential,
      Self.isUsableToken(token),
      !Task.isCancelled
    else {
      if Task.isCancelled {
        throw VoiceInterviewTransportError.cancelled
      }
      throw VoiceInterviewTransportError.connectionFailed
    }

    #if canImport(ElevenLabs)
    let (stream, continuation) = AsyncThrowingStream<VoiceInterviewEvent, Error>.makeStream(
      of: VoiceInterviewEvent.self,
      throwing: Error.self
    )

    let events = await MainActor.run {
      ElevenLabsVoiceInterviewEventSink(continuation: continuation)
    }
    let configuration = await MainActor.run {
      Self.makeConfiguration(overrides: request.overrides, events: events)
    }

    do {
      let conversation = try await ElevenLabs.startConversation(
        conversationToken: token,
        config: configuration
      )

      guard !Task.isCancelled else {
        await conversation.endConversation()
        await events.finish(throwing: VoiceInterviewTransportError.cancelled)
        throw VoiceInterviewTransportError.cancelled
      }

      let session = await MainActor.run {
        ElevenLabsVoiceInterviewSession(conversation: conversation, events: events)
      }
      install(session)
    } catch is CancellationError {
      await events.finish(throwing: VoiceInterviewTransportError.cancelled)
      throw VoiceInterviewTransportError.cancelled
    } catch let error as VoiceInterviewTransportError {
      await events.finish(throwing: error)
      throw error
    } catch {
      // SDK errors are intentionally normalized. The transport must not
      // leak provider diagnostics or credentials to the UI or logs.
      await events.finish(throwing: VoiceInterviewTransportError.connectionFailed)
      throw VoiceInterviewTransportError.connectionFailed
    }

    guard !Task.isCancelled else {
      await stopActiveSession()
      throw VoiceInterviewTransportError.cancelled
    }
    return stream
    #else
    // Keep this branch explicit so a build without the package cannot claim a
    // live interview or silently downgrade to the text-only signed URL path.
    throw VoiceInterviewTransportError.unavailable
    #endif
  }

  func stop() async {
    await stopActiveSession()
  }

  private func stopActiveSession() async {
    let session = activeSession
    activeSession = nil
    await session?.stop()
  }

  private func install(_ session: any VoiceInterviewSessionController) {
    activeSession = session
  }

  #if canImport(ElevenLabs)
  private static func isUsableToken(_ token: String) -> Bool {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty
      && trimmed == token
      && token.count <= NativeVoiceBootstrap.maxConversationTokenLength
  }

  @MainActor
  private static func makeConfiguration(
    overrides: VoiceInterviewOverrides,
    events: ElevenLabsVoiceInterviewEventSink
  ) -> ConversationConfig {
    let language = Language(rawValue: overrides.language.rawValue)
    return ConversationConfig(
      agentOverrides: AgentOverrides(
        prompt: overrides.prompt,
        firstMessage: overrides.firstMessage,
        language: language
      ),
      ttsOverrides: TTSOverrides(voiceId: overrides.voiceID),
      onAgentReady: {
        Task { @MainActor in events.connected() }
      },
      onDisconnect: { reason in
        Task { @MainActor in events.disconnected(reason) }
      },
      onError: { _ in
        Task { @MainActor in events.failed() }
      },
      onAgentResponse: { text, _ in
        Task { @MainActor in events.transcript(source: .ai, text: text) }
      },
      onUserTranscript: { text, _ in
        Task { @MainActor in events.transcript(source: .user, text: text) }
      },
      onAgentStateChange: { state in
        Task { @MainActor in
          if case .speaking = state {
            events.speaking(true)
          } else {
            events.speaking(false)
          }
        }
      }
    )
  }

#if DEBUG && canImport(ElevenLabs)
  /// Test-only projection of the SDK config passed to its initiation event.
  /// The SDK serializer maps these four non-nil override fields to
  /// `agent.prompt.prompt`, `agent.first_message`, `agent.language`, and
  /// `tts.voice_id`; all other client override groups stay nil.
  @MainActor
  static func configurationForTesting(overrides: VoiceInterviewOverrides) -> ConversationConfig {
    let (stream, continuation) = AsyncThrowingStream<VoiceInterviewEvent, Error>.makeStream(
      of: VoiceInterviewEvent.self,
      throwing: Error.self
    )
    _ = stream
    let events = ElevenLabsVoiceInterviewEventSink(continuation: continuation)
    let configuration = makeConfiguration(overrides: overrides, events: events)
    continuation.finish()
    return configuration
  }
#endif
  #else
  private static func isUsableToken(_ token: String) -> Bool { false }
  #endif
}

private protocol VoiceInterviewSessionController: AnyObject, Sendable {
  func stop() async
}

#if canImport(ElevenLabs)
@MainActor
private final class ElevenLabsVoiceInterviewEventSink {
  private let continuation: AsyncThrowingStream<VoiceInterviewEvent, Error>.Continuation
  private var stopRequested = false
  private var finished = false

  init(continuation: AsyncThrowingStream<VoiceInterviewEvent, Error>.Continuation) {
    self.continuation = continuation
  }

  func connected() {
    guard !finished else { return }
    continuation.yield(.connected)
  }

  func speaking(_ value: Bool) {
    guard !finished else { return }
    continuation.yield(.speaking(value))
  }

  func transcript(source: VoiceTranscriptEntry.Source, text: String) {
    guard !finished else { return }
    let entry = VoiceTranscriptEntry(source: source, message: text)
    do {
      try VoiceTranscriptEntry.validate(entry)
      continuation.yield(.transcript(entry))
    } catch {
      finish(throwing: VoiceInterviewTransportError.connectionFailed)
    }
  }

  func requestStop() {
    stopRequested = true
  }

  func disconnected(_: DisconnectionReason) {
    guard !finished else { return }
    // Only an explicit stop requested through this adapter can claim a
    // graceful end. A remote/user reason from the SDK is still treated as a
    // failed connection unless this owner initiated the stop.
    if stopRequested {
      continuation.yield(.ended)
      finish()
    } else {
      finish(throwing: VoiceInterviewTransportError.connectionFailed)
    }
  }

  func failed() {
    guard !finished else { return }
    finish(throwing: VoiceInterviewTransportError.connectionFailed)
  }

  func finishEndedIfNeeded() {
    guard !finished else { return }
    continuation.yield(.ended)
    finish()
  }

  func finish(throwing error: Error? = nil) {
    guard !finished else { return }
    finished = true
    if let error {
      continuation.finish(throwing: error)
    } else {
      continuation.finish()
    }
  }
}

@MainActor
private final class ElevenLabsVoiceInterviewSession: VoiceInterviewSessionController {
  private let conversation: Conversation
  private let events: ElevenLabsVoiceInterviewEventSink

  init(conversation: Conversation, events: ElevenLabsVoiceInterviewEventSink) {
    self.conversation = conversation
    self.events = events
  }

  func stop() async {
    events.requestStop()
    await conversation.endConversation()
    events.finishEndedIfNeeded()
  }
}
#endif
