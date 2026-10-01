#if DEBUG
import SwiftUI

/// A local-only SwiftUI port of the current Web speed-dating reference.
/// It is available only in DEBUG and never replaces the production root.
struct ReferenceJourney: View {
  @StateObject private var model: ReferenceJourneyModel
  @State private var showsProfileEditor = false

  init(
    data: ReferenceJourneyData = ReferenceJourneyFixtures.data,
    actions: ReferenceJourneyActions = ReferenceJourneyActions()
  ) {
    _model = StateObject(
      wrappedValue: ReferenceJourneyModel(
        data: data,
        actions: actions,
        initialProfileDraft: ReferenceJourneyFixtures.profileDraft
      )
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      ReferenceFixtureBar(surfaceState: model.surfaceState) { option in
        model.setPreviewState(option)
      }

      if model.screen == .login {
        screenContent
      } else {
        ReferenceHeader(
          onLogo: { model.navigate(to: headerDestination) },
          selfImageName: model.data.selfImageName,
          onProfile: { showsProfileEditor = true }
        )
        screenContent
      }
    }
    .background(ReferencePalette.cream)
    .tint(ReferencePalette.ink)
    .sheet(item: $model.selectedCandidate) { candidate in
      ReferenceCandidateDetailSheet(candidate: candidate) {
        model.openChat(with: candidate)
      }
    }
    .sheet(isPresented: $showsProfileEditor) {
      ReferenceSetupProfileScreen(
        initialDraft: model.profileDraft,
        backTitle: "キャンセル",
        continueTitle: "保存",
        showsProgress: false,
        onBack: { showsProfileEditor = false }
      ) { draft in
        model.setProfile(draft)
        showsProfileEditor = false
      }
      .presentationDetents([.large])
      .presentationDragIndicator(.visible)
      .tint(ReferencePalette.ink)
    }
    .preferredColorScheme(.light)
  }

  @ViewBuilder
  private var screenContent: some View {
    ReferenceStateSurface(
      state: model.surfaceState,
      onRetry: { model.retrySurface() }
    ) {
      switch model.screen {
      case .login:
        ReferenceLoginScreen(
          candidates: model.data.candidates,
          onContinue: { model.continueFromLogin() }
        )
      case .setupProfile:
        ReferenceSetupProfileScreen(
          initialDraft: model.profileDraft,
          onBack: { model.navigate(to: .login) }
        ) { draft in
          model.setProfile(draft)
          model.continueFromProfile()
        }
      case .setupQuiz:
        ReferenceSetupQuizScreen(
          selectedPace: model.selectedPace,
          selectedWeekend: model.selectedWeekend,
          onBack: { model.navigate(to: .setupProfile) },
          onPace: { model.setPace($0) },
          onWeekend: { model.setWeekend($0) },
          onContinue: { model.continueFromQuiz() }
        )
      case .wardIntro:
        ReferenceWardIntroScreen(
          sessions: model.data.wardSessions,
          step: model.wardStep,
          voicePhase: model.voicePhase,
          onBack: { model.retreatWardPreview() },
          onVoicePhase: { model.setVoicePhase($0) },
          onMicrophoneAttempt: { model.requestMicrophone() },
          onContinue: { model.continueWardPreview() }
        )
      case .insight:
        ReferenceInsightScreen(data: model.data) {
          model.navigate(to: .home)
        }
      case .home:
        ReferenceHomeScreen(
          data: model.data,
          selectedScreen: model.screen,
          onSelectCandidate: { model.selectCandidate($0) },
          onReadInsight: { model.navigate(to: .insight) },
          onOpenChat: { model.openChat(with: $0) },
          onHome: { model.navigate(to: .home) },
          onChat: {
            if let candidate = model.activeCandidate {
              model.openChat(with: candidate)
            } else {
              model.navigate(to: .chat)
            }
          }
        )
      case .chat:
        ReferenceChatScreen(
          model: model,
          onBack: { model.navigate(to: .home) },
          onHome: { model.navigate(to: .home) },
          onChat: { model.navigate(to: .chat) }
        )
      }
    }
  }

  private var headerDestination: ReferenceJourneyScreen {
    switch model.screen {
    case .home, .chat:
      return .home
    case .login:
      return .login
    case .setupProfile, .setupQuiz, .wardIntro, .insight:
      return .login
    }
  }
}

private struct ReferenceLoginScreen: View {
  let candidates: [ReferenceCandidate]
  let onContinue: () -> Void
  @State private var email = "you@example.com"
  @State private var password = "preview123"
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    Group {
      if horizontalSizeClass == .regular {
        HStack(spacing: 0) {
          story
          panel
        }
      } else {
        ScrollView {
          VStack(spacing: 0) {
            story
            panel
          }
        }
      }
    }
    .background(ReferencePalette.cream)
  }

  private var story: some View {
    VStack(alignment: .leading, spacing: 0) {
      ReferenceBrand()
      Spacer(minLength: 44)
      Text("YOUR WARD, YOUR PACE")
        .font(.caption.weight(.bold))
        .tracking(2)
        .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
      Text("会う前の対話を、\nWardに任せる。")
        .font(.system(size: 42, weight: .bold, design: .rounded))
        .tracking(-1.8)
        .foregroundStyle(ReferencePalette.ink)
        .padding(.top, 14)
      Text("あなたを理解したWardが、相性のよい相手のWardと先に話します。")
        .font(.body)
        .foregroundStyle(ReferencePalette.muted)
        .lineSpacing(6)
        .padding(.top, 18)
      Spacer(minLength: 36)
      HStack(spacing: -12) {
        ForEach(candidates) { candidate in
          ReferencePortrait(candidate: candidate, size: .medium)
        }
      }
      .accessibilityHidden(true)
    }
    .padding(28)
    .frame(maxWidth: .infinity, minHeight: 470, alignment: .leading)
    .background(
      LinearGradient(
        colors: [Color(red: 1, green: 0.976, blue: 0.914), .white, Color(red: 0.956, green: 0.945, blue: 1)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
  }

  private var panel: some View {
    VStack {
      VStack(alignment: .leading, spacing: 0) {
        ReferenceWardMark()
          .padding(.bottom, 22)
        Text("おかえりなさい")
          .font(.title.weight(.bold))
          .foregroundStyle(ReferencePalette.ink)
        Text("このプレビューでは、入力内容を送信・保存しません。")
          .font(.subheadline)
          .foregroundStyle(ReferencePalette.muted)
          .lineSpacing(4)
          .padding(.top, 8)

        VStack(alignment: .leading, spacing: 8) {
          Text("メールアドレス")
            .font(.caption.weight(.bold))
            .padding(.top, 26)
          TextField("メールアドレス", text: $email)
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("reference.login.email")
          Text("パスワード")
            .font(.caption.weight(.bold))
            .padding(.top, 8)
          SecureField("パスワード", text: $password)
            .textContentType(.password)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("reference.login.password")
        }

        Button("プレビューを開く", action: onContinue)
          .buttonStyle(ReferencePrimaryButtonStyle())
          .padding(.top, 22)
          .accessibilityIdentifier("reference.login.continue")

        Label("ローカルモック · 外部通信なし", systemImage: "checkmark.shield")
          .font(.caption)
          .foregroundStyle(ReferencePalette.muted)
          .frame(maxWidth: .infinity)
          .padding(.top, 20)
          .accessibilityIdentifier("reference.login.localNote")
      }
      .padding(26)
      .frame(maxWidth: 430)
      .background(.white)
      .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
      .shadow(color: ReferencePalette.ink.opacity(0.1), radius: 30, y: 12)
    }
    .padding(22)
    .frame(maxWidth: .infinity, minHeight: 470)
    .background(ReferencePalette.ink)
  }
}

private struct ReferenceSetupProfileScreen: View {
  let backTitle: String
  let continueTitle: String
  let showsProgress: Bool
  let onBack: () -> Void
  let onContinue: (ReferenceProfileDraft) -> Void
  @State private var draft: ReferenceProfileDraft

  init(
    initialDraft: ReferenceProfileDraft,
    backTitle: String = "戻る",
    continueTitle: String = "次へ",
    showsProgress: Bool = true,
    onBack: @escaping () -> Void,
    onContinue: @escaping (ReferenceProfileDraft) -> Void
  ) {
    self.backTitle = backTitle
    self.continueTitle = continueTitle
    self.showsProgress = showsProgress
    self.onBack = onBack
    self.onContinue = onContinue
    _draft = State(initialValue: initialDraft)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        ReferenceProgressHeader(
          backTitle: backTitle,
          progress: showsProgress ? "セットアップ 1 / 2" : "プロフィール設定",
          progressValue: showsProgress ? 0.5 : 0,
          showsProgress: showsProgress,
          backIdentifier: showsProgress ? "reference.progress.back" : "reference.profile.back",
          onBack: onBack
        )

        VStack(alignment: .leading, spacing: 12) {
          Text("BASIC PROFILE")
            .font(.caption.weight(.bold))
            .tracking(2)
            .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
          Text("まず、あなたのことを少しだけ。")
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .tracking(-1.3)
          Text("変更はプレビュー中だけ反映されます。")
            .font(.body)
            .foregroundStyle(ReferencePalette.muted)
            .lineSpacing(5)

          VStack(alignment: .leading, spacing: 8) {
            Text("ニックネーム").font(.caption.weight(.bold))
            TextField("ニックネーム", text: $draft.name)
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("reference.profile.name")
            Text("生まれた年")
              .font(.caption.weight(.bold))
              .padding(.top, 8)
            TextField("生まれた年", text: $draft.birthYear)
              .keyboardType(.numberPad)
              .textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("reference.profile.birthYear")
            Text("性別")
              .font(.caption.weight(.bold))
              .padding(.top, 8)
            Picker("性別", selection: $draft.gender) {
              ForEach(ReferenceProfileGender.allCases) { gender in
                Text(gender.title).tag(gender)
              }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(ReferencePalette.field)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("reference.profile.gender")
          }
          .padding(.top, 10)

          preferenceSection
          locationSection

          Button(continueTitle, action: { onContinue(draft) })
            .buttonStyle(ReferencePrimaryButtonStyle())
            .padding(.top, 10)
            .disabled(!draft.isReadyForContinue)
            .accessibilityIdentifier("reference.profile.continue")
        }
        .padding(26)
        .background(.white)
        .overlay {
          RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(ReferencePalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
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

  private var preferenceSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("恋愛対象").font(.caption.weight(.bold))
      Text("希望する相手を選べます。回答しない場合は選択内容を使いません。")
        .font(.footnote)
        .foregroundStyle(ReferencePalette.muted)
      HStack(spacing: 9) {
        profileChoice(
          title: "希望を選ぶ",
          isSelected: draft.preferenceMode == .selected,
          identifier: "reference.profile.preference.selected"
        ) {
          draft.setPreferenceMode(.selected)
        }
        profileChoice(
          title: "回答しない",
          isSelected: draft.preferenceMode == .noAnswer,
          identifier: "reference.profile.preference.noAnswer"
        ) {
          draft.setPreferenceMode(.noAnswer)
        }
      }
      if draft.preferenceMode == .selected {
        ForEach(ReferenceProfileGender.allCases.filter { $0 != .preferNotToSay }) { gender in
          profileChoice(
            title: gender.title,
            isSelected: draft.preferredGenders.contains(gender),
            identifier: "reference.profile.preferred.\(gender.id)"
          ) {
            draft.togglePreferredGender(gender)
          }
        }
      }
    }
    .padding(.top, 14)
  }

  private var locationSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("いつものエリア").font(.caption.weight(.bold))
      Text("最寄り駅を選ぶと、生活エリアが設定されます。あとから変更できます。")
        .font(.footnote)
        .foregroundStyle(ReferencePalette.muted)
      profileChoice(
        title: "最寄り駅",
        isSelected: draft.locationMode == .station,
        identifier: "reference.profile.location.station"
      ) {
        draft.setLocationMode(.station)
      }
      profileChoice(
        title: "あとで設定する",
        isSelected: draft.locationMode == .notSet,
        identifier: "reference.profile.location.notSet"
      ) {
        draft.setLocationMode(.notSet)
      }

      if draft.locationMode == .station {
        stationPicker
        if let station = ReferenceJourneyFixtures.stationOptions.first(where: { $0.id == draft.stationID }),
          let areaID = station.areaID,
          let areaTitle = ReferenceJourneyFixtures.areaTitles[areaID]
        {
          Text("生活エリア: \(areaTitle)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ReferencePalette.muted)
            .accessibilityIdentifier("reference.profile.location.areaValue")
        }
      }
    }
    .padding(.top, 14)
  }

  private var stationPicker: some View {
    Picker(
      "最寄り駅",
      selection: Binding<String>(
        get: { draft.stationID ?? "" },
        set: { value in
          draft.selectStation(
            value.isEmpty
              ? nil
              : ReferenceJourneyFixtures.stationOptions.first(where: { $0.id == value })
          )
        }
      )
    ) {
      Text("駅を選択…").tag("")
      ForEach(ReferenceJourneyFixtures.stationOptions) { option in
        Text(option.title).tag(option.id)
      }
    }
    .pickerStyle(.menu)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .frame(minHeight: 48)
    .background(ReferencePalette.field)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityIdentifier("reference.profile.station")
  }

  private func profileChoice(
    title: String,
    isSelected: Bool,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack {
        Text(title).multilineTextAlignment(.leading)
        Spacer()
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(ReferencePalette.yellow)
            .accessibilityHidden(true)
        }
      }
      .foregroundStyle(ReferencePalette.ink)
      .padding(.horizontal, 14)
      .frame(minHeight: 48)
      .background(isSelected ? ReferencePalette.yellowSoft : ReferencePalette.field)
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(isSelected ? ReferencePalette.yellow : ReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier(identifier)
  }

}

private struct ReferenceSetupQuizScreen: View {
  let selectedPace: ReferenceQuizPace
  let selectedWeekend: ReferenceQuizWeekend
  let onBack: () -> Void
  let onPace: (ReferenceQuizPace) -> Void
  let onWeekend: (ReferenceQuizWeekend) -> Void
  let onContinue: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        ReferenceProgressHeader(
          backTitle: "戻る",
          progress: "セットアップ 2 / 2",
          progressValue: 1,
          onBack: onBack
        )

        VStack(alignment: .leading, spacing: 12) {
          Text("FIRST IMPRESSION")
            .font(.caption.weight(.bold))
            .tracking(2)
            .foregroundStyle(Color(red: 0.57, green: 0.44, blue: 0.0))
          Text("心地よい関係を教えてください。")
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .tracking(-1.3)
          Text("正解はありません。今の気分に近いものを選んでください。")
            .font(.body)
            .foregroundStyle(ReferencePalette.muted)
            .lineSpacing(5)

          VStack(alignment: .leading, spacing: 9) {
            Text("初対面では").font(.caption.weight(.bold))
            quizChoice(
              title: ReferenceQuizPace.slow.title,
              isSelected: selectedPace == .slow,
              identifier: "reference.quiz.pace.slow",
              action: { onPace(.slow) }
            )
            quizChoice(
              title: ReferenceQuizPace.quick.title,
              isSelected: selectedPace == .quick,
              identifier: "reference.quiz.pace.quick",
              action: { onPace(.quick) }
            )
          }
          .padding(.top, 12)

          VStack(alignment: .leading, spacing: 9) {
            Text("休日は").font(.caption.weight(.bold))
            quizChoice(
              title: ReferenceQuizWeekend.outside.title,
              isSelected: selectedWeekend == .outside,
              identifier: "reference.quiz.weekend.outside",
              action: { onWeekend(.outside) }
            )
            quizChoice(
              title: ReferenceQuizWeekend.both.title,
              isSelected: selectedWeekend == .both,
              identifier: "reference.quiz.weekend.both",
              action: { onWeekend(.both) }
            )
          }
          .padding(.top, 8)

          Button("Wardとの会話へ", action: onContinue)
            .buttonStyle(ReferencePrimaryButtonStyle())
            .padding(.top, 8)
            .accessibilityIdentifier("reference.quiz.continue")
        }
        .padding(26)
        .background(.white)
        .overlay {
          RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(ReferencePalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
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

  private func quizChoice(
    title: String,
    isSelected: Bool,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack {
        Text(title).multilineTextAlignment(.leading)
        Spacer()
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(ReferencePalette.yellow)
            .accessibilityHidden(true)
        }
      }
      .foregroundStyle(ReferencePalette.ink)
      .padding(.horizontal, 14)
      .frame(minHeight: 48)
      .background(isSelected ? ReferencePalette.yellowSoft : ReferencePalette.field)
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(isSelected ? ReferencePalette.yellow : ReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier(identifier)
  }
}
#endif
