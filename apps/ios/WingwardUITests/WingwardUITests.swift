import XCTest

final class WingwardUITests: XCTestCase {
  func testSignedOutLandingHasAccessibleAuthActions() {
    let app = launch(in: "signedOut")

    XCTAssertTrue(app.buttons["auth.signIn"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["auth.signUp"].exists)
    captureReferenceScreenshot("auth-01-landing", in: app)
  }

  func testInputErrorsAreVisibleWithoutNetwork() {
    let app = launch(in: "signedOut")
    app.buttons["auth.signUp"].tap()
    let submit = app.buttons["signup.submit"]
    XCTAssertTrue(submit.waitForExistence(timeout: 2))
    submit.tap()
    XCTAssertTrue(app.staticTexts["Enter your email address."].waitForExistence(timeout: 2))
    captureReferenceScreenshot("auth-02-signup-input-error", in: app)
  }

  func testAgeGateDemoIsReachable() {
    let app = launch(in: "needsAge")
    XCTAssertTrue(app.buttons["ageGate.submit"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.datePickers["ageGate.birthDate"].exists)
  }

  func testProductionRootStartsAtLanguageChoiceAndReachesBothTabs() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--wingward-matches-fixture",
      "success",
      "-wingward.displayLanguage",
      ""
    ]
    app.launch()

    let japanese = app.buttons["production.languageChoice.ja"]
    XCTAssertTrue(japanese.waitForExistence(timeout: 2))
    japanese.tap()

    let wordsTab = app.descendants(matching: .any)["production.tab.words"]
    XCTAssertTrue(wordsTab.waitForExistence(timeout: 2))

    let youTab = app.buttons["You"]
    XCTAssertTrue(youTab.waitForExistence(timeout: 2))
    youTab.tap()
    XCTAssertTrue(
      app.buttons["production.you.setting.languageRegion"].waitForExistence(timeout: 2)
    )
    XCTAssertTrue(
      app.staticTexts["保存された会話の特徴です。"].waitForExistence(timeout: 3)
    )
    XCTAssertTrue(app.staticTexts["丁寧に話を聴く"].exists)
    XCTAssertTrue(app.staticTexts["ゆっくり信頼を育てる"].exists)
    XCTAssertTrue(
      app.buttons["production.you.setting.matchPreferences"].waitForExistence(timeout: 2)
    )
    XCTAssertFalse(app.buttons["production.you.setting.wardSetup"].exists)

    let localizedYouScreenshot = XCTAttachment(screenshot: app.screenshot())
    localizedYouScreenshot.name = "production-you-japanese-localized"
    localizedYouScreenshot.lifetime = .keepAlways
    add(localizedYouScreenshot)
    XCTAssertFalse(app.staticTexts["Wingward"].exists)
  }

  func testProductionNotificationsSettingOpensFunctionalSettings() {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-matches-fixture", "success", "-wingward.displayLanguage", "en"]
    app.launch()
    let you = app.buttons["You"]
    XCTAssertTrue(you.waitForExistence(timeout: 3))
    you.tap()
    let notifications = app.buttons["production.you.setting.notifications"]
    for _ in 0..<4 where !notifications.isHittable { app.swipeUp() }
    XCTAssertTrue(notifications.waitForExistence(timeout: 3))
    notifications.tap()
    XCTAssertTrue(app.buttons["notifications.settings.openSystemSettings"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["notifications.settings.clearBadge"].exists)
  }

  func testProductionOnboardingOptionsRetryKeepsDraftLocaleAndOwner() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--wingward-matches-fixture",
      "success",
      "-wingward.displayLanguage",
      "en",
      "--wingward-onboarding-options-retry"
    ]
    app.launch()

    let you = app.buttons["You"]
    XCTAssertTrue(you.waitForExistence(timeout: 3))
    you.tap()
    tapReferenceButton("production.you.setting.matchPreferences", in: app)

    let japaneseLocale = app.buttons["production.onboarding.uiLanguage.ja"]
    XCTAssertTrue(japaneseLocale.waitForExistence(timeout: 3))
    XCTAssertTrue(japaneseLocale.isSelected)

    let englishConversationLanguage = app.buttons[
      "production.onboarding.conversationLanguage.en"
    ]
    tapReferenceButton("production.onboarding.conversationLanguage.en", in: app)
    XCTAssertTrue(englishConversationLanguage.isSelected)

    let optionsStatus = app.staticTexts["production.onboarding.optionsStatus"]
    XCTAssertTrue(optionsStatus.waitForExistence(timeout: 3))
    XCTAssertEqual(optionsStatus.label, "Location options are unavailable.")
    let retry = app.buttons["production.onboarding.optionsRetry"]
    XCTAssertTrue(retry.waitForExistence(timeout: 3))
    tapReferenceButton("production.onboarding.optionsRetry", in: app)

    let stationPicker = app.descendants(matching: .any)["production.onboarding.station"]
    XCTAssertTrue(stationPicker.waitForExistence(timeout: 3))
    XCTAssertTrue(japaneseLocale.isSelected)
    XCTAssertTrue(englishConversationLanguage.isSelected)

    for _ in 0..<5 where !stationPicker.isHittable { app.swipeUp() }
    XCTAssertTrue(stationPicker.isHittable)
    stationPicker.tap()
    XCTAssertTrue(app.buttons["下北沢"].waitForExistence(timeout: 3))
  }

  func testProductionHelpOpensGuideAndSubscriptionManagement() {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-matches-fixture", "success", "-wingward.displayLanguage", "en"]
    app.launch()
    let you = app.buttons["You"]
    XCTAssertTrue(you.waitForExistence(timeout: 3))
    you.tap()
    let help = app.buttons["production.you.setting.help"]
    for _ in 0..<4 where !help.isHittable { app.swipeUp() }
    XCTAssertTrue(help.waitForExistence(timeout: 3))
    help.tap()
    XCTAssertTrue(app.staticTexts["Using WingWard"].waitForExistence(timeout: 3))
    let manage = app.descendants(matching: .any)["production.you.help.appleSubscriptions"]
    for _ in 0..<4 where !manage.isHittable { app.swipeUp() }
    XCTAssertTrue(manage.exists)
  }

  func testProductionPartnerWardKeepsWardDefaultAndGatesHumanModeInline() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--wingward-matches-fixture",
      "success",
      "-wingward.displayLanguage",
      ""
    ]
    app.launch()

    let japanese = app.buttons["production.languageChoice.ja"]
    XCTAssertTrue(japanese.waitForExistence(timeout: 2))
    japanese.tap()

    let match = app.descendants(matching: .any)[
      "production.words.match.11111111-1111-1111-1111-111111111111"
    ]
    XCTAssertTrue(match.waitForExistence(timeout: 3))
    match.tap()

    let partnerWard = app.descendants(matching: .any)["production.matchDetail.partnerWard"]
    XCTAssertTrue(partnerWard.waitForExistence(timeout: 3))
    XCTAssertTrue(partnerWard.label.contains("Chat"))
    partnerWard.tap()

    let wardMode = app.descendants(matching: .any)["production.partnerWard.mode.ward"]
    let youMode = app.descendants(matching: .any)["production.partnerWard.mode.you"]
    XCTAssertTrue(wardMode.waitForExistence(timeout: 3))
    XCTAssertTrue(youMode.exists)
    XCTAssertTrue(wardMode.label.contains("AI"))
    XCTAssertTrue(app.textFields["production.partnerWard.composer"].exists)
    XCTAssertTrue(
      app.descendants(matching: .any)["production.partnerWard.history"].exists
    )
    let wardDefaultScreenshot = XCTAttachment(screenshot: app.screenshot())
    wardDefaultScreenshot.name = "production-partner-ward-default"
    wardDefaultScreenshot.lifetime = .keepAlways
    add(wardDefaultScreenshot)

    youMode.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["production.partnerWard.directChat.unavailable"]
        .waitForExistence(timeout: 2)
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["production.partnerWard.humanComposer.locked"]
        .waitForExistence(timeout: 2)
    )
    XCTAssertFalse(
      app.textFields["production.partnerWard.humanComposer"].exists,
      "The human composer must stay hidden when no server room is available."
    )
    let humanModeLockedScreenshot = XCTAttachment(screenshot: app.screenshot())
    humanModeLockedScreenshot.name = "production-partner-you-locked"
    humanModeLockedScreenshot.lifetime = .keepAlways
    add(humanModeLockedScreenshot)
  }

  func testProductionMatchDetailShowsPublicPartnerAnalysisAndChatRoute() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--wingward-matches-fixture",
      "success",
      "-wingward.displayLanguage",
      ""
    ]
    app.launch()

    let japanese = app.buttons["production.languageChoice.ja"]
    XCTAssertTrue(japanese.waitForExistence(timeout: 2))
    japanese.tap()

    let match = app.descendants(matching: .any)[
      "production.words.match.11111111-1111-1111-1111-111111111111"
    ]
    XCTAssertTrue(match.waitForExistence(timeout: 3))
    match.tap()

    XCTAssertTrue(
      app.descendants(matching: .any)["production.matchDetail.partnerAnalysis"]
        .waitForExistence(timeout: 3)
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["production.matchDetail.partnerAnalysis.summary"]
        .waitForExistence(timeout: 3)
    )
    XCTAssertTrue(
      app.staticTexts["どちらのWardも、落ち着いて丁寧に話すことを大切にしています。"]
        .waitForExistence(timeout: 3)
    )

    let chat = app.descendants(matching: .any)["production.matchDetail.partnerWard"]
    XCTAssertTrue(chat.waitForExistence(timeout: 3))
    XCTAssertTrue(chat.label.contains("Chat"))

    let analysisChatScreenshot = XCTAttachment(screenshot: app.screenshot())
    analysisChatScreenshot.name = "production-match-detail-analysis-chat"
    analysisChatScreenshot.lifetime = .keepAlways
    add(analysisChatScreenshot)
  }

  func testProductionMeetupVerificationCallbackShowsProviderUnavailableNotice() {
    let app = launchProductionFixture(
      extraArguments: ["--wingward-native-meetup-verification-required"]
    )
    openProductionFirstMatch(in: app)

    let meetup = app.buttons["production.matchDetail.meetup"]
    XCTAssertTrue(meetup.waitForExistence(timeout: 3))
    scrollTo(meetup, in: app)
    meetup.tap()

    let retry = app.buttons["meetup.arrangeFailed.retry"]
    XCTAssertTrue(retry.waitForExistence(timeout: 3))
    scrollTo(retry, in: app)
    retry.tap()

    XCTAssertTrue(
      app.descendants(matching: .any)["meetup.verificationGate"].waitForExistence(timeout: 3)
    )
    let verification = app.buttons["meetup.verification.open"]
    scrollTo(verification, in: app)
    XCTAssertTrue(verification.waitForExistence(timeout: 3))
    verification.tap()
    let alert = app.alerts.firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 3))
    let notice = alert.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "cannot start here")
    ).firstMatch
    XCTAssertTrue(notice.waitForExistence(timeout: 3))
    XCTAssertTrue(notice.label.contains("cannot start here"))
    XCTAssertTrue(notice.label.contains("does not mark your account as verified"))
  }

  func testProductionMeetupPaywallCallbackRoutesToBillingFixture() {
    let app = launchProductionFixture(
      extraArguments: ["--wingward-native-meetup-quota"]
    )
    openProductionFirstMatch(in: app)

    let meetup = app.buttons["production.matchDetail.meetup"]
    XCTAssertTrue(meetup.waitForExistence(timeout: 3))
    scrollTo(meetup, in: app)
    meetup.tap()

    let arrange = app.buttons["meetup.arrange"]
    XCTAssertTrue(arrange.waitForExistence(timeout: 3))
    scrollTo(arrange, in: app)
    arrange.tap()

    let paywall = app.buttons["meetup.paywall"]
    XCTAssertTrue(paywall.waitForExistence(timeout: 3))
    scrollTo(paywall, in: app)
    paywall.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["billing.status"].waitForExistence(timeout: 3)
    )
  }

  func testProductionMeetupReportCallbackOpensMatchSafety() {
    let app = launchProductionFixture(
      extraArguments: ["--wingward-native-meetup-verifying"]
    )
    openProductionFirstMatch(in: app)

    let meetup = app.buttons["production.matchDetail.meetup"]
    XCTAssertTrue(meetup.waitForExistence(timeout: 3))
    scrollTo(meetup, in: app)
    meetup.tap()

    let report = app.buttons["meetup.report"]
    XCTAssertTrue(report.waitForExistence(timeout: 3))
    scrollTo(report, in: app)
    report.tap()
    XCTAssertTrue(app.buttons["safety.report"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["safety.block"].exists)
  }

  func testProductionDeepLinkBlockRefreshesUnderlyingMatches() {
    let app = launchProductionFixture(
      extraArguments: [
        "--wingward-production-deep-link-safety",
        "--wingward-production-safety-reconciliation",
      ]
    )
    let report = app.buttons["production.debugRoute.reportBlock"]
    XCTAssertTrue(report.waitForExistence(timeout: 3))
    report.tap()
    let block = app.buttons["safety.block"]
    XCTAssertTrue(block.waitForExistence(timeout: 3))
    scrollTo(block, in: app)
    block.tap()
    let confirm = app.buttons.matching(identifier: "safety.block.confirm").firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 3))
    confirm.tap()

    XCTAssertTrue(
      app.descendants(matching: .any)["production.words.empty"].waitForExistence(timeout: 4)
    )
    XCTAssertFalse(
      app.descendants(matching: .any)[
        "production.words.match.11111111-1111-1111-1111-111111111111"
      ].exists
    )
  }

  func testProductionDeepLinkBlockReconciliationRefreshesUnderlyingMatches() {
    let app = launchProductionFixture(
      extraArguments: [
        "--wingward-production-deep-link-safety",
        "--wingward-production-safety-reconciliation",
        "--wingward-production-safety-block-failure",
      ]
    )
    let report = app.buttons["production.debugRoute.reportBlock"]
    XCTAssertTrue(report.waitForExistence(timeout: 3))
    report.tap()
    let block = app.buttons["safety.block"]
    XCTAssertTrue(block.waitForExistence(timeout: 3))
    scrollTo(block, in: app)
    block.tap()
    let confirm = app.buttons.matching(identifier: "safety.block.confirm").firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 3))
    confirm.tap()

    XCTAssertTrue(
      app.descendants(matching: .any)["production.words.empty"].waitForExistence(timeout: 4)
    )
    XCTAssertFalse(
      app.descendants(matching: .any)[
        "production.words.match.11111111-1111-1111-1111-111111111111"
      ].exists
    )
  }

  func testAuthenticatedDebugRouteShowsSettingsAndPendingInterview() {
    let app = launch(in: "success")
    openYou(in: app)
    XCTAssertTrue(app.descendants(matching: .any)["production.accountBadge"].exists)
    XCTAssertTrue(app.buttons["production.you.signOut"].exists)
    let voice = app.buttons["production.you.voice"]
    scrollTo(voice, in: app)
    XCTAssertTrue(voice.exists)
    XCTAssertFalse(voice.isEnabled, "Unavailable fixture services must not become live services")
  }

  func testDebugMatchesSuccessShowsRankAndSettings() {
    let app = launchMatches(in: "success")
    let card = app.descendants(matching: .any)["production.words.match.11111111-1111-1111-1111-111111111111"]
    XCTAssertTrue(card.waitForExistence(timeout: 3))
    XCTAssertTrue(card.label.contains("Aoi"))
    XCTAssertTrue(app.buttons["production.words.refresh"].exists)
    openYou(in: app)
    XCTAssertTrue(app.buttons["production.you.signOut"].exists)
    XCTAssertTrue(app.buttons["production.you.setting.matchPreferences"].exists)
    captureMatchesScreenshot("matches-01-success", in: app)
  }

  func testDebugConversationInsightCardOpensSavedReport() {
    let app = launchMatches(in: "success")
    openYou(in: app)
    let card = app.buttons["production.you.analysis.open"]
    XCTAssertTrue(card.waitForExistence(timeout: 3))
    card.tap()
    XCTAssertTrue(app.staticTexts["A saved conversation signature."].waitForExistence(timeout: 3))
    captureMatchesScreenshot("matches-insight-report", in: app)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(card.waitForExistence(timeout: 3))
  }

  func testDebugMatchesDetailHistoryAndCandidateIdentity() {
    let app = launchMatches(in: "success")
    let first = app.descendants(matching: .any)["production.words.match.11111111-1111-1111-1111-111111111111"]
    XCTAssertTrue(first.waitForExistence(timeout: 3))
    first.tap()
    XCTAssertEqual(app.staticTexts["production.matchDetail.partner"].label, "Aoi")
    let history = app.staticTexts["production.matchDetail.history"]
    scrollTo(history, in: app)
    XCTAssertTrue(history.exists)
    for id in ["44444444-4444-4444-8444-444444444444", "55555555-5555-4555-8555-555555555555"] {
      let message = app.descendants(matching: .any)["production.matchDetail.message.\(id)"]
      scrollTo(message, in: app)
      XCTAssertTrue(message.exists)
    }
    captureMatchesScreenshot("matches-detail-01-history", in: app)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    let second = app.descendants(matching: .any)["production.words.match.22222222-2222-2222-2222-222222222222"]
    scrollTo(second, in: app)
    second.tap()
    XCTAssertTrue(app.staticTexts["production.matchDetail.partner"].waitForExistence(timeout: 3))
    XCTAssertEqual(app.staticTexts["production.matchDetail.partner"].label, "Mina")
    let empty = app.staticTexts["production.matchDetail.history.empty"]
    scrollTo(empty, in: app)
    XCTAssertTrue(empty.exists)
    XCTAssertFalse(app.buttons["production.matchDetail.partnerWard"].exists)
  }

  func testDebugPartnerWardSupportsHistoryComposerSafetyAndBack() {
    let app = launchMatches(in: "success")
    let first = app.descendants(matching: .any)["production.words.match.11111111-1111-1111-1111-111111111111"]
    XCTAssertTrue(first.waitForExistence(timeout: 3))
    first.tap()
    let entry = app.descendants(matching: .any)["production.matchDetail.partnerWard"]
    XCTAssertTrue(entry.waitForExistence(timeout: 3))
    entry.tap()
    XCTAssertTrue(app.staticTexts["production.partnerWard.history"].waitForExistence(timeout: 3))
    let composer = app.textFields["production.partnerWard.composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 3))
    composer.tap()
    composer.typeText("Fixture message")
    let send = app.buttons["production.partnerWard.send"]
    XCTAssertTrue(send.isEnabled)
    send.tap()
    XCTAssertTrue(app.staticTexts["Fixture message"].waitForExistence(timeout: 3))
    let humanMode = app.buttons["production.partnerWard.mode.you"]
    humanMode.tap()
    XCTAssertTrue(app.descendants(matching: .any)["production.partnerWard.humanComposer.locked"].exists)
    XCTAssertFalse(app.textFields["production.partnerWard.humanComposer"].exists)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(entry.waitForExistence(timeout: 3))
  }

  func testDebugPendingMatchStartsWardConversationExplicitly() {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-matches-fixture", "pending", "-wingward.displayLanguage", ""]
    app.launch()
    let japanese = app.buttons["production.languageChoice.ja"]
    XCTAssertTrue(japanese.waitForExistence(timeout: 3))
    japanese.tap()
    let firstCard = app.descendants(matching: .any)[
      "production.words.match.11111111-1111-1111-1111-111111111111"
    ]
    XCTAssertTrue(firstCard.waitForExistence(timeout: 2))
    firstCard.tap()

    let startButton = app.buttons["production.matchDetail.startWard"]
    XCTAssertTrue(startButton.waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Wardの会話を始められます"].exists)
    captureMatchesScreenshot("matches-detail-pending-before-start", in: app)

    startButton.tap()

    XCTAssertTrue(
      app.staticTexts["Wardが会話しています"].waitForExistence(timeout: 3)
    )
    XCTAssertFalse(startButton.exists)
    captureMatchesScreenshot("matches-detail-pending-after-start", in: app)
  }

  func testDebugMatchesDetailRetryRecovers() {
    let app = launchMatches(in: "retry")
    let retry = app.buttons["production.words.retry"]
    XCTAssertTrue(retry.waitForExistence(timeout: 3))
    retry.tap()
    let first = app.descendants(matching: .any)["production.words.match.11111111-1111-1111-1111-111111111111"]
    XCTAssertTrue(first.waitForExistence(timeout: 3))
    first.tap()
    let detailRetry = app.buttons["production.matchDetail.retry"]
    XCTAssertTrue(detailRetry.waitForExistence(timeout: 3))
    detailRetry.tap()
    XCTAssertTrue(app.staticTexts["production.matchDetail.partner"].waitForExistence(timeout: 3))
    let history = app.staticTexts["production.matchDetail.history"]
    scrollTo(history, in: app)
    XCTAssertTrue(history.exists)
  }

  func testDebugMatchesEmptyState() {
    let app = launchMatches(in: "empty")
    XCTAssertTrue(app.descendants(matching: .any)["production.words.empty"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.descendants(matching: .any)["production.words.match.11111111-1111-1111-1111-111111111111"].exists)
    let refresh = app.buttons["production.words.empty.refresh"]
    XCTAssertTrue(refresh.exists)
    refresh.tap()
    XCTAssertTrue(app.descendants(matching: .any)["production.words.empty"].waitForExistence(timeout: 3))
    captureMatchesScreenshot("matches-02-empty", in: app)
  }

  func testDebugRecordingRehearsalFixtureShowsSyntheticResultAndDisclaimer() {
    let app = launchMatches(
      in: "empty",
      extraArguments: ["--wingward-recording-matching-fixture"]
    )
    let disclaimer = app.staticTexts[
      "DEBUG UI fixture — no matching request was sent to the service"
    ]
    let start = app.buttons["production.words.empty.startTestMatching"]

    XCTAssertTrue(start.waitForExistence(timeout: 3))
    XCTAssertTrue(disclaimer.exists)
    start.tap()

    let firstSyntheticMatch = app.descendants(matching: .any)[
      "production.words.match.11111111-1111-1111-1111-111111111111"
    ]
    XCTAssertTrue(firstSyntheticMatch.waitForExistence(timeout: 3))
    XCTAssertTrue(disclaimer.exists)
    XCTAssertFalse(start.exists)
    let status = app.staticTexts["production.words.recordingRehearsal.status"]
    XCTAssertTrue(status.waitForExistence(timeout: 3))
    XCTAssertEqual(status.label, "Synthetic fixture result shown; no live matching ran.")
  }

  func testDebugMatchesConversationInProgressCanRefreshStatus() {
    let app = launchMatches(in: "success")
    let match = app.descendants(matching: .any)[
      "production.words.match.22222222-2222-2222-2222-222222222222"
    ]
    XCTAssertTrue(match.waitForExistence(timeout: 3))
    match.tap()

    let refresh = app.buttons["production.matchDetail.history.refresh"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 3))
    refresh.tap()
    XCTAssertTrue(app.staticTexts["production.matchDetail.history"].exists)
  }

  func testDebugMatchesRetryRecovers() {
    let app = launchMatches(in: "retry")
    let retry = app.buttons["production.words.retry"]
    XCTAssertTrue(retry.waitForExistence(timeout: 3))
    retry.tap()
    XCTAssertTrue(app.descendants(matching: .any)["production.words.match.11111111-1111-1111-1111-111111111111"].waitForExistence(timeout: 3))
    XCTAssertFalse(retry.exists)
    captureMatchesScreenshot("matches-04-retry-success", in: app)
  }

  func testDebugMatchesLoadingState() {
    let app = launchMatches(in: "loading")
    XCTAssertTrue(app.descendants(matching: .any)["production.words.loading"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.descendants(matching: .any)["production.words.match.11111111-1111-1111-1111-111111111111"].exists)
    captureMatchesScreenshot("matches-05-loading", in: app)
  }

  func testDebugMatchesOpensSettings() {
    let app = launchMatches(in: "success")
    openYou(in: app)
    let settings = app.buttons["production.you.setting.matchPreferences"]
    XCTAssertTrue(settings.waitForExistence(timeout: 3))
    settings.tap()
    let preference = app.buttons["production.onboarding.preference.noAnswer"]
    scrollTo(preference, in: app)
    XCTAssertTrue(preference.exists)
    captureMatchesScreenshot("matches-06-settings", in: app)
  }

  func testDebugNativeJourneyReachesEveryFeatureSurface() {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-native-journey", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()

    XCTAssertTrue(
      app.staticTexts["DEBUG FIXTURE · synthetic preview · no account changes"]
        .waitForExistence(timeout: 2)
    )

    for identifier in [
      "nativeHub.voiceProfile",
      "nativeHub.directChats",
      "nativeHub.meetups",
      "nativeHub.billing",
      "nativeHub.safetyAccount"
    ] {
      let entry = app.buttons[identifier]
      XCTAssertTrue(entry.waitForExistence(timeout: 2), identifier)
      entry.tap()
      if identifier == "nativeHub.voiceProfile" {
        XCTAssertTrue(app.buttons["voiceProfile.start.virtual_similar"].waitForExistence(timeout: 3))
      } else if identifier == "nativeHub.directChats" {
        XCTAssertTrue(app.staticTexts["chatsDebugFixture.banner"].waitForExistence(timeout: 2))
      } else if identifier == "nativeHub.meetups" {
        XCTAssertTrue(app.buttons["meetup.intent"].waitForExistence(timeout: 3))
      } else if identifier == "nativeHub.billing" {
        XCTAssertTrue(app.descendants(matching: .any)["billing.status"].waitForExistence(timeout: 3))
      } else {
        XCTAssertTrue(app.buttons["safety.report"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["accountDeletion.delete"].exists)
      }
      if identifier == "nativeHub.directChats" {
        XCTAssertTrue(app.buttons["chatsDebugFixture.backToHub"].waitForExistence(timeout: 2))
        app.buttons["chatsDebugFixture.backToHub"].tap()
      } else {
        app.navigationBars.buttons.element(boundBy: 0).tap()
      }
      XCTAssertTrue(entry.waitForExistence(timeout: 2), identifier)
    }
  }

  func testDebugNativeJourneyPartnerWardFixtureCanSend() {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-native-journey", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()

    let directChats = app.buttons["nativeHub.directChats"]
    XCTAssertTrue(directChats.waitForExistence(timeout: 2))
    directChats.tap()

    let partnerWard = app.buttons["chatsDebugFixture.partnerWard"]
    XCTAssertTrue(partnerWard.waitForExistence(timeout: 2))
    partnerWard.tap()

    let composer = app.textFields["partnerWard.composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 2))
    composer.tap()
    composer.typeText("Fixture message")
    let send = app.buttons["partnerWard.send"]
    XCTAssertTrue(send.isEnabled)
    send.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)[
        "partnerWard.message.99999999-9999-4999-8999-000000000001"
      ].waitForExistence(timeout: 3)
    )
    XCTAssertTrue(app.staticTexts["その気持ちをもう少し聞かせてください。"].exists)
    XCTAssertEqual(composer.value as? String, "Write to Partner Ward")
    captureMatchesScreenshot("native-partner-ward-send", in: app)
  }

  func testDebugNativeJourneyDirectChatCanSend() {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-native-journey", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    app.buttons["nativeHub.directChats"].tap()

    let row = app.buttons["directChats.row.CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"]
    scrollTo(row, in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 3))
    row.tap()
    let composer = app.textFields["directChat.composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 3))
    composer.tap()
    composer.typeText("Fixture direct message")
    let send = app.buttons["directChat.send"]
    XCTAssertTrue(send.isEnabled)
    send.tap()
    XCTAssertTrue(app.staticTexts["Fixture direct message"].waitForExistence(timeout: 3))
    XCTAssertEqual(composer.value as? String, "Write a message")
    captureMatchesScreenshot("native-direct-chat-send", in: app)
  }


  func testDebugNativeJourneyInlineMeetupPrivacyRestoreAndReflection() {
    let app = XCUIApplication()
    // Synthetic provider response: validates attribution rendering, not live Google access.
    app.launchArguments = ["--wingward-native-journey", "--wingward-chat-meetup-mock-google", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    app.buttons["nativeHub.directChats"].tap()

    let row = app.buttons["directChats.row.CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"]
    scrollTo(row, in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 3))
    row.tap()

    let card = app.descendants(matching: .any)["directChat.meetupCard"]
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    let intent = app.buttons["directChat.meetup.intent.yes"]
    XCTAssertTrue(intent.waitForExistence(timeout: 3))
    scrollTo(intent, in: app)
    intent.tap()

    let calendar = app.buttons["directChat.meetup.availability.calendar"]
    XCTAssertTrue(calendar.waitForExistence(timeout: 3))
    scrollTo(calendar, in: app)
    calendar.tap()
    let calendarDisclosure = app.staticTexts["directChat.meetup.calendarDisclosure"]
    XCTAssertTrue(calendarDisclosure.waitForExistence(timeout: 3))
    XCTAssertTrue((calendarDisclosure.label).contains("Calendar access is off"))

    let roughAvailability = app.buttons["directChat.meetup.manual.weekends"]
    scrollTo(roughAvailability, in: app)
    roughAvailability.tap()
    let timeChoice = app.buttons["directChat.meetup.time.12121212-1212-4212-8212-121212121212"]
    XCTAssertTrue(timeChoice.waitForExistence(timeout: 4))
    scrollTo(timeChoice, in: app)
    timeChoice.tap()

    XCTAssertTrue(app.staticTexts["directChat.meetup.noReservation"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.textFields["directChat.meetup.location.station"].exists)
    XCTAssertFalse(app.buttons["directChat.meetup.cafe.approve.debug-cafe-central"].exists)

    let attended = app.buttons["directChat.meetup.complete"]
    XCTAssertTrue(attended.waitForExistence(timeout: 3))
    scrollTo(attended, in: app)
    attended.tap()
    let reflection = app.buttons["directChat.reflection.toggle"]
    XCTAssertTrue(reflection.waitForExistence(timeout: 3))
    scrollTo(reflection, in: app)
    reflection.tap()

    let startReflection = app.buttons["directChat.reflection.start"]
    XCTAssertTrue(startReflection.waitForExistence(timeout: 3))
    scrollTo(startReflection, in: app)
    captureMatchesScreenshot("private-reflection-ready", in: app)
    startReflection.tap()
    let draft = app.buttons["directChat.reflection.draft"]
    XCTAssertTrue(draft.waitForExistence(timeout: 5))
    scrollTo(draft, in: app)
    draft.tap()
    let candidate = app.buttons["directChat.reflection.candidate.16161616-1616-4616-8616-161616161616"]
    XCTAssertTrue(candidate.waitForExistence(timeout: 3))
    scrollTo(candidate, in: app)
    captureMatchesScreenshot("private-reflection-draft", in: app)
    candidate.tap()
    let confirm = app.buttons["directChat.reflection.confirm"]
    scrollTo(confirm, in: app)
    confirm.tap()
    let confirmed = app.staticTexts["directChat.reflection.confirmed.social_energy"]
    XCTAssertTrue(confirmed.waitForExistence(timeout: 4))
    scrollTo(confirmed, in: app)
    captureMatchesScreenshot("private-reflection-confirmed", in: app)

    let wardHistory = app.buttons["directChat.wardHistory.toggle"]
    scrollTo(wardHistory, in: app)
    wardHistory.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["directChat.wardHistory.event.13131313-1313-4313-8313-131313131313"]
        .waitForExistence(timeout: 3)
    )

    let back = app.buttons["directChat.back"]
    scrollTo(back, in: app)
    back.tap()
    scrollTo(row, in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 3))
    row.tap()
    XCTAssertTrue(app.staticTexts["directChat.meetup.noReservation"].waitForExistence(timeout: 4))
    let restoredReflection = app.buttons["directChat.reflection.toggle"]
    XCTAssertTrue(restoredReflection.waitForExistence(timeout: 3))
    scrollTo(restoredReflection, in: app)
    restoredReflection.tap()
    XCTAssertTrue(app.staticTexts["directChat.reflection.version"].waitForExistence(timeout: 4))
    XCTAssertTrue(app.staticTexts["directChat.reflection.confirmed.social_energy"].waitForExistence(timeout: 3))
  }

  func testJudgeCounterpartSimulatesMeetupWithHonestReflectionCopy() {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-native-journey", "--wingward-judge-counterpart-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    app.buttons["nativeHub.directChats"].tap()
    let row = app.buttons["directChats.row.CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"]
    scrollTo(row, in: app)
    row.tap()
    let disclosure = app.staticTexts["directChat.meetup.simulatedCounterpart"]
    XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
    XCTAssertTrue(disclosure.label.contains("No real meeting takes place"))
    let intent = app.buttons["directChat.meetup.intent.yes"]
    scrollTo(intent, in: app)
    intent.tap()
    let rough = app.buttons["directChat.meetup.manual.weekends"]
    XCTAssertTrue(rough.waitForExistence(timeout: 4))
    scrollTo(rough, in: app)
    rough.tap()
    let time = app.buttons["directChat.meetup.time.12121212-1212-4212-8212-121212121212"]
    XCTAssertTrue(time.waitForExistence(timeout: 4))
    scrollTo(time, in: app)
    time.tap()
    let simulate = app.buttons["directChat.meetup.simulateCompletion"]
    XCTAssertTrue(simulate.waitForExistence(timeout: 4))
    XCTAssertFalse(app.buttons["directChat.meetup.complete"].exists)
    scrollTo(simulate, in: app)
    captureMatchesScreenshot("judge-simulated-meetup-confirmed", in: app)
    simulate.tap()
    let reflection = app.buttons["directChat.reflection.toggle"]
    XCTAssertTrue(reflection.waitForExistence(timeout: 4))
    scrollTo(reflection, in: app)
    reflection.tap()
    let reflectionDisclosure = app.staticTexts["directChat.reflection.simulatedCounterpart"]
    XCTAssertTrue(reflectionDisclosure.waitForExistence(timeout: 4))
    scrollTo(reflectionDisclosure, in: app)
    captureMatchesScreenshot("judge-simulated-meetup-reflection", in: app)
  }

  func testDebugNativeJourneyMeetupStaleRevisionRefreshesBeforeRetry() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--wingward-native-journey",
      "--wingward-chat-meetup-stale-once",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
    ]
    app.launch()
    app.buttons["nativeHub.directChats"].tap()
    let row = app.buttons["directChats.row.CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"]
    scrollTo(row, in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 3))
    row.tap()

    let intent = app.buttons["directChat.meetup.intent.yes"]
    XCTAssertTrue(intent.waitForExistence(timeout: 4))
    scrollTo(intent, in: app)
    intent.tap()
    let notice = app.staticTexts["directChat.meetup.notice"]
    XCTAssertTrue(notice.waitForExistence(timeout: 4))
    XCTAssertTrue(notice.label.contains("meetup changed"))
    XCTAssertTrue(app.buttons["directChat.meetup.refresh"].exists)
  }

  func testDebugNativeJourneyChatRequestStateSurvivesCreateAndAcceptRefresh() {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-native-journey", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    app.buttons["nativeHub.directChats"].tap()

    let requestReview = app.buttons["directChats.requests"]
    XCTAssertTrue(requestReview.waitForExistence(timeout: 3))
    scrollTo(requestReview, in: app)
    requestReview.tap()
    let accept = app.buttons["chatRequests.accept.99999999-9999-4999-8999-999999999999"]
    XCTAssertTrue(accept.waitForExistence(timeout: 3))
    scrollTo(accept, in: app)
    accept.tap()

    let requestState = app.staticTexts["chatsDebugFixture.requestState"]
    XCTAssertTrue(requestState.waitForExistence(timeout: 3))
    let acceptedState = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS %@", "accepted"),
      object: requestState
    )
    XCTAssertEqual(XCTWaiter.wait(for: [acceptedState], timeout: 3), .completed)

    let partnerWard = app.buttons["chatsDebugFixture.partnerWard"]
    XCTAssertTrue(partnerWard.waitForExistence(timeout: 3))
    scrollTo(partnerWard, in: app)
    partnerWard.tap()
    let requestButton = app.buttons["partnerWard.requestDirectChat"]
    XCTAssertTrue(requestButton.waitForExistence(timeout: 3))
    scrollTo(requestButton, in: app)
    requestButton.tap()

    let create = app.buttons["directChatRequest.submit"]
    XCTAssertTrue(create.waitForExistence(timeout: 3))
    scrollTo(create, in: app)
    create.tap()
    let requestSheetDismissed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: create
    )
    XCTAssertEqual(XCTWaiter.wait(for: [requestSheetDismissed], timeout: 3), .completed)
    let back = app.buttons["partnerWard.back"]
    XCTAssertTrue(back.waitForExistence(timeout: 3))
    back.tap()
    XCTAssertTrue(requestState.waitForExistence(timeout: 3))
    let pendingState = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS %@", "pending"),
      object: requestState
    )
    XCTAssertEqual(XCTWaiter.wait(for: [pendingState], timeout: 3), .completed)
  }

  func testDebugNativeJourneyVoiceInterviewsGenerateAndConfirm() {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-native-journey", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    app.buttons["nativeHub.voiceProfile"].tap()

    for (index, persona) in ["virtual_similar", "virtual_complementary", "virtual_discovery"].enumerated() {
      let start = app.buttons["voiceProfile.start.\(persona)"]
      XCTAssertTrue(start.waitForExistence(timeout: 3), persona)
      start.tap()
      if index < 2 {
        XCTAssertTrue(
          app.descendants(matching: .any)["voiceProfile.completed.\(persona)"]
            .waitForExistence(timeout: 3),
          persona
        )
      }
    }

    let generate = app.buttons["voiceProfile.generateProfile"]
    XCTAssertTrue(generate.waitForExistence(timeout: 3))
    generate.tap()
    let confirm = app.buttons["voiceProfile.confirmProfile"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 3))
    confirm.tap()
    XCTAssertTrue(app.buttons["voiceProfile.continue"].waitForExistence(timeout: 3))
    captureMatchesScreenshot("native-voice-profile-confirmed", in: app)
  }

  func testDebugProfileRevisionKeepsOldDraftUnconfirmedUntilFreshDraftLoads() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--wingward-native-journey",
      "--wingward-native-profile-revision",
      "-AppleLanguages",
      "(en)",
      "-AppleLocale",
      "en_US"
    ]
    app.launch()
    app.buttons["nativeHub.voiceProfile"].tap()

    let signature = app.staticTexts["voiceProfile.signature"]
    XCTAssertTrue(signature.waitForExistence(timeout: 3))
    XCTAssertEqual(signature.label, "An older debug profile, preserved for review.")

    let createNew = app.buttons["voiceProfile.createNewProfileFromThree"]
    XCTAssertTrue(createNew.waitForExistence(timeout: 3))
    XCTAssertTrue(createNew.label.contains("Create a new profile from all 3 interviews"))
    XCTAssertFalse(app.buttons["voiceProfile.confirmProfile"].exists)

    createNew.tap()
    let replacementLoaded = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "A fresh debug profile from all three interviews."),
      object: signature
    )
    XCTAssertEqual(XCTWaiter.wait(for: [replacementLoaded], timeout: 3), .completed)

    let edit = app.buttons["voiceProfile.draft.edit"]
    XCTAssertTrue(edit.waitForExistence(timeout: 3))
    scrollTo(edit, in: app)
    edit.tap()
    let tags = app.textFields["voiceProfile.draft.tags"]
    XCTAssertTrue(tags.waitForExistence(timeout: 3))
    tags.tap()
    // Use the supported keyboard selection event; the edit menu is transient.
    tags.typeKey("a", modifierFlags: .command)
    tags.typeText("Calm, Curious, Kind")
    XCTAssertEqual(tags.value as? String, "Calm, Curious, Kind")
    let bio = app.textViews["voiceProfile.draft.bio"]
    scrollTo(bio, in: app)
    bio.tap()
    bio.typeText("A quiet afternoon.")
    captureMatchesScreenshot("draft-profile-editor", in: app)
    let save = app.buttons["voiceProfile.draft.save"]
    scrollTo(save, in: app)
    save.tap()
    let saved = app.staticTexts["voiceProfile.draft.savedBio"]
    XCTAssertTrue(saved.waitForExistence(timeout: 3))
    XCTAssertEqual(saved.label, "A quiet afternoon.")
    XCTAssertTrue(app.staticTexts["Calm"].exists)
    XCTAssertTrue(app.staticTexts["Curious"].exists)
    XCTAssertTrue(app.staticTexts["Kind"].exists)
    scrollTo(saved, in: app)
    captureMatchesScreenshot("draft-profile-saved", in: app)

    let confirm = app.buttons["voiceProfile.confirmProfile"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 3))
    confirm.tap()
    XCTAssertTrue(app.buttons["voiceProfile.continue"].waitForExistence(timeout: 3))
  }

  func testDebugNativeJourneyMeetupIntentAndBillingRestore() {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-native-journey", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()

    app.buttons["nativeHub.meetups"].tap()
    let intent = app.buttons["meetup.intent"]
    XCTAssertTrue(intent.waitForExistence(timeout: 3))
    intent.tap()
    XCTAssertTrue(app.descendants(matching: .any)["meetup.intentPending"].waitForExistence(timeout: 3))
    let intentRefresh = app.buttons["meetup.intentPending.refresh"]
    XCTAssertTrue(intentRefresh.waitForExistence(timeout: 3))
    intentRefresh.tap()
    XCTAssertTrue(app.descendants(matching: .any)["meetup.intentPending"].waitForExistence(timeout: 3))
    app.navigationBars.buttons.element(boundBy: 0).tap()

    app.buttons["nativeHub.billing"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["billing.status"].waitForExistence(timeout: 3))
    app.buttons["billing.restore"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["billing.notice"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.descendants(matching: .any)["billing.manageSubscriptions"].exists)
    captureMatchesScreenshot("native-billing-restore", in: app)
  }

  func testDebugNativeJourneyMeetupCandidateSelectionConfirms() {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-native-journey", "--wingward-native-meetup-proposed"]
    app.launch()
    app.buttons["nativeHub.meetups"].tap()
    let candidate = app.buttons["meetup.proposal.0"]
    XCTAssertTrue(candidate.waitForExistence(timeout: 3))
    candidate.tap()
    XCTAssertTrue(app.descendants(matching: .any)["meetup.confirmed"].waitForExistence(timeout: 3))
    captureMatchesScreenshot("native-meetup-confirmed", in: app)
  }

  func testDebugNativeJourneySafetyReportBlockAndDeletion() {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-native-journey", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    app.buttons["nativeHub.safetyAccount"].tap()

    let report = app.buttons["safety.report"]
    XCTAssertTrue(report.waitForExistence(timeout: 3))
    report.tap()
    XCTAssertTrue(app.buttons["safety.report.submit"].waitForExistence(timeout: 3))
    app.buttons["safety.report.submit"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["safety.reportSubmitted"].waitForExistence(timeout: 3))

    let block = app.buttons["safety.block"]
    XCTAssertTrue(block.waitForExistence(timeout: 3))
    block.tap()
    let blockConfirmation = app.buttons.matching(identifier: "safety.block.confirm").firstMatch
    XCTAssertTrue(blockConfirmation.waitForExistence(timeout: 2))
    blockConfirmation.tap()
    XCTAssertTrue(app.descendants(matching: .any)["safety.contentHidden"].waitForExistence(timeout: 3))
    captureMatchesScreenshot("native-safety-blocked", in: app)

    let delete = app.buttons["accountDeletion.delete"]
    XCTAssertTrue(delete.waitForExistence(timeout: 3))
    delete.tap()
    let deletionConfirmation = app.buttons.matching(identifier: "accountDeletion.confirm").firstMatch
    XCTAssertTrue(deletionConfirmation.waitForExistence(timeout: 2))
    deletionConfirmation.tap()
    XCTAssertTrue(app.descendants(matching: .any)["accountDeletion.success"].waitForExistence(timeout: 3))
    captureMatchesScreenshot("native-account-deleted", in: app)
  }

  func testReferenceJourneyTraversesPreviewFlow() {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-reference-journey"]
    app.launch()

    let loginContinue = app.buttons["reference.login.continue"]
    XCTAssertTrue(loginContinue.waitForExistence(timeout: 2))
    captureReferenceScreenshot("reference-01-login", in: app)
    tapReferenceButton("reference.login.continue", in: app)

    let profileContinue = app.buttons["reference.profile.continue"]
    XCTAssertTrue(profileContinue.waitForExistence(timeout: 2))
    captureReferenceScreenshot("reference-02-setup-profile", in: app)
    tapReferenceButton("reference.profile.continue", in: app)

    let quizContinue = app.buttons["reference.quiz.continue"]
    XCTAssertTrue(quizContinue.waitForExistence(timeout: 2))
    captureReferenceScreenshot("reference-03-setup-quiz", in: app)
    tapReferenceButton("reference.quiz.continue", in: app)

    let wardContinue = app.buttons["reference.ward.viewNext"]
    XCTAssertTrue(wardContinue.waitForExistence(timeout: 2))
    captureReferenceScreenshot("reference-04-ward-intro", in: app)
    tapReferenceButton("reference.ward.viewNext", in: app)
    tapReferenceButton("reference.ward.viewNext", in: app)
    tapReferenceButton("reference.ward.viewNext", in: app)

    let insightContinue = app.buttons["reference.insight.continue"]
    XCTAssertTrue(insightContinue.waitForExistence(timeout: 2))
    captureReferenceScreenshot("reference-05-insight", in: app)
    tapReferenceButton("reference.insight.continue", in: app)

    let candidateButton = app.buttons["reference.home.candidate.aoi"]
    XCTAssertTrue(candidateButton.waitForExistence(timeout: 2))
    captureReferenceScreenshot("reference-06-home", in: app)
    tapReferenceButton("reference.home.candidate.aoi", in: app)

    let candidateOpenChat = app.buttons["reference.candidate.openChat"]
    XCTAssertTrue(candidateOpenChat.waitForExistence(timeout: 2))
    captureReferenceScreenshot("reference-08-candidate-detail", in: app)
    tapReferenceButton("reference.candidate.openChat", in: app)

    let modePicker = app.descendants(matching: .any)["reference.chat.modePicker"]
    XCTAssertTrue(modePicker.waitForExistence(timeout: 2))
    captureReferenceScreenshot("reference-07-chat-ward", in: app)

    let personTab = app.buttons["自分"]
    XCTAssertTrue(personTab.waitForExistence(timeout: 2))
    personTab.tap()

    let draft = app.textFields["reference.chat.draft"]
    XCTAssertTrue(draft.waitForExistence(timeout: 2))
    captureReferenceScreenshot("reference-09-chat-person", in: app)
    draft.tap()
    draft.typeText("テストメッセージ")
    tapReferenceButton("reference.chat.send", in: app)
    let unavailableMessage = app.staticTexts["送信機能はまだ接続されていません。下書きは保持されています。"]
    XCTAssertTrue(unavailableMessage.waitForExistence(timeout: 2))
    captureReferenceScreenshot("reference-10-chat-person-unavailable", in: app)
  }

  func testReferenceProfileEditorCancelAndSaveAreSessionLocal() {
    let app = launchReferenceHome()
    let profile = app.buttons["reference.header.profile"]
    XCTAssertTrue(profile.waitForExistence(timeout: 2))

    profile.tap()
    let selectedPreference = app.buttons["reference.profile.preference.selected"]
    XCTAssertTrue(selectedPreference.waitForExistence(timeout: 2))
    captureReferenceScreenshot("reference-11-profile-editor", in: app)

    app.buttons["reference.profile.preference.noAnswer"].tap()
    XCTAssertFalse(app.buttons["reference.profile.preferred.woman"].exists)
    app.buttons["reference.profile.location.notSet"].tap()
    app.buttons["reference.profile.back"].tap()

    profile.tap()
    XCTAssertTrue(app.buttons["reference.profile.preference.selected"].isSelected)
    XCTAssertTrue(app.buttons["reference.profile.location.station"].isSelected)

    app.buttons["reference.profile.preference.noAnswer"].tap()
    app.buttons["reference.profile.preference.selected"].tap()
    let preferredWoman = app.buttons["reference.profile.preferred.woman"]
    XCTAssertTrue(preferredWoman.waitForExistence(timeout: 2))
    preferredWoman.tap()
    let stationPicker = app.descendants(matching: .any)["reference.profile.station"]
    XCTAssertTrue(stationPicker.waitForExistence(timeout: 2))
    stationPicker.tap()
    let shibuya = app.buttons["渋谷駅"]
    if shibuya.waitForExistence(timeout: 1) {
      shibuya.tap()
    } else {
      let shibuyaText = app.staticTexts["渋谷駅"]
      XCTAssertTrue(shibuyaText.waitForExistence(timeout: 2))
      shibuyaText.tap()
    }
    XCTAssertTrue(app.buttons["reference.profile.continue"].isEnabled)
    captureReferenceScreenshot("reference-12-profile-edited", in: app)
    app.buttons["reference.profile.continue"].tap()

    XCTAssertTrue(profile.waitForExistence(timeout: 2))
    captureReferenceScreenshot("reference-13-profile-saved", in: app)
    profile.tap()
    XCTAssertTrue(app.buttons["reference.profile.preference.selected"].isSelected)
    XCTAssertTrue(app.buttons["reference.profile.preferred.woman"].isSelected)
    XCTAssertTrue(app.buttons["reference.profile.location.station"].isSelected)
    XCTAssertTrue(app.staticTexts["生活エリア: 渋谷区"].exists)
    app.buttons["reference.profile.back"].tap()
  }

  func testProductionExplicitPreferenceChoiceRevealsGenders() {
    let app = launch(in: "success")
    openYou(in: app)
    app.buttons["production.you.setting.matchPreferences"].tap()
    let noAnswer = app.buttons["production.onboarding.preference.noAnswer"]
    scrollTo(noAnswer, in: app)
    XCTAssertTrue(noAnswer.waitForExistence(timeout: 2))
    noAnswer.tap()
    XCTAssertFalse(app.buttons["production.onboarding.preference.woman"].exists)

    let choosePreferences = app.buttons["production.onboarding.preference.selected"]
    XCTAssertTrue(choosePreferences.waitForExistence(timeout: 2))
    choosePreferences.tap()
    XCTAssertTrue(app.buttons["production.onboarding.preference.woman"].waitForExistence(timeout: 2))
    captureReferenceScreenshot("settings-preferences-selected", in: app)
  }

  func testProductionConversationQuizUsesOneQuestionStepsAndExplicitSave() {
    let app = launchQuiz(in: "success")
    openYou(in: app)
    let openQuiz = app.buttons["production.you.quiz"]
    scrollTo(openQuiz, in: app)
    XCTAssertTrue(openQuiz.waitForExistence(timeout: 2))
    openQuiz.tap()

    for questionNumber in 1...9 {
      let question = app.descendants(matching: .any)[
        "onboarding.quiz.question.q\(questionNumber)"
      ]
      XCTAssertTrue(question.waitForExistence(timeout: 2))
      let option = app.buttons["onboarding.quiz.option.q\(questionNumber).a"]
      XCTAssertTrue(option.exists)
      option.tap()
      let next = app.buttons["onboarding.quiz.next"]
      XCTAssertTrue(next.isEnabled)
      next.tap()
    }

    XCTAssertTrue(
      app.descendants(matching: .any)["onboarding.quiz.question.q10"]
        .waitForExistence(timeout: 2)
    )
    let finalOption = app.buttons["onboarding.quiz.option.q10.a"]
    XCTAssertTrue(finalOption.exists)
    finalOption.tap()
    let save = app.buttons["onboarding.quiz.save"]
    XCTAssertTrue(save.waitForExistence(timeout: 2))
    XCTAssertTrue(save.isEnabled)
    save.tap()

    XCTAssertTrue(
      app.descendants(matching: .any)["onboarding.quiz.saved"]
        .waitForExistence(timeout: 2)
    )
    captureReferenceScreenshot("settings-conversation-quiz-saved", in: app)
  }

  func testProductionConversationQuizRetryIsFixtureOnly() {
    let app = launchQuiz(in: "retry")
    openYou(in: app)
    let openQuiz = app.buttons["production.you.quiz"]
    scrollTo(openQuiz, in: app)
    XCTAssertTrue(openQuiz.waitForExistence(timeout: 2))
    openQuiz.tap()

    XCTAssertTrue(app.staticTexts["クイズを読み込めませんでした"].waitForExistence(timeout: 2))
    let retry = app.buttons["onboarding.quiz.retry"]
    XCTAssertTrue(retry.exists)
    retry.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["onboarding.quiz.question.q1"]
        .waitForExistence(timeout: 2)
    )
  }

  func testProductionConversationQuizDirtyDismissalKeepsDraftUntilDiscard() {
    let app = launchQuiz(in: "success")
    openYou(in: app)
    let openQuiz = app.buttons["production.you.quiz"]
    scrollTo(openQuiz, in: app)
    XCTAssertTrue(openQuiz.waitForExistence(timeout: 2))
    openQuiz.tap()

    let q1Option = app.buttons["onboarding.quiz.option.q1.a"]
    XCTAssertTrue(q1Option.waitForExistence(timeout: 2))
    q1Option.tap()
    app.buttons["onboarding.quiz.next"].tap()

    let q2Option = app.buttons["onboarding.quiz.option.q2.a"]
    XCTAssertTrue(q2Option.waitForExistence(timeout: 2))
    q2Option.tap()
    app.buttons["onboarding.quiz.previous"].tap()
    XCTAssertTrue(q1Option.waitForExistence(timeout: 2))
    XCTAssertTrue(q1Option.isSelected)
    captureReferenceScreenshot("settings-conversation-quiz-dirty-before-dismissal", in: app)

    app.buttons["onboarding.quiz.back"].tap()
    XCTAssertTrue(app.staticTexts["回答を破棄しますか？"].waitForExistence(timeout: 2))
    let keepEditing = app.buttons["回答を続ける"]
    XCTAssertTrue(keepEditing.waitForExistence(timeout: 2))
    keepEditing.tap()

    XCTAssertTrue(q1Option.waitForExistence(timeout: 2))
    XCTAssertTrue(q1Option.isSelected)

    app.buttons["onboarding.quiz.back"].tap()
    let discard = app.buttons["破棄する"]
    XCTAssertTrue(discard.waitForExistence(timeout: 2))
    discard.tap()
    XCTAssertTrue(openQuiz.waitForExistence(timeout: 2))
  }

  func testPasswordResetRequestIsReachableWithoutNetwork() {
    let app = launch(in: "signedOut")
    app.buttons["auth.signIn"].tap()
    let forgotPassword = app.buttons["signin.forgotPassword"]
    XCTAssertTrue(forgotPassword.waitForExistence(timeout: 2))
    forgotPassword.tap()

    let email = app.textFields["passwordReset.email"]
    XCTAssertTrue(email.waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["passwordReset.submit"].exists)
  }

  func testPasswordResetCompletionIsReachableWithoutNetwork() {
    let app = launch(in: "passwordResetRequested")
    XCTAssertTrue(
      app.staticTexts["If an account uses that address, we'll send a password reset link. Check your inbox and spam folder."]
        .waitForExistence(timeout: 2)
    )
    XCTAssertTrue(
      app.buttons["passwordResetRequested.backToSignIn"].waitForExistence(timeout: 2)
    )
  }

  func testPasswordResetRequestFormIsReachableWithoutNetwork() {
    let app = launch(in: "passwordResetRequest")
    let submit = app.buttons["passwordReset.submit"]
    XCTAssertTrue(submit.waitForExistence(timeout: 2))
    XCTAssertTrue(app.textFields["passwordReset.email"].exists)
  }

  func testPasswordRecoveryStateIsReachableWithoutNetwork() {
    let app = launch(in: "passwordRecovery")

    XCTAssertTrue(app.secureTextFields["passwordRecovery.password"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.secureTextFields["passwordRecovery.passwordConfirmation"].exists)
    let submit = app.buttons["passwordRecovery.submit"]
    XCTAssertTrue(submit.exists)
  }

  private func launchReferenceHome() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-reference-journey"]
    app.launch()
    tapReferenceButton("reference.login.continue", in: app)
    tapReferenceButton("reference.profile.continue", in: app)
    tapReferenceButton("reference.quiz.continue", in: app)
    tapReferenceButton("reference.ward.viewNext", in: app)
    tapReferenceButton("reference.ward.viewNext", in: app)
    tapReferenceButton("reference.ward.viewNext", in: app)
    tapReferenceButton("reference.insight.continue", in: app)
    XCTAssertTrue(app.buttons["reference.home.candidate.aoi"].waitForExistence(timeout: 2))
    return app
  }

  private func tapReferenceButton(_ identifier: String, in app: XCUIApplication) {
    let button = app.buttons[identifier]
    XCTAssertTrue(button.waitForExistence(timeout: 2))

    var attempts = 0
    while !button.isHittable && attempts < 5 {
      app.swipeUp()
      attempts += 1
    }

    XCTAssertTrue(button.isHittable)
    button.tap()
  }

  private func captureReferenceScreenshot(_ name: String, in app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func captureMatchesScreenshot(_ name: String, in app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func openYou(in app: XCUIApplication) {
    let tab = app.buttons["You"]
    XCTAssertTrue(tab.waitForExistence(timeout: 3))
    tab.tap()
  }

  private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<10 {
      if element.exists && element.isHittable { return }
      app.swipeUp()
    }
  }

  private func launchMatches(
    in scenario: String,
    extraArguments: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--wingward-matches-fixture",
      scenario,
    ] + extraArguments + [
      "-wingward.displayLanguage",
      "en",
      "-AppleLanguages",
      "(en)",
      "-AppleLocale",
      "en_US",
    ]
    app.launch()
    return app
  }

  private func launchProductionFixture(extraArguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--wingward-matches-fixture",
      "success",
      "--wingward-production-callback-fixture",
    ] + extraArguments + [
      "-wingward.displayLanguage",
      "en",
      "-AppleLanguages",
      "(en)",
      "-AppleLocale",
      "en_US",
    ]
    app.launch()
    return app
  }

  private func openProductionFirstMatch(in app: XCUIApplication) {
    let first = app.descendants(matching: .any)[
      "production.words.match.11111111-1111-1111-1111-111111111111"
    ]
    XCTAssertTrue(first.waitForExistence(timeout: 3))
    first.tap()
  }

  private func launchQuiz(in scenario: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-quiz-fixture", scenario, "-wingward.displayLanguage", "ja"]
    app.launch()
    return app
  }

  private func launch(in state: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--wingward-debug-state", state, "-wingward.displayLanguage", "en", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    return app
  }
}
