import Foundation
import SwiftUI

/// A match-scoped safety destination shared by meetup and chat-request
/// surfaces. The target is derived from a server-validated match identifier;
/// callers never provide a partner account identifier from view state.
struct PartnerSafetyTarget: Equatable, Sendable {
  let matchID: UUID
  let context: ReportContext

  static func make(matchID: UUID?, context: ReportContext) -> Self? {
    guard let matchID else { return nil }
    return Self(matchID: matchID, context: context)
  }

  func open(using callback: ((UUID, ReportContext) -> Void)?) {
    callback?(matchID, context)
  }
}

struct MeetupView: View {
  let ownerID: String
  let pilotPolicy: MeetupPilotPolicy
  let onOpenVerification: (() -> Void)?
  let onOpenPaywall: ((PaywallSource) -> Void)?
  let onOpenReportForMatch: ((UUID, ReportContext) -> Void)?

  @Environment(\.locale) private var locale
  @State private var store: MeetupStore
  @State private var preferences = MeetupPreferences.empty

  private var copy: MeetupCopy {
    MeetupCopy(locale: locale)
  }

  init(
    ownerID: String,
    meetupID: UUID? = nil,
    matchID: UUID? = nil,
    api: any MeetupsAPI,
    pilotPolicy: MeetupPilotPolicy = .publicDefault,
    onOpenVerification: (() -> Void)? = nil,
    onOpenPaywall: ((PaywallSource) -> Void)? = nil,
    onOpenReportForMatch: ((UUID, ReportContext) -> Void)? = nil
  ) {
    self.ownerID = ownerID
    self.pilotPolicy = pilotPolicy
    self.onOpenVerification = onOpenVerification
    self.onOpenPaywall = onOpenPaywall
    self.onOpenReportForMatch = onOpenReportForMatch
    _store = State(
      initialValue: MeetupStore(
        ownerID: ownerID,
        meetupID: meetupID,
        matchID: matchID,
        api: api
      )
    )
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if pilotPolicy.canSchedule {
            content
          } else {
            unavailableSurface
          }

          if let onOpenReportForMatch,
            let safetyTarget = PartnerSafetyTarget.make(
              matchID: store.expectedMatchID ?? store.detail?.matchID,
              context: .meetup
            )
          {
            Button {
              safetyTarget.open(using: onOpenReportForMatch)
            } label: {
              Label(reportBlockTitle, systemImage: "exclamationmark.shield")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ReferenceOutlineButtonStyle())
            .accessibilityIdentifier("meetup.report")
          }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.hidden)
      .background(ReferencePalette.cream.ignoresSafeArea())
      .navigationTitle(copy.navigationTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(ReferencePalette.cream, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarColorScheme(.light, for: .navigationBar)
    }
    .tint(ReferencePalette.ink)
    .foregroundStyle(ReferencePalette.ink)
    .task(id: ownerID) {
      // Preferences are draft state owned by this destination. Reset them
      // when the signed-in owner changes so one actor's choices cannot appear
      // in another actor's editor.
      preferences = .empty
      guard pilotPolicy.canSchedule else { return }
      await store.load().value
    }
    .onDisappear {
      store.cancel()
    }
    .preferredColorScheme(.light)
  }

  private var reportBlockTitle: String {
    locale.identifier.lowercased().hasPrefix("ja") ? "報告またはブロック" : "Report or block"
  }

  @ViewBuilder
  private var content: some View {
    switch store.viewState {
    case .idle, .loading:
      loadingSurface
    case .intentAvailable:
      if store.canExpressIntent {
        intentSurface
      } else {
        unavailableSurface
      }
    case .intentPending:
      intentPendingSurface
    case let .verifying(gate):
      VStack(alignment: .leading, spacing: 16) {
        MeetupVerificationGateView(
          state: gate,
          onRefresh: { Task { await store.retry().value } },
          onOpenVerification: onOpenVerification
        )
        preferencesSurface
        arrangementButton
      }
    case .arranging:
      arrangingSurface
    case .proposed:
      proposalSurface
    case .arrangeFailed:
      arrangeFailedSurface
    case .confirmed:
      confirmedSurface
    case .expired:
      terminalSurface(title: copy.expiredTitle, message: copy.expiredMessage)
    case .cancelled:
      terminalSurface(title: copy.cancelledTitle, message: copy.cancelledMessage)
    case let .failed(error):
      failureSurface(error)
    }
  }

  private var unavailableSurface: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(copy.unavailableTitle, systemImage: "calendar.badge.exclamationmark")
        .font(.system(size: 28, weight: .bold, design: .rounded))
      Text(copy.unavailableMessage)
        .foregroundStyle(ReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .surfaceCard(fill: ReferencePalette.field)
    .accessibilityIdentifier("meetup.closedPilotUnavailable")
  }

  private var loadingSurface: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(copy.loadingTitle, systemImage: "calendar.badge.clock")
        .font(.system(size: 28, weight: .bold, design: .rounded))
      Text(copy.loadingMessage)
        .foregroundStyle(ReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
      ProgressView()
        .tint(ReferencePalette.ink)
        .frame(minHeight: 48)
        .accessibilityIdentifier("meetup.loading")
    }
    .surfaceCard()
  }

  private var intentSurface: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label(copy.intentEyebrow, systemImage: "calendar.badge.plus")
        .font(.caption.weight(.bold))
        .foregroundStyle(ReferencePalette.muted)
      Text(copy.intentTitle)
        .font(.system(size: 32, weight: .bold, design: .rounded))
      Text(copy.intentMessage)
        .foregroundStyle(ReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
      Button(copy.intentAction) {
        Task { await store.expressIntent().value }
      }
      .buttonStyle(ReferencePrimaryButtonStyle())
      .disabled(!store.canExpressIntent)
      .accessibilityIdentifier("meetup.intent")
    }
    .surfaceCard(fill: ReferencePalette.yellowSoft, border: ReferencePalette.yellow.opacity(0.55))
  }

  private var intentPendingSurface: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(copy.intentPendingTitle, systemImage: "checkmark.circle.fill")
        .font(.title3.weight(.bold))
        .foregroundStyle(ReferencePalette.ink)
      Text(copy.intentPendingMessage)
        .foregroundStyle(ReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
      Button(copy.refreshAction) {
        Task { await store.retry().value }
      }
      .buttonStyle(ReferenceOutlineButtonStyle())
      .accessibilityIdentifier("meetup.intentPending.refresh")
    }
    .surfaceCard(fill: ReferencePalette.yellowSoft, border: ReferencePalette.yellow.opacity(0.55))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("meetup.intentPending")
  }

  private var preferencesSurface: some View {
    MeetupPreferencesEditor(
      preferences: $preferences,
      isSaving: store.phase == .savingPreferences
    ) {
      Task { await store.savePreferences(preferences).value }
    }
  }

  private var arrangementButton: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button(copy.arrangementAction) {
        Task { await store.arrange().value }
      }
      .buttonStyle(ReferencePrimaryButtonStyle())
      .disabled(!store.canArrange)
      .accessibilityIdentifier("meetup.arrange")
      Text(copy.arrangementMessage)
        .font(.footnote)
        .foregroundStyle(ReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .surfaceCard(fill: ReferencePalette.field)
  }

  private var arrangingSurface: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(copy.arrangingTitle, systemImage: "sparkles")
        .font(.system(size: 28, weight: .bold, design: .rounded))
      Text(copy.arrangingMessage)
        .foregroundStyle(ReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
      ProgressView()
        .tint(ReferencePalette.ink)
        .frame(minHeight: 44)
        .accessibilityIdentifier("meetup.arranging")
      Button(copy.arrangingRefreshAction) {
        Task { await store.retry().value }
      }
      .buttonStyle(ReferenceOutlineButtonStyle())
      .accessibilityIdentifier("meetup.arranging.refresh")
    }
    .surfaceCard()
  }

  private var proposalSurface: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label(copy.proposalTitle, systemImage: "calendar")
        .font(.system(size: 30, weight: .bold, design: .rounded))
      Text(copy.proposalMessage)
        .foregroundStyle(ReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
      if let proposal = store.detail?.proposal {
        ForEach(Array(proposal.candidates.enumerated()), id: \.element.id) { index, candidate in
          MeetupCandidateCard(
            index: index,
            candidate: candidate,
            action: { Task { await store.respond(selectedCandidateIndex: index).value } },
            isEnabled: store.canRespond
          )
        }
        if store.canRetryArrangement {
          Button(copy.proposalRetryAction) {
            Task { await store.retryArrangement().value }
          }
          .buttonStyle(ReferenceOutlineButtonStyle())
          .accessibilityIdentifier("meetup.retry")
          Text(copy.proposalRetryMessage)
            .font(.footnote)
            .foregroundStyle(ReferencePalette.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Label(copy.proposalUnavailable, systemImage: "exclamationmark.triangle")
          .foregroundStyle(ReferencePalette.muted)
        Button(copy.refreshAction) {
          Task { await store.retry().value }
        }
        .buttonStyle(ReferenceOutlineButtonStyle())
        .accessibilityIdentifier("meetup.proposal.refresh")
      }
    }
    .surfaceCard()
  }

  private var arrangeFailedSurface: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(copy.arrangeFailedTitle, systemImage: "exclamationmark.triangle")
        .font(.title3.weight(.bold))
      Text(copy.arrangeFailedMessage)
        .foregroundStyle(ReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
      preferencesSurface
      Button(copy.arrangeFailedRetryAction) {
        Task { await store.retryArrangement().value }
      }
      .buttonStyle(ReferencePrimaryButtonStyle())
      .disabled(!store.canRetryArrangement)
      .accessibilityIdentifier("meetup.arrangeFailed.retry")
      Button(copy.refreshAction) {
        Task { await store.retry().value }
      }
      .buttonStyle(ReferenceOutlineButtonStyle())
      .accessibilityIdentifier("meetup.arrangeFailed.refresh")
    }
    .surfaceCard(fill: ReferencePalette.yellowSoft, border: ReferencePalette.yellow.opacity(0.55))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("meetup.arrangeFailed")
  }

  private var confirmedSurface: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(copy.confirmedTitle, systemImage: "checkmark.seal.fill")
        .font(.title2.weight(.bold))
      if let candidate = store.detail?.confirmedCandidate {
        if let dateText = MeetupDateFormatting.dateText(
          for: candidate.startsAt,
          timezone: candidate.timezone
        ) {
          Text(dateText)
            .font(.headline)
          Text(candidate.timezone)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ReferencePalette.muted)
            .accessibilityLabel(copy.timezoneLabel(candidate.timezone))
        } else {
          Label(copy.timeUnavailable, systemImage: "exclamationmark.triangle")
            .foregroundStyle(ReferencePalette.muted)
        }
        Text(copy.candidateSummary(area: candidate.area, format: candidate.format))
          .foregroundStyle(ReferencePalette.muted)
      } else {
        Label(copy.confirmedDetailsUnavailable, systemImage: "exclamationmark.triangle")
          .foregroundStyle(ReferencePalette.muted)
      }
      Text(copy.confirmedSafetyMessage)
        .foregroundStyle(ReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .surfaceCard(fill: ReferencePalette.yellowSoft, border: ReferencePalette.yellow.opacity(0.55))
    .accessibilityIdentifier("meetup.confirmed")
  }

  private func terminalSurface(title: String, message: String) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.system(size: 28, weight: .bold))
      Text(message)
        .foregroundStyle(ReferencePalette.muted)
    }
    .surfaceCard()
  }

  private func failureSurface(_ error: MeetupStoreError) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(copy.failureTitle, systemImage: "exclamationmark.triangle")
        .font(.system(size: 28, weight: .bold, design: .rounded))
      Text(copy.errorMessage(error))
        .foregroundStyle(ReferencePalette.muted)
      if case let .quotaExhausted(source) = error, let source, let onOpenPaywall {
        Button(copy.paywallAction) {
          onOpenPaywall(source)
        }
        .buttonStyle(ReferenceOutlineButtonStyle())
        .accessibilityIdentifier("meetup.paywall")
      } else if case let .quotaExhausted(source) = error, source != nil {
        Text(copy.paywallUnavailable)
          .font(.footnote)
          .foregroundStyle(ReferencePalette.muted)
          .accessibilityIdentifier("meetup.paywall.unavailable")
      }
      Button(copy.retryAction) {
        Task { await store.retry().value }
      }
      .buttonStyle(ReferencePrimaryButtonStyle())
      .accessibilityIdentifier("meetup.retryLoad")
    }
    .surfaceCard(fill: ReferencePalette.field)
  }
}

struct MeetupVerificationGateView: View {
  let state: MeetupVerificationGateState
  let onRefresh: () -> Void
  let onOpenVerification: (() -> Void)?

  @Environment(\.locale) private var locale

  private var copy: MeetupCopy {
    MeetupCopy(locale: locale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(copy.verificationTitle(state), systemImage: "checkmark.shield")
        .font(.title3.weight(.bold))
      Text(copy.verificationMessage(state))
        .foregroundStyle(ReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
      if let onOpenVerification {
        Button(copy.openVerificationAction) {
          onOpenVerification()
        }
        .buttonStyle(ReferencePrimaryButtonStyle())
        .accessibilityIdentifier("meetup.verification.open")
      } else {
        Text(copy.verificationUnavailable)
          .font(.footnote)
          .foregroundStyle(ReferencePalette.muted)
          .accessibilityIdentifier("meetup.verification.unavailable")
      }
      Button(copy.checkAgainAction) {
        onRefresh()
      }
      .buttonStyle(ReferenceOutlineButtonStyle())
      .accessibilityIdentifier("meetup.verification.refresh")
      Text(copy.verificationFootnote)
        .font(.footnote)
        .foregroundStyle(ReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .surfaceCard(fill: ReferencePalette.yellowSoft, border: ReferencePalette.yellow.opacity(0.55))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("meetup.verificationGate")
  }
}

private struct MeetupPreferencesEditor: View {
  @Binding var preferences: MeetupPreferences
  let isSaving: Bool
  let onSave: () -> Void

  @Environment(\.locale) private var locale

  private var copy: MeetupCopy {
    MeetupCopy(locale: locale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(copy.preferencesTitle, systemImage: "slider.horizontal.3")
        .font(.title3.weight(.bold))
      Text(copy.preferencesMessage)
        .font(.subheadline)
        .foregroundStyle(ReferencePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
      DatePicker(copy.fromLabel, selection: startDateBinding, displayedComponents: [.date, .hourAndMinute])
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(ReferencePalette.field)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      DatePicker(copy.untilLabel, selection: endDateBinding, displayedComponents: [.date, .hourAndMinute])
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(ReferencePalette.field)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      TextField(copy.areaPlaceholder, text: areaBinding)
        .textInputAutocapitalization(.words)
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(ReferencePalette.field)
        .overlay {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(ReferencePalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("meetup.preferences.area")
      Picker(copy.budgetLabel, selection: budgetBinding) {
        ForEach(MeetupBudgetBand.allCases, id: \.self) { band in
          Text(copy.budgetName(band)).tag(band)
        }
      }
      .pickerStyle(.segmented)
      .tint(ReferencePalette.yellow)
      .accessibilityIdentifier("meetup.preferences.budget")
      VStack(alignment: .leading, spacing: 8) {
        Text(copy.formatLabel)
          .font(.subheadline.weight(.semibold))
        ForEach(MeetupFormat.allCases, id: \.self) { format in
          Toggle(copy.formatName(format), isOn: formatBinding(format))
            .tint(ReferencePalette.yellow)
            .accessibilityIdentifier("meetup.preferences.format.\(format.rawValue)")
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text(copy.needsLabel)
          .font(.subheadline.weight(.semibold))
        Toggle(
          copy.stepFreeAccess,
          isOn: constraintBinding(key: "accessibility", value: "step_free")
        )
        .tint(ReferencePalette.yellow)
        Toggle(
          copy.vegetarianOptions,
          isOn: constraintBinding(key: "dietary", value: "vegetarian")
        )
        .tint(ReferencePalette.yellow)
      }
      Button(action: {
        if preferences.availability.isEmpty {
          preferences.availability = [
            MeetupAvailability(
              startsAt: startDateBinding.wrappedValue,
              endsAt: endDateBinding.wrappedValue
            )
          ]
        }
        preferences.areas = [areaBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)]
        if preferences.formats.isEmpty { preferences.formats = [.cafe] }
        onSave()
      }) {
        HStack(spacing: 8) {
          if isSaving {
            ProgressView()
              .tint(ReferencePalette.ink)
          }
          Text(isSaving ? copy.savingPreferences : copy.savePreferences)
        }
      }
      .buttonStyle(ReferencePrimaryButtonStyle())
      .disabled(isSaving)
      .accessibilityIdentifier("meetup.preferences.save")
    }
    .surfaceCard()
    .disabled(isSaving)
  }

  private var startDateBinding: Binding<Date> {
    Binding(
      get: {
        preferences.availability.first?.startsAt ?? MeetupPreferenceDefaults.start()
      },
      set: { newValue in
        let currentEnd = preferences.availability.first?.endsAt
          ?? Calendar.current.date(byAdding: .hour, value: 2, to: newValue)
          ?? newValue
        preferences.availability = [MeetupAvailability(startsAt: newValue, endsAt: currentEnd)]
      }
    )
  }

  private var endDateBinding: Binding<Date> {
    Binding(
      get: {
        preferences.availability.first?.endsAt ?? MeetupPreferenceDefaults.end()
      },
      set: { newValue in
        let currentStart = preferences.availability.first?.startsAt
          ?? MeetupPreferenceDefaults.start()
        preferences.availability = [MeetupAvailability(startsAt: currentStart, endsAt: newValue)]
      }
    )
  }

  private var areaBinding: Binding<String> {
    Binding(
      get: { preferences.areas.first ?? "" },
      set: { newValue in
        preferences.areas = [newValue]
      }
    )
  }

  private var budgetBinding: Binding<MeetupBudgetBand> {
    Binding(
      get: { preferences.budgetBand },
      set: { preferences.budgetBand = $0 }
    )
  }

  private func formatBinding(_ format: MeetupFormat) -> Binding<Bool> {
    Binding(
      get: { preferences.formats.contains(format) },
      set: { isSelected in
        if isSelected {
          if !preferences.formats.contains(format) { preferences.formats.append(format) }
        } else {
          preferences.formats.removeAll { $0 == format }
        }
      }
    )
  }

  private func constraintBinding(key: String, value: String) -> Binding<Bool> {
    Binding(
      get: { preferences.constraints[key] == value },
      set: { isSelected in
        if isSelected {
          preferences.constraints[key] = value
        } else {
          preferences.constraints.removeValue(forKey: key)
        }
      }
    )
  }
}

private struct MeetupCandidateCard: View {
  let index: Int
  let candidate: MeetupCandidate
  let action: () -> Void
  let isEnabled: Bool

  @Environment(\.locale) private var locale

  private var copy: MeetupCopy {
    MeetupCopy(locale: locale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(copy.optionLabel(index))
        .font(.caption.weight(.bold))
        .foregroundStyle(ReferencePalette.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(ReferencePalette.yellow)
        .clipShape(Capsule())
      if let dateText = MeetupDateFormatting.dateText(
        for: candidate.startsAt,
        timezone: candidate.timezone
      ) {
        Text(dateText)
          .font(.headline)
        Text(candidate.timezone)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(ReferencePalette.muted)
          .accessibilityLabel(copy.timezoneLabel(candidate.timezone))
      } else {
        Label(copy.timeUnavailable, systemImage: "exclamationmark.triangle")
          .foregroundStyle(ReferencePalette.muted)
      }
      Text(copy.candidateSummary(area: candidate.area, format: candidate.format))
        .foregroundStyle(ReferencePalette.muted)
      if let rationale = candidate.rationale {
        Text(rationale)
          .font(.subheadline)
          .foregroundStyle(ReferencePalette.muted)
      }
      Button(copy.chooseAction(index), action: action)
        .buttonStyle(ReferenceOutlineButtonStyle())
        .disabled(!isEnabled)
        .accessibilityIdentifier("meetup.proposal.\(index)")
    }
    .surfaceCard(fill: ReferencePalette.field)
  }
}

private extension View {
  func surfaceCard(
    fill: Color = .white,
    border: Color = ReferencePalette.line
  ) -> some View {
    self
      .padding(22)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(fill)
      .overlay {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
          .stroke(border, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
      .shadow(color: ReferencePalette.ink.opacity(0.07), radius: 16, y: 8)
  }
}

private struct MeetupCopy {
  private let isJapanese: Bool

  init(locale: Locale) {
    let identifier = locale.identifier.lowercased()
    isJapanese = identifier == "ja"
      || identifier.hasPrefix("ja_")
      || identifier.hasPrefix("ja-")
  }

  private func text(_ japanese: String, _ english: String) -> String {
    isJapanese ? japanese : english
  }

  var navigationTitle: String { text("会う予定", "Meetup") }

  var unavailableTitle: String {
    text("会う予定はまだ利用できません", "Meetups aren’t available yet")
  }

  var unavailableMessage: String {
    text("このアカウントでは現在この機能を利用できません。", "This feature is currently unavailable for your account.")
  }

  var loadingTitle: String { text("会う予定を準備しています", "Preparing your meetup") }
  var loadingMessage: String { text("最新の予定情報を確認しています。", "We’re checking your latest meetup details.") }

  var intentEyebrow: String { text("会ってみたい気持ちを伝える", "LET WINGWARD KNOW") }
  var intentTitle: String { text("心地よいタイミングで会う", "Meet when it feels right") }
  var intentMessage: String {
    text(
      "会ってみてもいいと思ったら、Wardに伝えてください。無料で何度でも使え、ふたりが選ぶまで相手には通知されません。",
      "Tell Ward you’d be open to meeting. This is free and unlimited, and the other person is not notified until you both choose it."
    )
  }
  var intentAction: String { text("会ってみたい", "I’d like to meet") }

  var intentPendingTitle: String { text("気持ちを保存しました", "Your interest is saved") }
  var intentPendingMessage: String {
    text(
      "日程調整が始められるようになったらお知らせします。相手の選択はここには表示されません。",
      "We’ll let you know if scheduling opens. Nothing about the other person’s choice is shown here."
    )
  }

  var arrangementAction: String { text("Wardに日程調整を頼む", "Ask Ward to arrange") }
  var arrangementMessage: String {
    text(
      "日程調整を始める前に、WingWardがふたりの本人確認状態を確認します。",
      "WingWard checks both participants’ verification before any arrangement starts."
    )
  }

  var arrangingTitle: String { text("希望条件を照らし合わせています", "Ward is comparing your preferences") }
  var arrangingMessage: String {
    text(
      "安全な候補が用意されると、3つの選択肢が表示されます。候補を作れない場合は、その旨をお知らせします。",
      "You’ll see three choices when Ward has a safe proposal. If no valid proposal can be made, we’ll tell you."
    )
  }
  var arrangingRefreshAction: String { text("更新を確認", "Check for an update") }

  var proposalTitle: String { text("候補から選ぶ", "Choose a time") }
  var proposalMessage: String {
    text(
      "Wardの3つの候補から選んでください。選択はこの予定のためだけに送られます。",
      "Pick one of these three Ward options. Your choice is sent only for this meetup."
    )
  }
  var proposalUnavailable: String {
    text("候補を表示できません。最新の状態を確認してください。", "The proposal is unavailable. Check the latest meetup state.")
  }
  var proposalRetryAction: String { text("別の候補を試す", "Try another set") }
  var proposalRetryMessage: String {
    text(
      "候補が合わない場合、無料で1回だけ再調整できます。利用枠や購入の判定はサーバーが行います。",
      "One free retry is available for a proposal mismatch. Any quota or purchase decision stays on the server."
    )
  }

  var arrangeFailedTitle: String { text("安全な候補を見つけられませんでした", "Ward couldn’t find a safe arrangement") }
  var arrangeFailedMessage: String {
    text(
      "候補は保存されませんでした。大まかな希望を更新してから、もう一度調整してください。",
      "No proposal was saved. Update your broad preferences, then try the arrangement again."
    )
  }
  var arrangeFailedRetryAction: String { text("もう一度調整する", "Try arrangement again") }
  var refreshAction: String { text("予定を更新", "Refresh meetup") }

  var confirmedTitle: String { text("会う予定が確定しました", "Meetup confirmed") }
  var timeUnavailable: String { text("時間を表示できません", "Time unavailable") }
  var confirmedDetailsUnavailable: String {
    text("確定した時間を表示できません。予定を更新して確認してください。", "The confirmed time is unavailable. Refresh the meetup to check again.")
  }
  var confirmedSafetyMessage: String {
    text(
      "具体的な場所はふたりで決め、公共の場所を選びましょう。会場チェックインと会った後の機能は、招待制のクローズドパイロットに限られます。",
      "Choose the specific venue together and keep your plans in a public place. Venue check-in and post-meetup features are limited to the invited closed pilot."
    )
  }

  var expiredTitle: String { text("この予定の期限が切れました", "This meetup has expired") }
  var expiredMessage: String { text("日程調整の受付期間が終了しています。", "The scheduling window has closed.") }
  var cancelledTitle: String { text("この予定は終了しました", "This meetup is closed") }
  var cancelledMessage: String { text("この日程調整は利用できなくなりました。", "This scheduling thread is no longer available.") }

  var failureTitle: String { text("予定を更新できませんでした", "We couldn’t update this meetup") }
  var paywallAction: String { text("利用できるプランを見る", "See available options") }
  var paywallUnavailable: String {
    text(
      "この画面から購入方法を表示できません。時間をおいて再試行してください。",
      "Purchase options aren’t available from this screen yet. Try again later."
    )
  }
  var retryAction: String { text("もう一度試す", "Try again") }

  func errorMessage(_ error: MeetupStoreError) -> String {
    switch error {
    case .identityVerificationRequired:
      return text(
        "調整を始めるには、ふたりの本人確認が必要です。",
        "Both people must complete identity verification before scheduling."
      )
    case .quotaExhausted:
      return text("いまは日程調整を利用できません。", "Meetup arrangement is unavailable right now.")
    case .ageVerificationRequired:
      return text("日程調整を使う前に、年齢確認を完了してください。", "Verify your age before using meetup scheduling.")
    case .rateLimited:
      return text("少し待ってから、もう一度お試しください。", "Please wait a moment, then try again.")
    case .unauthenticated, .forbidden, .notFound, .invalidRequest, .invalidResponse, .invalidState,
      .temporarilyUnavailable, .cancelled:
      return text("予定を更新できませんでした。もう一度お試しください。", "We couldn’t update this meetup. Try again.")
    }
  }

  func verificationTitle(_ state: MeetupVerificationGateState) -> String {
    switch state {
    case .required: return text("本人確認が必要です", "Identity verification required")
    case .pending: return text("本人確認を進めています", "Verification is in progress")
    case .failed: return text("本人確認を確認してください", "Verification needs attention")
    case .expired: return text("本人確認の期限が切れました", "Verification has expired")
    }
  }

  func verificationMessage(_ state: MeetupVerificationGateState) -> String {
    switch state {
    case .required:
      return text(
        "日程調整を始めるには、ふたりの本人確認が必要です。",
        "Both people must be verified before WingWard can arrange a meetup."
      )
    case .pending:
      return text(
        "WingWardが本人確認を認めるまで、日程調整は利用できません。",
        "Scheduling will become available after WingWard confirms verification."
      )
    case .failed:
      return text(
        "本人確認が正常に完了するまで、日程調整は一時停止します。",
        "Scheduling stays paused until verification is completed successfully."
      )
    case .expired:
      return text(
        "会う予定の調整を始める前に、もう一度本人確認を完了してください。",
        "Please complete verification again before arranging a meetup."
      )
    }
  }

  var openVerificationAction: String { text("本人確認を開く", "Open verification") }
  var verificationUnavailable: String {
    text(
      "この画面から本人確認を開始できません。利用できる本人確認フローを完了してから、もう一度確認してください。",
      "Verification can’t be started from this screen yet. Complete the available verification flow, then check again."
    )
  }
  var checkAgainAction: String { text("もう一度確認", "Check again") }
  var verificationFootnote: String {
    text(
      "WingWardはこの端末だけで本人確認完了とは判定しません。ふたりの確認がサーバーで認められてから日程調整が始まります。",
      "WingWard never marks verification complete on this device. Scheduling opens only after WingWard confirms both people."
    )
  }

  var preferencesTitle: String { text("会う予定の希望条件", "Your meetup preferences") }
  var preferencesMessage: String {
    text(
      "空いている時間帯と市区町村・エリアを大まかに共有します。ここでは会場や正確な位置情報を尋ねません。",
      "Share broad availability and a city/ward area. WingWard does not ask for a venue or exact location here."
    )
  }
  var fromLabel: String { text("開始", "From") }
  var untilLabel: String { text("終了", "Until") }
  var areaPlaceholder: String { text("市区町村・エリア", "City / ward") }
  var budgetLabel: String { text("予算", "Budget") }
  var formatLabel: String { text("形式", "Format") }
  var needsLabel: String { text("希望条件", "Needs") }
  var stepFreeAccess: String { text("段差のない場所", "Step-free access") }
  var vegetarianOptions: String { text("ベジタリアン対応", "Vegetarian options") }
  var savePreferences: String { text("希望条件を保存", "Save preferences") }
  var savingPreferences: String { text("保存中…", "Saving…") }

  func formatName(_ format: MeetupFormat) -> String {
    switch format {
    case .cafe: return text("カフェ", "Café")
    case .meal: return text("食事", "Meal")
    case .activity: return text("アクティビティ", "Activity")
    case .online: return text("オンライン", "Online")
    }
  }

  func budgetName(_ budget: MeetupBudgetBand) -> String {
    switch budget {
    case .low: return text("控えめ", "Low")
    case .medium: return text("標準", "Medium")
    case .high: return text("高め", "High")
    }
  }

  func optionLabel(_ index: Int) -> String {
    text("候補 \(index + 1)", "Option \(index + 1)")
  }

  func chooseAction(_ index: Int) -> String {
    text("候補 \(index + 1)を選ぶ", "Choose option \(index + 1)")
  }

  func candidateSummary(area: String, format: MeetupFormat) -> String {
    "\(area) \(isJapanese ? "・" : "·") \(formatName(format))"
  }

  func timezoneLabel(_ timezone: String) -> String {
    text("タイムゾーン \(timezone)", "Timezone \(timezone)")
  }
}
