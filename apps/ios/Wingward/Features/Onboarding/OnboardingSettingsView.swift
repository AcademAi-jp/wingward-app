import SwiftUI

private enum OnboardingViewPalette {
  static let cream = ReferencePalette.cream
  static let ink = ReferencePalette.ink
  static let yellow = ReferencePalette.yellow
  static let yellowSoft = ReferencePalette.yellowSoft
  static let accentText = Color(red: 0.57, green: 0.44, blue: 0.0)
  static let muted = ReferencePalette.muted
  static let surface = ReferencePalette.field
  static let selectedSurface = yellowSoft
  static let line = ReferencePalette.line
}

private struct OnboardingChoiceButton: View {
  let title: String
  let isSelected: Bool
  let identifier: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Text(title)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 8)
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(OnboardingViewPalette.accentText)
            .accessibilityHidden(true)
        }
      }
      .font(.body.weight(isSelected ? .semibold : .regular))
      .foregroundStyle(OnboardingViewPalette.ink)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
      .background(isSelected ? OnboardingViewPalette.selectedSurface : OnboardingViewPalette.surface)
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(
            isSelected ? OnboardingViewPalette.accentText : OnboardingViewPalette.line,
            lineWidth: isSelected ? 1.5 : 1
          )
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

struct OnboardingSettingsView: View {
  let controller: AuthSessionController
  let ownerID: String
  let isDebugFixture: Bool
  let quizAPIFactory: (any QuizAPIFactory)?
  let nativeIntegration: NativeFeatureIntegration
  let allowsPostOnboardingFeatures: Bool
  let onCompleted: () -> Void
  @State private var store: OnboardingSettingsStore
  @State private var loadedDisplayLanguage: OnboardingLanguage?
  @State private var showsQuiz = false

  init(
    controller: AuthSessionController,
    ownerID: String,
    api: any OnboardingSettingsAPI,
    isDebugFixture: Bool = false,
    quizAPIFactory: (any QuizAPIFactory)? = nil,
    nativeIntegration: NativeFeatureIntegration = .unavailable,
    allowsPostOnboardingFeatures: Bool = false,
    onCompleted: @escaping () -> Void = {}
  ) {
    self.controller = controller
    self.ownerID = ownerID
    self.isDebugFixture = isDebugFixture
    self.quizAPIFactory = quizAPIFactory
    self.nativeIntegration = nativeIntegration
    self.allowsPostOnboardingFeatures = allowsPostOnboardingFeatures
    self.onCompleted = onCompleted
    _store = State(initialValue: OnboardingSettingsStore(ownerID: ownerID, api: api))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          switch store.phase {
          case .idle, .loading:
            loadingSurface
          case let .failed(error):
            failureSurface(error)
          case .loaded, .saving:
            settingsSurface
          }
        }
        .padding(20)
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .background(OnboardingViewPalette.cream)
      .navigationTitle("Your settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.white, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarColorScheme(.light, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          ReferenceBrand()
            .scaleEffect(0.82, anchor: .leading)
            .accessibilityHidden(true)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Sign out") {
            Task { await controller.signOut() }
          }
          .disabled(controller.isSubmitting)
          .accessibilityIdentifier("authenticated.signOut")
        }
      }
    }
    .background(OnboardingViewPalette.cream.ignoresSafeArea())
    .tint(OnboardingViewPalette.ink)
    .task(id: ownerID) {
      await store.load().value
      if !Task.isCancelled {
        loadedDisplayLanguage = store.draft.uiLocale
      }
    }
    .onDisappear {
      store.cancel()
    }
    .preferredColorScheme(.light)
    .sheet(isPresented: $showsQuiz) {
      if let quizAPI = quizAPIFactory?.make(ownerID: ownerID) {
        QuizView(
          ownerID: ownerID,
          api: quizAPI,
          locale: loadedDisplayLanguage ?? store.draft.uiLocale ?? .en,
          onDismiss: { showsQuiz = false }
        )
      } else {
        Text("The quiz is unavailable right now.")
          .font(.body)
          .foregroundStyle(OnboardingViewPalette.muted)
          .padding(24)
      }
    }
  }

  private var loadingSurface: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Preparing your settings")
        .font(.system(size: 34, weight: .bold))
      Text("We’re checking your saved choices.")
        .foregroundStyle(OnboardingViewPalette.muted)
      ProgressView()
        .tint(OnboardingViewPalette.accentText)
        .frame(minHeight: 48)
        .accessibilityIdentifier("onboarding.loading")
    }
    .padding(26)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(OnboardingViewPalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    .shadow(color: OnboardingViewPalette.ink.opacity(0.07), radius: 24, y: 10)
  }

  private func failureSurface(_ error: OnboardingSettingsStoreError) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("We couldn’t load your settings")
        .font(.system(size: 34, weight: .bold))
      Text(error.userMessage)
        .foregroundStyle(OnboardingViewPalette.muted)
      Button("Try again") {
        Task { await store.retry().value }
      }
      .buttonStyle(ReferencePrimaryButtonStyle())
      .accessibilityIdentifier("onboarding.retry")
    }
    .padding(26)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(OnboardingViewPalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    .shadow(color: OnboardingViewPalette.ink.opacity(0.07), radius: 24, y: 10)
  }

  private var settingsSurface: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Tell Wingward what feels right for your next conversation.")
          .font(.system(size: 28, weight: .bold))
        Text("You can change these choices later. Nothing is saved until you confirm.")
          .foregroundStyle(OnboardingViewPalette.muted)
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.white)
      .overlay {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .stroke(OnboardingViewPalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

      if isDebugFixture {
        Text("DEBUG FIXTURE · synthetic preview · no account changes")
          .font(.caption.weight(.bold))
          .foregroundStyle(OnboardingViewPalette.accentText)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(OnboardingViewPalette.selectedSurface)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .accessibilityIdentifier("onboarding.debugFixture")
      } else {
        Text(store.didConfirmSave ? "Saved to your account." : "Not saved yet.")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(store.didConfirmSave ? OnboardingViewPalette.accentText : OnboardingViewPalette.muted)
          .accessibilityIdentifier("onboarding.saveStatus")
      }

      displayLanguageSection
      conversationLanguageSection
      marketSection
      timezoneSection
      distanceSection
      identitySection
      preferenceSection
      locationSection
      termsSection
      saveSection
      if quizAPIFactory != nil {
        conversationQuizSurface
      }
      if hasNativeFeatures {
        nativeFeaturesSurface
      }
      if !isDebugFixture, store.serverConfirmedCompletion {
        Button("View matches", action: onCompleted)
          .buttonStyle(ReferencePrimaryButtonStyle())
          .accessibilityIdentifier("onboarding.viewMatches")
      }
      aiInterviewPending
    }
    .disabled(store.isSaving)
  }

  private var conversationQuizSurface: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Conversation quiz", systemImage: "square.grid.2x2")
        .font(.headline.weight(.semibold))
        .foregroundStyle(OnboardingViewPalette.accentText)
      Text("Answer preference and personality questions to reflect in your persona.")
        .font(.footnote)
        .foregroundStyle(OnboardingViewPalette.muted)
      Button("Take the quiz") {
        guard !store.isSaving else { return }
        showsQuiz = true
      }
      .buttonStyle(ReferencePrimaryButtonStyle())
      .accessibilityIdentifier("onboarding.conversationQuiz.open")
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(OnboardingViewPalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private var hasNativeFeatures: Bool {
    nativeIntegration.voiceProfile != nil
      || nativeIntegration.profilePhoto != nil
      || nativeIntegration.directChats != nil
      || nativeIntegration.meetups != nil
      || nativeIntegration.billing != nil
      || nativeIntegration.accountSafety != nil
  }

  private var nativeFeaturesSurface: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("More Wingward features", systemImage: "square.grid.2x2")
        .font(.headline.weight(.semibold))
        .foregroundStyle(OnboardingViewPalette.accentText)
      Text("Open voice, chats, meetup scheduling, billing, and account safety from one place.")
        .font(.footnote)
        .foregroundStyle(OnboardingViewPalette.muted)
      NavigationLink {
        NativeFeatureHubView(
          ownerID: ownerID,
          integration: nativeIntegration,
          allowsPostOnboardingFeatures: allowsPostOnboardingFeatures,
          callbacks: NativeFeatureCallbacks(onOpenSettings: onCompleted)
        )
      } label: {
        Label("Open feature hub", systemImage: "arrow.up.right.square")
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      }
      .buttonStyle(ReferenceOutlineButtonStyle())
      .accessibilityIdentifier("onboarding.nativeFeatures.open")
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(OnboardingViewPalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private var displayLanguageSection: some View {
    section(title: "Display language", subtitle: "Choose the language used around Wingward.") {
      HStack(spacing: 10) {
        choice(title: "日本語", selected: store.draft.uiLocale == .ja, id: "onboarding.uiLocale.ja") {
          store.setUILocale(.ja)
        }
        choice(title: "English", selected: store.draft.uiLocale == .en, id: "onboarding.uiLocale.en") {
          store.setUILocale(.en)
        }
      }
    }
  }

  private var conversationLanguageSection: some View {
    section(title: "Conversation language", subtitle: "This is separate from the app display language.") {
      HStack(spacing: 10) {
        choice(title: "日本語", selected: store.draft.conversationLanguage == .ja, id: "onboarding.conversationLanguage.ja") {
          store.setConversationLanguage(.ja)
        }
        choice(title: "English", selected: store.draft.conversationLanguage == .en, id: "onboarding.conversationLanguage.en") {
          store.setConversationLanguage(.en)
        }
      }
    }
  }

  private var marketSection: some View {
    section(title: "Dating market", subtitle: "This choice controls the available location options.") {
      HStack(spacing: 10) {
        choice(title: "Japan", selected: store.draft.datingMarket == .JP, id: "onboarding.market.jp") {
          store.setDatingMarket(.JP)
        }
        choice(title: "United States", selected: store.draft.datingMarket == .US, id: "onboarding.market.us") {
          store.setDatingMarket(.US)
        }
      }
    }
  }

  private var timezoneSection: some View {
    section(title: "Time zone", subtitle: "Use an IANA time zone such as Asia/Tokyo.") {
      Picker(
        "Time zone",
        selection: Binding<String>(
          get: { store.draft.timezone ?? "" },
          set: { value in
            guard !value.isEmpty else { return }
            store.setTimezone(value)
          }
        )
      ) {
        Text("Choose…").tag("")
        ForEach(OnboardingTimeZoneCatalog.choices(including: store.draft.timezone), id: \.self) { value in
          Text(value).tag(value)
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .frame(minHeight: 48)
      .background(OnboardingViewPalette.surface)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .accessibilityLabel("Time zone")
      .accessibilityIdentifier("onboarding.timezone")
    }
  }

  private var distanceSection: some View {
    section(title: "Distance unit", subtitle: "Choose how distances should be shown.") {
      HStack(spacing: 10) {
        choice(title: "Kilometres", selected: store.draft.distanceUnit == .km, id: "onboarding.distance.km") {
          store.setDistanceUnit(.km)
        }
        choice(title: "Miles", selected: store.draft.distanceUnit == .mi, id: "onboarding.distance.mi") {
          store.setDistanceUnit(.mi)
        }
      }
    }
  }

  private var identitySection: some View {
    section(title: "Your identity", subtitle: "This is private. Choose prefer not to say if you do not want to answer.") {
      VStack(spacing: 10) {
        choice(title: "Prefer not to say", selected: isIdentitySelected(.noAnswer), id: "onboarding.identity.noAnswer") {
          store.setGenderIdentity(.noAnswer)
        }
        HStack(spacing: 10) {
          choice(title: "Woman", selected: isIdentitySelected(.selected(.woman)), id: "onboarding.identity.woman") {
            store.setGenderIdentity(.selected(.woman))
          }
          choice(title: "Man", selected: isIdentitySelected(.selected(.man)), id: "onboarding.identity.man") {
            store.setGenderIdentity(.selected(.man))
          }
        }
        choice(title: "Non-binary", selected: isIdentitySelected(.selected(.nonbinary)), id: "onboarding.identity.nonbinary") {
          store.setGenderIdentity(.selected(.nonbinary))
        }
      }
    }
  }

  private var preferenceSection: some View {
    section(title: "Preferred genders", subtitle: "Choose up to three, or prefer not to say.") {
      VStack(spacing: 10) {
        VStack(spacing: 10) {
          choice(title: "Choose preferences", selected: store.draft.preferenceMode == .selected, id: "onboarding.preferences.selected") {
            store.setPreferenceMode(.selected)
          }
          choice(title: "Prefer not to say", selected: store.draft.preferenceMode == .noAnswer, id: "onboarding.preferences.noAnswer") {
            store.setPreferenceMode(.noAnswer)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if store.draft.preferenceMode == .selected {
          HStack(spacing: 10) {
            preferredGenderChoice(.woman, title: "Women")
            preferredGenderChoice(.man, title: "Men")
          }
          preferredGenderChoice(.nonbinary, title: "Non-binary")
        } else if store.draft.preferenceMode == .noAnswer {
          Text("Your preference answer will remain private.")
            .font(.footnote)
            .foregroundStyle(OnboardingViewPalette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("onboarding.noAnswerNotice")
        }
      }
    }
  }

  private var locationSection: some View {
    section(title: "Usual location", subtitle: "Use a usual station or a broad area. We do not ask for your address or current location.") {
      VStack(spacing: 10) {
        HStack(spacing: 10) {
          choice(title: "Station", selected: store.draft.locationMode == .station, id: "onboarding.location.station") {
            store.setLocationMode(.station)
          }
          if store.draft.datingMarket == .US {
            choice(title: "No public transit", selected: store.draft.locationMode == .noTransit, id: "onboarding.location.noTransit") {
              store.setLocationMode(.noTransit)
            }
          }
        }
        choice(title: "Prefer not to set", selected: store.draft.locationMode == .notSet, id: "onboarding.location.notSet") {
          store.setLocationMode(.notSet)
        }

        if store.draft.locationMode == .station || store.draft.locationMode == .noTransit {
          if store.options == nil {
            locationOptionsStatus
          } else {
            if store.draft.locationMode == .station {
              stationPicker
            }
            areaPicker
          }
        } else {
          Text("You can choose a location later.")
            .font(.footnote)
            .foregroundStyle(OnboardingViewPalette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  private var locationOptionsStatus: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        store.optionsError == nil
          ? "Loading location options…"
          : "Location options are unavailable."
      )
      .font(.footnote)
      .foregroundStyle(OnboardingViewPalette.muted)
      .accessibilityIdentifier("onboarding.optionsStatus")

      if store.optionsError != nil {
        Button("Try again") {
          guard let task = store.retryOptions() else { return }
          Task { await task.value }
        }
        .buttonStyle(ReferenceOutlineButtonStyle())
        .disabled(store.isBusy)
        .accessibilityIdentifier("onboarding.optionsRetry")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var stationPicker: some View {
    if let options = store.options {
      Picker(
        "Usual station",
        selection: Binding<String>(
          get: { store.draft.stationID ?? "" },
          set: { value in store.setStationID(value.isEmpty ? nil : value) }
        )
      ) {
        Text("Choose a station…").tag("")
        ForEach(options.stations, id: \.id) { station in
          Text(station.name).tag(station.id)
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .frame(minHeight: 48)
      .background(OnboardingViewPalette.surface)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .accessibilityLabel("Usual station")
      .accessibilityIdentifier("onboarding.station")
    }
  }

  @ViewBuilder
  private var areaPicker: some View {
    if let options = store.options {
      Picker(
        "Broad area",
        selection: Binding<String>(
          get: { store.draft.coarseAreaID ?? "" },
          set: { value in store.setCoarseAreaID(value.isEmpty ? nil : value) }
        )
      ) {
        Text("Choose an area…").tag("")
        ForEach(options.areas, id: \.id) { area in
          Text(area.name).tag(area.id)
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .frame(minHeight: 48)
      .background(OnboardingViewPalette.surface)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .accessibilityLabel("Broad area")
      .accessibilityIdentifier("onboarding.area")
    }
  }

  private var termsSection: some View {
    Text("Location choices are a draft fixture catalog for this pilot and may change.")
      .font(.footnote)
      .foregroundStyle(OnboardingViewPalette.muted)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("onboarding.optionsTerms")
  }

  private var saveSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let issue = store.validationError {
        Text(issue.userMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .accessibilityIdentifier("onboarding.validationError")
      }
      if store.saveError != nil {
        Text("We couldn’t save your settings. Try again.")
          .font(.footnote)
          .foregroundStyle(.red)
          .accessibilityIdentifier("onboarding.saveError")
      }
      Button {
        Task {
          await store.save().value
          if store.didConfirmSave {
            loadedDisplayLanguage = store.draft.uiLocale
          }
        }
      } label: {
        HStack {
          if store.isSaving { ProgressView().tint(.black) }
          Text(isDebugFixture ? "Preview only" : (store.isSaving ? "Saving…" : "Save settings"))
        }
      }
      .buttonStyle(ReferencePrimaryButtonStyle())
      .disabled(isDebugFixture || !store.canSave)
      .accessibilityIdentifier("onboarding.save")
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(OnboardingViewPalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private var aiInterviewPending: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Next AI interview", systemImage: "sparkles")
        .font(.headline.weight(.semibold))
        .foregroundStyle(OnboardingViewPalette.accentText)
      Text("Coming soon · pending")
        .font(.title3.weight(.bold))
      Text("Your settings will guide the interview when that module is available.")
        .font(.footnote)
        .foregroundStyle(OnboardingViewPalette.muted)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(OnboardingViewPalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityIdentifier("onboarding.aiInterviewPending")
  }

  private func section<Content: View>(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.headline.weight(.semibold))
      Text(subtitle)
        .font(.footnote)
        .foregroundStyle(OnboardingViewPalette.muted)
      content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.white)
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(OnboardingViewPalette.line, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private func choice(title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
    OnboardingChoiceButton(title: title, isSelected: selected, identifier: id, action: action)
  }

  private func preferredGenderChoice(_ value: OnboardingGenderCategory, title: String) -> some View {
    choice(
      title: title,
      selected: store.draft.preferredGenders.contains(value),
      id: "onboarding.preferred.\(value.rawValue)"
    ) {
      store.togglePreferredGender(value)
    }
  }

  private func isIdentitySelected(_ value: OnboardingGenderIdentitySelection) -> Bool {
    store.draft.genderIdentity == value
  }
}
