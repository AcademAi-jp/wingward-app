import SwiftUI

private struct MatchSafetyRequest: Identifiable {
  enum Target {
    case user(UUID)
    case match(UUID)
  }

  let target: Target
  let context: ReportContext

  var id: String {
    switch target {
    case let .user(id): return "user-\(id.uuidString)-\(context.rawValue)"
    case let .match(id): return "match-\(id.uuidString)-\(context.rawValue)"
    }
  }
}

private struct MatchChatRequest: Identifiable {
  let matchID: UUID
  var id: UUID { matchID }
}

struct MatchesView: View {
  let controller: AuthSessionController
  let ownerID: String
  let onOpenSettings: () -> Void
  let nativeIntegration: NativeFeatureIntegration
  let onOpenRoute: (AppRoute) -> Void
  let matchDetailAPI: (any MatchDetailAPI)?
  let insightAPI: (any ConversationInsightAPI)?
  @Environment(\.locale) private var locale
  @State private var store: MatchesStore
  @State private var pendingSafetyRequest: MatchSafetyRequest?
  @State private var pendingChatRequest: MatchChatRequest?
  @State private var showsVerificationUnavailable = false

  init(
    controller: AuthSessionController,
    ownerID: String,
    api: any MatchesAPI,
    matchDetailAPI: (any MatchDetailAPI)? = nil,
    insightAPI: (any ConversationInsightAPI)? = nil,
    onOpenSettings: @escaping () -> Void = {},
    nativeIntegration: NativeFeatureIntegration = .unavailable,
    onOpenRoute: @escaping (AppRoute) -> Void = { _ in }
  ) {
    self.controller = controller
    self.ownerID = ownerID
    self.onOpenSettings = onOpenSettings
    self.nativeIntegration = nativeIntegration
    self.onOpenRoute = onOpenRoute
    self.matchDetailAPI = matchDetailAPI
    self.insightAPI = insightAPI
    _store = State(initialValue: MatchesStore(ownerID: ownerID, api: api))
    _pendingSafetyRequest = State(initialValue: nil)
    _pendingChatRequest = State(initialValue: nil)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ReferenceHeader(
          onLogo: {},
          onProfile: {
            store.cancel()
            onOpenSettings()
          },
          profileIdentifier: "matches.settings",
          notificationIdentifier: "matches.notifications",
          notificationLabel: "お知らせはまだ利用できません"
        )

        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            switch store.phase {
            case .idle, .loading:
              loadingSurface
            case let .failed(error):
              failureSurface(error)
            case .loaded:
              if store.supportsDemoJudgeMatching {
                DemoJudgeMatchingControls(store: store, japanese: locale.identifier.lowercased().hasPrefix("ja"))
              }
              if store.payload?.simulatedCounterpart == true {
                Text(locale.identifier.lowercased().hasPrefix("ja") ? "審査用の架空の相手とのマッチです。実際の面会は行いません。" : "This judge match uses a fictional counterpart. No real meeting takes place.")
                  .font(.footnote).foregroundStyle(ReferencePalette.muted)
                  .accessibilityIdentifier("matches.simulatedCounterpart")
              }
              loadedSurface
            }

            if let insightAPI {
              ConversationInsightView(ownerID: ownerID, api: insightAPI)
                .id("conversation-insight-\(ownerID)")
            }

            actionRow
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 16)
          .frame(maxWidth: 760, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
      }
      .background(ReferencePalette.cream)
      .toolbar(.hidden, for: .navigationBar)
    }
    .foregroundStyle(ReferencePalette.ink)
    .environment(\.colorScheme, .light)
    .tint(ReferencePalette.ink)
    .background(ReferencePalette.cream)
    .task(id: ownerID) {
      await store.load().value
    }
    .onDisappear {
      store.cancel()
    }
    .sheet(item: $pendingSafetyRequest) { request in
      switch request.target {
      case let .user(targetID):
        if let destination = nativeIntegration.safetyAction?(ownerID, targetID, request.context, nil) {
          destination
        } else {
          NativeFeatureUnavailableView()
        }
      case let .match(matchID):
        if let destination = nativeIntegration.matchSafety?(
          ownerID,
          matchID,
          request.context,
          NativeFeatureCallbacks(
            onBlocked: {
              pendingSafetyRequest = nil
              store.cancel()
              onOpenSettings()
            },
            onBlockNeedsReconciliation: {
              pendingSafetyRequest = nil
              Task { await store.retry().value }
            }
          )
        ) {
          destination
        } else {
          NativeFeatureUnavailableView()
        }
      }
    }
    .sheet(item: $pendingChatRequest) { request in
      if let destination = nativeIntegration.chatRequestForMatch?(
        ownerID,
        request.matchID,
        NativeFeatureCallbacks(
          onOpenSettings: onOpenSettings,
          onOpenReportForMatch: { matchID, context in
            pendingSafetyRequest = MatchSafetyRequest(
              target: .match(matchID),
              context: context
            )
          }
        )
      ) {
        destination
      } else {
        NativeFeatureUnavailableView()
      }
    }
    .alert(
      locale.identifier.lowercased().hasPrefix("ja")
        ? "本人確認はまだ利用できません"
        : "Identity verification is unavailable",
      isPresented: $showsVerificationUnavailable
    ) {
      Button(
        locale.identifier.lowercased().hasPrefix("ja") ? "閉じる" : "Close",
        role: .cancel
      ) {}
    } message: {
      Text(
        locale.identifier.lowercased().hasPrefix("ja")
          ? "本人確認の接続先がありません。アカウントは本人確認済みになりません。"
          : "No identity verification provider is connected. This does not verify your account."
      )
    }
    .preferredColorScheme(.light)
  }

  private var actionRow: some View {
    HStack(spacing: 10) {
      Spacer(minLength: 0)

      if hasNativeFeatures {
        NavigationLink {
          NativeFeatureHubView(
            ownerID: ownerID,
            integration: nativeIntegration,
            callbacks: NativeFeatureCallbacks(
              onOpenSettings: onOpenSettings,
              onOpenReport: { targetID, context in
                pendingSafetyRequest = MatchSafetyRequest(target: .user(targetID), context: context)
              },
              onOpenReportForMatch: { matchID, context in
                pendingSafetyRequest = MatchSafetyRequest(target: .match(matchID), context: context)
              },
              onOpenMeetup: { meetupID in
                onOpenRoute(.meetup(meetupID))
              },
              onBlocked: onOpenSettings,
              onOpenVerification: { showsVerificationUnavailable = true },
              onOpenPaywall: { source in onOpenRoute(.paywall(source)) },
              onBlockNeedsReconciliation: {
                Task { await store.retry().value }
              }
            )
          )
        } label: {
          Image(systemName: "square.grid.2x2")
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Open WingWard features")
        .accessibilityIdentifier("matches.nativeFeatures")
        .background(.white)
        .overlay {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(ReferencePalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      }

      Button {
        Task { await store.retry().value }
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 16, weight: .semibold))
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel("Refresh matches")
      .accessibilityIdentifier("matches.refresh")
      .background(.white)
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(ReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

      Button {
        store.cancel()
        Task { await controller.signOut() }
      } label: {
        Image(systemName: "rectangle.portrait.and.arrow.right")
          .font(.system(size: 15, weight: .semibold))
          .frame(width: 44, height: 44)
      }
      .disabled(controller.isSubmitting)
      .accessibilityLabel("Sign out")
      .accessibilityIdentifier("matches.signOut")
      .background(.white)
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(ReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
  }

  private var hasNativeFeatures: Bool {
    nativeIntegration.voiceProfile != nil
      || nativeIntegration.directChats != nil
      || nativeIntegration.meetups != nil
      || nativeIntegration.billing != nil
      || nativeIntegration.accountSafety != nil
  }

  private var loadingSurface: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Your matches")
        .font(.system(size: 30, weight: .bold))
      Text(store.supportsDemoJudgeMatching ? "Checking saved discovery matches." : "Checking today's matching results.")
        .font(.body)
        .foregroundStyle(ReferencePalette.muted)
      ProgressView()
        .tint(ReferencePalette.yellow)
        .frame(minHeight: 48)
        .accessibilityIdentifier("matches.loading")
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(ReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
  }

  private func failureSurface(_ error: MatchesStoreError) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Image(systemName: "arrow.clockwise.circle")
        .font(.system(size: 32, weight: .medium))
        .foregroundStyle(ReferencePalette.yellow)
        .accessibilityHidden(true)
      Text("We couldn't load your matches")
        .font(.title2.weight(.bold))
      Text(error.userMessage)
        .font(.body)
        .foregroundStyle(ReferencePalette.muted)
      Button("Try again") {
        Task { await store.retry().value }
      }
      .buttonStyle(ReferencePrimaryButtonStyle())
      .accessibilityIdentifier("matches.retry")
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(ReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
  }

  @ViewBuilder
  private func matchCard(rank: Int, match: ProductionMatch) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let matchDetailAPI {
        NavigationLink {
          MatchDetailView(
            ownerID: ownerID,
            rank: rank,
            matchID: match.id,
            api: matchDetailAPI,
            onOpenSettings: {
              store.cancel()
              onOpenSettings()
            },
            onSignOut: {
              store.cancel()
              Task { await controller.signOut() }
            },
            onOpenReport: { targetID, context in
              pendingSafetyRequest = MatchSafetyRequest(target: .user(targetID), context: context)
            },
            onOpenMeetup: { meetupID in
              onOpenRoute(.meetup(meetupID))
            },
            onOpenChatRequest: { matchID in
              pendingChatRequest = MatchChatRequest(matchID: matchID)
            }
          )
          .id("match-detail-\(ownerID)-\(match.id.uuidString)")
        } label: {
          MatchCard(rank: rank, match: match)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open match details")
      } else {
        MatchCard(rank: rank, match: match)
      }

      if let meetupForMatch = nativeIntegration.meetupForMatch,
        let destination = meetupForMatch(
          ownerID,
          match.id,
          NativeFeatureCallbacks(
            onOpenSettings: onOpenSettings,
            onOpenReportForMatch: { matchID, context in
              pendingSafetyRequest = MatchSafetyRequest(target: .match(matchID), context: context)
            },
            onBlocked: onOpenSettings,
            onOpenVerification: { showsVerificationUnavailable = true },
            onOpenPaywall: { source in onOpenRoute(.paywall(source)) },
            onBlockNeedsReconciliation: {
              Task { await store.retry().value }
            }
          )
        )
      {
        NavigationLink {
          destination
        } label: {
          Label("Plan a meetup", systemImage: "calendar")
            .font(.footnote.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        }
        .buttonStyle(ReferenceOutlineButtonStyle())
        .accessibilityIdentifier("matches.meetup.\(match.id.uuidString)")
      }
    }
  }

  @ViewBuilder
  private var loadedSurface: some View {
    if !store.displayedMatches.isEmpty {
      VStack(alignment: .leading, spacing: 28) {
        HStack(alignment: .bottom) {
          VStack(alignment: .leading, spacing: 5) {
            Text("WARD SELECTED")
              .font(.caption2.weight(.bold))
              .tracking(1.5)
              .foregroundStyle(ReferencePalette.ink.opacity(0.72))
            Text(store.supportsDemoJudgeMatching ? "Discovery matches" : "People who may feel right for you")
              .font(.title.weight(.bold))
          }
          Spacer()
          Text("By rank")
            .font(.caption)
            .foregroundStyle(ReferencePalette.muted)
        }

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 22) {
            ForEach(Array(store.displayedMatches.enumerated()), id: \.element.id) { index, match in
              matchCard(rank: index + 1, match: match)
            }
          }
          .padding(.horizontal, 3)
          .padding(.bottom, 4)
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 14) {
        Image(systemName: "sparkles")
          .font(.system(size: 30, weight: .medium))
          .foregroundStyle(ReferencePalette.yellow)
          .accessibilityHidden(true)
        Text("No matches yet")
          .font(.title2.weight(.bold))
        Text(store.supportsDemoJudgeMatching ? "No saved discovery matches yet. Preview checks eligibility; Start creates real matches." : "There are no matching results to show today. Check again later.")
          .font(.body)
          .foregroundStyle(ReferencePalette.muted)
          .lineSpacing(4)
        Button("Refresh matches") {
          Task { await store.retry().value }
        }
        .buttonStyle(ReferencePrimaryButtonStyle())
        .accessibilityIdentifier("matches.empty.refresh")
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.white)
      .overlay {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .stroke(ReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
      .accessibilityIdentifier("matches.empty")
    }
  }
}

private struct MatchCard: View {
  let rank: Int
  let match: ProductionMatch

  var body: some View {
    VStack(spacing: 8) {
      MatchPortrait(partner: match.partner)

      Text(match.partner.displayName)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(ReferencePalette.ink)
        .lineLimit(1)
        .frame(maxWidth: 118)

      Text("RANK \(rank)")
        .font(.caption.weight(.bold))
        .tracking(1.3)
        .foregroundStyle(ReferencePalette.ink.opacity(0.72))
    }
    .frame(minWidth: 94)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Rank \(rank), \(match.partner.displayName)")
    .accessibilityValue(statusCopy)
    .accessibilityIdentifier("matches.card.\(match.id.uuidString)")
  }

  private var statusCopy: String {
    switch match.status {
    case "pending":
      return "Ready to start your Ward conversation."
    case "fox_conversation_completed":
      return "The Ward conversation is complete."
    case "fox_conversation_in_progress":
      return "The Ward conversation is in progress."
    case "fox_conversation_failed":
      return "The Ward conversation couldn't be completed."
    default:
      return "Match status is being checked."
    }
  }
}

private struct MatchPortrait: View {
  let partner: ProductionMatch.Partner

  private var imageURL: URL? {
    partner.avatarURL ?? partner.personaIconURL
  }

  var body: some View {
    AsyncImage(url: imageURL) { phase in
      switch phase {
      case let .success(image):
        image
          .resizable()
          .scaledToFill()
      case .empty, .failure:
        placeholder
      @unknown default:
        placeholder
      }
    }
    .frame(width: 92, height: 92)
    .background(ReferencePalette.yellowSoft)
    .clipShape(Circle())
    .overlay {
      Circle().stroke(ReferencePalette.yellow, lineWidth: 3)
    }
    .accessibilityLabel("\(partner.displayName)'s profile image")
  }

  private var placeholder: some View {
    Image(systemName: "person.fill")
      .font(.system(size: 28, weight: .medium))
      .foregroundStyle(ReferencePalette.muted)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Judge controls only call server routes; eligibility preview never starts matching.
struct DemoJudgeMatchingControls: View {
  let store: MatchesStore
  let japanese: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(japanese ? "候補選定によるマッチ" : "Discovery matches")
        .font(.headline)
      Text(japanese ? "架空ユーザーのデモ。通常の候補選定で保存されたマッチを表示します。プレビューはマッチを作成しません。" :
        "Fictional demo. These are saved matches from ordinary discovery. Preview does not create matches.")
        .font(.footnote)
      Text(statusText)
        .font(.footnote)
        .accessibilityIdentifier("matches.demoJudge.status")
      Button(japanese ? "候補をプレビュー" : "Preview eligibility") {
        store.previewDemoJudgeMatching()
      }
      .buttonStyle(BilingualReferenceSecondaryButtonStyle())
      .disabled(!store.canPreviewDemoJudgeMatching)
      .accessibilityIdentifier("matches.demoJudge.preview")
      Button(japanese ? "マッチングを開始" : "Start matching") {
        store.startDemoJudgeMatching()
      }
      .buttonStyle(BilingualReferencePrimaryButtonStyle())
      .disabled(!store.canStartDemoJudgeMatching)
      .accessibilityIdentifier("matches.demoJudge.start")
      if store.isDemoJudgeInProgress { ProgressView() }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(BilingualReferencePalette.softYellow)
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .accessibilityIdentifier("matches.demoJudge.controls")
  }

  private var statusText: String {
    switch store.demoJudgePhase {
    case .idle: return japanese ? "まずプレビューを確認してください。" : "Preview eligibility before starting."
    case .previewing: return japanese ? "候補を確認中…" : "Checking eligibility…"
    case let .previewed(count): return japanese ? "新しい候補: \(count)件。まだ開始していません。" : "New eligible candidates: \(count). Matching has not started."
    case .starting: return japanese ? "マッチング処理中…" : "Creating matches…"
    case let .finished(outcome, count):
      if outcome == .startedPartial {
        return japanese ? "一部の処理が完了しました。新しいマッチ: \(count)件。" : "Partially completed. New matches: \(count)."
      }
      return japanese ? "処理が完了しました。新しいマッチ: \(count)件。" : "Completed. New matches: \(count)."
    case .resultsUnavailable: return japanese ? "開始結果の再取得が必要です。更新してください。" : "Refresh to retrieve the saved results."
    case .failed: return japanese ? "処理を確認できませんでした。結果を更新してください。" : "The request could not be confirmed. Refresh saved results."
    case .cancelled: return japanese ? "処理の表示を中断しました。結果を更新してください。" : "The view was interrupted. Refresh saved results."
    }
  }
}
