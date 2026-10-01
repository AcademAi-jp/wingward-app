import Foundation
import Observation
import SwiftUI

/// The unified Partner Ward screen starts in the private Ward view. Human
/// messages are a separate mode, but the server remains the only authority
/// for whether that mode can send.
enum BilingualProductionPartnerConversationMode: String, CaseIterable, Equatable, Sendable {
  case ward
  case you
}

enum BilingualProductionChatRequestState: String, Equatable, Sendable {
  case none
  case outgoingPending
  case incomingPending
  case accepted
  case declined
  case expired
}

func bilingualProductionActiveDirectChat(
  for matchID: UUID,
  in chats: [DirectChatSummary]
) -> DirectChatSummary? {
  chats.first { $0.matchID == matchID && $0.status == "active" }
}

func bilingualProductionChatRequestState(
  for request: ChatRequestMatchState?,
  ownerID: String,
  matchID: UUID
) -> BilingualProductionChatRequestState {
  guard let request,
    request.matchID == matchID,
    let ownerUUID = UUID(uuidString: ownerID)
  else {
    return .none
  }
  guard request.requesterID == ownerUUID || request.responderID == ownerUUID else {
    return .none
  }
  switch request.status {
  case .pending:
    return request.requesterID == ownerUUID ? .outgoingPending : .incomingPending
  case .accepted:
    return .accepted
  case .declined:
    return .declined
  case .expired:
    return .expired
  }
}

func bilingualProductionHumanComposerIsEnabled(
  mode: BilingualProductionPartnerConversationMode,
  activeChat: DirectChatSummary?,
  matchID: UUID,
  storeCanSend: Bool
) -> Bool {
  mode == .you
    && storeCanSend
    && activeChat?.matchID == matchID
    && activeChat?.status == "active"
}

func bilingualProductionPartnerAnalysisSummary(
  _ summary: String?,
  language: BilingualReferenceLanguage
) -> String? {
  guard let summary else { return nil }
  let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  guard language == .japanese,
    trimmed == "Both Wards value calm, thoughtful conversations."
  else {
    return trimmed
  }
  return "どちらのWardも、落ち着いて丁寧に話すことを大切にしています。"
}

/// The authenticated product surface uses the approved bilingual visual system
/// while keeping all live APIs and stores owner-bound. Synthetic data is never
/// used as a fallback here; the DEBUG-only ReferenceJourney remains separate.
struct BilingualProductionAuthenticatedView: View {
  let controller: AuthSessionController
  let profile: UserProfile
  let onboardingAPIFactory: (any OnboardingSettingsAPIFactory)?
  let matchesAPIFactory: (any MatchesAPIFactory)?
  let matchDetailAPIFactory: (any MatchDetailAPIFactory)?
  let conversationInsightAPIFactory: (any ConversationInsightAPIFactory)?
  let quizAPIFactory: (any QuizAPIFactory)?
  let nativeIntegration: NativeFeatureIntegration
  let language: BilingualReferenceLanguage
  let onLanguageChange: (BilingualReferenceLanguage) -> Void
  let isDebugFixture: Bool
  let requestedRoute: AppRoute?
  let onRouteConsumed: () -> Void

  @State private var presentedRoute: AppRoute?
  @State private var safetyRefreshGeneration = 0

  init(
    controller: AuthSessionController,
    profile: UserProfile,
    onboardingAPIFactory: (any OnboardingSettingsAPIFactory)?,
    matchesAPIFactory: (any MatchesAPIFactory)?,
    matchDetailAPIFactory: (any MatchDetailAPIFactory)?,
    conversationInsightAPIFactory: (any ConversationInsightAPIFactory)?,
    quizAPIFactory: (any QuizAPIFactory)?,
    nativeIntegration: NativeFeatureIntegration = .unavailable,
    language: BilingualReferenceLanguage = .english,
    onLanguageChange: @escaping (BilingualReferenceLanguage) -> Void = { _ in },
    isDebugFixture: Bool = false,
    requestedRoute: AppRoute? = nil,
    onRouteConsumed: @escaping () -> Void = {}
  ) {
    self.controller = controller
    self.profile = profile
    self.onboardingAPIFactory = onboardingAPIFactory
    self.matchesAPIFactory = matchesAPIFactory
    self.matchDetailAPIFactory = matchDetailAPIFactory
    self.conversationInsightAPIFactory = conversationInsightAPIFactory
    self.quizAPIFactory = quizAPIFactory
    self.nativeIntegration = nativeIntegration
    self.language = language
    self.onLanguageChange = onLanguageChange
    self.isDebugFixture = isDebugFixture
    self.requestedRoute = requestedRoute
    self.onRouteConsumed = onRouteConsumed
    _presentedRoute = State(initialValue: nil)
  }

  var body: some View {
    Group {
      if profile.onboardingCompleted {
        if let ownerID = profile.id,
          let matchesAPI = matchesAPIFactory?.make(ownerID: ownerID)
        {
          BilingualProductionShell(
            controller: controller,
            ownerID: ownerID,
            language: language,
            matchesAPI: matchesAPI,
            matchDetailAPI: matchDetailAPIFactory?.make(ownerID: ownerID),
            insightAPI: conversationInsightAPIFactory?.make(ownerID: ownerID),
            onboardingAPIFactory: onboardingAPIFactory,
            quizAPIFactory: quizAPIFactory,
            nativeIntegration: nativeIntegration,
            onLanguageChange: onLanguageChange,
            isDebugFixture: isDebugFixture
          )
          .id(safetyRefreshGeneration)
        } else {
          BilingualProductionUnavailableView(
            language: language,
            title: .productionFeatureUnavailable,
            detail: .productionDetailPlaceholder
          )
        }
      } else {
        if let ownerID = profile.id,
          let onboardingAPI = onboardingAPIFactory?.make(ownerID: ownerID)
        {
          BilingualProductionOnboardingView(
            controller: controller,
            ownerID: ownerID,
            api: onboardingAPI,
            language: language,
            quizAPIFactory: quizAPIFactory,
            nativeIntegration: nativeIntegration,
            onLanguageChange: onLanguageChange,
            onCompleted: {
              Task {
                _ = await controller.refreshProfileAfterOnboarding(ownerID: ownerID)
              }
            }
          )
        } else {
          BilingualProductionUnavailableView(
            language: language,
            title: .productionOnboardingError,
            detail: .productionDetailPlaceholder
          )
        }
      }
    }
    .background(BilingualReferencePalette.cream.ignoresSafeArea())
    .preferredColorScheme(.light)
    .onAppear { applyRequestedRoute(requestedRoute) }
    .onChange(of: requestedRoute) { _, route in applyRequestedRoute(route) }
    .sheet(
      isPresented: Binding(
        get: { presentedRoute != nil },
        set: { if !$0 { presentedRoute = nil } }
      )
    ) {
      if let ownerID = profile.id, let presentedRoute {
        BilingualProductionRouteDestination(
          ownerID: ownerID,
          route: presentedRoute,
          integration: nativeIntegration,
          language: language,
          onBlocked: refreshShellAfterSafety,
          onBlockNeedsReconciliation: refreshShellAfterSafety
        )
      } else {
        BilingualProductionUnavailableView(
          language: language,
          title: .productionFeatureUnavailable,
          detail: .productionDetailPlaceholder
        )
      }
    }
  }

  private func applyRequestedRoute(_ route: AppRoute?) {
    guard let route, profile.id != nil else { return }
    guard NativeFeatureRouteGate.allows(
      route,
      isAuthenticated: true,
      ageVerified: profile.ageVerified,
      onboardingCompleted: profile.onboardingCompleted
    ) else { return }

    switch route {
    case .matches, .settings, .onboarding:
      // The shell's Words and You tabs own these destinations. A deep link
      // to one of them is consumed without opening a second legacy shell.
      break
    default:
      guard profile.onboardingCompleted else { return }
      presentedRoute = route
    }
    onRouteConsumed()
  }

  private func refreshShellAfterSafety() {
    safetyRefreshGeneration &+= 1
    presentedRoute = nil
  }
}

struct BilingualProductionLanguageChoiceView: View {
  let onSelect: (BilingualReferenceLanguage) -> Void

  var body: some View {
    ZStack {
      BilingualReferencePalette.cream.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          Circle()
            .fill(BilingualReferencePalette.yellow)
            .frame(width: 54, height: 54)
            .overlay {
              Image(systemName: "globe")
                .font(.title3.weight(.bold))
            }
            .padding(.top, 42)
          Text(bilingualReferenceCopy(.languageChoiceTitle, language: .japanese))
            .font(.system(size: 32, weight: .bold, design: .rounded))
            .tracking(-1)
            .padding(.top, 22)
            .accessibilityIdentifier("production.languageChoice.title")

          languageCard(
            language: .japanese,
            title: bilingualReferenceCopy(.languageJapanese, language: .japanese),
            subtitle: bilingualReferenceCopy(.languageChoiceJapaneseSubtitle, language: .japanese)
          )
          .padding(.top, 28)
          languageCard(
            language: .english,
            title: bilingualReferenceCopy(.languageEnglish, language: .english),
            subtitle: bilingualReferenceCopy(.languageChoiceEnglishSubtitle, language: .english)
          )
          .padding(.top, 12)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 34)
      }
    }
    .foregroundStyle(BilingualReferencePalette.ink)
  }

  private func languageCard(
    language: BilingualReferenceLanguage,
    title: String,
    subtitle: String
  ) -> some View {
    Button {
      onSelect(language)
    } label: {
      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 5) {
          Text(title)
            .font(.headline.weight(.bold))
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(BilingualReferencePalette.muted)
        }
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.right")
          .font(.headline.weight(.semibold))
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.white)
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(BilingualReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("production.languageChoice.\(language.rawValue)")
  }
}

struct BilingualProductionShell: View {
  let controller: AuthSessionController
  let ownerID: String
  let language: BilingualReferenceLanguage
  let matchesAPI: any MatchesAPI
  let matchDetailAPI: (any MatchDetailAPI)?
  let insightAPI: (any ConversationInsightAPI)?
  let onboardingAPIFactory: (any OnboardingSettingsAPIFactory)?
  let quizAPIFactory: (any QuizAPIFactory)?
  let nativeIntegration: NativeFeatureIntegration
  let onLanguageChange: (BilingualReferenceLanguage) -> Void
  let isDebugFixture: Bool

  @State private var selectedTab: BilingualReferenceTab = .words

  var body: some View {
    TabView(selection: $selectedTab) {
      NavigationStack {
        BilingualProductionWordsView(
          controller: controller,
          ownerID: ownerID,
          language: language,
          api: matchesAPI,
          matchDetailAPI: matchDetailAPI,
          nativeIntegration: nativeIntegration,
          isDebugFixture: isDebugFixture
        )
        .id("production.words-\(ownerID)")
      }
      .tabItem {
        Label(
          bilingualReferenceCopy(.tabWords, language: language),
          systemImage: "text.bubble.fill"
        )
      }
      .tag(BilingualReferenceTab.words)
      .accessibilityIdentifier("production.tab.words")

      NavigationStack {
        BilingualProductionYouView(
          controller: controller,
          ownerID: ownerID,
          language: language,
          insightAPI: insightAPI,
          onboardingAPIFactory: onboardingAPIFactory,
          quizAPIFactory: quizAPIFactory,
          nativeIntegration: nativeIntegration,
          onLanguageChange: onLanguageChange,
          isDebugFixture: isDebugFixture
        )
      }
      .tabItem {
        Label(
          bilingualReferenceCopy(.tabYou, language: language),
          systemImage: "person.crop.circle.fill"
        )
      }
      .tag(BilingualReferenceTab.you)
      .accessibilityIdentifier("production.tab.you")
    }
    .tint(BilingualReferencePalette.ink)
    .environment(
      \.locale,
      Locale(identifier: language == .japanese ? "ja" : "en")
    )
    .preferredColorScheme(.light)
  }
}

private struct BilingualProductionWordsView: View {
  let controller: AuthSessionController
  let ownerID: String
  let language: BilingualReferenceLanguage
  let api: any MatchesAPI
  let matchDetailAPI: (any MatchDetailAPI)?
  let nativeIntegration: NativeFeatureIntegration
  let isDebugFixture: Bool

  @State private var store: MatchesStore

  init(
    controller: AuthSessionController,
    ownerID: String,
    language: BilingualReferenceLanguage,
    api: any MatchesAPI,
    matchDetailAPI: (any MatchDetailAPI)?,
    nativeIntegration: NativeFeatureIntegration,
    isDebugFixture: Bool = false
  ) {
    self.controller = controller
    self.ownerID = ownerID
    self.language = language
    self.api = api
    self.matchDetailAPI = matchDetailAPI
    self.nativeIntegration = nativeIntegration
    self.isDebugFixture = isDebugFixture
    _store = State(initialValue: MatchesStore(ownerID: ownerID, api: api))
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      BilingualReferencePalette.cream.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          BilingualReferenceSectionLabel(
            text: bilingualReferenceCopy(.wordsKicker, language: language)
          )
          .padding(.top, 20)
          Text(store.supportsDemoJudgeMatching ? (language == .japanese ? "候補選定によるマッチ" : "Discovery matches") : bilingualReferenceCopy(.wordsTitle, language: language))
            .font(.system(size: 36, weight: .bold, design: .rounded))
            .tracking(-1.4)
            .lineSpacing(2)
            .padding(.top, 14)
          Text(store.supportsDemoJudgeMatching ? (language == .japanese ? "通常の候補選定で保存されたマッチです。" : "Saved matches from ordinary discovery.") : bilingualReferenceCopy(.productionWordsBody, language: language))
            .font(.subheadline)
            .foregroundStyle(BilingualReferencePalette.muted)
            .lineSpacing(5)
            .padding(.top, 14)
          if store.payload?.simulatedCounterpart == true {
            Text(language == .japanese ? "審査用の架空の相手とのマッチです。相手側の操作は自動で進み、実際の面会は行いません。" : "This judge match uses a fictional counterpart. Their actions advance automatically; no real meeting takes place.")
              .font(.footnote).foregroundStyle(BilingualReferencePalette.muted)
              .padding(.top, 14)
              .accessibilityIdentifier("production.words.simulatedCounterpart")
          }
          if store.supportsDemoJudgeMatching, store.phase == .loaded {
            DemoJudgeMatchingControls(store: store, japanese: language == .japanese)
              .padding(.top, 20)
          }
          content
            .padding(.top, 28)
        }
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
      }
      .scrollIndicators(.hidden)
      BilingualProductionAccountBadge(language: language, isDebugFixture: isDebugFixture)
        .padding(.top, 10)
        .padding(.trailing, 16)
    }
    .foregroundStyle(BilingualReferencePalette.ink)
    .task(id: ownerID) {
      await store.load().value
    }
    .onDisappear {
      store.cancel()
    }
  }

  @ViewBuilder
  private var content: some View {
    switch store.phase {
    case .idle, .loading:
      BilingualProductionLoadingCard(
        language: language,
        detail: .productionLoading,
        identifier: "production.words.loading"
      )
    case .failed:
      BilingualProductionErrorCard(
        language: language,
        title: .productionMatchesLoadError,
        retry: { Task { await store.retry().value } },
        identifier: "production.words.retry"
      )
    case .loaded:
      if !store.displayedMatches.isEmpty {
        VStack(alignment: .leading, spacing: 14) {
          if let noticeKey = recordingRehearsalNoticeCopy {
            Text(bilingualReferenceCopy(noticeKey, language: language))
              .font(.footnote.weight(.bold))
              .foregroundStyle(BilingualReferencePalette.ink)
              .accessibilityIdentifier("production.words.recordingRehearsal.notice")
          }
          if let statusKey = recordingRehearsalStatusCopy {
            Text(bilingualReferenceCopy(statusKey, language: language))
              .font(.footnote.weight(.medium))
              .foregroundStyle(BilingualReferencePalette.muted)
              .accessibilityIdentifier("production.words.recordingRehearsal.status")
          }
          HStack(alignment: .firstTextBaseline) {
            Text(bilingualReferenceCopy(.wordsCandidatesLabel, language: language))
              .font(.caption.weight(.bold))
              .tracking(1.3)
              .foregroundStyle(BilingualReferencePalette.muted)
            Spacer()
            Button {
              Task { await store.retry().value }
            } label: {
              Text(bilingualReferenceCopy(.productionRefresh, language: language))
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("production.words.refresh")
          }
          ForEach(Array(store.displayedMatches.enumerated()), id: \.element.id) { index, match in
            matchRow(rank: index + 1, match: match)
          }
        }
      } else {
        VStack(spacing: 10) {
          if store.supportsDemoJudgeMatching {
            Text(language == .japanese ? "保存済みマッチはありません。" : "No saved discovery matches yet.")
              .accessibilityIdentifier("production.words.empty")
          } else {
            BilingualProductionEmptyCard(
              language: language,
              title: .productionMatchesEmptyTitle,
              detail: .productionMatchesEmptyBody,
              identifier: "production.words.empty"
            )
          }
          if let noticeKey = recordingRehearsalNoticeCopy {
            Text(bilingualReferenceCopy(noticeKey, language: language))
              .font(.footnote)
              .foregroundStyle(BilingualReferencePalette.muted)
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityIdentifier("production.words.recordingRehearsal.notice")
            if let statusKey = recordingRehearsalStatusCopy {
              Text(bilingualReferenceCopy(statusKey, language: language))
                .font(.footnote.weight(.medium))
                .foregroundStyle(BilingualReferencePalette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("production.words.recordingRehearsal.status")
            }
            if store.canPreviewRecordingRehearsal {
              Button {
                guard let task = store.previewRecordingRehearsal() else { return }
                Task { await task.value }
              } label: {
                Text(bilingualReferenceCopy(.recordingRehearsalPreviewOnly, language: language))
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(BilingualReferenceSecondaryButtonStyle())
              .accessibilityIdentifier("production.words.empty.previewTestMatching")
            }
            if store.canStartRecordingRehearsal {
              Button {
                guard let task = store.startRecordingRehearsal() else { return }
                Task { await task.value }
              } label: {
                Text(bilingualReferenceCopy(.recordingRehearsalStart, language: language))
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(BilingualReferenceSecondaryButtonStyle())
              .accessibilityIdentifier("production.words.empty.startTestMatching")
            } else if store.isRecordingRehearsalInProgress {
              ProgressView()
                .tint(BilingualReferencePalette.yellow)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("production.words.recordingRehearsal.progress")
            } else {
              Button {
                Task { await store.retry().value }
              } label: {
                Text(bilingualReferenceCopy(.productionRefresh, language: language))
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(BilingualReferenceSecondaryButtonStyle())
              .accessibilityIdentifier("production.words.empty.refresh")
            }
          } else {
            Button {
              Task { await store.retry().value }
            } label: {
              Text(bilingualReferenceCopy(.productionRefresh, language: language))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(BilingualReferenceSecondaryButtonStyle())
            .accessibilityIdentifier("production.words.empty.refresh")
          }
        }
      }
    }
  }

  private var recordingRehearsalNoticeCopy: BilingualReferenceCopyKey? {
    guard store.supportsRecordingRehearsal else { return nil }
    return isDebugFixture ? .recordingRehearsalDebugNotice : .recordingRehearsalNotice
  }

  private var recordingRehearsalStatusCopy: BilingualReferenceCopyKey? {
    if isDebugFixture {
      switch store.rehearsalPhase {
      case .idle:
        return nil
      case .previewing:
        return .recordingRehearsalDebugChecking
      case .previewed:
        return .recordingRehearsalDebugResult
      case .previewFailed:
        return .recordingRehearsalDebugError
      case .starting:
        return .recordingRehearsalDebugStarting
      case .refreshingResults:
        return .recordingRehearsalDebugLoading
      case .finished:
        return .recordingRehearsalDebugResult
      case .resultsUnavailable, .failed, .cancelled:
        return .recordingRehearsalDebugError
      }
    }

    switch store.rehearsalPhase {
    case .idle:
      return nil
    case .previewing:
      return .recordingRehearsalChecking
    case let .previewed(result):
      switch result.outcome {
      case .eligible: return .recordingRehearsalPreviewEligible
      case .notEligible: return .recordingRehearsalPreviewNotEligible
      case .alreadyExists: return .recordingRehearsalPreviewAlreadyExists
      case .expired: return .recordingRehearsalPreviewExpired
      }
    case .previewFailed:
      return .recordingRehearsalPreviewFailed
    case .starting:
      return .recordingRehearsalStarting
    case .refreshingResults:
      return .recordingRehearsalLoading
    case let .finished(outcome):
      switch outcome {
      case .started: return .recordingRehearsalStarted
      case .startedPartial: return .recordingRehearsalPartial
      case .alreadyExists: return .recordingRehearsalExisting
      case .notEligible: return .recordingRehearsalNotEligible
      case .expired: return .recordingRehearsalExpired
    }
    case let .resultsUnavailable(outcome):
      if outcome == .startedPartial {
        return .recordingRehearsalPartialResultsUnavailable
      }
      return .recordingRehearsalResultsUnavailable
    case .failed:
      return .recordingRehearsalFailed
    case .cancelled:
      return .recordingRehearsalCancelled
    }
  }

  @ViewBuilder
  private func matchRow(rank: Int, match: ProductionMatch) -> some View {
    if let matchDetailAPI {
      NavigationLink {
        BilingualProductionMatchDetailView(
          controller: controller,
          ownerID: ownerID,
          rank: rank,
          matchID: match.id,
          api: matchDetailAPI,
          language: language,
          nativeIntegration: nativeIntegration,
          isDebugFixture: isDebugFixture
        )
      } label: {
        BilingualProductionMatchCard(
          rank: rank,
          match: match,
          language: language
        )
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("production.words.match.\(match.id.uuidString)")
    } else {
      BilingualProductionMatchCard(rank: rank, match: match, language: language)
        .accessibilityIdentifier("production.words.match.\(match.id.uuidString)")
    }
  }
}

private struct BilingualProductionAccountBadge: View {
  let language: BilingualReferenceLanguage
  let isDebugFixture: Bool

  init(language: BilingualReferenceLanguage, isDebugFixture: Bool = false) {
    self.language = language
    self.isDebugFixture = isDebugFixture
  }

  var body: some View {
    Group {
      if isDebugFixture {
        BilingualReferenceOfflineBadge(language: language)
      } else {
        Text(bilingualReferenceCopy(.productionLiveBadge, language: language))
          .font(.caption2.weight(.bold))
          .tracking(1.2)
          .foregroundStyle(BilingualReferencePalette.ink)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(BilingualReferencePalette.yellow)
          .clipShape(Capsule())
      }
    }
      .accessibilityIdentifier("production.accountBadge")
}
}

private struct BilingualProductionMatchCard: View {
  let rank: Int
  let match: ProductionMatch
  let language: BilingualReferenceLanguage

  var body: some View {
    HStack(spacing: 14) {
      BilingualProductionMatchPortrait(partner: match.partner)
      VStack(alignment: .leading, spacing: 6) {
        Text(String(format: bilingualReferenceCopy(.productionMatchRank, language: language), rank))
          .font(.caption2.weight(.bold))
          .tracking(1.3)
          .foregroundStyle(BilingualReferencePalette.muted)
        Text(match.partner.displayName)
          .font(.title3.weight(.bold))
        Text(statusCopy)
          .font(.subheadline)
          .foregroundStyle(BilingualReferencePalette.muted)
          .lineSpacing(3)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.caption.weight(.bold))
        .foregroundStyle(BilingualReferencePalette.muted)
        .accessibilityHidden(true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(match.partner.displayName), \(statusCopy)")
  }

  private var statusCopy: String {
    switch match.status {
    case "pending":
      return bilingualReferenceCopy(.productionMatchStatusPending, language: language)
    case "fox_conversation_in_progress":
      return bilingualReferenceCopy(.productionMatchStatusInProgress, language: language)
    case "fox_conversation_completed":
      return bilingualReferenceCopy(.productionMatchStatusCompleted, language: language)
    case "fox_conversation_failed":
      return bilingualReferenceCopy(.productionMatchStatusFailed, language: language)
    default:
      return bilingualReferenceCopy(.productionMatchStatusUnknown, language: language)
    }
  }
}

private struct BilingualProductionMatchPortrait: View {
  let partner: ProductionMatch.Partner

  var body: some View {
    AsyncImage(url: partner.avatarURL ?? partner.personaIconURL) { phase in
      switch phase {
      case let .success(image):
        image.resizable().scaledToFill()
      case .empty, .failure:
        placeholder
      @unknown default:
        placeholder
      }
    }
    .frame(width: 76, height: 76)
    .background(BilingualReferencePalette.softYellow)
    .clipShape(Circle())
    .overlay {
      Circle().stroke(BilingualReferencePalette.yellow, lineWidth: 2)
    }
    .accessibilityLabel(partner.displayName)
  }

  private var placeholder: some View {
    Image(systemName: "person.fill")
      .font(.system(size: 26, weight: .medium))
      .foregroundStyle(BilingualReferencePalette.muted)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct BilingualProductionMatchDetailView: View {
  let controller: AuthSessionController
  let ownerID: String
  let rank: Int
  let matchID: UUID
  let api: any MatchDetailAPI
  let language: BilingualReferenceLanguage
  let nativeIntegration: NativeFeatureIntegration
  let isDebugFixture: Bool

  @Environment(\.dismiss) private var dismiss
  @State private var store: MatchDetailStore
  @State private var presentedFeature: BilingualProductionFeaturePresentation?

  init(
    controller: AuthSessionController,
    ownerID: String,
    rank: Int,
    matchID: UUID,
    api: any MatchDetailAPI,
    language: BilingualReferenceLanguage,
    nativeIntegration: NativeFeatureIntegration,
    isDebugFixture: Bool = false
  ) {
    self.controller = controller
    self.ownerID = ownerID
    self.rank = rank
    self.matchID = matchID
    self.api = api
    self.language = language
    self.nativeIntegration = nativeIntegration
    self.isDebugFixture = isDebugFixture
    _store = State(initialValue: MatchDetailStore(ownerID: ownerID, matchID: matchID, api: api))
    _presentedFeature = State(initialValue: nil)
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      BilingualReferencePalette.cream.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          BilingualReferenceSectionLabel(
            text: bilingualReferenceCopy(.productionMatchDetailTitle, language: language)
          )
          Text(String(format: bilingualReferenceCopy(.productionMatchRank, language: language), rank))
            .font(.caption.weight(.bold))
            .tracking(1.3)
            .foregroundStyle(BilingualReferencePalette.muted)
          Text(bilingualReferenceCopy(.productionMatchDetailBody, language: language))
            .font(.subheadline)
            .foregroundStyle(BilingualReferencePalette.muted)
            .lineSpacing(4)
          content
        }
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 30)
      }
      .scrollIndicators(.hidden)
      BilingualProductionAccountBadge(language: language, isDebugFixture: isDebugFixture)
        .padding(.top, 10)
        .padding(.trailing, 16)
    }
    .foregroundStyle(BilingualReferencePalette.ink)
    .navigationTitle(bilingualReferenceCopy(.productionMatchDetailTitle, language: language))
    .navigationBarTitleDisplayMode(.inline)
    .task(id: "\(ownerID)-\(matchID.uuidString)") {
      await store.load().value
    }
    .onDisappear {
      store.cancel()
    }
    .sheet(item: $presentedFeature) { presentation in
      BilingualProductionFeatureDestination(
        presentation: presentation,
        ownerID: ownerID,
        matchID: matchID,
        nativeIntegration: nativeIntegration,
        language: language,
        onDismiss: { presentedFeature = nil },
        onOpenReportForMatch: { targetMatchID, context in
          guard targetMatchID == matchID else { return }
          presentedFeature = BilingualProductionFeaturePresentation(
            kind: .safety,
            safetyContext: context
          )
        },
        onBlocked: {
          presentedFeature = nil
          Task { await store.retry().value }
        },
        onBlockNeedsReconciliation: {
          presentedFeature = nil
          Task { await store.retry().value }
        }
      )
    }
  }

  @ViewBuilder
  private var content: some View {
    switch store.phase {
    case .idle, .loading:
      BilingualProductionLoadingCard(
        language: language,
        detail: .productionMatchDetailLoading,
        identifier: "production.matchDetail.loading"
      )
    case .failed:
      BilingualProductionErrorCard(
        language: language,
        title: .productionMatchDetailError,
        retry: { Task { await store.retry().value } },
        identifier: "production.matchDetail.retry"
      )
    case .loaded:
      if let detail = store.detail {
        loadedSurface(detail)
      } else {
        BilingualProductionEmptyCard(
          language: language,
          title: .productionMatchDetailError,
          detail: .productionNoConversation,
          identifier: "production.matchDetail.empty"
        )
      }
    }
  }

  private func loadedSurface(_ detail: ProductionMatchDetail) -> some View {
    VoiceProfileCard {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .top, spacing: 14) {
          BilingualProductionDetailPortrait(partner: detail.partner)
          VStack(alignment: .leading, spacing: 5) {
            Text(detail.partner.displayName)
              .font(.system(size: 25, weight: .bold, design: .rounded))
              .accessibilityIdentifier("production.matchDetail.partner")
            Text(statusCopy(for: detail.status))
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(BilingualReferencePalette.muted)
          }
          Spacer(minLength: 0)
        }

        partnerAnalysisSurface(detail.foxSummary)
        actionSurface(detail)
        historySurface(detail)
      }
    }
  }

  @ViewBuilder
  private func partnerAnalysisSurface(_ summary: String?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(bilingualReferenceCopy(.productionPartnerAnalysisTitle, language: language))
        .font(.headline.weight(.bold))
        .accessibilityIdentifier("production.matchDetail.partnerAnalysis")
      if let summary = bilingualProductionPartnerAnalysisSummary(summary, language: language) {
        Text(summary)
          .font(.subheadline)
          .foregroundStyle(BilingualReferencePalette.muted)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("production.matchDetail.partnerAnalysis.summary")
      } else {
        Text(bilingualReferenceCopy(.productionPartnerAnalysisEmpty, language: language))
          .font(.subheadline.weight(.semibold))
          .accessibilityIdentifier("production.matchDetail.partnerAnalysis.empty")
        Text(bilingualReferenceCopy(.productionPartnerAnalysisEmptyBody, language: language))
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(BilingualReferencePalette.field)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  @ViewBuilder
  private func actionSurface(_ detail: ProductionMatchDetail) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if nativeIntegration.matchSafety != nil {
        Button {
          presentedFeature = BilingualProductionFeaturePresentation(kind: .safety)
        } label: {
          Label(
            bilingualReferenceCopy(.productionReportBlock, language: language),
            systemImage: "exclamationmark.shield"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
        .accessibilityIdentifier("production.matchDetail.reportBlock")
      }

      if nativeIntegration.meetupForMatch != nil {
        Button {
          presentedFeature = BilingualProductionFeaturePresentation(kind: .meetup)
        } label: {
          Label(
            bilingualReferenceCopy(.productionPlanMeetup, language: language),
            systemImage: "calendar"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
        .accessibilityIdentifier("production.matchDetail.meetup")
      }

      if store.canStartConversation {
        Button {
          Task { await store.startConversation().value }
        } label: {
          HStack(spacing: 8) {
            if store.isStartingConversation { ProgressView().tint(BilingualReferencePalette.ink) }
            Text(bilingualReferenceCopy(.productionStartWard, language: language))
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(BilingualReferencePrimaryButtonStyle())
        .disabled(store.isStartingConversation)
        .accessibilityIdentifier("production.matchDetail.startWard")
      }

      if store.startError != nil {
        BilingualProductionInlineNotice(
          language: language,
          title: .productionMatchDetailError,
          detail: .productionDetailPlaceholder,
          identifier: "production.matchDetail.startError"
        )
      }

      if store.canStartPartnerChat {
        Button {
          Task { await store.startPartnerChat().value }
        } label: {
          HStack(spacing: 8) {
            if store.isStartingPartnerChat { ProgressView().tint(BilingualReferencePalette.ink) }
            Text(bilingualReferenceCopy(.productionStartPartnerWard, language: language))
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
        .disabled(store.isStartingPartnerChat)
        .accessibilityIdentifier("production.matchDetail.startPartnerWard")
      }

      if nativeIntegration.chatRequestForMatch != nil, detail.partnerFoxChatID != nil,
        detail.status == "fox_conversation_completed" || detail.status == "partner_chat_started"
      {
        Button {
          presentedFeature = BilingualProductionFeaturePresentation(kind: .chatRequest)
        } label: {
          Text(bilingualReferenceCopy(.productionRequestDirectChat, language: language))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(BilingualReferencePrimaryButtonStyle())
        .accessibilityIdentifier("production.matchDetail.requestDirectChat")
      }

      if nativeIntegration.directChats != nil,
        ["direct_chat_requested", "direct_chat_active", "meetup_intent", "meetup_confirmed"]
          .contains(detail.status)
      {
        Button {
          presentedFeature = BilingualProductionFeaturePresentation(kind: .directChats)
        } label: {
          Text(bilingualReferenceCopy(.productionChatLabel, language: language))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(BilingualReferencePrimaryButtonStyle())
        .accessibilityIdentifier("production.matchDetail.directChats")
      }

      if let partnerStartError = store.partnerStartError {
        BilingualProductionInlineNotice(
          language: language,
          title: .productionPartnerWard,
          detail: .productionDetailPlaceholder,
          identifier: "production.matchDetail.partnerWardError"
        )
        #if DEBUG
        Text("Diagnostic code: PW-\(String(describing: partnerStartError))")
          .font(.caption.monospaced())
          .accessibilityIdentifier("production.matchDetail.partnerWardDiagnostic")
        #endif
      }

      if let partnerChatID = detail.partnerFoxChatID {
        NavigationLink {
          BilingualProductionPartnerWardView(
            ownerID: ownerID,
            matchID: matchID,
            partnerID: detail.partnerID,
            chatID: partnerChatID,
            api: api,
            language: language,
            nativeIntegration: nativeIntegration,
            directChatsAPI: nativeIntegration.directChatsAPI?(ownerID)
          )
        } label: {
          HStack {
            Text(bilingualReferenceCopy(.productionChatLabel, language: language))
            Spacer()
            Image(systemName: "chevron.right")
          }
          .font(.subheadline.weight(.bold))
          .foregroundStyle(BilingualReferencePalette.ink)
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(BilingualReferencePalette.softYellow)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("production.matchDetail.partnerWard")
      }

    }
  }

  private func historySurface(_ detail: ProductionMatchDetail) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(bilingualReferenceCopy(.productionWardHistory, language: language))
          .font(.headline.weight(.bold))
          .accessibilityIdentifier("production.matchDetail.history")
        Spacer()
        if let conversation = store.conversation {
          Text(
            String(
              format: bilingualReferenceCopy(.productionRound, language: language),
              conversation.currentRound,
              conversation.totalRounds
            )
          )
          .font(.caption.weight(.bold))
          .padding(.horizontal, 9)
          .padding(.vertical, 6)
          .background(BilingualReferencePalette.softYellow)
          .clipShape(Capsule())
        }
      }
      if store.messages.isEmpty {
        Text(bilingualReferenceCopy(.productionWardHistoryEmpty, language: language))
          .font(.subheadline)
          .foregroundStyle(BilingualReferencePalette.muted)
          .accessibilityIdentifier("production.matchDetail.history.empty")
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(store.messages) { message in
            BilingualProductionWardMessageRow(
              message: message,
              partnerName: detail.partner.displayName,
              language: language
            )
          }
        }
        .padding(12)
        .background(BilingualReferencePalette.field)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        Text(bilingualReferenceCopy(.productionHistoryLimit, language: language))
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
      }
      if detail.status == "fox_conversation_in_progress" {
        Button {
          Task { await store.retry().value }
        } label: {
          Text(bilingualReferenceCopy(.productionRefresh, language: language))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
        .accessibilityIdentifier("production.matchDetail.history.refresh")
      }
    }
  }

  private func statusCopy(for status: String) -> String {
    switch status {
    case "pending": return bilingualReferenceCopy(.productionMatchStatusPending, language: language)
    case "fox_conversation_in_progress": return bilingualReferenceCopy(.productionMatchStatusInProgress, language: language)
    case "fox_conversation_completed": return bilingualReferenceCopy(.productionMatchStatusCompleted, language: language)
    case "fox_conversation_failed": return bilingualReferenceCopy(.productionMatchStatusFailed, language: language)
    default: return bilingualReferenceCopy(.productionMatchStatusUnknown, language: language)
    }
  }
}

private struct BilingualProductionDetailPortrait: View {
  let partner: MatchDetailPartner

  var body: some View {
    ZStack {
      BilingualReferencePalette.softYellow
      Text(String(partner.displayName.prefix(1)))
        .font(.system(size: 26, weight: .bold, design: .rounded))
        .foregroundStyle(BilingualReferencePalette.ink)
    }
    .frame(width: 74, height: 74)
    .clipShape(Circle())
    .overlay {
      Circle().stroke(BilingualReferencePalette.yellow, lineWidth: 2)
    }
    .accessibilityLabel(partner.displayName)
  }
}

private struct BilingualProductionWardMessageRow: View {
  let message: FoxConversationMessage
  let partnerName: String
  let language: BilingualReferenceLanguage

  var body: some View {
    let isMine = message.speaker == .myFox
    HStack(alignment: .bottom, spacing: 8) {
      if isMine { Spacer(minLength: 32) }
      VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
        Text(isMine ? bilingualReferenceCopy(.wordsComposerMyWard, language: language) : partnerName)
          .font(.caption2.weight(.bold))
          .foregroundStyle(BilingualReferencePalette.muted)
        Text(message.content)
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
        Text(message.createdAt, style: .time)
          .font(.caption2)
          .foregroundStyle(BilingualReferencePalette.muted)
      }
      .padding(.horizontal, 13)
      .padding(.vertical, 10)
      .background(isMine ? BilingualReferencePalette.yellow : .white)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      if !isMine { Spacer(minLength: 32) }
    }
    .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    .accessibilityIdentifier("production.matchDetail.message.\(message.id.uuidString)")
  }
}

/// The Partner Ward route keeps the existing owner/match/chat binding while
/// making Ward and human conversation one screen. Human access is resolved
/// from the owner-bound DirectChats stores; local mode state never unlocks it.
private struct BilingualProductionPartnerWardView: View {
  let ownerID: String
  let matchID: UUID
  let partnerID: UUID
  let chatID: UUID
  let api: any MatchDetailAPI
  let language: BilingualReferenceLanguage
  let nativeIntegration: NativeFeatureIntegration
  let directChatsAPI: (any DirectChatsAPI)?

  @State private var store: PartnerWardStore
  @State private var directChatsStore: DirectChatsStore?
  @State private var requestsStore: ChatRequestsStore?
  @State private var directChatStore: DirectChatStore?
  @State private var mode: BilingualProductionPartnerConversationMode = .ward
  @State private var wardDraft = ""
  @State private var humanDraft = ""
  @State private var presentedFeature: BilingualProductionFeaturePresentation?

  init(
    ownerID: String,
    matchID: UUID,
    partnerID: UUID,
    chatID: UUID,
    api: any MatchDetailAPI,
    language: BilingualReferenceLanguage,
    nativeIntegration: NativeFeatureIntegration,
    directChatsAPI: (any DirectChatsAPI)? = nil
  ) {
    self.ownerID = ownerID
    self.matchID = matchID
    self.partnerID = partnerID
    self.chatID = chatID
    self.api = api
    self.language = language
    self.nativeIntegration = nativeIntegration
    self.directChatsAPI = directChatsAPI
    _store = State(
      initialValue: PartnerWardStore(
        ownerID: ownerID,
        matchID: matchID,
        partnerID: partnerID,
        chatID: chatID,
        api: api
      )
    )
    _directChatsStore = State(
      initialValue: directChatsAPI.map { DirectChatsStore(ownerID: ownerID, api: $0) }
    )
    _requestsStore = State(
      initialValue: directChatsAPI.map { ChatRequestsStore(ownerID: ownerID, api: $0) }
    )
  }

  var body: some View {
    ZStack {
      BilingualReferencePalette.cream.ignoresSafeArea()
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            BilingualReferenceSectionLabel(
              text: bilingualReferenceCopy(.productionPartnerWard, language: language)
            )
            VoiceProfileCardHeading(
              systemImage: "bubble.left.and.bubble.right.fill",
              title: bilingualReferenceCopy(.productionPartnerWard, language: language),
              subtitle: bilingualReferenceCopy(.productionPartnerWardBody, language: language)
            )
            content
          }
          .frame(maxWidth: 700, alignment: .leading)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 22)
          .padding(.top, 26)
          .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .onChange(of: mode) { _, newMode in
          guard newMode == .you else { return }
          Task { await loadDirectChatAccess() }
        }
        .onChange(of: wardMessageIDs) { _, _ in
          guard mode == .ward else { return }
          scrollToLatest(proxy)
        }
        .onChange(of: directMessageIDs) { _, _ in
          guard mode == .you else { return }
          scrollToLatest(proxy)
        }
      }
    }
    .foregroundStyle(BilingualReferencePalette.ink)
    .navigationTitle(bilingualReferenceCopy(.productionPartnerWard, language: language))
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      conversationComposer
    }
    .task(id: routeID) {
      await store.load().value
      await loadDirectChatAccess()
      syncDirectChatStore()
    }
    .onDisappear {
      store.cancel()
      directChatsStore?.cancel()
      requestsStore?.cancel()
      directChatStore?.cancel()
    }
    .sheet(item: $presentedFeature) { presentation in
      BilingualProductionFeatureDestination(
        presentation: presentation,
        ownerID: ownerID,
        matchID: matchID,
        nativeIntegration: nativeIntegration,
        language: language,
        onDismiss: { presentedFeature = nil },
        onOpenReportForMatch: { targetMatchID, context in
          guard targetMatchID == matchID else { return }
          presentedFeature = BilingualProductionFeaturePresentation(
            kind: .safety,
            safetyContext: context
          )
        },
        onBlocked: {
          presentedFeature = nil
          Task {
            await store.retry().value
            await loadDirectChatAccess()
          }
        },
        onBlockNeedsReconciliation: {
          presentedFeature = nil
          Task {
            await store.retry().value
            await loadDirectChatAccess()
          }
        }
      )
    }
  }

  private var routeID: String {
    "\(ownerID)-\(matchID.uuidString)-\(chatID.uuidString)"
  }

  private var wardMessageIDs: [UUID] {
    store.messages.map(\.id)
  }

  private var directMessageIDs: [UUID] {
    directChatStore?.messages.map(\.id) ?? []
  }

  private var matchingDirectChat: DirectChatSummary? {
    guard let chats = directChatsStore?.chats else { return nil }
    return bilingualProductionActiveDirectChat(for: matchID, in: chats)
  }

  private var matchingRequest: ChatRequestSummary? {
    requestsStore?.requests.first {
      $0.matchID == matchID && $0.status == "pending"
    }
  }

  private var composerModeSelector: some View {
    HStack(spacing: 4) {
      modeButton(
        .ward,
        title: .productionConversationModeWard,
        identifier: "production.partnerWard.mode.ward"
      )
      modeButton(
        .you,
        title: .productionConversationModeYou,
        identifier: "production.partnerWard.mode.you"
      )
    }
    .padding(3)
    .background(BilingualReferencePalette.field)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func modeButton(
    _ value: BilingualProductionPartnerConversationMode,
    title: BilingualReferenceCopyKey,
    identifier: String
  ) -> some View {
    Button {
      mode = value
    } label: {
      HStack(spacing: 5) {
        Image(systemName: value == .ward ? "sparkles" : "person.fill")
          .font(.caption.weight(.semibold))
        Text(bilingualReferenceCopy(title, language: language))
          .font(.caption.weight(.semibold))
      }
      .foregroundStyle(BilingualReferencePalette.ink)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(minWidth: 54)
      .background(mode == value ? BilingualReferencePalette.yellow : .clear)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
    .accessibilityAddTraits(mode == value ? .isSelected : [])
  }

  @ViewBuilder
  private var content: some View {
    switch store.phase {
    case .idle, .loading:
      BilingualProductionLoadingCard(
        language: language,
        detail: .productionLoading,
        identifier: "production.partnerWard.loading"
      )
    case .failed:
      BilingualProductionErrorCard(
        language: language,
        title: .productionMatchDetailError,
        retry: { Task { await store.retry().value } },
        identifier: "production.partnerWard.retry"
      )
    case .loaded:
      if let chat = store.chat {
        loadedSurface(chat)
      } else {
        BilingualProductionEmptyCard(
          language: language,
          title: .productionPartnerWard,
          detail: .productionNoConversation,
          identifier: "production.partnerWard.empty"
        )
      }
    }
  }

  private func loadedSurface(_ chat: PartnerFoxChatDetail) -> some View {
    VoiceProfileCard {
      VStack(alignment: .leading, spacing: 18) {
        VoiceProfileCardHeading(
          systemImage: "person.fill",
          title: localizedPartnerName(chat.partner.nickname),
          subtitle: bilingualReferenceCopy(.productionPartnerWard, language: language)
        )
        .accessibilityIdentifier("production.partnerWard.partner")
        partnerActions
        conversationHistory(chat)
      }
    }
  }

  @ViewBuilder
  private func conversationHistory(_ chat: PartnerFoxChatDetail) -> some View {
    if mode == .ward {
      wardHistory(chat)
    } else {
      humanHistory
    }
  }

  private func wardHistory(_ chat: PartnerFoxChatDetail) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(bilingualReferenceCopy(.productionWardHistory, language: language))
        .font(.headline.weight(.bold))
        .accessibilityIdentifier("production.partnerWard.history")
      if store.messages.isEmpty {
        Text(bilingualReferenceCopy(.productionWardHistoryEmpty, language: language))
          .font(.subheadline)
          .foregroundStyle(BilingualReferencePalette.muted)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(store.messages) { message in
            partnerMessageRow(
              message,
              partnerName: localizedPartnerName(chat.partner.nickname)
            )
            .id("ward-\(message.id.uuidString)")
          }
        }
        .padding(12)
        .background(BilingualReferencePalette.field)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
    }
  }

  @ViewBuilder
  private var humanHistory: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(bilingualReferenceCopy(.productionDirectChat, language: language))
        .font(.headline.weight(.bold))
        .accessibilityIdentifier("production.partnerWard.humanHistory")
      if let activeChat = matchingDirectChat {
        directChatHistory(activeChat)
      } else {
        humanAccessSurface
      }
    }
  }

  @ViewBuilder
  private func directChatHistory(_ activeChat: DirectChatSummary) -> some View {
    if let directChatStore, directChatStore.roomID == activeChat.id {
      switch directChatStore.phase {
      case .idle, .loading:
        BilingualProductionLoadingCard(
          language: language,
          detail: .productionLoading,
          identifier: "production.partnerWard.directChat.loading"
        )
      case .failed:
        BilingualProductionErrorCard(
          language: language,
          title: .productionDirectChatError,
          retry: { Task { await directChatStore.retry().value } },
          identifier: "production.partnerWard.directChat.retry"
        )
      case .loaded:
        if directChatStore.messages.isEmpty {
          Text(bilingualReferenceCopy(.productionWardHistoryEmpty, language: language))
            .font(.subheadline)
            .foregroundStyle(BilingualReferencePalette.muted)
            .accessibilityIdentifier("production.partnerWard.directChat.empty")
        } else {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(directChatStore.messages) { message in
              directMessageRow(
                message,
                partnerName: localizedPartnerName(activeChat.partner?.nickname)
              )
              .id("direct-\(message.id.uuidString)")
            }
          }
          .padding(12)
          .background(BilingualReferencePalette.field)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
      }
    } else {
      BilingualProductionLoadingCard(
        language: language,
        detail: .productionLoading,
        identifier: "production.partnerWard.directChat.loading"
      )
    }
  }

  @ViewBuilder
  private var humanAccessSurface: some View {
    if directChatsAPI == nil {
      accessUnavailableSurface
    } else if let chatsStore = directChatsStore, let requestsStore {
      if case .failed = chatsStore.phase {
        accessErrorSurface
      } else if case .failed = requestsStore.phase {
        accessErrorSurface
      } else if case .failed = requestsStore.requestStatePhase {
        accessErrorSurface
      } else if chatsStore.phase != .loaded || requestsStore.phase != .loaded
        || requestsStore.requestStatePhase != .loaded
      {
        BilingualProductionLoadingCard(
          language: language,
          detail: .productionLoading,
          identifier: "production.partnerWard.directChat.accessLoading"
        )
      } else {
        switch bilingualProductionChatRequestState(
          for: requestsStore.requestState,
          ownerID: ownerID,
          matchID: matchID
        ) {
        case .none:
          requestSurface
        case .outgoingPending:
          pendingRequestSurface
        case .incomingPending:
          if matchingRequest != nil {
            incomingRequestSurface
          } else {
            incomingRequestStatePendingSurface
          }
        case .accepted:
          acceptedRequestSurface
        case .declined:
          terminalRequestSurface(
            detail: .productionDirectChatDeclined,
            identifier: "production.partnerWard.directChat.declined"
          )
        case .expired:
          terminalRequestSurface(
            detail: .productionDirectChatExpired,
            identifier: "production.partnerWard.directChat.expired"
          )
        }
      }
    } else {
      accessUnavailableSurface
    }
  }

  private var accessUnavailableSurface: some View {
    BilingualProductionEmptyCard(
      language: language,
      title: .productionDirectChat,
      detail: .productionDirectChatUnavailable,
      identifier: "production.partnerWard.directChat.unavailable"
    )
  }

  private var accessErrorSurface: some View {
    BilingualProductionErrorCard(
      language: language,
      title: .productionDirectChatError,
      retry: { Task { await loadDirectChatAccess() } },
      identifier: "production.partnerWard.directChat.retry"
    )
  }

  private var requestSurface: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(bilingualReferenceCopy(.productionRequestDirectChat, language: language))
        .font(.subheadline.weight(.bold))
      Text(bilingualReferenceCopy(.productionDirectChatRequestBody, language: language))
        .font(.subheadline)
        .foregroundStyle(BilingualReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
      if requestsStore?.creatingError != nil {
        Text(bilingualReferenceCopy(.productionDirectChatCreateFailed, language: language))
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
          .accessibilityIdentifier("production.partnerWard.directChat.createError")
        Button {
          refreshDirectChatAccess()
        } label: {
          Text(bilingualReferenceCopy(.productionRefresh, language: language))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
        .accessibilityIdentifier("production.partnerWard.directChat.request.refresh")
      }
      Button {
        createDirectChatRequest()
      } label: {
        HStack(spacing: 8) {
          if requestsStore?.isCreating == true {
            ProgressView().tint(BilingualReferencePalette.ink)
          }
          Text(bilingualReferenceCopy(.productionRequestDirectChat, language: language))
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(BilingualReferencePrimaryButtonStyle())
      .disabled(requestsStore?.isCreating == true)
      .accessibilityIdentifier("production.partnerWard.requestDirectChat")
    }
    .padding(15)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(BilingualReferencePalette.softYellow)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityIdentifier("production.partnerWard.directChat.request")
  }

  private var pendingRequestSurface: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(bilingualReferenceCopy(.productionDirectChatPendingTitle, language: language))
        .font(.subheadline.weight(.bold))
      Text(bilingualReferenceCopy(.productionDirectChatPendingBody, language: language))
        .font(.subheadline)
        .foregroundStyle(BilingualReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        refreshDirectChatAccess()
      } label: {
        Text(bilingualReferenceCopy(.productionRefresh, language: language))
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(BilingualReferenceSecondaryButtonStyle())
      .accessibilityIdentifier("production.partnerWard.directChat.pending.refresh")
    }
    .padding(15)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(BilingualReferencePalette.softYellow)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityIdentifier("production.partnerWard.directChat.pending")
  }

  private var incomingRequestStatePendingSurface: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(bilingualReferenceCopy(.productionDirectChatIncomingTitle, language: language))
        .font(.subheadline.weight(.bold))
      Text(bilingualReferenceCopy(.productionDirectChatIncomingBody, language: language))
        .font(.subheadline)
        .foregroundStyle(BilingualReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        refreshDirectChatAccess()
      } label: {
        Text(bilingualReferenceCopy(.productionRefresh, language: language))
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(BilingualReferenceSecondaryButtonStyle())
      .accessibilityIdentifier("production.partnerWard.directChat.incoming.refresh")
    }
    .padding(15)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(BilingualReferencePalette.softYellow)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityIdentifier("production.partnerWard.directChat.incomingPending")
  }

  private var acceptedRequestSurface: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(bilingualReferenceCopy(.productionDirectChatAccepted, language: language))
        .font(.subheadline.weight(.semibold))
      Button {
        refreshDirectChatAccess()
      } label: {
        Text(bilingualReferenceCopy(.productionRefresh, language: language))
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(BilingualReferenceSecondaryButtonStyle())
      .accessibilityIdentifier("production.partnerWard.directChat.accepted.refresh")
    }
    .padding(15)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(BilingualReferencePalette.softYellow)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityIdentifier("production.partnerWard.directChat.accepted")
  }

  private func terminalRequestSurface(
    detail: BilingualReferenceCopyKey,
    identifier: String
  ) -> some View {
    Text(bilingualReferenceCopy(detail, language: language))
      .font(.subheadline)
      .foregroundStyle(BilingualReferencePalette.muted)
      .fixedSize(horizontal: false, vertical: true)
      .padding(15)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(BilingualReferencePalette.field)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .accessibilityIdentifier(identifier)
  }

  @ViewBuilder
  private var incomingRequestSurface: some View {
    if let request = matchingRequest {
      let isActing = requestsStore?.actionRequestIDs.contains(request.id) == true
      VStack(alignment: .leading, spacing: 12) {
        Text(bilingualReferenceCopy(.productionDirectChatIncomingTitle, language: language))
          .font(.subheadline.weight(.bold))
        Text(bilingualReferenceCopy(.productionDirectChatIncomingBody, language: language))
          .font(.subheadline)
          .foregroundStyle(BilingualReferencePalette.muted)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
          Button {
            respondToRequest(request, action: .decline)
          } label: {
            Text(bilingualReferenceCopy(.productionDirectChatDecline, language: language))
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(BilingualReferenceSecondaryButtonStyle())
          .disabled(isActing)
          .accessibilityIdentifier("production.partnerWard.directChat.decline")

          Button {
            respondToRequest(request, action: .accept)
          } label: {
            HStack(spacing: 6) {
              if isActing { ProgressView().tint(BilingualReferencePalette.ink) }
              Text(bilingualReferenceCopy(.productionDirectChatAccept, language: language))
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(BilingualReferencePrimaryButtonStyle())
          .disabled(isActing)
          .accessibilityIdentifier("production.partnerWard.directChat.accept")
        }
        if requestsStore?.actionErrors[request.id] != nil {
          Text(
            bilingualReferenceCopy(.productionDirectChatError, language: language)
          )
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
          .accessibilityIdentifier("production.partnerWard.directChat.actionError")
        }
      }
      .padding(15)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(BilingualReferencePalette.softYellow)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .accessibilityIdentifier("production.partnerWard.directChat.incoming")
    }
  }

  @ViewBuilder
  private var partnerActions: some View {
    VStack(spacing: 10) {
      if nativeIntegration.matchSafety != nil {
        Button {
          presentedFeature = BilingualProductionFeaturePresentation(kind: .safety)
        } label: {
          Label(
            bilingualReferenceCopy(.productionReportBlock, language: language),
            systemImage: "exclamationmark.shield"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
      }
      if nativeIntegration.meetupForMatch != nil {
        Button {
          presentedFeature = BilingualProductionFeaturePresentation(kind: .meetup)
        } label: {
          Label(
            bilingualReferenceCopy(.productionPlanMeetup, language: language),
            systemImage: "calendar"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
      }
    }
  }

  @ViewBuilder
  private var conversationComposer: some View {
    switch mode {
    case .ward:
      if store.canSendMessage {
        wardComposer
      }
    case .you:
      if let directChatStore,
        let activeChat = matchingDirectChat,
        bilingualProductionHumanComposerIsEnabled(
          mode: mode,
          activeChat: activeChat,
          matchID: matchID,
          storeCanSend: directChatStore.canSendMessage
        )
      {
        humanComposer(directChatStore, partnerName: localizedPartnerName(activeChat.partner?.nickname))
      } else {
        humanComposerLocked
      }
    }
  }

  private var wardComposer: some View {
    compactComposerSurface {
      composerModeSelector
      HStack(alignment: .bottom, spacing: 8) {
        TextField(
          bilingualReferenceCopy(.productionAIComposerPlaceholder, language: language),
          text: $wardDraft,
          axis: .vertical
        )
        .lineLimit(1...4)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(BilingualReferencePalette.field)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel(bilingualReferenceCopy(.productionPartnerWard, language: language))
        .accessibilityIdentifier("production.partnerWard.composer")

        Button {
          let value = wardDraft
          Task {
            await store.sendMessage(value).value
            if store.lastSentMessageID != nil, wardDraft == value { wardDraft = "" }
          }
        } label: {
          if store.isSending {
            ProgressView().tint(BilingualReferencePalette.ink)
          } else {
            Image(systemName: "arrow.up")
              .font(.headline.weight(.bold))
          }
        }
        .frame(width: 46, height: 46)
        .background(BilingualReferencePalette.yellow)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(
          store.isSending
            || wardDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || wardDraft.count > 2_000
        )
        .accessibilityLabel(bilingualReferenceCopy(.wordsComposerSend, language: language))
        .accessibilityIdentifier("production.partnerWard.send")
      }
      composerCount(wardDraft.count, limit: 2_000)
      if store.sendError != nil {
        BilingualProductionInlineNotice(
          language: language,
          title: .productionMatchDetailError,
          detail: .productionDetailPlaceholder,
          identifier: "production.partnerWard.sendError"
        )
      }
    }
  }

  private func humanComposer(_ chatStore: DirectChatStore, partnerName: String) -> some View {
    compactComposerSurface {
      composerModeSelector
      HStack(alignment: .bottom, spacing: 8) {
        TextField(
          bilingualReferenceCopy(.productionDirectChatComposerPlaceholder, language: language),
          text: $humanDraft,
          axis: .vertical
        )
        .lineLimit(1...4)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(BilingualReferencePalette.field)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel(partnerName)
        .accessibilityIdentifier("production.partnerWard.humanComposer")

        Button {
          let value = humanDraft
          Task {
            await chatStore.sendMessage(value).value
            if chatStore.lastSentMessageID != nil, humanDraft == value { humanDraft = "" }
          }
        } label: {
          if chatStore.isSending {
            ProgressView().tint(BilingualReferencePalette.ink)
          } else {
            Image(systemName: "arrow.up")
              .font(.headline.weight(.bold))
          }
        }
        .frame(width: 46, height: 46)
        .background(BilingualReferencePalette.yellow)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(
          chatStore.isSending
            || humanDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || humanDraft.count > 1_000
        )
        .accessibilityLabel(bilingualReferenceCopy(.productionDirectChatSend, language: language))
        .accessibilityIdentifier("production.partnerWard.humanSend")
      }
      composerCount(humanDraft.count, limit: 1_000)
      if chatStore.sendError != nil {
        BilingualProductionInlineNotice(
          language: language,
          title: .productionDirectChat,
          detail: .productionDirectChatError,
          identifier: "production.partnerWard.humanSendError"
        )
      }
    }
  }

  private var humanComposerLocked: some View {
    compactComposerSurface {
      composerModeSelector
      HStack(spacing: 8) {
        Image(systemName: "lock.fill")
          .font(.caption.weight(.bold))
          .foregroundStyle(BilingualReferencePalette.muted)
        Text(bilingualReferenceCopy(.productionDirectChatComposerPlaceholder, language: language))
          .font(.subheadline)
          .foregroundStyle(BilingualReferencePalette.muted)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 11)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(BilingualReferencePalette.field)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .accessibilityIdentifier("production.partnerWard.humanComposer.locked")
      Text(bilingualReferenceCopy(.productionDirectChatComposerLocked, language: language))
        .font(.caption)
        .foregroundStyle(BilingualReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
      Text(bilingualReferenceCopy(humanComposerLockedDetail, language: language))
        .font(.caption2)
        .foregroundStyle(BilingualReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var humanComposerLockedDetail: BilingualReferenceCopyKey {
    guard directChatsAPI != nil else { return .productionDirectChatUnavailable }
    guard let chatsStore = directChatsStore,
      let requestsStore,
      chatsStore.phase == .loaded,
      requestsStore.phase == .loaded,
      requestsStore.requestStatePhase == .loaded
    else {
      return .productionLoading
    }
    switch bilingualProductionChatRequestState(
      for: requestsStore.requestState,
      ownerID: ownerID,
      matchID: matchID
    ) {
    case .none:
      return .productionDirectChatRequestBody
    case .outgoingPending:
      return .productionDirectChatPendingBody
    case .incomingPending:
      return .productionDirectChatIncomingBody
    case .accepted:
      return .productionDirectChatAccepted
    case .declined:
      return .productionDirectChatDeclined
    case .expired:
      return .productionDirectChatExpired
    }
  }

  private func compactComposerSurface<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      content()
    }
    .padding(.horizontal, 16)
    .padding(.top, 10)
    .padding(.bottom, 8)
    .frame(maxWidth: 700)
    .frame(maxWidth: .infinity)
    .background(.white)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(BilingualReferencePalette.line)
        .frame(height: 1)
    }
  }

  private func composerCount(_ count: Int, limit: Int) -> some View {
    HStack {
      Text("\(count) / \(limit.formatted())")
        .font(.caption2)
        .foregroundStyle(count > limit ? .red : BilingualReferencePalette.muted)
      Spacer(minLength: 0)
    }
  }

  private func partnerMessageRow(_ message: PartnerFoxMessage, partnerName: String) -> some View {
    let isMine = message.role == .user
    return HStack(alignment: .bottom, spacing: 8) {
      if isMine { Spacer(minLength: 32) }
      VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
        Text(isMine ? bilingualReferenceCopy(.wordsComposerMe, language: language) : partnerName)
          .font(.caption2.weight(.bold))
          .foregroundStyle(BilingualReferencePalette.muted)
        Text(message.content)
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
        Text(message.createdAt, style: .time)
          .font(.caption2)
          .foregroundStyle(BilingualReferencePalette.muted)
      }
      .padding(.horizontal, 13)
      .padding(.vertical, 10)
      .background(isMine ? BilingualReferencePalette.yellow : .white)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      if !isMine { Spacer(minLength: 32) }
    }
    .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
  }

  private func directMessageRow(_ message: DirectChatMessage, partnerName: String) -> some View {
    let isMine = message.isMine
    return HStack(alignment: .bottom, spacing: 8) {
      if isMine { Spacer(minLength: 32) }
      VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
        Text(isMine ? bilingualReferenceCopy(.wordsComposerMe, language: language) : partnerName)
          .font(.caption2.weight(.bold))
          .foregroundStyle(BilingualReferencePalette.muted)
        Text(message.content)
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
        Text(message.createdAt, style: .time)
          .font(.caption2)
          .foregroundStyle(BilingualReferencePalette.muted)
      }
      .padding(.horizontal, 13)
      .padding(.vertical, 10)
      .background(isMine ? BilingualReferencePalette.yellow : .white)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      if !isMine { Spacer(minLength: 32) }
    }
    .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
  }

  private func localizedPartnerName(_ value: String?) -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty, trimmed != "Wingward member" else {
      return bilingualReferenceCopy(.productionMemberFallback, language: language)
    }
    return trimmed
  }

  private func loadDirectChatAccess() async {
    guard let directChatsStore, let requestsStore else { return }
    await directChatsStore.load().value
    await requestsStore.load().value
    await requestsStore.loadRequestState(matchID: matchID).value
    syncDirectChatStore()
  }

  private func refreshDirectChatAccess() {
    Task { await loadDirectChatAccess() }
  }

  private func syncDirectChatStore() {
    guard let activeChat = matchingDirectChat, let directChatsAPI else {
      directChatStore?.cancel()
      directChatStore = nil
      return
    }
    guard directChatStore?.roomID != activeChat.id else { return }
    directChatStore?.cancel()
    let newStore = DirectChatStore(ownerID: ownerID, roomID: activeChat.id, api: directChatsAPI)
    directChatStore = newStore
    Task { await newStore.load().value }
  }

  private func createDirectChatRequest() {
    guard let requestsStore else { return }
    Task {
      await requestsStore.createRequest(matchID: matchID).value
      await loadDirectChatAccess()
    }
  }

  private func respondToRequest(_ request: ChatRequestSummary, action: ChatRequestAction) {
    guard let requestsStore else { return }
    Task {
      await requestsStore.respond(to: request, action: action).value
      await loadDirectChatAccess()
    }
  }

  private func scrollToLatest(_ proxy: ScrollViewProxy) {
    let target: String?
    switch mode {
    case .ward:
      target = store.messages.last.map { "ward-\($0.id.uuidString)" }
    case .you:
      target = directChatStore?.messages.last.map { "direct-\($0.id.uuidString)" }
    }
    guard let target else { return }
    withAnimation(.easeOut(duration: 0.2)) {
      proxy.scrollTo(target, anchor: .bottom)
    }
  }
}

private enum BilingualProductionFeatureKind: String, Identifiable {
  case meetup
  case chatRequest
  case directChats
  case safety

  var id: String { rawValue }
}

private struct BilingualProductionFeaturePresentation: Identifiable {
  let kind: BilingualProductionFeatureKind
  let safetyContext: ReportContext
  var id: String { "\(kind.id)-\(safetyContext.rawValue)" }

  init(kind: BilingualProductionFeatureKind, safetyContext: ReportContext = .match) {
    self.kind = kind
    self.safetyContext = safetyContext
  }
}

private struct BilingualProductionRoutePresentation: Identifiable {
  let route: AppRoute
  var id: String { String(describing: route) }
}

private struct BilingualProductionFeatureDestination: View {
  let presentation: BilingualProductionFeaturePresentation
  let ownerID: String
  let matchID: UUID
  let nativeIntegration: NativeFeatureIntegration
  let language: BilingualReferenceLanguage
  let onDismiss: () -> Void
  let onOpenReportForMatch: (UUID, ReportContext) -> Void
  let onBlocked: () -> Void
  let onBlockNeedsReconciliation: () -> Void
  @State private var showsVerificationUnavailable = false
  @State private var presentedNestedRoute: BilingualProductionRoutePresentation?

  var body: some View {
    Group {
      switch presentation.kind {
      case .directChats:
        if let destination = nativeIntegration.directChats?(
          ownerID,
          NativeFeatureCallbacks(
            onOpenSettings: onDismiss,
            onOpenReportForMatch: onOpenReportForMatch
          )
        ) {
          NavigationStack { destination }
            .environment(\.locale, Locale(identifier: language == .japanese ? "ja" : "en"))
        } else {
          BilingualProductionUnavailableView(
            language: language,
            title: .productionChatLabel,
            detail: .productionFeatureUnavailable
          )
        }
      case .chatRequest:
        if let destination = nativeIntegration.chatRequestForMatch?(
          ownerID,
          matchID,
          NativeFeatureCallbacks(onOpenSettings: onDismiss)
        ) {
          destination
        } else {
          BilingualProductionUnavailableView(
            language: language,
            title: .productionRequestDirectChat,
            detail: .productionFeatureUnavailable
          )
        }
      case .meetup:
        if let destination = nativeIntegration.meetupForMatch?(
          ownerID,
          matchID,
          NativeFeatureCallbacks(
            onOpenSettings: onDismiss,
            onOpenReportForMatch: onOpenReportForMatch,
            onOpenVerification: { showsVerificationUnavailable = true },
            onOpenPaywall: { source in
              presentedNestedRoute = BilingualProductionRoutePresentation(
                route: .paywall(source)
              )
            }
          )
        ) {
          destination
        } else {
          BilingualProductionUnavailableView(
            language: language,
            title: .productionPlanMeetup,
            detail: .productionFeatureUnavailable
          )
        }
      case .safety:
        if let destination = nativeIntegration.matchSafety?(
          ownerID,
          matchID,
          presentation.safetyContext,
          NativeFeatureCallbacks(
            onOpenSettings: onDismiss,
            onBlocked: onBlocked,
            onBlockNeedsReconciliation: onBlockNeedsReconciliation
          )
        ) {
          destination
        } else {
          BilingualProductionUnavailableView(
            language: language,
            title: .productionReportBlock,
            detail: .productionFeatureUnavailable
          )
        }
      }
    }
    .background(BilingualReferencePalette.cream.ignoresSafeArea())
    .alert(
      bilingualReferenceCopy(.productionFeatureUnavailable, language: language),
      isPresented: $showsVerificationUnavailable
    ) {
      Button(bilingualReferenceCopy(.productionClose, language: language), role: .cancel) {}
    } message: {
      Text(
        bilingualReferenceCopy(.productionIdentityVerificationUnavailable, language: language)
      )
      .accessibilityIdentifier("production.meetup.verificationUnavailable")
    }
    .sheet(item: $presentedNestedRoute) { nested in
      BilingualProductionRouteDestination(
        ownerID: ownerID,
        route: nested.route,
        integration: nativeIntegration,
        language: language,
        onBlocked: onBlocked,
        onBlockNeedsReconciliation: onBlockNeedsReconciliation
      )
    }
  }
}

private struct BilingualProductionRouteDestination: View {
  let ownerID: String
  let route: AppRoute
  let integration: NativeFeatureIntegration
  let language: BilingualReferenceLanguage
  let onBlocked: () -> Void
  let onBlockNeedsReconciliation: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var pendingSafetyRequest: BilingualProductionRouteSafetyRequest?
  @State private var presentedNestedRoute: BilingualProductionRoutePresentation?
  @State private var showsVerificationUnavailable = false

  var body: some View {
    ZStack {
      BilingualReferencePalette.cream.ignoresSafeArea()
      if let destination = integration.routeView(
        route,
        ownerID: ownerID,
        callbacks: NativeFeatureCallbacks(
          onOpenSettings: dismissRoute,
          onOpenReport: { targetID, context in
            pendingSafetyRequest = BilingualProductionRouteSafetyRequest(
              target: .user(targetID),
              context: context
            )
          },
          onOpenReportForMatch: { matchID, context in
            pendingSafetyRequest = BilingualProductionRouteSafetyRequest(
              target: .match(matchID),
              context: context
            )
          },
          onOpenMeetup: { meetupID in
            presentedNestedRoute = BilingualProductionRoutePresentation(
              route: .meetup(meetupID)
            )
          },
          onBlocked: {
            onBlocked()
            dismissRoute()
          },
          onOpenVerification: { showsVerificationUnavailable = true },
          onOpenPaywall: { source in
            presentedNestedRoute = BilingualProductionRoutePresentation(
              route: .paywall(source)
            )
          },
          onBlockNeedsReconciliation: {
            onBlockNeedsReconciliation()
            dismissRoute()
          }
        )
      ) {
        BilingualProductionNativeFeatureHost(
          language: language,
          title: routeTitle,
          destination: destination
        )
      } else {
        BilingualProductionUnavailableView(
          language: language,
          title: .productionFeatureUnavailable,
          detail: .productionDetailPlaceholder
        )
      }
    }
    .alert(
      bilingualReferenceCopy(.productionFeatureUnavailable, language: language),
      isPresented: $showsVerificationUnavailable
    ) {
      Button(bilingualReferenceCopy(.productionClose, language: language), role: .cancel) {}
    } message: {
      Text(
        bilingualReferenceCopy(.productionIdentityVerificationUnavailable, language: language)
      )
      .accessibilityIdentifier("production.route.verificationUnavailable")
    }
    .sheet(item: $presentedNestedRoute) { nested in
      BilingualProductionRouteDestination(
        ownerID: ownerID,
        route: nested.route,
        integration: integration,
        language: language,
        onBlocked: onBlocked,
        onBlockNeedsReconciliation: onBlockNeedsReconciliation
      )
    }
    .sheet(item: $pendingSafetyRequest) { request in
      safetyDestination(for: request)
    }
  }

  @ViewBuilder
  private func safetyDestination(
    for request: BilingualProductionRouteSafetyRequest
  ) -> some View {
    switch request.target {
    case let .user(targetID):
      if let destination = integration.safetyAction?(
        ownerID,
        targetID,
        request.context,
        nil
      ) {
        BilingualProductionNativeFeatureHost(
          language: language,
          title: .productionReportBlock,
          destination: destination
        )
      } else {
        BilingualProductionUnavailableView(
          language: language,
          title: .productionReportBlock,
          detail: .productionFeatureUnavailable
        )
      }
    case let .match(matchID):
      if let destination = integration.matchSafety?(
        ownerID,
        matchID,
        request.context,
        NativeFeatureCallbacks(
          onBlocked: {
            onBlocked()
            dismissRoute()
          },
          onBlockNeedsReconciliation: {
            onBlockNeedsReconciliation()
            dismissRoute()
          }
        )
      ) {
        BilingualProductionNativeFeatureHost(
          language: language,
          title: .productionReportBlock,
          destination: destination
        )
      } else {
        BilingualProductionUnavailableView(
          language: language,
          title: .productionReportBlock,
          detail: .productionFeatureUnavailable
        )
      }
    }
  }

  private func dismissRoute() {
    pendingSafetyRequest = nil
    dismiss()
  }

  private var routeTitle: BilingualReferenceCopyKey {
    switch route {
    case .matches:
      return .wordsTitle
    case .matchDetail:
      return .productionMatchDetailTitle
    case .foxConversation, .foxConversationResult:
      return .productionWardHistory
    case .partnerFoxChat:
      return .productionPartnerWard
    case .directChat:
      return .productionDirectChat
    case .report:
      return .productionReportBlock
    case .paywall:
      return .youPlanPayments
    case .meetup, .meetupVerification, .meetupFeedback, .meetupResult, .availability:
      return .productionPlanMeetup
    case .chatRequest:
      return .productionRequestDirectChat
    case .foxLearned:
      return .youAnalysisTitle
    case .notificationLanding:
      return .youNotifications
    case .authentication, .ageGate, .onboarding, .settings:
      return .productionFeatureUnavailable
    }
  }
}

private struct BilingualProductionRouteSafetyRequest: Identifiable {
  enum Target {
    case user(UUID)
    case match(UUID)
  }

  let target: Target
  let context: ReportContext

  var id: String {
    switch target {
    case let .user(targetID):
      return "user-\(targetID.uuidString)-\(context.rawValue)"
    case let .match(matchID):
      return "match-\(matchID.uuidString)-\(context.rawValue)"
    }
  }
}

/// Live onboarding settings. Every control writes through the existing
/// owner-bound store; this view never treats a local selection as a completed
/// profile until the server confirms the save.
struct BilingualProductionOnboardingView: View {
  let controller: AuthSessionController
  let ownerID: String
  let api: any OnboardingSettingsAPI
  let language: BilingualReferenceLanguage
  let quizAPIFactory: (any QuizAPIFactory)?
  let nativeIntegration: NativeFeatureIntegration
  let onLanguageChange: (BilingualReferenceLanguage) -> Void
  let onCompleted: () -> Void

  @State private var store: OnboardingSettingsStore
  @State private var presentedNativeFeature: BilingualProductionNativeFeature?

  init(
    controller: AuthSessionController,
    ownerID: String,
    api: any OnboardingSettingsAPI,
    language: BilingualReferenceLanguage,
    quizAPIFactory: (any QuizAPIFactory)? = nil,
    nativeIntegration: NativeFeatureIntegration = .unavailable,
    onLanguageChange: @escaping (BilingualReferenceLanguage) -> Void = { _ in },
    onCompleted: @escaping () -> Void = {}
  ) {
    self.controller = controller
    self.ownerID = ownerID
    self.api = api
    self.language = language
    self.quizAPIFactory = quizAPIFactory
    self.nativeIntegration = nativeIntegration
    self.onLanguageChange = onLanguageChange
    self.onCompleted = onCompleted
    _store = State(initialValue: OnboardingSettingsStore(ownerID: ownerID, api: api))
  }

  var body: some View {
    NavigationStack {
      ZStack {
        BilingualReferencePalette.cream.ignoresSafeArea()
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            header
            content
          }
          .frame(maxWidth: 720, alignment: .leading)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 20)
          .padding(.top, 22)
          .padding(.bottom, 34)
        }
        .scrollIndicators(.hidden)
      }
      .navigationTitle(bilingualReferenceCopy(.productionProfileTitle, language: language))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(bilingualReferenceCopy(.productionSignOut, language: language)) {
            Task { await controller.signOut() }
          }
          .disabled(controller.isSubmitting)
          .accessibilityIdentifier("production.onboarding.signOut")
        }
      }
    }
    .foregroundStyle(BilingualReferencePalette.ink)
    .tint(BilingualReferencePalette.ink)
    .background(BilingualReferencePalette.cream.ignoresSafeArea())
    .preferredColorScheme(.light)
    .task(id: ownerID) {
      await store.load().value
    }
    .onDisappear { store.cancel() }
    .sheet(item: $presentedNativeFeature) { feature in
      BilingualProductionNativeFeatureDestination(
        feature: feature,
        ownerID: ownerID,
        language: language,
        onLanguageChange: onLanguageChange,
        quizAPIFactory: quizAPIFactory,
        nativeIntegration: nativeIntegration,
        controller: controller,
        onDismiss: { presentedNativeFeature = nil },
        onQuizSaved: { presentedNativeFeature = .voice }
      )
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      BilingualReferenceSectionLabel(
        text: bilingualReferenceCopy(.productionOnboardingKicker, language: language)
      )
      Text(bilingualReferenceCopy(.productionOnboardingTitle, language: language))
        .font(.system(size: 34, weight: .bold, design: .rounded))
        .tracking(-1.1)
        .lineSpacing(2)
      Text(bilingualReferenceCopy(.productionOnboardingBody, language: language))
        .font(.subheadline)
        .foregroundStyle(BilingualReferencePalette.muted)
        .lineSpacing(5)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch store.phase {
    case .idle, .loading:
      BilingualProductionLoadingCard(
        language: language,
        detail: .productionOnboardingLoading,
        identifier: "production.onboarding.loading"
      )
    case let .failed(error):
      VStack(alignment: .leading, spacing: 12) {
        BilingualProductionErrorCard(
          language: language,
          title: .productionOnboardingError,
          retry: { Task { await store.retry().value } },
          identifier: "production.onboarding.retry"
        )
        Text(onboardingErrorCopy(error))
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
      }
    case .loaded, .saving:
      settingsSurface
    }
  }

  private var settingsSurface: some View {
    VStack(alignment: .leading, spacing: 14) {
      settingsSection(.productionOnboardingDisplayLanguage) {
        choiceButton(
          title: bilingualReferenceCopy(.languageJapanese, language: language),
          selected: store.draft.uiLocale == .ja,
          identifier: "production.onboarding.uiLanguage.ja"
        ) { store.setUILocale(.ja) }
        choiceButton(
          title: bilingualReferenceCopy(.languageEnglish, language: language),
          selected: store.draft.uiLocale == .en,
          identifier: "production.onboarding.uiLanguage.en"
        ) { store.setUILocale(.en) }
      }

      settingsSection(.productionOnboardingConversationLanguage) {
        choiceButton(
          title: bilingualReferenceCopy(.languageJapanese, language: language),
          selected: store.draft.conversationLanguage == .ja,
          identifier: "production.onboarding.conversationLanguage.ja"
        ) { store.setConversationLanguage(.ja) }
        choiceButton(
          title: bilingualReferenceCopy(.languageEnglish, language: language),
          selected: store.draft.conversationLanguage == .en,
          identifier: "production.onboarding.conversationLanguage.en"
        ) { store.setConversationLanguage(.en) }
      }

      settingsSection(.productionOnboardingMarket) {
        choiceButton(
          title: bilingualReferenceCopy(.productionMarketJapan, language: language),
          selected: store.draft.datingMarket == .JP,
          identifier: "production.onboarding.market.jp"
        ) { store.setDatingMarket(.JP) }
        choiceButton(
          title: bilingualReferenceCopy(.productionMarketUS, language: language),
          selected: store.draft.datingMarket == .US,
          identifier: "production.onboarding.market.us"
        ) { store.setDatingMarket(.US) }
      }

      settingsSection(.productionOnboardingTimezone) {
        Picker(
          bilingualReferenceCopy(.productionOnboardingTimezone, language: language),
          selection: Binding(
            get: { store.draft.timezone ?? "" },
            set: { if !$0.isEmpty { store.setTimezone($0) } }
          )
        ) {
          Text(bilingualReferenceCopy(.productionLocationNotSet, language: language))
            .tag("")
          ForEach(OnboardingTimeZoneCatalog.choices(including: store.draft.timezone), id: \.self) { value in
            Text(value).tag(value)
          }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .background(BilingualReferencePalette.field)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("production.onboarding.timezone")
      }

      settingsSection(.productionOnboardingDistance) {
        choiceButton(
          title: bilingualReferenceCopy(.productionDistanceKilometers, language: language),
          selected: store.draft.distanceUnit == .km,
          identifier: "production.onboarding.distance.km"
        ) { store.setDistanceUnit(.km) }
        choiceButton(
          title: bilingualReferenceCopy(.productionDistanceMiles, language: language),
          selected: store.draft.distanceUnit == .mi,
          identifier: "production.onboarding.distance.mi"
        ) { store.setDistanceUnit(.mi) }
      }

      settingsSection(.productionOnboardingIdentity) {
        choiceButton(
          title: bilingualReferenceCopy(.productionIdentityWoman, language: language),
          selected: store.draft.genderIdentity == .selected(.woman),
          identifier: "production.onboarding.identity.woman"
        ) { store.setGenderIdentity(.selected(.woman)) }
        choiceButton(
          title: bilingualReferenceCopy(.productionIdentityMan, language: language),
          selected: store.draft.genderIdentity == .selected(.man),
          identifier: "production.onboarding.identity.man"
        ) { store.setGenderIdentity(.selected(.man)) }
        choiceButton(
          title: bilingualReferenceCopy(.productionIdentityNonbinary, language: language),
          selected: store.draft.genderIdentity == .selected(.nonbinary),
          identifier: "production.onboarding.identity.nonbinary"
        ) { store.setGenderIdentity(.selected(.nonbinary)) }
        choiceButton(
          title: bilingualReferenceCopy(.productionIdentityNoAnswer, language: language),
          selected: store.draft.genderIdentity == .noAnswer,
          identifier: "production.onboarding.identity.noAnswer"
        ) { store.setGenderIdentity(.noAnswer) }
      }

      settingsSection(.productionOnboardingPreferences) {
        choiceButton(
          title: bilingualReferenceCopy(.productionPreferenceSelected, language: language),
          selected: store.draft.preferenceMode == .selected,
          identifier: "production.onboarding.preference.selected"
        ) { store.setPreferenceMode(.selected) }
        if store.draft.preferenceMode == .selected {
          ForEach(OnboardingGenderCategory.allCases, id: \.self) { value in
            choiceButton(
              title: genderCopy(value),
              selected: store.draft.preferredGenders.contains(value),
              identifier: "production.onboarding.preference.\(value.rawValue)"
            ) { store.togglePreferredGender(value) }
          }
        }
        choiceButton(
          title: bilingualReferenceCopy(.productionPreferenceNoAnswer, language: language),
          selected: store.draft.preferenceMode == .noAnswer,
          identifier: "production.onboarding.preference.noAnswer"
        ) { store.setPreferenceMode(.noAnswer) }
      }

      settingsSection(.productionOnboardingLocation) {
        choiceButton(
          title: bilingualReferenceCopy(.productionLocationNotSet, language: language),
          selected: store.draft.locationMode == .notSet,
          identifier: "production.onboarding.location.notSet"
        ) { store.setLocationMode(.notSet) }
        if store.draft.datingMarket == .US {
          choiceButton(
            title: bilingualReferenceCopy(.productionLocationNoTransit, language: language),
            selected: store.draft.locationMode == .noTransit,
            identifier: "production.onboarding.location.noTransit"
          ) {
            store.setLocationMode(.noTransit)
          }
        }
        choiceButton(
          title: bilingualReferenceCopy(.productionLocationStation, language: language),
          selected: store.draft.locationMode == .station,
          identifier: "production.onboarding.location.station"
        ) { store.setLocationMode(.station) }

        if store.draft.locationMode == .station || store.draft.locationMode == .noTransit {
          if let options = store.options {
            Picker(
              bilingualReferenceCopy(.productionOnboardingArea, language: language),
              selection: Binding(
                get: { store.draft.coarseAreaID ?? "" },
                set: { store.setCoarseAreaID($0.isEmpty ? nil : $0) }
              )
            ) {
              Text(bilingualReferenceCopy(.productionLocationNotSet, language: language)).tag("")
              ForEach(options.areas, id: \.id) { area in
                Text(area.name).tag(area.id)
              }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .background(BilingualReferencePalette.field)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("production.onboarding.area")

            if store.draft.locationMode == .station {
              Picker(
                bilingualReferenceCopy(.productionOnboardingStation, language: language),
                selection: Binding(
                  get: { store.draft.stationID ?? "" },
                  set: { store.setStationID($0.isEmpty ? nil : $0) }
                )
              ) {
                Text(bilingualReferenceCopy(.productionLocationNotSet, language: language)).tag("")
                ForEach(options.stations, id: \.id) { station in
                  Text(station.name).tag(station.id)
                }
              }
              .pickerStyle(.menu)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 14)
              .frame(minHeight: 50)
              .background(BilingualReferencePalette.field)
              .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
              .accessibilityIdentifier("production.onboarding.station")
            }
          } else {
            locationOptionsStatus
          }
        }
      }

      if let validationError = store.validationError {
        Text(onboardingIssueCopy(validationError))
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
          .accessibilityIdentifier("production.onboarding.validationError")
      }
      if store.saveError != nil {
        Text(bilingualReferenceCopy(.productionOnboardingNotSaved, language: language))
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
          .accessibilityIdentifier("production.onboarding.saveError")
      }
      if store.didConfirmSave {
        Text(bilingualReferenceCopy(.productionOnboardingSaved, language: language))
          .font(.caption.weight(.semibold))
          .foregroundStyle(BilingualReferencePalette.green)
          .accessibilityIdentifier("production.onboarding.saved")
      }

      Button {
        Task {
          await store.save().value
          if store.didConfirmSave { onCompleted() }
        }
      } label: {
        HStack(spacing: 8) {
          if store.isSaving { ProgressView().tint(BilingualReferencePalette.ink) }
          Text(bilingualReferenceCopy(.productionOnboardingSave, language: language))
        }
      }
      .buttonStyle(BilingualReferencePrimaryButtonStyle())
      .disabled(!store.canSave)
      .accessibilityIdentifier("production.onboarding.save")

      featureLinks
    }
  }

  private var locationOptionsStatus: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        bilingualReferenceCopy(
          store.optionsError == nil
            ? .productionOnboardingOptionsLoading
            : .productionOnboardingOptionsUnavailable,
          language: language
        )
      )
      .font(.caption)
      .foregroundStyle(BilingualReferencePalette.muted)
      .accessibilityIdentifier("production.onboarding.optionsStatus")

      if store.optionsError != nil {
        Button(bilingualReferenceCopy(.productionRetry, language: language)) {
          guard let task = store.retryOptions() else { return }
          Task { await task.value }
        }
        .buttonStyle(BilingualReferencePrimaryButtonStyle())
        .disabled(store.isBusy)
        .accessibilityIdentifier("production.onboarding.optionsRetry")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var featureLinks: some View {
    VStack(alignment: .leading, spacing: 12) {
      BilingualReferenceSectionLabel(
        text: bilingualReferenceCopy(.productionProfileTitle, language: language)
      )
      Button {
        presentedNativeFeature = .quiz
      } label: {
        featureLinkLabel(title: .productionQuizTitle, body: .productionQuizBody, symbol: "checklist")
      }
      .buttonStyle(.plain)
      .disabled(quizAPIFactory == nil)
      .accessibilityIdentifier("production.onboarding.quiz")

      Button {
        presentedNativeFeature = .voice
      } label: {
        featureLinkLabel(title: .productionVoiceTitle, body: .productionVoiceBody, symbol: "waveform")
      }
      .buttonStyle(.plain)
      .disabled(nativeIntegration.voiceProfile == nil)
      .accessibilityIdentifier("production.onboarding.voice")

      Button {
        presentedNativeFeature = .watercolorProfile
      } label: {
        featureLinkLabel(
          title: .productionWatercolorTitle,
          body: .productionWatercolorBody,
          symbol: "paintbrush.pointed.fill"
        )
      }
      .buttonStyle(.plain)
      .disabled(nativeIntegration.profilePhoto == nil)
      .accessibilityIdentifier("production.onboarding.watercolorProfile")
    }
  }

  private func settingsSection<Content: View>(
    _ title: BilingualReferenceCopyKey,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(bilingualReferenceCopy(title, language: language))
        .font(.headline.weight(.bold))
      content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
  }

  private func choiceButton(
    title: String,
    selected: Bool,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Text(title)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 8)
        if selected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(BilingualReferencePalette.green)
            .accessibilityHidden(true)
        }
      }
      .font(.body.weight(selected ? .semibold : .regular))
      .foregroundStyle(BilingualReferencePalette.ink)
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
      .background(selected ? BilingualReferencePalette.softYellow : BilingualReferencePalette.field)
      .overlay {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
          .stroke(selected ? BilingualReferencePalette.yellow : BilingualReferencePalette.line, lineWidth: selected ? 1.5 : 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func featureLinkLabel(
    title: BilingualReferenceCopyKey,
    body: BilingualReferenceCopyKey,
    symbol: String
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.headline.weight(.bold))
        .frame(width: 38, height: 38)
        .background(BilingualReferencePalette.softYellow)
        .clipShape(Circle())
      VStack(alignment: .leading, spacing: 3) {
        Text(bilingualReferenceCopy(title, language: language))
          .font(.subheadline.weight(.bold))
        Text(bilingualReferenceCopy(body, language: language))
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.caption.weight(.bold))
        .foregroundStyle(BilingualReferencePalette.muted)
    }
    .padding(13)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(BilingualReferencePalette.field)
    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
  }

  private func genderCopy(_ value: OnboardingGenderCategory) -> String {
    switch value {
    case .woman: return bilingualReferenceCopy(.productionIdentityWoman, language: language)
    case .man: return bilingualReferenceCopy(.productionIdentityMan, language: language)
    case .nonbinary: return bilingualReferenceCopy(.productionIdentityNonbinary, language: language)
    }
  }

  private func onboardingIssueCopy(_ issue: OnboardingSettingsDraftIssue) -> String {
    switch issue {
    case .uiLocaleRequired: return bilingualReferenceCopy(.productionOnboardingDisplayLanguage, language: language)
    case .conversationLanguageRequired: return bilingualReferenceCopy(.productionOnboardingConversationLanguage, language: language)
    case .datingMarketRequired: return bilingualReferenceCopy(.productionOnboardingMarket, language: language)
    case .timezoneRequired: return bilingualReferenceCopy(.productionOnboardingTimezone, language: language)
    case .distanceUnitRequired: return bilingualReferenceCopy(.productionOnboardingDistance, language: language)
    case .genderIdentityRequired: return bilingualReferenceCopy(.productionOnboardingIdentity, language: language)
    case .preferenceModeRequired, .preferredGendersRequired: return bilingualReferenceCopy(.productionOnboardingPreferences, language: language)
    case .locationModeRequired, .stationRequired, .areaRequired: return bilingualReferenceCopy(.productionOnboardingLocation, language: language)
    case .invalidSettings: return bilingualReferenceCopy(.productionOnboardingNotSaved, language: language)
    }
  }

  private func onboardingErrorCopy(_ error: OnboardingSettingsStoreError) -> String {
    switch error {
    case .ageVerificationRequired: return bilingualReferenceCopy(.productionDetailPlaceholder, language: language)
    default: return bilingualReferenceCopy(.productionOnboardingError, language: language)
    }
  }
}

private enum BilingualProductionNativeFeature: String, Identifiable {
  case quiz
  case voice
  case watercolorProfile

  var id: String { rawValue }
}

private struct BilingualProductionNativeFeatureDestination: View {
  let feature: BilingualProductionNativeFeature
  let ownerID: String
  let language: BilingualReferenceLanguage
  let onLanguageChange: (BilingualReferenceLanguage) -> Void
  let quizAPIFactory: (any QuizAPIFactory)?
  let nativeIntegration: NativeFeatureIntegration
  let controller: AuthSessionController
  let onDismiss: () -> Void
  var onQuizSaved: (() -> Void)? = nil

  var body: some View {
    switch feature {
    case .quiz:
      if let api = quizAPIFactory?.make(ownerID: ownerID) {
        BilingualProductionNativeFeatureHost(
          language: language,
          title: .productionQuizTitle,
          destination: AnyView(
            QuizView(
              ownerID: ownerID,
              api: api,
              locale: language == .japanese ? .ja : .en,
              onDismiss: onDismiss,
              onSaved: onQuizSaved
            )
          )
        )
      } else {
        BilingualProductionUnavailableView(
          language: language,
          title: .productionQuizTitle,
          detail: .productionFeatureUnavailable
        )
      }
    case .voice:
      if let destination = nativeIntegration.ownerView(
        nativeIntegration.voiceProfile,
        ownerID: ownerID,
        callbacks: NativeFeatureCallbacks(onOpenSettings: onDismiss)
      ) {
        BilingualProductionNativeFeatureHost(
          language: language,
          title: .productionVoiceTitle,
          destination: destination,
          onLanguageChange: onLanguageChange
        )
      } else {
        BilingualProductionUnavailableView(
          language: language,
          title: .productionVoiceTitle,
          detail: .productionFeatureUnavailable
        )
      }
    case .watercolorProfile:
      nativeDestination(
        factory: nativeIntegration.profilePhoto,
        title: .productionWatercolorTitle
      )
    }
  }

  @ViewBuilder
  private func nativeDestination(
    factory: NativeFeatureIntegration.OwnerViewFactory?,
    title: BilingualReferenceCopyKey
  ) -> some View {
    if let destination = nativeIntegration.ownerView(
      factory,
      ownerID: ownerID,
      callbacks: NativeFeatureCallbacks(onOpenSettings: onDismiss)
    ) {
      BilingualProductionNativeFeatureHost(
        language: language,
        title: title,
        destination: destination
      )
    } else {
      BilingualProductionUnavailableView(
        language: language,
        title: title,
        detail: .productionFeatureUnavailable
      )
    }
  }
}

private struct BilingualProductionNativeFeatureHost: View {
  let language: BilingualReferenceLanguage
  let title: BilingualReferenceCopyKey
  let destination: AnyView
  var onLanguageChange: ((BilingualReferenceLanguage) -> Void)? = nil

  var body: some View {
    ZStack {
      BilingualReferencePalette.cream.ignoresSafeArea()
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          BilingualReferenceSectionLabel(text: bilingualReferenceCopy(title, language: language))
          Spacer()
          if let onLanguageChange {
            Button(language == .japanese ? "English" : "日本語") {
              onLanguageChange(language == .japanese ? .english : .japanese)
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("production.voice.displayLanguageToggle")
          }
        }
        destination
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 20)
      .padding(.top, 20)
      .padding(.bottom, 24)
    }
    .foregroundStyle(BilingualReferencePalette.ink)
    .environment(
      \.locale,
      Locale(identifier: language == .japanese ? "ja" : "en")
    )
    .navigationTitle(bilingualReferenceCopy(title, language: language))
    .navigationBarTitleDisplayMode(.inline)
    .preferredColorScheme(.light)
  }
}

private struct BilingualProductionHelpView: View {
  let language: BilingualReferenceLanguage

  private var isJapanese: Bool { language == .japanese }

  var body: some View {
    ZStack {
      BilingualReferencePalette.cream.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          BilingualReferenceSectionLabel(text: isJapanese ? "ヘルプ" : "HELP")
          Text(isJapanese ? "この画面でできること" : "Using WingWard")
            .font(.title2.weight(.bold))

          section(
            title: isJapanese ? "マッチング設定" : "Matching settings",
            detail: isJapanese
              ? "設定を開き、内容を確認してから保存してください。読み込みや保存に失敗したときは、画面の再試行を使ってください。"
              : "Open matching settings and save after reviewing your choices. Use the on-screen retry if loading or saving fails."
          )
          section(
            title: isJapanese ? "購入を復元" : "Restore purchases",
            detail: isJapanese
              ? "プランと支払いを開き、購入時と同じAppleアカウントで「購入を復元」を押してください。利用状況はサーバー確認後に反映されます。"
              : "Open Plan & Payments and choose Restore purchases while signed in to the same Apple Account used to buy. Access changes only after the server confirms it."
          )
          section(
            title: isJapanese ? "プランの解約" : "Cancel a plan",
            detail: isJapanese
              ? "Appleで購入したプランはAppleアカウントで管理・解約します。更新日と解約後の扱いはAppleの画面で確認してください。"
              : "Manage or cancel plans purchased through Apple in your Apple Account. Check Apple's screen for renewal dates and cancellation timing."
          )
          Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
            Text(isJapanese ? "Appleのサブスクリプションを開く" : "Open Apple Subscriptions")
              .font(.subheadline.weight(.semibold))
              .underline()
          }
          .accessibilityIdentifier("production.you.help.appleSubscriptions")

          section(
            title: isJapanese ? "通報・ブロック" : "Reports and blocks",
            detail: isJapanese
              ? "通報やブロックは、相手のプロフィールなどのパートナー画面から利用できます。"
              : "Reports and blocks are available from partner surfaces such as a person's profile."
          )
          section(
            title: isJapanese ? "アカウント削除" : "Delete your account",
            detail: isJapanese
              ? "プライバシーと安全から削除を選び、確認してください。サーバーから完了の確認が届くまで、削除は完了していません。"
              : "Choose Delete account under Privacy & Safety and confirm. Deletion is confirmed only after the server responds."
          )
          section(
            title: isJapanese ? "規約・プライバシー・お問い合わせ" : "Terms, privacy, and support",
            detail: isJapanese
              ? "このビルドでは、公開済みの利用規約・プライバシーポリシーURLと、お問い合わせ先は設定されていません。プライバシー権利の申請窓口も未設定です。"
              : "This build has no published Terms or Privacy Policy URL and no support contact configured. A channel for privacy-rights requests is also not set up."
          )
        }
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
      }
    }
    .foregroundStyle(BilingualReferencePalette.ink)
    .tint(BilingualReferencePalette.ink)
    .navigationTitle(isJapanese ? "ヘルプ" : "Help")
    .navigationBarTitleDisplayMode(.inline)
    .preferredColorScheme(.light)
    .accessibilityIdentifier("production.you.help")
  }

  private func section(title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline.weight(.bold))
      Text(detail)
        .font(.subheadline)
        .foregroundStyle(BilingualReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

private struct BilingualProductionAccountPortrait: View {
  let language: BilingualReferenceLanguage
  let size: CGFloat
  let avatarURL: URL?
  let usesFixtureFallback: Bool

  var body: some View {
    Group {
      if let avatarURL {
        AsyncImage(url: avatarURL) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          fallback
        }
      } else {
        fallback
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay { Circle().stroke(.white, lineWidth: 3) }
    .shadow(color: BilingualReferencePalette.ink.opacity(0.08), radius: 5, y: 2)
    .accessibilityLabel(bilingualReferenceCopy(.youPortraitLabel, language: language))
    .accessibilityIdentifier("production.you.avatar")
  }

  @ViewBuilder
  private var fallback: some View {
    if usesFixtureFallback {
      Image("mio-watercolor")
        .resizable()
        .scaledToFill()
    } else {
      ZStack {
        Circle().fill(BilingualReferencePalette.field)
        Image(systemName: "person.fill")
          .font(.system(size: size * 0.43))
          .foregroundStyle(BilingualReferencePalette.muted)
      }
    }
  }
}

struct BilingualProductionProfileAvatarState: Equatable {
  private(set) var ownerID: String?
  private(set) var avatarURL: URL?
  private var generation: UInt64 = 0

  init() {}

  mutating func beginRefresh(ownerID: String) -> UInt64 {
    generation &+= 1
    self.ownerID = ownerID
    avatarURL = nil
    return generation
  }

  func isCurrent(ownerID: String, generation: UInt64) -> Bool {
    self.ownerID == ownerID && self.generation == generation
  }

  mutating func finishRefresh(avatarURL: URL?, ownerID: String, generation: UInt64) {
    guard isCurrent(ownerID: ownerID, generation: generation) else { return }
    self.avatarURL = avatarURL
  }
}

/// The second production tab is account scoped. The insight card is backed by
/// the own-profile endpoint; when that endpoint has no result, the UI stays
/// explicit about the empty state instead of filling in a fixture narrative.
struct BilingualProductionYouView: View {
  let controller: AuthSessionController
  let ownerID: String
  let language: BilingualReferenceLanguage
  let insightAPI: (any ConversationInsightAPI)?
  let onboardingAPIFactory: (any OnboardingSettingsAPIFactory)?
  let quizAPIFactory: (any QuizAPIFactory)?
  let nativeIntegration: NativeFeatureIntegration
  let onLanguageChange: (BilingualReferenceLanguage) -> Void
  let isDebugFixture: Bool

  @State private var presentedNativeFeature: BilingualProductionAccountFeature?
  @State private var profileAvatarState: BilingualProductionProfileAvatarState

  init(
    controller: AuthSessionController,
    ownerID: String,
    language: BilingualReferenceLanguage,
    insightAPI: (any ConversationInsightAPI)?,
    onboardingAPIFactory: (any OnboardingSettingsAPIFactory)?,
    quizAPIFactory: (any QuizAPIFactory)?,
    nativeIntegration: NativeFeatureIntegration,
    onLanguageChange: @escaping (BilingualReferenceLanguage) -> Void,
    isDebugFixture: Bool = false
  ) {
    self.controller = controller
    self.ownerID = ownerID
    self.language = language
    self.insightAPI = insightAPI
    self.onboardingAPIFactory = onboardingAPIFactory
    self.quizAPIFactory = quizAPIFactory
    self.nativeIntegration = nativeIntegration
    self.onLanguageChange = onLanguageChange
    self.isDebugFixture = isDebugFixture
    _presentedNativeFeature = State(initialValue: nil)
    _profileAvatarState = State(initialValue: BilingualProductionProfileAvatarState())
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      BilingualReferencePalette.cream.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          header
          analysisSurface
          settingsSurface
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 34)
      }
      .scrollIndicators(.hidden)
      BilingualProductionAccountBadge(language: language, isDebugFixture: isDebugFixture)
        .padding(.top, 10)
        .padding(.trailing, 16)
    }
    .navigationTitle(bilingualReferenceCopy(.youTitle, language: language))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(bilingualReferenceCopy(.productionSignOut, language: language)) {
          Task { await controller.signOut() }
        }
        .disabled(controller.isSubmitting)
        .accessibilityIdentifier("production.you.signOut")
      }
    }
    .foregroundStyle(BilingualReferencePalette.ink)
    .tint(BilingualReferencePalette.ink)
    .background(BilingualReferencePalette.cream.ignoresSafeArea())
    .preferredColorScheme(.light)
    .task(id: ownerID) {
      await refreshProfileAvatar()
    }
    .sheet(item: $presentedNativeFeature, onDismiss: {
      Task { await refreshProfileAvatar() }
    }) { feature in
      BilingualProductionAccountFeatureDestination(
        feature: feature,
        ownerID: ownerID,
        language: language,
        controller: controller,
        insightAPI: insightAPI,
        onboardingAPIFactory: onboardingAPIFactory,
        quizAPIFactory: quizAPIFactory,
        nativeIntegration: nativeIntegration,
        onLanguageChange: onLanguageChange,
        onDismiss: { presentedNativeFeature = nil }
      )
    }
  }

  private func refreshProfileAvatar() async {
    let requestedOwnerID = ownerID
    let generation = profileAvatarState.beginRefresh(ownerID: requestedOwnerID)
    guard let api = nativeIntegration.profilePhotoAPIFactory?.make(ownerID: requestedOwnerID) else {
      return
    }
    do {
      let avatarURL = try await api.fetchSavedAvatarURL()
      guard !Task.isCancelled,
        profileAvatarState.isCurrent(ownerID: requestedOwnerID, generation: generation)
      else { return }
      profileAvatarState.finishRefresh(
        avatarURL: avatarURL,
        ownerID: requestedOwnerID,
        generation: generation
      )
    } catch {
      guard !Task.isCancelled,
        profileAvatarState.isCurrent(ownerID: requestedOwnerID, generation: generation)
      else { return }
      profileAvatarState.finishRefresh(
        avatarURL: nil,
        ownerID: requestedOwnerID,
        generation: generation
      )
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      BilingualReferenceSectionLabel(
        text: bilingualReferenceCopy(.youKicker, language: language)
      )
      HStack(alignment: .center, spacing: 14) {
        BilingualProductionAccountPortrait(
          language: language,
          size: 76,
          avatarURL: profileAvatarState.ownerID == ownerID ? profileAvatarState.avatarURL : nil,
          usesFixtureFallback: isDebugFixture
        )
        VStack(alignment: .leading, spacing: 5) {
          Text(bilingualReferenceCopy(.youTitle, language: language))
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .tracking(-0.8)
          Text(bilingualReferenceCopy(.youBody, language: language))
            .font(.subheadline)
            .foregroundStyle(BilingualReferencePalette.muted)
            .lineSpacing(4)
        }
      }
    }
  }

  @ViewBuilder
  private var analysisSurface: some View {
    if let insightAPI {
      BilingualProductionInsightSurface(
        ownerID: ownerID,
        language: language,
        api: insightAPI
      )
    } else {
      BilingualProductionUnavailableView(
        language: language,
        title: .youAnalysisTitle,
        detail: .productionFeatureUnavailable
      )
    }
  }

  private var settingsSurface: some View {
    VStack(alignment: .leading, spacing: 12) {
      BilingualReferenceSectionLabel(
        text: bilingualReferenceCopy(.youSettingsLabel, language: language)
      )

      settingsGroup(
        title: .youPreferencesGroup,
        rows: BilingualProductionAccountFeature.connectionSettings
      )

      settingsGroup(
        title: .youAccountGroup,
        rows: [
          (.youPlanPayments, .planPayments),
          (.youNotifications, .notifications),
          (.youPrivacySafety, .privacySafety),
          (.youHelp, .help)
        ]
      )

      VStack(alignment: .leading, spacing: 10) {
        BilingualReferenceSectionLabel(
          text: bilingualReferenceCopy(.productionProfileTitle, language: language)
        )
        Button {
          presentedNativeFeature = .voice
        } label: {
          accountFeatureLabel(title: .productionVoiceTitle, body: .productionVoiceBody, symbol: "waveform")
        }
        .buttonStyle(.plain)
        .disabled(nativeIntegration.voiceProfile == nil)
        .accessibilityIdentifier("production.you.voice")

        Button {
          presentedNativeFeature = .watercolorProfile
        } label: {
          accountFeatureLabel(
            title: .productionWatercolorTitle,
            body: .productionWatercolorBody,
            symbol: "paintbrush.pointed.fill"
          )
        }
        .buttonStyle(.plain)
        .disabled(nativeIntegration.profilePhoto == nil)
        .accessibilityIdentifier("production.you.watercolorProfile")

        Button {
          presentedNativeFeature = .quiz
        } label: {
          accountFeatureLabel(title: .productionQuizTitle, body: .productionQuizBody, symbol: "checklist")
        }
        .buttonStyle(.plain)
        .disabled(quizAPIFactory == nil)
        .accessibilityIdentifier("production.you.quiz")
      }
    }
  }

  private func settingsGroup(
    title: BilingualReferenceCopyKey,
    rows: [(BilingualReferenceCopyKey, BilingualProductionAccountFeature)]
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(bilingualReferenceCopy(title, language: language))
        .font(.caption.weight(.bold))
        .tracking(1.4)
        .foregroundStyle(BilingualReferencePalette.muted)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        Button {
          presentedNativeFeature = row.1
        } label: {
          HStack(spacing: 12) {
            Text(bilingualReferenceCopy(row.0, language: language))
              .font(.body.weight(.medium))
              .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
              .font(.caption.weight(.bold))
              .foregroundStyle(BilingualReferencePalette.muted)
          }
          .padding(.horizontal, 16)
          .frame(minHeight: 54)
          .background(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("production.you.setting.\(row.1.rawValue)")
        if index < rows.count - 1 {
          Rectangle()
            .fill(BilingualReferencePalette.line)
            .frame(height: 1)
            .padding(.leading, 16)
        }
      }
    }
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
  }

  private func accountFeatureLabel(
    title: BilingualReferenceCopyKey,
    body: BilingualReferenceCopyKey,
    symbol: String
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.headline.weight(.bold))
        .frame(width: 38, height: 38)
        .background(BilingualReferencePalette.softYellow)
        .clipShape(Circle())
      VStack(alignment: .leading, spacing: 3) {
        Text(bilingualReferenceCopy(title, language: language))
          .font(.subheadline.weight(.bold))
        Text(bilingualReferenceCopy(body, language: language))
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.caption.weight(.bold))
        .foregroundStyle(BilingualReferencePalette.muted)
    }
    .padding(13)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(BilingualReferencePalette.field)
    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
  }
}

enum BilingualProductionAccountFeature: String, Identifiable, Equatable {
  case languageRegion
  case matchPreferences
  case planPayments
  case notifications
  case privacySafety
  case help
  case quiz
  case voice
  case watercolorProfile

  var id: String { rawValue }

  static let connectionSettings: [(BilingualReferenceCopyKey, Self)] = [
    (.youLanguageRegion, .languageRegion),
    (.youMatchPreferences, .matchPreferences)
  ]
}

private struct BilingualProductionAccountFeatureDestination: View {
  let feature: BilingualProductionAccountFeature
  let ownerID: String
  let language: BilingualReferenceLanguage
  let controller: AuthSessionController
  let insightAPI: (any ConversationInsightAPI)?
  let onboardingAPIFactory: (any OnboardingSettingsAPIFactory)?
  let quizAPIFactory: (any QuizAPIFactory)?
  let nativeIntegration: NativeFeatureIntegration
  let onLanguageChange: (BilingualReferenceLanguage) -> Void
  let onDismiss: () -> Void

  var body: some View {
    switch feature {
    case .matchPreferences:
      if let api = onboardingAPIFactory?.make(ownerID: ownerID) {
        BilingualProductionOnboardingView(
          controller: controller,
          ownerID: ownerID,
          api: api,
          language: language,
          quizAPIFactory: quizAPIFactory,
          nativeIntegration: nativeIntegration,
          onLanguageChange: onLanguageChange,
          onCompleted: onDismiss
        )
      } else {
        BilingualProductionUnavailableView(
          language: language,
          title: .youMatchPreferences,
          detail: .productionFeatureUnavailable
        )
      }
    case .languageRegion:
      BilingualProductionLanguageRegionView(
        language: language,
        onSelect: onLanguageChange
      )
    case .planPayments:
      nativeDestination(
        factory: nativeIntegration.billing,
        title: .youPlanPayments
      )
    case .privacySafety:
      nativeDestination(
        factory: nativeIntegration.accountSafety,
        title: .youPrivacySafety
      )
    case .notifications:
      BilingualProductionNativeFeatureHost(
        language: language,
        title: .youNotifications,
        destination: AnyView(
          WingwardNotificationSettingsView(
            ownerID: ownerID,
            seenAPI: nativeIntegration.notificationSeenAPIFactory?(ownerID)
          )
        )
      )
    case .help:
      BilingualProductionHelpView(language: language)
    case .quiz:
      if let api = quizAPIFactory?.make(ownerID: ownerID) {
        BilingualProductionNativeFeatureHost(
          language: language,
          title: .productionQuizTitle,
          destination: AnyView(
            QuizView(
              ownerID: ownerID,
              api: api,
              locale: language == .japanese ? .ja : .en,
              onDismiss: onDismiss
            )
          )
        )
      } else {
        BilingualProductionUnavailableView(
          language: language,
          title: .productionQuizTitle,
          detail: .productionFeatureUnavailable
        )
      }
    case .voice:
      if let destination = nativeIntegration.ownerView(
        nativeIntegration.voiceProfile,
        ownerID: ownerID,
        callbacks: NativeFeatureCallbacks(onOpenSettings: onDismiss)
      ) {
        BilingualProductionNativeFeatureHost(
          language: language,
          title: .productionVoiceTitle,
          destination: destination
        )
      } else {
        BilingualProductionUnavailableView(
          language: language,
          title: .productionVoiceTitle,
          detail: .productionFeatureUnavailable
        )
      }
    case .watercolorProfile:
      nativeDestination(
        factory: nativeIntegration.profilePhoto,
        title: .productionWatercolorTitle
      )
    }
  }

  @ViewBuilder
  private func nativeDestination(
    factory: NativeFeatureIntegration.OwnerViewFactory?,
    title: BilingualReferenceCopyKey
  ) -> some View {
    if let destination = nativeIntegration.ownerView(
      factory,
      ownerID: ownerID,
      callbacks: NativeFeatureCallbacks(onOpenSettings: onDismiss)
    ) {
      BilingualProductionNativeFeatureHost(
        language: language,
        title: title,
        destination: destination
      )
    } else {
      BilingualProductionUnavailableView(
        language: language,
        title: title,
        detail: .productionFeatureUnavailable
      )
    }
  }
}

private struct BilingualProductionLanguageRegionView: View {
  let language: BilingualReferenceLanguage
  let onSelect: (BilingualReferenceLanguage) -> Void

  var body: some View {
    ZStack {
      BilingualReferencePalette.cream.ignoresSafeArea()
      VStack(alignment: .leading, spacing: 16) {
        BilingualReferenceSectionLabel(
          text: bilingualReferenceCopy(.youLanguageRegion, language: language)
        )
        Text(bilingualReferenceCopy(.productionDetailPlaceholder, language: language))
          .font(.title3.weight(.bold))
        Text(bilingualReferenceCopy(.productionLanguageSaved, language: language))
          .font(.subheadline)
          .foregroundStyle(BilingualReferencePalette.muted)
        languageButton(.japanese)
        languageButton(.english)
      }
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity)
      .padding(22)
    }
    .foregroundStyle(BilingualReferencePalette.ink)
    .navigationTitle(bilingualReferenceCopy(.youLanguageRegion, language: language))
    .navigationBarTitleDisplayMode(.inline)
    .preferredColorScheme(.light)
  }

  private func languageButton(_ value: BilingualReferenceLanguage) -> some View {
    Button {
      onSelect(value)
    } label: {
      HStack {
        Text(
          bilingualReferenceCopy(
            value == .japanese ? .languageJapanese : .languageEnglish,
            language: language
          )
        )
          .font(.body.weight(.semibold))
        Spacer(minLength: 0)
        Image(systemName: value == language ? "checkmark.circle.fill" : "chevron.right")
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(value == language ? BilingualReferencePalette.softYellow : .white)
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(value == language ? BilingualReferencePalette.yellow : BilingualReferencePalette.line, lineWidth: value == language ? 2 : 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("production.you.language.\(value.rawValue)")
  }
}

private struct BilingualProductionInsightSurface: View {
  let ownerID: String
  let language: BilingualReferenceLanguage
  let api: any ConversationInsightAPI

  @State private var store: ConversationInsightStore

  init(ownerID: String, language: BilingualReferenceLanguage, api: any ConversationInsightAPI) {
    self.ownerID = ownerID
    self.language = language
    self.api = api
    _store = State(initialValue: ConversationInsightStore(ownerID: ownerID, api: api))
  }

  var body: some View {
    Group {
      switch store.phase {
      case .idle, .loading:
        BilingualProductionLoadingCard(
          language: language,
          detail: .productionAnalysisLoading,
          identifier: "production.you.analysis.loading"
        )
      case .failed:
        BilingualProductionErrorCard(
          language: language,
          title: .productionAnalysisError,
          retry: { Task { await store.retry().value } },
          identifier: "production.you.analysis.retry"
        )
      case .loaded:
        if let insight = store.insight,
          !insight.personalityTags.isEmpty || insight.overallSignature != nil
            || !insight.currentPreferences.isEmpty || insight.latestConfirmedPersonaUnavailable
        {
          NavigationLink {
            BilingualProductionAnalysisDetailView(insight: insight, language: language)
          } label: {
            loadedCard(insight)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("production.you.analysis.open")
        } else {
          BilingualProductionEmptyCard(
            language: language,
            title: .productionAnalysisEmpty,
            detail: .productionAnalysisEmptyBody,
            identifier: "production.you.analysis.empty"
          )
        }
      }
    }
    .task(id: ownerID) { await store.load().value }
    .onDisappear { store.cancel() }
  }

  private func loadedCard(_ insight: OwnInsight) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 14) {
        BilingualProductionAccountPortrait(language: language, size: 62, avatarURL: nil, usesFixtureFallback: false)
        VStack(alignment: .leading, spacing: 4) {
          Text(bilingualReferenceCopy(.youAnalysisTitle, language: language))
            .font(.title3.weight(.bold))
          Text(profileLabel(insight))
            .font(.caption.weight(.bold))
            .tracking(1.3)
            .foregroundStyle(BilingualReferencePalette.muted)
        }
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.right")
          .font(.headline.weight(.semibold))
      }
      if let signature = insight.overallSignature,
        !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        Text(BilingualReferenceCatalog.insightText(signature, language: language))
          .font(.body)
          .foregroundStyle(BilingualReferencePalette.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      BilingualCurrentProfileTraits(insight: insight, language: language)
      Text(bilingualReferenceCopy(.productionReadAnalysis, language: language))
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(BilingualReferencePalette.ink)
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
  }

  private func profileLabel(_ insight: OwnInsight) -> String {
    let label = language == .japanese ? "現在のプロフィール" : "YOUR CURRENT PROFILE"
    return insight.profileVersion.map { "\(label) · v\($0)" } ?? label
  }
}

private struct BilingualProductionAnalysisDetailView: View {
  let insight: OwnInsight
  let language: BilingualReferenceLanguage

  var body: some View {
    ZStack {
      BilingualReferencePalette.cream.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          BilingualProductionAccountPortrait(language: language, size: 88, avatarURL: nil, usesFixtureFallback: false)
          BilingualReferenceSectionLabel(
            text: bilingualReferenceCopy(.analysisDetailKicker, language: language)
          )
          Text(bilingualReferenceCopy(.youAnalysisTitle, language: language))
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .tracking(-1)
          if let signature = insight.overallSignature,
            !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            detailSection(.analysisDetailSummaryLabel) {
              Text(BilingualReferenceCatalog.insightText(signature, language: language))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          detailSection(.youTraitsLabel) {
            BilingualCurrentProfileTraits(insight: insight, language: language)
          }
          Text(bilingualReferenceCopy(.productionDetailPlaceholder, language: language))
            .font(.caption)
            .foregroundStyle(BilingualReferencePalette.muted)
        }
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(22)
      }
      .scrollIndicators(.hidden)
    }
    .foregroundStyle(BilingualReferencePalette.ink)
    .navigationTitle(bilingualReferenceCopy(.youAnalysisTitle, language: language))
    .navigationBarTitleDisplayMode(.inline)
    .preferredColorScheme(.light)
  }

  private func detailSection<Content: View>(
    _ title: BilingualReferenceCopyKey,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(bilingualReferenceCopy(title, language: language))
        .font(.caption.weight(.bold))
        .tracking(1.3)
        .foregroundStyle(BilingualReferencePalette.muted)
      content()
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

private struct BilingualCurrentProfileTraits: View {
  let insight: OwnInsight
  let language: BilingualReferenceLanguage

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 8) {
        ForEach(Array(insight.personalityTags.enumerated()), id: \.offset) { _, tag in
          BilingualReferenceTraitChip(text: BilingualReferenceCatalog.insightText(tag, language: language))
        }
        if !insight.currentPreferences.isEmpty {
          ForEach(insight.currentPreferences, id: \.key) { trait in
            VStack(alignment: .leading, spacing: 5) {
              Text(changeLabel(trait))
                .font(.caption2.weight(.bold))
                .foregroundStyle(BilingualReferencePalette.muted)
              Text(label(for: trait))
                .font(.subheadline.weight(.medium))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BilingualReferencePalette.softYellow)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("production.you.confirmedPersona.\(trait.key.rawValue)")
          }
        }
      }
      if !insight.currentPreferences.isEmpty {
        Text(language == .japanese ? "Wardとの振り返りで確認した内容を、元のプロフィールに追加・更新しました。" : "Your confirmed reflection preferences are part of your existing profile.")
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
        if let changes = insight.currentPreferenceChanges {
          Text(language == .japanese
            ? "今回の更新：追加\(changes.addedKeys.count)項目・変更\(changes.changedKeys.count)項目"
            : "Latest update: \(changes.addedKeys.count) added · \(changes.changedKeys.count) changed")
            .font(.caption.weight(.semibold))
            .accessibilityIdentifier("production.you.profileUpdate.summary")
        } else if insight.latestConfirmedPersona?.changesUnavailable == true {
          Text(language == .japanese ? "前回との差分は現在確認できません。" : "The comparison with your previous update is unavailable.")
            .font(.caption)
            .foregroundStyle(BilingualReferencePalette.muted)
        }
      } else if insight.latestConfirmedPersonaUnavailable {
        Text(language == .japanese ? "保存した好みを読み込めませんでした。画面を開き直してお試しください。" : "Your saved preferences couldn't be loaded. Reopen this screen to try again.")
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
          .accessibilityIdentifier("production.you.confirmedPersona.unavailable")
      }
    }
    .accessibilityIdentifier("production.you.currentProfile.traits")
  }

  private func changeLabel(_ trait: ChatMeetupReflectionTrait) -> String {
    if insight.currentPreferenceChanges?.addedKeys.contains(trait.key) == true {
      return language == .japanese ? "今回追加" : "ADDED"
    }
    if insight.currentPreferenceChanges?.changedKeys.contains(trait.key) == true {
      return language == .japanese ? "今回変更" : "UPDATED"
    }
    return language == .japanese ? "確認済み" : "CONFIRMED"
  }

  private func label(for trait: ChatMeetupReflectionTrait) -> String {
    let keys: [ChatMeetupReflectionTraitKey: (String, String)] = [
      .socialEnergy: ("Social energy", "人との過ごし方"),
      .planningStyle: ("Planning", "計画の立て方"),
      .decisionStyle: ("Decision style", "判断の仕方"),
      .attachmentTendency: ("Relationship style", "関係の築き方"),
      .conflictStyle: ("Resolving differences", "意見が違うとき"),
      .rhythmPreference: ("Pace", "ペース"),
      .communicationPreference: ("Communication", "コミュニケーション"),
      .priorityValue: ("What matters", "大切にすること"),
      .favoriteActivity: ("Interests", "好きな活動")
    ]
    let values: [ChatMeetupReflectionTraitValue: (String, String)] = [
      .introverted: ("Introverted", "内向的"), .ambiverted: ("In between", "どちらも"), .extroverted: ("Outgoing", "外向的"),
      .planned: ("Planned", "計画的"), .mixed: ("Flexible", "柔軟"), .spontaneous: ("Spontaneous", "自然な流れ"),
      .analytical: ("Analytical", "分析的"), .balanced: ("Balanced", "バランス重視"), .emotional: ("Feelings first", "気持ちを重視"),
      .secure: ("Secure", "安心感"), .anxious: ("Needs reassurance", "安心の確認"), .avoidant: ("Needs space", "自分の時間"),
      .dialogue: ("Talk it through", "話し合い"), .yields: ("Accommodating", "譲り合い"), .maintains: ("Stands firm", "意思を保つ"), .avoids: ("Takes distance", "距離を置く"),
      .slow: ("Slow", "ゆっくり"), .moderate: ("Moderate", "ほどよく"), .fast: ("Fast", "速め"),
      .concise: ("Concise", "簡潔"), .detailed: ("Detailed", "丁寧に詳しく"),
      .family: ("Family", "家族"), .friendship: ("Friendship", "友情"), .independence: ("Independence", "自立"),
      .creativity: ("Creativity", "創造性"), .learning: ("Learning", "学び"), .stability: ("Stability", "安定"), .community: ("Community", "地域との交流"),
      .arts: ("Arts", "アート"), .music: ("Music", "音楽"), .reading: ("Reading", "読書"), .outdoors: ("Outdoors", "アウトドア"),
      .food: ("Food", "食"), .technology: ("Technology", "テクノロジー"), .sports: ("Sports", "スポーツ")
    ]
    guard let key = keys[trait.key], let value = values[trait.value] else { return "" }
    return language == .japanese ? "\(key.1)：\(value.1)" : "\(key.0): \(value.0)"
  }
}

private struct BilingualProductionLoadingCard: View {
  let language: BilingualReferenceLanguage
  let detail: BilingualReferenceCopyKey
  let identifier: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ProgressView()
        .tint(BilingualReferencePalette.yellow)
      Text(bilingualReferenceCopy(detail, language: language))
        .font(.subheadline)
        .foregroundStyle(BilingualReferencePalette.muted)
    }
    .padding(20)
    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .accessibilityIdentifier(identifier)
  }
}

private struct BilingualProductionErrorCard: View {
  let language: BilingualReferenceLanguage
  let title: BilingualReferenceCopyKey
  let retry: () -> Void
  let identifier: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Image(systemName: "arrow.clockwise.circle")
        .font(.title2)
        .foregroundStyle(BilingualReferencePalette.yellow)
      Text(bilingualReferenceCopy(title, language: language))
        .font(.headline.weight(.bold))
      Button(bilingualReferenceCopy(.productionRetry, language: language), action: retry)
        .buttonStyle(BilingualReferencePrimaryButtonStyle())
        .accessibilityIdentifier(identifier)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

private struct BilingualProductionEmptyCard: View {
  let language: BilingualReferenceLanguage
  let title: BilingualReferenceCopyKey
  let detail: BilingualReferenceCopyKey
  let identifier: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: "sparkles")
        .font(.title2)
        .foregroundStyle(BilingualReferencePalette.yellow)
      Text(bilingualReferenceCopy(title, language: language))
        .font(.title3.weight(.bold))
      Text(bilingualReferenceCopy(detail, language: language))
        .font(.subheadline)
        .foregroundStyle(BilingualReferencePalette.muted)
        .lineSpacing(4)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .accessibilityIdentifier(identifier)
  }
}

private struct BilingualProductionInlineNotice: View {
  let language: BilingualReferenceLanguage
  let title: BilingualReferenceCopyKey
  let detail: BilingualReferenceCopyKey
  let identifier: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(bilingualReferenceCopy(title, language: language))
        .font(.subheadline.weight(.bold))
      Text(bilingualReferenceCopy(detail, language: language))
        .font(.caption)
        .foregroundStyle(BilingualReferencePalette.muted)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(BilingualReferencePalette.field)
    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    .accessibilityIdentifier(identifier)
  }
}

private struct BilingualProductionUnavailableView: View {
  let language: BilingualReferenceLanguage
  let title: BilingualReferenceCopyKey
  let detail: BilingualReferenceCopyKey

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      BilingualReferenceSectionLabel(text: bilingualReferenceCopy(title, language: language))
      Text(bilingualReferenceCopy(.productionFeatureUnavailable, language: language))
        .font(.title3.weight(.bold))
      Text(bilingualReferenceCopy(detail, language: language))
        .font(.body)
        .foregroundStyle(BilingualReferencePalette.muted)
        .lineSpacing(5)
    }
    .padding(22)
    .frame(maxWidth: 640, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(BilingualReferencePalette.cream)
    .foregroundStyle(BilingualReferencePalette.ink)
  }
}
