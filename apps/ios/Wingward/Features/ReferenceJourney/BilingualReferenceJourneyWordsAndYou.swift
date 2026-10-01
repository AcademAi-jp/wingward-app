#if DEBUG
import SwiftUI

struct BilingualReferenceShell: View {
  @ObservedObject var model: BilingualReferenceJourneyModel
  let language: BilingualReferenceLanguage

  var body: some View {
    TabView(selection: Binding(
      get: { model.selectedTab },
      set: { model.selectTab($0) }
    )) {
      BilingualReferenceWordsView(model: model, language: language)
        .tabItem {
          Label(
            bilingualReferenceCopy(.tabWords, language: language),
            systemImage: "text.bubble.fill"
          )
        }
        .tag(BilingualReferenceTab.words)
        .accessibilityIdentifier("bilingual.tab.words")
      BilingualReferenceYouView(model: model, language: language)
        .tabItem {
          Label(
            bilingualReferenceCopy(.tabYou, language: language),
            systemImage: "person.crop.circle.fill"
          )
        }
        .tag(BilingualReferenceTab.you)
        .accessibilityIdentifier("bilingual.tab.you")
    }
    .tint(BilingualReferencePalette.ink)
  }
}

private struct BilingualReferenceWordsView: View {
  @ObservedObject var model: BilingualReferenceJourneyModel
  let language: BilingualReferenceLanguage

  var body: some View {
    ZStack(alignment: .topTrailing) {
      BilingualReferencePalette.cream.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          BilingualReferenceSectionLabel(
            text: bilingualReferenceCopy(.wordsKicker, language: language)
          )
          .padding(.top, 20)
          Text(bilingualReferenceCopy(.wordsTitle, language: language))
            .font(.system(size: 36, weight: .bold, design: .rounded))
            .tracking(-1.4)
            .lineSpacing(2)
            .padding(.top, 14)
          Text(bilingualReferenceCopy(.wordsBody, language: language))
            .font(.subheadline)
            .foregroundStyle(BilingualReferencePalette.muted)
            .lineSpacing(5)
            .padding(.top, 14)

          candidateSection
            .padding(.top, 28)
          selectedCandidateSection
            .padding(.top, 24)
          transcriptSection
            .padding(.top, 18)
          interestSection
            .padding(.top, 18)
        }
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
      }
      .scrollIndicators(.hidden)
      BilingualReferenceOfflineBadge(language: language)
        .padding(.top, 10)
        .padding(.trailing, 16)
      .accessibilityIdentifier("bilingual.offlineBadge")
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      composerSection
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(BilingualReferencePalette.cream)
    }
    .foregroundStyle(BilingualReferencePalette.ink)
  }

  private var candidateSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(bilingualReferenceCopy(.wordsCandidatesLabel, language: language))
        .font(.caption.weight(.bold))
        .tracking(1.4)
        .foregroundStyle(BilingualReferencePalette.muted)
      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
        spacing: 10
      ) {
        ForEach(BilingualReferenceCatalog.candidates.prefix(3)) { candidate in
          BilingualReferenceCandidateCard(
            candidate: candidate,
            language: language,
            selected: candidate.id == model.selectedCandidateID,
            onSelect: { model.selectCandidate(candidate) }
          )
        }
      }
    }
  }

  private var selectedCandidateSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 14) {
        BilingualReferenceAvatar(candidate: model.selectedCandidate, size: 76)
        VStack(alignment: .leading, spacing: 5) {
          Text(model.selectedCandidate.name)
            .font(.title3.weight(.bold))
          Text("\(model.selectedCandidate.age) · \(model.selectedCandidate.location.value(for: language))")
            .font(.subheadline)
            .foregroundStyle(BilingualReferencePalette.muted)
          Text(model.selectedCandidate.signature.value(for: language))
            .font(.subheadline.weight(.semibold))
            .lineSpacing(3)
        }
        Spacer(minLength: 0)
      }
      Text(model.selectedCandidate.summary.value(for: language))
        .font(.body)
        .foregroundStyle(BilingualReferencePalette.muted)
        .lineSpacing(5)
    }
    .padding(18)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
  }

  private var transcriptSection: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text(bilingualReferenceCopy(.wordsWardTranscript, language: language))
            .font(.caption.weight(.bold))
            .tracking(1.25)
          Text(bilingualReferenceCopy(.wordsTranscriptSubtitle, language: language))
            .font(.caption)
            .foregroundStyle(BilingualReferencePalette.muted)
        }
        Spacer()
        Image(systemName: "waveform")
          .foregroundStyle(BilingualReferencePalette.yellow)
      }

      VStack(alignment: .leading, spacing: 12) {
        ForEach(BilingualReferenceCatalog.wardTranscript + model.localMessages) { message in
          BilingualReferenceTranscriptBubble(message: message, language: language)
        }
      }
    }
    .padding(18)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
  }

  private var interestSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      if model.interestState == .notStarted {
        notStartedInterestSurface
      } else if model.interestState == .pending {
        pendingInterestSurface
      } else {
        mutualInterestSurface
      }
    }
    .padding(18)
    .background(model.interestState == .mutual ? BilingualReferencePalette.softYellow : .white)
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .accessibilityIdentifier("bilingual.words.interestCard")
  }

  private var notStartedInterestSurface: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "heart")
          .font(.title3.weight(.semibold))
          .foregroundStyle(BilingualReferencePalette.yellow)
        VStack(alignment: .leading, spacing: 4) {
          Text(bilingualReferenceCopy(.wordsInterestAction, language: language))
            .font(.headline.weight(.bold))
          Text(bilingualReferenceCopy(.wordsInterestBody, language: language))
            .font(.caption)
            .foregroundStyle(BilingualReferencePalette.muted)
        }
        Spacer(minLength: 0)
      }
      Button {
        model.expressInterest()
      } label: {
        Text(bilingualReferenceCopy(.wordsInterestAction, language: language))
      }
      .buttonStyle(BilingualReferencePrimaryButtonStyle())
      .accessibilityIdentifier("bilingual.words.interest")
    }
  }

  private var pendingInterestSurface: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "heart.circle")
          .font(.title3.weight(.semibold))
          .foregroundStyle(BilingualReferencePalette.yellow)
        VStack(alignment: .leading, spacing: 4) {
          Text(bilingualReferenceCopy(.wordsInterestPending, language: language))
            .font(.headline.weight(.bold))
          Text(pendingInterestBody)
            .font(.caption)
            .foregroundStyle(BilingualReferencePalette.muted)
            .lineSpacing(3)
        }
        Spacer(minLength: 0)
      }
      Button {
        model.simulateMutualInterest()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "sparkles")
          Text(bilingualReferenceCopy(.wordsInterestPreviewMutual, language: language))
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(BilingualReferencePalette.ink)
        .frame(maxWidth: .infinity, minHeight: 38)
        .background(BilingualReferencePalette.softYellow)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("bilingual.words.previewMutual")
    }
  }

  private var mutualInterestSurface: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "heart.fill")
          .font(.title3.weight(.semibold))
          .foregroundStyle(BilingualReferencePalette.green)
        VStack(alignment: .leading, spacing: 4) {
          Text(bilingualReferenceCopy(.wordsInterestMutual, language: language))
            .font(.headline.weight(.bold))
          Text(bilingualReferenceCopy(.wordsInterestBody, language: language))
            .font(.caption)
            .foregroundStyle(BilingualReferencePalette.muted)
        }
        Spacer(minLength: 0)
      }
      venueSurface
    }
  }

  private var pendingInterestBody: String {
    BilingualReferenceCatalog.pendingInterestBody(
      for: model.selectedCandidate.name,
      language: language
    )
  }

  @ViewBuilder
  private var venueSurface: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(bilingualReferenceCopy(.wordsVenueTitle, language: language))
          .font(.subheadline.weight(.bold))
        Spacer()
        Text(venueStatusText)
          .font(.caption.weight(.bold))
          .foregroundStyle(BilingualReferencePalette.green)
      }
      if model.venueStage == .suggested {
        ForEach(Array(BilingualReferenceCatalog.venueOptions.enumerated()), id: \.offset) { _, option in
          HStack(spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
              .foregroundStyle(BilingualReferencePalette.yellow)
            Text(option.value(for: language))
              .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
          }
          .padding(12)
          .background(.white.opacity(0.75))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
      } else if model.venueStage == .coordinating {
        ProgressView()
          .tint(BilingualReferencePalette.yellow)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if model.venueStage != .suggested {
        Button {
          model.advanceVenueCoordination()
        } label: {
          Text(bilingualReferenceCatalogVenueButtonTitle)
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
        .accessibilityIdentifier("bilingual.words.venue")
      }
      Text(bilingualReferenceCopy(.wordsVenueBody, language: language))
        .font(.caption)
        .foregroundStyle(BilingualReferencePalette.muted)
    }
    .padding(.top, 6)
    .accessibilityIdentifier("bilingual.words.venueCard")
  }

  private var venueStatusText: String {
    switch model.venueStage {
    case .hidden: return bilingualReferenceCopy(.wordsVenueReady, language: language)
    case .ready: return bilingualReferenceCopy(.wordsVenueReady, language: language)
    case .coordinating: return bilingualReferenceCopy(.wordsVenueCoordination, language: language)
    case .suggested: return bilingualReferenceCopy(.wordsVenueSuggested, language: language)
    }
  }

  private var bilingualReferenceCatalogVenueButtonTitle: String {
    switch model.venueStage {
    case .ready: return bilingualReferenceCopy(.wordsVenueAction, language: language)
    case .coordinating: return bilingualReferenceCopy(.wordsVenueSuggested, language: language)
    case .hidden, .suggested: return bilingualReferenceCopy(.wordsVenueAction, language: language)
    }
  }

  private var composerSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(bilingualReferenceCopy(.wordsComposerTitle, language: language))
        .font(.caption.weight(.bold))
        .tracking(1.25)
        .foregroundStyle(BilingualReferencePalette.muted)
      HStack(spacing: 8) {
        composerModeButton(.myWard, title: bilingualReferenceCopy(.wordsComposerMyWard, language: language))
        composerModeButton(.me, title: bilingualReferenceCopy(.wordsComposerMeLocked, language: language))
      }
      if let notice = model.composerNotice {
        HStack(alignment: .top, spacing: 9) {
          Image(systemName: "lock.fill")
            .foregroundStyle(BilingualReferencePalette.muted)
          Text(bilingualReferenceCopy(notice, language: language))
            .font(.caption)
            .foregroundStyle(BilingualReferencePalette.muted)
          Spacer(minLength: 0)
          Button {
            model.clearComposerNotice()
          } label: {
            Image(systemName: "xmark")
              .font(.caption.weight(.bold))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(bilingualReferenceCopy(.dismissAccessibilityLabel, language: language))
        }
        .padding(12)
        .background(BilingualReferencePalette.field)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("bilingual.words.composer.lockedExplanation")
      }
      HStack(spacing: 9) {
        TextField(
          bilingualReferenceCopy(.wordsComposerPlaceholder, language: language),
          text: Binding(get: { model.draft }, set: { model.setDraft($0) })
        )
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("bilingual.words.composer")
        Button {
          model.appendLocalWardMessage()
        } label: {
          Image(systemName: "arrow.up")
            .frame(width: 46, height: 46)
            .background(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? BilingualReferencePalette.line : BilingualReferencePalette.yellow)
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel(bilingualReferenceCopy(.wordsComposerSend, language: language))
        .accessibilityIdentifier("bilingual.words.composer.send")
      }
      Text(bilingualReferenceCopy(.wordsComposerLocalNote, language: language))
        .font(.caption)
        .foregroundStyle(BilingualReferencePalette.muted)
    }
    .padding(18)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .accessibilityIdentifier("bilingual.words.composerCard")
  }

  private func composerModeButton(_ mode: BilingualReferenceComposerMode, title: String) -> some View {
    Button {
      model.selectComposerMode(mode)
    } label: {
      HStack(spacing: 6) {
        if mode == .me && !model.approvalFixture {
          Image(systemName: "lock.fill")
            .font(.caption2)
        }
        Text(title)
          .font(.caption.weight(.bold))
          .lineLimit(1)
      }
      .foregroundStyle(model.composerMode == mode ? BilingualReferencePalette.ink : BilingualReferencePalette.muted)
      .frame(maxWidth: .infinity, minHeight: 40)
      .background(model.composerMode == mode ? BilingualReferencePalette.yellow : BilingualReferencePalette.field)
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(mode == .myWard ? "bilingual.words.composer.myWard" : "bilingual.words.composer.me")
  }
}

private struct BilingualReferenceTranscriptBubble: View {
  let message: BilingualReferenceMessage
  let language: BilingualReferenceLanguage

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      Circle()
        .fill(message.author == .myWard ? BilingualReferencePalette.yellow : BilingualReferencePalette.line)
        .frame(width: 10, height: 10)
        .padding(.top, 5)
      VStack(alignment: .leading, spacing: 3) {
        Text(authorLabel)
          .font(.caption2.weight(.bold))
          .foregroundStyle(BilingualReferencePalette.muted)
        Text(message.text.value(for: language))
          .font(.subheadline)
          .lineSpacing(3)
      }
      Spacer(minLength: 0)
    }
    .accessibilityIdentifier("bilingual.words.transcript.\(message.id)")
  }

  private var authorLabel: String {
    switch message.author {
    case .myWard: return bilingualReferenceCopy(.wordsComposerMyWard, language: language)
    case .partnerWard: return bilingualReferenceCopy(.wordsPartnerWard, language: language)
    case .localNote: return bilingualReferenceCopy(.wordsComposerMyWard, language: language)
    }
  }
}

private struct BilingualReferenceYouView: View {
  @ObservedObject var model: BilingualReferenceJourneyModel
  let language: BilingualReferenceLanguage
  @State private var showsLanguagePicker = false

  var body: some View {
    NavigationStack {
      ZStack(alignment: .topTrailing) {
        BilingualReferencePalette.cream.ignoresSafeArea()
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            BilingualReferenceSectionLabel(
              text: bilingualReferenceCopy(.youKicker, language: language)
            )
            .padding(.top, 20)
            Text(bilingualReferenceCopy(.youTitle, language: language))
              .font(.system(size: 36, weight: .bold, design: .rounded))
              .tracking(-1.4)
              .lineSpacing(2)
              .padding(.top, 14)
            Text(bilingualReferenceCopy(.youBody, language: language))
              .font(.subheadline)
              .foregroundStyle(BilingualReferencePalette.muted)
              .lineSpacing(5)
              .padding(.top, 14)
            analysisCard
              .padding(.top, 26)
            settingsSection
              .padding(.top, 28)
          }
          .frame(maxWidth: 820)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 20)
          .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        BilingualReferenceOfflineBadge(language: language)
          .padding(.top, 10)
          .padding(.trailing, 16)
          .accessibilityIdentifier("bilingual.offlineBadge")
      }
      .navigationBarHidden(true)
      .navigationDestination(for: BilingualReferenceSettingDestination.self) { destination in
        BilingualReferenceDestinationView(destination: destination, language: language)
      }
      .sheet(isPresented: $showsLanguagePicker) {
        BilingualReferenceLanguagePickerSheet(
          language: language,
          onSelect: { model.setLanguage($0); showsLanguagePicker = false }
        )
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
      }
    }
    .tint(BilingualReferencePalette.ink)
  }

  private var analysisCard: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack(alignment: .top, spacing: 12) {
        ZStack {
          Circle().fill(BilingualReferencePalette.softYellow)
          Image(systemName: "sparkles")
            .font(.title3.weight(.semibold))
        }
        .frame(width: 48, height: 48)
        VStack(alignment: .leading, spacing: 5) {
          Text(bilingualReferenceCopy(.youAnalysisTitle, language: language))
            .font(.headline.weight(.bold))
          Text(bilingualReferenceCopy(.youAnalysisBody, language: language))
            .font(.subheadline)
            .foregroundStyle(BilingualReferencePalette.muted)
            .lineSpacing(3)
        }
        Spacer(minLength: 0)
        BilingualReferenceSelfPortrait(language: language, size: 64)
      }
      Text(bilingualReferenceCopy(.youTraitsLabel, language: language))
        .font(.caption2.weight(.bold))
        .tracking(1.2)
        .foregroundStyle(BilingualReferencePalette.muted)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
        ForEach(Array(BilingualReferenceCatalog.traits.prefix(4).enumerated()), id: \.offset) { _, trait in
          BilingualReferenceTraitChip(text: trait.value(for: language))
        }
      }
      NavigationLink(value: BilingualReferenceSettingDestination.analysis) {
        HStack {
          Text(bilingualReferenceCopy(.youAnalysisAction, language: language))
          Spacer()
          Image(systemName: "arrow.up.right")
        }
        .font(.subheadline.weight(.bold))
        .foregroundStyle(BilingualReferencePalette.ink)
      }
      .accessibilityIdentifier("bilingual.you.analysis")
    }
    .padding(18)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(BilingualReferencePalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .accessibilityIdentifier("bilingual.you.analysisCard")
  }

  private var settingsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(bilingualReferenceCopy(.youSettingsLabel, language: language))
        .font(.caption.weight(.bold))
        .tracking(1.4)
        .foregroundStyle(BilingualReferencePalette.muted)
      settingsGroup(
        title: bilingualReferenceCopy(.youPreferencesGroup, language: language)
      ) {
        BilingualReferenceSettingsRow(
          title: bilingualReferenceCopy(.youWardSetup, language: language),
          destination: BilingualReferenceSettingDestination.wardSetup
        )
        .accessibilityIdentifier("bilingual.you.setting.wardSetup")
        Button {
          showsLanguagePicker = true
        } label: {
          settingsRowLabel(bilingualReferenceCopy(.youLanguageRegion, language: language))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bilingual.you.setting.languageRegion")
        BilingualReferenceSettingsRow(
          title: bilingualReferenceCopy(.youMatchPreferences, language: language),
          destination: BilingualReferenceSettingDestination.matchPreferences
        )
        .accessibilityIdentifier("bilingual.you.setting.matchPreferences")
      }
      settingsGroup(
        title: bilingualReferenceCopy(.youAccountGroup, language: language)
      ) {
        BilingualReferenceSettingsRow(
          title: bilingualReferenceCopy(.youPlanPayments, language: language),
          destination: BilingualReferenceSettingDestination.planPayments
        )
        .accessibilityIdentifier("bilingual.you.setting.planPayments")
        BilingualReferenceSettingsRow(
          title: bilingualReferenceCopy(.youNotifications, language: language),
          destination: BilingualReferenceSettingDestination.notifications
        )
        .accessibilityIdentifier("bilingual.you.setting.notifications")
        BilingualReferenceSettingsRow(
          title: bilingualReferenceCopy(.youPrivacySafety, language: language),
          destination: BilingualReferenceSettingDestination.privacySafety
        )
        .accessibilityIdentifier("bilingual.you.setting.privacySafety")
        BilingualReferenceSettingsRow(
          title: bilingualReferenceCopy(.youHelp, language: language),
          destination: BilingualReferenceSettingDestination.help
        )
        .accessibilityIdentifier("bilingual.you.setting.help")
      }
    }
  }

  private func settingsGroup<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.caption2.weight(.bold))
        .tracking(1.2)
        .foregroundStyle(BilingualReferencePalette.muted)
      VStack(spacing: 1, content: content)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(BilingualReferencePalette.line, lineWidth: 1)
        }
    }
  }

  private func settingsRowLabel(_ title: String) -> some View {
    HStack(spacing: 12) {
      Text(title)
        .font(.body.weight(.medium))
      Spacer()
      Image(systemName: "chevron.right")
        .font(.caption.weight(.bold))
        .foregroundStyle(BilingualReferencePalette.muted)
    }
    .foregroundStyle(BilingualReferencePalette.ink)
    .padding(.horizontal, 16)
    .frame(minHeight: 56)
    .background(.white)
  }
}

private struct BilingualReferenceDestinationView: View {
  let destination: BilingualReferenceSettingDestination
  let language: BilingualReferenceLanguage

  var body: some View {
    if destination == .analysis {
      BilingualReferenceAnalysisDetailView(language: language)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          BilingualReferenceSectionLabel(
            text: bilingualReferenceCopy(destination.copyKey, language: language)
          )
          Text(bilingualReferenceCopy(destination.copyKey, language: language))
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .tracking(-1)
          Text(bilingualReferenceCopy(.detailPlaceholder, language: language))
            .font(.body)
            .foregroundStyle(BilingualReferencePalette.muted)
            .lineSpacing(6)
          if destination == .wardSetup {
            VStack(alignment: .leading, spacing: 10) {
              Image(systemName: "person.crop.circle.badge.checkmark")
                .foregroundStyle(BilingualReferencePalette.yellow)
              Text(bilingualReferenceCatalogWardSetupLabel)
                .font(.headline.weight(.bold))
              Text(bilingualReferenceCatalogWardSetupBody)
                .font(.subheadline)
                .foregroundStyle(BilingualReferencePalette.muted)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
          }
        }
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .padding(22)
      }
      .background(BilingualReferencePalette.cream)
      .navigationTitle(bilingualReferenceCopy(destination.copyKey, language: language))
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  private var bilingualReferenceCatalogWardSetupLabel: String {
    BilingualReferenceCatalog.text(.wordsComposerMyWard, language: language)
  }

  private var bilingualReferenceCatalogWardSetupBody: String {
    BilingualReferenceCatalog.text(.wordsComposerLocalNote, language: language)
  }
}

private struct BilingualReferenceLanguagePickerSheet: View {
  let language: BilingualReferenceLanguage
  let onSelect: (BilingualReferenceLanguage) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(bilingualReferenceCopy(.youLanguageRegion, language: language))
        .font(.title3.weight(.bold))
      Text(bilingualReferenceCopy(.detailPlaceholder, language: language))
        .font(.subheadline)
        .foregroundStyle(BilingualReferencePalette.muted)
      ForEach(BilingualReferenceLanguage.allCases) { option in
        Button {
          onSelect(option)
        } label: {
          HStack {
            Text(languageOptionTitle(option))
              .font(.body.weight(.semibold))
            Spacer()
            if option == language {
              Image(systemName: "checkmark")
                .font(.headline.weight(.bold))
            }
          }
          .foregroundStyle(BilingualReferencePalette.ink)
          .frame(minHeight: 48)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bilingual.languagePicker.\(option.rawValue)")
      }
      Spacer(minLength: 0)
    }
    .padding(24)
    .background(BilingualReferencePalette.cream)
    .presentationBackground(BilingualReferencePalette.cream)
  }

  private func languageOptionTitle(_ option: BilingualReferenceLanguage) -> String {
    switch option {
    case .japanese:
      return bilingualReferenceCopy(.languageJapanese, language: language)
    case .english:
      return bilingualReferenceCopy(.languageEnglish, language: language)
    }
  }
}

private struct BilingualReferenceAnalysisDetailView: View {
  let language: BilingualReferenceLanguage

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        BilingualReferenceSectionLabel(
          text: bilingualReferenceCopy(.analysisDetailKicker, language: language)
        )
        Text(bilingualReferenceCopy(.analysisDetailTitle, language: language))
          .font(.system(size: 38, weight: .bold, design: .rounded))
          .tracking(-1.5)
          .lineSpacing(2)
        Text(bilingualReferenceCopy(.analysisDetailBody, language: language))
          .font(.body)
          .foregroundStyle(BilingualReferencePalette.muted)
          .lineSpacing(6)

        VStack(alignment: .leading, spacing: 16) {
          Text(bilingualReferenceCopy(.analysisDetailSummaryLabel, language: language))
            .font(.caption2.weight(.bold))
            .tracking(1.4)
            .foregroundStyle(BilingualReferencePalette.muted)
          Text(bilingualReferenceCopy(.analysisDetailSummary, language: language))
            .font(.title3.weight(.bold))
            .lineSpacing(4)
          Rectangle().fill(BilingualReferencePalette.line).frame(height: 1)
          Text(bilingualReferenceCopy(.analysisDetailStrengthsLabel, language: language))
            .font(.caption2.weight(.bold))
            .tracking(1.4)
            .foregroundStyle(BilingualReferencePalette.muted)
          ForEach([
            BilingualReferenceCopyKey.analysisDetailStrengthOne,
            .analysisDetailStrengthTwo,
            .analysisDetailStrengthThree
          ], id: \.self) { key in
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(BilingualReferencePalette.yellow)
              Text(bilingualReferenceCopy(key, language: language))
                .font(.body.weight(.medium))
            }
          }
        }
        .padding(20)
        .background(.white)
        .overlay {
          RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(BilingualReferencePalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

        VStack(alignment: .leading, spacing: 10) {
          Text(bilingualReferenceCopy(.analysisDetailPracticeLabel, language: language))
            .font(.caption2.weight(.bold))
            .tracking(1.4)
          Text(bilingualReferenceCopy(.analysisDetailPractice, language: language))
            .font(.subheadline)
            .lineSpacing(5)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BilingualReferencePalette.softYellow)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

        Text(bilingualReferenceCopy(.analysisDetailFootnote, language: language))
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
          .frame(maxWidth: .infinity, alignment: .center)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: 680)
      .frame(maxWidth: .infinity)
      .padding(22)
    }
    .background(BilingualReferencePalette.cream)
    .navigationTitle(bilingualReferenceCopy(.youAnalysisTitle, language: language))
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("bilingual.you.analysisDetail")
  }
}

#endif
