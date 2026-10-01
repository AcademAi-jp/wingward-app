import SwiftUI

/// Contextual explanation shown at the first Fox result.  The app entry
/// point owns when this sheet is attached; callers invoke
/// `prepareForFirstFoxResult()` only after the server has confirmed N-01.
struct WingwardNotificationPermissionPrompt: View {
  let onAllow: () -> Void
  let onNotNow: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Image(systemName: "bell.badge")
        .font(.system(size: 32, weight: .semibold))
        .foregroundStyle(ReferencePalette.ink)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 8) {
        Text("Keep your results within reach")
          .font(.title3.weight(.bold))
        Text("Allow notifications when a new Ward result is ready. You can change this later in Settings.")
          .font(.body)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: 10) {
        Button("Allow notifications", action: onAllow)
          .buttonStyle(ReferencePrimaryButtonStyle())
          .accessibilityIdentifier("notifications.permission.allow")
        Button("Not now", action: onNotNow)
          .buttonStyle(ReferenceOutlineButtonStyle())
          .accessibilityIdentifier("notifications.permission.notNow")
      }
    }
    .padding(24)
    .frame(maxWidth: 430, alignment: .leading)
    .background(ReferencePalette.cream)
    .foregroundStyle(ReferencePalette.ink)
    .presentationDetents([.height(330)])
    .presentationDragIndicator(.visible)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("notifications.permission.prompt")
  }
}

/// A small status surface for Settings and the notification landing route.
/// It becomes visible only when the app has local fallback work to show.
struct WingwardNotificationBadge: View {
  let count: Int
  let authorization: WingwardNotificationAuthorization

  var body: some View {
    if count > 0, !authorization.canDeliverPush {
      HStack(spacing: 8) {
        Image(systemName: "bell.badge.fill")
          .accessibilityHidden(true)
        Text(count > 99 ? "99+" : "\(count)")
          .font(.caption.weight(.bold))
          .monospacedDigit()
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .foregroundStyle(ReferencePalette.ink)
      .background(ReferencePalette.yellow)
      .clipShape(Capsule())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(count) notification\(count == 1 ? "" : "s") waiting in the app")
      .accessibilityIdentifier("notifications.inAppBadge")
    }
  }
}

/// Provider-independent notification settings.  The system Settings button
/// is the only re-permission path after the user has denied notifications.
@MainActor
struct WingwardNotificationSettingsView: View {
  let ownerID: String
  let permissionClient: any WingwardNotificationPermissionClient
  let badgePersistence: any WingwardNotificationBadgePersistence
  let seenAPI: (any WingwardNotificationSeenAPI)?

  @State private var model: WingwardNotificationPermissionModel
  @Environment(\.scenePhase) private var scenePhase

  init(
    ownerID: String,
    permissionClient: (any WingwardNotificationPermissionClient)? = nil,
    badgePersistence: (any WingwardNotificationBadgePersistence)? = nil,
    seenAPI: (any WingwardNotificationSeenAPI)? = nil
  ) {
    self.ownerID = ownerID
    let resolvedPermissionClient = permissionClient ?? SystemWingwardNotificationPermissionClient()
    let resolvedBadgePersistence = badgePersistence ?? WingwardKeychainNotificationBadgePersistence()
    self.permissionClient = resolvedPermissionClient
    self.badgePersistence = resolvedBadgePersistence
    self.seenAPI = seenAPI
    _model = State(
      initialValue: WingwardNotificationPermissionModel(
        ownerID: ownerID,
        permissionClient: resolvedPermissionClient,
        badgePersistence: resolvedBadgePersistence,
        seenAPI: seenAPI
      )
    )
  }

  var body: some View {
    List {
      Section {
        HStack {
          Label("Notifications", systemImage: "bell")
          Spacer()
          Text(statusLabel)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(statusColor)
        }
        .accessibilityIdentifier("notifications.settings.status")

        if model.shouldShowFallbackBadge {
          HStack(alignment: .top, spacing: 12) {
            WingwardNotificationBadge(
              count: model.pendingBadgeCount,
              authorization: model.authorization
            )
            Text("Results waiting in the app")
              .font(.subheadline)
          }
          .accessibilityIdentifier("notifications.settings.fallback")
        }
      }

      Section {
        Button {
          model.openSettings()
        } label: {
          Label("Open iPhone Settings", systemImage: "gear")
        }
        .accessibilityIdentifier("notifications.settings.openSystemSettings")

        Button {
          Task { await model.markPendingResultsSeen() }
        } label: {
          if model.isMarkingSeen {
            Label("Updating notification status…", systemImage: "hourglass")
          } else {
            Label("Mark waiting results as seen", systemImage: "checkmark.circle")
          }
        }
        .disabled(model.pendingBadgeCount == 0 || model.isMarkingSeen)
        .accessibilityIdentifier("notifications.settings.clearBadge")

        if let seenError = model.seenError {
          Text(seenError)
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityIdentifier("notifications.settings.seenError")
        }
      }
    }
    .navigationTitle("Notifications")
    .task { await model.refresh() }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task { await model.refresh() }
    }
    .tint(ReferencePalette.ink)
  }

  private var statusLabel: String {
    switch model.authorization {
    case .authorized: return "On"
    case .provisional: return "Quiet preview"
    case .ephemeral: return "Temporary"
    case .denied: return "Off"
    case .notDetermined: return "Not set"
    case .unknown: return "Unavailable"
    }
  }

  private var statusColor: Color {
    model.authorization.canDeliverPush ? ReferencePalette.ink : ReferencePalette.muted
  }
}

/// Route wrapper used by the live integration seam.  The destination itself
/// remains feature-owned; this wrapper only records that the allowlisted
/// destination became visible after a notification tap.
@MainActor
struct WingwardNotificationTrackedDestinationView: View {
  let ownerID: String
  let route: AppRoute
  let destination: AnyView
  let coordinator: WingwardNotificationCoordinator?
  @State private var permissionModel: WingwardNotificationPermissionModel

  init(
    ownerID: String,
    route: AppRoute,
    destination: AnyView,
    coordinator: WingwardNotificationCoordinator?
  ) {
    self.ownerID = ownerID
    self.route = route
    self.destination = destination
    self.coordinator = coordinator
    _permissionModel = State(
      initialValue: WingwardNotificationPermissionModel(ownerID: ownerID)
    )
  }

  var body: some View {
    destination
      .onAppear {
        coordinator?.recordScreenViewed(for: route)
      }
      .task(id: route) {
        guard case .foxConversationResult = route else { return }
        await permissionModel.prepareForFirstFoxResult()
      }
      .sheet(
        isPresented: Binding(
          get: { permissionModel.isPromptPresented },
          set: { isPresented in
            if !isPresented { permissionModel.dismissPrompt() }
          }
        )
      ) {
        WingwardNotificationPermissionPrompt(
          onAllow: { Task { await permissionModel.acceptPrompt() } },
          onNotNow: { permissionModel.deferPrompt() }
        )
      }
  }
}

/// The payload-free notification landing route remains internal.  It gives a
/// denied user a real settings/badge surface and records `screen_viewed` with
/// the notification UUID that opened it.
@MainActor
struct WingwardNotificationLandingView: View {
  let ownerID: String
  let notificationID: UUID
  let coordinator: WingwardNotificationCoordinator?
  let seenAPI: (any WingwardNotificationSeenAPI)?

  init(
    ownerID: String,
    notificationID: UUID,
    coordinator: WingwardNotificationCoordinator?,
    seenAPI: (any WingwardNotificationSeenAPI)? = nil
  ) {
    self.ownerID = ownerID
    self.notificationID = notificationID
    self.coordinator = coordinator
    self.seenAPI = seenAPI
  }

  var body: some View {
    WingwardNotificationSettingsView(ownerID: ownerID, seenAPI: seenAPI)
      .onAppear {
        coordinator?.recordScreenViewed(for: .notificationLanding(notificationID))
      }
  }
}
