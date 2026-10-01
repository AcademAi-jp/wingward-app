import Combine
import Foundation

/// The seven screens in the local SwiftUI port of the Web speed-dating reference.
/// This route model is intentionally separate from the production app route.
public enum ReferenceJourneyScreen: String, CaseIterable, Hashable, Identifiable, Sendable {
  case login
  case setupProfile = "setup-profile"
  case setupQuiz = "setup-quiz"
  case wardIntro = "ward-intro"
  case insight
  case home
  case chat

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .login: return "ログイン"
    case .setupProfile: return "プロフィール設定"
    case .setupQuiz: return "関係のペース"
    case .wardIntro: return "Wardとの会話"
    case .insight: return "対話のインサイト"
    case .home: return "ホーム"
    case .chat: return "トーク"
    }
  }
}

/// These values deliberately keep nonbinary and prefer-not-to-say distinct.
/// They are only local display choices and are not the production onboarding contract.
public enum ReferenceProfileGender: String, CaseIterable, Hashable, Identifiable, Sendable {
  case woman
  case man
  case nonbinary
  case preferNotToSay

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .woman: return "女性"
    case .man: return "男性"
    case .nonbinary: return "ノンバイナリー"
    case .preferNotToSay: return "回答しない"
    }
  }
}

public enum ReferenceQuizPace: String, CaseIterable, Hashable, Identifiable, Sendable {
  case slow
  case quick

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .slow: return "ゆっくり話したい"
    case .quick: return "テンポよく話したい"
    }
  }
}

public enum ReferenceQuizWeekend: String, CaseIterable, Hashable, Identifiable, Sendable {
  case outside
  case both

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .outside: return "外へ出かけたい"
    case .both: return "家でも外でも"
    }
  }
}

public enum ReferenceVoicePhase: String, CaseIterable, Hashable, Identifiable, Sendable {
  case ready
  case speaking
  case listening
  case complete

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .ready: return "準備ができました"
    case .speaking: return "Wardが話しています"
    case .listening: return "あなたの声を聞いています"
    case .complete: return "会話が完了しました"
    }
  }
}

public enum ReferenceChatMode: String, CaseIterable, Hashable, Identifiable, Sendable {
  case ward
  case person

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .ward: return "Ward"
    case .person: return "自分"
    }
  }
}

public enum ReferenceMessageSide: String, Hashable, Sendable {
  case mine
  case theirs
}

public struct ReferenceCandidateReason: Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let detail: String

  public init(id: String, label: String, detail: String) {
    self.id = id
    self.label = label
    self.detail = detail
  }
}

/// Candidate data intentionally contains display fields only. Owner settings and privacy
/// choices stay outside this shape so a future API response cannot accidentally mix them.
public struct ReferenceCandidate: Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let age: Int
  public let imageName: String
  public let match: Int
  public let location: String
  public let summary: String
  public let signature: String
  public let reasons: [ReferenceCandidateReason]

  public init(
    id: String,
    name: String,
    age: Int,
    imageName: String,
    match: Int,
    location: String,
    summary: String,
    signature: String,
    reasons: [ReferenceCandidateReason]
  ) {
    self.id = id
    self.name = name
    self.age = age
    self.imageName = imageName
    self.match = match
    self.location = location
    self.summary = summary
    self.signature = signature
    self.reasons = reasons
  }
}

public struct ReferenceWardSession: Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let caption: String

  public init(id: String, name: String, caption: String) {
    self.id = id
    self.name = name
    self.caption = caption
  }
}

public struct ReferenceChatMessage: Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let side: ReferenceMessageSide
  public let actor: String
  public let text: String
  public let time: String

  public init(id: String, side: ReferenceMessageSide, actor: String, text: String, time: String) {
    self.id = id
    self.side = side
    self.actor = actor
    self.text = text
    self.time = time
  }
}

public struct ReferenceInsightSection: Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let body: String

  public init(id: String, title: String, body: String) {
    self.id = id
    self.title = title
    self.body = body
  }
}

public enum ReferencePreferenceMode: String, Equatable, Hashable, Sendable {
  case selected
  case noAnswer
}

public enum ReferenceLocationMode: String, Equatable, Hashable, Sendable {
  case station
  case notSet
}

public struct ReferenceLocationOption: Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let areaID: String?

  public init(id: String, title: String, areaID: String? = nil) {
    self.id = id
    self.title = title
    self.areaID = areaID
  }
}

public struct ReferenceProfileDraft: Equatable, Sendable {
  public var name: String
  public var birthYear: String
  public var gender: ReferenceProfileGender
  public var preferenceMode: ReferencePreferenceMode
  public var preferredGenders: [ReferenceProfileGender]
  public var locationMode: ReferenceLocationMode
  public var stationID: String?
  public var broadAreaID: String?

  public static let empty = ReferenceProfileDraft(name: "", birthYear: "", gender: .preferNotToSay)

  public init(
    name: String,
    birthYear: String,
    gender: ReferenceProfileGender,
    preferenceMode: ReferencePreferenceMode = .noAnswer,
    preferredGenders: [ReferenceProfileGender] = [],
    locationMode: ReferenceLocationMode = .notSet,
    stationID: String? = nil,
    broadAreaID: String? = nil
  ) {
    self.name = name
    self.birthYear = birthYear
    self.gender = gender
    self.preferenceMode = preferenceMode
    self.preferredGenders = preferredGenders
    self.locationMode = locationMode
    self.stationID = stationID
    self.broadAreaID = broadAreaID
  }

  public var isReadyForContinue: Bool {
    let hasPreference = preferenceMode == .noAnswer || !preferredGenders.isEmpty
    let hasLocation = locationMode == .notSet || (stationID != nil && broadAreaID != nil)
    return hasPreference && hasLocation
  }

  public mutating func setPreferenceMode(_ mode: ReferencePreferenceMode) {
    preferenceMode = mode
    if mode == .noAnswer {
      preferredGenders.removeAll()
    }
  }

  public mutating func togglePreferredGender(_ gender: ReferenceProfileGender) {
    guard gender != .preferNotToSay else { return }
    preferenceMode = .selected
    if let index = preferredGenders.firstIndex(of: gender) {
      preferredGenders.remove(at: index)
    } else if preferredGenders.count < 3 {
      preferredGenders.append(gender)
    }
  }

  public mutating func setLocationMode(_ mode: ReferenceLocationMode) {
    locationMode = mode
    if mode == .notSet {
      stationID = nil
      broadAreaID = nil
    }
  }

  public mutating func selectStation(_ option: ReferenceLocationOption?) {
    locationMode = .station
    stationID = option?.id
    broadAreaID = option?.areaID
  }
}

public struct ReferenceJourneyData: Equatable, Sendable {
  public let candidates: [ReferenceCandidate]
  public let wardSessions: [ReferenceWardSession]
  public let wardMessagesByCandidate: [String: [ReferenceChatMessage]]
  public let personMessagesByCandidate: [String: [ReferenceChatMessage]]
  public let selfImageName: String
  public let insightTags: [String]
  public let insightSections: [ReferenceInsightSection]

  public init(
    candidates: [ReferenceCandidate],
    wardSessions: [ReferenceWardSession],
    wardMessagesByCandidate: [String: [ReferenceChatMessage]],
    personMessagesByCandidate: [String: [ReferenceChatMessage]],
    selfImageName: String,
    insightTags: [String],
    insightSections: [ReferenceInsightSection]
  ) {
    self.candidates = candidates
    self.wardSessions = wardSessions
    self.wardMessagesByCandidate = wardMessagesByCandidate
    self.personMessagesByCandidate = personMessagesByCandidate
    self.selfImageName = selfImageName
    self.insightTags = insightTags
    self.insightSections = insightSections
  }

  public func wardMessages(for candidateID: String) -> [ReferenceChatMessage] {
    wardMessagesByCandidate[candidateID] ?? []
  }

  public func personMessages(for candidateID: String) -> [ReferenceChatMessage] {
    personMessagesByCandidate[candidateID] ?? []
  }
}

public enum ReferenceJourneyAction: Equatable, Sendable {
  case openedPreview
  case selectedCandidate(id: String)
  case attemptedVoice
  case attemptedMessage(candidateID: String, text: String)
  case retryRequested
}

/// Side effects are explicit and injectable. The fixture supplies a no-op handler; a future
/// production adapter can observe these actions without changing the view composition.
public struct ReferenceJourneyActions {
  private let handler: @Sendable (ReferenceJourneyAction) -> Void

  public init(handler: @escaping @Sendable (ReferenceJourneyAction) -> Void = { _ in }) {
    self.handler = handler
  }

  public func emit(_ action: ReferenceJourneyAction) {
    handler(action)
  }
}

public enum ReferenceSurfaceState: Equatable, Hashable, Identifiable, Sendable {
  case loaded
  case loading
  case empty
  case error(message: String)
  case unavailable(message: String)
  case microphoneDenied
  case reconnecting

  public var id: String {
    switch self {
    case .loaded: return "loaded"
    case .loading: return "loading"
    case .empty: return "empty"
    case .error: return "error"
    case .unavailable: return "unavailable"
    case .microphoneDenied: return "microphone-denied"
    case .reconnecting: return "reconnecting"
    }
  }

  public var title: String {
    switch self {
    case .loaded: return "表示中"
    case .loading: return "読み込み中"
    case .empty: return "まだ表示できるものがありません"
    case .error: return "読み込みに失敗しました"
    case .unavailable: return "この機能は未接続です"
    case .microphoneDenied: return "マイクを使えません"
    case .reconnecting: return "再接続を待機しています"
    }
  }

  public var message: String {
    switch self {
    case .loaded: return ""
    case .loading: return "プレビューの状態を準備しています。"
    case .empty: return "この状態ではサンプルデータを表示しません。"
    case let .error(message), let .unavailable(message): return message
    case .microphoneDenied: return "このプレビューはマイクを起動しません。"
    case .reconnecting: return "接続先が用意されるまで、入力内容はこの画面に保持されます。"
    }
  }
}

public enum ReferencePreviewStateOption: String, CaseIterable, Hashable, Identifiable, Sendable {
  case loaded
  case loading
  case empty
  case error
  case unavailable
  case microphoneDenied
  case reconnecting

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .loaded: return "通常表示"
    case .loading: return "読み込み中"
    case .empty: return "空"
    case .error: return "エラー"
    case .unavailable: return "未接続"
    case .microphoneDenied: return "マイク拒否"
    case .reconnecting: return "再接続中"
    }
  }

  public var state: ReferenceSurfaceState {
    switch self {
    case .loaded: return .loaded
    case .loading: return .loading
    case .empty: return .empty
    case .error: return .error(message: "データを読み込めませんでした。")
    case .unavailable: return .unavailable(message: "この機能はまだ接続されていません。")
    case .microphoneDenied: return .microphoneDenied
    case .reconnecting: return .reconnecting
    }
  }
}

@MainActor
public final class ReferenceJourneyModel: ObservableObject {
  public let data: ReferenceJourneyData
  public let actions: ReferenceJourneyActions
  private let initialProfileDraft: ReferenceProfileDraft
  private var draftsByCandidate: [String: String] = [:]

  @Published public private(set) var screen: ReferenceJourneyScreen = .login
  @Published public private(set) var profileDraft: ReferenceProfileDraft
  @Published public private(set) var selectedPace: ReferenceQuizPace = .slow
  @Published public private(set) var selectedWeekend: ReferenceQuizWeekend = .both
  @Published public private(set) var wardStep = 0
  @Published public private(set) var voicePhase: ReferenceVoicePhase = .ready
  @Published public private(set) var activeCandidate: ReferenceCandidate?
  @Published public var selectedCandidate: ReferenceCandidate?
  @Published public private(set) var chatMode: ReferenceChatMode = .ward
  @Published public var draft = ""
  @Published public private(set) var surfaceState: ReferenceSurfaceState = .loaded

  public init(
    data: ReferenceJourneyData,
    actions: ReferenceJourneyActions = ReferenceJourneyActions(),
    initialProfileDraft: ReferenceProfileDraft = .empty
  ) {
    self.data = data
    self.actions = actions
    self.initialProfileDraft = initialProfileDraft
    self.profileDraft = initialProfileDraft
    self.activeCandidate = data.candidates.first
  }

  public var routeOrder: [ReferenceJourneyScreen] { ReferenceJourneyScreen.allCases }

  public func navigate(to destination: ReferenceJourneyScreen) {
    screen = destination
    if destination != .chat {
      selectedCandidate = nil
    }
  }

  public func continueFromLogin() {
    actions.emit(.openedPreview)
    screen = .setupProfile
  }

  public func continueFromProfile() {
    screen = .setupQuiz
  }

  public func continueFromQuiz() {
    wardStep = 0
    voicePhase = .ready
    screen = .wardIntro
  }

  public func setProfile(_ draft: ReferenceProfileDraft) {
    profileDraft = draft
  }

  public func setProfileGender(_ gender: ReferenceProfileGender) {
    profileDraft.gender = gender
  }

  public func setPace(_ pace: ReferenceQuizPace) {
    selectedPace = pace
  }

  public func setWeekend(_ weekend: ReferenceQuizWeekend) {
    selectedWeekend = weekend
  }

  public func setVoicePhase(_ phase: ReferenceVoicePhase) {
    voicePhase = phase
  }

  public func requestMicrophone() {
    actions.emit(.attemptedVoice)
    surfaceState = .unavailable(message: "マイク機能はまだ接続されていません。このプレビューはマイクを起動しません。")
  }

  public func continueWardPreview() {
    guard !data.wardSessions.isEmpty else {
      surfaceState = .empty
      return
    }
    if wardStep < data.wardSessions.count - 1 {
      wardStep += 1
      voicePhase = .ready
    } else {
      screen = .insight
    }
  }

  public func retreatWardPreview() {
    if wardStep > 0 {
      wardStep -= 1
      voicePhase = .ready
    } else {
      screen = .setupQuiz
    }
  }

  public func selectCandidate(_ candidate: ReferenceCandidate) {
    guard data.candidates.contains(candidate) else { return }
    selectedCandidate = candidate
    actions.emit(.selectedCandidate(id: candidate.id))
  }

  public func openChat(with candidate: ReferenceCandidate) {
    guard data.candidates.contains(candidate) else { return }
    if let previousCandidate = activeCandidate {
      draftsByCandidate[previousCandidate.id] = draft
    }
    activeCandidate = candidate
    chatMode = .ward
    selectedCandidate = nil
    draft = draftsByCandidate[candidate.id] ?? ""
    screen = .chat
  }

  public func setChatMode(_ mode: ReferenceChatMode) {
    chatMode = mode
  }

  public func setDraft(_ draft: String) {
    self.draft = draft
    if let activeCandidate {
      draftsByCandidate[activeCandidate.id] = draft
    }
  }

  public func attemptSend() {
    guard chatMode == .person else { return }
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let activeCandidate else { return }
    actions.emit(.attemptedMessage(candidateID: activeCandidate.id, text: trimmed))
    surfaceState = .unavailable(message: "送信機能はまだ接続されていません。下書きは保持されています。")
  }

  public func setPreviewState(_ option: ReferencePreviewStateOption) {
    surfaceState = option.state
  }

  public func retrySurface() {
    actions.emit(.retryRequested)
    surfaceState = .reconnecting
  }

  public func resetSurfaceState() {
    surfaceState = .loaded
  }

  public func reset() {
    screen = .login
    profileDraft = initialProfileDraft
    selectedPace = .slow
    selectedWeekend = .both
    wardStep = 0
    voicePhase = .ready
    activeCandidate = data.candidates.first
    selectedCandidate = nil
    chatMode = .ward
    draft = ""
    draftsByCandidate = [:]
    surfaceState = .loaded
  }
}
