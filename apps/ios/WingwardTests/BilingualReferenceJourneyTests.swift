import Foundation
import XCTest
@testable import Wingward

#if DEBUG
@MainActor
final class BilingualReferenceJourneyTests: XCTestCase {
  func testInitialLanguageGateIsTheFirstRoute() {
    let model = BilingualReferenceJourneyModel()

    XCTAssertEqual(model.route, .languageChoice)
    XCTAssertNil(model.language)
    XCTAssertEqual(
      BilingualReferenceCatalog.text(.languageChoiceTitle, language: .japanese),
      "表示言語を選択してください"
    )
  }

  func testCatalogHasBothLanguagesForEveryPrototypeString() {
    XCTAssertEqual(
      Set(BilingualReferenceCatalog.entries.keys),
      Set(BilingualReferenceCopyKey.allCases)
    )
    XCTAssertTrue(
      BilingualReferenceCatalog.allLocalizedTexts.allSatisfy {
        !$0.japanese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
    )
  }

  func testLanguageCanBeChangedFromTheSelectedLanguage() {
    let model = BilingualReferenceJourneyModel()

    model.chooseLanguage(.english)
    XCTAssertEqual(model.language, .english)
    XCTAssertEqual(model.route, .onboarding)
    XCTAssertEqual(
      BilingualReferenceCatalog.text(.onboardingCTA, language: .english),
      "Start quick check-in"
    )

    model.setLanguage(.japanese)
    XCTAssertEqual(model.language, .japanese)
    XCTAssertEqual(
      BilingualReferenceCatalog.text(.onboardingCTA, language: .japanese),
      "チェックインをはじめる"
    )
  }

  func testPersistedLanguagePreferenceRoundTripsWithoutAThirdValue() {
    for language in BilingualReferenceLanguage.allCases {
      let rawValue = BilingualReferenceLanguagePreference.rawValue(for: language)
      XCTAssertEqual(BilingualReferenceLanguagePreference.language(from: rawValue), language)
    }
    XCTAssertNil(BilingualReferenceLanguagePreference.language(from: "fr"))
    XCTAssertNil(BilingualReferenceLanguagePreference.language(from: ""))
  }

  func testOnboardingAnswersAutoAdvanceThenFinishVoiceToWords() {
    let model = BilingualReferenceJourneyModel()
    model.chooseLanguage(.japanese)
    model.openCheckIn()

    XCTAssertEqual(model.route, .quickCheckIn)
    XCTAssertEqual(model.questionIndex, 0)
    for question in BilingualReferenceCatalog.quizQuestions {
      model.answerCurrentQuestion(with: question.answers[0].id)
    }

    XCTAssertEqual(model.answersByQuestion.count, 10)
    XCTAssertEqual(model.route, .voice)
    XCTAssertEqual(model.voicePhase, .ready)

    model.startVoice()
    XCTAssertEqual(model.voicePhase, .listening)
    model.finishVoice()
    XCTAssertEqual(model.route, .shell)
    XCTAssertEqual(model.selectedTab, .words)
  }

  func testCheckInPauseBlocksAnswerUntilResumed() {
    let model = BilingualReferenceJourneyModel()
    model.chooseLanguage(.english)
    model.openCheckIn()
    model.toggleCheckInPause()
    model.answerCurrentQuestion(with: model.currentQuestion.answers[0].id)

    XCTAssertTrue(model.isCheckInPaused)
    XCTAssertEqual(model.questionIndex, 0)
    XCTAssertTrue(model.answersByQuestion.isEmpty)

    model.toggleCheckInPause()
    model.answerCurrentQuestion(with: model.currentQuestion.answers[0].id)
    XCTAssertFalse(model.isCheckInPaused)
    XCTAssertEqual(model.questionIndex, 1)
  }

  func testShellDefinesExactlyWordsAndYouTabs() {
    XCTAssertEqual(BilingualReferenceTab.allCases, [.words, .you])
    XCTAssertEqual(BilingualReferenceCatalog.candidates.count, 3)
    XCTAssertEqual(BilingualReferenceCatalog.candidates.map(\.name), ["Ren", "Aoi", "Yui"])
  }

  func testProductionMatchesEmptyAndLoadFailureCopyAreScopedToTheList() {
    XCTAssertEqual(
      BilingualReferenceCatalog.text(.productionMatchesEmptyBody, language: .japanese),
      "マッチング希望が「回答しない」の場合、候補は表示されません。"
    )
    XCTAssertEqual(
      BilingualReferenceCatalog.text(.productionMatchesLoadError, language: .japanese),
      "候補の一覧を読み込めませんでした。"
    )
    XCTAssertNotEqual(BilingualReferenceCopyKey.productionMatchesLoadError, .productionMatchDetailError)
  }

  func testVerificationUnavailableAndRequestFailureCopyStayTruthful() {
    let japaneseVerification = BilingualReferenceCatalog.text(
      .productionIdentityVerificationUnavailable,
      language: .japanese
    )
    let englishVerification = BilingualReferenceCatalog.text(
      .productionIdentityVerificationUnavailable,
      language: .english
    )
    let englishRequestFailure = BilingualReferenceCatalog.text(
      .productionDirectChatCreateFailed,
      language: .english
    )

    XCTAssertTrue(japaneseVerification.contains("本人確認済みとして扱われることはありません"))
    XCTAssertTrue(englishVerification.contains("does not mark your account as verified"))
    XCTAssertTrue(englishRequestFailure.contains("no request is recorded"))
  }

  func testHumanChatModeStaysLockedUntilApprovalFixture() {
    let model = BilingualReferenceJourneyModel(approvalFixture: false)

    model.selectComposerMode(.me)

    XCTAssertEqual(model.composerMode, .myWard)
    XCTAssertEqual(model.composerNotice, .wordsComposerLockedBody)

    let approvedModel = BilingualReferenceJourneyModel(approvalFixture: true)
    approvedModel.selectComposerMode(.me)
    XCTAssertEqual(approvedModel.composerMode, .me)
    XCTAssertNil(approvedModel.composerNotice)
  }

  func testInterestAndVenueFixtureProgressesInlineWithoutNetwork() {
    let model = BilingualReferenceJourneyModel()

    XCTAssertEqual(model.interestState, .notStarted)
    XCTAssertEqual(model.venueStage, .hidden)
    model.expressInterest()
    XCTAssertEqual(model.interestState, .pending)
    XCTAssertEqual(model.venueStage, .hidden)
    XCTAssertTrue(
      BilingualReferenceCatalog.text(.wordsInterestPendingBody, language: .english)
        .contains("will not be told")
    )

    model.simulateMutualInterest()
    XCTAssertEqual(model.interestState, .mutual)
    XCTAssertEqual(model.venueStage, .ready)
    model.advanceVenueCoordination()
    XCTAssertEqual(model.venueStage, .coordinating)
    model.advanceVenueCoordination()
    XCTAssertEqual(model.venueStage, .suggested)
  }

  func testPartnerConversationDefaultsToWardAndRequiresServerRoomForHumanComposer() {
    let matchID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let otherMatchID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let room = DirectChatSummary(
      id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
      matchID: matchID,
      partner: nil,
      lastMessage: nil,
      unreadCount: 0,
      unreadCountAfterSeen: 0,
      status: "active"
    )

    XCTAssertEqual(BilingualProductionPartnerConversationMode.allCases.first, .ward)
    XCTAssertFalse(
      bilingualProductionHumanComposerIsEnabled(
        mode: .you,
        activeChat: nil,
        matchID: matchID,
        storeCanSend: true
      )
    )
    XCTAssertFalse(
      bilingualProductionHumanComposerIsEnabled(
        mode: .you,
        activeChat: room,
        matchID: otherMatchID,
        storeCanSend: true
      )
    )
    XCTAssertTrue(
      bilingualProductionHumanComposerIsEnabled(
        mode: .you,
        activeChat: room,
        matchID: matchID,
        storeCanSend: true
      )
    )
    XCTAssertFalse(
      bilingualProductionHumanComposerIsEnabled(
        mode: .ward,
        activeChat: room,
        matchID: matchID,
        storeCanSend: true
      )
    )
    XCTAssertNil(bilingualProductionActiveDirectChat(for: matchID, in: []))
    XCTAssertEqual(bilingualProductionActiveDirectChat(for: matchID, in: [room]), room)
  }

  func testPartnerComposerStartsWithAIAndUsesLocalizedModeCopy() {
    XCTAssertEqual(BilingualProductionPartnerConversationMode.allCases.first, .ward)
    XCTAssertEqual(
      BilingualReferenceCatalog.text(.productionConversationModeWard, language: .japanese),
      "AI"
    )
    XCTAssertEqual(
      BilingualReferenceCatalog.text(.productionConversationModeYou, language: .japanese),
      "人"
    )
    XCTAssertEqual(
      BilingualReferenceCatalog.text(.productionConversationModeWard, language: .english),
      "AI"
    )
    XCTAssertEqual(
      BilingualReferenceCatalog.text(.productionConversationModeYou, language: .english),
      "You"
    )
    XCTAssertEqual(
      BilingualReferenceCatalog.text(.productionAIComposerPlaceholder, language: .japanese),
      "AIに話してもらう内容を書く…"
    )
    XCTAssertEqual(
      BilingualReferenceCatalog.text(.productionDirectChatComposerPlaceholder, language: .japanese),
      "メッセージを書く…"
    )
    XCTAssertEqual(
      BilingualReferenceCatalog.text(.productionChatLabel, language: .japanese),
      "Chat"
    )
    XCTAssertEqual(
      BilingualReferenceCatalog.text(.productionChatLabel, language: .english),
      "Chat"
    )
  }

  func testPartnerAnalysisSummaryUsesOnlyPresentNonWhitespaceContent() {
    XCTAssertNil(bilingualProductionPartnerAnalysisSummary(nil, language: .japanese))
    XCTAssertNil(bilingualProductionPartnerAnalysisSummary(" \n\t", language: .japanese))
    XCTAssertEqual(
      bilingualProductionPartnerAnalysisSummary("  A shared rhythm.  ", language: .japanese),
      "A shared rhythm."
    )
    XCTAssertEqual(
      bilingualProductionPartnerAnalysisSummary(
        "Both Wards value calm, thoughtful conversations.",
        language: .japanese
      ),
      "どちらのWardも、落ち着いて丁寧に話すことを大切にしています。"
    )
    XCTAssertEqual(
      bilingualProductionPartnerAnalysisSummary(
        "Both Wards value calm, thoughtful conversations.",
        language: .english
      ),
      "Both Wards value calm, thoughtful conversations."
    )
    XCTAssertEqual(
      bilingualProductionPartnerAnalysisSummary(
        "A different server summary.",
        language: .japanese
      ),
      "A different server summary."
    )
  }

  func testPartnerRequestStateUsesServerRequesterAndMatchBinding() {
    let ownerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let ownerUUID = UUID(uuidString: ownerID)!
    let requesterID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    let matchID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let otherMatchID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let expiresAt = Date(timeIntervalSince1970: 4_600)
    let request = ChatRequestMatchState(
      id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
      matchID: matchID,
      requesterID: requesterID,
      responderID: ownerUUID,
      status: .pending,
      expiresAt: expiresAt
    )
    let outgoingRequest = ChatRequestMatchState(
      id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
      matchID: matchID,
      requesterID: ownerUUID,
      responderID: requesterID,
      status: .pending,
      expiresAt: expiresAt
    )

    XCTAssertEqual(
      bilingualProductionChatRequestState(for: request, ownerID: ownerID, matchID: matchID),
      .incomingPending
    )
    XCTAssertEqual(
      bilingualProductionChatRequestState(
        for: outgoingRequest,
        ownerID: ownerID,
        matchID: matchID
      ),
      .outgoingPending
    )
    XCTAssertEqual(
      bilingualProductionChatRequestState(for: request, ownerID: ownerID, matchID: otherMatchID),
      .none
    )
    XCTAssertEqual(
      bilingualProductionChatRequestState(
        for: request,
        ownerID: "not-a-uuid",
        matchID: matchID
      ),
      .none
    )

    let declined = ChatRequestMatchState(
      id: request.id,
      matchID: matchID,
      requesterID: ownerUUID,
      responderID: requesterID,
      status: .declined,
      expiresAt: expiresAt
    )
    XCTAssertEqual(
      bilingualProductionChatRequestState(for: declined, ownerID: ownerID, matchID: matchID),
      .declined
    )
  }

  func testProductionYouConnectionSettingsDoNotDuplicateWardSetup() {
    XCTAssertEqual(
      BilingualProductionAccountFeature.connectionSettings.map { $0.1 },
      [.languageRegion, .matchPreferences]
    )
    XCTAssertEqual(
      BilingualProductionAccountFeature.connectionSettings.map { $0.0 },
      [.youLanguageRegion, .youMatchPreferences]
    )
  }

  func testJapaneseInsightPresentationMapsOnlyKnownCanonicalValues() {
    XCTAssertEqual(
      BilingualReferenceCatalog.insightText(
        "A saved conversation signature.",
        language: .japanese
      ),
      "保存された会話の特徴です。"
    )
    XCTAssertEqual(
      BilingualReferenceCatalog.insightText("Listens carefully", language: .japanese),
      "丁寧に話を聴く"
    )
    XCTAssertEqual(
      BilingualReferenceCatalog.insightText("Builds trust slowly", language: .japanese),
      "ゆっくり信頼を育てる"
    )
    XCTAssertEqual(
      BilingualReferenceCatalog.insightText("保存された会話の特徴です。", language: .japanese),
      "保存された会話の特徴です。"
    )
    XCTAssertEqual(
      BilingualReferenceCatalog.insightText("An unknown server value", language: .japanese),
      "An unknown server value"
    )
    XCTAssertEqual(
      BilingualReferenceCatalog.insightText(
        "A saved conversation signature.",
        language: .english
      ),
      "A saved conversation signature."
    )
  }
}
#endif
