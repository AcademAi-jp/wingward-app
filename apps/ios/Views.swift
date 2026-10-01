import Foundation
import SwiftUI

struct RootView: View {
  let controller: AuthSessionController
  let onboardingAPIFactory: (any OnboardingSettingsAPIFactory)?
  let matchesAPIFactory: (any MatchesAPIFactory)?
  let matchDetailAPIFactory: (any MatchDetailAPIFactory)?
  let conversationInsightAPIFactory: (any ConversationInsightAPIFactory)?
  let quizAPIFactory: (any QuizAPIFactory)?
  let nativeIntegration: NativeFeatureIntegration
  let notificationRuntime: WingwardNotificationRuntime?
  let notificationEventsAPIFactory: (any WingwardNotificationEventsAPIFactory)?
  let notificationSeenAPIFactory: (any WingwardNotificationSeenAPIFactory)?
  let requestedRoute: AppRoute?
  let onNotificationRoute: (AppRoute) -> Void
  let onRouteConsumed: () -> Void
  let initiallyShowsMatches: Bool

  @AppStorage(BilingualReferenceLanguagePreference.storageKey)
  private var storedLanguageRawValue = ""
  @State private var selectedLanguage: BilingualReferenceLanguage?

  init(
    controller: AuthSessionController,
    onboardingAPIFactory: (any OnboardingSettingsAPIFactory)? = nil,
    matchesAPIFactory: (any MatchesAPIFactory)? = nil,
    matchDetailAPIFactory: (any MatchDetailAPIFactory)? = nil,
    conversationInsightAPIFactory: (any ConversationInsightAPIFactory)? = nil,
    quizAPIFactory: (any QuizAPIFactory)? = nil,
    nativeIntegration: NativeFeatureIntegration = .unavailable,
    notificationRuntime: WingwardNotificationRuntime? = nil,
    notificationEventsAPIFactory: (any WingwardNotificationEventsAPIFactory)? = nil,
    notificationSeenAPIFactory: (any WingwardNotificationSeenAPIFactory)? = nil,
    requestedRoute: AppRoute? = nil,
    onNotificationRoute: @escaping (AppRoute) -> Void = { _ in },
    onRouteConsumed: @escaping () -> Void = {},
    initiallyShowsMatches: Bool = false
  ) {
    self.controller = controller
    self.onboardingAPIFactory = onboardingAPIFactory
    self.matchesAPIFactory = matchesAPIFactory
    self.matchDetailAPIFactory = matchDetailAPIFactory
    self.conversationInsightAPIFactory = conversationInsightAPIFactory
    self.quizAPIFactory = quizAPIFactory
    self.nativeIntegration = nativeIntegration
    self.notificationRuntime = notificationRuntime
    self.notificationEventsAPIFactory = notificationEventsAPIFactory
    self.notificationSeenAPIFactory = notificationSeenAPIFactory
    self.requestedRoute = requestedRoute
    self.onNotificationRoute = onNotificationRoute
    self.onRouteConsumed = onRouteConsumed
    self.initiallyShowsMatches = initiallyShowsMatches
    _selectedLanguage = State(initialValue: nil)
  }

  @ViewBuilder
  var body: some View {
    content
      .environment(
        \.locale,
        Locale(identifier: (selectedLanguage ?? .english) == .japanese ? "ja" : "en")
      )
      .preferredColorScheme(.light)
      .task {
        notificationRuntime?.install()
        configureNotificationRuntime(for: controller.state)
      }
      .onChange(of: controller.state) { _, state in
        configureNotificationRuntime(for: state)
      }
  }

  @MainActor
  private func configureNotificationRuntime(for state: AuthState) {
    guard let notificationRuntime else { return }
    notificationRuntime.coordinator.onRoute = { [onNotificationRoute] route in
      onNotificationRoute(route)
    }

    guard case let .authenticated(profile) = state,
      let ownerID = profile.id,
      let eventsAPI = notificationEventsAPIFactory?.make(ownerID: ownerID)
    else {
      notificationRuntime.bind(ownerID: nil, reporter: nil, seenAPI: nil)
      return
    }

    let reporter = WingwardNotificationEventReporter(api: eventsAPI)
    let seenAPI = notificationSeenAPIFactory?.make(ownerID: ownerID)
    notificationRuntime.bind(ownerID: ownerID, reporter: reporter, seenAPI: seenAPI)
  }

  @ViewBuilder
  private var content: some View {
    Group {
      if let language = selectedLanguage {
        localizedContent(language)
      } else {
        BilingualProductionLanguageChoiceView(onSelect: selectLanguage)
      }
    }
    .onAppear(perform: restoreLanguage)
  }

  @ViewBuilder
  private func localizedContent(_ language: BilingualReferenceLanguage) -> some View {
    ZStack {
      BilingualReferencePalette.cream.ignoresSafeArea()
      switch controller.state {
      case .booting:
        BlockingView(language: language)
      case .configurationError:
        ConfigurationErrorView(language: language)
      case .signedOut:
        AuthLandingView(controller: controller, language: language)
      case .passwordResetRequest:
        PasswordResetRequestView(controller: controller, language: language)
      case .passwordResetRequested:
        PasswordResetRequestedView(controller: controller, language: language)
      case .passwordRecovery:
        PasswordRecoveryView(controller: controller, language: language)
      case let .awaitingEmailConfirmation(maskedEmail):
        EmailConfirmationView(maskedEmail: maskedEmail, controller: controller, language: language)
      case .needsAgeVerification:
        AgeGateView(controller: controller, language: language)
      case let .authenticated(profile):
        BilingualProductionAuthenticatedView(
          controller: controller,
          profile: profile,
          onboardingAPIFactory: onboardingAPIFactory,
          matchesAPIFactory: matchesAPIFactory,
          matchDetailAPIFactory: matchDetailAPIFactory,
          conversationInsightAPIFactory: conversationInsightAPIFactory,
          quizAPIFactory: quizAPIFactory,
          nativeIntegration: nativeIntegration,
          language: language,
          onLanguageChange: selectLanguage,
          isDebugFixture: onboardingAPIFactory?.isDebugFixture == true || nativeIntegration.isDebugFixture,
          requestedRoute: requestedRoute,
          onRouteConsumed: onRouteConsumed
        )
      case .recoverableError:
        RecoverableErrorView(controller: controller, language: language)
      }
    }
  }

  private func restoreLanguage() {
    guard selectedLanguage == nil else { return }
    selectedLanguage = BilingualReferenceLanguagePreference.language(from: storedLanguageRawValue)
  }

  private func selectLanguage(_ language: BilingualReferenceLanguage) {
    storedLanguageRawValue = BilingualReferenceLanguagePreference.rawValue(for: language)
    selectedLanguage = language
  }
}

struct AuthLandingView: View {
  let controller: AuthSessionController
  let language: BilingualReferenceLanguage
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  init(controller: AuthSessionController, language: BilingualReferenceLanguage = .english) {
    self.controller = controller
    self.language = language
  }

  var body: some View {
    NavigationStack {
      Group {
        if horizontalSizeClass == .regular {
          HStack(spacing: 0) {
            story
            panel
          }
        } else {
          ScrollView {
            VStack(spacing: 0) {
              story
              panel
            }
          }
          .scrollIndicators(.hidden)
        }
      }
      .background(BilingualReferencePalette.cream)
      .toolbar(.hidden, for: .navigationBar)
    }
    .tint(BilingualReferencePalette.ink)
    .preferredColorScheme(.light)
  }

  private var story: some View {
    VStack(alignment: .leading, spacing: 0) {
      Circle()
        .fill(BilingualReferencePalette.yellow)
        .frame(width: 46, height: 46)
        .overlay {
          Image(systemName: "bubble.left.and.bubble.right.fill")
            .font(.headline.weight(.bold))
        }
      Spacer(minLength: 44)
      Text(bilingualReferenceCopy(.authStoryKicker, language: language))
        .font(.caption.weight(.bold))
        .tracking(2)
        .foregroundStyle(BilingualReferencePalette.muted)
      Text(bilingualReferenceCopy(.authStoryTitle, language: language))
        .font(.system(size: 42, weight: .bold))
        .tracking(-1.8)
        .foregroundStyle(BilingualReferencePalette.ink)
        .padding(.top, 14)
      Text(bilingualReferenceCopy(.authStoryBody, language: language))
        .font(.body)
        .foregroundStyle(BilingualReferencePalette.muted)
        .lineSpacing(6)
        .padding(.top, 18)
      Spacer(minLength: 36)
      HStack(spacing: -12) {
        BilingualReferenceSelfPortrait(language: language, size: 58)
        ForEach(Array(BilingualReferenceCatalog.candidates.prefix(2))) { candidate in
          BilingualReferenceAvatar(candidate: candidate, size: 58)
        }
      }
      .accessibilityHidden(true)
    }
    .padding(28)
    .frame(maxWidth: .infinity, minHeight: 470, alignment: .leading)
    .background(
      LinearGradient(
        colors: [
          BilingualReferencePalette.softYellow,
          BilingualReferencePalette.cream,
          .white
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
  }

  private var panel: some View {
    VStack {
      VStack(alignment: .leading, spacing: 0) {
        Circle()
          .fill(BilingualReferencePalette.yellow)
          .frame(width: 42, height: 42)
          .overlay {
            Image(systemName: "person.fill")
              .font(.headline.weight(.bold))
          }
          .padding(.bottom, 22)
        Text(bilingualReferenceCopy(.authWelcomeTitle, language: language))
          .font(.title.weight(.bold))
          .foregroundStyle(BilingualReferencePalette.ink)
        Text(bilingualReferenceCopy(.authWelcomeBody, language: language))
          .font(.subheadline)
          .foregroundStyle(BilingualReferencePalette.muted)
          .lineSpacing(4)
          .padding(.top, 8)

        NavigationLink {
          SignInView(controller: controller, language: language)
        } label: {
          Text(bilingualReferenceCopy(.authSignIn, language: language))
        }
        .buttonStyle(BilingualReferencePrimaryButtonStyle())
        .padding(.top, 26)
        .accessibilityIdentifier("auth.signIn")

        NavigationLink {
          SignUpView(controller: controller, language: language)
        } label: {
          Text(bilingualReferenceCopy(.authCreateAccount, language: language))
        }
        .buttonStyle(BilingualReferenceSecondaryButtonStyle())
        .padding(.top, 10)
        .accessibilityIdentifier("auth.signUp")

        Label(bilingualReferenceCopy(.authProtected, language: language), systemImage: "checkmark.shield")
          .font(.caption)
          .foregroundStyle(BilingualReferencePalette.muted)
          .frame(maxWidth: .infinity)
          .padding(.top, 20)
      }
      .padding(26)
      .frame(maxWidth: 430)
      .background(.white)
      .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
      .shadow(color: BilingualReferencePalette.ink.opacity(0.1), radius: 30, y: 12)
    }
    .padding(22)
    .frame(maxWidth: .infinity, minHeight: 470)
    .background(BilingualReferencePalette.ink)
  }
}

struct SignUpView: View {
  let controller: AuthSessionController
  let language: BilingualReferenceLanguage
  private let showsInputError: Bool

  @State private var email = ""
  @State private var password = ""
  @State private var passwordConfirmation = ""
  @State private var birthDate = SignUpView.defaultBirthDate
  @State private var inputIssue: InputValidationIssue?
  @State private var hasSubmitted = false

  init(
    controller: AuthSessionController,
    language: BilingualReferenceLanguage = .english,
    showsInputError: Bool = false
  ) {
    self.controller = controller
    self.language = language
    self.showsInputError = showsInputError
  }

  fileprivate static var defaultBirthDate: Date {
    BirthDateValidator.exactDate(year: 2000, month: 1, day: 1) ?? Date(timeIntervalSince1970: 0)
  }

  var body: some View {
    FormShell(
      title: bilingualReferenceCopy(.authSignUpTitle, language: language),
      subtitle: bilingualReferenceCopy(.authSignUpSubtitle, language: language),
      language: language
    ) {
      VStack(alignment: .leading, spacing: 18) {
        TextField(bilingualReferenceCopy(.authEmail, language: language), text: $email)
          .textContentType(.emailAddress)
          .keyboardType(.emailAddress)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .accessibilityLabel(bilingualReferenceCopy(.authEmail, language: language))
          .accessibilityIdentifier("signup.email")
          .textFieldStyle(WingwardTextFieldStyle())

        SecureField(bilingualReferenceCopy(.authPassword, language: language), text: $password)
          .textContentType(.newPassword)
          .accessibilityLabel(bilingualReferenceCopy(.authPassword, language: language))
          .accessibilityIdentifier("signup.password")
          .textFieldStyle(WingwardTextFieldStyle())

        SecureField(bilingualReferenceCopy(.authConfirmPassword, language: language), text: $passwordConfirmation)
          .textContentType(.newPassword)
          .accessibilityLabel(bilingualReferenceCopy(.authConfirmPassword, language: language))
          .accessibilityIdentifier("signup.passwordConfirmation")
          .textFieldStyle(WingwardTextFieldStyle())

        DatePicker(
          bilingualReferenceCopy(.authBirthDate, language: language),
          selection: $birthDate,
          in: ...Date(),
          displayedComponents: .date
        )
        .environment(\.calendar, BirthDateValidator.utcGregorianCalendar)
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        .datePickerStyle(.compact)
        .accessibilityIdentifier("signup.birthDate")

        if let issue = inputIssue ?? controller.lastInputError
          ?? (showsInputError ? InputValidationIssue.emailRequired : nil),
          (showsInputError || hasSubmitted || !email.isEmpty || !password.isEmpty || !passwordConfirmation.isEmpty)
        {
          Text(bilingualReferenceAuthError(issue, language: language))
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityIdentifier("signup.inputError")
        }

        Button {
          submit()
        } label: {
          HStack {
            if controller.isSubmitting { ProgressView().tint(.black) }
            Text(
              bilingualReferenceCopy(
                controller.isSubmitting ? .authCreatingAccount : .authCreateAccount,
                language: language
              )
            )
          }
        }
        .buttonStyle(BilingualReferencePrimaryButtonStyle())
        .disabled(controller.isSubmitting)
        .accessibilityIdentifier("signup.submit")
      }
    }
  }

  private func submit() {
    hasSubmitted = true
    let form = SignUpForm(
      email: email,
      password: password,
      passwordConfirmation: passwordConfirmation,
      birthDate: birthDate
    )
    if let issue = form.validated().failure {
      inputIssue = issue
      return
    }
    inputIssue = nil
    Task {
      await controller.signUp(form: form)
    }
  }
}

struct SignInView: View {
  let controller: AuthSessionController
  let language: BilingualReferenceLanguage

  @State private var email = ""
  @State private var password = ""
  @State private var inputIssue: InputValidationIssue?

  init(controller: AuthSessionController, language: BilingualReferenceLanguage = .english) {
    self.controller = controller
    self.language = language
  }

  var body: some View {
    FormShell(
      title: bilingualReferenceCopy(.authSignInTitle, language: language),
      subtitle: bilingualReferenceCopy(.authSignInSubtitle, language: language),
      language: language
    ) {
      VStack(alignment: .leading, spacing: 18) {
        TextField(bilingualReferenceCopy(.authEmail, language: language), text: $email)
          .textContentType(.emailAddress)
          .keyboardType(.emailAddress)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .accessibilityLabel(bilingualReferenceCopy(.authEmail, language: language))
          .accessibilityIdentifier("signin.email")
          .textFieldStyle(WingwardTextFieldStyle())

        PasteButton(payloadType: String.self) { values in
          guard let value = values.first else { return }
          email = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .accessibilityLabel(language == .japanese ? "メールアドレスを貼り付け" : "Paste email")
        .accessibilityIdentifier("signin.email.paste")
        .disabled(controller.isSubmitting)

        SecureField(bilingualReferenceCopy(.authPassword, language: language), text: $password)
          .textContentType(.password)
          .accessibilityLabel(bilingualReferenceCopy(.authPassword, language: language))
          .accessibilityIdentifier("signin.password")
          .textFieldStyle(WingwardTextFieldStyle())

        PasteButton(payloadType: String.self) { values in
          guard let value = values.first else { return }
          password = value
        }
        .accessibilityLabel(language == .japanese ? "パスワードを貼り付け" : "Paste password")
        .accessibilityIdentifier("signin.password.paste")
        .disabled(controller.isSubmitting)

        if let issue = inputIssue {
          Text(bilingualReferenceAuthError(issue, language: language))
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityIdentifier("signin.inputError")
        }

        Button {
          guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            inputIssue = .emailRequired
            return
          }
          guard !password.isEmpty else {
            inputIssue = .passwordRequired
            return
          }
          inputIssue = nil
          Task { await controller.signIn(email: email, password: password) }
        } label: {
          HStack {
            if controller.isSubmitting { ProgressView().tint(.black) }
            Text(
              bilingualReferenceCopy(
                controller.isSubmitting ? .authSigningIn : .authSignIn,
                language: language
              )
            )
          }
        }
        .buttonStyle(BilingualReferencePrimaryButtonStyle())
        .disabled(controller.isSubmitting)
        .accessibilityIdentifier("signin.submit")

        Button(bilingualReferenceCopy(.authForgotPassword, language: language)) {
          controller.beginPasswordResetRequest()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(BilingualReferencePalette.ink)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("signin.forgotPassword")
      }
    }
  }
}

struct PasswordResetRequestView: View {
  let controller: AuthSessionController
  let language: BilingualReferenceLanguage

  @State private var email = ""
  @State private var hasSubmitted = false

  init(controller: AuthSessionController, language: BilingualReferenceLanguage = .english) {
    self.controller = controller
    self.language = language
  }

  var body: some View {
    FormShell(
      title: bilingualReferenceCopy(.authResetTitle, language: language),
      subtitle: bilingualReferenceCopy(.authResetSubtitle, language: language),
      showsBackButton: false,
      language: language
    ) {
      VStack(alignment: .leading, spacing: 18) {
        TextField(bilingualReferenceCopy(.authEmail, language: language), text: $email)
          .textContentType(.emailAddress)
          .keyboardType(.emailAddress)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .accessibilityLabel(bilingualReferenceCopy(.authEmail, language: language))
          .accessibilityIdentifier("passwordReset.email")
          .textFieldStyle(WingwardTextFieldStyle())

        if let issue = controller.lastInputError,
          hasSubmitted || !email.isEmpty
        {
          Text(bilingualReferenceAuthError(issue, language: language))
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityIdentifier("passwordReset.inputError")
        }

        Button {
          hasSubmitted = true
          Task { await controller.resetPassword(email: email) }
        } label: {
          HStack {
            if controller.isSubmitting { ProgressView().tint(.black) }
            Text(
              bilingualReferenceCopy(
                controller.isSubmitting ? .authSending : .authSendResetLink,
                language: language
              )
            )
          }
        }
        .buttonStyle(BilingualReferencePrimaryButtonStyle())
        .disabled(controller.isSubmitting)
        .accessibilityIdentifier("passwordReset.submit")

        Button(bilingualReferenceCopy(.authBackToSignIn, language: language)) {
          controller.returnToSignedOut()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(BilingualReferencePalette.ink)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("passwordReset.backToSignIn")
      }
    }
  }
}

struct PasswordResetRequestedView: View {
  let controller: AuthSessionController
  let language: BilingualReferenceLanguage

  init(controller: AuthSessionController, language: BilingualReferenceLanguage = .english) {
    self.controller = controller
    self.language = language
  }

  var body: some View {
    MessageShell(
      title: bilingualReferenceCopy(.authCheckEmailTitle, language: language),
      message: bilingualReferenceCopy(.authResetRequestedBody, language: language),
      language: language
    ) {
      Button(bilingualReferenceCopy(.authBackToSignIn, language: language)) {
        controller.returnToSignedOut()
      }
      .buttonStyle(BilingualReferencePrimaryButtonStyle())
      .accessibilityIdentifier("passwordResetRequested.backToSignIn")
    }
  }
}

struct PasswordRecoveryView: View {
  let controller: AuthSessionController
  let language: BilingualReferenceLanguage

  @State private var password = ""
  @State private var passwordConfirmation = ""
  @State private var hasSubmitted = false

  init(controller: AuthSessionController, language: BilingualReferenceLanguage = .english) {
    self.controller = controller
    self.language = language
  }

  var body: some View {
    FormShell(
      title: bilingualReferenceCopy(.authRecoveryTitle, language: language),
      subtitle: bilingualReferenceCopy(.authRecoverySubtitle, language: language),
      showsBackButton: false,
      language: language
    ) {
      VStack(alignment: .leading, spacing: 18) {
        SecureField(bilingualReferenceCopy(.authNewPassword, language: language), text: $password)
          .textContentType(.newPassword)
          .accessibilityLabel(bilingualReferenceCopy(.authNewPassword, language: language))
          .accessibilityIdentifier("passwordRecovery.password")
          .textFieldStyle(WingwardTextFieldStyle())

        SecureField(bilingualReferenceCopy(.authConfirmNewPassword, language: language), text: $passwordConfirmation)
          .textContentType(.newPassword)
          .accessibilityLabel(bilingualReferenceCopy(.authConfirmNewPassword, language: language))
          .accessibilityIdentifier("passwordRecovery.passwordConfirmation")
          .textFieldStyle(WingwardTextFieldStyle())

        if let issue = controller.lastInputError,
          hasSubmitted || !password.isEmpty || !passwordConfirmation.isEmpty
        {
          Text(bilingualReferenceAuthError(issue, language: language))
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityIdentifier("passwordRecovery.inputError")
        }

        if controller.hasPasswordUpdateError {
          Text(bilingualReferenceCopy(.authGenericError, language: language))
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityIdentifier("passwordRecovery.error")
        }

        Button {
          hasSubmitted = true
          Task {
            await controller.updatePassword(
              form: PasswordResetForm(
                password: password,
                passwordConfirmation: passwordConfirmation
              )
            )
          }
        } label: {
          HStack {
            if controller.isSubmitting { ProgressView().tint(.black) }
            Text(
              bilingualReferenceCopy(
                controller.isSubmitting ? .authUpdating : .authUpdatePassword,
                language: language
              )
            )
          }
        }
        .buttonStyle(BilingualReferencePrimaryButtonStyle())
        .disabled(controller.isSubmitting)
        .accessibilityIdentifier("passwordRecovery.submit")
      }
    }
  }
}

struct EmailConfirmationView: View {
  let maskedEmail: String
  let controller: AuthSessionController
  let language: BilingualReferenceLanguage

  init(
    maskedEmail: String,
    controller: AuthSessionController,
    language: BilingualReferenceLanguage = .english
  ) {
    self.maskedEmail = maskedEmail
    self.controller = controller
    self.language = language
  }

  var body: some View {
    MessageShell(
      title: bilingualReferenceCopy(.authCheckEmailTitle, language: language),
      message: bilingualReferenceConfirmationMessage(maskedEmail: maskedEmail, language: language),
      language: language
    ) {
      Button(bilingualReferenceCopy(.authBackToSignIn, language: language)) { controller.leaveEmailConfirmation() }
        .buttonStyle(BilingualReferencePrimaryButtonStyle())
        .accessibilityIdentifier("confirmation.backToSignIn")
    }
  }
}

struct AgeGateView: View {
  let controller: AuthSessionController
  let language: BilingualReferenceLanguage

  @State private var birthDate = SignUpView.defaultBirthDate

  init(controller: AuthSessionController, language: BilingualReferenceLanguage = .english) {
    self.controller = controller
    self.language = language
  }

  var body: some View {
    FormShell(
      title: bilingualReferenceCopy(.authAgeTitle, language: language),
      subtitle: bilingualReferenceCopy(.authAgeSubtitle, language: language),
      showsBackButton: false,
      language: language
    ) {
      VStack(alignment: .leading, spacing: 20) {
        DatePicker(
          bilingualReferenceCopy(.authBirthDate, language: language),
          selection: $birthDate,
          in: ...Date(),
          displayedComponents: .date
        )
        .environment(\.calendar, BirthDateValidator.utcGregorianCalendar)
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        .datePickerStyle(.graphical)
        .accessibilityIdentifier("ageGate.birthDate")

        if let issue = controller.lastInputError {
          Text(bilingualReferenceAuthError(issue, language: language))
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityIdentifier("ageGate.inputError")
        }

        Button {
          Task { await controller.submitAgeVerification(birthDate: birthDate) }
        } label: {
          HStack {
            if controller.isSubmitting { ProgressView().tint(.black) }
            Text(
              bilingualReferenceCopy(
                controller.isSubmitting ? .authVerifying : .authVerifyAge,
                language: language
              )
            )
          }
        }
        .buttonStyle(BilingualReferencePrimaryButtonStyle())
        .disabled(controller.isSubmitting)
        .accessibilityIdentifier("ageGate.submit")
      }
    }
  }
}

struct BlockingView: View {
  let language: BilingualReferenceLanguage

  init(language: BilingualReferenceLanguage = .english) {
    self.language = language
  }

  var body: some View {
    MessageShell(
      title: bilingualReferenceCopy(.authLoadingTitle, language: language),
      message: bilingualReferenceCopy(.authLoadingBody, language: language),
      language: language
    ) {
      ProgressView().tint(BilingualReferencePalette.yellow).frame(minHeight: 52)
    }
  }
}

struct ConfigurationErrorView: View {
  let language: BilingualReferenceLanguage

  init(language: BilingualReferenceLanguage = .english) {
    self.language = language
  }

  var body: some View {
    MessageShell(
      title: bilingualReferenceCopy(.authConfigurationTitle, language: language),
      message: bilingualReferenceCopy(.authConfigurationBody, language: language),
      language: language
    ) {}
  }
}

struct RecoverableErrorView: View {
  let controller: AuthSessionController
  let language: BilingualReferenceLanguage

  init(controller: AuthSessionController, language: BilingualReferenceLanguage = .english) {
    self.controller = controller
    self.language = language
  }

  var body: some View {
    MessageShell(
      title: bilingualReferenceCopy(.authRecoverableTitle, language: language),
      message: bilingualReferenceCopy(.authRecoverableBody, language: language),
      language: language
    ) {
      VStack(spacing: 12) {
#if DEBUG
        if AuthDiagnosticPresentation.isEnabled(
          bundleIdentifier: Bundle.main.bundleIdentifier,
          arguments: ProcessInfo.processInfo.arguments
        ), let diagnostic = controller.lastDiagnostic {
          Text("Diagnostic code: \(diagnostic.reportCode)")
            .font(.caption.monospaced())
            .foregroundStyle(BilingualReferencePalette.muted)
            .accessibilityIdentifier("recoverable.diagnosticCode")
        }
#endif
        Button(bilingualReferenceCopy(.authTryAgain, language: language)) { Task { await controller.retry() } }
          .buttonStyle(BilingualReferencePrimaryButtonStyle())
          .disabled(controller.isSubmitting)
          .accessibilityIdentifier("recoverable.retry")
        Button(language == .japanese ? "サインアウトしてログインに戻る" : "Sign out and return to login") {
          Task { await controller.signOut() }
        }
          .disabled(controller.isSubmitting)
          .accessibilityIdentifier("recoverable.signOut")
      }
    }
  }
}

private struct FormShell<Content: View>: View {
  let title: String
  let subtitle: String
  let showsBackButton: Bool
  let language: BilingualReferenceLanguage
  let content: () -> Content
  @Environment(\.dismiss) private var dismiss

  init(
    title: String,
    subtitle: String,
    showsBackButton: Bool = true,
    language: BilingualReferenceLanguage = .english,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.showsBackButton = showsBackButton
    self.language = language
    self.content = content
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if showsBackButton {
            Button {
              dismiss()
            } label: {
              Label(
                bilingualReferenceCopy(.detailBack, language: language),
                systemImage: "chevron.left"
              )
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(BilingualReferencePalette.ink)
            .frame(minHeight: 44)
            .accessibilityIdentifier("auth.form.back")
          }

          VStack(alignment: .leading, spacing: 0) {
              Circle()
                .fill(BilingualReferencePalette.yellow)
                .frame(width: 42, height: 42)
                .overlay {
                  Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.headline.weight(.bold))
                }
                .padding(.bottom, 22)
            Text(title)
              .font(.system(size: 34, weight: .bold))
              .foregroundStyle(BilingualReferencePalette.ink)
              .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
              .font(.body)
              .foregroundStyle(BilingualReferencePalette.muted)
              .lineSpacing(4)
              .padding(.top, 10)
            content()
              .padding(.top, 24)
          }
          .padding(26)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.white)
          .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
              .stroke(BilingualReferencePalette.line, lineWidth: 1)
          }
          .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
          .shadow(color: BilingualReferencePalette.ink.opacity(0.07), radius: 24, y: 10)
        }
        .padding(20)
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .background(
        LinearGradient(
        colors: [.white, BilingualReferencePalette.cream],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .toolbar(.hidden, for: .navigationBar)
    }
    .tint(BilingualReferencePalette.ink)
    .preferredColorScheme(.light)
  }
}

private struct MessageShell<Content: View>: View {
  let title: String
  let message: String
  let language: BilingualReferenceLanguage
  let content: () -> Content

  init(
    title: String,
    message: String,
    language: BilingualReferenceLanguage = .english,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.message = message
    self.language = language
    self.content = content
  }

  var body: some View {
    VStack(spacing: 22) {
      Spacer()
      VStack(spacing: 0) {
        Circle()
          .fill(BilingualReferencePalette.yellow)
          .frame(width: 46, height: 46)
          .overlay {
            Image(systemName: "bubble.left.and.bubble.right.fill")
              .font(.headline.weight(.bold))
          }
          .padding(.bottom, 22)
        Text(title)
          .font(.system(size: 32, weight: .bold))
          .foregroundStyle(BilingualReferencePalette.ink)
          .multilineTextAlignment(.center)
        Text(message)
          .font(.body)
          .foregroundStyle(BilingualReferencePalette.muted)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .lineSpacing(4)
          .padding(.top, 10)
        content()
          .frame(maxWidth: 420)
          .padding(.top, 24)
      }
      .padding(26)
      .frame(maxWidth: 560)
      .frame(maxWidth: .infinity)
      .background(.white)
      .overlay {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
          .stroke(BilingualReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: BilingualReferencePalette.ink.opacity(0.07), radius: 24, y: 10)
      Spacer()
    }
    .padding(20)
    .frame(maxWidth: 620)
    .frame(maxWidth: .infinity)
    .background(BilingualReferencePalette.cream)
    .tint(BilingualReferencePalette.ink)
  }
}

private struct WingwardTextFieldStyle: TextFieldStyle {
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .padding(.horizontal, 16)
      .frame(minHeight: 52)
      .background(BilingualReferencePalette.field)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

#if DEBUG
  #Preview("Signed out") {
    RootView(controller: .preview(state: .signedOut))
  }

  #Preview("Confirmation") {
    RootView(controller: .preview(state: .awaitingEmailConfirmation(maskedEmail: "a••••@example.com")))
  }

  #Preview("Password reset request") {
    RootView(controller: .preview(state: .passwordResetRequest))
  }

  #Preview("Password reset requested") {
    RootView(controller: .preview(state: .passwordResetRequested))
  }

  #Preview("Password recovery") {
    RootView(controller: .preview(state: .passwordRecovery))
  }

  #Preview("Needs age") {
    RootView(controller: .preview(state: .needsAgeVerification))
  }

  #Preview("Authenticated") {
    RootView(controller: .preview(state: .authenticated(profile: .fixture)))
  }

  #Preview("Input error") {
    SignUpView(controller: .preview(state: .signedOut), showsInputError: true)
  }

  #Preview("Recoverable") {
    RootView(controller: .preview(state: .recoverableError))
  }
#endif
