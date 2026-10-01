import XCTest
@testable import Wingward

final class NativeFeatureIntegrationTests: XCTestCase {
  @MainActor
  func testRouteViewForwardsOwnerBoundSafetyCallbacks() {
    let ownerID = "owner-a"
    let route = AppRoute.directChat(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!)
    let targetID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    var receivedOwnerID: String?
    var receivedRoute: AppRoute?
    var receivedSafetyTarget: (UUID, ReportContext)?

    let integration = NativeFeatureIntegration(
      route: { ownerID, route, callbacks in
        receivedOwnerID = ownerID
        receivedRoute = route
        callbacks.onOpenReportForMatch?(targetID, .directChat)
        return nil
      }
    )

    let destination = integration.routeView(
      route,
      ownerID: ownerID,
      callbacks: NativeFeatureCallbacks(
        onOpenReportForMatch: { targetID, context in
          receivedSafetyTarget = (targetID, context)
        }
      )
    )

    XCTAssertNil(destination)
    XCTAssertEqual(receivedOwnerID, ownerID)
    XCTAssertEqual(receivedRoute, route)
    XCTAssertEqual(receivedSafetyTarget?.0, targetID)
    XCTAssertEqual(receivedSafetyTarget?.1, .directChat)
  }

  @MainActor
  func testRouteViewRejectsEmptyOwnerBeforeInvokingFactory() {
    var factoryInvoked = false
    let integration = NativeFeatureIntegration(
      route: { _, _, _ in
        factoryInvoked = true
        return nil
      }
    )

    XCTAssertNil(integration.routeView(.directChat(UUID()), ownerID: ""))
    XCTAssertFalse(factoryInvoked)
  }

  func testFeatureRoutesRequireServerConfirmedOnboarding() {
    let route = AppRoute.directChat(UUID())

    XCTAssertFalse(
      NativeFeatureRouteGate.allows(
        route,
        isAuthenticated: true,
        ageVerified: true,
        onboardingCompleted: false
      )
    )
    XCTAssertTrue(
      NativeFeatureRouteGate.allows(
        route,
        isAuthenticated: true,
        ageVerified: true,
        onboardingCompleted: true
      )
    )
  }

  func testSettingsRouteRemainsAvailableBeforeOnboardingCompletion() {
    XCTAssertTrue(
      NativeFeatureRouteGate.allows(
        .settings,
        isAuthenticated: true,
        ageVerified: true,
        onboardingCompleted: false
      )
    )
  }

  func testAuthenticationAndAgeRoutesNeverOpenAsFeatureDestinations() {
    XCTAssertFalse(
      NativeFeatureRouteGate.allows(
        .authentication,
        isAuthenticated: true,
        ageVerified: true,
        onboardingCompleted: true
      )
    )
    XCTAssertFalse(
      NativeFeatureRouteGate.allows(
        .ageGate,
        isAuthenticated: true,
        ageVerified: true,
        onboardingCompleted: true
      )
    )
  }
}
