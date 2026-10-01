import Foundation
import AVFoundation

enum VoiceProfileDTOValidationError: Error, Equatable, Sendable {
  case invalidValue
  case invalidIdentifier
  case invalidURL
  case unsupportedPersona
  case duplicatePersona
  case duplicateSession
  case invalidPersonaCount
  case invalidGenerationState
  case ownerMismatch
  case invalidSession
  case invalidTranscript
  case unsupportedLanguage
  case invalidStatus
}

enum VoicePersonaType: String, CaseIterable, Codable, Hashable, Sendable {
  case similar = "virtual_similar"
  case complementary = "virtual_complementary"
  case discovery = "virtual_discovery"

  var sortOrder: Int {
    switch self {
    case .similar: return 0
    case .complementary: return 1
    case .discovery: return 2
    }
  }
}

enum VoiceProfileRevisionStatus: String, Decodable, Equatable, Sendable {
  case available
  case claimed
  case completed
}

/// The native client intentionally keeps only the identity needed to choose a
/// session. Persona documents and sections are private generation inputs and
/// are ignored by this closed projection. The optional completion marker is
/// returned only by the owner-bound catalog read so the client can restore
/// progress after relaunch.
struct VoicePersona: Decodable, Equatable, Identifiable, Sendable {
  static let maxNameLength = 120

  let id: UUID
  let type: VoicePersonaType
  let name: String
  let completedSessionID: UUID?

  private enum CodingKeys: String, CodingKey {
    case id
    case type = "persona_type"
    case name
    case completedSessionID = "completed_session_id"
  }

  init(id: UUID, type: VoicePersonaType, name: String, completedSessionID: UUID? = nil) {
    self.id = id
    self.type = type
    self.name = name
    self.completedSessionID = completedSessionID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try APIDTOValidation.requireUUID(container.decode(String.self, forKey: .id))
    let rawType = try container.decode(String.self, forKey: .type)
    guard let type = VoicePersonaType(rawValue: rawType) else {
      throw VoiceProfileDTOValidationError.unsupportedPersona
    }
    let name = try container.decode(String.self, forKey: .name)
    let completedSessionID: UUID?
    if let rawCompletedSessionID = try container.decodeIfPresent(
      String.self,
      forKey: .completedSessionID
    ) {
      completedSessionID = try APIDTOValidation.requireUUID(rawCompletedSessionID)
    } else {
      completedSessionID = nil
    }
    self.init(
      id: id,
      type: type,
      name: name,
      completedSessionID: completedSessionID
    )
    try Self.validate(self)
  }

  static func validate(_ value: VoicePersona) throws {
    try APIDTOValidation.requireNonEmpty(value.name)
    guard value.name.count <= maxNameLength else {
      throw VoiceProfileDTOValidationError.invalidValue
    }
  }
}

struct VoicePersonasPayload: Decodable, Equatable, Sendable, APIValidatable {
  let personas: [VoicePersona]

  init(personas: [VoicePersona]) {
    self.personas = personas
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    personas = try container.decode([VoicePersona].self)
  }

  static func validate(_ value: VoicePersonasPayload) throws {
    // A failed save may leave a valid subset. Preserve it so preparation can
    // recover missing styles without losing completed interviews.
    guard value.personas.count <= VoicePersonaType.allCases.count else {
      throw VoiceProfileDTOValidationError.invalidPersonaCount
    }
    var ids = Set<UUID>()
    var types = Set<VoicePersonaType>()
    var completedSessionIDs = Set<UUID>()
    for persona in value.personas {
      try VoicePersona.validate(persona)
      guard ids.insert(persona.id).inserted else {
        throw VoiceProfileDTOValidationError.duplicatePersona
      }
      guard types.insert(persona.type).inserted else {
        throw VoiceProfileDTOValidationError.duplicatePersona
      }
      if let completedSessionID = persona.completedSessionID {
        guard completedSessionIDs.insert(completedSessionID).inserted else {
          throw VoiceProfileDTOValidationError.duplicateSession
        }
      }
    }
    if value.personas.count == VoicePersonaType.allCases.count,
       types != Set(VoicePersonaType.allCases) {
      throw VoiceProfileDTOValidationError.invalidPersonaCount
    }
  }
}

/// Server-owned generation progress used to restore the personal profile
/// journey after relaunch. The client never infers these flags from a local
/// request history.
struct GenerationStateDTO: Decodable, Equatable, Sendable, APIValidatable {
	static let defaultRequiredInterviewCount = VoicePersonaType.allCases.count
	static let waiverRequiredInterviewCount = 2

	let userID: UUID
	let profileGenerated: Bool
	let wingfoxGenerated: Bool
	let profileConfirmed: Bool
	let requiredInterviewCount: Int
	let interviewWaiverActive: Bool
	let profileRevisionStatus: VoiceProfileRevisionStatus?
	let canRegenerateFromThree: Bool?

	private enum CodingKeys: String, CodingKey {
		case userID = "user_id"
		case profileGenerated = "profile_generated"
		case wingfoxGenerated = "wingfox_generated"
		case profileConfirmed = "profile_confirmed"
		case requiredInterviewCount = "required_interview_count"
		case interviewWaiverActive = "interview_waiver_active"
		case profileRevisionStatus = "profile_revision_status"
		case canRegenerateFromThree = "can_regenerate_from_three"
	}

  init(
    userID: UUID,
		profileGenerated: Bool,
		wingfoxGenerated: Bool,
		profileConfirmed: Bool,
		requiredInterviewCount: Int = Self.defaultRequiredInterviewCount,
		interviewWaiverActive: Bool = false,
		profileRevisionStatus: VoiceProfileRevisionStatus? = nil,
		canRegenerateFromThree: Bool? = nil
	) {
		self.userID = userID
		self.profileGenerated = profileGenerated
		self.wingfoxGenerated = wingfoxGenerated
		self.profileConfirmed = profileConfirmed
		self.requiredInterviewCount = requiredInterviewCount
		self.interviewWaiverActive = interviewWaiverActive
		self.profileRevisionStatus = profileRevisionStatus
		self.canRegenerateFromThree = canRegenerateFromThree
	}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let profileRevisionStatus: VoiceProfileRevisionStatus?
    if let rawStatus = try container.decodeIfPresent(String.self, forKey: .profileRevisionStatus) {
      guard let parsedStatus = VoiceProfileRevisionStatus(rawValue: rawStatus) else {
        throw VoiceProfileDTOValidationError.invalidGenerationState
      }
      profileRevisionStatus = parsedStatus
    } else {
      profileRevisionStatus = nil
    }
    self.init(
      userID: try APIDTOValidation.requireUUID(container.decode(String.self, forKey: .userID)),
		profileGenerated: try container.decode(Bool.self, forKey: .profileGenerated),
		wingfoxGenerated: try container.decode(Bool.self, forKey: .wingfoxGenerated),
		profileConfirmed: try container.decode(Bool.self, forKey: .profileConfirmed),
		requiredInterviewCount: try container.decodeIfPresent(Int.self, forKey: .requiredInterviewCount)
			?? Self.defaultRequiredInterviewCount,
		interviewWaiverActive: try container.decodeIfPresent(Bool.self, forKey: .interviewWaiverActive)
			?? false,
		profileRevisionStatus: profileRevisionStatus,
		canRegenerateFromThree: try container.decodeIfPresent(Bool.self, forKey: .canRegenerateFromThree)
		)
    try Self.validate(self)
  }

	static func validate(_ value: GenerationStateDTO) throws {
		guard value.requiredInterviewCount == (value.interviewWaiverActive
			? Self.waiverRequiredInterviewCount
			: Self.defaultRequiredInterviewCount) else {
			throw VoiceProfileDTOValidationError.invalidGenerationState
		}
		guard (value.profileRevisionStatus == nil) == (value.canRegenerateFromThree == nil) else {
			throw VoiceProfileDTOValidationError.invalidGenerationState
		}
		if let profileRevisionStatus = value.profileRevisionStatus {
			guard value.profileGenerated,
				value.wingfoxGenerated,
				value.requiredInterviewCount == Self.defaultRequiredInterviewCount,
				!value.interviewWaiverActive
			else {
				throw VoiceProfileDTOValidationError.invalidGenerationState
			}
			if profileRevisionStatus != .completed, value.profileConfirmed {
				throw VoiceProfileDTOValidationError.invalidGenerationState
			}
			if profileRevisionStatus != .available, value.canRegenerateFromThree == true {
				throw VoiceProfileDTOValidationError.invalidGenerationState
			}
		}
		// The server requires a personal profile before creating the AI partner,
    // and confirmation requires both generated resources.
    guard value.profileGenerated || !value.wingfoxGenerated,
      value.profileGenerated || !value.profileConfirmed,
      value.wingfoxGenerated || !value.profileConfirmed
    else {
      throw VoiceProfileDTOValidationError.invalidGenerationState
    }
  }
}

/// Alias used by callers that describe this value as the voice generation
/// state rather than by its wire-level DTO name.
typealias VoiceGenerationStateDTO = GenerationStateDTO

struct VoiceSessionStartResult: Decodable, Equatable, Sendable, APIValidatable {
  let sessionID: UUID
  let personaID: UUID
  let personaName: String

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case persona
  }

  private struct Persona: Decodable {
    let id: String
    let name: String
  }

  init(sessionID: UUID, personaID: UUID, personaName: String) {
    self.sessionID = sessionID
    self.personaID = personaID
    self.personaName = personaName
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let sessionID = try APIDTOValidation.requireUUID(container.decode(String.self, forKey: .sessionID))
    let persona = try container.decode(Persona.self, forKey: .persona)
    let personaID = try APIDTOValidation.requireUUID(persona.id)
    self.init(sessionID: sessionID, personaID: personaID, personaName: persona.name)
    try Self.validate(self)
  }

  static func validate(_ value: VoiceSessionStartResult) throws {
    try APIDTOValidation.requireNonEmpty(value.personaName)
    guard value.personaName.count <= VoicePersona.maxNameLength else {
      throw VoiceProfileDTOValidationError.invalidValue
    }
  }
}

struct VoiceInterviewOverrides: Decodable, Equatable, Sendable {
  let prompt: String
  let firstMessage: String?
  let language: OnboardingLanguage
  let voiceID: String

  private enum CodingKeys: String, CodingKey {
    case agent
    case tts
  }

  private struct Agent: Decodable {
    let prompt: Prompt
    let firstMessage: String?
    let language: String?

    enum CodingKeys: String, CodingKey {
      case prompt
      case firstMessage = "firstMessage"
      case language
    }
  }

  private struct Prompt: Decodable {
    let prompt: String
  }

  private struct TTS: Decodable {
    let voiceID: String?

    enum CodingKeys: String, CodingKey {
      case voiceID = "voiceId"
    }
  }

  init(prompt: String, firstMessage: String?, language: OnboardingLanguage, voiceID: String) {
    self.prompt = prompt
    self.firstMessage = firstMessage
    self.language = language
    self.voiceID = voiceID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let agent = try container.decode(Agent.self, forKey: .agent)
    let tts = try container.decode(TTS.self, forKey: .tts)
    guard let language = agent.language.flatMap(OnboardingLanguage.init(rawValue:)) else {
      throw VoiceProfileDTOValidationError.unsupportedLanguage
    }
    guard let voiceID = tts.voiceID else {
      throw VoiceProfileDTOValidationError.invalidValue
    }
    self.init(
      prompt: agent.prompt.prompt,
      firstMessage: agent.firstMessage,
      language: language,
      voiceID: voiceID
    )
    try Self.validate(self)
  }

  static func validate(_ value: VoiceInterviewOverrides) throws {
    try APIDTOValidation.requireNonEmpty(value.prompt)
    guard value.prompt.count <= 32_000 else { throw VoiceProfileDTOValidationError.invalidValue }
    if let firstMessage = value.firstMessage {
      try APIDTOValidation.requireNonEmpty(firstMessage)
      guard firstMessage.count <= 1_000 else { throw VoiceProfileDTOValidationError.invalidValue }
    }
    try APIDTOValidation.requireNonEmpty(value.voiceID)
    guard value.voiceID.count <= 160 else { throw VoiceProfileDTOValidationError.invalidValue }
  }
}

struct VoiceInterviewBootstrap: Decodable, Equatable, Sendable, APIValidatable {
  static let allowedSignedURLHost = "api.elevenlabs.io"

  let signedURL: URL
  let overrides: VoiceInterviewOverrides
  let personaName: String

  private enum CodingKeys: String, CodingKey {
    case signedURL = "signed_url"
    case overrides
    case persona
  }

  private struct Persona: Decodable {
    let name: String
  }

  init(signedURL: URL, overrides: VoiceInterviewOverrides, personaName: String) {
    self.signedURL = signedURL
    self.overrides = overrides
    self.personaName = personaName
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawURL = try container.decode(String.self, forKey: .signedURL)
    guard let signedURL = URL(string: rawURL) else {
      throw VoiceProfileDTOValidationError.invalidURL
    }
    let overrides = try container.decode(VoiceInterviewOverrides.self, forKey: .overrides)
    let personaName = try container.decode(Persona.self, forKey: .persona).name
    self.init(signedURL: signedURL, overrides: overrides, personaName: personaName)
    try Self.validate(self)
  }

  static func validate(_ value: VoiceInterviewBootstrap) throws {
    guard value.signedURL.scheme?.lowercased() == "wss",
      value.signedURL.host?.lowercased() == allowedSignedURLHost,
      value.signedURL.path == "/v1/convai/conversation",
      value.signedURL.user == nil,
      value.signedURL.password == nil,
      value.signedURL.fragment == nil,
      value.signedURL.port == nil || value.signedURL.port == 443
    else {
      throw VoiceProfileDTOValidationError.invalidURL
    }
    let hasSignature = URLComponents(url: value.signedURL, resolvingAgainstBaseURL: false)?
      .queryItems?
      .contains { item in
        item.name == "conversation_signature"
          && !(item.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
      } ?? false
    guard hasSignature else { throw VoiceProfileDTOValidationError.invalidURL }
    try VoiceInterviewOverrides.validate(value.overrides)
    try APIDTOValidation.requireNonEmpty(value.personaName)
    guard value.personaName.count <= VoicePersona.maxNameLength else {
      throw VoiceProfileDTOValidationError.invalidValue
    }
  }
}

/// Native voice bootstrap returned by the owner-bound backend route. The
/// conversation token is an opaque, short-lived vendor credential and is
/// intentionally kept separate from the legacy signed WebSocket URL DTO.
struct NativeVoiceBootstrap: Decodable, Equatable, Sendable, APIValidatable {
  static let maxConversationTokenLength = 8_192

  let sessionID: UUID
  let conversationToken: String
  let overrides: VoiceInterviewOverrides

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case conversationToken = "conversation_token"
    case overrides
  }

  init(
    sessionID: UUID,
    conversationToken: String,
    overrides: VoiceInterviewOverrides
  ) {
    self.sessionID = sessionID
    self.conversationToken = conversationToken
    self.overrides = overrides
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let sessionID = try APIDTOValidation.requireUUID(container.decode(String.self, forKey: .sessionID))
    let conversationToken = try container.decode(String.self, forKey: .conversationToken)
    let overrides = try container.decode(VoiceInterviewOverrides.self, forKey: .overrides)
    self.init(
      sessionID: sessionID,
      conversationToken: conversationToken,
      overrides: overrides
    )
    try Self.validate(self)
  }

  static func validate(_ value: NativeVoiceBootstrap) throws {
    try validateConversationToken(value.conversationToken)
    try VoiceInterviewOverrides.validate(value.overrides)
  }

  static func validateConversationToken(_ token: String) throws {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      trimmed == token,
      token.count <= maxConversationTokenLength
    else {
      throw VoiceProfileDTOValidationError.invalidValue
    }
  }
}

struct VoiceTranscriptEntry: Codable, Equatable, Sendable {
  enum Source: String, Codable, Equatable, Sendable {
    case user
    case ai
  }

  static let maxMessageLength = 2_000

  let source: Source
  let message: String

  init(source: Source, message: String) {
    self.source = source
    self.message = message
  }

  static func validate(_ value: VoiceTranscriptEntry) throws {
    try APIDTOValidation.requireNonEmpty(value.message)
    guard value.message.count <= maxMessageLength else {
      throw VoiceProfileDTOValidationError.invalidTranscript
    }
  }
}

struct VoiceSessionCompletion: Decodable, Equatable, Sendable, APIValidatable {
  let sessionID: UUID
  let status: String
  let allSessionsCompleted: Bool

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case status
    case allSessionsCompleted = "all_sessions_completed"
  }

  init(sessionID: UUID, status: String, allSessionsCompleted: Bool) {
    self.sessionID = sessionID
    self.status = status
    self.allSessionsCompleted = allSessionsCompleted
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let sessionID = try APIDTOValidation.requireUUID(container.decode(String.self, forKey: .sessionID))
    self.init(
      sessionID: sessionID,
      status: try container.decode(String.self, forKey: .status),
      allSessionsCompleted: try container.decode(Bool.self, forKey: .allSessionsCompleted)
    )
    try Self.validate(self)
  }

  static func validate(_ value: VoiceSessionCompletion) throws {
    guard value.status == "completed" else { throw VoiceProfileDTOValidationError.invalidStatus }
  }
}

/// Generation endpoints return a large private profile/persona document. The
/// native layer decodes only the stable identity projection and deliberately
/// ignores raw profile sections and analysis fields.
struct VoiceGenerationAcknowledgement: Decodable, Equatable, Sendable, APIValidatable {
  let id: UUID
  let userID: UUID

  private enum CodingKeys: String, CodingKey {
    case id
    case userID = "user_id"
  }

  init(id: UUID, userID: UUID) {
    self.id = id
    self.userID = userID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try APIDTOValidation.requireUUID(container.decode(String.self, forKey: .id)),
      userID: try APIDTOValidation.requireUUID(container.decode(String.self, forKey: .userID))
    )
    try Self.validate(self)
  }

  static func validate(_ value: VoiceGenerationAcknowledgement) throws {
    // UUID parsing above is canonical and the server-owned identity fields are
    // required even though the private document is intentionally ignored.
    _ = value.id
    _ = value.userID
  }
}

struct VoiceProfileConfirmation: Decodable, Equatable, Sendable, APIValidatable {
  let status: String
  let confirmedAt: Date

  private enum CodingKeys: String, CodingKey {
    case status
    case confirmedAt = "confirmed_at"
  }

  init(status: String, confirmedAt: Date) {
    self.status = status
    self.confirmedAt = confirmedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let status = try container.decode(String.self, forKey: .status)
    let confirmedAt = try APIDTOValidation.requireRFC3339(container.decode(String.self, forKey: .confirmedAt))
    self.init(status: status, confirmedAt: confirmedAt)
    try Self.validate(self)
  }

  static func validate(_ value: VoiceProfileConfirmation) throws {
    guard value.status == "confirmed" else { throw VoiceProfileDTOValidationError.invalidStatus }
  }
}

protocol BoundedRealtimeCallAPI: Sendable {
  func fetchRealtimeCall(sessionID: UUID, sdp: String, voice: RealtimeVoice) async throws -> BoundedRealtimeCallAnswer
  func stopRealtimeCall(sessionID: UUID) async throws
}

protocol VoiceProfileAPI: BoundedRealtimeCallAPI {
  func fetchPersonas() async throws -> [VoicePersona]
  func generatePersonas() async throws -> [VoicePersona]
  func fetchGenerationState() async throws -> GenerationStateDTO?
  func startSession(personaID: UUID) async throws -> VoiceSessionStartResult
  func fetchSignedURL(sessionID: UUID) async throws -> VoiceInterviewBootstrap
  func fetchNativeBootstrap(sessionID: UUID) async throws -> NativeVoiceBootstrap
  func fetchRealtimeBootstrap(sessionID: UUID, voice: RealtimeVoice) async throws -> RealtimeVoiceBootstrap
  func fetchRealtimeCall(sessionID: UUID, sdp: String, voice: RealtimeVoice) async throws -> BoundedRealtimeCallAnswer
  func stopRealtimeCall(sessionID: UUID) async throws
  func completeSession(sessionID: UUID, transcript: [VoiceTranscriptEntry]) async throws -> VoiceSessionCompletion
  func generateProfile() async throws
  func generateWingfox() async throws
  func confirmProfile() async throws -> VoiceProfileConfirmation
}

extension VoiceProfileAPI {
  func fetchRealtimeCall(sessionID: UUID, sdp: String, voice: RealtimeVoice) async throws -> BoundedRealtimeCallAnswer { throw VoiceInterviewTransportError.unavailable }
  func stopRealtimeCall(sessionID: UUID) async throws { throw VoiceInterviewTransportError.unavailable }
  /// Legacy/debug fakes remain valid until the generation-state route is
  /// available in their fixture. The live adapter never uses this fallback.
  func fetchGenerationState() async throws -> GenerationStateDTO? { nil }

  func fetchRealtimeBootstrap(sessionID: UUID, voice: RealtimeVoice) async throws -> RealtimeVoiceBootstrap {
    throw VoiceInterviewTransportError.unavailable
  }

  /// Legacy/debug fakes remain valid until the native token route is enabled
  /// explicitly by the live factory.
  func fetchNativeBootstrap(sessionID: UUID) async throws -> NativeVoiceBootstrap {
    throw VoiceInterviewTransportError.unavailable
  }
}

struct LiveVoiceProfileAPI: VoiceProfileAPI, Sendable {
  static let personasPath = "/api/speed-dating/personas"
  static let sessionsPath = "/api/speed-dating/sessions"
  static let generationStatePath = "/api/profiles/me/generation-state"
  static let profileGenerationPath = "/api/profiles/generate"
  static let wingfoxGenerationPath = "/api/personas/wingfox/generate"
  static let profileConfirmationPath = "/api/profiles/me/confirm"

  let client: any AuthenticatedAPIClientProtocol
  let expectedOwnerID: UUID

  init(client: any AuthenticatedAPIClientProtocol, ownerID: String) throws {
    self.client = client
    self.expectedOwnerID = try APIDTOValidation.requireUUID(ownerID)
  }

  private init(client: any AuthenticatedAPIClientProtocol, expectedOwnerID: UUID) {
    self.client = client
    self.expectedOwnerID = expectedOwnerID
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
    self.init(client: client, expectedOwnerID: try APIDTOValidation.requireUUID(ownerID))
  }

  func fetchPersonas() async throws -> [VoicePersona] {
    try await client.get(Self.personasPath, as: VoicePersonasPayload.self).personas
  }

  func generatePersonas() async throws -> [VoicePersona] {
    try await client.post(Self.personasPath, as: VoicePersonasPayload.self).personas
  }

  func fetchGenerationState() async throws -> GenerationStateDTO? {
    // The live adapter must call this route. The optional protocol result is
    // only a compatibility seam for old/debug fakes.
    let state = try await client.get(Self.generationStatePath, as: GenerationStateDTO.self)
    guard state.userID == expectedOwnerID else {
      throw APIClientError.invalidResponse
    }
    return state
  }

  func startSession(personaID: UUID) async throws -> VoiceSessionStartResult {
    struct Request: Encodable {
      let personaID: String
      enum CodingKeys: String, CodingKey { case personaID = "persona_id" }
    }

    let body = try JSONEncoder().encode(Request(personaID: personaID.uuidString.lowercased()))
    let result = try await client.post(Self.sessionsPath, body: body, as: VoiceSessionStartResult.self)
    guard result.personaID == personaID else { throw APIClientError.invalidResponse }
    return result
  }

  func fetchSignedURL(sessionID: UUID) async throws -> VoiceInterviewBootstrap {
    let path = "\(Self.sessionsPath)/\(sessionID.uuidString.lowercased())/signed-url"
    return try await client.get(path, as: VoiceInterviewBootstrap.self)
  }

  func fetchNativeBootstrap(sessionID: UUID) async throws -> NativeVoiceBootstrap {
    let path = "\(Self.sessionsPath)/\(sessionID.uuidString.lowercased())/native-bootstrap"
    let bootstrap = try await client.get(path, as: NativeVoiceBootstrap.self)
    guard bootstrap.sessionID == sessionID else { throw APIClientError.invalidResponse }
    return bootstrap
  }

  func fetchRealtimeBootstrap(sessionID: UUID, voice: RealtimeVoice) async throws -> RealtimeVoiceBootstrap {
    struct Request: Encodable { let voice: RealtimeVoice }
    let path = "\(Self.sessionsPath)/\(sessionID.uuidString.lowercased())/realtime-bootstrap"
    let result = try await client.post(path, body: JSONEncoder().encode(Request(voice: voice)), as: RealtimeVoiceBootstrap.self)
    guard result.sessionID == sessionID, result.overrides.voiceID == voice.rawValue else { throw APIClientError.invalidResponse }
    return result
  }

  func fetchRealtimeCall(sessionID: UUID, sdp: String, voice: RealtimeVoice) async throws -> BoundedRealtimeCallAnswer {
    struct Request: Encodable { let sdp: String; let voice: RealtimeVoice }
    guard sdp.hasPrefix("v=0"), sdp.utf8.count <= 65_536 else { throw APIClientError.invalidResponse }
    return try await client.post("\(Self.sessionsPath)/\(sessionID.uuidString.lowercased())/realtime-call",
      body: JSONEncoder().encode(Request(sdp: sdp, voice: voice)), as: BoundedRealtimeCallAnswer.self)
  }

  func stopRealtimeCall(sessionID: UUID) async throws {
    struct Stopped: Decodable, Sendable, APIValidatable {
      let closed: Bool
      static func validate(_ value: Self) throws { guard value.closed else { throw APIClientError.invalidResponse } }
    }
    _ = try await client.post("\(Self.sessionsPath)/\(sessionID.uuidString.lowercased())/realtime-stop", as: Stopped.self)
  }

  func completeSession(sessionID: UUID, transcript: [VoiceTranscriptEntry]) async throws -> VoiceSessionCompletion {
    struct Request: Encodable { let transcript: [VoiceTranscriptEntry] }
    for entry in transcript { try VoiceTranscriptEntry.validate(entry) }
    let body = try JSONEncoder().encode(Request(transcript: transcript))
    let path = "\(Self.sessionsPath)/\(sessionID.uuidString.lowercased())/complete"
    let completion = try await client.post(path, body: body, as: VoiceSessionCompletion.self)
    guard completion.sessionID == sessionID else { throw APIClientError.invalidResponse }
    return completion
  }

  func generateProfile() async throws {
    let acknowledgement = try await client.post(Self.profileGenerationPath, as: VoiceGenerationAcknowledgement.self)
    try validateOwner(acknowledgement)
  }

  func generateWingfox() async throws {
    let acknowledgement = try await client.post(Self.wingfoxGenerationPath, as: VoiceGenerationAcknowledgement.self)
    try validateOwner(acknowledgement)
  }

  func confirmProfile() async throws -> VoiceProfileConfirmation {
    try await client.post(Self.profileConfirmationPath, as: VoiceProfileConfirmation.self)
  }

  private func validateOwner(_ acknowledgement: VoiceGenerationAcknowledgement) throws {
    guard acknowledgement.userID == expectedOwnerID else {
      throw APIClientError.invalidResponse
    }
  }
}

enum VoiceInterviewBootstrapKind: Equatable, Sendable {
  case legacySignedURL
  case nativeConversationToken
  case openAIRealtime
}

struct VoiceProfileModule: Sendable {
  let api: any VoiceProfileAPI
  let photoAPI: any ProfilePhotoAPI
  let settingsAPI: any OnboardingSettingsAPI
  let insightAPI: any ConversationInsightAPI
  let permissionClient: any VoicePermissionClient
  let transport: any VoiceInterviewTransport
  let bootstrapKind: VoiceInterviewBootstrapKind

  init(
    api: any VoiceProfileAPI,
    photoAPI: any ProfilePhotoAPI = UnavailableProfilePhotoAPI(),
    settingsAPI: any OnboardingSettingsAPI,
    insightAPI: any ConversationInsightAPI,
    permissionClient: any VoicePermissionClient = SystemVoicePermissionClient(),
    transport: any VoiceInterviewTransport = UnavailableVoiceInterviewTransport(),
    bootstrapKind: VoiceInterviewBootstrapKind = .legacySignedURL
  ) {
    self.api = api
    self.photoAPI = photoAPI
    self.settingsAPI = settingsAPI
    self.insightAPI = insightAPI
    self.permissionClient = permissionClient
    self.transport = transport
    self.bootstrapKind = bootstrapKind
  }
}

protocol VoiceProfileAPIFactory: Sendable {
  func make(ownerID: String) -> VoiceProfileModule?
}

struct LiveVoiceProfileAPIFactory: VoiceProfileAPIFactory, Sendable {
  let baseURL: URL
  let authService: any AuthService
  let profileAPI: any ProfileAPI
  let transport: any APIHTTPTransport
  let permissionClient: any VoicePermissionClient
  let voiceTransport: any VoiceInterviewTransport
  let bootstrapKind: VoiceInterviewBootstrapKind

  init(
    baseURL: URL,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    transport: any APIHTTPTransport = URLSession(configuration: .ephemeral),
    permissionClient: any VoicePermissionClient = SystemVoicePermissionClient(),
    voiceTransport: any VoiceInterviewTransport = UnavailableVoiceInterviewTransport(),
    bootstrapKind: VoiceInterviewBootstrapKind = .legacySignedURL
  ) {
    self.baseURL = baseURL
    self.authService = authService
    self.profileAPI = profileAPI
    self.transport = transport
    self.permissionClient = permissionClient
    self.voiceTransport = voiceTransport
    self.bootstrapKind = bootstrapKind
  }

  func make(ownerID: String) -> VoiceProfileModule? {
    guard let expectedPhotoOwnerID = UUID(uuidString: ownerID.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    do {
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
      let liveAPI = try LiveVoiceProfileAPI(client: client, ownerID: ownerID)
      let boundedTransport: any VoiceInterviewTransport = bootstrapKind == .openAIRealtime && voiceTransport is OpenAIRealtimeTransport
        ? OpenAIRealtimeTransport(enabled: voiceTransport.isAvailable, serverAPI: liveAPI) : voiceTransport
      return VoiceProfileModule(
        api: liveAPI,
        photoAPI: LiveProfilePhotoAPI(client: client, expectedOwnerID: expectedPhotoOwnerID),
        settingsAPI: LiveOnboardingSettingsAPI(client: client, ownerID: ownerID),
        insightAPI: LiveConversationInsightAPI(client: client),
        permissionClient: permissionClient,
        transport: boundedTransport,
        bootstrapKind: bootstrapKind
      )
    } catch {
      return nil
    }
  }
}

enum VoicePermissionStatus: Equatable, Sendable {
  case granted
  case denied
  case restricted
}

protocol VoicePermissionClient: Sendable {
  @MainActor func requestMicrophonePermission() async -> VoicePermissionStatus
}

struct SystemVoicePermissionClient: VoicePermissionClient, Sendable {
  @MainActor
  func requestMicrophonePermission() async -> VoicePermissionStatus {
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
      return .granted
    case .denied:
      return .denied
    case .undetermined:
      return await withCheckedContinuation { continuation in
        AVAudioApplication.requestRecordPermission { granted in
          continuation.resume(returning: granted ? .granted : .denied)
        }
      }
    @unknown default:
      return .restricted
    }
  }
}

enum VoiceInterviewCredential: Equatable, Sendable {
  case signedURL(URL)
  case conversationToken(String)
  case realtimeSecret(String, expiresAt: Double)
  case serverBoundedRealtime(maxSeconds: Int)

  static func validate(_ credential: VoiceInterviewCredential) throws {
    switch credential {
    case let .signedURL(signedURL):
      guard signedURL.scheme?.lowercased() == "wss",
        signedURL.host?.lowercased() == VoiceInterviewBootstrap.allowedSignedURLHost,
        signedURL.path == "/v1/convai/conversation",
        signedURL.user == nil,
        signedURL.password == nil,
        signedURL.fragment == nil,
        signedURL.port == nil || signedURL.port == 443
      else {
        throw VoiceProfileDTOValidationError.invalidURL
      }
      let hasSignature = URLComponents(url: signedURL, resolvingAgainstBaseURL: false)?
        .queryItems?
        .contains { item in
          item.name == "conversation_signature"
            && !(item.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        } ?? false
      guard hasSignature else { throw VoiceProfileDTOValidationError.invalidURL }
    case let .serverBoundedRealtime(maxSeconds):
      guard (15...180).contains(maxSeconds) else { throw VoiceProfileDTOValidationError.invalidValue }
    case let .realtimeSecret(token, expiresAt):
      try RealtimeVoiceBootstrap.validateSecret(token, expiresAt: expiresAt)
    case let .conversationToken(token):
      try NativeVoiceBootstrap.validateConversationToken(token)
    }
  }
}

struct VoiceInterviewRequest: Equatable, Sendable {
  let sessionID: UUID
  let credential: VoiceInterviewCredential
  let overrides: VoiceInterviewOverrides

  /// Compatibility initializer for legacy URL fixtures and text-only
  /// transport tests. Native voice callers must use `credential` with a token.
  init(sessionID: UUID, signedURL: URL, overrides: VoiceInterviewOverrides) {
    self.init(sessionID: sessionID, credential: .signedURL(signedURL), overrides: overrides)
  }

  init(sessionID: UUID, credential: VoiceInterviewCredential, overrides: VoiceInterviewOverrides) {
    self.sessionID = sessionID
    self.credential = credential
    self.overrides = overrides
  }

  static func validate(_ request: VoiceInterviewRequest) throws {
    try VoiceInterviewCredential.validate(request.credential)
    try VoiceInterviewOverrides.validate(request.overrides)
  }
}

enum VoiceInterviewEvent: Equatable, Sendable {
  case connected
  case speaking(Bool)
  case transcript(VoiceTranscriptEntry)
  case ended
}

enum VoiceInterviewTransportError: Error, Equatable, Sendable {
  case unavailable
  case connectionFailed
  case cancelled
}

protocol VoiceInterviewTransport: Sendable {
  var isAvailable: Bool { get }
  func start(_ request: VoiceInterviewRequest) async throws -> AsyncThrowingStream<VoiceInterviewEvent, Error>
  func stop() async
}

/// This is intentionally the default. A signed URL alone does not implement
/// the ElevenLabs websocket/audio protocol, and the app must not claim a live
/// interview until a separately reviewed transport is wired in.
struct UnavailableVoiceInterviewTransport: VoiceInterviewTransport, Sendable {
  let isAvailable = false

  func start(_ request: VoiceInterviewRequest) async throws -> AsyncThrowingStream<VoiceInterviewEvent, Error> {
    throw VoiceInterviewTransportError.unavailable
  }

  func stop() async {}
}

#if DEBUG
struct DebugVoicePermissionClient: VoicePermissionClient, Sendable {
  let status: VoicePermissionStatus

  init(status: VoicePermissionStatus = .granted) {
    self.status = status
  }

  @MainActor
  func requestMicrophonePermission() async -> VoicePermissionStatus { status }
}

struct DebugVoiceInterviewTransport: VoiceInterviewTransport, Sendable {
  let isAvailable: Bool
  let events: [VoiceInterviewEvent]
  let failure: VoiceInterviewTransportError?

  init(
    isAvailable: Bool = true,
    events: [VoiceInterviewEvent] = [
      .connected,
      .transcript(VoiceTranscriptEntry(source: .ai, message: "Hello!")),
      .transcript(VoiceTranscriptEntry(source: .user, message: "Nice to meet you.")),
      .ended,
    ],
    failure: VoiceInterviewTransportError? = nil
  ) {
    self.isAvailable = isAvailable
    self.events = events
    self.failure = failure
  }

  func start(_ request: VoiceInterviewRequest) async throws -> AsyncThrowingStream<VoiceInterviewEvent, Error> {
    if let failure { throw failure }
    return AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }

  func stop() async {}
}
#endif

/// Voice choice never depends on the user's gender or partner preferences.
enum RealtimeVoice: String, CaseIterable, Codable, Sendable { case cedar, marin, ash }

struct BoundedRealtimeCallAnswer: Decodable, Sendable, APIValidatable {
  let sdp: String
  let maxDurationSeconds: Int
  enum CodingKeys: String, CodingKey { case sdp; case maxDurationSeconds = "max_duration_seconds" }
  static func validate(_ value: Self) throws {
    guard value.sdp.hasPrefix("v=0"), value.sdp.utf8.count <= 65_536, !value.sdp.contains("\0"),
      (1...180).contains(value.maxDurationSeconds) else { throw VoiceProfileDTOValidationError.invalidValue }
  }
}

struct RealtimeVoiceBootstrap: Decodable, Sendable, APIValidatable {
  let sessionID: UUID
  let clientSecret: String
  let expiresAt: Double
  let model: String
  let overrides: VoiceInterviewOverrides
  let serverBounded: Bool
  let maxDurationSeconds: Int
  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id", clientSecret = "client_secret", expiresAt = "expires_at", model, overrides, mode
    case maxDurationSeconds = "max_duration_seconds"
  }
  init(sessionID: UUID, clientSecret: String, expiresAt: Double, model: String, overrides: VoiceInterviewOverrides,
    serverBounded: Bool = false, maxDurationSeconds: Int = 180) {
    self.sessionID = sessionID; self.clientSecret = clientSecret; self.expiresAt = expiresAt; self.model = model
    self.overrides = overrides; self.serverBounded = serverBounded; self.maxDurationSeconds = maxDurationSeconds
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let mode = try c.decodeIfPresent(String.self, forKey: .mode)
    guard mode == nil || mode == "server_bounded" else { throw VoiceProfileDTOValidationError.invalidValue }
    self.init(sessionID: try c.decode(UUID.self, forKey: .sessionID),
      clientSecret: try c.decodeIfPresent(String.self, forKey: .clientSecret) ?? "",
      expiresAt: try c.decode(Double.self, forKey: .expiresAt), model: try c.decode(String.self, forKey: .model),
      overrides: try c.decode(VoiceInterviewOverrides.self, forKey: .overrides), serverBounded: mode == "server_bounded",
      maxDurationSeconds: try c.decodeIfPresent(Int.self, forKey: .maxDurationSeconds) ?? 180)
    try Self.validate(self)
  }
  static func validateSecret(_ token: String, expiresAt: Double) throws {
    guard token.hasPrefix("ek_"), token.count > 3, token.count <= 8192,
      token.range(of: "^ek_[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
      expiresAt.isFinite, expiresAt > Date().timeIntervalSince1970 + 5,
      expiresAt <= Date().timeIntervalSince1970 + 125 else { throw VoiceProfileDTOValidationError.invalidValue }
  }
  static func validate(_ value: Self) throws {
    if value.serverBounded {
      guard value.clientSecret.isEmpty, (15...180).contains(value.maxDurationSeconds), value.expiresAt.isFinite,
        value.expiresAt > Date().timeIntervalSince1970 + 5,
        value.expiresAt <= Date().timeIntervalSince1970 + 125 else { throw VoiceProfileDTOValidationError.invalidValue }
    } else { try validateSecret(value.clientSecret, expiresAt: value.expiresAt) }
    try VoiceInterviewOverrides.validate(value.overrides)
    guard value.model == "gpt-realtime-2.1-mini", RealtimeVoice(rawValue: value.overrides.voiceID) != nil else {
      throw VoiceProfileDTOValidationError.invalidValue
    }
  }
}
