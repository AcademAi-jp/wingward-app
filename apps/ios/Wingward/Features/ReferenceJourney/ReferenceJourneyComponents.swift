import SwiftUI

enum ReferencePalette {
  static let cream = Color(red: 0.968, green: 0.968, blue: 0.957)
  static let ink = Color(red: 0.09, green: 0.09, blue: 0.098)
  static let yellow = Color(red: 1.0, green: 0.792, blue: 0.157)
  static let yellowSoft = Color(red: 1.0, green: 0.953, blue: 0.769)
  static let muted = Color(red: 0.447, green: 0.447, blue: 0.471)
  static let line = Color(red: 0.898, green: 0.898, blue: 0.886)
  static let field = Color(red: 0.98, green: 0.98, blue: 0.973)
  static let darkSurface = Color(red: 0.141, green: 0.141, blue: 0.149)
}

struct ReferencePrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline.weight(.semibold))
      .foregroundStyle(ReferencePalette.ink)
      .frame(maxWidth: .infinity, minHeight: 52)
      .background(ReferencePalette.yellow)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .opacity(configuration.isPressed ? 0.75 : 1)
  }
}

struct ReferenceSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline.weight(.semibold))
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity, minHeight: 52)
      .background(ReferencePalette.ink)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .opacity(configuration.isPressed ? 0.75 : 1)
  }
}

struct ReferenceOutlineButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.semibold))
      .foregroundStyle(ReferencePalette.ink)
      .frame(maxWidth: .infinity, minHeight: 48)
      .background(ReferencePalette.field)
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(ReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .opacity(configuration.isPressed ? 0.75 : 1)
  }
}

struct ReferenceWardMark: View {
  enum Size {
    case small
    case normal
    case large

    var dimension: CGFloat {
      switch self {
      case .small: return 32
      case .normal: return 52
      case .large: return 72
      }
    }

    var cornerRadius: CGFloat {
      switch self {
      case .small: return 11
      case .normal: return 18
      case .large: return 24
      }
    }

    var iconSize: CGFloat {
      switch self {
      case .small: return 14
      case .normal: return 22
      case .large: return 28
      }
    }
  }

  let size: Size

  init(size: Size = .normal) {
    self.size = size
  }

  var body: some View {
    Image(systemName: "sparkles")
      .font(.system(size: size.iconSize, weight: .semibold))
      .foregroundStyle(ReferencePalette.ink)
      .frame(width: size.dimension, height: size.dimension)
      .background(ReferencePalette.yellow)
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: size.cornerRadius,
          bottomLeadingRadius: size.cornerRadius / 3,
          bottomTrailingRadius: size.cornerRadius,
          topTrailingRadius: size.cornerRadius
        )
      )
      .accessibilityHidden(true)
  }
}

struct ReferenceBrand: View {
  var body: some View {
    HStack(spacing: 10) {
      ReferenceWardMark(size: .small)
      Text("WingWard")
        .font(.title2.weight(.bold))
        .tracking(-0.6)
    }
    .foregroundStyle(ReferencePalette.ink)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("WingWard")
  }
}

struct ReferenceAvatar: View {
  let imageName: String?
  let dimension: CGFloat

  init(imageName: String? = nil, dimension: CGFloat = 34) {
    self.imageName = imageName
    self.dimension = dimension
  }

  var body: some View {
    Group {
      if let imageName, !imageName.isEmpty {
        Image(imageName)
          .resizable()
          .scaledToFill()
      } else {
        ZStack {
          Circle().fill(ReferencePalette.field)
          Image(systemName: "person.fill")
            .font(.system(size: dimension * 0.42, weight: .medium))
            .foregroundStyle(ReferencePalette.muted)
        }
      }
    }
    .frame(width: dimension, height: dimension)
    .clipShape(Circle())
    .overlay {
      Circle().stroke(ReferencePalette.line, lineWidth: 1)
    }
  }
}

struct ReferencePortrait: View {
  enum Size {
    case small
    case medium
    case large

    var dimension: CGFloat {
      switch self {
      case .small: return 52
      case .medium: return 68
      case .large: return 92
      }
    }
  }

  let candidate: ReferenceCandidate
  let size: Size

  init(candidate: ReferenceCandidate, size: Size = .medium) {
    self.candidate = candidate
    self.size = size
  }

  var body: some View {
    ZStack {
      Circle()
        .stroke(ReferencePalette.line, lineWidth: 4)
      Circle()
        .trim(from: 0, to: CGFloat(min(max(candidate.match, 0), 100)) / 100)
        .stroke(
          ReferencePalette.yellow,
          style: StrokeStyle(lineWidth: 4, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
      Image(candidate.imageName)
        .resizable()
        .scaledToFill()
        .frame(width: size.dimension - 10, height: size.dimension - 10)
        .clipShape(Circle())
        .overlay {
          Circle().stroke(.white, lineWidth: 3)
        }
    }
    .frame(width: size.dimension, height: size.dimension)
    .accessibilityLabel("\(candidate.name)の水彩画プロフィール")
  }
}

struct ReferenceFixtureBar: View {
  let surfaceState: ReferenceSurfaceState
  let onSelectState: (ReferencePreviewStateOption) -> Void

  var body: some View {
    HStack(spacing: 10) {
      Label("DEBUG FIXTURE · local only", systemImage: "flask")
        .font(.caption2.weight(.bold))
        .foregroundStyle(ReferencePalette.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityIdentifier("reference.fixtureLabel")
      Spacer(minLength: 4)
      ReferencePreviewStateMenu(surfaceState: surfaceState, onSelect: onSelectState)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .background(ReferencePalette.yellowSoft)
  }
}

struct ReferencePreviewStateMenu: View {
  let surfaceState: ReferenceSurfaceState
  let onSelect: (ReferencePreviewStateOption) -> Void

  var body: some View {
    Menu {
      ForEach(ReferencePreviewStateOption.allCases) { option in
        Button {
          onSelect(option)
        } label: {
          Label(option.title, systemImage: option.state.id == surfaceState.id ? "checkmark" : "circle")
        }
      }
    } label: {
      Label("状態", systemImage: "slider.horizontal.3")
        .font(.caption.weight(.semibold))
        .foregroundStyle(ReferencePalette.ink)
        .frame(minWidth: 44, minHeight: 36)
    }
    .accessibilityLabel("プレビュー状態を選択")
    .accessibilityIdentifier("reference.stateMenu")
  }
}

struct ReferenceHeader: View {
  let onLogo: () -> Void
  let selfImageName: String?
  let onProfile: () -> Void
  let profileIdentifier: String
  let notificationIdentifier: String
  let notificationLabel: String

  init(
    onLogo: @escaping () -> Void,
    selfImageName: String? = nil,
    onProfile: @escaping () -> Void,
    profileIdentifier: String = "reference.header.profile",
    notificationIdentifier: String = "reference.header.notifications",
    notificationLabel: String = "お知らせ（プレビュー）"
  ) {
    self.onLogo = onLogo
    self.selfImageName = selfImageName
    self.onProfile = onProfile
    self.profileIdentifier = profileIdentifier
    self.notificationIdentifier = notificationIdentifier
    self.notificationLabel = notificationLabel
  }

  var body: some View {
    HStack {
      Button(action: onLogo) {
        ReferenceBrand()
      }
      .buttonStyle(.plain)
      .accessibilityLabel("ホームへ")
      .accessibilityIdentifier("reference.logo")

      Spacer()

      Image(systemName: "bell")
        .font(.system(size: 19, weight: .medium))
        .foregroundStyle(ReferencePalette.ink)
        .frame(width: 44, height: 44)
        .accessibilityLabel(notificationLabel)
        .accessibilityIdentifier(notificationIdentifier)

      Button(action: onProfile) {
        ReferenceAvatar(imageName: selfImageName)
      }
      .buttonStyle(.plain)
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
      .accessibilityLabel("プロフィール設定")
      .accessibilityIdentifier(profileIdentifier)
    }
    .padding(.horizontal, 18)
    .frame(height: 64)
    .background(.white)
    .overlay(alignment: .bottom) {
      Rectangle().fill(ReferencePalette.line).frame(height: 1)
    }
  }
}

struct ReferenceProgressHeader: View {
  let backTitle: String
  let progress: String
  let progressValue: Double
  let showsProgress: Bool
  let backIdentifier: String
  let onBack: () -> Void

  init(
    backTitle: String,
    progress: String,
    progressValue: Double,
    showsProgress: Bool = true,
    backIdentifier: String = "reference.progress.back",
    onBack: @escaping () -> Void
  ) {
    self.backTitle = backTitle
    self.progress = progress
    self.progressValue = progressValue
    self.showsProgress = showsProgress
    self.backIdentifier = backIdentifier
    self.onBack = onBack
  }

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Button(action: onBack) {
          Label(backTitle, systemImage: "chevron.left")
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(ReferencePalette.ink)
        .frame(minHeight: 44)
        .accessibilityIdentifier(backIdentifier)
        Spacer()
        Text(progress)
          .font(.caption.weight(.bold))
          .foregroundStyle(ReferencePalette.muted)
      }
      if showsProgress {
        ProgressView(value: progressValue)
          .tint(ReferencePalette.ink)
          .accessibilityLabel("進捗")
          .accessibilityValue("\(Int(progressValue * 100))パーセント")
      }
    }
  }
}

struct ReferenceStateSurface<Content: View>: View {
  let state: ReferenceSurfaceState
  let onRetry: (() -> Void)?
  @ViewBuilder let content: () -> Content

  init(
    state: ReferenceSurfaceState,
    onRetry: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.state = state
    self.onRetry = onRetry
    self.content = content
  }

  var body: some View {
    Group {
      if state == .loaded {
        content()
      } else {
        ScrollView {
          VStack(spacing: 18) {
            Spacer(minLength: 64)
            Image(systemName: iconName)
              .font(.system(size: 32, weight: .medium))
              .foregroundStyle(ReferencePalette.yellow)
              .accessibilityHidden(true)
            Text(state.title)
              .font(.title2.weight(.bold))
              .multilineTextAlignment(.center)
            Text(state.message)
              .font(.body)
              .foregroundStyle(ReferencePalette.muted)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
            if shouldOfferRetry, let onRetry {
              Button("状態を再確認", action: onRetry)
                .buttonStyle(ReferenceOutlineButtonStyle())
                .frame(maxWidth: 320)
                .accessibilityIdentifier("reference.stateRetry")
            }
            Spacer(minLength: 64)
          }
          .padding(24)
          .frame(maxWidth: 560)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ReferencePalette.cream)
    .accessibilityElement(children: .contain)
  }

  private var shouldOfferRetry: Bool {
    switch state {
    case .error, .unavailable, .reconnecting:
      return true
    case .loaded, .loading, .empty, .microphoneDenied:
      return false
    }
  }

  private var iconName: String {
    switch state {
    case .loaded: return "checkmark.circle"
    case .loading: return "hourglass"
    case .empty: return "tray"
    case .error: return "exclamationmark.triangle"
    case .unavailable: return "link.badge.plus"
    case .microphoneDenied: return "mic.slash"
    case .reconnecting: return "wifi.exclamationmark"
    }
  }
}

struct ReferenceBottomNav: View {
  let selected: ReferenceJourneyScreen
  let onHome: () -> Void
  let onChat: () -> Void

  var body: some View {
    HStack {
      navButton(
        title: "ホーム",
        icon: "house",
        isSelected: selected == .home,
        action: onHome,
        identifier: "reference.bottomNav.home"
      )
      navButton(
        title: "トーク",
        icon: "bubble.left.and.bubble.right",
        isSelected: selected == .chat,
        action: onChat,
        identifier: "reference.bottomNav.chat"
      )
    }
    .padding(.top, 7)
    .padding(.bottom, 7)
    .background(.white.opacity(0.94))
    .overlay(alignment: .top) {
      Rectangle().fill(ReferencePalette.line).frame(height: 1)
    }
  }

  private func navButton(
    title: String,
    icon: String,
    isSelected: Bool,
    action: @escaping () -> Void,
    identifier: String
  ) -> some View {
    Button(action: action) {
      VStack(spacing: 3) {
        Image(systemName: isSelected ? "\(icon).fill" : icon)
          .font(.system(size: 21, weight: .medium))
        Text(title)
          .font(.caption2.weight(isSelected ? .bold : .regular))
      }
      .foregroundStyle(isSelected ? ReferencePalette.ink : ReferencePalette.muted)
      .frame(maxWidth: .infinity, minHeight: 48)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier(identifier)
  }
}

struct ReferenceTag: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .foregroundStyle(ReferencePalette.ink)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(ReferencePalette.yellowSoft)
      .clipShape(Capsule())
  }
}

struct ReferenceMessageBubble: View {
  let message: ReferenceChatMessage

  var body: some View {
    VStack(alignment: message.side == .mine ? .trailing : .leading, spacing: 4) {
      Text(message.actor)
        .font(.caption2.weight(.bold))
        .foregroundStyle(ReferencePalette.muted)
      Text(message.text)
        .font(.body)
        .foregroundStyle(message.side == .mine ? ReferencePalette.ink : ReferencePalette.ink)
        .multilineTextAlignment(.leading)
      Text(message.time)
        .font(.caption2)
        .foregroundStyle(message.side == .mine ? ReferencePalette.ink.opacity(0.58) : ReferencePalette.muted)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(message.side == .mine ? ReferencePalette.yellow : .white)
    .clipShape(
      UnevenRoundedRectangle(
        topLeadingRadius: 19,
        bottomLeadingRadius: message.side == .mine ? 19 : 5,
        bottomTrailingRadius: message.side == .mine ? 5 : 19,
        topTrailingRadius: 19
      )
    )
    .frame(maxWidth: 310, alignment: message.side == .mine ? .trailing : .leading)
    .frame(maxWidth: .infinity, alignment: message.side == .mine ? .trailing : .leading)
  }
}
