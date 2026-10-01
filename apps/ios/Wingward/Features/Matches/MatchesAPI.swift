import Foundation

protocol MatchesAPI: Sendable {
  func fetchDailyResults() async throws -> DailyMatchesPayload
  var demoJudgeMatchingAPI: (any DemoJudgeMatchingAPI)? { get }
  var recordingRehearsalMatchingAPI: (any RecordingRehearsalMatchingAPI)? { get }
}

extension MatchesAPI {
  var demoJudgeMatchingAPI: (any DemoJudgeMatchingAPI)? { nil }
  var recordingRehearsalMatchingAPI: (any RecordingRehearsalMatchingAPI)? { nil }
}

protocol RecordingRehearsalMatchingAPI: Sendable {
  func previewRecordingRehearsal() async throws -> RecordingRehearsalPreviewResult
  func startRecordingRehearsal() async throws -> RecordingRehearsalStartResult
}

protocol DemoJudgeMatchingAPI: Sendable {
  func fetchDiscoveryResults() async throws -> DiscoveryMatchesPayload
  func previewDemoJudgeMatching() async throws -> DemoJudgePreviewResult
  func startDemoJudgeMatching() async throws -> DemoJudgeStartResult
}

struct LiveMatchesAPI: MatchesAPI, RecordingRehearsalMatchingAPI, DemoJudgeMatchingAPI, Sendable {
  static let discoveryResultsPath = "/api/demo-judge/matching/results"
  static let demoJudgePreviewPath = "/api/demo-judge/matching/preview"
  static let demoJudgeStartPath = "/api/demo-judge/matching/start"
  static let dailyResultsPath = "/api/matching/daily-results"
  static let recordingRehearsalPreviewPath = "/api/recording-rehearsal/matching/preview"
  static let recordingRehearsalStartPath = "/api/recording-rehearsal/matching/start"

  let client: any AuthenticatedAPIClientProtocol
  private let demoJudgeMatchingEnabled: Bool
  private let recordingRehearsalMatchingEnabled: Bool

  var demoJudgeMatchingAPI: (any DemoJudgeMatchingAPI)? {
    demoJudgeMatchingEnabled && !recordingRehearsalMatchingEnabled ? self : nil
  }

  var recordingRehearsalMatchingAPI: (any RecordingRehearsalMatchingAPI)? {
    recordingRehearsalMatchingEnabled && !demoJudgeMatchingEnabled ? self : nil
  }

  init(
    client: any AuthenticatedAPIClientProtocol,
    recordingRehearsalMatchingEnabled: Bool = false,
    demoJudgeMatchingEnabled: Bool = false
  ) {
    self.client = client
    self.recordingRehearsalMatchingEnabled = recordingRehearsalMatchingEnabled
    self.demoJudgeMatchingEnabled = demoJudgeMatchingEnabled
  }

  init(
    baseURL: URL,
    ownerID: String,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    transport: any APIHTTPTransport = URLSession(configuration: .ephemeral),
    recordingRehearsalMatchingEnabled: Bool = false,
    demoJudgeMatchingEnabled: Bool = false
  ) throws {
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
    self.init(
      client: client,
      recordingRehearsalMatchingEnabled: recordingRehearsalMatchingEnabled,
      demoJudgeMatchingEnabled: demoJudgeMatchingEnabled
    )
  }

  func fetchDailyResults() async throws -> DailyMatchesPayload {
    guard !demoJudgeMatchingEnabled else { throw APIClientError.invalidState }
    return try await client.get(Self.dailyResultsPath, as: DailyMatchesPayload.self)
  }

  func previewRecordingRehearsal() async throws -> RecordingRehearsalPreviewResult {
    guard recordingRehearsalMatchingEnabled && !demoJudgeMatchingEnabled else { throw APIClientError.invalidState }
    return try await client.post(Self.recordingRehearsalPreviewPath, as: RecordingRehearsalPreviewResult.self)
  }

  func startRecordingRehearsal() async throws -> RecordingRehearsalStartResult {
    guard recordingRehearsalMatchingEnabled && !demoJudgeMatchingEnabled else { throw APIClientError.invalidState }
    return try await client.post(Self.recordingRehearsalStartPath, as: RecordingRehearsalStartResult.self)
  }
}

extension LiveMatchesAPI {
  func fetchDiscoveryResults() async throws -> DiscoveryMatchesPayload {
    guard demoJudgeMatchingAPI != nil else { throw APIClientError.invalidState }
    return try await client.get(Self.discoveryResultsPath, as: DiscoveryMatchesPayload.self)
  }
  func previewDemoJudgeMatching() async throws -> DemoJudgePreviewResult {
    guard demoJudgeMatchingAPI != nil else { throw APIClientError.invalidState }
    return try await client.post(Self.demoJudgePreviewPath, as: DemoJudgePreviewResult.self)
  }
  func startDemoJudgeMatching() async throws -> DemoJudgeStartResult {
    guard demoJudgeMatchingAPI != nil else { throw APIClientError.invalidState }
    return try await client.post(Self.demoJudgeStartPath, as: DemoJudgeStartResult.self)
  }
}

protocol MatchesAPIFactory: Sendable {
  func make(ownerID: String) -> (any MatchesAPI)?
}

struct LiveMatchesAPIFactory: MatchesAPIFactory, Sendable {
  let baseURL: URL
  let authService: any AuthService
  let profileAPI: any ProfileAPI
  let transport: any APIHTTPTransport
  let demoJudgeMatchingEnabled: Bool
  let recordingRehearsalMatchingEnabled: Bool

  init(
    baseURL: URL,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    transport: any APIHTTPTransport = URLSession(configuration: .ephemeral),
    recordingRehearsalMatchingEnabled: Bool = false,
    demoJudgeMatchingEnabled: Bool = false
  ) {
    self.baseURL = baseURL
    self.authService = authService
    self.profileAPI = profileAPI
    self.transport = transport
    self.recordingRehearsalMatchingEnabled = recordingRehearsalMatchingEnabled
    self.demoJudgeMatchingEnabled = demoJudgeMatchingEnabled
  }

  func make(ownerID: String) -> (any MatchesAPI)? {
    guard !(recordingRehearsalMatchingEnabled && demoJudgeMatchingEnabled) else { return nil }
    return try? LiveMatchesAPI(
      baseURL: baseURL,
      ownerID: ownerID,
      authService: authService,
      profileAPI: profileAPI,
      transport: transport,
      recordingRehearsalMatchingEnabled: recordingRehearsalMatchingEnabled,
      demoJudgeMatchingEnabled: demoJudgeMatchingEnabled
    )
  }
}

#if DEBUG
enum DebugMatchesScenario: String, Sendable {
  case success
  case pending
  case empty
  case retry
  case loading

  static var requested: Self? {
    guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--wingward-matches-fixture"),
      ProcessInfo.processInfo.arguments.indices.contains(index + 1)
    else { return nil }
    return Self(rawValue: ProcessInfo.processInfo.arguments[index + 1])
  }
}

struct DebugMatchesAPIFactory: MatchesAPIFactory, Sendable {
  private let api: DebugMatchesAPI

  init(scenario: DebugMatchesScenario, recordingRehearsalFixtureEnabled: Bool = false) {
    api = DebugMatchesAPI(
      scenario: scenario,
      recordingRehearsalFixtureEnabled: recordingRehearsalFixtureEnabled && scenario == .empty
    )
  }

  func make(ownerID: String) -> (any MatchesAPI)? {
    guard ownerID == UserProfile.fixture.id else { return nil }
    return api
  }
}

private actor DebugMatchesAPI: MatchesAPI, RecordingRehearsalMatchingAPI {
  private let scenario: DebugMatchesScenario
  nonisolated let recordingRehearsalFixtureEnabled: Bool
  private var requestCount = 0
  private var recordingRehearsalStarted = false

  nonisolated var recordingRehearsalMatchingAPI: (any RecordingRehearsalMatchingAPI)? {
    recordingRehearsalFixtureEnabled ? self : nil
  }

  init(scenario: DebugMatchesScenario, recordingRehearsalFixtureEnabled: Bool) {
    self.scenario = scenario
    self.recordingRehearsalFixtureEnabled = recordingRehearsalFixtureEnabled
  }

  func fetchDailyResults() async throws -> DailyMatchesPayload {
    requestCount += 1
    switch scenario {
    case .success:
      if ProcessInfo.processInfo.arguments.contains(
        "--wingward-production-safety-reconciliation"
      ), requestCount > 1 {
        return Self.emptyPayload
      }
      return Self.successPayload
    case .pending:
      return Self.pendingPayload
    case .empty:
      if recordingRehearsalFixtureEnabled, recordingRehearsalStarted {
        return Self.successPayload
      }
      return Self.emptyPayload
    case .retry:
      if requestCount == 1 {
        throw APIClientError.temporarilyUnavailable
      }
      return Self.successPayload
    case .loading:
      try await Task.sleep(nanoseconds: 600_000_000_000)
      throw APIClientError.cancelled
    }
  }

  func previewRecordingRehearsal() async throws -> RecordingRehearsalPreviewResult {
    guard recordingRehearsalFixtureEnabled else { throw APIClientError.invalidState }
    return RecordingRehearsalPreviewResult(outcome: .eligible, count: 1)
  }

  func startRecordingRehearsal() async throws -> RecordingRehearsalStartResult {
    guard recordingRehearsalFixtureEnabled else { throw APIClientError.invalidState }
    recordingRehearsalStarted = true
    return RecordingRehearsalStartResult(outcome: .started, count: 1)
  }

  private static var successPayload: DailyMatchesPayload {
    let matches = [
      ProductionMatch(
        debugID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        partnerID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
        nickname: "Aoi",
        status: "fox_conversation_completed"
      ),
      ProductionMatch(
        debugID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        partnerID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
        nickname: "Mina",
        status: "fox_conversation_in_progress"
      )
    ]
    return DailyMatchesPayload(
      batchDate: "2026-09-07",
      batchStatus: "completed",
      matches: matches,
      isNew: true,
      conversationsCompleted: 1,
      conversationsFailed: 0,
      totalMatches: matches.count
    )
  }

  private static var emptyPayload: DailyMatchesPayload {
    DailyMatchesPayload(
      batchDate: "2026-09-07",
      batchStatus: "completed",
      matches: [],
      isNew: false,
      conversationsCompleted: 0,
      conversationsFailed: 0,
      totalMatches: 0
    )
  }

  private static var pendingPayload: DailyMatchesPayload {
    let matches = [
      ProductionMatch(
        debugID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        partnerID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
        nickname: "Aoi",
        status: "pending"
      ),
      ProductionMatch(
        debugID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        partnerID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
        nickname: "Mina",
        status: "fox_conversation_in_progress"
      )
    ]
    return DailyMatchesPayload(
      batchDate: "2026-09-07",
      batchStatus: "completed",
      matches: matches,
      isNew: true,
      conversationsCompleted: 0,
      conversationsFailed: 0,
      totalMatches: matches.count
    )
  }
}

fileprivate extension ProductionMatch {
  init(debugID: UUID, partnerID: UUID, nickname: String, status: String) {
    self.id = debugID
    self.partnerID = partnerID
    self.partner = Partner(nickname: nickname, avatarURL: nil, personaIconURL: nil)
    self.status = status
    self.foxConversationID = nil
  }
}
#endif
