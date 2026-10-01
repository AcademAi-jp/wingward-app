import SwiftUI

private enum DirectChatCopyKey {
  case notificationUnavailable
  case homeAccessibility
  case profileAccessibility
  case directChatsBack
  case directChatsProgress
  case directChatsLoadingTitle
  case directChatsLoadingBody
  case directChatsLoadFailedTitle
  case retry
  case directChatsKicker
  case directChatsTitle
  case refresh
  case directChatsEmptyTitle
  case directChatsEmptyBody
  case member
  case startConversation
  case unreadMessages
  case reviewRequests
  case chatBack
  case chatProgress
  case reportBlock
  case chatLoadFailedTitle
  case loadEarlierMessages
  case chatEmpty
  case you
  case messagePlaceholder
  case messageAccessibilityLabel
  case messageAccessibilityHint
  case sendMessage
  case retrySend
  case chatRequestsBack
  case chatRequestsProgress
  case chatRequestsLoadingTitle
  case chatRequestsLoadingBody
  case chatRequestsLoadFailedTitle
  case chatRequestsKicker
  case chatRequestsTitle
  case chatRequestsEmptyTitle
  case requestBody
  case decline
  case accept
  case directRequestBack
  case directRequestProgress
  case directRequestKicker
  case directRequestTitle
  case directRequestBody
  case sending
  case sendRequest
  case requestSentTitle
  case requestSentBody
  case expires

  var japanese: String {
    switch self {
    case .notificationUnavailable: return "お知らせはまだ利用できません"
    case .homeAccessibility: return "ホームへ"
    case .profileAccessibility: return "プロフィール設定"
    case .directChatsBack: return "マッチ"
    case .directChatsProgress: return "ダイレクトチャット"
    case .directChatsLoadingTitle: return "ダイレクトチャット"
    case .directChatsLoadingBody: return "会話を読み込んでいます。"
    case .directChatsLoadFailedTitle: return "ダイレクトチャットを読み込めませんでした"
    case .retry: return "再試行"
    case .directChatsKicker: return "ダイレクトチャット"
    case .directChatsTitle: return "気持ちを大切にする会話"
    case .refresh: return "ダイレクトチャットを更新"
    case .directChatsEmptyTitle: return "ダイレクトチャットはまだありません"
    case .directChatsEmptyBody: return "チャットリクエストが承認されると、ここに会話が表示されます。"
    case .member: return "WingWardメンバー"
    case .startConversation: return "会話を始める"
    case .unreadMessages: return "未読メッセージ"
    case .reviewRequests: return "チャットリクエストを確認"
    case .chatBack: return "ダイレクトチャット"
    case .chatProgress: return "チャット"
    case .reportBlock: return "報告またはブロック"
    case .chatLoadFailedTitle: return "このチャットを読み込めませんでした"
    case .loadEarlierMessages: return "以前のメッセージを読み込む"
    case .chatEmpty: return "まだメッセージはありません。準備ができたら会話を始めましょう。"
    case .you: return "あなた"
    case .messagePlaceholder: return "メッセージを書く"
    case .messageAccessibilityLabel: return "ダイレクトチャットのメッセージ"
    case .messageAccessibilityHint: return "1,000文字以内で入力してください"
    case .sendMessage: return "ダイレクトチャットのメッセージを送信"
    case .retrySend: return "再送信"
    case .chatRequestsBack: return "ダイレクトチャット"
    case .chatRequestsProgress: return "チャットリクエスト"
    case .chatRequestsLoadingTitle: return "チャットリクエスト"
    case .chatRequestsLoadingBody: return "リクエストを読み込んでいます。"
    case .chatRequestsLoadFailedTitle: return "チャットリクエストを読み込めませんでした"
    case .chatRequestsKicker: return "チャットリクエスト"
    case .chatRequestsTitle: return "つながりたい人からのリクエスト"
    case .chatRequestsEmptyTitle: return "チャットリクエストはまだありません"
    case .requestBody: return "ダイレクトチャットを始めたいと考えています。"
    case .decline: return "辞退"
    case .accept: return "承認"
    case .directRequestBack: return "マッチの詳細"
    case .directRequestProgress: return "ダイレクトチャットリクエスト"
    case .directRequestKicker: return "ダイレクトチャット"
    case .directRequestTitle: return "ダイレクトチャットをリクエスト"
    case .directRequestBody: return "会話を直接続けるためのリクエストを1件送ります。承認するかどうかは相手が決めます。"
    case .sending: return "送信中…"
    case .sendRequest: return "リクエストを送信"
    case .requestSentTitle: return "リクエストを送信しました"
    case .requestSentBody: return "相手が承認すると、ダイレクトチャットを始められます。"
    case .expires: return "有効期限"
    }
  }

  var english: String {
    switch self {
    case .notificationUnavailable: return "Notifications aren't available yet"
    case .homeAccessibility: return "Go to home"
    case .profileAccessibility: return "Profile settings"
    case .directChatsBack: return "Matches"
    case .directChatsProgress: return "DIRECT CHAT"
    case .directChatsLoadingTitle: return "Direct chats"
    case .directChatsLoadingBody: return "Loading your conversations."
    case .directChatsLoadFailedTitle: return "We couldn't load direct chats"
    case .retry: return "Try again"
    case .directChatsKicker: return "DIRECT CHAT"
    case .directChatsTitle: return "Conversations with intention"
    case .refresh: return "Refresh direct chats"
    case .directChatsEmptyTitle: return "No direct chats yet"
    case .directChatsEmptyBody: return "When a chat request is accepted, the conversation will appear here."
    case .member: return "WingWard member"
    case .startConversation: return "Start a conversation"
    case .unreadMessages: return "unread messages"
    case .reviewRequests: return "Review chat requests"
    case .chatBack: return "Direct chats"
    case .chatProgress: return "CHAT"
    case .reportBlock: return "Report or block"
    case .chatLoadFailedTitle: return "We couldn't load this chat"
    case .loadEarlierMessages: return "Load earlier messages"
    case .chatEmpty: return "No messages yet. Start the conversation when you're ready."
    case .you: return "You"
    case .messagePlaceholder: return "Write a message"
    case .messageAccessibilityLabel: return "Direct chat message"
    case .messageAccessibilityHint: return "Enter up to 1,000 characters"
    case .sendMessage: return "Send direct chat message"
    case .retrySend: return "Retry"
    case .chatRequestsBack: return "Direct chats"
    case .chatRequestsProgress: return "CHAT REQUESTS"
    case .chatRequestsLoadingTitle: return "Chat requests"
    case .chatRequestsLoadingBody: return "Loading your requests."
    case .chatRequestsLoadFailedTitle: return "We couldn't load chat requests"
    case .chatRequestsKicker: return "CHAT REQUESTS"
    case .chatRequestsTitle: return "Requests from people who want to connect"
    case .chatRequestsEmptyTitle: return "No chat requests yet"
    case .requestBody: return "Would like to start a direct chat."
    case .decline: return "Decline"
    case .accept: return "Accept"
    case .directRequestBack: return "Match detail"
    case .directRequestProgress: return "DIRECT CHAT REQUEST"
    case .directRequestKicker: return "DIRECT CHAT"
    case .directRequestTitle: return "Request a direct chat"
    case .directRequestBody: return "Send one request to continue the conversation directly. The other person decides whether to accept."
    case .sending: return "Sending…"
    case .sendRequest: return "Send request"
    case .requestSentTitle: return "Request sent"
    case .requestSentBody: return "Once they accept, you can start a direct chat."
    case .expires: return "Expires"
    }
  }

  func value(for language: BilingualReferenceLanguage) -> String {
    switch language {
    case .japanese: return japanese
    case .english: return english
    }
  }
}

private enum DirectChatErrorContext {
  case list
  case chat
  case requests
  case send
  case createRequest
  case requestAction
}

private extension Locale {
  var directChatLanguage: BilingualReferenceLanguage {
    identifier.lowercased().hasPrefix("ja") ? .japanese : .english
  }
}

private func directChatCopy(
  _ key: DirectChatCopyKey,
  language: BilingualReferenceLanguage
) -> String {
  key.value(for: language)
}

private func directChatErrorMessage(
  _ error: DirectChatsStoreError,
  context: DirectChatErrorContext,
  language: BilingualReferenceLanguage
) -> String {
  switch (context, error) {
  case (_, .ageVerificationRequired):
    return language == .japanese
      ? "ダイレクトチャットを利用する前に年齢確認を完了してください。"
      : "Verify your age before using direct chat."
  case (_, .invalidRequest):
    return language == .japanese
      ? "メッセージは1,000文字以内で入力してください。"
      : "Enter a message up to 1,000 characters."
  case (_, .invalidState):
    return language == .japanese
      ? "このチャットは利用できなくなりました。"
      : "This chat is no longer available."
  case (_, .rateLimited):
    return language == .japanese
      ? "少し待ってから、もう一度お試しください。"
      : "Please wait a moment, then try again."
  case (.send, _):
    return language == .japanese
      ? "メッセージを送信できませんでした。もう一度お試しください。"
      : "We couldn't send your message. Try again."
  case (.createRequest, _):
    return language == .japanese
      ? "リクエストを送信できませんでした。もう一度お試しください。"
      : "We couldn't send the request. Try again."
  case (.requestAction, _):
    return language == .japanese
      ? "リクエストを処理できませんでした。もう一度お試しください。"
      : "We couldn't process the request. Try again."
  case (.chat, _):
    return language == .japanese
      ? "このチャットを読み込めませんでした。もう一度お試しください。"
      : "We couldn't load this chat. Try again."
  case (.requests, _):
    return language == .japanese
      ? "チャットリクエストを読み込めませんでした。もう一度お試しください。"
      : "We couldn't load chat requests. Try again."
  case (.list, _):
    return language == .japanese
      ? "ダイレクトチャットを読み込めませんでした。もう一度お試しください。"
      : "We couldn't load direct chats. Try again."
  }
}

private func directChatDisplayName(
  _ nickname: String?,
  language: BilingualReferenceLanguage
) -> String {
  let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  return trimmed.isEmpty ? directChatCopy(.member, language: language) : trimmed
}

private struct DirectChatHeader: View {
  let onLogo: () -> Void
  let onProfile: () -> Void
  let profileIdentifier: String
  let notificationIdentifier: String
  let notificationLabel: String
  @Environment(\.locale) private var locale

  var body: some View {
    HStack {
      Button(action: onLogo) {
        HStack(spacing: 10) {
          Image(systemName: "sparkles")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(BilingualReferencePalette.ink)
            .frame(width: 32, height: 32)
            .background(BilingualReferencePalette.yellow)
            .clipShape(
              UnevenRoundedRectangle(
                topLeadingRadius: 11,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: 11,
                topTrailingRadius: 11
              )
            )
        }
      }
      .buttonStyle(.plain)
      .foregroundStyle(BilingualReferencePalette.ink)
      .accessibilityLabel(
        directChatCopy(.homeAccessibility, language: locale.directChatLanguage)
      )
      .accessibilityIdentifier("reference.logo")

      Spacer()

      Image(systemName: "bell")
        .font(.system(size: 19, weight: .medium))
        .foregroundStyle(BilingualReferencePalette.ink)
        .frame(width: 44, height: 44)
        .accessibilityLabel(notificationLabel)
        .accessibilityIdentifier(notificationIdentifier)

      Button(action: onProfile) {
        Circle()
          .fill(BilingualReferencePalette.field)
          .frame(width: 34, height: 34)
          .overlay {
            Image(systemName: "person.fill")
              .font(.system(size: 14, weight: .medium))
              .foregroundStyle(BilingualReferencePalette.muted)
          }
          .overlay {
            Circle().stroke(BilingualReferencePalette.line, lineWidth: 1)
          }
      }
      .buttonStyle(.plain)
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
      .accessibilityLabel(
        directChatCopy(.profileAccessibility, language: locale.directChatLanguage)
      )
      .accessibilityIdentifier(profileIdentifier)
    }
    .padding(.horizontal, 18)
    .frame(height: 64)
    .background(.white)
    .overlay(alignment: .bottom) {
      Rectangle().fill(BilingualReferencePalette.line).frame(height: 1)
    }
  }
}

private struct DirectChatProgressHeader: View {
  let backTitle: String
  let progress: String
  let progressValue: Double
  let showsProgress: Bool
  let backIdentifier: String
  let onBack: () -> Void
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Button(action: onBack) {
          Label(backTitle, systemImage: "chevron.left")
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(BilingualReferencePalette.ink)
        .frame(minHeight: 44)
        .accessibilityIdentifier(backIdentifier)
        Spacer()
        Text(progress)
          .font(.caption.weight(.bold))
          .tracking(1.2)
          .foregroundStyle(BilingualReferencePalette.muted)
      }
      if showsProgress {
        ProgressView(value: progressValue)
          .tint(BilingualReferencePalette.yellow)
          .accessibilityLabel(locale.directChatLanguage == .japanese ? "進捗" : "Progress")
          .accessibilityValue(
            locale.directChatLanguage == .japanese
              ? "\(Int(progressValue * 100))パーセント"
              : "\(Int(progressValue * 100))%"
          )
      }
    }
  }
}

struct DirectChatsView: View {
  let ownerID: String
  let api: any DirectChatsAPI
  let onOpenSettings: () -> Void
  let onOpenReport: ((UUID, ReportContext) -> Void)?
  let onOpenReportForMatch: ((UUID, ReportContext) -> Void)?
  let onOpenChatRequests: (() -> Void)?
  let calendarProvider: any NativeBusyCalendarProvider
  let locationProvider: any NativeMeetupLocationProvider
  let reflectionTransport: any VoiceInterviewTransport
  let voicePermissionClient: any VoicePermissionClient
  let retryReceiptStore: (any MessageSendRetryReceiptStoring)?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @State private var store: DirectChatsStore

  init(
    ownerID: String,
    api: any DirectChatsAPI,
    onOpenSettings: @escaping () -> Void = {},
    onOpenReport: ((UUID, ReportContext) -> Void)? = nil,
    onOpenReportForMatch: ((UUID, ReportContext) -> Void)? = nil,
    onOpenChatRequests: (() -> Void)? = nil,
    calendarProvider: any NativeBusyCalendarProvider = UnavailableNativeBusyCalendarProvider(),
    locationProvider: any NativeMeetupLocationProvider = UnavailableNativeMeetupLocationProvider(),
    reflectionTransport: any VoiceInterviewTransport = UnavailableVoiceInterviewTransport(),
    voicePermissionClient: any VoicePermissionClient = SystemVoicePermissionClient(),
    retryReceiptStore: (any MessageSendRetryReceiptStoring)? = nil
  ) {
    self.ownerID = ownerID
    self.api = api
    self.onOpenSettings = onOpenSettings
    self.onOpenReport = onOpenReport
    self.onOpenReportForMatch = onOpenReportForMatch
    self.onOpenChatRequests = onOpenChatRequests
    self.calendarProvider = calendarProvider
    self.locationProvider = locationProvider
    self.reflectionTransport = reflectionTransport
    self.voicePermissionClient = voicePermissionClient
    self.retryReceiptStore = retryReceiptStore
    _store = State(initialValue: DirectChatsStore(ownerID: ownerID, api: api))
  }

  var body: some View {
    let language = locale.directChatLanguage
    VStack(spacing: 0) {
      DirectChatHeader(
        onLogo: {
          store.cancel()
          dismiss()
        },
        onProfile: {
          store.cancel()
          onOpenSettings()
        },
        profileIdentifier: "directChats.settings",
        notificationIdentifier: "directChats.notifications",
        notificationLabel: directChatCopy(.notificationUnavailable, language: language)
      )

      DirectChatProgressHeader(
        backTitle: directChatCopy(.directChatsBack, language: language),
        progress: directChatCopy(.directChatsProgress, language: language),
        progressValue: 0,
        showsProgress: false,
        backIdentifier: "directChats.back"
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
    .background(BilingualReferencePalette.cream)
    .toolbar(.hidden, for: .navigationBar)
    .foregroundStyle(BilingualReferencePalette.ink)
    .environment(\.colorScheme, .light)
    .tint(BilingualReferencePalette.ink)
    .preferredColorScheme(.light)
    .task(id: ownerID) {
      await store.load().value
    }
    .onDisappear {
      store.cancel()
    }
  }

  private var loadingSurface: some View {
    let language = locale.directChatLanguage
    return VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Image(systemName: "bubble.left.and.bubble.right.fill")
          .font(.title3.weight(.semibold))
          .foregroundStyle(BilingualReferencePalette.ink)
          .frame(width: 44, height: 44)
          .background(BilingualReferencePalette.softYellow)
          .clipShape(Circle())
          .accessibilityHidden(true)
        Text(directChatCopy(.directChatsLoadingTitle, language: language))
          .font(.title2.weight(.bold))
      }
      Text(directChatCopy(.directChatsLoadingBody, language: language))
        .font(.body)
        .foregroundStyle(BilingualReferencePalette.muted)
      ProgressView()
        .tint(BilingualReferencePalette.yellow)
        .frame(minHeight: 48)
        .accessibilityIdentifier("directChats.loading")
    }
    .cardSurface()
  }

  private func failureSurface(_ error: DirectChatsStoreError) -> some View {
    let language = locale.directChatLanguage
    return VStack(alignment: .leading, spacing: 16) {
      Image(systemName: "arrow.clockwise.circle")
        .font(.system(size: 32, weight: .medium))
        .foregroundStyle(BilingualReferencePalette.yellow)
        .accessibilityHidden(true)
      Text(directChatCopy(.directChatsLoadFailedTitle, language: language))
        .font(.title2.weight(.bold))
      Text(directChatErrorMessage(error, context: .list, language: language))
        .font(.body)
        .foregroundStyle(BilingualReferencePalette.muted)
      Button(directChatCopy(.retry, language: language)) {
        Task { await store.retry().value }
      }
      .buttonStyle(BilingualReferencePrimaryButtonStyle())
      .accessibilityIdentifier("directChats.retry")
    }
    .cardSurface()
  }

  @ViewBuilder
  private var loadedSurface: some View {
    let language = locale.directChatLanguage
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .bottom) {
        VStack(alignment: .leading, spacing: 5) {
          Text(directChatCopy(.directChatsKicker, language: language))
            .font(.caption2.weight(.bold))
            .tracking(1.5)
            .foregroundStyle(BilingualReferencePalette.ink.opacity(0.72))
          Text(directChatCopy(.directChatsTitle, language: language))
            .font(.title.weight(.bold))
        }
        Spacer()
        Button {
          Task { await store.retry().value }
        } label: {
          Image(systemName: "arrow.clockwise")
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(BilingualReferencePalette.ink)
        .background(BilingualReferencePalette.softYellow)
        .clipShape(Circle())
        .accessibilityLabel(directChatCopy(.refresh, language: language))
        .accessibilityIdentifier("directChats.refresh")
      }

      ChatRequestsView(
        ownerID: ownerID,
        api: api,
        onAccepted: { _ in Task { await store.retry().value } },
        onOpenReportForMatch: onOpenReportForMatch,
        inline: true
      )

      if store.chats.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Image(systemName: "bubble.left.and.bubble.right")
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(BilingualReferencePalette.yellow)
            .accessibilityHidden(true)
          Text(directChatCopy(.directChatsEmptyTitle, language: language))
            .font(.title3.weight(.bold))
          Text(directChatCopy(.directChatsEmptyBody, language: language))
            .font(.body)
            .foregroundStyle(BilingualReferencePalette.muted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BilingualReferencePalette.field)
        .overlay {
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(BilingualReferencePalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("directChats.empty")
      } else {
        LazyVStack(spacing: 10) {
          ForEach(store.chats) { chat in
            NavigationLink {
              DirectChatView(
                ownerID: ownerID,
                summary: chat,
                api: api,
                onOpenReport: onOpenReport,
                onOpenReportForMatch: onOpenReportForMatch,
                calendarProvider: calendarProvider,
                locationProvider: locationProvider,
                reflectionTransport: reflectionTransport,
                voicePermissionClient: voicePermissionClient,
                retryReceiptStore: retryReceiptStore
              )
              .id("direct-chat-\(ownerID)-\(chat.id.uuidString)")
            } label: {
              directChatRow(chat)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("directChats.row.\(chat.id.uuidString)")
          }
        }
      }

      if let onOpenChatRequests {
        Button {
          onOpenChatRequests()
        } label: {
          Label(directChatCopy(.reviewRequests, language: language), systemImage: "person.2.wave.2")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
        .accessibilityIdentifier("directChats.requests")
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .shadow(color: BilingualReferencePalette.ink.opacity(0.05), radius: 16, y: 8)
  }

  private func directChatRow(_ chat: DirectChatSummary) -> some View {
    let language = locale.directChatLanguage
    return HStack(spacing: 14) {
      Image(systemName: "person.crop.circle.fill")
        .font(.system(size: 38, weight: .medium))
        .foregroundStyle(BilingualReferencePalette.muted)
        .frame(width: 48, height: 48)
        .background(BilingualReferencePalette.softYellow)
        .clipShape(Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(directChatDisplayName(chat.partner?.nickname, language: language))
          .font(.subheadline.weight(.bold))
        if let lastMessage = chat.lastMessage {
          Text(lastMessage.content)
            .font(.footnote)
            .foregroundStyle(BilingualReferencePalette.muted)
            .lineLimit(1)
        } else {
          Text(directChatCopy(.startConversation, language: language))
            .font(.footnote)
            .foregroundStyle(BilingualReferencePalette.muted)
        }
      }
      Spacer(minLength: 8)
      if chat.unreadCountAfterSeen > 0 {
        Text("\(chat.unreadCountAfterSeen)")
          .font(.caption.weight(.bold))
          .foregroundStyle(BilingualReferencePalette.ink)
          .frame(minWidth: 28, minHeight: 28)
          .background(BilingualReferencePalette.yellow)
          .clipShape(Circle())
          .accessibilityLabel(
            language == .japanese
              ? "\(chat.unreadCountAfterSeen)件の未読メッセージ"
              : "\(chat.unreadCountAfterSeen) \(directChatCopy(.unreadMessages, language: language))"
          )
      }
      Image(systemName: "chevron.right")
        .font(.caption.weight(.bold))
        .foregroundStyle(BilingualReferencePalette.muted)
        .accessibilityHidden(true)
    }
    .padding(14)
    .frame(minHeight: 76)
    .background(BilingualReferencePalette.field)
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

struct DirectChatView: View {
  let ownerID: String
  let summary: DirectChatSummary
  let api: any DirectChatsAPI
  let onOpenReport: ((UUID, ReportContext) -> Void)?
  let onOpenReportForMatch: ((UUID, ReportContext) -> Void)?
  let calendarProvider: any NativeBusyCalendarProvider
  let locationProvider: any NativeMeetupLocationProvider
  let reflectionTransport: any VoiceInterviewTransport
  let voicePermissionClient: any VoicePermissionClient
  let retryReceiptStore: (any MessageSendRetryReceiptStoring)?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @State private var store: DirectChatStore
  @State private var draft = ""
  @FocusState private var composerFocused: Bool

  init(
    ownerID: String,
    summary: DirectChatSummary,
    api: any DirectChatsAPI,
    onOpenReport: ((UUID, ReportContext) -> Void)? = nil,
    onOpenReportForMatch: ((UUID, ReportContext) -> Void)? = nil,
    calendarProvider: any NativeBusyCalendarProvider = UnavailableNativeBusyCalendarProvider(),
    locationProvider: any NativeMeetupLocationProvider = UnavailableNativeMeetupLocationProvider(),
    reflectionTransport: any VoiceInterviewTransport = UnavailableVoiceInterviewTransport(),
    voicePermissionClient: any VoicePermissionClient = SystemVoicePermissionClient(),
    retryReceiptStore: (any MessageSendRetryReceiptStoring)? = nil
  ) {
    self.ownerID = ownerID
    self.summary = summary
    self.api = api
    self.onOpenReport = onOpenReport
    self.onOpenReportForMatch = onOpenReportForMatch
    self.calendarProvider = calendarProvider
    self.locationProvider = locationProvider
    self.reflectionTransport = reflectionTransport
    self.voicePermissionClient = voicePermissionClient
    self.retryReceiptStore = retryReceiptStore
    _store = State(initialValue: DirectChatStore(
      ownerID: ownerID,
      roomID: summary.id,
      api: api,
      retryReceiptStore: retryReceiptStore
    ))
  }

  var body: some View {
    let language = locale.directChatLanguage
    VStack(spacing: 0) {
      DirectChatHeader(
        onLogo: {
          store.cancel()
          dismiss()
        },
        onProfile: {},
        profileIdentifier: "directChat.settings",
        notificationIdentifier: "directChat.notifications",
        notificationLabel: directChatCopy(.notificationUnavailable, language: language)
      )

      DirectChatProgressHeader(
        backTitle: directChatCopy(.chatBack, language: language),
        progress: directChatCopy(.chatProgress, language: language),
        progressValue: 0,
        showsProgress: false,
        backIdentifier: "directChat.back"
      ) {
        store.cancel()
        dismiss()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            switch store.phase {
            case .idle, .loading:
              ProgressView()
                .frame(maxWidth: .infinity, minHeight: 100)
                .accessibilityIdentifier("directChat.loading")
            case let .failed(error):
              failureSurface(error)
            case .loaded:
              loadedContent
            }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 18)
          .frame(maxWidth: 760, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
        .onChange(of: store.messages.count) { _, _ in
          if let last = store.messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
          }
        }
      }
    }
    .background(BilingualReferencePalette.cream)
    .toolbar(.hidden, for: .navigationBar)
    .foregroundStyle(BilingualReferencePalette.ink)
    .environment(\.colorScheme, .light)
    .tint(BilingualReferencePalette.ink)
    .preferredColorScheme(.light)
    .task(id: "\(ownerID)-\(summary.id.uuidString)") {
      await store.load().value
    }
    .onDisappear {
      store.cancel()
    }
  }

  private var loadedContent: some View {
    let language = locale.directChatLanguage
    return VStack(alignment: .leading, spacing: 14) {
      if let onOpenReportForMatch {
        Button {
          // The direct-chat list intentionally omits the partner account ID.
          // The integration resolves this match context through the owner-bound
          // match detail before opening moderation.
          onOpenReportForMatch(summary.matchID, .directChat)
        } label: {
          Label(
            directChatCopy(.reportBlock, language: language),
            systemImage: "exclamationmark.shield"
          )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
        .accessibilityIdentifier("directChat.report")
      }

      ChatMeetupInlineCard(
        ownerID: ownerID,
        roomID: summary.id,
        api: api,
        calendarProvider: calendarProvider,
        locationProvider: locationProvider,
        reflectionTransport: reflectionTransport,
        voicePermissionClient: voicePermissionClient
      )

      if let error = store.loadError {
        Text(directChatErrorMessage(error, context: .chat, language: language))
          .font(.footnote)
          .foregroundStyle(BilingualReferencePalette.muted)
          .accessibilityIdentifier("directChat.loadError")
      }

      if store.hasMore {
        Button {
          Task { await store.loadMore().value }
        } label: {
          HStack(spacing: 8) {
            if store.isLoadingMore {
              ProgressView().tint(BilingualReferencePalette.ink)
            }
            Text(directChatCopy(.loadEarlierMessages, language: language))
          }
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
        .disabled(store.isLoadingMore)
        .accessibilityIdentifier("directChat.loadMore")
      }

      if store.messages.isEmpty {
        Text(directChatCopy(.chatEmpty, language: language))
          .font(.body)
          .foregroundStyle(BilingualReferencePalette.muted)
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(BilingualReferencePalette.field)
          .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .stroke(BilingualReferencePalette.line, lineWidth: 1)
          }
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          .accessibilityIdentifier("directChat.empty")
      } else {
        ForEach(store.messages) { message in
          directMessageRow(message)
            .id(message.id)
            .onAppear {
              if !message.isMine, !message.isRead {
                Task { await store.markRead(message).value }
              }
            }
        }
      }

      composer
    }
  }

  private func failureSurface(_ error: DirectChatsStoreError) -> some View {
    let language = locale.directChatLanguage
    return VStack(alignment: .leading, spacing: 16) {
      Image(systemName: "arrow.clockwise.circle")
        .font(.system(size: 32, weight: .medium))
        .foregroundStyle(BilingualReferencePalette.yellow)
        .accessibilityHidden(true)
      Text(directChatCopy(.chatLoadFailedTitle, language: language))
        .font(.title2.weight(.bold))
      Text(directChatErrorMessage(error, context: .chat, language: language))
        .font(.body)
        .foregroundStyle(BilingualReferencePalette.muted)
      Button(directChatCopy(.retry, language: language)) {
        Task { await store.retry().value }
      }
      .buttonStyle(BilingualReferencePrimaryButtonStyle())
      .accessibilityIdentifier("directChat.retry")
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .shadow(color: BilingualReferencePalette.ink.opacity(0.05), radius: 16, y: 8)
  }

  private func directMessageRow(_ message: DirectChatMessage) -> some View {
    let language = locale.directChatLanguage
    return HStack(alignment: .bottom, spacing: 8) {
      if message.isMine { Spacer(minLength: 40) }
      VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
        Text(
          message.isMine
            ? directChatCopy(.you, language: language)
            : directChatDisplayName(summary.partner?.nickname, language: language)
        )
          .font(.caption2.weight(.bold))
          .foregroundStyle(
            message.isMine
              ? BilingualReferencePalette.ink.opacity(0.58)
              : BilingualReferencePalette.muted
          )
        Text(message.content)
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
        Text(message.createdAt, style: .time)
          .font(.caption2)
          .foregroundStyle(
            message.isMine
              ? BilingualReferencePalette.ink.opacity(0.58)
              : BilingualReferencePalette.muted
          )
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
      .background(message.isMine ? BilingualReferencePalette.yellow : .white)
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: 19,
          bottomLeadingRadius: message.isMine ? 19 : 5,
          bottomTrailingRadius: message.isMine ? 5 : 19,
          topTrailingRadius: 19
        )
      )
      .overlay {
        if !message.isMine {
          UnevenRoundedRectangle(
            topLeadingRadius: 19,
            bottomLeadingRadius: 5,
            bottomTrailingRadius: 19,
            topTrailingRadius: 19
          )
          .stroke(BilingualReferencePalette.line, lineWidth: 1)
        }
      }
      .frame(maxWidth: 310, alignment: message.isMine ? .trailing : .leading)
      .accessibilityIdentifier("directChat.message.\(message.id.uuidString)")
      if !message.isMine { Spacer(minLength: 40) }
    }
    .frame(maxWidth: .infinity, alignment: message.isMine ? .trailing : .leading)
  }

  private var composer: some View {
    let language = locale.directChatLanguage
    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .bottom, spacing: 10) {
        TextField(
          directChatCopy(.messagePlaceholder, language: language),
          text: $draft,
          axis: .vertical
        )
          .lineLimit(1...5)
          .focused($composerFocused)
          .textInputAutocapitalization(.sentences)
          .padding(.horizontal, 14)
          .padding(.vertical, 11)
          .frame(minHeight: 48)
          .background(BilingualReferencePalette.field)
          .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
          .accessibilityLabel(directChatCopy(.messageAccessibilityLabel, language: language))
          .accessibilityHint(directChatCopy(.messageAccessibilityHint, language: language))
          .accessibilityIdentifier("directChat.composer")

        Button {
          let submitted = draft
          composerFocused = false
          Task {
            await store.sendMessage(submitted).value
            if store.lastSentMessageID != nil, draft == submitted {
              draft = ""
            }
          }
        } label: {
          Group {
            if store.isSending {
              ProgressView().tint(BilingualReferencePalette.ink)
            } else {
              Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
            }
          }
          .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .background(BilingualReferencePalette.yellow)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .disabled(
          store.isSending
            || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.count > 1_000
        )
        .accessibilityLabel(directChatCopy(.sendMessage, language: language))
        .accessibilityIdentifier("directChat.send")
      }
      HStack {
        PasteButton(payloadType: String.self) { values in
          guard let value = values.first else { return }
          draft = value
        }
        .accessibilityLabel(language == .japanese ? "メッセージを貼り付け" : "Paste message")
        .accessibilityIdentifier("directChat.paste")
        .disabled(store.isSending)
        Text(
          language == .japanese
            ? "\(draft.count) / 1,000文字"
            : "\(draft.count) / 1,000"
        )
          .font(.caption2)
          .foregroundStyle(draft.count > 1_000 ? .red : BilingualReferencePalette.muted)
        Spacer()
      }
      if let error = store.sendError {
        HStack(alignment: .top, spacing: 8) {
          Text(directChatErrorMessage(error, context: .send, language: language))
            .font(.footnote)
            .foregroundStyle(BilingualReferencePalette.muted)
          Spacer(minLength: 0)
          Button(directChatCopy(.retrySend, language: language)) {
            let submitted = draft
            Task {
              await store.sendMessage(submitted).value
              if store.lastSentMessageID != nil, draft == submitted { draft = "" }
            }
          }
          .font(.footnote.weight(.semibold))
          .frame(minHeight: 44)
          .accessibilityIdentifier("directChat.send.retry")
        }
        .accessibilityIdentifier("directChat.sendError")
      }
    }
  }
}


private struct ChatMeetupInlineCard: View {
  let ownerID: String
  let roomID: UUID
  let api: any DirectChatsAPI
  let calendarProvider: any NativeBusyCalendarProvider
  let locationProvider: any NativeMeetupLocationProvider
  let reflectionTransport: any VoiceInterviewTransport
  let voicePermissionClient: any VoicePermissionClient
  @Environment(\.locale) private var locale
  @State private var store: ChatMeetupStore

  init(ownerID: String, roomID: UUID, api: any DirectChatsAPI,
       calendarProvider: any NativeBusyCalendarProvider,
       locationProvider: any NativeMeetupLocationProvider,
       reflectionTransport: any VoiceInterviewTransport,
       voicePermissionClient: any VoicePermissionClient) {
    self.ownerID = ownerID
    self.roomID = roomID
    self.api = api
    self.calendarProvider = calendarProvider
    self.locationProvider = locationProvider
    self.reflectionTransport = reflectionTransport
    self.voicePermissionClient = voicePermissionClient
    _store = State(initialValue: ChatMeetupStore(ownerID: ownerID, roomID: roomID, api: api,
      calendarProvider: calendarProvider, locationProvider: locationProvider))
  }

  var body: some View {
    let ja = locale.directChatLanguage == .japanese
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: "calendar.badge.clock")
          .foregroundStyle(BilingualReferencePalette.ink)
          .frame(width: 38, height: 38)
          .background(BilingualReferencePalette.softYellow)
          .clipShape(Circle())
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(ja ? "Wardの待ち合わせ" : "Meetup with Ward").font(.headline.bold())
          Text(ja ? "Wardによる予定調整" : "Planning with Ward")
            .font(.caption).foregroundStyle(BilingualReferencePalette.muted)
        }
        Spacer()
        Button { Task { await store.refresh() } } label: {
          Image(systemName: "arrow.clockwise").frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .background(BilingualReferencePalette.field)
        .clipShape(Circle())
        .accessibilityLabel(ja ? "待ち合わせを更新" : "Refresh meetup")
        .accessibilityIdentifier("directChat.meetup.refresh")
      }

      if store.isLoading && store.state == nil {
        ProgressView(ja ? "待ち合わせを確認中…" : "Checking meetup…")
          .accessibilityIdentifier("directChat.meetup.loading")
      } else if let state = store.state {
        if state.simulatedCounterpart {
          Text(ja ? "審査用の架空の相手です。相手側の操作は自動で進みます。実際の面会は行いません。" :
            "Fictional counterpart for judging. Their actions advance automatically. No real meeting takes place.")
            .font(.footnote).foregroundStyle(BilingualReferencePalette.muted)
            .accessibilityIdentifier("directChat.meetup.simulatedCounterpart")
        }
        if let admission = state.syntheticTestAdmission {
          VStack(alignment: .leading, spacing: 4) {
            Text(admission.disclosureText(japanese: ja))
              .font(.subheadline.weight(.semibold))
            Text(ja ? "この架空ペアの一時的なテスト参加資格です。操作はサーバーの許可に従います。" :
              "Temporary test admission for this fictional pair. Available actions follow server permissions.")
              .font(.caption)
          }
          .foregroundStyle(BilingualReferencePalette.ink)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(BilingualReferencePalette.softYellow)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .accessibilityIdentifier("directChat.meetup.syntheticTestAdmission")
        }

        Text(statusText(state.status, ja: ja))
          .font(.subheadline.weight(.semibold))
          .accessibilityIdentifier("directChat.meetup.status")

        if !state.ownPermissions.canIntent && !state.ownPermissions.canSchedule,
          let reason = state.ownPermissions.reason {
          Text(permissionText(reason, ja: ja))
            .font(.footnote).foregroundStyle(BilingualReferencePalette.muted)
            .accessibilityIdentifier("directChat.meetup.permissionReason")
        }

        if state.status == .unavailable {
          Text(unavailableText(state.unavailableReason, ja: ja))
            .font(.footnote).foregroundStyle(BilingualReferencePalette.muted)
            .accessibilityIdentifier("directChat.meetup.unavailable")
        }

        if state.ownDecisions.intentValue == .yes {
          Text(ja ? "あなたの希望を非公開で記録しました。相手の判断は表示しません。" :
            "Your interest is recorded privately. The other person's choice is never shown here.")
            .font(.caption).foregroundStyle(BilingualReferencePalette.muted)
            .accessibilityIdentifier("directChat.meetup.intent.privateStatus")
        } else if state.ownDecisions.intentValue == .withdraw {
          Text(ja ? "あなたの希望を取り消しました。" : "Your interest was withdrawn.")
            .font(.caption).foregroundStyle(BilingualReferencePalette.muted)
        }
        if state.ownPermissions.canIntent && state.ownDecisions.intentValue != .yes {
          Text(ja ? "希望はあなた専用の判断として送られます。相手の判断は表示しません。" :
            "Your interest is private. The other person's choice is never shown here.")
            .font(.caption).foregroundStyle(BilingualReferencePalette.muted)
          Button(ja ? "待ち合わせに興味があります" : "I'm open to meeting") {
            Task { await store.perform(.intent(.yes)) }
          }
          .buttonStyle(BilingualReferencePrimaryButtonStyle())
          .accessibilityIdentifier("directChat.meetup.intent.yes")
        }
        if state.ownDecisions.intentValue == .yes && state.ownPermissions.canIntent {
          Button(ja ? "自分の希望を取り消す" : "Withdraw my interest") {
            Task { await store.perform(.intent(.withdraw)) }
          }
          .buttonStyle(BilingualReferenceSecondaryButtonStyle())
          .accessibilityIdentifier("directChat.meetup.intent.withdraw")
        }

        if state.ownPermissions.canSchedule && state.status == .awaitingAvailability {
          availabilityPanel(ja: ja)
        }

        if state.status == .timeProposed {
          VStack(alignment: .leading, spacing: 8) {
            Text(ja ? "候補の日時" : "Suggested times").font(.subheadline.bold())
            ForEach(state.timeCandidates) { item in
              VStack(alignment: .leading, spacing: 6) {
                Text(item.startsAt.formatted(date: .abbreviated, time: .shortened))
                  .font(.subheadline.weight(.semibold))
                if state.ownDecisions.timeCandidateID == item.id {
                  Text(ja ? "あなたの選択を非公開で記録しました" : "Your choice is recorded privately")
                    .font(.caption).foregroundStyle(BilingualReferencePalette.muted)
                } else {
                  Button(ja ? "この日時を選ぶ" : "Choose this time") {
                    Task { await store.perform(.approveTime(candidateID: item.id)) }
                  }
                  .buttonStyle(BilingualReferenceSecondaryButtonStyle())
                  .accessibilityIdentifier("directChat.meetup.time.\(item.id.uuidString)")
                }
              }
              .padding(10).frame(maxWidth: .infinity, alignment: .leading)
              .background(BilingualReferencePalette.field)
              .clipShape(RoundedRectangle(cornerRadius: 13))
            }
          }
        }

        if state.status == .confirmed || state.status == .completed,
          let plan = state.confirmedPlan {
          Text(plan.timeSummary(ja: ja))
            .font(.footnote.weight(.semibold))
            .accessibilityIdentifier("directChat.meetup.confirmedPlan.time")
        }
        // Venue discovery is deferred. Keep its implementation isolated from the shipped flow.
        if state.status == .confirmed || state.status == .completed {
          Text(ja ? "二人で日時を確認しました。待ち合わせ場所はチャットで相談してください。" :
            "You both confirmed this time. Arrange the meeting place in chat.")
            .font(.caption).foregroundStyle(BilingualReferencePalette.muted)
            .accessibilityIdentifier("directChat.meetup.noReservation")
        }
        if state.simulatedCounterpart && state.status == .confirmed {
          Button(ja ? "面会を模擬して振り返りへ" : "Simulate meetup and continue to reflection") {
            Task { await store.simulateMeeting() }
          }
          .buttonStyle(BilingualReferenceSecondaryButtonStyle())
          .disabled(store.isActing)
          .accessibilityIdentifier("directChat.meetup.simulateCompletion")
        }
        if state.ownPermissions.canComplete && !state.simulatedCounterpart {
          Button(ja ? "待ち合わせに参加しました" : "I attended this meetup") {
            Task { await store.completeMeeting() }
          }
          .buttonStyle(BilingualReferenceSecondaryButtonStyle())
          .accessibilityIdentifier("directChat.meetup.complete")
        }

        HStack(spacing: 8) {
          if state.ownPermissions.canReplan {
            Button(ja ? "候補を変更" : "Change plan") { Task { await store.perform(.replan) } }
              .buttonStyle(BilingualReferenceSecondaryButtonStyle())
              .accessibilityIdentifier("directChat.meetup.replan")
          }
          if state.ownPermissions.canCancel {
            Button(ja ? "取り消す" : "Cancel meetup") { Task { await store.perform(.cancel) } }
              .buttonStyle(BilingualReferenceSecondaryButtonStyle())
              .accessibilityIdentifier("directChat.meetup.cancel")
          }
        }

        ForEach(state.events.filter { !(isJudgeBuild || state.simulatedCounterpart) || $0.kind != .system }) { event in
          VStack(alignment: .leading, spacing: 3) {
            Text(eventTitle(event.kind, ja: ja)).font(.caption.bold())
              .foregroundStyle(BilingualReferencePalette.muted)
            Text(event.text).font(.footnote)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("directChat.meetup.event.\(event.id.uuidString)")
        }

        if let msg = store.noticeMessage {
          Text(msg).font(.footnote).foregroundStyle(BilingualReferencePalette.muted)
            .accessibilityIdentifier("directChat.meetup.notice")
        }
      } else if let msg = store.errorMessage {
        Text(msg).font(.footnote).foregroundStyle(BilingualReferencePalette.muted)
          .accessibilityIdentifier("directChat.meetup.error")
        Button(ja ? "再試行" : "Retry") { Task { await store.refresh() } }
          .buttonStyle(BilingualReferenceSecondaryButtonStyle())
          .accessibilityIdentifier("directChat.meetup.retry")
      }

      if let msg = store.errorMessage, store.state != nil {
        Text(msg).font(.footnote).foregroundStyle(BilingualReferencePalette.muted)
          .accessibilityIdentifier("directChat.meetup.error")
        HStack {
          Button(ja ? "同じ操作を再試行" : "Retry same choice") {
            Task { await store.retryPendingAction() }
          }
          .buttonStyle(BilingualReferenceSecondaryButtonStyle())
          .accessibilityIdentifier("directChat.meetup.retryAction")
          Button(ja ? "最新状態を更新" : "Refresh state") {
            Task { await store.refresh() }
          }
          .buttonStyle(BilingualReferenceSecondaryButtonStyle())
          .accessibilityIdentifier("directChat.meetup.refreshState")
        }
      }

      wardHistory(ja: ja)
      if stateForReflection?.ownDecisions.completed == true, let meetupID = stateForReflection?.meetupID {
        ChatMeetupReflectionCard(ownerID: ownerID, meetupID: meetupID, api: api,
          simulatedCounterpart: stateForReflection?.simulatedCounterpart == true, transport: reflectionTransport, permissionClient: voicePermissionClient)
      }
    }
    .padding(15)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay { RoundedRectangle(cornerRadius: 20).stroke(BilingualReferencePalette.line, lineWidth: 1) }
    .clipShape(RoundedRectangle(cornerRadius: 20))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("directChat.meetupCard")
    .onAppear {
      if store.state == nil && !store.isLoading {
        Task { await store.load().value }
      }
    }
    .onDisappear {
      store.cancel()
    }
  }

  private var stateForReflection: ChatMeetupState? { store.state }

  private var isJudgeBuild: Bool {
    (try? DemoJudgeMatchingConfiguration.enabled(
      info: Bundle.main.infoDictionary ?? [:], arguments: [], allowLaunchArgument: false
    )) == true
  }

  private func availabilityPanel(ja: Bool) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(ja ? "空き時間の共有" : "Share availability").font(.subheadline.bold())
      if let admission = store.state?.syntheticTestAdmission {
        let start = admission.expiresAt.addingTimeInterval(-75 * 60)
        let end = admission.expiresAt.addingTimeInterval(-15 * 60)
        if start > Date() {
          Text(ja ? "今回の架空デモの60分枠" : "60-minute availability for this fictional demo")
            .font(.caption)
          Text("\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
            .font(.caption.weight(.semibold))
          Button(ja ? "このデモ枠で空き時間を共有" : "Share availability for this demo slot") {
            let slot = MeetupAvailability(startsAt: start, endsAt: end)
            Task { await store.perform(.manualAvailability(window: slot, available: [slot])) }
          }
          .buttonStyle(BilingualReferenceSecondaryButtonStyle())
          .accessibilityIdentifier("directChat.meetup.availability.fictionalSlot")
        }
      }
      Text(ja
        ? "iOSカレンダーの許可が必要です。許可範囲は予定全体を読めますが、この端末では日時と空き状況だけに変換し、タイトル・場所・参加者は送信しません。"
        : "iOS calendar permission is required. It can grant broad event access, but this device projects only time and busy/free status; titles, places and attendees are not sent.")
        .font(.caption).foregroundStyle(BilingualReferencePalette.muted)
      Button(ja ? "カレンダーの空き時間を共有" : "Share calendar availability") {
        let start = Calendar.current.startOfDay(for: Date().addingTimeInterval(24 * 60 * 60))
        let end = Calendar.current.date(byAdding: .day, value: 14, to: start) ??
          start.addingTimeInterval(14 * 24 * 60 * 60)
        Task { await store.shareCalendarAvailability(window: MeetupAvailability(startsAt: start, endsAt: end)) }
      }
      .buttonStyle(BilingualReferenceSecondaryButtonStyle())
      .accessibilityIdentifier("directChat.meetup.availability.calendar")
      HStack(spacing: 7) {
        Button(ja ? "平日の夕方" : "Weekday evenings") {
          Task { await store.submitRoughAvailability(weekdays: true) }
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
        .accessibilityIdentifier("directChat.meetup.manual.weekdays")
        Button(ja ? "週末の午後" : "Weekend afternoons") {
          Task { await store.submitRoughAvailability(weekdays: false) }
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
        .accessibilityIdentifier("directChat.meetup.manual.weekends")
      }
      if let message = store.calendarMessage {
        Text(message).font(.caption).foregroundStyle(BilingualReferencePalette.muted)
          .accessibilityIdentifier("directChat.meetup.calendarDisclosure")
      }
      Button(ja ? "共有済みの空き時間を削除" : "Clear shared availability") {
        Task { await store.clearAvailability() }
      }
      .font(.caption.weight(.semibold)).frame(minHeight: 44)
      .accessibilityIdentifier("directChat.meetup.availability.clear")
    }
    .padding(11).background(BilingualReferencePalette.field)
    .clipShape(RoundedRectangle(cornerRadius: 13))
  }

  private func wardHistory(ja: Bool) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Button { Task { await store.toggleWardHistory() } } label: {
        Label(ja ? "Ward同士の自動会話" : "Automatic Ward↔Ward conversation",
          systemImage: store.wardHistoryExpanded ? "chevron.down" : "chevron.right")
          .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      }
      .buttonStyle(.plain).accessibilityIdentifier("directChat.wardHistory.toggle")
      if store.wardHistoryExpanded {
        Text(ja ? "完了した相性会話のみです。人同士のメッセージや非公開Ward会話は含みません。" :
          "Completed compatibility conversation only. Human chat and private Ward messages are excluded.")
          .font(.caption).foregroundStyle(BilingualReferencePalette.muted)
        if store.isLoadingWardHistory { ProgressView() }
        else if let error = store.wardHistoryError {
          Text(error).font(.footnote).foregroundStyle(BilingualReferencePalette.muted)
            .accessibilityIdentifier("directChat.wardHistory.error")
          Button(ja ? "再試行" : "Retry Ward conversation") {
            Task { await store.retryWardHistory() }
          }
          .buttonStyle(BilingualReferenceSecondaryButtonStyle())
          .accessibilityIdentifier("directChat.wardHistory.retry")
        } else if store.wardEvents.isEmpty {
          Text(ja ? "共有できる自動会話はありません。" : "No shareable Ward conversation is available.")
            .font(.footnote).foregroundStyle(BilingualReferencePalette.muted)
            .accessibilityIdentifier("directChat.wardHistory.empty")
        } else {
          ForEach(store.wardEvents) { event in
            VStack(alignment: .leading, spacing: 3) {
              Text(event.speaker == .myWard ? (ja ? "あなたのWard" : "Your Ward") :
                (ja ? "相手のWard" : "Partner Ward")).font(.caption.bold())
              Text(event.text).font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(9)
            .background(BilingualReferencePalette.field).clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("directChat.wardHistory.event.\(event.id.uuidString)")
          }
          if store.wardHistoryHasMore {
            Button(ja ? "以前の会話を表示" : "Load older Ward conversation") {
              Task { await store.loadMoreWardHistory() }
            }
            .buttonStyle(BilingualReferenceSecondaryButtonStyle())
            .accessibilityIdentifier("directChat.wardHistory.loadMore")
          }
        }
      }
    }
  }

  private func statusText(_ status: ChatMeetupStatus, ja: Bool) -> String {
    switch status {
    case .idle, .intentPending: ja ? "それぞれの希望を非公開に保ちながら進めます。" : "Each person keeps their choices private while planning."
    case .awaitingAvailability: ja ? "次の2週間の空き時間を共有できます。" : "Share availability for the next two weeks."
    case .timeProposed: ja ? "日時候補を確認してください。" : "Review the suggested time."
    case .awaitingLocation: ja ? "日時を選び直してください。" : "Choose a new time to continue."
    case .cafeProposed: ja ? "日時を選び直してください。" : "Choose a new time to continue."
    case .confirmed: ja ? "二人で日時を確認しました。" : "You both confirmed this time."
    case .completed: ja ? "あなたの参加確認を記録しました。" : "Your attendance confirmation is recorded."
    case .cancelled: ja ? "待ち合わせは取り消されました。" : "The meetup was cancelled."
    case .expired: ja ? "候補の期限が切れました。" : "The meetup options have expired."
    case .unavailable: ja ? "待ち合わせ機能は現在利用できません。" : "Meetup planning is unavailable right now."
    }
  }

  private func unavailableText(_ reason: ChatMeetupUnavailableReason?, ja: Bool) -> String {
    switch reason {
    case .calendarUnavailable: ja ? "カレンダー未接続です。空き時間ボタンを使えます。" : "Calendar is unavailable. Use rough availability."
    case .noSharedTime: ja ? "共有時間に候補がありません。別の時間を選べます。" : "No shared time was found. Choose another window."
    case .cafeUnavailable, .noCafe: ja ? "日時を選び直してください。" : "Choose a new time to continue."
    case .migrationUnavailable, .providerUnavailable, .none:
      ja ? "必要なサービスは未接続です。利用可能になったら表示します。" :
        "A required service is not connected yet. This card will update when it is."
    }
  }

  private func permissionText(_ reason: ChatMeetupPermissionReason, ja: Bool) -> String {
    switch reason {
    case .featureDisabled, .providerUnavailable:
      ja ? "待ち合わせサービスはまだ接続されていません。" : "Meetup planning is not connected here yet."
    case .identityVerificationRequired:
      ja ? "待ち合わせを使うには年齢・本人確認が必要です。" : "Age or identity verification is required before planning."
    case .eligibilityUnavailable:
      ja ? "このチャットでは待ち合わせを利用できません。" : "This chat is not eligible for meetup planning."
    case .quotaExhausted:
      ja ? "待ち合わせは一時的に利用できません。" : "Meetup planning is temporarily unavailable."
    case .notParticipant, .terminalState:
      ja ? "このチャットでは待ち合わせを続けられません。" : "Meetup planning is unavailable for this chat."
    }
  }

  private func eventTitle(_ kind: ChatMeetupEventKind, ja: Bool) -> String {
    switch kind {
    case .system: ja ? "WingWardの更新" : "WingWard update"
    case .human: ja ? "チャットの更新" : "Chat update"
    case .ward: ja ? "自動Wardの更新" : "Automatic Ward update"
    }
  }
}

private struct ChatMeetupReflectionCard: View {
  let ownerID: String
  let meetupID: UUID
  let api: any DirectChatsAPI
  let simulatedCounterpart: Bool
  let transport: any VoiceInterviewTransport
  let permissionClient: any VoicePermissionClient
  @Environment(\.locale) private var locale
  @State private var store: ChatMeetupReflectionStore
  @State private var expanded = false

  init(ownerID: String, meetupID: UUID, api: any DirectChatsAPI,
       simulatedCounterpart: Bool = false, transport: any VoiceInterviewTransport, permissionClient: any VoicePermissionClient) {
    self.ownerID = ownerID
    self.meetupID = meetupID
    self.api = api
    self.simulatedCounterpart = simulatedCounterpart
    self.transport = transport
    self.permissionClient = permissionClient
    _store = State(initialValue: ChatMeetupReflectionStore(ownerID: ownerID, meetupID: meetupID,
      api: api, transport: transport, permissionClient: permissionClient))
  }

  private var ja: Bool { locale.directChatLanguage == .japanese }

  var body: some View {
    VoiceProfileCard {
      VStack(alignment: .leading, spacing: 18) {
        Button {
          expanded.toggle()
          if expanded { Task { await store.load() } }
          else { Task { await store.cancel() } }
        } label: {
          HStack(alignment: .top, spacing: 14) {
            VoiceProfileIconBadge(systemImage: "waveform", size: 48)
            VStack(alignment: .leading, spacing: 6) {
              Text(simulatedCounterpart ? (ja ? "模擬面会の振り返り" : "After your simulated meetup") : (ja ? "会ったあとの振り返り" : "After your meetup"))
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
              Text(ja ? "自分だけのWardとの会話" : "A private conversation with Ward")
                .font(.subheadline)
                .foregroundStyle(VoiceProfilePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.subheadline.weight(.semibold))
          }
          .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("directChat.reflection.toggle")
        .accessibilityValue(expanded ? (ja ? "開いています" : "Expanded") : (ja ? "閉じています" : "Collapsed"))

        if expanded {
          if simulatedCounterpart {
            Text(ja ? "架空の相手との模擬体験です。実際に会ったことや相手の評価を記録せず、自分の気づきだけを確認してください。" :
              "This was a simulated experience with a fictional counterpart. Confirm only insights about yourself; no real meeting or partner rating is recorded.")
              .font(.subheadline).foregroundStyle(VoiceProfilePalette.muted)
              .accessibilityIdentifier("directChat.reflection.simulatedCounterpart")
          }
          Text(ja
            ? "自分の経験を振り返ります。相手の評価や会話記録は保存しません。選んで確認した内容だけを、今のプロフィールに追加・更新します。"
            : "Reflect on your own experience. No partner rating or transcript is saved. Only values you confirm are added to or updated in your current profile.")
            .font(.subheadline)
            .foregroundStyle(VoiceProfilePalette.muted)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)

          HStack(spacing: 10) {
            Image(systemName: "lock.fill").accessibilityHidden(true)
            Text(ja ? "自分だけに表示" : "Only visible to you")
            Spacer(minLength: 0)
            Text(phaseLabel).font(.caption.weight(.bold))
          }
          .font(.subheadline.weight(.semibold))
          .padding(.horizontal, 16)
          .frame(minHeight: 48)
          .background(VoiceProfilePalette.softYellow)
          .clipShape(Capsule())
          .accessibilityIdentifier("directChat.reflection.progress")

          reflectionSurface

          if let message = store.errorMessage {
            Label(message, systemImage: "exclamationmark.circle")
              .font(.footnote)
              .foregroundStyle(VoiceProfilePalette.muted)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("directChat.reflection.error")
          }
          if let snapshot = store.snapshot, !snapshot.confirmedTraits.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              Label(ja ? "確認済みの振り返り v\(snapshot.currentPersonaVersion)" : "Confirmed reflection v\(snapshot.currentPersonaVersion)", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VoiceProfilePalette.accentText)
                .accessibilityIdentifier("directChat.reflection.version")
              ForEach(Array(snapshot.confirmedTraits.enumerated()), id: \.offset) { _, trait in
                Text(traitLabel(key: trait.key, value: trait.value))
                  .font(.subheadline)
                  .fixedSize(horizontal: false, vertical: true)
                  .accessibilityIdentifier("directChat.reflection.confirmed.\(trait.key.rawValue)")
              }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VoiceProfilePalette.field)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          }
        }
      }
    }
    .foregroundStyle(VoiceProfilePalette.ink)
    .onDisappear { Task { await store.cancel() } }
  }

  private var phaseLabel: String {
    switch store.phase {
    case .idle: ja ? "振り返る" : "Reflect"
    case .bootstrapping: ja ? "接続中" : "Connecting"
    case .interviewing: ja ? "会話中" : "In conversation"
    case .drafting: ja ? "提案を作成中" : "Preparing suggestions"
    case .readyToConfirm: ja ? "確認する" : "Review"
    case .saving: ja ? "保存中" : "Saving"
    case .finished: ja ? "確認済み" : "Confirmed"
    }
  }

  @ViewBuilder
  private var reflectionSurface: some View {
    switch store.phase {
    case .bootstrapping, .drafting, .saving:
      HStack(spacing: 12) {
        ProgressView().tint(VoiceProfilePalette.accentText)
        Text(phaseLabel).font(.subheadline.weight(.semibold))
      }
      .frame(minHeight: 48, alignment: .leading)
      .accessibilityIdentifier("directChat.reflection.busy")
    case .interviewing:
      Label(ja ? "Wardと話しています" : "You’re talking with Ward", systemImage: "waveform")
        .font(.headline)
      Text(ja ? "一時的な自分の発話: \(store.userStatements.count)件" : "Your temporary voice turns: \(store.userStatements.count)")
        .font(.subheadline)
        .foregroundStyle(VoiceProfilePalette.muted)
      Button(ja ? "終了して一時メモを消去" : "Stop and clear temporary voice notes") {
        Task { await store.stopAndClear() }
      }
      .buttonStyle(VoiceProfileSecondaryButtonStyle())
      .accessibilityIdentifier("directChat.reflection.stop")
    case .readyToConfirm:
      if let draft = store.draft {
        VStack(alignment: .leading, spacing: 12) {
          Text(ja ? "プロフィールに残す内容を選ぶ" : "Choose what belongs in your profile")
            .font(.headline)
          Text(ja ? "AIの提案です。選択はいつでも変更できます。" : "These are AI suggestions. You decide what to keep.")
            .font(.subheadline).foregroundStyle(VoiceProfilePalette.muted)
          ForEach(draft.candidates) { item in
            Button { store.toggle(item) } label: {
              HStack(alignment: .center, spacing: 12) {
                Image(systemName: store.selectedCandidateIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                  .font(.title3)
                  .foregroundStyle(VoiceProfilePalette.accentText)
                  .accessibilityHidden(true)
                Text(traitLabel(key: item.key, value: item.value))
                  .font(.subheadline.weight(.semibold))
                  .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
              }
              .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
              .padding(12)
              .background(store.selectedCandidateIDs.contains(item.id) ? VoiceProfilePalette.softYellow : VoiceProfilePalette.field)
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(store.selectedCandidateIDs.contains(item.id) ? (ja ? "選択済み" : "Selected") : (ja ? "未選択" : "Not selected"))
            .accessibilityIdentifier("directChat.reflection.candidate.\(item.id.uuidString)")
          }
          Button(ja ? "選んだ内容でプロフィールを更新" : "Update my profile with selected values") {
            Task { await store.confirmSelected() }
          }
          .buttonStyle(VoiceProfilePrimaryButtonStyle())
          .disabled(store.selectedCandidateIDs.isEmpty)
          .accessibilityIdentifier("directChat.reflection.confirm")
          Button(ja ? "提案を破棄" : "Discard suggestions") { Task { await store.stopAndClear() } }
            .buttonStyle(VoiceProfileSecondaryButtonStyle())
            .accessibilityIdentifier("directChat.reflection.discard")
        }
      }
    case .idle, .finished:
      if store.phase == .finished {
        Label(ja ? "確認した内容をプロフィールに反映しました" : "Your confirmed values are saved to your profile", systemImage: "checkmark.circle.fill")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(VoiceProfilePalette.accentText)
          .accessibilityIdentifier("directChat.reflection.saved")
      }
      Button(ja ? "音声で振り返りを始める" : "Start private voice reflection") {
        Task { await store.start() }
      }
      .buttonStyle(VoiceProfilePrimaryButtonStyle())
      .accessibilityIdentifier("directChat.reflection.start")
      if !store.userStatements.isEmpty {
        Button(ja ? "自分の発話から提案を作る" : "Draft suggestions from my words") {
          Task { await store.draftSuggestions() }
        }
        .buttonStyle(VoiceProfileSecondaryButtonStyle())
        .accessibilityIdentifier("directChat.reflection.draft")
        Button(ja ? "一時メモを消去" : "Clear temporary notes") { Task { await store.stopAndClear() } }
          .buttonStyle(VoiceProfileSecondaryButtonStyle())
          .accessibilityIdentifier("directChat.reflection.clear")
      }
    }
  }

  private func traitLabel(key traitKey: ChatMeetupReflectionTraitKey, value traitValue: ChatMeetupReflectionTraitValue) -> String {
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
    guard let key = keys[traitKey], let value = values[traitValue] else { return "" }
    return ja ? "\(key.1)：\(value.1)" : "\(key.0): \(value.0)"
  }
}

struct ChatRequestsView: View {
  let ownerID: String
  let api: any DirectChatsAPI
  let onAccepted: ((UUID) -> Void)?
  let onOpenReportForMatch: ((UUID, ReportContext) -> Void)?
  let inline: Bool
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @State private var store: ChatRequestsStore

  init(
    ownerID: String,
    api: any DirectChatsAPI,
    onAccepted: ((UUID) -> Void)? = nil,
    onOpenReportForMatch: ((UUID, ReportContext) -> Void)? = nil,
    inline: Bool = false
  ) {
    self.ownerID = ownerID
    self.api = api
    self.onAccepted = onAccepted
    self.onOpenReportForMatch = onOpenReportForMatch
    self.inline = inline
    _store = State(initialValue: ChatRequestsStore(ownerID: ownerID, api: api))
  }

  var body: some View {
    let language = locale.directChatLanguage
    Group {
      if inline {
        VStack(alignment: .leading, spacing: 14) {
          switch store.phase {
          case .idle, .loading:
            loadingSurface
          case let .failed(error):
            failureSurface(error)
          case .loaded:
            if !store.requests.isEmpty { loadedSurface }
          }
        }
      } else {
    VStack(spacing: 0) {
      DirectChatHeader(
        onLogo: {
          store.cancel()
          dismiss()
        },
        onProfile: {},
        profileIdentifier: "chatRequests.settings",
        notificationIdentifier: "chatRequests.notifications",
        notificationLabel: directChatCopy(.notificationUnavailable, language: language)
      )
      DirectChatProgressHeader(
        backTitle: directChatCopy(.chatRequestsBack, language: language),
        progress: directChatCopy(.chatRequestsProgress, language: language),
        progressValue: 0,
        showsProgress: false,
        backIdentifier: "chatRequests.back"
      ) {
        store.cancel()
        dismiss()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
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
    .background(BilingualReferencePalette.cream)
    .toolbar(.hidden, for: .navigationBar)
    .foregroundStyle(BilingualReferencePalette.ink)
    .environment(\.colorScheme, .light)
    .tint(BilingualReferencePalette.ink)
    .preferredColorScheme(.light)
      }
    }
    .task(id: ownerID) { await store.load().value }
    .onDisappear { store.cancel() }
  }

  private var loadingSurface: some View {
    let language = locale.directChatLanguage
    return VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Image(systemName: "person.2.wave.2.fill")
          .font(.title3.weight(.semibold))
          .foregroundStyle(BilingualReferencePalette.ink)
          .frame(width: 44, height: 44)
          .background(BilingualReferencePalette.softYellow)
          .clipShape(Circle())
          .accessibilityHidden(true)
        Text(directChatCopy(.chatRequestsLoadingTitle, language: language))
          .font(.title2.weight(.bold))
      }
      Text(directChatCopy(.chatRequestsLoadingBody, language: language))
        .font(.body)
        .foregroundStyle(BilingualReferencePalette.muted)
      ProgressView()
        .tint(BilingualReferencePalette.yellow)
        .frame(minHeight: 48)
        .accessibilityIdentifier("chatRequests.loading")
    }
    .cardSurface()
  }

  private func failureSurface(_ error: DirectChatsStoreError) -> some View {
    let language = locale.directChatLanguage
    return VStack(alignment: .leading, spacing: 16) {
      Image(systemName: "arrow.clockwise.circle")
        .font(.system(size: 32, weight: .medium))
        .foregroundStyle(BilingualReferencePalette.yellow)
        .accessibilityHidden(true)
      Text(directChatCopy(.chatRequestsLoadFailedTitle, language: language))
        .font(.title2.weight(.bold))
      Text(directChatErrorMessage(error, context: .requests, language: language))
        .font(.body)
        .foregroundStyle(BilingualReferencePalette.muted)
      Button(directChatCopy(.retry, language: language)) {
        Task { await store.retry().value }
      }
      .buttonStyle(BilingualReferencePrimaryButtonStyle())
      .accessibilityIdentifier("chatRequests.retry")
    }
    .cardSurface()
  }

  @ViewBuilder
  private var loadedSurface: some View {
    let language = locale.directChatLanguage
    if store.requests.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        Image(systemName: "person.2.wave.2")
          .font(.system(size: 30, weight: .medium))
          .foregroundStyle(BilingualReferencePalette.yellow)
          .accessibilityHidden(true)
        Text(directChatCopy(.chatRequestsEmptyTitle, language: language))
          .font(.title3.weight(.bold))
        Text(
          language == .japanese
            ? "新しいリクエストが届くと、ここで確認できます。"
            : "New requests will appear here when someone wants to connect."
        )
          .font(.body)
          .foregroundStyle(BilingualReferencePalette.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      .cardSurface()
      .accessibilityIdentifier("chatRequests.empty")
    } else {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 5) {
          Text(directChatCopy(.chatRequestsKicker, language: language))
            .font(.caption2.weight(.bold))
            .tracking(1.5)
            .foregroundStyle(BilingualReferencePalette.ink.opacity(0.72))
          Text(directChatCopy(.chatRequestsTitle, language: language))
            .font(.title.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(store.requests) { request in
          requestRow(request)
        }
      }
      .cardSurface()
    }
  }

  private func requestRow(_ request: ChatRequestSummary) -> some View {
    let language = locale.directChatLanguage
    let isActing = store.actionRequestIDs.contains(request.id)
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Image(systemName: "person.crop.circle.fill")
          .font(.system(size: 28, weight: .medium))
          .foregroundStyle(BilingualReferencePalette.muted)
          .frame(width: 44, height: 44)
          .background(BilingualReferencePalette.softYellow)
          .clipShape(Circle())
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(directChatDisplayName(request.requester.nickname, language: language))
            .font(.headline.weight(.bold))
          Text(directChatCopy(.requestBody, language: language))
            .font(.body)
            .foregroundStyle(BilingualReferencePalette.muted)
        }
        Spacer(minLength: 0)
      }
      HStack(spacing: 6) {
        Image(systemName: "clock")
          .font(.caption)
        Text(directChatCopy(.expires, language: language))
        Text(request.expiresAt, style: .date)
      }
      .font(.caption)
      .foregroundStyle(BilingualReferencePalette.muted)

      HStack(spacing: 10) {
        if let onOpenReportForMatch,
          let safetyTarget = PartnerSafetyTarget.make(
            matchID: request.matchID,
            context: .directChat
          )
        {
          Button {
            safetyTarget.open(using: onOpenReportForMatch)
          } label: {
            Label(
              directChatCopy(.reportBlock, language: language),
              systemImage: "exclamationmark.shield"
            )
          }
          .buttonStyle(BilingualReferenceSecondaryButtonStyle())
          .disabled(isActing)
          .accessibilityIdentifier("chatRequests.report.\(request.id.uuidString)")
        }
        Button {
          Task { await store.respond(to: request, action: .decline).value }
        } label: {
          HStack(spacing: 6) {
            if isActing { ProgressView().tint(BilingualReferencePalette.ink) }
            Text(directChatCopy(.decline, language: language))
          }
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
        .disabled(isActing)
        .accessibilityIdentifier("chatRequests.decline.\(request.id.uuidString)")
        Button {
          Task {
            await store.respond(to: request, action: .accept).value
            if let roomID = store.lastAcceptedRoomID { onAccepted?(roomID) }
          }
        } label: {
          HStack(spacing: 6) {
            if isActing { ProgressView().tint(BilingualReferencePalette.ink) }
            Text(directChatCopy(.accept, language: language))
          }
        }
        .buttonStyle(BilingualReferencePrimaryButtonStyle())
        .disabled(isActing)
        .accessibilityIdentifier("chatRequests.accept.\(request.id.uuidString)")
      }
      if let error = store.actionErrors[request.id] {
        Text(directChatErrorMessage(error, context: .requestAction, language: language))
          .font(.footnote)
          .foregroundStyle(BilingualReferencePalette.muted)
          .accessibilityIdentifier("chatRequests.error.\(request.id.uuidString)")
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(BilingualReferencePalette.field)
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

/// Confirmation surface opened from a selected match after Partner Ward has
/// been started. The request endpoint is idempotency/authorization owned by
/// the server; this view only reports the returned pending row.
struct DirectChatRequestView: View {
  let ownerID: String
  let matchID: UUID
  let api: any DirectChatsAPI
  let onCompleted: ((ChatRequestCreateResult) -> Void)?
  let onOpenReportForMatch: ((UUID, ReportContext) -> Void)?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @State private var store: ChatRequestsStore

  init(
    ownerID: String,
    matchID: UUID,
    api: any DirectChatsAPI,
    onCompleted: ((ChatRequestCreateResult) -> Void)? = nil,
    onOpenReportForMatch: ((UUID, ReportContext) -> Void)? = nil
  ) {
    self.ownerID = ownerID
    self.matchID = matchID
    self.api = api
    self.onCompleted = onCompleted
    self.onOpenReportForMatch = onOpenReportForMatch
    _store = State(initialValue: ChatRequestsStore(ownerID: ownerID, api: api))
  }

  var body: some View {
    let language = locale.directChatLanguage
    VStack(spacing: 0) {
      DirectChatHeader(
        onLogo: {
          store.cancel()
          dismiss()
        },
        onProfile: {},
        profileIdentifier: "directChatRequest.settings",
        notificationIdentifier: "directChatRequest.notifications",
        notificationLabel: directChatCopy(.notificationUnavailable, language: language)
      )
      DirectChatProgressHeader(
        backTitle: directChatCopy(.directRequestBack, language: language),
        progress: directChatCopy(.directRequestProgress, language: language),
        progressValue: 0,
        showsProgress: false,
        backIdentifier: "directChatRequest.back"
      ) {
        store.cancel()
        dismiss()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)

      ScrollView {
        requestSurface(language: language)
          .padding(.horizontal, 16)
          .padding(.bottom, 24)
          .frame(maxWidth: 760, alignment: .leading)
          .frame(maxWidth: .infinity)
      }
    }
    .background(BilingualReferencePalette.cream)
    .toolbar(.hidden, for: .navigationBar)
    .foregroundStyle(BilingualReferencePalette.ink)
    .environment(\.colorScheme, .light)
    .tint(BilingualReferencePalette.ink)
    .preferredColorScheme(.light)
    .onDisappear { store.cancel() }
  }

  @ViewBuilder
  private func requestSurface(language: BilingualReferenceLanguage) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Image(systemName: "paperplane.circle.fill")
          .font(.system(size: 34, weight: .medium))
          .foregroundStyle(BilingualReferencePalette.ink)
          .frame(width: 58, height: 58)
          .background(BilingualReferencePalette.yellow)
          .clipShape(Circle())
          .accessibilityHidden(true)
        BilingualReferenceSectionLabel(
          text: directChatCopy(.directRequestKicker, language: language)
        )
      }
      Text(directChatCopy(.directRequestTitle, language: language))
        .font(.system(size: 30, weight: .bold, design: .rounded))
        .tracking(-0.8)
      Text(directChatCopy(.directRequestBody, language: language))
        .font(.body)
        .foregroundStyle(BilingualReferencePalette.muted)
        .lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)

      if let onOpenReportForMatch,
        let safetyTarget = PartnerSafetyTarget.make(
          matchID: matchID,
          context: .directChat
        )
      {
        Button {
          safetyTarget.open(using: onOpenReportForMatch)
        } label: {
          Label(
            directChatCopy(.reportBlock, language: language),
            systemImage: "exclamationmark.shield"
          )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
        .accessibilityIdentifier("directChatRequest.report")
      }

      if let result = store.lastCreatedRequest {
        VStack(alignment: .leading, spacing: 6) {
          Label(
            directChatCopy(.requestSentTitle, language: language),
            systemImage: "checkmark.circle.fill"
          )
          .font(.headline.weight(.bold))
          .foregroundStyle(BilingualReferencePalette.green)
          Text(result.simulatedCounterpart && store.lastAcceptedRoomID != nil
            ? (language == .japanese ? "審査用の架空の相手が応答しました。チャットから予定調整を続けられます。" : "The fictional counterpart responded. Continue planning from Chats.")
            : directChatCopy(.requestSentBody, language: language))
            .font(.subheadline)
            .foregroundStyle(BilingualReferencePalette.muted)
          HStack(spacing: 5) {
            Text(directChatCopy(.expires, language: language))
            Text(result.expiresAt, style: .date)
          }
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BilingualReferencePalette.softYellow)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("directChatRequest.sent")
      }

      if let error = store.creatingError {
        Text(directChatErrorMessage(error, context: .createRequest, language: language))
          .font(.footnote)
          .foregroundStyle(BilingualReferencePalette.muted)
          .accessibilityIdentifier("directChatRequest.error")
      }

      Button {
        Task {
          await store.createRequest(matchID: matchID).value
          if let result = store.lastCreatedRequest {
            onCompleted?(result)
          }
        }
      } label: {
        HStack(spacing: 10) {
          if store.isCreating { ProgressView().tint(BilingualReferencePalette.ink) }
          Text(
            store.isCreating
              ? directChatCopy(.sending, language: language)
              : directChatCopy(.sendRequest, language: language)
          )
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(BilingualReferencePrimaryButtonStyle())
      .disabled(store.isCreating)
      .accessibilityIdentifier("directChatRequest.submit")
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .shadow(color: BilingualReferencePalette.ink.opacity(0.05), radius: 16, y: 8)
  }
}

typealias ChatRequestView = DirectChatRequestView

private extension View {
  func cardSurface() -> some View {
    self
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.white)
      .overlay {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .stroke(BilingualReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
      .shadow(color: BilingualReferencePalette.ink.opacity(0.05), radius: 16, y: 8)
  }
}
