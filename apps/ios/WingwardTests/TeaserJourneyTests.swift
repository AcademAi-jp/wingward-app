import XCTest
@testable import Wingward

#if DEBUG
@MainActor
final class TeaserJourneyTests: XCTestCase {
    func testRouteOrderIsDeterministic() {
        let expected: [TeaserJourneyRoute] = [
            .onboardingQuiz,
            .speedDateIntro,
            .speedDateResult,
            .profileReview,
            .foxCompletion,
            .signedInTabs,
            .rankedMatches,
            .foxConversationWaiting,
            .foxConversationResult,
            .chatPreview,
            .freeMeetIntent,
            .identityExplanation,
            .meetupPreferences,
            .candidateMatches,
            .confirmedSafetyGuide,
            .quotaPaywall,
            .settings
        ]

        XCTAssertEqual(TeaserJourneyRoute.allCases, expected)
        XCTAssertEqual(TeaserJourneyModel().routeOrder, expected)
    }

    func testFreeMeetIntentNeverRoutesToQuotaPaywall() {
        let model = TeaserJourneyModel()
        model.navigate(to: .freeMeetIntent)

        model.chooseFreeMeetIntent()

        XCTAssertEqual(model.route, .identityExplanation)
        XCTAssertNotEqual(model.route, .quotaPaywall)

        model.advance()
        XCTAssertEqual(model.route, .meetupPreferences)
        XCTAssertNotEqual(model.route, .quotaPaywall)
    }

    func testConfirmedMeetupContinuesToSettingsInsteadOfPaywall() {
        let model = TeaserJourneyModel()
        model.navigate(to: .confirmedSafetyGuide)

        model.advance()

        XCTAssertEqual(model.route, .settings)
        XCTAssertNotEqual(model.route, .quotaPaywall)
    }

    func testThereAreExactlyThreeCandidateCards() {
        let model = TeaserJourneyModel()

        XCTAssertEqual(model.candidateCards.count, 3)
        XCTAssertEqual(Set(model.candidateCards.map(\.id)).count, 3)
    }

    func testRestoreIsUserTriggered() {
        let model = TeaserJourneyModel()
        model.navigate(to: .quotaPaywall)

        XCTAssertEqual(model.restoreRequestCount, 0)
        XCTAssertFalse(model.didRequestRestore)

        model.requestRestore()

        XCTAssertEqual(model.restoreRequestCount, 1)
        XCTAssertTrue(model.didRequestRestore)
        XCTAssertEqual(model.route, .quotaPaywall)
    }

    func testRankedMatchesExposeNoNumericRatingField() {
        let model = TeaserJourneyModel()
        let propertyNames = model.rankedMatches.flatMap { match in
            Mirror(reflecting: match).children.compactMap(\.label)
        }

        XCTAssertFalse(propertyNames.contains { $0.localizedCaseInsensitiveContains("score") })
        XCTAssertFalse(model.rankedMatches.contains { $0.context.localizedCaseInsensitiveContains("score") })
    }
}
#endif
