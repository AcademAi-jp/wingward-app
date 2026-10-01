import Foundation
import Observation
import SwiftUI

/// The small, user-facing profile slice used by the own insight surface.
/// Unknown server fields are intentionally ignored so private or numeric
/// analysis data cannot cross into the feature.
struct OwnInsight: APIValidatable, Equatable, Identifiable, Sendable {
  static let maxTagCount = 24
  static let maxTagLength = 120
  static let maxSignatureLength = 4_000

  let id: UUID
  let userID: UUID
  let personalityTags: [String]
  let status: String
  let overallSignature: String?
  let bio: String?
  let latestConfirmedPersona: OwnConfirmedPersona?
  let latestConfirmedPersonaUnavailable: Bool
  let profileVersion: Int?
  let confirmedPreferences: [ChatMeetupReflectionTrait]?

  var currentPreferences: [ChatMeetupReflectionTrait] {
    confirmedPreferences ?? latestConfirmedPersona?.traits ?? []
  }

  var currentPreferenceChanges: OwnConfirmedPersona.Changes? {
    guard let latestConfirmedPersona,
      currentPreferences == latestConfirmedPersona.traits else { return nil }
    return latestConfirmedPersona.changes
  }

  private struct InteractionStyle: Decodable {
    let overallSignature: String?

    enum CodingKeys: String, CodingKey {
      case overallSignature = "overall_signature"
    }
  }

  private struct BasicInfo: Decodable { let bio: String? }

  private enum CodingKeys: String, CodingKey {
    case id
    case userID = "user_id"
    case personalityTags = "personality_tags"
    case status
    case basicInfo = "basic_info"
    case interactionStyle = "interaction_style"
    case latestConfirmedPersona = "latest_confirmed_persona"
    case latestConfirmedPersonaUnavailable = "latest_confirmed_persona_unavailable"
    case profileVersion = "version"
    case confirmedPreferences = "confirmed_preferences"
  }

  init(
    id: UUID,
    userID: UUID,
    personalityTags: [String],
    status: String,
    overallSignature: String?,
    latestConfirmedPersona: OwnConfirmedPersona? = nil,
    latestConfirmedPersonaUnavailable: Bool = false,
    profileVersion: Int? = nil,
    confirmedPreferences: [ChatMeetupReflectionTrait]? = nil,
    bio: String? = nil
  ) {
    self.id = id
    self.userID = userID
    self.personalityTags = personalityTags
    self.status = status
    self.overallSignature = overallSignature
    self.bio = bio
    self.latestConfirmedPersona = latestConfirmedPersona
    self.latestConfirmedPersonaUnavailable = latestConfirmedPersonaUnavailable
    self.profileVersion = profileVersion
    self.confirmedPreferences = confirmedPreferences
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try APIDTOValidation.requireUUID(container.decode(String.self, forKey: .id))
    let userID = try APIDTOValidation.requireUUID(
      container.decode(String.self, forKey: .userID)
    )
    let tags = try container.decodeIfPresent([String].self, forKey: .personalityTags) ?? []
    let status = try container.decode(String.self, forKey: .status)
    let interactionStyle = try container.decodeIfPresent(
      InteractionStyle.self,
      forKey: .interactionStyle
    )
    var personaUnavailable = try container.decodeIfPresent(
      Bool.self, forKey: .latestConfirmedPersonaUnavailable
    ) ?? false
    let persona: OwnConfirmedPersona?
    do {
      persona = try container.decodeIfPresent(OwnConfirmedPersona.self, forKey: .latestConfirmedPersona)
    } catch {
      // A bad optional overlay must not hide the owner's existing profile.
      persona = nil
      personaUnavailable = true
    }
    let preferences: [ChatMeetupReflectionTrait]?
    if let raw = try container.decodeIfPresent([String: String].self, forKey: .confirmedPreferences) {
      preferences = try raw.map { key, value in
        guard let key = ChatMeetupReflectionTraitKey(rawValue: key),
          let value = ChatMeetupReflectionTraitValue(rawValue: value) else {
          throw ChatsDTOValidationError.invalidValue
        }
        let trait = ChatMeetupReflectionTrait(key: key, value: value)
        try ChatMeetupReflectionTrait.validate(trait)
        return trait
      }.sorted { $0.key.rawValue < $1.key.rawValue }
    } else {
      preferences = nil
    }

    self.init(
      id: id,
      userID: userID,
      personalityTags: tags,
      status: status,
      overallSignature: interactionStyle?.overallSignature,
      latestConfirmedPersona: personaUnavailable ? nil : persona,
      latestConfirmedPersonaUnavailable: personaUnavailable,
      profileVersion: try container.decodeIfPresent(Int.self, forKey: .profileVersion),
      confirmedPreferences: preferences,
      bio: try container.decodeIfPresent(BasicInfo.self, forKey: .basicInfo)?.bio
    )
    try Self.validate(self)
  }

  static func validate(_ value: OwnInsight) throws {
    guard value.personalityTags.count <= maxTagCount else {
      throw OwnInsightValidationError.tooManyTags
    }
    for tag in value.personalityTags {
      try APIDTOValidation.requireNonEmpty(tag)
      guard tag.count <= maxTagLength else {
        throw OwnInsightValidationError.tagTooLong
      }
    }

    try APIDTOValidation.requireNonEmpty(value.status)
    guard value.status.count <= 80 else {
      throw OwnInsightValidationError.statusTooLong
    }

    if let bio = value.bio, bio.count > 1_000 { throw OwnInsightValidationError.signatureTooLong }
    if let signature = value.overallSignature {
      guard signature.count <= maxSignatureLength else {
        throw OwnInsightValidationError.signatureTooLong
      }
    }
  }
}

/// Preferences the owner explicitly confirmed after a meetup. Free text and
/// unknown trait values never enter this optional profile overlay.
struct OwnConfirmedPersona: Decodable, Equatable, Sendable {
  let version: Int
  let traits: [ChatMeetupReflectionTrait]
  let confirmedAt: Date
  let changes: Changes?
  let changesUnavailable: Bool

  struct Changes: Decodable, Equatable, Sendable {
    let comparedToVersion: Int?
    let addedKeys: [ChatMeetupReflectionTraitKey]
    let changedKeys: [ChatMeetupReflectionTraitKey]

    enum CodingKeys: String, CodingKey {
      case comparedToVersion = "compared_to_version"
      case addedKeys = "added_keys"
      case changedKeys = "changed_keys"
    }
  }

  private enum CodingKeys: String, CodingKey {
    case version, traits
    case confirmedAt = "confirmed_at"
    case changes
    case changesUnavailable = "changes_unavailable"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    guard (1...2_000_000_000).contains(version) else { throw ChatsDTOValidationError.invalidValue }
    confirmedAt = try APIDTOValidation.requireRFC3339(container.decode(String.self, forKey: .confirmedAt))
    let raw = try container.decode([String: String].self, forKey: .traits)
    guard !raw.isEmpty, raw.count <= ChatMeetupReflectionTraitKey.allCases.count else {
      throw ChatsDTOValidationError.invalidValue
    }
    traits = try raw.map { rawKey, rawValue in
      guard let key = ChatMeetupReflectionTraitKey(rawValue: rawKey),
        let value = ChatMeetupReflectionTraitValue(rawValue: rawValue)
      else { throw ChatsDTOValidationError.invalidValue }
      let trait = ChatMeetupReflectionTrait(key: key, value: value)
      try ChatMeetupReflectionTrait.validate(trait)
      return trait
    }.sorted { $0.key.rawValue < $1.key.rawValue }
    var unavailable = (try? container.decodeIfPresent(Bool.self, forKey: .changesUnavailable)) ?? false
    var decodedChanges = try? container.decodeIfPresent(Changes.self, forKey: .changes)
    if let change = decodedChanges {
      let added = Set(change.addedKeys), changed = Set(change.changedKeys), keys = Set(traits.map(\.key))
      let validComparison = version == 1
        ? change.comparedToVersion == nil && added == keys && changed.isEmpty
        : change.comparedToVersion == version - 1
      if !validComparison || added.count != change.addedKeys.count || changed.count != change.changedKeys.count
        || !added.isDisjoint(with: changed) || !added.union(changed).isSubset(of: keys) {
        unavailable = true
        decodedChanges = nil
      }
    } else if container.contains(.changes), (try? container.decodeNil(forKey: .changes)) != true {
      unavailable = true
    }
    changes = unavailable ? nil : decodedChanges
    changesUnavailable = unavailable
  }
}

private enum OwnInsightValidationError: Error, Equatable, Sendable {
  case tooManyTags
  case tagTooLong
  case statusTooLong
  case signatureTooLong
}

protocol ConversationInsightAPI: Sendable {
  func updateDraftProfile(tags: [String], bio: String) async throws -> OwnInsight
  func fetchInsight() async throws -> OwnInsight
}

extension ConversationInsightAPI {
  func updateDraftProfile(tags: [String], bio: String) async throws -> OwnInsight { throw APIClientError.invalidState }
}

struct LiveConversationInsightAPI: ConversationInsightAPI, Sendable {
  static let profilePath = "/api/profiles/me"

  let client: any AuthenticatedAPIClientProtocol

  init(client: any AuthenticatedAPIClientProtocol) {
    self.client = client
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
    let client = try AuthenticatedAPIClient(
      baseURL: baseURL,
      tokenProvider: provider,
      transport: transport
    )
    self.init(client: client)
  }

  func updateDraftProfile(tags: [String], bio: String) async throws -> OwnInsight {
    guard (3...5).contains(tags.count), Set(tags).count == tags.count, tags.allSatisfy({
      !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) && $0.count <= 100
    }), bio.count <= 1_000 else { throw APIClientError.invalidRequest }
    struct Body: Encodable { let personality_tags: [String]; let basic_info: BasicInfo }
    struct BasicInfo: Encodable { let bio: String }
    let request = try APIRequest.json(method: .put, path: Self.profilePath,
      body: Body(personality_tags: tags, basic_info: BasicInfo(bio: bio)))
    let value = try await client.send(request, as: OwnInsight.self)
    guard value.status == "draft" else { throw APIClientError.invalidResponse }
    return value
  }

  func fetchInsight() async throws -> OwnInsight {
    try await client.get(Self.profilePath, as: OwnInsight.self)
  }
}

protocol ConversationInsightAPIFactory: Sendable {
  func make(ownerID: String) -> (any ConversationInsightAPI)?
}

struct LiveConversationInsightAPIFactory: ConversationInsightAPIFactory, Sendable {
  let baseURL: URL
  let authService: any AuthService
  let profileAPI: any ProfileAPI
  let transport: any APIHTTPTransport

  init(
    baseURL: URL,
    authService: any AuthService,
    profileAPI: any ProfileAPI,
    transport: any APIHTTPTransport = URLSession(configuration: .ephemeral)
  ) {
    self.baseURL = baseURL
    self.authService = authService
    self.profileAPI = profileAPI
    self.transport = transport
  }

  func make(ownerID: String) -> (any ConversationInsightAPI)? {
    try? LiveConversationInsightAPI(
      baseURL: baseURL,
      ownerID: ownerID,
      authService: authService,
      profileAPI: profileAPI,
      transport: transport
    )
  }
}

#if DEBUG
/// A local-only fixture factory. It accepts UUID owners so the same owner
/// binding used by the live store remains exercised in previews.
struct DebugConversationInsightAPIFactory: ConversationInsightAPIFactory, Sendable {
  private let scenario: DebugMatchesScenario

  init(scenario: DebugMatchesScenario) {
    self.scenario = scenario
  }

  func make(ownerID: String) -> (any ConversationInsightAPI)? {
    guard let ownerUUID = UUID(uuidString: ownerID) else { return nil }
    return DebugConversationInsightAPI(scenario: scenario, ownerID: ownerUUID)
  }
}

private actor DebugConversationInsightAPI: ConversationInsightAPI {
  private let scenario: DebugMatchesScenario
  private let ownerID: UUID
  private var requestCount = 0

  init(scenario: DebugMatchesScenario, ownerID: UUID) {
    self.scenario = scenario
    self.ownerID = ownerID
  }

  func fetchInsight() async throws -> OwnInsight {
    requestCount += 1
    switch scenario {
    case .retry where requestCount == 1:
      throw APIClientError.temporarilyUnavailable
    case .loading:
      try await Task.sleep(nanoseconds: 600_000_000_000)
      throw APIClientError.cancelled
    case .empty:
      return OwnInsight(
        id: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
        userID: ownerID,
        personalityTags: [],
        status: "draft",
        overallSignature: nil
      )
    default:
      return OwnInsight(
        id: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
        userID: ownerID,
        personalityTags: ["Listens carefully", "Builds trust slowly"],
        status: "ready",
        overallSignature: "A saved conversation signature."
      )
    }
  }
}
#endif

enum ConversationInsightStoreError: Error, Equatable, Sendable {
  case unauthenticated
  case ageVerificationRequired
  case forbidden
  case notFound
  case ownerMismatch
  case invalidResponse
  case invalidState
  case rateLimited
  case temporarilyUnavailable
  case cancelled

  var userMessage: String {
    switch self {
    case .ageVerificationRequired:
      return "Verify your age before viewing your conversation insight."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .unauthenticated, .forbidden, .notFound, .ownerMismatch, .invalidResponse,
      .invalidState, .temporarilyUnavailable, .cancelled:
      return "We couldn't load your conversation insight. Try again."
    }
  }
}

enum ConversationInsightStorePhase: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case failed(ConversationInsightStoreError)
}

@MainActor
@Observable
final class ConversationInsightStore {
  private(set) var ownerID: String
  private(set) var phase: ConversationInsightStorePhase = .idle
  private(set) var insight: OwnInsight?

  private let api: any ConversationInsightAPI
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  private var generation = 0

  init(ownerID: String, api: any ConversationInsightAPI) {
    self.ownerID = ownerID
    self.api = api
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    invalidateLoad()
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    clearProtectedContent()
    phase = .loading

    let task = Task { [weak self] in
      guard let self else { return }
      await self.performLoad(ownerID: capturedOwnerID, generation: capturedGeneration)
    }
    loadTask = task
    return task
  }

  @discardableResult
  func retry() -> Task<Void, Never> {
    load()
  }

  func cancel() {
    invalidateLoad()
    clearProtectedContent()
    phase = .idle
  }

  func updateOwner(_ newOwnerID: String) {
    guard ownerID != newOwnerID else { return }
    cancel()
    ownerID = newOwnerID
  }

  private func clearProtectedContent() {
    insight = nil
  }

  private func invalidateLoad() {
    loadTask?.cancel()
    loadTask = nil
    generation &+= 1
  }

  private func isCurrent(ownerID: String, generation: Int) -> Bool {
    !Task.isCancelled && self.ownerID == ownerID && self.generation == generation
  }

  private func performLoad(ownerID: String, generation: Int) async {
    do {
      let fetchedInsight = try await api.fetchInsight()
      try OwnInsight.validate(fetchedInsight)
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      guard fetchedInsight.userID.uuidString.caseInsensitiveCompare(ownerID) == .orderedSame else {
        throw ConversationInsightStoreError.ownerMismatch
      }

      insight = fetchedInsight
      phase = .loaded
      loadTask = nil
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      clearProtectedContent()
      let mapped = Self.map(error)
      phase = mapped == .cancelled ? .idle : .failed(mapped)
      loadTask = nil
    }
  }

  private static func map(_ error: Error) -> ConversationInsightStoreError {
    if let storeError = error as? ConversationInsightStoreError {
      return storeError
    }
    if error is APIDTOValidationError || error is OwnInsightValidationError {
      return .invalidResponse
    }
    guard let clientError = error as? APIClientError else {
      return .temporarilyUnavailable
    }
    switch clientError {
    case .unauthenticated: return .unauthenticated
    case .ageVerificationRequired: return .ageVerificationRequired
    case .forbidden: return .forbidden
    case .notFound: return .notFound
    case .invalidResponse, .invalidRequest, .invalidURL: return .invalidResponse
    case .invalidState: return .invalidState
    case .rateLimited: return .rateLimited
    case .cancelled: return .cancelled
    case .transportFailure, .temporarilyUnavailable, .quotaExhausted:
      return .temporarilyUnavailable
    }
  }
}

struct ConversationInsightView: View {
  let ownerID: String
  let api: any ConversationInsightAPI

  @State private var store: ConversationInsightStore
  @State private var isReportPresented = false

  init(ownerID: String, api: any ConversationInsightAPI) {
    self.ownerID = ownerID
    self.api = api
    _store = State(initialValue: ConversationInsightStore(ownerID: ownerID, api: api))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ReferencePalette.cream)
    .task(id: ownerID) {
      await store.load().value
    }
    .onDisappear {
      store.cancel()
    }
    .sheet(isPresented: $isReportPresented) {
      if let insight = store.insight {
        ConversationInsightReportSheet(insight: insight)
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch store.phase {
    case .idle:
      ConversationInsightLoadingCard()
    case .loading:
      ConversationInsightLoadingCard()
    case .loaded:
      if let insight = store.insight {
        ConversationInsightCard(insight: insight) {
          isReportPresented = true
        }
      } else {
        ConversationInsightEmptyCard()
      }
    case let .failed(error):
      ConversationInsightErrorCard(error: error) {
        _ = store.retry()
      }
    }
  }
}

private struct ConversationInsightCard: View {
  let insight: OwnInsight
  let onReadReport: () -> Void

  private var savedSignature: String? {
    guard let signature = insight.overallSignature,
      !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return signature
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 16) {
        ReferenceAvatar(dimension: 68)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          Text("YOUR CONVERSATION INSIGHT")
            .font(.caption2.weight(.bold))
            .tracking(1.5)
            .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
          if let savedSignature {
            Text(savedSignature)
              .font(.title3.weight(.bold))
              .foregroundStyle(ReferencePalette.ink)
              .lineLimit(3)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            Text("Your conversation insight is taking shape.")
              .font(.title3.weight(.bold))
              .foregroundStyle(ReferencePalette.ink)
          }
          if savedSignature == nil {
            Text("Your saved insight will appear here as more conversation data becomes available.")
              .font(.subheadline)
              .foregroundStyle(ReferencePalette.muted)
              .lineSpacing(4)
          }
        }
      }
      .padding(.bottom, 2)
      .overlay(alignment: .bottom) {
        Rectangle().fill(ReferencePalette.line).frame(height: 1)
      }

      if insight.personalityTags.isEmpty {
        Text("No saved tags yet.")
          .font(.subheadline)
          .foregroundStyle(ReferencePalette.muted)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(Array(insight.personalityTags.enumerated()), id: \.offset) { _, tag in
              ReferenceTag(text: tag)
            }
          }
        }
      }

      if savedSignature != nil || !insight.personalityTags.isEmpty {
        Button("Read saved insight", action: onReadReport)
          .buttonStyle(.plain)
          .font(.subheadline.weight(.semibold))
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
          .accessibilityIdentifier("conversationInsight.readReport")
      }
    }
    .padding(24)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .stroke(ReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("conversationInsight.card")
  }
}

private struct ConversationInsightLoadingCard: View {
  var body: some View {
    VStack(spacing: 14) {
      ProgressView()
        .tint(ReferencePalette.ink)
      Text("Loading your conversation insight…")
        .font(.subheadline)
        .foregroundStyle(ReferencePalette.muted)
    }
    .frame(maxWidth: .infinity, minHeight: 180)
    .background(.white)
    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("conversationInsight.loading")
  }
}

private struct ConversationInsightEmptyCard: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("YOUR CONVERSATION INSIGHT")
        .font(.caption2.weight(.bold))
        .tracking(1.5)
        .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
      Text("Your insight is not ready yet.")
        .font(.title3.weight(.bold))
      Text("Keep having conversations and your saved insight will appear here.")
        .font(.subheadline)
        .foregroundStyle(ReferencePalette.muted)
        .lineSpacing(4)
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .stroke(ReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
  }
}

private struct ConversationInsightErrorCard: View {
  let error: ConversationInsightStoreError
  let onRetry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Conversation insight", systemImage: "exclamationmark.circle")
        .font(.headline.weight(.semibold))
      Text(error.userMessage)
        .font(.subheadline)
        .foregroundStyle(ReferencePalette.muted)
        .lineSpacing(4)
      Button("Try again", action: onRetry)
        .buttonStyle(ReferenceOutlineButtonStyle())
        .accessibilityIdentifier("conversationInsight.retry")
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .stroke(ReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
  }
}

private struct ConversationInsightReportSheet: View {
  let insight: OwnInsight
  @Environment(\.dismiss) private var dismiss

  private var savedSignature: String? {
    guard let signature = insight.overallSignature,
      !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return signature
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          Text("YOUR CONVERSATION INSIGHT")
            .font(.caption.weight(.bold))
            .tracking(2)
            .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))

          if let savedSignature {
            Text(savedSignature)
              .font(.title2.weight(.bold))
              .foregroundStyle(ReferencePalette.ink)
              .fixedSize(horizontal: false, vertical: true)
          }

          if insight.personalityTags.isEmpty && savedSignature == nil {
            Text("No saved insight text or tags are available yet.")
              .font(.body)
              .foregroundStyle(ReferencePalette.muted)
              .lineSpacing(5)
          } else if !insight.personalityTags.isEmpty {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 105), spacing: 8)],
              alignment: .leading,
              spacing: 8
            ) {
              ForEach(Array(insight.personalityTags.enumerated()), id: \.offset) { _, tag in
                ReferenceTag(text: tag)
              }
            }
          }
        }
        .padding(20)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
      }
      .background(ReferencePalette.cream)
      .navigationTitle("Saved insight")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}
