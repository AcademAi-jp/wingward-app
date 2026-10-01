#if DEBUG
import SwiftUI

struct ReferenceHomeScreen: View {
  let data: ReferenceJourneyData
  let selectedScreen: ReferenceJourneyScreen
  let onSelectCandidate: (ReferenceCandidate) -> Void
  let onReadInsight: () -> Void
  let onOpenChat: (ReferenceCandidate) -> Void
  let onHome: () -> Void
  let onChat: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        HStack(alignment: .bottom) {
          VStack(alignment: .leading, spacing: 5) {
            Text("WARD SELECTED")
              .font(.caption2.weight(.bold))
              .tracking(1.5)
              .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
            Text("相性のよい人")
              .font(.title.weight(.bold))
          }
          Spacer()
          Text("相性順")
            .font(.caption)
            .foregroundStyle(ReferencePalette.muted)
        }

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 22) {
            ForEach(data.candidates) { candidate in
              Button {
                onSelectCandidate(candidate)
              } label: {
                VStack(spacing: 8) {
                  ReferencePortrait(candidate: candidate, size: .large)
                  Text(candidate.name)
                    .font(.subheadline.weight(.semibold))
                  Text("\(candidate.match)%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
                }
                .frame(minWidth: 94)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("\(candidate.name)のプロフィールを表示")
              .accessibilityIdentifier("reference.home.candidate.\(candidate.id)")
            }
          }
          .padding(.horizontal, 3)
          .padding(.bottom, 4)
        }

        VStack(alignment: .leading, spacing: 18) {
          HStack(alignment: .top, spacing: 18) {
            Image(data.selfImageName)
              .resizable()
              .scaledToFill()
              .frame(width: 82, height: 82)
              .clipShape(Circle())
              .accessibilityLabel("あなたの水彩画プロフィール")
            VStack(alignment: .leading, spacing: 5) {
              Text("YOUR CONVERSATION INSIGHT")
                .font(.caption2.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
              Text("深く聴き、言葉で安心をつくる人")
                .font(.title3.weight(.bold))
              Text("相手の言葉を受け止めながら、小さな共感を重ねて信頼を育てます。")
                .font(.subheadline)
                .foregroundStyle(ReferencePalette.muted)
                .lineSpacing(4)
            }
          }
          .padding(.bottom, 2)
          .overlay(alignment: .bottom) {
            Rectangle().fill(ReferencePalette.line).frame(height: 1)
          }

          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(data.insightTags, id: \.self) { tag in
                ReferenceTag(text: tag)
              }
            }
          }

          Button("分析レポートを読む", action: onReadInsight)
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("reference.home.insight")
        }
        .padding(24)
        .background(.white)
        .overlay {
          RoundedRectangle(cornerRadius: 26, style: .continuous)
            .stroke(ReferencePalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

        if let candidate = data.candidates.first {
          VStack(spacing: 16) {
            HStack(spacing: -8) {
              Image(data.selfImageName)
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 58)
                .clipShape(Circle())
                .overlay { Circle().stroke(ReferencePalette.ink, lineWidth: 3) }
              ReferenceWardMark(size: .small)
                .zIndex(1)
              ReferencePortrait(candidate: candidate, size: .small)
                .overlay { Circle().stroke(ReferencePalette.ink, lineWidth: 3) }
            }
            Text("\(candidate.name)のWardと\n会話しています")
              .font(.title2.weight(.bold))
              .multilineTextAlignment(.center)
            Text("相性 \(candidate.match)%。会話のリズムと感情的な応答に強い近さがあります。")
              .font(.subheadline)
              .foregroundStyle(Color.white.opacity(0.72))
              .multilineTextAlignment(.center)
              .lineSpacing(4)
            Button("会話を見る", action: { onOpenChat(candidate) })
              .font(.headline.weight(.semibold))
              .foregroundStyle(ReferencePalette.ink)
              .frame(maxWidth: .infinity, minHeight: 52)
              .background(.white)
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
              .accessibilityIdentifier("reference.home.openChat")
          }
          .padding(26)
          .frame(maxWidth: .infinity)
          .background(ReferencePalette.ink)
          .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 26)
      .frame(maxWidth: 1140)
      .frame(maxWidth: .infinity)
    }
    .background(ReferencePalette.cream)
    .safeAreaInset(edge: .bottom) {
      ReferenceBottomNav(selected: selectedScreen, onHome: onHome, onChat: onChat)
    }
  }
}

struct ReferenceCandidateDetailSheet: View {
  let candidate: ReferenceCandidate
  let onOpenChat: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .top, spacing: 18) {
          ReferencePortrait(candidate: candidate, size: .large)
          VStack(alignment: .leading, spacing: 5) {
            Text("MATCH")
              .font(.caption2.weight(.bold))
              .tracking(1.5)
              .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
            Text("\(candidate.match)%")
              .font(.system(size: 38, weight: .bold, design: .rounded))
            Text("\(candidate.name), \(candidate.age)")
              .font(.title3.weight(.bold))
            Text(candidate.location)
              .font(.subheadline)
              .foregroundStyle(ReferencePalette.muted)
          }
        }

        Text(candidate.summary)
          .font(.body)
          .foregroundStyle(ReferencePalette.muted)
          .lineSpacing(5)

        VStack(alignment: .leading, spacing: 6) {
          Text("WARD SUMMARY")
            .font(.caption2.weight(.bold))
            .tracking(1.5)
            .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
          Text(candidate.signature)
            .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(ReferencePalette.yellowSoft)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        VStack(spacing: 1) {
          ForEach(candidate.reasons) { reason in
            VStack(alignment: .leading, spacing: 5) {
              Text(reason.label).font(.subheadline.weight(.bold))
              Text(reason.detail)
                .font(.footnote)
                .foregroundStyle(ReferencePalette.muted)
                .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(ReferencePalette.field)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        Button("Wardの会話を見る") {
          onOpenChat()
          dismiss()
        }
        .buttonStyle(ReferencePrimaryButtonStyle())
        .accessibilityIdentifier("reference.candidate.openChat")
      }
      .padding(24)
    }
    .background(ReferencePalette.cream)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(candidate.name)のプロフィール")
  }
}

struct ReferenceChatScreen: View {
  @ObservedObject var model: ReferenceJourneyModel
  let onBack: () -> Void
  let onHome: () -> Void
  let onChat: () -> Void
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    VStack(spacing: 0) {
      if horizontalSizeClass == .regular {
        HStack(spacing: 0) {
          inbox
            .frame(width: 250)
          chatColumn
        }
      } else {
        chatColumn
      }
    }
    .background(.white)
    .safeAreaInset(edge: .bottom) {
      ReferenceBottomNav(selected: .chat, onHome: onHome, onChat: onChat)
    }
  }

  private var inbox: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .bottom) {
          Text("トーク")
            .font(.title2.weight(.bold))
          Spacer()
          Text("相性順")
            .font(.caption)
            .foregroundStyle(ReferencePalette.muted)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)

        ForEach(model.data.candidates) { candidate in
          Button {
            model.openChat(with: candidate)
          } label: {
            HStack(spacing: 10) {
              ReferencePortrait(candidate: candidate, size: .small)
              VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name).font(.subheadline.weight(.bold))
                Text("\(candidate.name)のWardが対話中")
                  .font(.caption2)
                  .foregroundStyle(ReferencePalette.muted)
                  .lineLimit(1)
              }
              Spacer(minLength: 4)
              Text("\(candidate.match)%")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
            }
            .padding(10)
            .background(model.activeCandidate?.id == candidate.id ? ReferencePalette.line : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(candidate.name)のトークを開く")
          .accessibilityIdentifier("reference.chat.thread.\(candidate.id)")
        }
      }
      .padding(14)
    }
    .overlay(alignment: .trailing) {
      Rectangle().fill(ReferencePalette.line).frame(width: 1)
    }
  }

  @ViewBuilder
  private var chatColumn: some View {
    if let candidate = model.activeCandidate {
      VStack(spacing: 0) {
        chatHeader(candidate)
        modePicker
        contextBanner
        messages(for: candidate)
        composer(for: candidate)
      }
    } else {
      ReferenceStateSurface(state: .empty) {
        Text("候補者を選択してください。")
      }
    }
  }

  private func chatHeader(_ candidate: ReferenceCandidate) -> some View {
    HStack(spacing: 10) {
      Button(action: onBack) {
        Image(systemName: "chevron.left")
          .font(.headline)
          .frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("ホームへ戻る")
      .accessibilityIdentifier("reference.chat.back")
      ReferencePortrait(candidate: candidate, size: .small)
      VStack(alignment: .leading, spacing: 3) {
        Text(candidate.name).font(.subheadline.weight(.bold))
        Text(model.chatMode == .ward ? "Ward同士が会話中" : "自分で会話中")
          .font(.caption2)
          .foregroundStyle(ReferencePalette.muted)
      }
      Spacer()
      Text("\(candidate.match)%")
        .font(.caption.weight(.bold))
        .foregroundStyle(Color(red: 0.45, green: 0.34, blue: 0.0))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(ReferencePalette.yellowSoft)
        .clipShape(Capsule())
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .overlay(alignment: .bottom) {
      Rectangle().fill(ReferencePalette.line).frame(height: 1)
    }
  }

  private var modePicker: some View {
    Picker("会話する主体", selection: Binding(
      get: { model.chatMode },
      set: { model.setChatMode($0) }
    )) {
      ForEach(ReferenceChatMode.allCases) { mode in
        Text(mode.title).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .accessibilityLabel("会話する主体")
    .accessibilityIdentifier("reference.chat.modePicker")
  }

  private var contextBanner: some View {
    HStack(spacing: 9) {
      ReferenceWardMark(size: .small)
      VStack(alignment: .leading, spacing: 2) {
        Text(model.chatMode == .ward ? "Ward同士の会話" : "あなたと相手の会話")
          .font(.caption.weight(.bold))
        Text(model.chatMode == .ward ? "Wardがあなたの代わりに対話しています。" : "あなた自身の言葉で送信します。")
          .font(.caption2)
          .foregroundStyle(ReferencePalette.muted)
      }
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .background(Color(red: 1, green: 0.98, blue: 0.94))
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color(red: 0.953, green: 0.894, blue: 0.698)).frame(height: 1)
    }
  }

  private func messages(for candidate: ReferenceCandidate) -> some View {
    let messages = model.chatMode == .ward
      ? model.data.wardMessages(for: candidate.id)
      : model.data.personMessages(for: candidate.id)

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 13) {
        Text("今日")
          .font(.caption)
          .foregroundStyle(ReferencePalette.muted)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.bottom, 4)
        if messages.isEmpty {
          VStack(spacing: 10) {
            Image(systemName: "bubble.left")
              .font(.title2)
              .foregroundStyle(ReferencePalette.yellow)
            Text("この会話のサンプルはまだありません。")
              .font(.subheadline.weight(.semibold))
            Text("状態メニューから空の表示も確認できます。")
              .font(.caption)
              .foregroundStyle(ReferencePalette.muted)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 60)
        } else {
          ForEach(messages) { message in
            ReferenceMessageBubble(message: message)
          }
        }
      }
      .padding(18)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ReferencePalette.cream)
  }

  private func composer(for candidate: ReferenceCandidate) -> some View {
    Group {
      if model.chatMode == .ward {
        HStack(spacing: 10) {
          ReferenceWardMark(size: .small)
          VStack(alignment: .leading, spacing: 2) {
            Text("Ward同士の会話は自動で進みます")
              .font(.caption.weight(.bold))
            Text("必要なときだけ「自分」へ切り替えられます。")
              .font(.caption2)
              .foregroundStyle(ReferencePalette.muted)
          }
          Spacer()
        }
      } else {
        HStack(spacing: 9) {
          TextField(
            "\(candidate.name)へメッセージ…",
            text: Binding(get: { model.draft }, set: { model.setDraft($0) })
          )
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("メッセージ")
          .accessibilityIdentifier("reference.chat.draft")
          Button(action: { model.attemptSend() }) {
            Image(systemName: "paperplane.fill")
              .frame(width: 48, height: 48)
              .background(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ReferencePalette.line : ReferencePalette.yellow)
              .clipShape(Circle())
          }
          .buttonStyle(.plain)
          .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityLabel("送信を試す")
          .accessibilityIdentifier("reference.chat.send")
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 11)
    .frame(minHeight: 76)
    .background(.white)
    .overlay(alignment: .top) {
      Rectangle().fill(ReferencePalette.line).frame(height: 1)
    }
  }
}
#endif
