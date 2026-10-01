import SwiftUI

struct QuizView: View {
  let ownerID: String
  let api: any QuizAPI
  let locale: OnboardingLanguage
  let onDismiss: (() -> Void)?
  let onSaved: (() -> Void)?

  @Environment(\.dismiss) private var dismiss
  @State private var store: QuizStore
  @State private var questionIndex = 0
  @State private var showsDiscardConfirmation = false

  init(
    ownerID: String,
    api: any QuizAPI,
    locale: OnboardingLanguage = .en,
    onDismiss: (() -> Void)? = nil,
    onSaved: (() -> Void)? = nil
  ) {
    self.ownerID = ownerID
    self.api = api
    self.locale = locale
    self.onDismiss = onDismiss
    self.onSaved = onSaved
    _store = State(initialValue: QuizStore(ownerID: ownerID, api: api))
  }

  var body: some View {
    NavigationStack {
      ZStack {
        QuizViewPalette.cream.ignoresSafeArea()

        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            switch store.phase {
            case .idle, .loading:
              loadingSurface
            case .failed:
              failureSurface(store.loadError ?? .temporarilyUnavailable)
            case .loaded, .saving:
              if store.questions.isEmpty {
                loadingSurface
              } else {
                quizSurface
              }
            }
          }
          .frame(maxWidth: 680, alignment: .leading)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 22)
          .padding(.vertical, 18)
        }
        .scrollIndicators(.hidden)
      }
      .toolbar(.hidden, for: .navigationBar)
    }
    .background(QuizViewPalette.cream.ignoresSafeArea())
    .tint(QuizViewPalette.ink)
    .preferredColorScheme(.light)
    .interactiveDismissDisabled(store.isSaving || hasUnsavedChanges)
    .task(id: ownerID) {
      await store.load().value
    }
    .onDisappear {
      store.cancel()
    }
    .alert(
      copy.discardTitle,
      isPresented: $showsDiscardConfirmation
    ) {
      Button(copy.discardAction, role: .destructive) {
        dismissQuiz()
      }
      Button(copy.keepEditing, role: .cancel) {}
    } message: {
      Text(copy.discardMessage)
    }
  }

  private var copy: QuizCopy {
    QuizCopy(locale: locale)
  }

  private var loadingSurface: some View {
    VStack(alignment: .leading, spacing: 16) {
      closeHeader

      QuizStatusIcon(systemImage: "sparkles")
        .padding(.top, 20)

      Text(copy.loadingTitle)
        .font(.system(size: 34, weight: .bold, design: .rounded))
        .tracking(-0.8)
        .padding(.top, 8)

      Text(copy.description)
        .font(.body)
        .foregroundStyle(QuizViewPalette.muted)

      HStack(spacing: 12) {
        ProgressView()
          .tint(QuizViewPalette.accentText)
        Text(copy.loadingMessage)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(QuizViewPalette.ink)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 12)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("onboarding.quiz.loading")
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quizCard(cornerRadius: 26)
  }

  private func failureSurface(_ error: QuizStoreError) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      closeHeader

      QuizStatusIcon(systemImage: "exclamationmark.triangle.fill")
        .padding(.top, 20)

      Text(copy.loadErrorTitle)
        .font(.system(size: 34, weight: .bold, design: .rounded))
        .tracking(-0.8)
        .padding(.top, 8)

      Text(copy.loadErrorMessage(for: error))
        .font(.body)
        .foregroundStyle(QuizViewPalette.muted)
        .lineSpacing(5)

      Button(copy.retry) {
        questionIndex = 0
        Task { await store.retry().value }
      }
      .buttonStyle(QuizPrimaryButtonStyle())
      .padding(.top, 6)
      .accessibilityIdentifier("onboarding.quiz.retry")
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quizCard(cornerRadius: 26)
  }

  private var quizSurface: some View {
    VStack(alignment: .leading, spacing: 16) {
      progressHeader

      if store.didSave {
        savedConfirmation
      }

      questionCard

      if let error = store.saveError {
        saveErrorSurface(error)
          .accessibilityIdentifier("onboarding.quiz.saveError")
      }

      navigationControls
    }
    .id("onboarding.quiz.\(ownerID)")
  }

  private var progressHeader: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Button(action: requestDismiss) {
          Image(systemName: "chevron.left")
            .font(.headline.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.76))
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(QuizViewPalette.ink)
        .accessibilityLabel(copy.back)
        .accessibilityIdentifier("onboarding.quiz.back")
        .disabled(store.isSaving)

        Spacer(minLength: 0)

        VStack(alignment: .trailing, spacing: 3) {
          Text(copy.progressKicker)
            .font(.caption2.weight(.bold))
            .tracking(1.3)
            .foregroundStyle(QuizViewPalette.muted)
          Text("\(questionIndex + 1) / \(store.questions.count)")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(QuizViewPalette.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(copy.progressAccessibilityLabel)
        .accessibilityValue(
          copy.progressAccessibilityValue(current: questionIndex + 1, total: store.questions.count)
        )
      }

      ProgressView(
        value: Double(questionIndex + 1),
        total: Double(max(store.questions.count, 1))
      )
      .tint(QuizViewPalette.yellow)
      .scaleEffect(x: 1, y: 1.7, anchor: .center)
      .accessibilityLabel(copy.progressAccessibilityLabel)
      .accessibilityValue(
        copy.progressAccessibilityValue(current: questionIndex + 1, total: store.questions.count)
      )
    }
  }

  private var currentQuestion: QuizQuestion? {
    guard store.questions.indices.contains(questionIndex) else { return nil }
    return store.questions[questionIndex]
  }

  private var questionCard: some View {
    Group {
      if let question = currentQuestion {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 8) {
            Text(copy.category(question.category))
              .font(.caption.weight(.bold))
              .tracking(1.6)
              .foregroundStyle(QuizViewPalette.accentText)
              .textCase(.uppercase)
            Text(copy.question(question))
              .font(.system(size: 28, weight: .bold, design: .rounded))
              .foregroundStyle(QuizViewPalette.ink)
              .lineSpacing(3)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("onboarding.quiz.question.\(question.id)")
            Text(question.allowMultiple ? copy.multipleHint : copy.singleHint)
              .font(.footnote)
              .foregroundStyle(QuizViewPalette.muted)
          }

          VStack(spacing: 10) {
            ForEach(copy.options(question), id: \.value) { option in
              QuizOptionCard(
                option: option,
                isSelected: selectedValues(for: question).contains(option.value),
                isMultiple: question.allowMultiple,
                identifier: "onboarding.quiz.option.\(question.id).\(option.value)",
                selectedLabel: copy.selected,
                notSelectedLabel: copy.notSelected
              ) {
                store.toggleSelection(questionID: question.id, optionValue: option.value)
              }
              .disabled(store.isSaving)
            }
          }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .quizCard(cornerRadius: 26)
      }
    }
  }

  private var savedConfirmation: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "checkmark.circle.fill")
        .font(.title3.weight(.semibold))
        .foregroundStyle(QuizViewPalette.accentText)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(copy.saved)
          .font(.subheadline.weight(.bold))
        Text(copy.savedDetail)
          .font(.caption)
          .foregroundStyle(QuizViewPalette.muted)
      }
    }
    .foregroundStyle(QuizViewPalette.ink)
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(QuizViewPalette.yellowSoft)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityIdentifier("onboarding.quiz.saved")
  }

  private func saveErrorSurface(_ error: QuizStoreError) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.circle.fill")
        .font(.title3.weight(.semibold))
        .foregroundStyle(QuizViewPalette.accentText)
        .accessibilityHidden(true)
      Text(copy.errorMessage(for: error))
        .font(.footnote.weight(.semibold))
        .foregroundStyle(QuizViewPalette.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(QuizViewPalette.yellowSoft)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private var navigationControls: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        Button {
          questionIndex = max(0, questionIndex - 1)
        } label: {
          Label(copy.previous, systemImage: "chevron.left")
        }
        .buttonStyle(QuizSecondaryButtonStyle())
        .disabled(questionIndex == 0 || store.isSaving)
        .accessibilityIdentifier("onboarding.quiz.previous")

        if questionIndex < store.questions.count - 1 {
          Button {
            questionIndex += 1
          } label: {
            Label(copy.next, systemImage: "chevron.right")
              .labelStyle(.titleAndIcon)
          }
          .buttonStyle(QuizPrimaryButtonStyle())
          .disabled(!hasCurrentSelection || store.isSaving)
          .accessibilityIdentifier("onboarding.quiz.next")
        } else {
          Button {
            saveAnswers()
          } label: {
            HStack(spacing: 8) {
              if store.isSaving {
                ProgressView().tint(QuizViewPalette.ink)
              }
              Text(store.isSaving ? copy.saving : copy.save)
            }
          }
          .buttonStyle(QuizPrimaryButtonStyle())
          .disabled(!store.canSave || store.isSaving)
          .accessibilityIdentifier("onboarding.quiz.save")
        }
      }
      if questionIndex == store.questions.count - 1 && !store.canSave && !store.isSaving {
        Text(copy.completeBeforeSave)
          .font(.footnote)
          .foregroundStyle(QuizViewPalette.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("onboarding.quiz.incomplete")
      }
    }
  }

  private var hasCurrentSelection: Bool {
    guard let currentQuestion else { return false }
    return !selectedValues(for: currentQuestion).isEmpty
  }

  private func selectedValues(for question: QuizQuestion) -> [String] {
    store.draftAnswers[question.id] ?? []
  }

  private func saveAnswers() {
    guard store.canSave, !store.isSaving else { return }
    Task {
      await store.save().value
      if store.didSave { onSaved?() }
    }
  }

  private func requestDismiss() {
    guard !store.isSaving else { return }
    if hasUnsavedChanges {
      showsDiscardConfirmation = true
    } else {
      dismissQuiz()
    }
  }

  private var hasUnsavedChanges: Bool {
    store.draftAnswers != store.savedAnswers
  }

  private func dismissQuiz() {
    store.cancel()
    if let onDismiss {
      onDismiss()
    } else {
      dismiss()
    }
  }

  private var closeHeader: some View {
    HStack {
      Button {
        requestDismiss()
      } label: {
        Image(systemName: "chevron.left")
          .font(.headline.weight(.semibold))
          .frame(width: 44, height: 44)
          .background(.white.opacity(0.76))
          .clipShape(Circle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(QuizViewPalette.ink)
      .accessibilityLabel(copy.back)
      .accessibilityIdentifier("onboarding.quiz.back")
      Spacer()
    }
  }
}

private struct QuizStatusIcon: View {
  let systemImage: String

  var body: some View {
    Image(systemName: systemImage)
      .font(.title2.weight(.bold))
      .foregroundStyle(QuizViewPalette.ink)
      .frame(width: 64, height: 64)
      .background(QuizViewPalette.yellow)
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: 22,
          bottomLeadingRadius: 8,
          bottomTrailingRadius: 22,
          topTrailingRadius: 22
        )
      )
      .accessibilityHidden(true)
  }
}

private struct QuizOptionCard: View {
  let option: QuizOption
  let isSelected: Bool
  let isMultiple: Bool
  let identifier: String
  let selectedLabel: String
  let notSelectedLabel: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        if isMultiple {
          Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .font(.title3.weight(.semibold))
            .foregroundStyle(isSelected ? QuizViewPalette.accentText : QuizViewPalette.muted)
            .accessibilityHidden(true)
        } else {
          Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
            .font(.title3.weight(.semibold))
            .foregroundStyle(isSelected ? QuizViewPalette.accentText : QuizViewPalette.muted)
            .accessibilityHidden(true)
        }
        Text(option.label)
          .font(.body.weight(isSelected ? .semibold : .medium))
          .foregroundStyle(QuizViewPalette.ink)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 15)
      .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
      .background(isSelected ? QuizViewPalette.yellowSoft : QuizViewPalette.field)
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(isSelected ? QuizViewPalette.accentText : QuizViewPalette.line, lineWidth: isSelected ? 1.5 : 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
    .accessibilityValue(isSelected ? selectedLabel : notSelectedLabel)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct QuizPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline.weight(.bold))
      .foregroundStyle(QuizViewPalette.ink)
      .frame(maxWidth: .infinity, minHeight: 54)
      .background(QuizViewPalette.yellow)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .opacity(configuration.isPressed ? 0.86 : 1)
  }
}

private struct QuizSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(QuizViewPalette.ink)
      .frame(maxWidth: .infinity, minHeight: 54)
      .background(QuizViewPalette.field)
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(QuizViewPalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .opacity(configuration.isPressed ? 0.72 : 1)
  }
}

private struct QuizCardModifier: ViewModifier {
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    content
      .background(.white)
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(QuizViewPalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .shadow(color: QuizViewPalette.ink.opacity(0.06), radius: 20, y: 8)
  }
}

private extension View {
  func quizCard(cornerRadius: CGFloat) -> some View {
    modifier(QuizCardModifier(cornerRadius: cornerRadius))
  }
}

private enum QuizViewPalette {
  static let cream = ReferencePalette.cream
  static let ink = ReferencePalette.ink
  static let yellow = ReferencePalette.yellow
  static let yellowSoft = ReferencePalette.yellowSoft
  static let accentText = Color(red: 0.57, green: 0.44, blue: 0.0)
  static let muted = ReferencePalette.muted
  static let line = ReferencePalette.line
  static let field = ReferencePalette.field
}

private struct QuizCopy {
  let locale: OnboardingLanguage

  var title: String { locale == .ja ? "会話クイズ" : "Conversation quiz" }
  var loadingTitle: String { locale == .ja ? "クイズを準備しています" : "Getting your quiz ready" }
  var loadingMessage: String { locale == .ja ? "質問を読み込んでいます…" : "Loading questions…" }
  var description: String {
    locale == .ja
      ? "10問の回答を、あなたのペルソナに反映します。"
      : "Your 10 answers help shape your persona."
  }
  var back: String { locale == .ja ? "戻る" : "Back" }
  var progressKicker: String { locale == .ja ? "質問" : "QUESTION" }
  var progressAccessibilityLabel: String { locale == .ja ? "クイズの進捗" : "Quiz progress" }
  func progressAccessibilityValue(current: Int, total: Int) -> String {
    locale == .ja ? "全\(total)問中\(current)問目" : "Question \(current) of \(total)"
  }
  var previous: String { locale == .ja ? "前へ" : "Previous" }
  var next: String { locale == .ja ? "次へ" : "Next" }
  var save: String { locale == .ja ? "回答を保存" : "Save answers" }
  var saving: String { locale == .ja ? "保存中…" : "Saving…" }
  var saved: String { locale == .ja ? "回答を保存しました" : "Answers saved" }
  var savedDetail: String {
    locale == .ja ? "ペルソナづくりに反映されます。" : "They will help shape your persona."
  }
  var selected: String { locale == .ja ? "選択済み" : "Selected" }
  var notSelected: String { locale == .ja ? "未選択" : "Not selected" }
  var retry: String { locale == .ja ? "再試行" : "Try again" }
  var loadErrorTitle: String { locale == .ja ? "クイズを読み込めませんでした" : "We couldn't load the quiz" }
  var loadErrorGeneric: String {
    locale == .ja ? "時間をおいて、もう一度お試しください。" : "Please wait a moment and try again."
  }
  var multipleHint: String { locale == .ja ? "複数選択できます。" : "Select all that apply." }
  var singleHint: String { locale == .ja ? "ひとつ選択してください。" : "Choose one answer." }
  var completeBeforeSave: String {
    locale == .ja ? "すべての質問に回答すると保存できます。" : "Answer every question before saving."
  }
  var reviewAnswers: String {
    locale == .ja ? "回答を確認して、もう一度お試しください。" : "Review your answers and try again."
  }
  var ageRequired: String {
    locale == .ja ? "保存する前に年齢確認を完了してください。" : "Verify your age before saving your answers."
  }
  var rateLimited: String {
    locale == .ja ? "少し待ってから、もう一度お試しください。" : "Please wait a moment, then try again."
  }
  var genericError: String {
    locale == .ja ? "回答を保存できませんでした。もう一度お試しください。" : "We couldn't save your answers. Try again."
  }
  var discardTitle: String { locale == .ja ? "回答を破棄しますか？" : "Discard your answers?" }
  var discardMessage: String {
    locale == .ja ? "保存していない回答はこの画面を閉じると失われます。" : "Unsaved answers will be lost when you leave."
  }
  var discardAction: String { locale == .ja ? "破棄する" : "Discard" }
  var keepEditing: String { locale == .ja ? "回答を続ける" : "Keep answering" }

  func errorMessage(for error: QuizStoreError) -> String {
    switch error {
    case .incompleteAnswers:
      return completeBeforeSave
    case .invalidSelection, .duplicateSelection:
      return reviewAnswers
    case .ageVerificationRequired:
      return ageRequired
    case .rateLimited:
      return rateLimited
    case .unauthenticated, .forbidden, .notFound, .ownerMismatch, .invalidResponse,
      .invalidState, .readbackMismatch, .temporarilyUnavailable, .cancelled:
      return genericError
    }
  }

  func loadErrorMessage(for error: QuizStoreError) -> String {
    switch error {
    case .rateLimited:
      return rateLimited
    case .cancelled:
      return loadErrorGeneric
    case .incompleteAnswers, .invalidSelection, .duplicateSelection, .ageVerificationRequired,
      .unauthenticated, .forbidden, .notFound, .ownerMismatch, .invalidResponse, .invalidState,
      .readbackMismatch, .temporarilyUnavailable:
      return loadErrorGeneric
    }
  }

  func category(_ value: String) -> String {
    switch value {
    case "lifestyle": return locale == .ja ? "ライフスタイル" : "LIFESTYLE"
    case "communication": return locale == .ja ? "コミュニケーション" : "COMMUNICATION"
    case "humor": return locale == .ja ? "ユーモア" : "HUMOR"
    case "expression": return locale == .ja ? "感情表現" : "EXPRESSION"
    case "values": return locale == .ja ? "価値観" : "VALUES"
    case "planning": return locale == .ja ? "行動スタイル" : "PLANNING"
    case "relationship": return locale == .ja ? "人間関係" : "RELATIONSHIPS"
    case "recovery": return locale == .ja ? "ストレス対処" : "RECOVERY"
    case "daily_rhythm": return locale == .ja ? "生活リズム" : "DAILY RHYTHM"
    case "lifestyle_zone": return locale == .ja ? "生活行動圏" : "LIFESTYLE AREA"
    default: return locale == .ja ? "質問" : "QUESTION"
    }
  }

  func question(_ question: QuizQuestion) -> String {
    guard locale == .ja else { return question.questionText }
    switch question.id {
    case "q1": return "自分にとっての「充実した休日」に一番近いのは？"
    case "q2": return "会話をしていて「居心地いいな」と感じるのはどんなとき？"
    case "q3": return "思わず笑ってしまうのはどんな瞬間？"
    case "q4": return "自分の気持ちを相手に伝えるとき、どちらに近い？"
    case "q5": return "お金を使うとしたら、どれが一番しっくりくる？"
    case "q6": return "予定の立て方として、自分に近いのは？"
    case "q7": return "友人・知人との関係で、自分に近いのは？"
    case "q8": return "疲れたとき、一番回復できるのは？"
    case "q9": return "自分の生活リズムはどちらに近い？"
    case "q10": return "よく行く・好きなエリアはどれ？"
    default: return question.questionText
    }
  }

  func options(_ question: QuizQuestion) -> [QuizOption] {
    guard locale == .ja else { return question.options }
    let labels: [String: [String: String]] = [
      "q1": [
        "a": "友達と外に出て、いろんな場所をはしごする",
        "b": "家でのんびり、好きなことだけをして過ごす",
        "c": "趣味や習い事に集中して、自分を磨く時間にする",
        "d": "特に計画せず、その日の気分で動く"
      ],
      "q2": [
        "a": "話がテンポよく弾んで、笑いが絶えないとき",
        "b": "ゆっくり深い話ができて、間があっても気にならないとき",
        "c": "共感し合えて、「わかる！」が続くとき",
        "d": "お互いの話が刺激になって、新しい発見があるとき"
      ],
      "q3": [
        "a": "日常のちょっとした「あるある」を面白く言ってもらったとき",
        "b": "話が突然予想外の方向に飛んだとき",
        "c": "シュールで意味不明なのに、なんかツボにはまったとき",
        "d": "ちょっと毒がある鋭いツッコミを聞いたとき"
      ],
      "q4": [
        "a": "感じたことをすぐ言葉にして伝える",
        "b": "じっくり考えてから、言葉を選んで伝える",
        "c": "言葉より行動や態度で示すほうが自然",
        "d": "雰囲気で伝わってほしいタイプ"
      ],
      "q5": [
        "a": "旅行や体験にお金をかけたい（思い出が残るから）",
        "b": "好きなものをじっくり集めたい（モノが好きだから）",
        "c": "なるべく貯めておきたい（安心感が大事だから）",
        "d": "コスパが良ければ何でもいい（合理的がベスト）"
      ],
      "q6": [
        "a": "先まで細かく決めてから動く（計画通りが好き）",
        "b": "大まかな方向だけ決めて、あとはその場で判断",
        "c": "直前に決めることが多い（ノリで動くのが好き）",
        "d": "計画は立てるけど、変更も全然 OK なフレキシブル派"
      ],
      "q7": [
        "a": "少人数の深い関係を大切にしている",
        "b": "広く浅くでも、色々な人とつながっていたい",
        "c": "一人の時間も同じくらい大切にしたい",
        "d": "状況によって使い分けている"
      ],
      "q8": [
        "a": "誰かと話して気分を発散する",
        "b": "一人の時間をとって静かに回復する",
        "c": "体を動かしてリフレッシュする",
        "d": "好きなことに没頭して気分を切り替える"
      ],
      "q9": [
        "a": "朝早く起きて、午前中に集中するタイプ（朝型）",
        "b": "夜の方が活動的で、遅くまで起きていることが多い（夜型）",
        "c": "特に決まっておらず、日によってバラバラ",
        "d": "できるだけ規則正しく、決まった時間に起きる・寝る"
      ],
      "q10": [
        "a": "都市中心部（ショッピング・グルメ・エンタメが充実している）",
        "b": "住宅街・下町（落ち着いた雰囲気が好き）",
        "c": "自然・郊外（公園・山・川沿いでリフレッシュ）",
        "d": "特にこだわりはなく、その日の気分で選ぶ"
      ]
    ]
    guard let localized = labels[question.id] else { return question.options }
    return question.options.map { QuizOption(value: $0.value, label: localized[$0.value] ?? $0.label) }
  }
}
