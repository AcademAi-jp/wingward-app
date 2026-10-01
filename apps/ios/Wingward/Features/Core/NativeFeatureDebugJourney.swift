#if DEBUG
import SwiftUI

/// Synthetic navigation only.  Every destination is explicitly labelled as a
/// fixture and has no API, store, account, or purchase side effects.
enum NativeFeatureDebugJourney {
  static let ownerID = UserProfile.fixture.id ?? "fixture-owner"
  static let safetyReconciliationMatchID = UUID(
    uuidString: "11111111-1111-1111-1111-111111111111"
  )!

  static var safetyScenario: SafetyDebugFixtureScenario {
    ProcessInfo.processInfo.arguments.contains("--wingward-production-safety-block-failure")
      ? .blockFailure
      : .success
  }

  static var meetupScenario: MeetupDebugScenario {
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("--wingward-native-meetup-quota") {
      return .quotaExhausted
    }
    if arguments.contains("--wingward-native-meetup-verification-required") {
      return .verificationRequired
    }
    if arguments.contains("--wingward-native-meetup-verifying") {
      return .verifying
    }
    return arguments.contains("--wingward-native-meetup-proposed") ? .proposed : .intent
  }

  static var integration: NativeFeatureIntegration {
    NativeFeatureIntegration(
      directChats: { ownerID, callbacks in
        ChatsDebugFixture.ownerView(ownerID: ownerID, callbacks: callbacks)
      },
      voiceProfile: VoiceProfileDebugFixture.ownerViewFactory(scenario: .interview),
      profilePhoto: WatercolorProfileDebugFixture.ownerViewFactory(),
      meetups: { _, callbacks in
        AnyView(MeetupDebugFixture.makeView(scenario: meetupScenario, callbacks: callbacks))
      },
      meetupForMatch: { _, matchID, callbacks in
        AnyView(
          MeetupDebugFixture.makeView(
            scenario: meetupScenario,
            matchID: matchID,
            callbacks: callbacks
          )
        )
      },
      billing: { ownerID, _ in
        BillingDebugFixture.view(ownerID: ownerID, scenario: .inactive)
      },
      accountSafety: { ownerID, _ in
        SafetyDebugFixture.combinedView(ownerID: ownerID)
      },
      route: { ownerID, route, callbacks in
        switch route {
        case .matchDetail:
          AnyView(NativeFeatureDebugMatchRoute(callbacks: callbacks))
        case .paywall:
          BillingDebugFixture.view(ownerID: ownerID, scenario: .inactive)
        default:
          nil
        }
      },
      matchSafety: { ownerID, _, context, callbacks in
        SafetyDebugFixture.actionView(
          ownerID: ownerID,
          scenario: safetyScenario,
          context: context,
          onBlocked: callbacks.onBlocked,
          onBlockNeedsReconciliation: callbacks.onBlockNeedsReconciliation
        )
      },
      isDebugFixture: true
    )
  }
}

private struct NativeFeatureDebugMatchRoute: View {
  let callbacks: NativeFeatureCallbacks

  var body: some View {
    Button("Open match safety fixture") {
      callbacks.onOpenReportForMatch?(NativeFeatureDebugJourney.safetyReconciliationMatchID, .match)
    }
    .accessibilityIdentifier("production.debugRoute.reportBlock")
  }
}

struct NativeFeatureDebugJourneyView: View {
  let integration: NativeFeatureIntegration

  var body: some View {
    VStack(spacing: 0) {
      Text("DEBUG FIXTURE · synthetic preview · no account changes")
        .font(.caption.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 36)
        .foregroundStyle(ReferencePalette.ink)
        .background(ReferencePalette.yellowSoft)
        .accessibilityIdentifier("nativeJourney.debugFixture")
      NativeFeatureHubView(
        ownerID: NativeFeatureDebugJourney.ownerID,
        integration: integration,
        allowsPostOnboardingFeatures: true
      )
    }
  }
}
#endif
