#if DEBUG
import SwiftUI

struct ReferenceWardIntroScreen: View {
  let sessions: [ReferenceWardSession]
  let step: Int
  let voicePhase: ReferenceVoicePhase
  let onBack: () -> Void
  let onVoicePhase: (ReferenceVoicePhase) -> Void
  let onMicrophoneAttempt: () -> Void
  let onContinue: () -> Void

  private var session: ReferenceWardSession? {
    guard sessions.indices.contains(step) else { return nil }
    return sessions[step]
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        ReferenceProgressHeader(
          backTitle: "戻る",
          progress: "\(min(step + 1, max(sessions.count, 1))) / \(max(sessions.count, 1))",
          progressValue: sessions.isEmpty ? 0 : min(1, Double(step + 1) / Double(sessions.count)),
          onBack: onBack
        )

        if let session {
          VStack(spacing: 16) {
            Text("VOICE WITH WARD")
              .font(.caption.weight(.bold))
              .tracking(2)
              .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
            Button(action: onMicrophoneAttempt) {
              ReferenceWardMark(size: .large)
                .padding(25)
                .background(Color(red: 1, green: 0.992, blue: 0.969))
                .clipShape(Circle())
                .overlay {
                  Circle().stroke(ReferencePalette.yellow, lineWidth: 2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("音声会話を試す（マイクは起動しません）")
            .accessibilityIdentifier("reference.ward.microphone")
            Text(session.name)
              .font(.title2.weight(.bold))
            Text(voicePhase.title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
              .accessibilityIdentifier("reference.ward.voiceState")

            Picker("音声表示状態", selection: Binding(
              get: { voicePhase },
              set: { onVoicePhase($0) }
            )) {
              ForEach(ReferenceVoicePhase.allCases) { phase in
                Text(phase.title).tag(phase)
              }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("音声表示状態を選択")
            .accessibilityIdentifier("reference.ward.phasePicker")

            HStack(spacing: 5) {
              ForEach(Array([11, 25, 34, 17, 29, 13, 31, 21, 10].enumerated()), id: \.offset) { _, height in
                RoundedRectangle(cornerRadius: 4)
                  .fill(ReferencePalette.yellow)
                  .frame(width: 4, height: CGFloat(height))
              }
            }
            .frame(height: 42)
            .padding(.vertical, 6)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
              Text("字幕プレビュー")
                .font(.caption2.weight(.bold))
                .foregroundStyle(ReferencePalette.muted)
              Text(voicePhase == .listening ? "話している間、Wardは静かに聞いています。" : session.caption)
                .font(.body)
                .lineSpacing(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(ReferencePalette.field)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text("ローカルモックのため、マイクは起動しません。")
              .font(.caption)
              .foregroundStyle(ReferencePalette.muted)
              .multilineTextAlignment(.center)

            Button("画面を見る", action: onContinue)
              .buttonStyle(ReferencePrimaryButtonStyle())
              .padding(.top, 4)
              .accessibilityIdentifier("reference.ward.viewNext")
          }
          .padding(26)
          .frame(maxWidth: 620)
          .background(.white)
          .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
              .stroke(ReferencePalette.line, lineWidth: 1)
          }
          .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        } else {
          Text("Wardのセッションはありません。")
            .foregroundStyle(ReferencePalette.muted)
        }
      }
      .padding(20)
      .frame(maxWidth: 700)
      .frame(maxWidth: .infinity)
    }
    .background(
      LinearGradient(
        colors: [.white, ReferencePalette.cream],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }
}

struct ReferenceInsightScreen: View {
  let data: ReferenceJourneyData
  let onContinue: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("YOUR CONVERSATION INSIGHT")
          .font(.caption.weight(.bold))
          .tracking(2)
          .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
        Text("あなたの対話の輪郭が\n見えてきました。")
          .font(.system(size: 38, weight: .bold, design: .rounded))
          .tracking(-1.5)
        Text("3人のWardとの会話から、あなたが安心して関係を育てるときの傾向を、読みやすい言葉にまとめました。")
          .font(.body)
          .foregroundStyle(ReferencePalette.muted)
          .lineSpacing(6)

        VStack(alignment: .leading, spacing: 20) {
          HStack(alignment: .top, spacing: 18) {
            Image(data.selfImageName)
              .resizable()
              .scaledToFill()
              .frame(width: 82, height: 82)
              .clipShape(Circle())
              .accessibilityLabel("あなたの水彩画プロフィール")
            VStack(alignment: .leading, spacing: 5) {
              Text("OVERALL SIGNATURE")
                .font(.caption2.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
              Text("深く聴き、言葉で安心をつくる人")
                .font(.title3.weight(.bold))
              Text("相手の言葉をいったん受け取り、気持ちを確かめながら会話を深めていく人です。最初から強く自分を見せるより、小さな共感を重ねるほど自然な魅力が伝わります。")
                .font(.subheadline)
                .foregroundStyle(ReferencePalette.muted)
                .lineSpacing(4)
            }
          }
          .padding(.bottom, 4)
          .overlay(alignment: .bottom) {
            Rectangle().fill(ReferencePalette.line).frame(height: 1)
          }

          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 105), spacing: 8)],
            alignment: .leading,
            spacing: 8
          ) {
            ForEach(data.insightTags, id: \.self) { tag in
              ReferenceTag(text: tag)
            }
          }

          VStack(spacing: 1) {
            ForEach(data.insightSections) { section in
              VStack(alignment: .leading, spacing: 7) {
                Text(section.title)
                  .font(.subheadline.weight(.bold))
                Text(section.body)
                  .font(.footnote)
                  .foregroundStyle(ReferencePalette.muted)
                  .lineSpacing(5)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(18)
              .background(ReferencePalette.field)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(24)
        .background(.white)
        .overlay {
          RoundedRectangle(cornerRadius: 26, style: .continuous)
            .stroke(ReferencePalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

        Button("マッチング画面を見る", action: onContinue)
          .buttonStyle(ReferencePrimaryButtonStyle())
          .accessibilityIdentifier("reference.insight.continue")
        Label("会話から生成した要約です。内部スコアは表示していません。", systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(ReferencePalette.muted)
          .frame(maxWidth: .infinity, alignment: .center)
      }
      .padding(20)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
    .background(ReferencePalette.cream)
  }
}
#endif
