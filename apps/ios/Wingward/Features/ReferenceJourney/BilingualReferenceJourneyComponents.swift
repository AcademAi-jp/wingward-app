import SwiftUI

enum BilingualReferencePalette {
  static let cream = Color(red: 247 / 255, green: 247 / 255, blue: 244 / 255)
  static let ink = Color(red: 23 / 255, green: 23 / 255, blue: 25 / 255)
  static let yellow = Color(red: 1, green: 202 / 255, blue: 40 / 255)
  static let softYellow = Color(red: 1, green: 243 / 255, blue: 196 / 255)
  static let line = Color(red: 229 / 255, green: 229 / 255, blue: 226 / 255)
  static let muted = Color(red: 98 / 255, green: 98 / 255, blue: 102 / 255)
  static let field = Color(red: 251 / 255, green: 251 / 255, blue: 249 / 255)
  static let green = Color(red: 44 / 255, green: 124 / 255, blue: 81 / 255)
}

@inline(__always)
func bilingualReferenceCopy(
  _ key: BilingualReferenceCopyKey,
  language: BilingualReferenceLanguage
) -> String {
  BilingualReferenceCatalog.text(key, language: language)
}

func bilingualReferenceAuthError(
  _ issue: InputValidationIssue,
  language: BilingualReferenceLanguage
) -> String {
  let key: BilingualReferenceCopyKey
  switch issue {
  case .emailRequired: key = .authErrorEmailRequired
  case .emailInvalid: key = .authErrorEmailInvalid
  case .passwordRequired: key = .authErrorPasswordRequired
  case .passwordTooShort: key = .authErrorPasswordTooShort
  case .passwordConfirmationRequired: key = .authErrorPasswordConfirmationRequired
  case .passwordsDoNotMatch: key = .authErrorPasswordsDoNotMatch
  case .birthDateInvalid: key = .authErrorBirthDateInvalid
  case .under18: key = .authErrorUnder18
  }
  return bilingualReferenceCopy(key, language: language)
}

func bilingualReferenceConfirmationMessage(
  maskedEmail: String,
  language: BilingualReferenceLanguage
) -> String {
  bilingualReferenceCopy(.authConfirmationBody, language: language)
    .replacingOccurrences(of: "{email}", with: maskedEmail)
}

struct BilingualReferencePrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline.weight(.bold))
      .foregroundStyle(BilingualReferencePalette.ink)
      .frame(maxWidth: .infinity, minHeight: 54)
      .background(BilingualReferencePalette.yellow)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .opacity(configuration.isPressed ? 0.88 : 1)
  }
}

struct BilingualReferenceSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(BilingualReferencePalette.ink)
      .frame(maxWidth: .infinity, minHeight: 48)
      .background(BilingualReferencePalette.field)
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(BilingualReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

struct BilingualReferenceOfflineBadge: View {
  let language: BilingualReferenceLanguage

  var body: some View {
    Label(
      bilingualReferenceCopy(.offlineBadge, language: language),
      systemImage: "lock.shield.fill"
    )
    .font(.caption2.weight(.bold))
    .foregroundStyle(BilingualReferencePalette.ink)
    .padding(.horizontal, 11)
    .padding(.vertical, 7)
    .background(BilingualReferencePalette.softYellow)
    .clipShape(Capsule())
  }
}

struct BilingualReferenceScreenFrame<Content: View>: View {
  let language: BilingualReferenceLanguage
  let content: Content

  init(language: BilingualReferenceLanguage, @ViewBuilder content: () -> Content) {
    self.language = language
    self.content = content()
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      BilingualReferencePalette.cream.ignoresSafeArea()
      ScrollView {
        content
          .frame(maxWidth: 760)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 22)
          .padding(.vertical, 26)
          .padding(.top, 18)
      }
      .scrollIndicators(.hidden)
      BilingualReferenceOfflineBadge(language: language)
        .padding(.top, 10)
        .padding(.trailing, 18)
        .accessibilityIdentifier("bilingual.offlineBadge")
    }
    .foregroundStyle(BilingualReferencePalette.ink)
    .tint(BilingualReferencePalette.ink)
  }
}

struct BilingualReferenceSectionLabel: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption.weight(.bold))
      .tracking(1.8)
      .foregroundStyle(BilingualReferencePalette.muted)
  }
}

struct BilingualReferenceProgressHeader: View {
  let language: BilingualReferenceLanguage
  let progress: Double
  let onBack: (() -> Void)?

  var body: some View {
    HStack(spacing: 14) {
      if let onBack {
        Button(action: onBack) {
          Image(systemName: "chevron.left")
            .font(.headline.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.7))
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bilingualReferenceCopy(.detailBack, language: language))
        .accessibilityIdentifier("bilingual.navigation.back")
      }
      ProgressView(value: min(max(progress, 0), 1))
        .tint(BilingualReferencePalette.yellow)
        .scaleEffect(x: 1, y: 1.7, anchor: .center)
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100))%")
      Spacer(minLength: 0)
    }
  }
}

struct BilingualReferenceTraitChip: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(BilingualReferencePalette.ink)
      .padding(.horizontal, 13)
      .padding(.vertical, 9)
      .background(BilingualReferencePalette.softYellow)
      .clipShape(Capsule())
  }
}

struct BilingualReferenceAvatar: View {
  let candidate: BilingualReferenceCandidate
  let size: CGFloat

  var body: some View {
    Image(candidate.imageName)
      .resizable()
      .scaledToFill()
      .frame(width: size, height: size)
      .clipShape(Circle())
      .overlay {
        Circle().stroke(.white, lineWidth: 3)
      }
      .shadow(color: BilingualReferencePalette.ink.opacity(0.08), radius: 5, y: 2)
      .accessibilityLabel(candidate.name)
  }
}

struct BilingualReferenceSelfPortrait: View {
  let language: BilingualReferenceLanguage
  let size: CGFloat

  var body: some View {
    Image("mio-watercolor")
      .resizable()
      .scaledToFill()
      .frame(width: size, height: size)
      .clipShape(Circle())
      .overlay {
        Circle().stroke(.white, lineWidth: 3)
      }
      .shadow(color: BilingualReferencePalette.ink.opacity(0.08), radius: 5, y: 2)
      .accessibilityLabel(bilingualReferenceCopy(.youPortraitLabel, language: language))
  }
}

struct BilingualReferenceCandidateCard: View {
  let candidate: BilingualReferenceCandidate
  let language: BilingualReferenceLanguage
  let selected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: 11) {
        ZStack(alignment: .topTrailing) {
          BilingualReferenceAvatar(candidate: candidate, size: 90)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text("\(candidate.matchScore)%")
            .font(.caption2.weight(.bold))
            .foregroundStyle(BilingualReferencePalette.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(BilingualReferencePalette.softYellow)
            .clipShape(Capsule())
        }
        Text(candidate.name)
          .font(.headline.weight(.bold))
        Text(candidate.location.value(for: language))
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
          .lineLimit(1)
        if selected {
          Text(bilingualReferenceCopy(.wordsSelectedLabel, language: language))
            .font(.caption2.weight(.bold))
            .foregroundStyle(BilingualReferencePalette.green)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(selected ? BilingualReferencePalette.softYellow : .white)
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(selected ? BilingualReferencePalette.yellow : BilingualReferencePalette.line, lineWidth: selected ? 2 : 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("bilingual.words.candidate.\(candidate.id)")
    .accessibilityLabel("\(candidate.name), \(candidate.matchScore)%")
    .accessibilityAddTraits(
      selected ? AccessibilityTraits.isSelected : AccessibilityTraits()
    )
  }
}

struct BilingualReferenceSettingsRow<Destination: Hashable>: View {
  let title: String
  let destination: Destination

  var body: some View {
    NavigationLink(value: destination) {
      HStack(spacing: 12) {
        Text(title)
          .font(.body.weight(.medium))
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption.weight(.bold))
          .foregroundStyle(BilingualReferencePalette.muted)
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 56)
      .background(.white)
    }
    .buttonStyle(.plain)
  }
}
