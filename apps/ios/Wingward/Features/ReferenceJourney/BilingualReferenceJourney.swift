#if DEBUG
import SwiftUI

/// The bilingual, offline-only redesign preview. It is deliberately isolated from
/// the production root and is opened only with its DEBUG launch argument.
struct BilingualReferenceJourney: View {
  @StateObject private var model: BilingualReferenceJourneyModel

  init(approvalFixture: Bool = false) {
    _model = StateObject(wrappedValue: BilingualReferenceJourneyModel(approvalFixture: approvalFixture))
  }

  var body: some View {
    Group {
      switch model.route {
      case .languageChoice:
        BilingualReferenceLanguageChoiceView(
          onSelect: { model.chooseLanguage($0) }
        )
      case .onboarding:
        BilingualReferenceOnboardingView(
          language: selectedLanguage,
          onStart: { model.openCheckIn() }
        )
      case .quickCheckIn:
        BilingualReferenceCheckInView(
          model: model,
          language: selectedLanguage,
          onBack: { model.returnToOnboarding() }
        )
      case .voice:
        BilingualReferenceVoiceView(
          model: model,
          language: selectedLanguage,
          onBack: { model.returnToCheckIn() }
        )
      case .shell:
        BilingualReferenceShell(model: model, language: selectedLanguage)
      }
    }
    .preferredColorScheme(.light)
  }

  private var selectedLanguage: BilingualReferenceLanguage {
    model.language ?? .japanese
  }
}

private struct BilingualReferenceLanguageChoiceView: View {
  let onSelect: (BilingualReferenceLanguage) -> Void

  var body: some View {
    ZStack {
      BilingualReferencePalette.cream.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          Spacer(minLength: 38)
          Circle()
            .fill(BilingualReferencePalette.yellow)
            .frame(width: 66, height: 66)
            .overlay {
              Image(systemName: "globe")
                .font(.title2.weight(.bold))
                .foregroundStyle(BilingualReferencePalette.ink)
            }
            .accessibilityHidden(true)
          Text(BilingualReferenceCatalog.text(.languageChoiceTitle, language: .japanese))
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .tracking(-1)
            .padding(.top, 26)
            .accessibilityIdentifier("bilingual.languageChoice.title")
          Text(BilingualReferenceCatalog.text(.languageJapanese, language: .japanese))
            .font(.subheadline.weight(.medium))
            .foregroundStyle(BilingualReferencePalette.muted)
            .padding(.top, 8)
            .accessibilityHidden(true)

          VStack(spacing: 12) {
            languageButton(
              language: .japanese,
              title: BilingualReferenceCatalog.text(.languageJapanese, language: .japanese),
              subtitle: BilingualReferenceCatalog.text(.languageChoiceJapaneseSubtitle, language: .japanese)
            )
            languageButton(
              language: .english,
              title: BilingualReferenceCatalog.text(.languageEnglish, language: .english),
              subtitle: BilingualReferenceCatalog.text(.languageChoiceEnglishSubtitle, language: .english)
            )
          }
          .padding(.top, 38)

          Text(BilingualReferenceCatalog.text(.localOnlyNote, language: .japanese))
            .font(.caption)
            .foregroundStyle(BilingualReferencePalette.muted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 30)
            .accessibilityIdentifier("bilingual.languageChoice.localNote")
          Spacer(minLength: 34)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
      }
    }
    .tint(BilingualReferencePalette.ink)
  }

  private func languageButton(
    language: BilingualReferenceLanguage,
    title: String,
    subtitle: String
  ) -> some View {
    Button {
      onSelect(language)
    } label: {
      HStack(spacing: 14) {
        Image(systemName: language == .japanese ? "character.book.closed" : "textformat")
          .font(.title3.weight(.semibold))
          .frame(width: 34)
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.headline.weight(.bold))
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(BilingualReferencePalette.muted)
        }
        Spacer()
        Image(systemName: "arrow.right")
          .font(.subheadline.weight(.bold))
      }
      .foregroundStyle(BilingualReferencePalette.ink)
      .padding(.horizontal, 18)
      .frame(minHeight: 76)
      .background(.white)
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(BilingualReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("bilingual.languageChoice.\(language.rawValue)")
  }
}

private struct BilingualReferenceOnboardingView: View {
  let language: BilingualReferenceLanguage
  let onStart: () -> Void

  var body: some View {
    BilingualReferenceScreenFrame(language: language) {
      VStack(alignment: .leading, spacing: 0) {
        BilingualReferenceSectionLabel(
          text: bilingualReferenceCopy(.onboardingKicker, language: language)
        )
        Text(bilingualReferenceCopy(.onboardingTitle, language: language))
          .font(.system(size: 40, weight: .bold, design: .rounded))
          .tracking(-1.8)
          .lineSpacing(2)
          .padding(.top, 16)
        Text(bilingualReferenceCopy(.onboardingBody, language: language))
          .font(.body)
          .foregroundStyle(BilingualReferencePalette.muted)
          .lineSpacing(6)
          .padding(.top, 18)

        HStack(spacing: -16) {
          ForEach(BilingualReferenceCatalog.candidates) { candidate in
            BilingualReferenceAvatar(candidate: candidate, size: 64)
          }
        }
        .padding(.top, 28)
        .accessibilityHidden(true)

        VStack(spacing: 0) {
          BilingualReferenceOnboardingStep(
            number: "01",
            title: bilingualReferenceCopy(.onboardingStepCheckIn, language: language),
            systemImage: "checklist"
          )
          BilingualReferenceOnboardingStep(
            number: "02",
            title: bilingualReferenceCopy(.onboardingStepVoice, language: language),
            systemImage: "waveform"
          )
        }
        .padding(.top, 34)

        Button(action: onStart) {
          Text(bilingualReferenceCopy(.onboardingCTA, language: language))
        }
        .buttonStyle(BilingualReferencePrimaryButtonStyle())
        .padding(.top, 30)
        .accessibilityIdentifier("bilingual.onboarding.start")
      }
    }
  }
}

private struct BilingualReferenceOnboardingStep: View {
  let number: String
  let title: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 14) {
      Text(number)
        .font(.caption.weight(.bold))
        .foregroundStyle(BilingualReferencePalette.muted)
        .frame(width: 26, alignment: .leading)
      Image(systemName: systemImage)
        .font(.headline.weight(.semibold))
        .frame(width: 30)
      Text(title)
        .font(.body.weight(.semibold))
      Spacer()
    }
    .frame(minHeight: 56)
    .overlay(alignment: .bottom) {
      Rectangle().fill(BilingualReferencePalette.line).frame(height: 1)
    }
  }
}

private struct BilingualReferenceCheckInView: View {
  @ObservedObject var model: BilingualReferenceJourneyModel
  let language: BilingualReferenceLanguage
  let onBack: () -> Void

  var body: some View {
    BilingualReferenceScreenFrame(language: language) {
      VStack(alignment: .leading, spacing: 0) {
        BilingualReferenceProgressHeader(
          language: language,
          progress: model.questionProgress,
          onBack: onBack
        )
        BilingualReferenceSectionLabel(
          text: bilingualReferenceCopy(.checkInKicker, language: language)
        )
        .padding(.top, 30)
        Text(bilingualReferenceCopy(.checkInTitle, language: language))
          .font(.system(size: 36, weight: .bold, design: .rounded))
          .tracking(-1.5)
          .lineSpacing(2)
          .padding(.top, 13)
        Text(bilingualReferenceCopy(.checkInBody, language: language))
          .font(.subheadline)
          .foregroundStyle(BilingualReferencePalette.muted)
          .lineSpacing(5)
          .padding(.top, 15)

        if model.isCheckInPaused {
          pauseCard
        } else {
          questionCard
        }
      }
    }
  }

  private var questionCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("\(bilingualReferenceCopy(.checkInQuestion, language: language)) \(model.questionIndex + 1) / \(BilingualReferenceCatalog.quizQuestions.count)")
          .font(.caption.weight(.bold))
          .foregroundStyle(BilingualReferencePalette.muted)
        Spacer()
        Button {
          model.toggleCheckInPause()
        } label: {
          Label(
            bilingualReferenceCopy(.checkInPause, language: language),
            systemImage: "pause.fill"
          )
          .font(.caption.weight(.bold))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bilingual.checkIn.pause")
      }
      Text(model.currentQuestion.prompt.value(for: language))
        .font(.title3.weight(.bold))
        .lineSpacing(4)
        .padding(.top, 18)
      VStack(spacing: 10) {
        ForEach(model.currentQuestion.answers) { answer in
          Button {
            model.answerCurrentQuestion(with: answer.id)
          } label: {
            HStack(alignment: .top, spacing: 12) {
              Circle()
                .stroke(BilingualReferencePalette.line, lineWidth: 2)
                .frame(width: 22, height: 22)
              Text(answer.text.value(for: language))
                .font(.body.weight(.medium))
                .multilineTextAlignment(.leading)
              Spacer(minLength: 0)
            }
            .foregroundStyle(BilingualReferencePalette.ink)
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(BilingualReferencePalette.field)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("bilingual.checkIn.answer.\(answer.id)")
        }
      }
      .padding(.top, 22)
    }
    .padding(20)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .padding(.top, 28)
  }

  private var pauseCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Image(systemName: "pause.circle.fill")
        .font(.system(size: 34))
        .foregroundStyle(BilingualReferencePalette.yellow)
      Text(bilingualReferenceCopy(.checkInPausedTitle, language: language))
        .font(.title3.weight(.bold))
      Text(bilingualReferenceCopy(.checkInPausedBody, language: language))
        .font(.subheadline)
        .foregroundStyle(BilingualReferencePalette.muted)
        .lineSpacing(4)
      Button {
        model.toggleCheckInPause()
      } label: {
        Text(bilingualReferenceCopy(.checkInResume, language: language))
      }
      .buttonStyle(BilingualReferencePrimaryButtonStyle())
      .accessibilityIdentifier("bilingual.checkIn.resume")
    }
    .padding(22)
    .background(BilingualReferencePalette.softYellow)
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .padding(.top, 28)
  }
}

private struct BilingualReferenceVoiceView: View {
  @ObservedObject var model: BilingualReferenceJourneyModel
  let language: BilingualReferenceLanguage
  let onBack: () -> Void

  var body: some View {
    BilingualReferenceScreenFrame(language: language) {
      VStack(alignment: .leading, spacing: 0) {
        BilingualReferenceProgressHeader(language: language, progress: 1, onBack: onBack)
        BilingualReferenceSectionLabel(
          text: bilingualReferenceCopy(.voiceKicker, language: language)
        )
        .padding(.top, 30)
        Text(bilingualReferenceCopy(.voiceTitle, language: language))
          .font(.system(size: 38, weight: .bold, design: .rounded))
          .tracking(-1.5)
          .lineSpacing(2)
          .padding(.top, 14)
        Text(bilingualReferenceCopy(.voiceBody, language: language))
          .font(.subheadline)
          .foregroundStyle(BilingualReferencePalette.muted)
          .lineSpacing(5)
          .padding(.top, 15)

        VStack(spacing: 18) {
          ZStack {
            Circle()
              .fill(model.voicePhase == .listening ? BilingualReferencePalette.softYellow : .white)
              .frame(width: 142, height: 142)
            Circle()
              .stroke(BilingualReferencePalette.yellow, lineWidth: 2)
              .frame(width: 142, height: 142)
            Image(systemName: model.voicePhase == .listening ? "waveform" : "waveform.circle")
              .font(.system(size: 46, weight: .medium))
              .foregroundStyle(BilingualReferencePalette.ink)
          }
          .accessibilityHidden(true)

          Text(model.voicePhase == .listening
            ? bilingualReferenceCopy(.voiceConnectionListening, language: language)
            : bilingualReferenceCopy(.voiceConnectionReady, language: language))
            .font(.headline.weight(.bold))
            .foregroundStyle(model.voicePhase == .listening ? BilingualReferencePalette.green : BilingualReferencePalette.ink)
            .accessibilityIdentifier("bilingual.voice.state")

          Text(model.voicePhase == .listening ? "00:18" : "00:00")
            .font(.system(size: 42, weight: .bold, design: .rounded))
            .monospacedDigit()
            .accessibilityLabel(bilingualReferenceCopy(.timerAccessibilityLabel, language: language))
            .accessibilityIdentifier("bilingual.voice.timer")

          HStack(spacing: 5) {
            ForEach([10, 22, 15, 29, 18, 34, 12, 26, 17], id: \.self) { height in
              RoundedRectangle(cornerRadius: 4)
                .fill(BilingualReferencePalette.yellow)
                .frame(width: 5, height: CGFloat(model.voicePhase == .listening ? height : 8))
            }
          }
          .frame(height: 36)
          .accessibilityHidden(true)

          if model.voicePhase == .ready {
            Button {
              model.startVoice()
            } label: {
              Text(bilingualReferenceCopy(.voiceStart, language: language))
            }
            .buttonStyle(BilingualReferencePrimaryButtonStyle())
            .accessibilityIdentifier("bilingual.voice.start")
          } else {
            Text(bilingualReferenceCopy(.voiceListening, language: language))
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(BilingualReferencePalette.muted)
            Button {
              model.finishVoice()
            } label: {
              Text(bilingualReferenceCopy(.voiceFinish, language: language))
            }
            .buttonStyle(BilingualReferencePrimaryButtonStyle())
            .accessibilityIdentifier("bilingual.voice.finish")
          }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.white)
        .overlay {
          RoundedRectangle(cornerRadius: 26, style: .continuous)
            .stroke(BilingualReferencePalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.top, 28)

        Text(bilingualReferenceCopy(.voiceOfflineNote, language: language))
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
          .frame(maxWidth: .infinity, alignment: .center)
          .multilineTextAlignment(.center)
          .padding(.top, 16)
      }
    }
  }
}

#endif
