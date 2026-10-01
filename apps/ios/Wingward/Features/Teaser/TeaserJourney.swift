import SwiftUI

#if DEBUG

/// The complete, deterministic route order used by the local teaser.
public enum TeaserJourneyRoute: Int, CaseIterable, Equatable, Identifiable {
    case onboardingQuiz
    case speedDateIntro
    case speedDateResult
    case profileReview
    case foxCompletion
    case signedInTabs
    case rankedMatches
    case foxConversationWaiting
    case foxConversationResult
    case chatPreview
    case freeMeetIntent
    case identityExplanation
    case meetupPreferences
    case candidateMatches
    case confirmedSafetyGuide
    case quotaPaywall
    case settings

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .onboardingQuiz: return "Welcome"
        case .speedDateIntro: return "Speed-date preview"
        case .speedDateResult: return "Speed-date result"
        case .profileReview: return "Profile review"
        case .foxCompletion: return "Fox completion"
        case .signedInTabs: return "Your spaces"
        case .rankedMatches: return "Ranked matches"
        case .foxConversationWaiting: return "Fox is thinking"
        case .foxConversationResult: return "Fox conversation"
        case .chatPreview: return "Chat preview"
        case .freeMeetIntent: return "Free meet"
        case .identityExplanation: return "Identity"
        case .meetupPreferences: return "Meetup preferences"
        case .candidateMatches: return "Meetup candidates"
        case .confirmedSafetyGuide: return "Confirmed meetup"
        case .quotaPaywall: return "Quota options"
        case .settings: return "Settings"
        }
    }
}

// Friendly aliases keep the route model easy to discover from tests and previews.
public typealias TeaserJourneyStep = TeaserJourneyRoute
public typealias TeaserRoute = TeaserJourneyRoute

public enum TeaserQuizOption: String, CaseIterable, Identifiable {
    case friendship
    case activityPartner
    case conversation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .friendship: return "Make a new friend"
        case .activityPartner: return "Find an activity partner"
        case .conversation: return "Have a good conversation"
        }
    }
}

public enum TeaserMeetupPreference: String, CaseIterable, Identifiable {
    case daytime
    case evening
    case weekend

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .daytime: return "Daytime"
        case .evening: return "Early evening"
        case .weekend: return "Weekend"
        }
    }
}

public struct TeaserRankedMatch: Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let context: String
    public let rank: Int

    public init(id: String, displayName: String, context: String, rank: Int) {
        self.id = id
        self.displayName = displayName
        self.context = context
        self.rank = rank
    }
}

public struct TeaserCandidate: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

@MainActor
public final class TeaserJourneyModel: ObservableObject {
    public nonisolated static let fixtureLocalizedPrice = "FIXTURE_LOCALIZED_PRICE"

    @Published public private(set) var route: TeaserJourneyRoute
    @Published public private(set) var selectedQuizOption: TeaserQuizOption?
    @Published public private(set) var selectedMeetupPreference: TeaserMeetupPreference?
    @Published public private(set) var selectedCandidate: TeaserCandidate?
    @Published public private(set) var restoreRequestCount = 0

    public let localizedFixturePrice: String

    /// These fixtures intentionally contain no remote data, credentials, or personal information.
    public let rankedMatches: [TeaserRankedMatch] = [
        TeaserRankedMatch(id: "match-a", displayName: "Match A", context: "Enjoys trying small creative projects", rank: 1),
        TeaserRankedMatch(id: "match-b", displayName: "Match B", context: "Likes relaxed weekend walks", rank: 2),
        TeaserRankedMatch(id: "match-c", displayName: "Match C", context: "Looks for thoughtful conversations", rank: 3)
    ]

    /// The meetup surface is deliberately fixed at three cards for this teaser.
    public let candidateCards: [TeaserCandidate] = [
        TeaserCandidate(id: "candidate-a", title: "Candidate A", detail: "A calm daytime coffee idea"),
        TeaserCandidate(id: "candidate-b", title: "Candidate B", detail: "A low-key early evening idea"),
        TeaserCandidate(id: "candidate-c", title: "Candidate C", detail: "A casual weekend idea")
    ]

    public init(localizedFixturePrice: String = TeaserJourneyModel.fixtureLocalizedPrice) {
        self.route = .onboardingQuiz
        self.localizedFixturePrice = localizedFixturePrice
    }

    public var currentRoute: TeaserJourneyRoute { route }

    public var didRequestRestore: Bool { restoreRequestCount > 0 }

    public var routeOrder: [TeaserJourneyRoute] { TeaserJourneyRoute.allCases }

    public func nextRoute(after route: TeaserJourneyRoute) -> TeaserJourneyRoute? {
        guard let nextIndex = TeaserJourneyRoute.allCases.firstIndex(of: route).map({ $0 + 1 }),
              nextIndex < TeaserJourneyRoute.allCases.count else {
            return nil
        }
        return TeaserJourneyRoute.allCases[nextIndex]
    }

    public func advance() {
        if route == .confirmedSafetyGuide {
            route = .settings
            return
        }
        guard let next = nextRoute(after: route) else { return }
        route = next
    }

    public func navigate(to destination: TeaserJourneyRoute) {
        route = destination
    }

    public func chooseQuizOption(_ option: TeaserQuizOption) {
        selectedQuizOption = option
        route = .speedDateIntro
    }

    public func chooseFreeMeetIntent() {
        // A free-meet intent always continues through identity and preference education.
        route = .identityExplanation
    }

    public func chooseMeetupPreference(_ preference: TeaserMeetupPreference) {
        selectedMeetupPreference = preference
        route = .candidateMatches
    }

    public func chooseCandidate(_ candidate: TeaserCandidate) {
        guard candidateCards.contains(candidate) else { return }
        selectedCandidate = candidate
        route = .confirmedSafetyGuide
    }

    public func requestRestore() {
        // This method is called only by the visible restore button; entering the paywall does not call it.
        restoreRequestCount += 1
    }

    public func cancelPaywall() {
        route = .settings
    }

    public func reset() {
        route = .onboardingQuiz
        selectedQuizOption = nil
        selectedMeetupPreference = nil
        selectedCandidate = nil
        restoreRequestCount = 0
    }
}

public struct TeaserJourney: View {
    @StateObject private var model: TeaserJourneyModel
    @State private var showReferenceJourney = false

    public init(localizedFixturePrice: String = TeaserJourneyModel.fixtureLocalizedPrice) {
        _model = StateObject(wrappedValue: TeaserJourneyModel(localizedFixturePrice: localizedFixturePrice))
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.03, green: 0.05, blue: 0.12),
                        Color(red: 0.10, green: 0.08, blue: 0.20)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                TeaserJourneySurface(model: model) {
                    showReferenceJourney = true
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(Color(red: 1.0, green: 0.82, blue: 0.12))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showReferenceJourney) {
            ReferenceJourney()
                .presentationDragIndicator(.visible)
        }
    }
}

public typealias TeaserJourneyView = TeaserJourney

private struct TeaserJourneySurface: View {
    @ObservedObject var model: TeaserJourneyModel
    let onOpenReferenceJourney: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.12))
                    Text("WINGWARD")
                        .font(.caption.weight(.bold))
                        .tracking(2)
                    Spacer()
                    Text("\(model.route.rawValue + 1) / \(model.routeOrder.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button("Speed-dating SwiftUI preview", action: onOpenReferenceJourney)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.12))
                    .accessibilityIdentifier("teaser.openReferenceJourney")
                    .frame(minHeight: 44)

                ProgressView(value: Double(model.route.rawValue + 1), total: Double(model.routeOrder.count))
                    .tint(Color(red: 1.0, green: 0.82, blue: 0.12))

                Text(model.route.title)
                    .font(.largeTitle.weight(.bold))

                Group {
                    switch model.route {
                    case .onboardingQuiz:
                        onboarding
                    case .speedDateIntro:
                        standardPage("Try a short, local speed-date preview before you decide what feels right.", buttonTitle: "Start preview", action: model.advance)
                    case .speedDateResult:
                        standardPage("The preview is ready. Fox found a simple opening for your next conversation.", buttonTitle: "Review profile", action: model.advance)
                    case .profileReview:
                        standardPage("Review the signals you chose for this fixture profile. Nothing is sent anywhere.", buttonTitle: "Complete review", action: model.advance)
                    case .foxCompletion:
                        standardPage("Fox completed the starter flow. Your signed-in spaces are ready to explore.", buttonTitle: "Open signed-in spaces", action: model.advance)
                    case .signedInTabs:
                        signedInTabs
                    case .rankedMatches:
                        rankedMatches
                    case .foxConversationWaiting:
                        standardPage("Fox is preparing a conversation prompt from the local fixture.", buttonTitle: "View result", action: model.advance)
                    case .foxConversationResult:
                        standardPage("Here is a gentle conversation opening you can preview.", buttonTitle: "Open chat preview", action: model.advance)
                    case .chatPreview:
                        chatPreview
                    case .freeMeetIntent:
                        freeMeetIntent
                    case .identityExplanation:
                        identityExplanation
                    case .meetupPreferences:
                        meetupPreferences
                    case .candidateMatches:
                        candidates
                    case .confirmedSafetyGuide:
                        confirmedSafetyGuide
                    case .quotaPaywall:
                        quotaPaywall
                    case .settings:
                        settings
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 22)
        }
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What would make a new connection feel useful?")
            ForEach(TeaserQuizOption.allCases) { option in
                journeyButton(option.title, accessibilityLabel: "Choose " + option.title) {
                    model.chooseQuizOption(option)
                }
            }
        }
    }

    private var signedInTabs: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Signed-in surfaces")
            journeyButton("Matches tab", accessibilityLabel: "Open matches tab") {
                model.navigate(to: .rankedMatches)
            }
            journeyButton("Chats tab", accessibilityLabel: "Open chats tab") {
                model.navigate(to: .chatPreview)
            }
            journeyButton("Meetups tab", accessibilityLabel: "Open meetups tab") {
                model.navigate(to: .identityExplanation)
            }
            journeyButton("Settings tab", accessibilityLabel: "Open settings tab") {
                model.navigate(to: .settings)
            }
        }
    }

    private var rankedMatches: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A local ranking, shown without numeric ratings.")
                .foregroundStyle(.secondary)
            ForEach(model.rankedMatches) { match in
                VStack(alignment: .leading, spacing: 6) {
                    Text("#" + String(match.rank) + " " + match.displayName)
                        .font(.headline)
                    Text(match.context)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
            journeyButton("Ask Fox for a conversation", accessibilityLabel: "Start Fox conversation") {
                model.advance()
            }
        }
    }

    private var chatPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Chat preview")
                .font(.headline)
            Text("Fox: Start with a small shared interest and see where it goes.")
            journeyButton("Suggest a free meet", accessibilityLabel: "Choose free meet intent") {
                model.advance()
            }
        }
    }

    private var freeMeetIntent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You can explore a free meet flow before choosing any quota option.")
            journeyButton("Continue with free meet", accessibilityLabel: "Continue with free meet") {
                model.chooseFreeMeetIntent()
            }
        }
    }

    private var identityExplanation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Identity helps people understand who is joining a meetup. This fixture explains the step without collecting identity data.")
            journeyButton("Choose meetup preferences", accessibilityLabel: "Continue to meetup preferences") {
                model.advance()
            }
        }
    }

    private var meetupPreferences: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick a broad time preference for the local meetup preview.")
            ForEach(TeaserMeetupPreference.allCases) { preference in
                journeyButton(preference.title, accessibilityLabel: "Choose " + preference.title) {
                    model.chooseMeetupPreference(preference)
                }
            }
        }
    }

    private var candidates: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Three fixture candidates")
                .font(.headline)
            ForEach(model.candidateCards) { candidate in
                VStack(alignment: .leading, spacing: 8) {
                    Text(candidate.title)
                        .font(.headline)
                    Text(candidate.detail)
                        .foregroundStyle(.secondary)
                    journeyButton("Choose " + candidate.title, accessibilityLabel: "Choose " + candidate.title) {
                        model.chooseCandidate(candidate)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var confirmedSafetyGuide: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Meetup confirmed for " + (model.selectedCandidate?.title ?? "the selected candidate") + " in the local fixture.")
                .font(.headline)
            Text("Safety guide: meet in a public place, tell a trusted person, and leave if anything feels uncomfortable.")
            journeyButton("Open settings", accessibilityLabel: "Open settings") {
                model.navigate(to: .settings)
            }
        }
    }

    private var quotaPaywall: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quota options")
                .font(.headline)
            Text("Fixture localized price: " + model.localizedFixturePrice)
            Text(model.didRequestRestore ? "Restore requested in this local fixture." : "Choose an action to continue.")
                .foregroundStyle(.secondary)
            journeyButton("Cancel", accessibilityLabel: "Cancel quota options") {
                model.cancelPaywall()
            }
            journeyButton("Restore", accessibilityLabel: "Restore purchase") {
                model.requestRestore()
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)
            Text("This teaser keeps settings local and uses fixture data only.")
            journeyButton("View premium options", accessibilityLabel: "View premium options") {
                model.navigate(to: .quotaPaywall)
            }
            journeyButton("Back to signed-in spaces", accessibilityLabel: "Back to signed-in spaces") {
                model.navigate(to: .signedInTabs)
            }
        }
    }

    private func standardPage(_ message: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(message)
            journeyButton(buttonTitle, accessibilityLabel: buttonTitle, action: action)
        }
    }

    private func journeyButton(_ title: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 16)
                .background(Color(red: 1.0, green: 0.82, blue: 0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .frame(minWidth: 44, minHeight: 44)
    }
}

#endif
