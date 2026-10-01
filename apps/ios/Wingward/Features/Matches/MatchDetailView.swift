import SwiftUI

struct MatchDetailView: View {
  let ownerID: String
  let rank: Int
  let matchID: UUID
  let api: any MatchDetailAPI
  let onOpenSettings: () -> Void
  let onSignOut: () -> Void
  let onOpenReport: ((UUID, ReportContext) -> Void)?
  let onOpenMeetup: ((UUID) -> Void)?
  let onOpenChatRequest: ((UUID) -> Void)?
  @Environment(\.dismiss) private var dismiss
  @State private var store: MatchDetailStore

  init(
    ownerID: String,
    rank: Int,
    matchID: UUID,
    api: any MatchDetailAPI,
    onOpenSettings: @escaping () -> Void = {},
    onSignOut: @escaping () -> Void = {},
    onOpenReport: ((UUID, ReportContext) -> Void)? = nil,
    onOpenMeetup: ((UUID) -> Void)? = nil,
    onOpenChatRequest: ((UUID) -> Void)? = nil
  ) {
    self.ownerID = ownerID
    self.rank = rank
    self.matchID = matchID
    self.api = api
    self.onOpenSettings = onOpenSettings
    self.onSignOut = onSignOut
    self.onOpenReport = onOpenReport
    self.onOpenMeetup = onOpenMeetup
    self.onOpenChatRequest = onOpenChatRequest
    _store = State(initialValue: MatchDetailStore(ownerID: ownerID, matchID: matchID, api: api))
  }

  var body: some View {
    VStack(spacing: 0) {
      ReferenceHeader(
        onLogo: {
          store.cancel()
          dismiss()
        },
        onProfile: {
          store.cancel()
          onOpenSettings()
        },
        profileIdentifier: "matchDetail.settings",
        notificationIdentifier: "matchDetail.notifications",
        notificationLabel: "お知らせはまだ利用できません"
      )

      ReferenceProgressHeader(
        backTitle: "Matches",
        progress: "MATCH DETAIL",
        progressValue: 0,
        showsProgress: false,
        backIdentifier: "matchDetail.back"
      ) {
        store.cancel()
        dismiss()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          actionRow

          switch store.phase {
          case .idle, .loading:
            loadingSurface
          case let .failed(error):
            failureSurface(error)
          case .loaded:
            loadedSurface
          }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
    }
    .background(ReferencePalette.cream)
    .toolbar(.hidden, for: .navigationBar)
    .foregroundStyle(ReferencePalette.ink)
    .environment(\.colorScheme, .light)
    .tint(ReferencePalette.ink)
    .preferredColorScheme(.light)
    .task(id: "\(ownerID)-\(matchID.uuidString)") {
      await store.load().value
    }
    .onDisappear {
      store.cancel()
    }
  }

  private var actionRow: some View {
    HStack(spacing: 10) {
      Spacer(minLength: 0)

      Button {
        Task { await store.retry().value }
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 16, weight: .semibold))
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel("Refresh match details")
      .accessibilityIdentifier("matchDetail.refresh")
      .disabled(store.isStartingConversation || store.isStartingPartnerChat)
      .background(.white)
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(ReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

      Button {
        store.cancel()
        onSignOut()
      } label: {
        Image(systemName: "rectangle.portrait.and.arrow.right")
          .font(.system(size: 15, weight: .semibold))
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel("Sign out")
      .accessibilityIdentifier("matchDetail.signOut")
      .background(.white)
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(ReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
  }

  private var loadingSurface: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Match detail")
        .font(.system(size: 30, weight: .bold))
      Text("Loading the details for this match.")
        .font(.body)
        .foregroundStyle(ReferencePalette.muted)
      ProgressView()
        .tint(ReferencePalette.yellow)
        .frame(minHeight: 48)
        .accessibilityIdentifier("matchDetail.loading")
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

  private func failureSurface(_ error: MatchDetailStoreError) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Image(systemName: "arrow.clockwise.circle")
        .font(.system(size: 32, weight: .medium))
        .foregroundStyle(ReferencePalette.yellow)
        .accessibilityHidden(true)
      Text("We couldn't load this match")
        .font(.title2.weight(.bold))
      Text(error.userMessage)
        .font(.body)
        .foregroundStyle(ReferencePalette.muted)
      Button("Try again") {
        Task { await store.retry().value }
      }
      .buttonStyle(ReferencePrimaryButtonStyle())
      .accessibilityIdentifier("matchDetail.retry")
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
  private var loadedSurface: some View {
    if let detail = store.detail {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .center, spacing: 14) {
          Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 56, weight: .medium))
            .foregroundStyle(ReferencePalette.muted)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 5) {
            Text("RANK \(rank)")
              .font(.caption.weight(.bold))
              .tracking(1.6)
              .foregroundStyle(ReferencePalette.ink.opacity(0.72))
            Text(detail.partner.displayName)
              .font(.system(size: 30, weight: .bold))
              .accessibilityIdentifier("matchDetail.detail")
            Text(statusCopy(for: detail.status))
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(ReferencePalette.ink.opacity(0.72))
          }
          Spacer(minLength: 0)
        }

        if let onOpenReport {
          Button {
            onOpenReport(detail.partnerID, .match)
          } label: {
            Label("Report or block", systemImage: "exclamationmark.shield")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(ReferenceOutlineButtonStyle())
          .accessibilityIdentifier("matchDetail.report")
        }

        if let onOpenMeetup {
          Button {
            onOpenMeetup(matchID)
          } label: {
            Label("Plan a meetup", systemImage: "calendar")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(ReferenceOutlineButtonStyle())
          .accessibilityIdentifier("matchDetail.meetup")
        }

        if store.canStartConversation {
          Button {
            Task { await store.startConversation().value }
          } label: {
            HStack(spacing: 10) {
              if store.isStartingConversation {
                ProgressView()
                  .tint(ReferencePalette.ink)
              }
              Text("Start Ward conversation")
            }
          }
          .buttonStyle(ReferencePrimaryButtonStyle())
          .disabled(store.isStartingConversation)
          .accessibilityIdentifier("matchDetail.startConversation")
        }

        if let startError = store.startError {
          VStack(alignment: .leading, spacing: 6) {
            Text("Ward conversation unavailable")
              .font(.subheadline.weight(.semibold))
            Text(startError.startUserMessage)
              .font(.footnote)
              .foregroundStyle(ReferencePalette.muted)
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(ReferencePalette.field)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          .accessibilityIdentifier("matchDetail.startError")
        }

        if store.canStartPartnerChat {
          Button {
            Task { await store.startPartnerChat().value }
          } label: {
            HStack(spacing: 10) {
              if store.isStartingPartnerChat {
                ProgressView()
                  .tint(ReferencePalette.ink)
              }
              Text("Start Partner Ward")
            }
          }
          .buttonStyle(ReferenceOutlineButtonStyle())
          .disabled(store.isStartingPartnerChat)
          .accessibilityIdentifier("matchDetail.startPartnerWard")
        }

        if let partnerStartError = store.partnerStartError {
          VStack(alignment: .leading, spacing: 6) {
            Text("Partner Ward unavailable")
              .font(.subheadline.weight(.semibold))
            Text(partnerStartError.startUserMessage)
              .font(.footnote)
              .foregroundStyle(ReferencePalette.muted)
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(ReferencePalette.field)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          .accessibilityIdentifier("matchDetail.partnerWardStartError")
        }

        if let partnerChatID = detail.partnerFoxChatID {
          NavigationLink {
            PartnerWardChatView(
              ownerID: ownerID,
              matchID: matchID,
              partnerID: detail.partnerID,
              chatID: partnerChatID,
              api: api,
              onOpenSettings: {
                store.cancel()
                onOpenSettings()
              },
              onOpenReport: onOpenReport,
              onOpenMeetup: onOpenMeetup,
              onOpenChatRequest: onOpenChatRequest
            )
            .id("partner-ward-\(ownerID)-\(matchID.uuidString)-\(partnerChatID.uuidString)")
          } label: {
            partnerWardEntry(partnerName: detail.partner.displayName)
          }
          .buttonStyle(.plain)
          .accessibilityHint("Open the Partner Ward conversation")
          .accessibilityIdentifier("matchDetail.partnerWard")

          if let onOpenChatRequest,
            detail.status == "partner_chat_started"
              || detail.status == "fox_conversation_completed"
          {
            Button {
              onOpenChatRequest(matchID)
            } label: {
              Label("Request direct chat", systemImage: "bubble.left.and.bubble.right")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ReferenceOutlineButtonStyle())
            .accessibilityIdentifier("matchDetail.requestDirectChat")
          }
        }

        historySurface
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
  }

  @ViewBuilder
  private var historySurface: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Ward conversation")
            .font(.title3.weight(.bold))
            .accessibilityIdentifier("matchDetail.history")
          Text("CONVERSATION HISTORY")
            .font(.caption2.weight(.bold))
            .tracking(1.4)
            .foregroundStyle(ReferencePalette.muted)
        }
        Spacer(minLength: 12)
        if let conversation = store.conversation {
          Text("\(conversation.currentRound) / \(conversation.totalRounds)")
            .font(.caption.weight(.bold))
            .foregroundStyle(ReferencePalette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ReferencePalette.yellowSoft)
            .clipShape(Capsule())
            .accessibilityLabel(
              "Round \(conversation.currentRound) of \(conversation.totalRounds)"
            )
            .accessibilityIdentifier("matchDetail.history.round")
        }
      }

      if store.conversation == nil || store.messages.isEmpty {
        Text("No conversation messages are available yet.")
          .font(.body)
          .foregroundStyle(ReferencePalette.muted)
          .accessibilityIdentifier("matchDetail.history.empty")
      } else {
        VStack(alignment: .leading, spacing: 13) {
          ForEach(store.messages) { message in
            messageRow(message, partnerName: store.detail?.partner.displayName ?? "Partner")
          }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReferencePalette.cream)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

        Text("最初の最大100件を表示しています")
          .font(.footnote)
          .foregroundStyle(ReferencePalette.muted)
          .accessibilityIdentifier("matchDetail.history.limitNotice")
      }
      if store.detail?.status == "fox_conversation_in_progress" {
        Button("Refresh status") {
          Task { await store.retry().value }
        }
        .buttonStyle(ReferenceOutlineButtonStyle())
        .accessibilityIdentifier("matchDetail.history.refresh")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func messageRow(_ message: FoxConversationMessage, partnerName: String) -> some View {
    let isMine = message.speaker == .myFox
    let speaker = isMine ? "Your Ward" : "\(partnerName)'s Ward"

    return HStack(alignment: .bottom, spacing: 8) {
      if isMine {
        Spacer(minLength: 40)
      }

      VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
        Text(speaker)
          .font(.caption2.weight(.bold))
          .foregroundStyle(isMine ? ReferencePalette.ink.opacity(0.58) : ReferencePalette.muted)
        Text(message.content)
          .font(.body)
          .foregroundStyle(ReferencePalette.ink)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Text(message.createdAt, style: .time)
          .font(.caption2)
          .foregroundStyle(isMine ? ReferencePalette.ink.opacity(0.58) : ReferencePalette.muted)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
      .background(isMine ? ReferencePalette.yellow : .white)
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: 19,
          bottomLeadingRadius: isMine ? 19 : 5,
          bottomTrailingRadius: isMine ? 5 : 19,
          topTrailingRadius: 19
        )
      )
      .overlay {
        if !isMine {
          UnevenRoundedRectangle(
            topLeadingRadius: 19,
            bottomLeadingRadius: 5,
            bottomTrailingRadius: 19,
            topTrailingRadius: 19
          )
          .stroke(ReferencePalette.line, lineWidth: 1)
        }
      }
      .frame(maxWidth: 310, alignment: isMine ? .trailing : .leading)
      .accessibilityIdentifier("matchDetail.message.\(message.id.uuidString)")

      if !isMine {
        Spacer(minLength: 40)
      }
    }
    .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
  }

  private func statusCopy(for status: String) -> String {
    switch status {
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

  private func partnerWardEntry(partnerName: String) -> some View {
    HStack(spacing: 14) {
      Image(systemName: "message.and.waveform")
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(ReferencePalette.ink)
        .frame(width: 44, height: 44)
        .background(ReferencePalette.yellowSoft)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

      VStack(alignment: .leading, spacing: 4) {
        Text("Partner Ward")
          .font(.subheadline.weight(.bold))
        Text("Read the conversation with \(partnerName)")
          .font(.footnote)
          .foregroundStyle(ReferencePalette.muted)
      }

      Spacer(minLength: 8)
      Image(systemName: "chevron.right")
        .font(.caption.weight(.bold))
        .foregroundStyle(ReferencePalette.muted)
        .accessibilityHidden(true)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ReferencePalette.field)
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(ReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

/// Partner Ward history and composer. The API owns all access checks and
/// generates the Fox response; this view publishes only returned messages.
struct PartnerWardChatView: View {
  let ownerID: String
  let matchID: UUID
  let partnerID: UUID
  let chatID: UUID
  let api: any MatchDetailAPI
  let onOpenSettings: () -> Void
  let onOpenReport: ((UUID, ReportContext) -> Void)?
  let onOpenMeetup: ((UUID) -> Void)?
  let onOpenChatRequest: ((UUID) -> Void)?

  @Environment(\.dismiss) private var dismiss
  @State private var store: PartnerWardStore
  @State private var draft = ""
  @FocusState private var composerFocused: Bool

  init(
    ownerID: String,
    matchID: UUID,
    partnerID: UUID,
    chatID: UUID,
    api: any MatchDetailAPI,
    onOpenSettings: @escaping () -> Void = {},
    onOpenReport: ((UUID, ReportContext) -> Void)? = nil,
    onOpenMeetup: ((UUID) -> Void)? = nil,
    onOpenChatRequest: ((UUID) -> Void)? = nil,
    retryReceiptStore: (any MessageSendRetryReceiptStoring)? = nil
  ) {
    self.ownerID = ownerID
    self.matchID = matchID
    self.partnerID = partnerID
    self.chatID = chatID
    self.api = api
    self.onOpenSettings = onOpenSettings
    self.onOpenReport = onOpenReport
    self.onOpenMeetup = onOpenMeetup
    self.onOpenChatRequest = onOpenChatRequest
    _store = State(
      initialValue: PartnerWardStore(
        ownerID: ownerID,
        matchID: matchID,
        partnerID: partnerID,
        chatID: chatID,
        api: api,
        retryReceiptStore: retryReceiptStore
      )
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      ReferenceHeader(
        onLogo: {
          store.cancel()
          dismiss()
        },
        onProfile: {
          store.cancel()
          onOpenSettings()
        },
        profileIdentifier: "partnerWard.settings",
        notificationIdentifier: "partnerWard.notifications",
        notificationLabel: "お知らせはまだ利用できません"
      )

      ReferenceProgressHeader(
        backTitle: "Match detail",
        progress: "PARTNER WARD",
        progressValue: 0,
        showsProgress: false,
        backIdentifier: "partnerWard.back"
      ) {
        store.cancel()
        dismiss()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          switch store.phase {
          case .idle, .loading:
            loadingSurface
          case let .failed(error):
            failureSurface(error)
          case .loaded:
            loadedSurface
          }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
    }
    .background(ReferencePalette.cream)
    .toolbar(.hidden, for: .navigationBar)
    .foregroundStyle(ReferencePalette.ink)
    .environment(\.colorScheme, .light)
    .tint(ReferencePalette.ink)
    .preferredColorScheme(.light)
    .task(id: "\(ownerID)-\(matchID.uuidString)-\(chatID.uuidString)") {
      await store.load().value
    }
    .onDisappear {
      store.cancel()
    }
  }

  private var loadingSurface: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Partner Ward")
        .font(.system(size: 30, weight: .bold))
      Text("Loading the conversation history.")
        .font(.body)
        .foregroundStyle(ReferencePalette.muted)
      ProgressView()
        .tint(ReferencePalette.yellow)
        .frame(minHeight: 48)
        .accessibilityIdentifier("partnerWard.loading")
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

  private func failureSurface(_ error: PartnerWardStoreError) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Image(systemName: "arrow.clockwise.circle")
        .font(.system(size: 32, weight: .medium))
        .foregroundStyle(ReferencePalette.yellow)
        .accessibilityHidden(true)
      Text("We couldn't load this conversation")
        .font(.title2.weight(.bold))
      Text(error.userMessage)
        .font(.body)
        .foregroundStyle(ReferencePalette.muted)
      Button("Try again") {
        Task { await store.retry().value }
      }
      .buttonStyle(ReferencePrimaryButtonStyle())
      .accessibilityIdentifier("partnerWard.retry")
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
  private var loadedSurface: some View {
    if let chat = store.chat {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .center, spacing: 14) {
          Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 56, weight: .medium))
            .foregroundStyle(ReferencePalette.muted)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 5) {
            Text("PARTNER WARD")
              .font(.caption.weight(.bold))
              .tracking(1.6)
              .foregroundStyle(ReferencePalette.ink.opacity(0.72))
            Text(chat.partner.displayName)
              .font(.system(size: 30, weight: .bold))
              .accessibilityIdentifier("partnerWard.detail")
            Text("Conversation history")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(ReferencePalette.ink.opacity(0.72))
          }
          Spacer(minLength: 0)
        }

        if let onOpenReport {
          Button {
            onOpenReport(partnerID, .partnerFoxChat)
          } label: {
            Label("Report or block", systemImage: "exclamationmark.shield")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(ReferenceOutlineButtonStyle())
          .accessibilityIdentifier("partnerWard.report")
        }

        if let onOpenChatRequest {
          Button {
            onOpenChatRequest(matchID)
          } label: {
            Label("Request direct chat", systemImage: "bubble.left.and.bubble.right")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(ReferenceOutlineButtonStyle())
          .accessibilityIdentifier("partnerWard.requestDirectChat")
        }

        if let onOpenMeetup {
          Button {
            onOpenMeetup(matchID)
          } label: {
            Label("Plan a meetup", systemImage: "calendar")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(ReferenceOutlineButtonStyle())
          .accessibilityIdentifier("partnerWard.meetup")
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("Partner Ward conversation")
            .font(.title3.weight(.bold))
            .accessibilityIdentifier("partnerWard.history")
          Text("PARTNER WARD CHAT")
            .font(.caption2.weight(.bold))
            .tracking(1.4)
            .foregroundStyle(ReferencePalette.muted)

          if store.messages.isEmpty {
            Text("No conversation messages are available yet.")
              .font(.body)
              .foregroundStyle(ReferencePalette.muted)
              .accessibilityIdentifier("partnerWard.history.empty")
          } else {
            VStack(alignment: .leading, spacing: 13) {
              ForEach(store.messages) { message in
                partnerMessageRow(message, partnerName: chat.partner.displayName)
              }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReferencePalette.cream)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          }

          composer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .bottom, spacing: 10) {
        TextField("Write to Partner Ward", text: $draft, axis: .vertical)
          .lineLimit(1...5)
          .focused($composerFocused)
          .textInputAutocapitalization(.sentences)
          .autocorrectionDisabled(false)
          .padding(.horizontal, 14)
          .padding(.vertical, 11)
          .frame(minHeight: 48)
          .background(ReferencePalette.field)
          .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
          .accessibilityLabel("Partner Ward message")
          .accessibilityHint("Enter up to 2,000 characters")
          .accessibilityIdentifier("partnerWard.composer")

        Button {
          let value = draft
          composerFocused = false
          Task {
            await store.sendMessage(value).value
            if store.lastSentMessageID != nil, draft == value {
              draft = ""
            }
          }
        } label: {
          Group {
            if store.isSending {
              ProgressView()
                .tint(ReferencePalette.ink)
            } else {
              Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
            }
          }
          .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .background(ReferencePalette.yellow)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .disabled(
          store.isSending
            || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.count > 2_000
        )
        .accessibilityLabel("Send Partner Ward message")
        .accessibilityIdentifier("partnerWard.send")
      }

      HStack {
        Text("\(draft.count) / 2,000")
          .font(.caption2)
          .foregroundStyle(draft.count > 2_000 ? .red : ReferencePalette.muted)
        Spacer()
      }

      if let sendError = store.sendError {
        HStack(alignment: .top, spacing: 8) {
          Text(sendError.sendUserMessage)
            .font(.footnote)
            .foregroundStyle(ReferencePalette.muted)
          Spacer(minLength: 0)
          if !store.isSending {
            Button("Retry") {
              let value = draft
              Task {
                await store.sendMessage(value).value
                if store.lastSentMessageID != nil, draft == value {
                  draft = ""
                }
              }
            }
            .font(.footnote.weight(.semibold))
            .frame(minHeight: 44)
            .accessibilityIdentifier("partnerWard.send.retry")
          }
        }
        .accessibilityIdentifier("partnerWard.sendError")
      }
    }
    .padding(.top, 4)
  }

  private func partnerMessageRow(_ message: PartnerFoxMessage, partnerName: String) -> some View {
    let isMine = message.role == .user
    let speaker = isMine ? "You" : "\(partnerName)'s Ward"

    return HStack(alignment: .bottom, spacing: 8) {
      if isMine {
        Spacer(minLength: 40)
      }

      VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
        Text(speaker)
          .font(.caption2.weight(.bold))
          .foregroundStyle(isMine ? ReferencePalette.ink.opacity(0.58) : ReferencePalette.muted)
        Text(message.content)
          .font(.body)
          .foregroundStyle(ReferencePalette.ink)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Text(message.createdAt, style: .time)
          .font(.caption2)
          .foregroundStyle(isMine ? ReferencePalette.ink.opacity(0.58) : ReferencePalette.muted)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
      .background(isMine ? ReferencePalette.yellow : .white)
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: 19,
          bottomLeadingRadius: isMine ? 19 : 5,
          bottomTrailingRadius: isMine ? 5 : 19,
          topTrailingRadius: 19
        )
      )
      .overlay {
        if !isMine {
          UnevenRoundedRectangle(
            topLeadingRadius: 19,
            bottomLeadingRadius: 5,
            bottomTrailingRadius: 19,
            topTrailingRadius: 19
          )
          .stroke(ReferencePalette.line, lineWidth: 1)
        }
      }
      .frame(maxWidth: 310, alignment: isMine ? .trailing : .leading)
      .accessibilityIdentifier("partnerWard.message.\(message.id.uuidString)")

      if !isMine {
        Spacer(minLength: 40)
      }
    }
    .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
  }
}
