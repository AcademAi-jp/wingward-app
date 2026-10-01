import Combine
import Foundation

/// The two languages available across the bilingual product surface and its
/// offline redesign preview.
public enum BilingualReferenceLanguage: String, CaseIterable, Hashable, Identifiable, Sendable {
  case japanese = "ja"
  case english = "en"

  public var id: String { rawValue }
}

public enum BilingualReferenceLanguagePreference {
  public static let storageKey = "wingward.displayLanguage"

  public static func language(from rawValue: String) -> BilingualReferenceLanguage? {
    BilingualReferenceLanguage(rawValue: rawValue)
  }

  public static func rawValue(for language: BilingualReferenceLanguage) -> String {
    language.rawValue
  }
}

public struct BilingualReferenceText: Equatable, Hashable, Sendable {
  public let japanese: String
  public let english: String

  public init(japanese: String, english: String) {
    self.japanese = japanese
    self.english = english
  }

  public func value(for language: BilingualReferenceLanguage) -> String {
    switch language {
    case .japanese: return japanese
    case .english: return english
    }
  }
}

/// Every string owned by the bilingual surface lives in this catalog. Live
/// routes and the DEBUG preview share the catalog, while only live routes may
/// read account data.
public enum BilingualReferenceCopyKey: String, CaseIterable, Hashable, Identifiable, Sendable {
  case languageChoiceTitle
  case languageJapanese
  case languageEnglish
  case languageChoiceJapaneseSubtitle
  case languageChoiceEnglishSubtitle
  case onboardingKicker
  case onboardingTitle
  case onboardingBody
  case onboardingStepCheckIn
  case onboardingStepVoice
  case onboardingCTA
  case offlineBadge
  case checkInKicker
  case checkInTitle
  case checkInBody
  case checkInQuestion
  case checkInPause
  case checkInContinue
  case checkInPausedTitle
  case checkInPausedBody
  case checkInResume
  case voiceKicker
  case voiceTitle
  case voiceBody
  case voiceConnectionReady
  case voiceConnectionListening
  case voiceStart
  case voiceListening
  case voiceFinish
  case voiceOfflineNote
  case tabWords
  case tabYou
  case wordsKicker
  case wordsTitle
  case wordsBody
  case wordsCandidatesLabel
  case wordsSelectedLabel
  case wordsWardTranscript
  case wordsPartnerWard
  case wordsTranscriptSubtitle
  case wordsInterestAction
  case wordsInterestPending
  case wordsInterestPendingBody
  case wordsInterestPreviewMutual
  case wordsInterestMutual
  case wordsInterestBody
  case wordsVenueAction
  case wordsVenueTitle
  case wordsVenueReady
  case wordsVenueCoordination
  case wordsVenueSuggested
  case wordsVenueBody
  case wordsComposerTitle
  case wordsComposerMyWard
  case wordsComposerMe
  case wordsComposerMeLocked
  case wordsComposerLockedBody
  case wordsComposerPlaceholder
  case wordsComposerSend
  case wordsComposerLocalNote
  case productionLiveBadge
  case productionWordsBody
  case productionLoading
  case productionRetry
  case productionRefresh
  case recordingRehearsalNotice
  case recordingRehearsalPreviewOnly
  case recordingRehearsalPreviewEligible
  case recordingRehearsalPreviewNotEligible
  case recordingRehearsalPreviewAlreadyExists
  case recordingRehearsalPreviewExpired
  case recordingRehearsalPreviewFailed
  case recordingRehearsalStart
  case recordingRehearsalChecking
  case recordingRehearsalStarting
  case recordingRehearsalLoading
  case recordingRehearsalStarted
  case recordingRehearsalPartial
  case recordingRehearsalExisting
  case recordingRehearsalNotEligible
  case recordingRehearsalExpired
  case recordingRehearsalFailed
  case recordingRehearsalCancelled
  case recordingRehearsalResultsUnavailable
  case recordingRehearsalPartialResultsUnavailable
  case recordingRehearsalDebugNotice
  case recordingRehearsalDebugChecking
  case recordingRehearsalDebugStarting
  case recordingRehearsalDebugLoading
  case recordingRehearsalDebugResult
  case recordingRehearsalDebugError
  case productionSignOut
  case productionMatchesEmptyTitle
  case productionMatchesEmptyBody
  case productionMatchesLoadError
  case productionMatchRank
  case productionMatchOpenDetails
  case productionMatchStatusPending
  case productionMatchStatusInProgress
  case productionMatchStatusCompleted
  case productionMatchStatusFailed
  case productionMatchStatusUnknown
  case productionMatchDetailTitle
  case productionMatchDetailBody
  case productionMatchDetailLoading
  case productionMatchDetailError
  case productionStartWard
  case productionWardHistory
  case productionWardHistoryEmpty
  case productionHistoryLimit
  case productionRound
  case productionStartPartnerWard
  case productionPartnerWard
  case productionPartnerWardBody
  case productionChatLabel
  case productionPartnerAnalysisTitle
  case productionPartnerAnalysisEmpty
  case productionPartnerAnalysisEmptyBody
  case productionRequestDirectChat
  case productionDirectChat
  case productionConversationModeWard
  case productionConversationModeYou
  case productionAIComposerPlaceholder
  case productionDirectChatComposerLocked
  case productionDirectChatRequestBody
  case productionDirectChatPendingTitle
  case productionDirectChatPendingBody
  case productionDirectChatAccepted
  case productionDirectChatDeclined
  case productionDirectChatExpired
  case productionDirectChatCreateFailed
  case productionDirectChatIncomingTitle
  case productionDirectChatIncomingBody
  case productionDirectChatAccept
  case productionDirectChatDecline
  case productionDirectChatComposerPlaceholder
  case productionDirectChatSend
  case productionDirectChatUnavailable
  case productionDirectChatError
  case productionMemberFallback
  case productionPlanMeetup
  case productionReportBlock
  case productionNoConversation
  case productionFeatureUnavailable
  case productionIdentityVerificationUnavailable
  case productionClose
  case productionDetailPlaceholder
  case authStoryKicker
  case authStoryTitle
  case authStoryBody
  case authWelcomeTitle
  case authWelcomeBody
  case authSignIn
  case authCreateAccount
  case authProtected
  case authSignUpTitle
  case authSignUpSubtitle
  case authEmail
  case authPassword
  case authConfirmPassword
  case authBirthDate
  case authCreatingAccount
  case authSignInTitle
  case authSignInSubtitle
  case authSigningIn
  case authForgotPassword
  case authResetTitle
  case authResetSubtitle
  case authSending
  case authSendResetLink
  case authBackToSignIn
  case authCheckEmailTitle
  case authResetRequestedBody
  case authRecoveryTitle
  case authRecoverySubtitle
  case authNewPassword
  case authConfirmNewPassword
  case authUpdating
  case authUpdatePassword
  case authConfirmationBody
  case authAgeTitle
  case authAgeSubtitle
  case authVerifying
  case authVerifyAge
  case authLoadingTitle
  case authLoadingBody
  case authConfigurationTitle
  case authConfigurationBody
  case authRecoverableTitle
  case authRecoverableBody
  case authTryAgain
  case authErrorEmailRequired
  case authErrorEmailInvalid
  case authErrorPasswordRequired
  case authErrorPasswordTooShort
  case authErrorPasswordConfirmationRequired
  case authErrorPasswordsDoNotMatch
  case authErrorBirthDateInvalid
  case authErrorUnder18
  case authGenericError
  case productionOnboardingKicker
  case productionOnboardingTitle
  case productionOnboardingBody
  case productionOnboardingLoading
  case productionOnboardingError
  case productionOnboardingOptionsLoading
  case productionOnboardingOptionsUnavailable
  case productionOnboardingRetry
  case productionOnboardingSave
  case productionOnboardingSaved
  case productionOnboardingNotSaved
  case productionOnboardingDisplayLanguage
  case productionOnboardingConversationLanguage
  case productionOnboardingMarket
  case productionOnboardingTimezone
  case productionOnboardingDistance
  case productionOnboardingIdentity
  case productionOnboardingPreferences
  case productionOnboardingLocation
  case productionOnboardingStation
  case productionOnboardingArea
  case productionMarketJapan
  case productionMarketUS
  case productionDistanceKilometers
  case productionDistanceMiles
  case productionIdentityWoman
  case productionIdentityMan
  case productionIdentityNonbinary
  case productionIdentityNoAnswer
  case productionPreferenceSelected
  case productionPreferenceNoAnswer
  case productionLocationStation
  case productionLocationNoTransit
  case productionLocationNotSet
  case productionQuizTitle
  case productionQuizBody
  case productionQuizOpen
  case productionVoiceTitle
  case productionVoiceBody
  case productionVoiceOpen
  case productionWatercolorTitle
  case productionWatercolorBody
  case productionWatercolorOpen
  case productionProfileTitle
  case productionProfileBody
  case productionAnalysisLoading
  case productionAnalysisEmpty
  case productionAnalysisEmptyBody
  case productionAnalysisError
  case productionSavedTags
  case productionNoSavedTags
  case productionReadAnalysis
  case productionNotificationsBody
  case productionLanguageSaved
  case youKicker
  case youTitle
  case youBody
  case youAnalysisTitle
  case youAnalysisBody
  case youAnalysisAction
  case youPortraitLabel
  case youTraitsLabel
  case youSettingsLabel
  case youPreferencesGroup
  case youAccountGroup
  case youWardSetup
  case youLanguageRegion
  case youMatchPreferences
  case youPlanPayments
  case youNotifications
  case youPrivacySafety
  case youHelp
  case detailPlaceholder
  case detailBack
  case timerAccessibilityLabel
  case dismissAccessibilityLabel
  case analysisDetailKicker
  case analysisDetailTitle
  case analysisDetailBody
  case analysisDetailSummaryLabel
  case analysisDetailSummary
  case analysisDetailStrengthsLabel
  case analysisDetailStrengthOne
  case analysisDetailStrengthTwo
  case analysisDetailStrengthThree
  case analysisDetailPracticeLabel
  case analysisDetailPractice
  case analysisDetailFootnote
  case localOnlyNote

  public var id: String { rawValue }
}

public enum BilingualReferenceCatalog {
  public static let entries: [BilingualReferenceCopyKey: BilingualReferenceText] = [
    .languageChoiceTitle: .init(japanese: "表示言語を選択してください", english: "Choose your display language"),
    .languageJapanese: .init(japanese: "日本語", english: "Japanese"),
    .languageEnglish: .init(japanese: "英語", english: "English"),
    .languageChoiceJapaneseSubtitle: .init(japanese: "日本語で表示", english: "Display in Japanese"),
    .languageChoiceEnglishSubtitle: .init(japanese: "英語で表示", english: "Display in English"),
    .onboardingKicker: .init(japanese: "はじめに", english: "FIRST STEP"),
    .onboardingTitle: .init(japanese: "あなたらしい出会いを、\n会話から。", english: "Start with a conversation\nthat sounds like you."),
    .onboardingBody: .init(
      japanese: "短いチェックインで会話の特徴を見つけ、そのあと音声で会話します。ここで見えるのは通信を使わない合成データです。",
      english: "Find your conversation traits in a quick check-in, then have a voice conversation. This preview uses synthetic data and stays offline."
    ),
    .onboardingStepCheckIn: .init(japanese: "クイックチェックイン", english: "Quick check-in"),
    .onboardingStepVoice: .init(japanese: "音声で会話", english: "Voice conversation"),
    .onboardingCTA: .init(japanese: "チェックインをはじめる", english: "Start quick check-in"),
    .offlineBadge: .init(japanese: "オフラインデモ", english: "OFFLINE DEMO"),
    .checkInKicker: .init(japanese: "クイックチェックイン", english: "QUICK CHECK-IN"),
    .checkInTitle: .init(japanese: "今の気分に近いものを\n選んでください。", english: "Choose what feels\nclosest right now."),
    .checkInBody: .init(japanese: "答えると次の質問へ自動で進みます。途中で一時停止できます。", english: "Your answer advances automatically. You can pause and continue anytime."),
    .checkInQuestion: .init(japanese: "質問", english: "Question"),
    .checkInPause: .init(japanese: "一時停止", english: "Pause"),
    .checkInContinue: .init(japanese: "続ける", english: "Continue"),
    .checkInPausedTitle: .init(japanese: "ここで一休み", english: "Take a pause"),
    .checkInPausedBody: .init(japanese: "回答はこの画面に保持されています。準備ができたら続けましょう。", english: "Your answers stay on this screen. Continue when you are ready."),
    .checkInResume: .init(japanese: "チェックインを再開", english: "Resume check-in"),
    .voiceKicker: .init(japanese: "音声で会話", english: "VOICE CONVERSATION"),
    .voiceTitle: .init(japanese: "あなたのペースで\n話してみましょう。", english: "Speak at\nyour own pace."),
    .voiceBody: .init(japanese: "接続・聞き取り・時間表示は、すべてオフラインの合成状態です。マイクは起動しません。", english: "Connection, listening, and timing are offline fixture states. Your microphone is never started."),
    .voiceConnectionReady: .init(japanese: "接続済み（合成状態）", english: "Connected (fixture)"),
    .voiceConnectionListening: .init(japanese: "聞き取り中（合成状態）", english: "Listening (fixture)"),
    .voiceStart: .init(japanese: "会話を開始", english: "Start conversation"),
    .voiceListening: .init(japanese: "あなたの声を待っています", english: "Waiting for your voice"),
    .voiceFinish: .init(japanese: "会話を終了してWardへ", english: "Finish and open Ward"),
    .voiceOfflineNote: .init(japanese: "この画面は通信・マイクを使わないデモです。", english: "This screen is an offline demo with no network or microphone."),
    .tabWords: .init(japanese: "Ward", english: "Ward"),
    .tabYou: .init(japanese: "You", english: "You"),
    .wordsKicker: .init(japanese: "候補を見つける", english: "FIND A CONNECTION"),
    .wordsTitle: .init(japanese: "会う前に、\n言葉を交わす。", english: "Meet through Wards\nbefore meeting in person."),
    .wordsBody: .init(japanese: "あなたのWardと相手のWardが先に会話します。表示はすべて合成データです。", english: "Your Ward speaks with each candidate's Ward first. All content here is synthetic."),
    .wordsCandidatesLabel: .init(japanese: "今日の候補", english: "TODAY'S CANDIDATES"),
    .wordsSelectedLabel: .init(japanese: "選択中", english: "SELECTED"),
    .wordsWardTranscript: .init(japanese: "Ward同士の会話", english: "WARD-TO-WARD TRANSCRIPT"),
    .wordsPartnerWard: .init(japanese: "相手のWard", english: "Their Ward"),
    .wordsTranscriptSubtitle: .init(japanese: "あなたのWardと相手のWardが交わした言葉", english: "A conversation between your Ward and their Ward"),
    .wordsInterestAction: .init(japanese: "気になると伝える", english: "Show interest"),
    .wordsInterestPending: .init(japanese: "気になる気持ちを保存しました", english: "Your interest is saved"),
    .wordsInterestPendingBody: .init(
      japanese: "相手が同じ気持ちを選ぶまで、{name}には伝わりません。",
      english: "{name} will not be told unless they choose the same."
    ),
    .wordsInterestPreviewMutual: .init(japanese: "相互状態をプレビュー", english: "Preview mutual state"),
    .wordsInterestMutual: .init(japanese: "お互いに気になっています", english: "You both seem interested"),
    .wordsInterestBody: .init(japanese: "合成の承認状態です。次は会う場所の候補を見てみましょう。", english: "This is a fixture approval state. Next, explore a place to meet."),
    .wordsVenueAction: .init(japanese: "会う場所を調整", english: "Coordinate a venue"),
    .wordsVenueTitle: .init(japanese: "会う場所の調整", english: "Venue coordination"),
    .wordsVenueReady: .init(japanese: "候補を見られます", english: "Ready to explore"),
    .wordsVenueCoordination: .init(japanese: "希望をすり合わせています", english: "Aligning your preferences"),
    .wordsVenueSuggested: .init(japanese: "候補を3つ用意しました", english: "Three options are ready"),
    .wordsVenueBody: .init(japanese: "実在の予約や確定を示すものではありません。", english: "This does not represent a real booking or confirmation."),
    .wordsComposerTitle: .init(japanese: "送る相手", english: "SEND AS"),
    .wordsComposerMyWard: .init(japanese: "My Ward", english: "My Ward"),
    .wordsComposerMe: .init(japanese: "自分", english: "Me"),
    .wordsComposerMeLocked: .init(japanese: "自分（承認後に利用可能）", english: "Me (available after approval)"),
    .wordsComposerLockedBody: .init(japanese: "相手の承認後に、自分の言葉で送れるようになります。今はMy Wardを使います。", english: "You can send in your own words after approval. My Ward is available for now."),
    .wordsComposerPlaceholder: .init(japanese: "Wardへのメモを書く…", english: "Write a note for your Ward…"),
    .wordsComposerSend: .init(japanese: "追加", english: "Add"),
    .wordsComposerLocalNote: .init(japanese: "このメモはこのデモ画面だけに残ります。", english: "This note stays inside this offline demo."),
    .productionLiveBadge: .init(japanese: "アカウントデータ", english: "ACCOUNT DATA"),
    .productionWordsBody: .init(japanese: "今日の候補を確認し、Ward同士の会話から次のステップへ進みます。", english: "Review today's candidates and move forward from the conversation between your Wards."),
    .productionLoading: .init(japanese: "読み込み中…", english: "Loading…"),
    .productionRetry: .init(japanese: "もう一度試す", english: "Try again"),
    .productionRefresh: .init(japanese: "更新", english: "Refresh"),
    .recordingRehearsalNotice: .init(
      japanese: "テストアカウントのリハーサルです。サーバーが選んだテストアカウントだけでマッチングします。",
      english: "Test-account rehearsal. Matching uses only the test accounts selected by the server."
    ),
    .recordingRehearsalPreviewOnly: .init(japanese: "対象可否だけ確認", english: "Check eligibility only"),
    .recordingRehearsalPreviewEligible: .init(
      japanese: "対象です（1組）。マッチングは開始していません。",
      english: "Eligible (1 pair). Matching has not started."
    ),
    .recordingRehearsalPreviewNotEligible: .init(
      japanese: "現在は対象外です。マッチングは開始していません。",
      english: "Not eligible yet. Matching has not started."
    ),
    .recordingRehearsalPreviewAlreadyExists: .init(
      japanese: "既存のマッチがあります。新しいマッチングは開始していません。",
      english: "A match already exists. No new matching run was started."
    ),
    .recordingRehearsalPreviewExpired: .init(
      japanese: "確認できる期間が終了しました。マッチングは開始していません。",
      english: "The preview window has expired. Matching has not started."
    ),
    .recordingRehearsalPreviewFailed: .init(
      japanese: "対象可否を確認できませんでした。マッチングは開始していません。",
      english: "Eligibility could not be checked. Matching has not started."
    ),
    .recordingRehearsalStart: .init(japanese: "テストマッチングを開始", english: "Start test matching"),
    .recordingRehearsalChecking: .init(
      japanese: "テストアカウントの対象可否を確認しています…",
      english: "Checking whether the test accounts are eligible…"
    ),
    .recordingRehearsalStarting: .init(japanese: "テストマッチングを開始しています…", english: "Starting test matching…"),
    .recordingRehearsalLoading: .init(japanese: "サーバーのマッチング結果を読み込んでいます…", english: "Loading the server's matching results…"),
    .recordingRehearsalStarted: .init(
      japanese: "テストマッチングを開始しました。候補はサーバーから読み込みました。",
      english: "Test matching started. These matches were loaded from the server."
    ),
    .recordingRehearsalPartial: .init(
      japanese: "テストマッチングは一部のみ開始されました。候補はサーバーから読み込みました。",
      english: "Test matching started partially. These matches were loaded from the server."
    ),
    .recordingRehearsalExisting: .init(
      japanese: "既存のテストマッチが見つかりました。新しいマッチングは開始していません。",
      english: "An existing test match was found. No new matching run was started."
    ),
    .recordingRehearsalNotEligible: .init(
      japanese: "このアカウントはテストマッチングの対象ではありません。",
      english: "This account isn't eligible for test matching."
    ),
    .recordingRehearsalExpired: .init(
      japanese: "テストマッチングの実行期間が終了しました。",
      english: "The test-matching window has expired."
    ),
    .recordingRehearsalFailed: .init(
      japanese: "開始状態を確認できませんでした。再試行する前に候補を更新して確認してください。",
      english: "The request didn't return a confirmed status. Refresh to check current results before trying again."
    ),
    .recordingRehearsalCancelled: .init(
      japanese: "リクエストが中断され、マッチングが開始された可能性があります。再試行する前に候補を更新して確認してください。",
      english: "The request was interrupted and matching may have started. Refresh to check results before trying again."
    ),
    .recordingRehearsalResultsUnavailable: .init(
      japanese: "マッチングの状態は更新されましたが、候補を読み込めませんでした。更新して確認してください。",
      english: "The matching state changed, but results couldn't be loaded. Refresh to check."
    ),
    .recordingRehearsalPartialResultsUnavailable: .init(
      japanese: "テストマッチングは一部のみ開始されましたが、候補を読み込めませんでした。更新して確認してください。",
      english: "Test matching started partially, but results couldn't be loaded. Refresh to check."
    ),
    .recordingRehearsalDebugNotice: .init(
      japanese: "DEBUG UI fixture — no matching request was sent to the service",
      english: "DEBUG UI fixture — no matching request was sent to the service"
    ),
    .recordingRehearsalDebugChecking: .init(
      japanese: "ローカルUIフィクスチャを確認しています…",
      english: "Checking the local UI fixture…"
    ),
    .recordingRehearsalDebugStarting: .init(
      japanese: "ローカルUIフィクスチャを開始しています…",
      english: "Starting the local UI fixture…"
    ),
    .recordingRehearsalDebugLoading: .init(
      japanese: "合成したフィクスチャ結果を読み込んでいます…",
      english: "Loading the synthetic fixture result…"
    ),
    .recordingRehearsalDebugResult: .init(
      japanese: "合成フィクスチャの候補を表示しています。実際のマッチングは実行していません。",
      english: "Synthetic fixture result shown; no live matching ran."
    ),
    .recordingRehearsalDebugError: .init(
      japanese: "ローカルUIフィクスチャを表示できませんでした。実際のマッチングは実行していません。",
      english: "The local UI fixture couldn't show a result; no live matching ran."
    ),
    .productionSignOut: .init(japanese: "サインアウト", english: "Sign out"),
    .productionMatchesEmptyTitle: .init(japanese: "今日は候補がありません", english: "No matches yet"),
    .productionMatchesEmptyBody: .init(
      japanese: "マッチング希望が「回答しない」の場合、候補は表示されません。",
      english: "Candidates are hidden when matching preferences are set to \"No answer.\""
    ),
    .productionMatchesLoadError: .init(
      japanese: "候補の一覧を読み込めませんでした。",
      english: "We couldn't load today's candidates."
    ),
    .productionMatchRank: .init(japanese: "候補 %d", english: "MATCH %d"),
    .productionMatchOpenDetails: .init(japanese: "詳細を見る", english: "View details"),
    .productionMatchStatusPending: .init(japanese: "Wardの会話を始められます", english: "Ready to start a Ward conversation"),
    .productionMatchStatusInProgress: .init(japanese: "Wardが会話しています", english: "Your Wards are in conversation"),
    .productionMatchStatusCompleted: .init(japanese: "Wardの会話が完了しました", english: "The Ward conversation is complete"),
    .productionMatchStatusFailed: .init(japanese: "Wardの会話を完了できませんでした", english: "The Ward conversation could not be completed"),
    .productionMatchStatusUnknown: .init(japanese: "候補の状態を確認しています", english: "Checking this match's status"),
    .productionMatchDetailTitle: .init(japanese: "候補の詳細", english: "Match details"),
    .productionMatchDetailBody: .init(japanese: "まずWard同士が会話します。次のステップは、サーバーで確認された状態だけが表示されます。", english: "Your Wards speak first. The next step appears only when the server confirms it."),
    .productionMatchDetailLoading: .init(japanese: "候補の詳細を読み込んでいます。", english: "Loading this match's details."),
    .productionMatchDetailError: .init(japanese: "候補の詳細を読み込めませんでした。", english: "We couldn't load this match."),
    .productionStartWard: .init(japanese: "Wardの会話を始める", english: "Start Ward conversation"),
    .productionWardHistory: .init(japanese: "Wardの会話履歴", english: "Ward conversation history"),
    .productionWardHistoryEmpty: .init(japanese: "会話はまだありません。", english: "No conversation messages yet."),
    .productionHistoryLimit: .init(japanese: "最初の最大100件を表示しています。", english: "Showing the first 100 messages at most."),
    .productionRound: .init(japanese: "ラウンド %d / %d", english: "Round %d of %d"),
    .productionStartPartnerWard: .init(japanese: "相手のWardを始める", english: "Start Partner Ward"),
    .productionPartnerWard: .init(japanese: "相手のWard", english: "Partner Ward"),
    .productionPartnerWardBody: .init(japanese: "相手のWardとの会話を確認できます。", english: "Review the conversation with their Ward."),
    .productionChatLabel: .init(japanese: "Chat", english: "Chat"),
    .productionPartnerAnalysisTitle: .init(japanese: "相手の分析", english: "Partner analysis"),
    .productionPartnerAnalysisEmpty: .init(japanese: "相手の分析はまだありません。", english: "No partner analysis is available yet."),
    .productionPartnerAnalysisEmptyBody: .init(
      japanese: "公開された分析結果がないため、マッチの状態だけを表示しています。",
      english: "Only the match status is shown because no public analysis result is available."
    ),
    .productionRequestDirectChat: .init(japanese: "直接チャットをリクエスト", english: "Request direct chat"),
    .productionDirectChat: .init(japanese: "直接チャット", english: "Direct chat"),
    .productionConversationModeWard: .init(japanese: "AI", english: "AI"),
    .productionConversationModeYou: .init(japanese: "人", english: "You"),
    .productionAIComposerPlaceholder: .init(
      japanese: "AIに話してもらう内容を書く…",
      english: "Write what you'd like the AI to say…"
    ),
    .productionDirectChatComposerLocked: .init(
      japanese: "承認後に人として送信できます。下の申請状況を確認してください。",
      english: "Human messages are available after approval. See the request status above."
    ),
    .productionDirectChatRequestBody: .init(
      japanese: "承認されると、この画面で本人同士の会話を始められます。",
      english: "When the request is accepted, you can start a conversation here."
    ),
    .productionDirectChatPendingTitle: .init(japanese: "承認を待っています", english: "Waiting for approval"),
    .productionDirectChatPendingBody: .init(
      japanese: "リクエストは送信済みです。相手が承認するまで、直接の会話は始まりません。",
      english: "Your request is sent. A direct conversation starts only after they approve."
    ),
    .productionDirectChatAccepted: .init(
      japanese: "相手が申請を承認しました。チャットの状態を更新してください。",
      english: "Your match accepted the request. Refresh to load the direct conversation."
    ),
    .productionDirectChatDeclined: .init(
      japanese: "申請は辞退されました。このマッチでは再申請できません。",
      english: "The request was declined. You cannot send another request for this match."
    ),
    .productionDirectChatExpired: .init(
      japanese: "申請の有効期限が切れました。このマッチでは再申請できません。",
      english: "The request expired. You cannot send another request for this match."
    ),
    .productionDirectChatCreateFailed: .init(
      japanese: "状態を更新しましたが、このマッチの申請は見つかりません。必要なら、もう一度申請できます。",
      english: "Status was refreshed, but no request is recorded for this match. You can try again if you still want to."
    ),
    .productionDirectChatIncomingTitle: .init(japanese: "直接チャットのリクエスト", english: "Direct chat request"),
    .productionDirectChatIncomingBody: .init(
      japanese: "相手が本人同士の会話を希望しています。承認すると、この画面で話せます。",
      english: "They would like to talk directly. Accept to continue in this conversation."
    ),
    .productionDirectChatAccept: .init(japanese: "承認する", english: "Accept"),
    .productionDirectChatDecline: .init(japanese: "辞退する", english: "Decline"),
    .productionDirectChatComposerPlaceholder: .init(japanese: "メッセージを書く…", english: "Write a message…"),
    .productionDirectChatSend: .init(japanese: "送信", english: "Send"),
    .productionDirectChatUnavailable: .init(
      japanese: "このアカウントでは直接チャットを確認できません。",
      english: "Direct chat access is unavailable for this account."
    ),
    .productionDirectChatError: .init(
      japanese: "直接チャットの状態を確認できませんでした。もう一度試してください。",
      english: "We couldn't confirm direct chat access. Try again."
    ),
    .productionMemberFallback: .init(japanese: "相手", english: "Your match"),
    .productionPlanMeetup: .init(japanese: "会う予定を調整", english: "Plan a meetup"),
    .productionReportBlock: .init(japanese: "通報またはブロック", english: "Report or block"),
    .productionNoConversation: .init(japanese: "会話の準備ができるとここに表示されます。", english: "The conversation will appear here when it is ready."),
    .productionFeatureUnavailable: .init(japanese: "この機能は現在利用できません。", english: "This feature is not available right now."),
    .productionIdentityVerificationUnavailable: .init(
      japanese: "本人確認の接続先がまだ設定されていないため、ここでは開始できません。本人確認済みとして扱われることはありません。",
      english: "Identity verification has no connected provider yet, so it cannot start here. This does not mark your account as verified."
    ),
    .productionClose: .init(japanese: "閉じる", english: "Close"),
    .productionDetailPlaceholder: .init(japanese: "この項目はアカウントに合わせて表示されます。", english: "This setting is shown for your account."),
    .authStoryKicker: .init(japanese: "あなたのWard、あなたのペース", english: "YOUR WARD, YOUR PACE"),
    .authStoryTitle: .init(japanese: "意図をもって、\n自分のペースで出会う。", english: "Meet people with intention.\nAt your own pace."),
    .authStoryBody: .init(japanese: "まずWardがあなたを知り、思いやりのある出会いをサポートします。", english: "Your Ward gets to know you first, then helps you meet with more care."),
    .authWelcomeTitle: .init(japanese: "おかえりなさい", english: "Welcome back"),
    .authWelcomeBody: .init(japanese: "続けるにはサインインするか、新しいアカウントを作成してください。", english: "Sign in to continue, or create a new account to get started."),
    .authSignIn: .init(japanese: "サインイン", english: "Sign in"),
    .authCreateAccount: .init(japanese: "アカウントを作成", english: "Create an account"),
    .authProtected: .init(japanese: "アカウントは保護されています", english: "Your account stays protected"),
    .authSignUpTitle: .init(japanese: "アカウントを作成", english: "Create your account"),
    .authSignUpSubtitle: .init(japanese: "生年月日は年齢確認のみに使用します。", english: "Your date of birth is used only for age verification."),
    .authEmail: .init(japanese: "メールアドレス", english: "Email"),
    .authPassword: .init(japanese: "パスワード", english: "Password"),
    .authConfirmPassword: .init(japanese: "パスワードを確認", english: "Confirm password"),
    .authBirthDate: .init(japanese: "生年月日", english: "Date of birth"),
    .authCreatingAccount: .init(japanese: "アカウントを作成中…", english: "Creating account…"),
    .authSignInTitle: .init(japanese: "おかえりなさい", english: "Welcome back"),
    .authSignInSubtitle: .init(japanese: "続けるにはサインインしてください。", english: "Sign in to continue."),
    .authSigningIn: .init(japanese: "サインイン中…", english: "Signing in…"),
    .authForgotPassword: .init(japanese: "パスワードを忘れた場合", english: "Forgot password?"),
    .authResetTitle: .init(japanese: "パスワードをリセット", english: "Reset your password"),
    .authResetSubtitle: .init(japanese: "メールアドレスを入力すると、登録されている場合に手順を送ります。", english: "Enter your email and we'll send instructions if an account is registered."),
    .authSending: .init(japanese: "送信中…", english: "Sending…"),
    .authSendResetLink: .init(japanese: "リセットリンクを送る", english: "Send reset link"),
    .authBackToSignIn: .init(japanese: "サインインに戻る", english: "Back to sign in"),
    .authCheckEmailTitle: .init(japanese: "メールを確認してください", english: "Check your email"),
    .authResetRequestedBody: .init(japanese: "このアドレスを使うアカウントがある場合、パスワードリセットのリンクを送ります。受信トレイと迷惑メールを確認してください。", english: "If an account uses that address, we'll send a password reset link. Check your inbox and spam folder."),
    .authRecoveryTitle: .init(japanese: "新しいパスワードを設定", english: "Choose a new password"),
    .authRecoverySubtitle: .init(japanese: "8文字以上で入力し、新しいパスワードを確認してください。", english: "Use at least 8 characters, then confirm your new password."),
    .authNewPassword: .init(japanese: "新しいパスワード", english: "New password"),
    .authConfirmNewPassword: .init(japanese: "新しいパスワードを確認", english: "Confirm new password"),
    .authUpdating: .init(japanese: "更新中…", english: "Updating…"),
    .authUpdatePassword: .init(japanese: "パスワードを更新", english: "Update password"),
    .authConfirmationBody: .init(japanese: "確認リンクを{email}に送りました。確認後、Wingwardに戻ってください。", english: "We sent a confirmation link to {email}. Confirm it, then return to Wingward."),
    .authAgeTitle: .init(japanese: "年齢を確認", english: "Verify your age"),
    .authAgeSubtitle: .init(japanese: "続けるには18歳以上である必要があります。", english: "You must be at least 18 to continue."),
    .authVerifying: .init(japanese: "確認中…", english: "Verifying…"),
    .authVerifyAge: .init(japanese: "年齢を確認", english: "Verify age"),
    .authLoadingTitle: .init(japanese: "読み込み中…", english: "Loading…"),
    .authLoadingBody: .init(japanese: "安全なセッションを準備しています。", english: "Preparing a secure session."),
    .authConfigurationTitle: .init(japanese: "接続設定を確認できません", english: "Connection setup unavailable"),
    .authConfigurationBody: .init(japanese: "このアプリに必要な接続設定が不足しているか、正しくありません。開発者に接続設定済みのビルドを依頼してください。iPadの設定変更は不要です。", english: "This app’s connection configuration is missing or invalid. Ask the developer for a configured build. You do not need to change your device settings."),
    .authRecoverableTitle: .init(japanese: "問題が発生しました", english: "Something went wrong"),
    .authRecoverableBody: .init(japanese: "リクエストを完了できませんでした。もう一度お試しください。", english: "We couldn't complete that request. Try again."),
    .authTryAgain: .init(japanese: "もう一度試す", english: "Try again"),
    .authErrorEmailRequired: .init(japanese: "メールアドレスを入力してください。", english: "Enter your email address."),
    .authErrorEmailInvalid: .init(japanese: "有効なメールアドレスを入力してください。", english: "Enter a valid email address."),
    .authErrorPasswordRequired: .init(japanese: "パスワードを入力してください。", english: "Enter a password."),
    .authErrorPasswordTooShort: .init(japanese: "パスワードは8文字以上にしてください。", english: "Use at least 8 characters for your password."),
    .authErrorPasswordConfirmationRequired: .init(japanese: "パスワードを確認してください。", english: "Confirm your password."),
    .authErrorPasswordsDoNotMatch: .init(japanese: "パスワードが一致しません。", english: "The passwords do not match."),
    .authErrorBirthDateInvalid: .init(japanese: "有効な生年月日を入力してください。", english: "Enter a valid birth date."),
    .authErrorUnder18: .init(japanese: "Wingwardを利用するには18歳以上である必要があります。", english: "You must be at least 18 to use Wingward."),
    .authGenericError: .init(japanese: "リクエストを完了できませんでした。もう一度お試しください。", english: "We couldn't complete that request. Try again."),
    .productionOnboardingKicker: .init(japanese: "あなたの設定", english: "YOUR SETTINGS"),
    .productionOnboardingTitle: .init(japanese: "あなたのペースで、\n会話を準備する。", english: "Prepare for a conversation\nat your own pace."),
    .productionOnboardingBody: .init(japanese: "表示言語や出会いの希望を保存すると、Wardとの会話を始められます。", english: "Save your language and connection preferences to start your Ward conversations."),
    .productionOnboardingLoading: .init(japanese: "保存した設定を確認しています。", english: "Checking your saved settings."),
    .productionOnboardingError: .init(japanese: "設定を読み込めませんでした。", english: "We couldn't load your settings."),
    .productionOnboardingOptionsLoading: .init(japanese: "地域の選択肢を読み込んでいます。", english: "Loading location options."),
    .productionOnboardingOptionsUnavailable: .init(japanese: "地域の選択肢を取得できませんでした。", english: "Location options are unavailable."),
    .productionOnboardingRetry: .init(japanese: "設定を再読み込み", english: "Reload settings"),
    .productionOnboardingSave: .init(japanese: "設定を保存", english: "Save settings"),
    .productionOnboardingSaved: .init(japanese: "アカウントに保存しました。", english: "Saved to your account."),
    .productionOnboardingNotSaved: .init(japanese: "まだ保存されていません。", english: "Not saved yet."),
    .productionOnboardingDisplayLanguage: .init(japanese: "表示言語", english: "Display language"),
    .productionOnboardingConversationLanguage: .init(japanese: "会話の言語", english: "Conversation language"),
    .productionOnboardingMarket: .init(japanese: "出会う地域", english: "Connection market"),
    .productionOnboardingTimezone: .init(japanese: "タイムゾーン", english: "Time zone"),
    .productionOnboardingDistance: .init(japanese: "距離の単位", english: "Distance unit"),
    .productionOnboardingIdentity: .init(japanese: "あなたについて", english: "About you"),
    .productionOnboardingPreferences: .init(japanese: "出会いの希望", english: "Connection preferences"),
    .productionOnboardingLocation: .init(japanese: "会いやすい場所", english: "A comfortable area"),
    .productionOnboardingStation: .init(japanese: "最寄りの駅", english: "Nearest station"),
    .productionOnboardingArea: .init(japanese: "エリア", english: "Area"),
    .productionMarketJapan: .init(japanese: "日本", english: "Japan"),
    .productionMarketUS: .init(japanese: "アメリカ合衆国", english: "United States"),
    .productionDistanceKilometers: .init(japanese: "キロメートル", english: "Kilometers"),
    .productionDistanceMiles: .init(japanese: "マイル", english: "Miles"),
    .productionIdentityWoman: .init(japanese: "女性", english: "Woman"),
    .productionIdentityMan: .init(japanese: "男性", english: "Man"),
    .productionIdentityNonbinary: .init(japanese: "ノンバイナリー", english: "Nonbinary"),
    .productionIdentityNoAnswer: .init(japanese: "答えたくない", english: "Prefer not to say"),
    .productionPreferenceSelected: .init(japanese: "選択する", english: "Choose"),
    .productionPreferenceNoAnswer: .init(japanese: "指定しない", english: "No preference"),
    .productionLocationStation: .init(japanese: "駅を選ぶ", english: "Choose a station"),
    .productionLocationNoTransit: .init(japanese: "駅は指定しない", english: "No station"),
    .productionLocationNotSet: .init(japanese: "あとで決める", english: "Decide later"),
    .productionQuizTitle: .init(japanese: "会話クイズ", english: "Conversation quiz"),
    .productionQuizBody: .init(japanese: "10問の回答を、あなたのペルソナに反映します。", english: "Your 10 answers help shape your persona."),
    .productionQuizOpen: .init(japanese: "クイズを開く", english: "Open quiz"),
    .productionVoiceTitle: .init(japanese: "音声プロフィール", english: "Voice profile"),
    .productionVoiceBody: .init(japanese: "音声インタビュー、生成、確認の状態を管理します。", english: "Manage voice interviews, generation, and confirmation."),
    .productionVoiceOpen: .init(japanese: "音声プロフィールを開く", english: "Open voice profile"),
    .productionWatercolorTitle: .init(japanese: "水彩プロフィール画像", english: "Watercolor profile image"),
    .productionWatercolorBody: .init(japanese: "写真を端末で水彩に変換し、確認してから保存します。", english: "Convert a photo on this device, review it, then save it."),
    .productionWatercolorOpen: .init(japanese: "水彩プロフィールを開く", english: "Open watercolor profile"),
    .productionProfileTitle: .init(japanese: "Wardの設定", english: "Ward setup"),
    .productionProfileBody: .init(japanese: "保存された設定から、Wardとの会話を準備します。", english: "Prepare your Ward conversation from saved settings."),
    .productionAnalysisLoading: .init(japanese: "会話の分析を読み込んでいます。", english: "Loading your conversation analysis."),
    .productionAnalysisEmpty: .init(japanese: "分析はまだ準備中です。", english: "Your analysis is not ready yet."),
    .productionAnalysisEmptyBody: .init(japanese: "会話が保存されると、ここにあなたの特徴が表示されます。", english: "Your saved conversation traits will appear here when available."),
    .productionAnalysisError: .init(japanese: "分析を読み込めませんでした。", english: "We couldn't load your analysis."),
    .productionSavedTags: .init(japanese: "保存された特徴", english: "SAVED TRAITS"),
    .productionNoSavedTags: .init(japanese: "保存された特徴はまだありません。", english: "No saved traits yet."),
    .productionReadAnalysis: .init(japanese: "保存された分析を見る", english: "View saved analysis"),
    .productionNotificationsBody: .init(japanese: "通知設定の画面は準備中です。大切な安全通知はアカウントの状態に応じて扱われます。", english: "Notification controls are being prepared. Important safety notices follow your account state."),
    .productionLanguageSaved: .init(japanese: "表示言語を更新しました。", english: "Display language updated."),
    .youKicker: .init(japanese: "あなたについて", english: "ABOUT YOU"),
    .youTitle: .init(japanese: "あなたの会話の\n輪郭。", english: "The shape of\nyour conversations."),
    .youBody: .init(japanese: "会話から見えてきた傾向と、マッチの希望をここで確認できます。", english: "Review your conversation traits and match preferences here."),
    .youAnalysisTitle: .init(japanese: "対話分析", english: "Conversation analysis"),
    .youAnalysisBody: .init(japanese: "深く聴き、言葉で安心をつくる人", english: "A thoughtful listener who builds trust with words"),
    .youAnalysisAction: .init(japanese: "分析の全体を見る", english: "View full analysis"),
    .youPortraitLabel: .init(japanese: "Mio", english: "Mio"),
    .youTraitsLabel: .init(japanese: "あなたの特徴", english: "YOUR TRAITS"),
    .youSettingsLabel: .init(japanese: "設定", english: "SETTINGS"),
    .youPreferencesGroup: .init(japanese: "出会いの設定", english: "CONNECTION SETTINGS"),
    .youAccountGroup: .init(japanese: "アカウントとサポート", english: "ACCOUNT & SUPPORT"),
    .youWardSetup: .init(japanese: "Wardの設定", english: "Ward setup"),
    .youLanguageRegion: .init(japanese: "言語と地域", english: "Language & region"),
    .youMatchPreferences: .init(japanese: "マッチの希望", english: "Match preferences"),
    .youPlanPayments: .init(japanese: "プランと支払い", english: "Plan & payments"),
    .youNotifications: .init(japanese: "通知", english: "Notifications"),
    .youPrivacySafety: .init(japanese: "プライバシーと安全", english: "Privacy & safety"),
    .youHelp: .init(japanese: "ヘルプ", english: "Help"),
    .detailPlaceholder: .init(japanese: "この項目の詳細はオフラインデモ用のプレースホルダーです。", english: "Details for this item are represented by an offline placeholder."),
    .detailBack: .init(japanese: "戻る", english: "Back"),
    .timerAccessibilityLabel: .init(japanese: "経過時間", english: "Elapsed time"),
    .dismissAccessibilityLabel: .init(japanese: "閉じる", english: "Dismiss"),
    .analysisDetailKicker: .init(japanese: "対話分析", english: "CONVERSATION ANALYSIS"),
    .analysisDetailTitle: .init(japanese: "深く聴き、\n安心をつくる人。", english: "A thoughtful listener\nwho builds trust."),
    .analysisDetailBody: .init(japanese: "相手の言葉をいったん受け取り、気持ちを確かめながら会話を深めていく傾向があります。", english: "You tend to receive a person's words first, then deepen the conversation by checking how they feel."),
    .analysisDetailSummaryLabel: .init(japanese: "全体の傾向", english: "OVERALL SIGNATURE"),
    .analysisDetailSummary: .init(japanese: "小さな共感を重ねるほど、自然な魅力が伝わります。", english: "Your natural warmth comes through when you build trust through small moments of empathy."),
    .analysisDetailStrengthsLabel: .init(japanese: "強み", english: "STRENGTHS"),
    .analysisDetailStrengthOne: .init(japanese: "相手の話を最後まで聴く", english: "You listen through the whole thought"),
    .analysisDetailStrengthTwo: .init(japanese: "気持ちを言葉にして確かめる", english: "You name feelings to build clarity"),
    .analysisDetailStrengthThree: .init(japanese: "急がず信頼を育てる", english: "You grow trust without rushing"),
    .analysisDetailPracticeLabel: .init(japanese: "試してみること", english: "TRY THIS"),
    .analysisDetailPractice: .init(japanese: "安心できる相手には、いつもより一歩早く自分の考えを伝えてみましょう。", english: "With someone who feels safe, try sharing your own thought one step earlier than usual."),
    .analysisDetailFootnote: .init(japanese: "この分析は合成データから作ったプレビューです。", english: "This analysis is a preview built from synthetic data."),
    .localOnlyNote: .init(japanese: "外部通信なし・入力は保存されません", english: "No network · input is not saved")
  ]

  public static func text(
    _ key: BilingualReferenceCopyKey,
    language: BilingualReferenceLanguage
  ) -> String {
    entries[key]?.value(for: language) ?? ""
  }

  public static func pendingInterestBody(
    for candidateName: String,
    language: BilingualReferenceLanguage
  ) -> String {
    text(.wordsInterestPendingBody, language: language)
      .replacingOccurrences(of: "{name}", with: candidateName)
  }

  /// Localizes only canonical insight values known to be emitted by the
  /// fixture/live contract. Unknown server text is returned unchanged so the
  /// presentation layer never invents a translation for user content.
  public static func insightText(
    _ value: String,
    language: BilingualReferenceLanguage
  ) -> String {
    guard language == .japanese else { return value }
    switch value {
    case "A saved conversation signature.":
      return "保存された会話の特徴です。"
    case "Listens carefully":
      return "丁寧に話を聴く"
    case "Builds trust slowly":
      return "ゆっくり信頼を育てる"
    default:
      return value
    }
  }

  public static let quizQuestions: [BilingualReferenceQuizQuestion] = [
    .init(id: "q1", prompt: .init(japanese: "初対面の人とは、どんなふうに話したい？", english: "How do you like to talk with someone new?"), answers: [
      .init(id: "q1a", text: .init(japanese: "まずは相手の話を聞きたい", english: "I like listening first")),
      .init(id: "q1b", text: .init(japanese: "お互いに少しずつ話したい", english: "A little from both of us")),
      .init(id: "q1c", text: .init(japanese: "テンポよく盛り上がりたい", english: "I like an easy, lively pace"))
    ]),
    .init(id: "q2", prompt: .init(japanese: "休日にいちばん近い過ごし方は？", english: "Which weekend sounds most like you?"), answers: [
      .init(id: "q2a", text: .init(japanese: "静かな場所を散歩する", english: "A walk somewhere quiet")),
      .init(id: "q2b", text: .init(japanese: "気になる店を探す", english: "Finding a new place")),
      .init(id: "q2c", text: .init(japanese: "家でゆっくり過ごす", english: "A slow day at home"))
    ]),
    .init(id: "q3", prompt: .init(japanese: "安心できる会話はどれ？", english: "What makes a conversation feel safe?"), answers: [
      .init(id: "q3a", text: .init(japanese: "沈黙も気にならない", english: "Silence feels comfortable")),
      .init(id: "q3b", text: .init(japanese: "気持ちを言葉にできる", english: "Feelings can be named")),
      .init(id: "q3c", text: .init(japanese: "笑いが自然に生まれる", english: "Laughter comes naturally"))
    ]),
    .init(id: "q4", prompt: .init(japanese: "新しい場所で惹かれるものは？", english: "What draws you to a new place?"), answers: [
      .init(id: "q4a", text: .init(japanese: "そこで暮らす人の気配", english: "The people who live there")),
      .init(id: "q4b", text: .init(japanese: "小さな発見", english: "A small discovery")),
      .init(id: "q4c", text: .init(japanese: "居心地のよい空間", english: "A welcoming space"))
    ]),
    .init(id: "q5", prompt: .init(japanese: "意見が違ったときは？", english: "When you disagree, what feels right?"), answers: [
      .init(id: "q5a", text: .init(japanese: "理由をゆっくり聞く", english: "Hear the reason slowly")),
      .init(id: "q5b", text: .init(japanese: "自分の考えも伝える", english: "Share my own view too")),
      .init(id: "q5c", text: .init(japanese: "一度時間を置く", english: "Take a little time"))
    ]),
    .init(id: "q6", prompt: .init(japanese: "誰かと仲良くなるきっかけは？", english: "What helps you get closer to someone?"), answers: [
      .init(id: "q6a", text: .init(japanese: "何度か会話を重ねる", english: "A few conversations")),
      .init(id: "q6b", text: .init(japanese: "好きなものが似ている", english: "A shared interest")),
      .init(id: "q6c", text: .init(japanese: "思いがけない共通点", english: "An unexpected connection"))
    ]),
    .init(id: "q7", prompt: .init(japanese: "今ほしい距離感は？", english: "What kind of distance feels good now?"), answers: [
      .init(id: "q7a", text: .init(japanese: "ゆっくり近づきたい", english: "I want to take it slowly")),
      .init(id: "q7b", text: .init(japanese: "自然な流れに任せたい", english: "Let it unfold naturally")),
      .init(id: "q7c", text: .init(japanese: "気が合えばすぐ話したい", english: "Talk more if we click"))
    ]),
    .init(id: "q8", prompt: .init(japanese: "会話で大切にしていることは？", english: "What matters most in a conversation?"), answers: [
      .init(id: "q8a", text: .init(japanese: "相手のペース", english: "The other person's pace")),
      .init(id: "q8b", text: .init(japanese: "率直さ", english: "Honesty")),
      .init(id: "q8c", text: .init(japanese: "遊び心", english: "A sense of play"))
    ]),
    .init(id: "q9", prompt: .init(japanese: "会ってみたい場所は？", english: "Where would you like to meet?"), answers: [
      .init(id: "q9a", text: .init(japanese: "落ち着いたカフェ", english: "A quiet café")),
      .init(id: "q9b", text: .init(japanese: "街を歩ける場所", english: "Somewhere to walk")),
      .init(id: "q9c", text: .init(japanese: "まだ決めずに話したい", english: "Talk before deciding"))
    ]),
    .init(id: "q10", prompt: .init(japanese: "この先の出会いに望むことは？", english: "What do you hope for next?"), answers: [
      .init(id: "q10a", text: .init(japanese: "安心して話せること", english: "Feeling safe to talk")),
      .init(id: "q10b", text: .init(japanese: "新しい視点に出会うこと", english: "Meeting a new perspective")),
      .init(id: "q10c", text: .init(japanese: "自然体でいられること", english: "Being able to be myself"))
    ])
  ]

  public static let candidates: [BilingualReferenceCandidate] = [
    .init(
      id: "ren",
      name: "Ren",
      age: 29,
      imageName: "ren-watercolor",
      matchScore: 87,
      location: .init(japanese: "清澄白河・東京", english: "Kiyosumi-Shirakawa · Tokyo"),
      summary: .init(japanese: "音楽とコーヒーが日課。余白のある対話を大切にしています。", english: "Music and coffee are part of his rhythm. He values conversations with room to breathe."),
      signature: .init(japanese: "言葉を急がず、信頼を育てる聞き手", english: "A listener who builds trust without rushing words")
    ),
    .init(
      id: "aoi",
      name: "Aoi",
      age: 27,
      imageName: "aoi-watercolor",
      matchScore: 92,
      location: .init(japanese: "中目黒・東京", english: "Nakameguro · Tokyo"),
      summary: .init(japanese: "静かな好奇心と、相手の話を広げる温かさを持つ人です。", english: "A quiet curiosity and a warmth that helps other people's stories unfold."),
      signature: .init(japanese: "好奇心を会話に変える、穏やかな探索者", english: "A gentle explorer who turns curiosity into conversation")
    ),
    .init(
      id: "yui",
      name: "Yui",
      age: 28,
      imageName: "yui-watercolor",
      matchScore: 84,
      location: .init(japanese: "谷中・東京", english: "Yanaka · Tokyo"),
      summary: .init(japanese: "日々の小さな変化を楽しみ、素直な言葉を大切にしています。", english: "She notices small changes in daily life and values simple, honest words."),
      signature: .init(japanese: "小さな発見を分かち合う、素直な旅人", english: "An open-hearted traveler who shares small discoveries")
    )
  ]

  public static let wardTranscript: [BilingualReferenceMessage] = [
    .init(id: "transcript-1", author: .myWard, text: .init(japanese: "この人とは、急がずに話せそうです。", english: "It feels like we could talk without rushing.")),
    .init(id: "transcript-2", author: .partnerWard, text: .init(japanese: "静かな場所で、好きな音楽の話をしたいそうです。", english: "They would like to talk about music somewhere calm.")),
    .init(id: "transcript-3", author: .myWard, text: .init(japanese: "まずは短い散歩から始めるのはどうでしょう。", english: "How about starting with a short walk?")),
    .init(id: "transcript-4", author: .partnerWard, text: .init(japanese: "そのくらいの余白が、ちょうどよさそうです。", english: "That amount of space sounds just right."))
  ]

  public static let traits: [BilingualReferenceText] = [
    .init(japanese: "よく聴く", english: "Deep listener"),
    .init(japanese: "共感を言葉にする", english: "Names empathy"),
    .init(japanese: "穏やかなテンポ", english: "Steady pace"),
    .init(japanese: "小さな発見", english: "Small discoveries")
  ]

  public static let venueOptions: [BilingualReferenceText] = [
    .init(japanese: "土曜 14:00 · 清澄白河のカフェ", english: "Sat 2:00 PM · Café in Kiyosumi-Shirakawa"),
    .init(japanese: "日曜 11:00 · 谷中を散歩", english: "Sun 11:00 AM · Walk around Yanaka"),
    .init(japanese: "日曜 16:00 · 中目黒の小さな書店", english: "Sun 4:00 PM · Small bookstore in Nakameguro")
  ]

  public static var allLocalizedTexts: [BilingualReferenceText] {
    var values = Array(entries.values)
    values += quizQuestions.flatMap { question in
      [question.prompt] + question.answers.map(\.text)
    }
    values += candidates.flatMap { [$0.location, $0.summary, $0.signature] }
    values += wardTranscript.map(\.text)
    values += traits
    values += venueOptions
    return values
  }
}

public struct BilingualReferenceQuizAnswer: Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let text: BilingualReferenceText

  public init(id: String, text: BilingualReferenceText) {
    self.id = id
    self.text = text
  }
}

public struct BilingualReferenceQuizQuestion: Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let prompt: BilingualReferenceText
  public let answers: [BilingualReferenceQuizAnswer]

  public init(id: String, prompt: BilingualReferenceText, answers: [BilingualReferenceQuizAnswer]) {
    self.id = id
    self.prompt = prompt
    self.answers = answers
  }
}

public enum BilingualReferenceMessageAuthor: String, Hashable, Sendable {
  case myWard
  case partnerWard
  case localNote
}

public struct BilingualReferenceMessage: Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let author: BilingualReferenceMessageAuthor
  public let text: BilingualReferenceText

  public init(id: String, author: BilingualReferenceMessageAuthor, text: BilingualReferenceText) {
    self.id = id
    self.author = author
    self.text = text
  }
}

public struct BilingualReferenceCandidate: Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let age: Int
  public let imageName: String
  public let matchScore: Int
  public let location: BilingualReferenceText
  public let summary: BilingualReferenceText
  public let signature: BilingualReferenceText

  public init(
    id: String,
    name: String,
    age: Int,
    imageName: String,
    matchScore: Int,
    location: BilingualReferenceText,
    summary: BilingualReferenceText,
    signature: BilingualReferenceText
  ) {
    self.id = id
    self.name = name
    self.age = age
    self.imageName = imageName
    self.matchScore = matchScore
    self.location = location
    self.summary = summary
    self.signature = signature
  }
}

public enum BilingualReferenceRoute: String, Hashable, Sendable {
  case languageChoice
  case onboarding
  case quickCheckIn
  case voice
  case shell
}

public enum BilingualReferenceTab: String, CaseIterable, Hashable, Identifiable, Sendable {
  case words
  case you

  public var id: String { rawValue }
}

public enum BilingualReferenceVoicePhase: String, Hashable, Sendable {
  case ready
  case listening
}

public enum BilingualReferenceInterestState: String, Hashable, Sendable {
  case notStarted
  case pending
  case mutual
}

public enum BilingualReferenceVenueStage: String, Hashable, Sendable {
  case hidden
  case ready
  case coordinating
  case suggested
}

public enum BilingualReferenceComposerMode: String, Hashable, Sendable {
  case myWard
  case me
}

public enum BilingualReferenceSettingDestination: String, CaseIterable, Hashable, Identifiable, Sendable {
  case analysis
  case wardSetup
  case matchPreferences
  case planPayments
  case notifications
  case privacySafety
  case help

  public var id: String { rawValue }

  public var copyKey: BilingualReferenceCopyKey {
    switch self {
    case .analysis: return .youAnalysisTitle
    case .wardSetup: return .youWardSetup
    case .matchPreferences: return .youMatchPreferences
    case .planPayments: return .youPlanPayments
    case .notifications: return .youNotifications
    case .privacySafety: return .youPrivacySafety
    case .help: return .youHelp
    }
  }
}

@MainActor
public final class BilingualReferenceJourneyModel: ObservableObject {
  public let approvalFixture: Bool

  @Published public private(set) var language: BilingualReferenceLanguage?
  @Published public private(set) var route: BilingualReferenceRoute = .languageChoice
  @Published public private(set) var selectedTab: BilingualReferenceTab = .words
  @Published public private(set) var questionIndex = 0
  @Published public private(set) var answersByQuestion: [String: String] = [:]
  @Published public private(set) var isCheckInPaused = false
  @Published public private(set) var voicePhase: BilingualReferenceVoicePhase = .ready
  @Published public private(set) var selectedCandidateID = BilingualReferenceCatalog.candidates[0].id
  @Published public private(set) var interestState: BilingualReferenceInterestState = .notStarted
  @Published public private(set) var venueStage: BilingualReferenceVenueStage = .hidden
  @Published public private(set) var composerMode: BilingualReferenceComposerMode = .myWard
  @Published public private(set) var composerNotice: BilingualReferenceCopyKey?
  @Published public private(set) var draft = ""
  @Published public private(set) var localMessages: [BilingualReferenceMessage] = []

  public init(approvalFixture: Bool = false) {
    self.approvalFixture = approvalFixture
  }

  public var selectedCandidate: BilingualReferenceCandidate {
    BilingualReferenceCatalog.candidates.first(where: { $0.id == selectedCandidateID })
      ?? BilingualReferenceCatalog.candidates[0]
  }

  public var currentQuestion: BilingualReferenceQuizQuestion {
    BilingualReferenceCatalog.quizQuestions[min(questionIndex, BilingualReferenceCatalog.quizQuestions.count - 1)]
  }

  public var questionProgress: Double {
    guard !BilingualReferenceCatalog.quizQuestions.isEmpty else { return 0 }
    return Double(questionIndex + 1) / Double(BilingualReferenceCatalog.quizQuestions.count)
  }

  public func chooseLanguage(_ language: BilingualReferenceLanguage) {
    setLanguage(language)
    route = .onboarding
  }

  public func setLanguage(_ language: BilingualReferenceLanguage) {
    self.language = language
  }

  public func returnToOnboarding() {
    route = .onboarding
  }

  public func returnToCheckIn() {
    route = .quickCheckIn
  }

  public func openCheckIn() {
    route = .quickCheckIn
    isCheckInPaused = false
  }

  public func answerCurrentQuestion(with answerID: String) {
    guard !isCheckInPaused, currentQuestion.answers.contains(where: { $0.id == answerID }) else { return }
    answersByQuestion[currentQuestion.id] = answerID
    if questionIndex + 1 < BilingualReferenceCatalog.quizQuestions.count {
      questionIndex += 1
    } else {
      route = .voice
      voicePhase = .ready
    }
  }

  public func toggleCheckInPause() {
    isCheckInPaused.toggle()
  }

  public func startVoice() {
    voicePhase = .listening
  }

  public func finishVoice() {
    route = .shell
    selectedTab = .words
  }

  public func selectTab(_ tab: BilingualReferenceTab) {
    route = .shell
    selectedTab = tab
  }

  public func selectCandidate(_ candidate: BilingualReferenceCandidate) {
    guard BilingualReferenceCatalog.candidates.contains(candidate) else { return }
    selectedCandidateID = candidate.id
    interestState = .notStarted
    venueStage = .hidden
    composerMode = .myWard
    composerNotice = nil
  }

  public func expressInterest() {
    interestState = .pending
    venueStage = .hidden
  }

  /// This is intentionally separate from `expressInterest`: it makes the
  /// one-sided privacy boundary explicit while still allowing a deterministic
  /// offline preview of the mutual state.
  public func simulateMutualInterest() {
    guard interestState == .pending else { return }
    interestState = .mutual
    venueStage = .ready
  }

  public func advanceVenueCoordination() {
    switch venueStage {
    case .hidden, .suggested:
      break
    case .ready:
      venueStage = .coordinating
    case .coordinating:
      venueStage = .suggested
    }
  }

  public func selectComposerMode(_ mode: BilingualReferenceComposerMode) {
    guard mode != .me || approvalFixture else {
      composerNotice = .wordsComposerLockedBody
      return
    }
    composerMode = mode
    composerNotice = nil
  }

  public func setDraft(_ value: String) {
    draft = value
  }

  public func appendLocalWardMessage() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    localMessages.append(
      .init(
        id: "local-\(localMessages.count + 1)",
        author: .localNote,
        text: .init(japanese: trimmed, english: trimmed)
      )
    )
    draft = ""
  }

  public func clearComposerNotice() {
    composerNotice = nil
  }

  public func reset() {
    language = nil
    route = .languageChoice
    selectedTab = .words
    questionIndex = 0
    answersByQuestion = [:]
    isCheckInPaused = false
    voicePhase = .ready
    selectedCandidateID = BilingualReferenceCatalog.candidates[0].id
    interestState = .notStarted
    venueStage = .hidden
    composerMode = .myWard
    composerNotice = nil
    draft = ""
    localMessages = []
  }
}
