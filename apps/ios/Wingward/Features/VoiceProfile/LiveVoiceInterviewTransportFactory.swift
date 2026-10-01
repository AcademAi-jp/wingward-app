import Foundation
import AVFoundation
import LiveKitWebRTC

/// Composition seam for the live Voice/Profile module. The caller explicitly
/// enables this only after the SDK and native token route are configured; the
/// default factory returns an unavailable transport.
struct LiveVoiceInterviewTransportFactory: Sendable {
  let bootstrapKind: VoiceInterviewBootstrapKind
  let enabled: Bool

  init(
    bootstrapKind: VoiceInterviewBootstrapKind = .legacySignedURL,
    enabled: Bool = false
  ) {
    self.bootstrapKind = bootstrapKind
    self.enabled = enabled
  }

  func make() -> any VoiceInterviewTransport {
    if bootstrapKind == .openAIRealtime { return OpenAIRealtimeTransport(enabled: enabled) }
    guard bootstrapKind == .nativeConversationToken else {
      return UnavailableVoiceInterviewTransport()
    }
    return LiveVoiceInterviewTransport(enabled: enabled)
  }
}

/// Holds finalized turns in conversation order, never in transcription arrival order.
/// An interrupted AI utterance is omitted: its full transcript was not heard.
struct RealtimeInterviewLog {
  struct Item {
    let id: String
    let source: VoiceTranscriptEntry.Source
    var text: String?
    var omitted = false
  }
  private(set) var items: [Item] = []
  mutating func ensureUserItem(id: String) throws {
    if items.contains(where: { $0.id == id }) { return }
    try add(id: id, role: "user")
  }
  mutating func add(id: String, role: String) throws {
    guard !items.contains(where: { $0.id == id }) else { return }
    guard role == "user" || role == "assistant" else { return }
    guard items.count < 200, !id.isEmpty else { throw VoiceProfileDTOValidationError.invalidTranscript }
    items.append(Item(id: id, source: role == "user" ? .user : .ai))
  }
  mutating func finalize(id: String, text: String) throws {
    guard let index = items.firstIndex(where: { $0.id == id }) else { throw VoiceProfileDTOValidationError.invalidTranscript }
    if items[index].omitted { return }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      items[index].omitted = true
      return
    }
    try VoiceTranscriptEntry.validate(.init(source: items[index].source, message: text))
    if let existing = items[index].text, existing != text { throw VoiceProfileDTOValidationError.invalidTranscript }
    items[index].text = text
  }
  mutating func omit(id: String) {
    if let index = items.firstIndex(where: { $0.id == id }) { items[index].omitted = true }
  }
  mutating func omitLastAssistant() {
    if let index = items.lastIndex(where: { $0.source == .ai }) { items[index].omitted = true }
  }
  var isSettled: Bool { items.allSatisfy { $0.omitted || $0.text != nil } }
  func entries() throws -> [VoiceTranscriptEntry] {
    guard isSettled else { throw VoiceProfileDTOValidationError.invalidTranscript }
    return items.compactMap { item in
      guard !item.omitted, let text = item.text else { return nil }
      return VoiceTranscriptEntry(source: item.source, message: text)
    }
  }
}

/// Correlates stop requests with responses. A response can finish on the
/// server before our cancel arrives; that benign race must not discard a call.
struct RealtimeResponseLifecycle {
  private(set) var activeIDs: Set<String> = []
  private var cancellationRequests: [String: String] = [:]
  private var cancellationRequested: Set<String> = []

  mutating func started(_ id: String) { activeIDs.insert(id) }
  mutating func finished(_ id: String) { activeIDs.remove(id) }

  mutating func cancellation(for id: String) -> [String: String]? {
    guard activeIDs.contains(id), cancellationRequested.insert(id).inserted else { return nil }
    let eventID = UUID().uuidString
    cancellationRequests[eventID] = id
    return ["type": "response.cancel", "response_id": id, "event_id": eventID]
  }

  mutating func acceptsAlreadyFinished(code: String?, eventID: String?) -> Bool {
    guard code == "response_cancel_not_active", let eventID,
      let responseID = cancellationRequests.removeValue(forKey: eventID) else { return false }
    activeIDs.remove(responseID)
    return true
  }
}

/// Stop has two provider barriers: disable automatic turns, then commit the
/// remaining input. VAD speech flags are advisory, not a save acknowledgement.
struct RealtimeInputCommit {
  private var updateRequested = false
  private var eventID: String?
  private(set) var isSettled = false

  mutating func beginShutdown() -> [String: Any]? {
    guard !updateRequested else { return nil }
    updateRequested = true
    return ["type": "session.update", "session": [
      "type": "realtime", "audio": ["input": ["turn_detection": NSNull()]]
    ]]
  }

  mutating func sessionUpdated(_ event: [String: Any]) -> [String: String]? {
    guard updateRequested,
      let session = event["session"] as? [String: Any],
      let audio = session["audio"] as? [String: Any],
      let input = audio["input"] as? [String: Any],
      input["turn_detection"] is NSNull else { return nil }
    return command()
  }

  mutating func command() -> [String: String]? {
    guard eventID == nil, !isSettled else { return nil }
    let id = UUID().uuidString
    eventID = id
    return ["type": "input_audio_buffer.commit", "event_id": id]
  }

  mutating func committed() {
    // Earlier automatic commits do not acknowledge our final explicit commit.
    guard eventID != nil else { return }
    isSettled = true
  }

  mutating func acceptsEmptyBuffer(code: String?, eventID incoming: String?) -> Bool {
    guard code == "input_audio_buffer_commit_empty", let incoming, incoming == eventID else { return false }
    eventID = nil
    isSettled = true
    return true
  }
}

actor OpenAIRealtimeTransport: VoiceInterviewTransport {
  nonisolated let isAvailable: Bool
  private var driver: RealtimeWebRTCSession?
  private let serverAPI: (any BoundedRealtimeCallAPI)?
  init(enabled: Bool, serverAPI: (any BoundedRealtimeCallAPI)? = nil) { isAvailable = enabled; self.serverAPI = serverAPI }
  func start(_ request: VoiceInterviewRequest) async throws -> AsyncThrowingStream<VoiceInterviewEvent, Error> {
    guard isAvailable else { throw VoiceInterviewTransportError.unavailable }
    try VoiceInterviewRequest.validate(request)
    switch request.credential {
    case .realtimeSecret: break
    case .serverBoundedRealtime: guard serverAPI != nil else { throw VoiceInterviewTransportError.connectionFailed }
    default: throw VoiceInterviewTransportError.connectionFailed
    }
    if let driver { await driver.abort() }
    let next = await RealtimeWebRTCSession(serverAPI: serverAPI)
    driver = next
    return try await withTaskCancellationHandler {
      try await next.connect(request)
    } onCancel: { Task { await next.abort() } }
  }
  func stop() async { if let driver { await driver.finishInterview() } }
}

private final class RealtimeNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Each call owns one peer, callback sink and in-memory log. No recordings or credentials are persisted.
@MainActor private final class RealtimeWebRTCSession: NSObject, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate {
  private var factory: LKRTCPeerConnectionFactory?
  private var peer: LKRTCPeerConnection?
  private var channel: LKRTCDataChannel?
  private var microphone: LKRTCAudioTrack?
  private var continuation: AsyncThrowingStream<VoiceInterviewEvent, Error>.Continuation?
  private var http: URLSession?
  private var log = RealtimeInterviewLog()
  private var closed = false
  private var ending = false
  private var ready = false
  private var speaking = false
  private var userSpeaking = false
  private var responses = RealtimeResponseLifecycle()
  private var inputCommit = RealtimeInputCommit()
  private var limitTask: Task<Void, Never>?
  private var diagnosticStage = "connection"
  private let serverAPI: (any BoundedRealtimeCallAPI)?
  private var boundedSessionID: UUID?
  init(serverAPI: (any BoundedRealtimeCallAPI)? = nil) { self.serverAPI = serverAPI; super.init() }

  /// Simulator-only diagnostics contain counts and state, never audio, text or credentials.
  private func writeSimulatorDiagnostic(_ outcome: String) {
    #if DEBUG && targetEnvironment(simulator)
      let values: [String: Any] = [
        "outcome": outcome, "stage": diagnosticStage, "ready": ready,
        "ending": ending, "user_speaking": userSpeaking, "ai_speaking": speaking,
        "active_responses": responses.activeIDs.count, "transcripts_settled": log.isSettled,
        "final_input_settled": inputCommit.isSettled,
        "user_items": log.items.filter { $0.source == .user }.count,
        "final_user_items": log.items.filter { $0.source == .user && $0.text != nil && !$0.omitted }.count,
        "ai_items": log.items.filter { $0.source == .ai }.count,
      ]
      if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
        let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
        try? data.write(to: directory.appendingPathComponent("realtime-state-counts.json"), options: .atomic)
      }
    #endif
  }

  func connect(_ request: VoiceInterviewRequest) async throws -> AsyncThrowingStream<VoiceInterviewEvent, Error> {
    var directSecret: String?
    var boundedSeconds = VoiceProfileStore.interviewDurationSeconds
    switch request.credential {
    case let .realtimeSecret(secret, _): directSecret = secret
    case let .serverBoundedRealtime(maxSeconds): boundedSeconds = min(boundedSeconds, maxSeconds - 10)
    default: throw VoiceInterviewTransportError.connectionFailed
    }
    let (stream, sink) = AsyncThrowingStream<VoiceInterviewEvent, Error>.makeStream()
    continuation = sink
    sink.onTermination = { [weak self] _ in Task { @MainActor in self?.abort() } }
    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
      try audio.setActive(true)
      let factory = LKRTCPeerConnectionFactory()
      self.factory = factory
      let config = LKRTCConfiguration()
      config.sdpSemantics = .unifiedPlan
      let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
      guard let peer = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
        throw VoiceInterviewTransportError.connectionFailed
      }
      self.peer = peer
      let track = factory.audioTrack(withTrackId: "wingward-microphone")
      track.isEnabled = false
      microphone = track
      peer.add(track, streamIds: ["wingward-audio"])
      let channelConfig = LKRTCDataChannelConfiguration()
      channelConfig.isOrdered = true
      channel = peer.dataChannel(forLabel: "oai-events", configuration: channelConfig)
      channel?.delegate = self
      guard channel != nil else { throw VoiceInterviewTransportError.connectionFailed }
      let offer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { completion in
        peer.offer(for: constraints) { sdp, _ in
          if let sdp { completion.resume(returning: sdp) }
          else { completion.resume(throwing: VoiceInterviewTransportError.connectionFailed) }
        }
      }
      try checkOpen()
      try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
        peer.setLocalDescription(offer) { error in
          if error != nil { completion.resume(throwing: VoiceInterviewTransportError.connectionFailed) }
          else { completion.resume() }
        }
      }
      try checkOpen()
      let sdp: String
      if case .serverBoundedRealtime = request.credential {
        guard let serverAPI, let voice = RealtimeVoice(rawValue: request.overrides.voiceID) else {
          throw VoiceInterviewTransportError.connectionFailed
        }
        boundedSessionID = request.sessionID
        let answer = try await serverAPI.fetchRealtimeCall(sessionID: request.sessionID, sdp: offer.sdp, voice: voice)
        try BoundedRealtimeCallAnswer.validate(answer)
        boundedSeconds = min(boundedSeconds, max(1, answer.maxDurationSeconds - 10))
        sdp = answer.sdp
      } else {
        guard let secret = directSecret else { throw VoiceInterviewTransportError.connectionFailed }
        var exchange = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/calls")!)
        exchange.httpMethod = "POST"
        exchange.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        exchange.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        exchange.httpBody = offer.sdp.data(using: .utf8)
        let configHTTP = URLSessionConfiguration.ephemeral
        configHTTP.timeoutIntervalForRequest = 15
        configHTTP.timeoutIntervalForResource = 20
        configHTTP.urlCache = nil
        configHTTP.httpCookieStorage = nil
        let session = URLSession(configuration: configHTTP, delegate: RealtimeNoRedirect(), delegateQueue: nil)
        http = session
        let (bytes, response) = try await session.bytes(for: exchange)
        guard let response = response as? HTTPURLResponse, response.statusCode == 201,
          response.url?.host == "api.openai.com" else { throw VoiceInterviewTransportError.connectionFailed }
        var data = Data()
        for try await byte in bytes {
          guard data.count < 65_536 else { throw VoiceInterviewTransportError.connectionFailed }
          data.append(byte)
        }
        session.finishTasksAndInvalidate()
        http = nil
        try checkOpen()
        guard let answer = String(data: data, encoding: .utf8), answer.hasPrefix("v=0") else { throw VoiceInterviewTransportError.connectionFailed }
        sdp = answer
      }
      try checkOpen()
      try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
        peer.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp)) { error in
          if error != nil { completion.resume(throwing: VoiceInterviewTransportError.connectionFailed) }
          else { completion.resume() }
        }
      }
      // Do not expose interviewing state until the actual provider session is ready.
      for _ in 0..<100 {
        try checkOpen()
        if ready { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard ready else { throw VoiceInterviewTransportError.connectionFailed }
      microphone?.isEnabled = true
      diagnosticStage = "interview"
      writeSimulatorDiagnostic("connected")
      try send(["type": "response.create"])
      let localDuration = boundedSeconds
      limitTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(localDuration)) } catch { return }
        await self?.finishInterview()
      }
      return stream
    } catch {
      abort()
      throw VoiceInterviewTransportError.connectionFailed
    }
  }

  private func checkOpen() throws {
    guard !closed, !Task.isCancelled else { throw VoiceInterviewTransportError.cancelled }
  }
  private func send(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    guard channel?.sendData(LKRTCDataBuffer(data: data, isBinary: false)) == true else {
      throw VoiceInterviewTransportError.connectionFailed
    }
  }
  func abort() {
    guard !closed else { return }
    writeSimulatorDiagnostic("failed")
    continuation?.finish(throwing: VoiceInterviewTransportError.connectionFailed)
    close()
  }
  private func close() {
    if let sessionID = boundedSessionID, let serverAPI {
      boundedSessionID = nil
      Task { try? await serverAPI.stopRealtimeCall(sessionID: sessionID) }
    }
    closed = true
    limitTask?.cancel()
    limitTask = nil
    microphone?.isEnabled = false
    channel?.delegate = nil
    peer?.delegate = nil
    channel?.close()
    peer?.close()
    channel = nil
    peer = nil
    microphone = nil
    factory = nil
    http?.invalidateAndCancel()
    http = nil
    continuation = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
  func finishInterview() async {
    guard !closed, !ending else { return }
    ending = true
    diagnosticStage = "finish"
    microphone?.isEnabled = false
    // End promptly without waiting for another long AI answer. Final user
    // transcription is still required; interrupted AI text is never saved as heard.
    do {
      // Stop automatic VAD turns before the final commit. The ordered session
      // acknowledgement prevents an earlier automatic commit from being mistaken
      // for completion of the final input. Commit even if speech_started is late.
      if let update = inputCommit.beginShutdown() { try send(update) }
      try cancelActiveResponses()
      if speaking {
        log.omitLastAssistant()
        try send(["type": "output_audio_buffer.clear"])
      }
    } catch { abort(); return }
    // Await the final commit, its transcription, and queued output playback.
    for index in 0..<120 {
      if closed { return }
      if index >= 15 && inputCommit.isSettled && !speaking && responses.activeIDs.isEmpty && log.isSettled { break }
      do { try await Task.sleep(for: .milliseconds(100)) } catch { abort(); return }
    }
    guard !closed, inputCommit.isSettled, !speaking, responses.activeIDs.isEmpty, log.isSettled,
      let entries = try? log.entries(), entries.contains(where: { $0.source == .user }) else { abort(); return }
    for entry in entries { continuation?.yield(.transcript(entry)) }
    writeSimulatorDiagnostic("completed")
    continuation?.yield(.ended)
    continuation?.finish()
    close()
  }
  private func cancelActiveResponses() throws {
    for id in responses.activeIDs.sorted() {
      if let event = responses.cancellation(for: id) { try send(event) }
    }
  }

  private func receive(_ data: Data) {
    guard !closed else { return }
    do {
      guard data.count <= 131_072, let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let type = event["type"] as? String else { throw VoiceInterviewTransportError.connectionFailed }
      switch type {
      case "session.created": ready = true; continuation?.yield(.connected)
      case "session.updated":
        if ending, let command = inputCommit.sessionUpdated(event) { try send(command) }
      case "input_audio_buffer.speech_started": userSpeaking = true
      case "input_audio_buffer.speech_stopped": userSpeaking = false
      case "input_audio_buffer.committed":
        if ending {
          guard let id = event["item_id"] as? String, !id.isEmpty else { throw VoiceInterviewTransportError.connectionFailed }
          // Reserve the item now so a delayed created event cannot make the
          // drain appear settled before final transcription arrives.
          try log.ensureUserItem(id: id)
          inputCommit.committed()
          userSpeaking = false
        }
      case "conversation.item.added", "conversation.item.created":
        if let item = event["item"] as? [String: Any], let id = item["id"] as? String, let role = item["role"] as? String {
          try log.add(id: id, role: role)
        }
      case "conversation.item.input_audio_transcription.completed", "response.output_audio_transcript.done":
        guard let id = event["item_id"] as? String, let text = event["transcript"] as? String else { throw VoiceInterviewTransportError.connectionFailed }
        try log.finalize(id: id, text: text)
      case "conversation.item.truncated":
        if let id = event["item_id"] as? String { log.omit(id: id) }
      case "response.created":
        guard let response = event["response"] as? [String: Any],
          let id = response["id"] as? String, !id.isEmpty else { throw VoiceInterviewTransportError.connectionFailed }
        responses.started(id)
        if ending { try cancelActiveResponses() }
      case "response.done":
        guard let response = event["response"] as? [String: Any], let status = response["status"] as? String,
          let id = response["id"] as? String, !id.isEmpty else { throw VoiceInterviewTransportError.connectionFailed }
        responses.finished(id)
        if status == "cancelled" || status == "incomplete" {
          for item in response["output"] as? [[String: Any]] ?? [] {
            if let id = item["id"] as? String { log.omit(id: id) }
          }
        } else if status != "completed" { throw VoiceInterviewTransportError.connectionFailed }
      case "output_audio_buffer.started": speaking = true; continuation?.yield(.speaking(true))
      case "output_audio_buffer.stopped", "output_audio_buffer.cleared": speaking = false; continuation?.yield(.speaking(false))
      case "error":
        diagnosticStage = "provider_error"
        let error = event["error"] as? [String: Any]
        if ending, inputCommit.acceptsEmptyBuffer(code: error?["code"] as? String,
          eventID: error?["event_id"] as? String) {
          userSpeaking = false
          return
        }
        // Ignore only a known harmless error linked to our own stop command.
        // Auth, transcription, unknown and unrelated errors still fail closed.
        guard ending, responses.acceptsAlreadyFinished(code: error?["code"] as? String,
          eventID: error?["event_id"] as? String) else { throw VoiceInterviewTransportError.connectionFailed }
      case "conversation.item.input_audio_transcription.failed":
        diagnosticStage = "transcription_error"
        throw VoiceInterviewTransportError.connectionFailed
      default: break
      }
    } catch { abort() }
  }
  nonisolated func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
    if dataChannel.readyState == .closed { Task { @MainActor [weak self] in self?.abort() } }
  }
  nonisolated func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
    let data = buffer.data
    Task { @MainActor [weak self] in self?.receive(data) }
  }
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
  nonisolated func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
    if newState == .failed { Task { @MainActor [weak self] in self?.abort() } }
  }
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}
