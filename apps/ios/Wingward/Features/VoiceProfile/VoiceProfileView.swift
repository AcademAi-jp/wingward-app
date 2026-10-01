import Foundation
import SwiftUI

struct VoiceProfileView: View {
  let ownerID: String
  let module: VoiceProfileModule
  let onConfirmed: (() -> Void)?

  @State private var store: VoiceProfileStore
  @State private var editsDraft = false
  @State private var draftTags = ""
  @State private var draftBio = ""
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale

  init(
    ownerID: String,
    module: VoiceProfileModule,
    onConfirmed: (() -> Void)? = nil
  ) {
    self.ownerID = ownerID
    self.module = module
    self.onConfirmed = onConfirmed
    _store = State(initialValue: VoiceProfileStore(ownerID: ownerID, module: module))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          journeyHeader
          phaseSurface
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.hidden)
      .background(VoiceProfilePalette.cream.ignoresSafeArea())
      .navigationTitle(copy.navigationTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.white, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarColorScheme(.light, for: .navigationBar)
    }
    .tint(VoiceProfilePalette.ink)
    .task(id: ownerID) {
      await store.load().value
      if store.needsPersonaGeneration { await store.generatePersonas().value }
    }
    .onDisappear {
      store.cancel()
    }
    .preferredColorScheme(.light)
  }

  private var language: OnboardingLanguage {
    let identifier = locale.identifier.lowercased()
    return identifier.hasPrefix("ja") ? .ja : .en
  }

  private var copy: VoiceProfileCopy {
    VoiceProfileCopy(language: language)
  }

  @ViewBuilder
  private var phaseSurface: some View {
    switch store.phase {
    case .idle, .loading:
      loadingSurface
    case .candidates, .permissionDenied:
      candidatesSurface
    case let .failed(error):
      if error == .generationFailed {
        generationSurface
      } else {
        candidatesSurface
      }
    case .connecting, .interviewing, .savingInterview, .completionFailed:
      interviewSurface
    case .readyToGenerate, .generating:
      generationSurface
    case .review, .confirming, .confirmed:
      reviewSurface
    }
  }

  private var journeyHeader: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 14) {
        VoiceProfileIconBadge(systemImage: "waveform")

        VStack(alignment: .leading, spacing: 6) {
          Text(copy.eyebrow)
            .font(.caption.weight(.bold))
            .tracking(1.8)
            .foregroundStyle(VoiceProfilePalette.muted)
          Text(copy.headerTitle)
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .tracking(-1.2)
            .lineSpacing(2)
        }
      }

      Text(copy.headerBody)
        .font(.body)
        .foregroundStyle(VoiceProfilePalette.muted)
        .lineSpacing(5)

      HStack(spacing: 12) {
        Image(systemName: "checkmark.circle.fill")
          .font(.headline.weight(.semibold))
          .foregroundStyle(VoiceProfilePalette.accentText)
          .accessibilityHidden(true)
        Text(copy.progressLabel)
          .font(.subheadline.weight(.semibold))
        Spacer(minLength: 12)
        Text("\(store.completedPersonaIDs.count)/\(store.requiredInterviewCount)")
          .font(.headline.weight(.bold).monospacedDigit())
          .accessibilityLabel(copy.progressValueLabel(store.completedPersonaIDs.count, required: store.requiredInterviewCount))
      }
      .foregroundStyle(VoiceProfilePalette.ink)
      .padding(.horizontal, 16)
      .frame(minHeight: 48)
      .background(VoiceProfilePalette.softYellow)
      .clipShape(Capsule())
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("voiceProfile.progress")
    }
  }

  private var loadingSurface: some View {
    VoiceProfileCard {
      VStack(alignment: .leading, spacing: 16) {
        VoiceProfileCardHeading(
          systemImage: "sparkles",
          title: copy.loadingTitle,
          subtitle: copy.loadingBody
        )

        HStack(spacing: 12) {
          ProgressView()
            .tint(VoiceProfilePalette.accentText)
            .accessibilityIdentifier("voiceProfile.loading")
          Text(copy.loadingStatus)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(VoiceProfilePalette.muted)
        }
        .frame(minHeight: 44, alignment: .leading)
      }
    }
  }

  private var candidatesSurface: some View {
    VStack(alignment: .leading, spacing: 16) {
      VoiceProfileCard {
        VoiceProfileCardHeading(
          systemImage: "person.3.fill",
          title: copy.candidatesTitle,
          subtitle: copy.candidatesBody
        )
      }

      if module.bootstrapKind == .openAIRealtime {
        VoiceProfileCard {
          Picker(locale.language.languageCode?.identifier == "ja" ? "1人目の声（3人とも異なる声）" : "First voice (three distinct voices)", selection: $store.selectedRealtimeVoice) {
            Text(locale.language.languageCode?.identifier == "ja" ? "男性の声 · Cedar" : "Masculine · Cedar").tag(RealtimeVoice.cedar)
            Text(locale.language.languageCode?.identifier == "ja" ? "女性の声 · Marin" : "Feminine · Marin").tag(RealtimeVoice.marin)
            Text(locale.language.languageCode?.identifier == "ja" ? "落ち着いた声 · Ash" : "Calm · Ash").tag(RealtimeVoice.ash)
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("realtime-voice-picker")
        }
      }

      if case let .failed(error) = store.phase {
        errorBanner(error)
      } else if store.phase == .permissionDenied {
        errorBanner(.microphonePermissionDenied)
      }

      if !module.transport.isAvailable && store.phase != .failed(.voiceUnavailable) {
        VoiceProfileCard {
          VoiceProfileCardHeading(
            systemImage: "waveform.slash",
            title: copy.voiceUnavailableTitle,
            subtitle: copy.voiceUnavailableBody
          )
        }
      }

      if store.needsPersonaGeneration {
        VoiceProfileCard {
          VStack(alignment: .leading, spacing: 16) {
            VoiceProfileCardHeading(
              systemImage: "sparkles",
              title: copy.prepareTitle,
              subtitle: copy.prepareBody
            )
            Button {
              Task { await store.generatePersonas().value }
            } label: {
              Label(copy.prepareButton, systemImage: "arrow.clockwise")
            }
            .buttonStyle(VoiceProfilePrimaryButtonStyle())
            .accessibilityIdentifier("voiceProfile.generatePersonas")
          }
        }
      } else {
        ForEach(store.personas) { persona in
          personaCard(persona)
        }
      }
    }
  }

  private func personaCard(_ persona: VoicePersona) -> some View {
    VoiceProfileCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 14) {
          VoiceProfilePersonaBadge(name: persona.name)

          VStack(alignment: .leading, spacing: 5) {
            Text(persona.name)
              .font(.headline.weight(.bold))
              .lineLimit(2)
            Text("\(copy.personaType(persona.type)) · \(store.realtimeVoice(for: persona.type).rawValue.capitalized) · 2:00")
              .font(.subheadline)
              .foregroundStyle(VoiceProfilePalette.muted)
          }

          Spacer(minLength: 8)
        }

        if store.isPersonaCompleted(persona) {
          Label(copy.completed, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(VoiceProfilePalette.accentText)
            .accessibilityIdentifier("voiceProfile.completed.\(persona.type.rawValue)")
        } else {
          Button {
            Task { await store.startInterview(personaID: persona.id).value }
          } label: {
            Label(copy.startInterview, systemImage: "waveform")
          }
          .buttonStyle(VoiceProfilePrimaryButtonStyle())
          .disabled(!module.transport.isAvailable)
          .accessibilityIdentifier("voiceProfile.start.\(persona.type.rawValue)")

          if !module.transport.isAvailable {
            Text(copy.voiceUnavailableShort)
              .font(.caption)
              .foregroundStyle(VoiceProfilePalette.muted)
          }
        }
      }
    }
  }

  private var interviewSurface: some View {
    VoiceProfileCard {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .center, spacing: 14) {
          VoiceProfileIconBadge(systemImage: "person.wave.2.fill", size: 48)
          VStack(alignment: .leading, spacing: 4) {
            Text(copy.interviewKicker)
              .font(.caption.weight(.bold))
              .tracking(1.4)
              .foregroundStyle(VoiceProfilePalette.muted)
            Text(store.currentPersona?.name ?? copy.interviewFallbackTitle)
              .font(.system(size: 26, weight: .bold, design: .rounded))
              .lineLimit(2)
          }
          Spacer(minLength: 0)
        }

        switch store.phase {
        case .connecting:
          interviewStatus(
            systemImage: "lock.shield.fill",
            text: copy.connectingStatus,
            showsProgress: true,
            identifier: "voiceProfile.connecting"
          )
        case .savingInterview:
          interviewStatus(
            systemImage: "externaldrive.fill",
            text: copy.savingStatus,
            showsProgress: true,
            identifier: "voiceProfile.saving"
          )
        case .completionFailed:
          errorBanner(.completionFailed)
          Button {
            Task { await store.retryCompletion().value }
          } label: {
            Label(copy.retryCompletion, systemImage: "arrow.clockwise")
          }
          .buttonStyle(VoiceProfilePrimaryButtonStyle())
          .accessibilityIdentifier("voiceProfile.retryCompletion")
          Button {
            store.discardCurrentInterview()
          } label: {
            Label(copy.discardInterview, systemImage: "trash")
          }
          .buttonStyle(VoiceProfileSecondaryButtonStyle())
          .accessibilityIdentifier("voiceProfile.discardInterview")
        default:
          HStack(spacing: 12) {
            VoiceProfileSignal(isActive: store.isSpeaking)
            Text(store.isSpeaking ? copy.partnerSpeaking : copy.listening)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(
                store.isSpeaking ? VoiceProfilePalette.accentText : VoiceProfilePalette.muted
              )
          }

          if let startedAt = store.interviewStartedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
              let remaining = max(0, VoiceProfileStore.interviewDurationSeconds - Int(context.date.timeIntervalSince(startedAt)))
              Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                .monospacedDigit()
                .accessibilityIdentifier("voiceProfile.remainingTime")
            }
          }
          transcriptSurface

          Text(copy.endAnytime)
            .font(.caption)
            .foregroundStyle(VoiceProfilePalette.muted)

          Button {
            store.endInterview()
          } label: {
            Label(copy.endInterview, systemImage: "stop.circle")
          }
          .buttonStyle(VoiceProfileSecondaryButtonStyle())
          .accessibilityIdentifier("voiceProfile.endInterview")
        }
      }
    }
  }

  private func interviewStatus(
    systemImage: String,
    text: String,
    showsProgress: Bool,
    identifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .font(.title3.weight(.semibold))
          .foregroundStyle(VoiceProfilePalette.accentText)
          .accessibilityHidden(true)
        Text(text)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(VoiceProfilePalette.muted)
      }
      if showsProgress {
        ProgressView()
          .tint(VoiceProfilePalette.accentText)
          .frame(minHeight: 36, alignment: .leading)
          .accessibilityIdentifier(identifier)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(VoiceProfilePalette.field)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private var generationSurface: some View {
    VStack(alignment: .leading, spacing: 16) {
      VoiceProfileCard {
        VStack(alignment: .leading, spacing: 16) {
            VoiceProfileCardHeading(
              systemImage: "wand.and.stars",
              title: copy.generationTitle,
              subtitle: store.phase == .generating
                ? copy.generatingBody
                : copy.readyToGenerateBody(
                  completed: store.completedPersonaIDs.count,
                  required: store.requiredInterviewCount,
                  waiverActive: store.interviewWaiverActive
                )
          )

          if store.phase == .generating {
            HStack(spacing: 12) {
              ProgressView()
                .tint(VoiceProfilePalette.accentText)
                .accessibilityIdentifier("voiceProfile.generating")
              Text(
                store.isCreatingNewProfileFromThree
                  ? copy.generatingRevisionStatus
                  : copy.generatingStatus
              )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VoiceProfilePalette.muted)
            }
            .frame(minHeight: 44, alignment: .leading)
          } else {
            if let error = store.lastError {
              inlineError(error)
            }

            HStack(spacing: 10) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(VoiceProfilePalette.accentText)
                .accessibilityHidden(true)
              Text(copy.allInterviewsSaved(
                completed: store.completedPersonaIDs.count,
                required: store.requiredInterviewCount,
                waiverActive: store.interviewWaiverActive
              ))
                .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(VoiceProfilePalette.ink)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VoiceProfilePalette.softYellow)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
              Task { await store.generateProfile().value }
            } label: {
              Label(copy.generateProfile, systemImage: "wand.and.stars")
            }
            .buttonStyle(VoiceProfilePrimaryButtonStyle())
            .accessibilityIdentifier("voiceProfile.generateProfile")
          }
        }
      }
    }
  }

  private var reviewSurface: some View {
    VoiceProfileCard {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .top, spacing: 14) {
          VoiceProfileIconBadge(
            systemImage: store.phase == .confirmed ? "checkmark" : "doc.text.magnifyingglass",
            size: 48
          )
          VStack(alignment: .leading, spacing: 5) {
            Text(store.phase == .confirmed ? copy.confirmedTitle : copy.reviewTitle)
              .font(.system(size: 28, weight: .bold, design: .rounded))
              .lineSpacing(2)
            Text(store.phase == .confirmed ? copy.confirmedLabel : copy.draftLabel)
              .font(.caption.weight(.bold))
              .foregroundStyle(VoiceProfilePalette.accentText)
          }
          Spacer(minLength: 0)
        }

        if let insight = store.insight {
          if let bio = insight.bio, !bio.isEmpty {
            Text(bio).font(.body).foregroundStyle(VoiceProfilePalette.muted)
              .accessibilityIdentifier("voiceProfile.draft.savedBio")
          }
          if !insight.personalityTags.isEmpty {
            Text(copy.traitsTitle)
              .font(.headline.weight(.bold))
            FlowTags(tags: insight.personalityTags)
          }

          if let signature = insight.overallSignature, !signature.isEmpty {
            Text(signature)
              .font(.body)
              .foregroundStyle(VoiceProfilePalette.muted)
              .lineSpacing(5)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("voiceProfile.signature")
          } else if insight.personalityTags.isEmpty {
            Text(copy.reviewSummaryReady)
              .font(.body)
              .foregroundStyle(VoiceProfilePalette.muted)
          }
        } else {
          Text(copy.reviewSummaryReady)
            .font(.body)
            .foregroundStyle(VoiceProfilePalette.muted)
        }

        if store.canEditDraftProfile || store.isSavingDraft || store.draftNeedsRefresh {
          VStack(alignment: .leading, spacing: 10) {
            if editsDraft {
              Text(locale.identifier.lowercased().hasPrefix("ja") ? "性格タグ（コンマ区切りで3〜5個）" : "Personality tags (3–5, separated by commas)")
                .font(.subheadline.weight(.semibold))
              TextField(locale.identifier.lowercased().hasPrefix("ja") ? "性格タグ" : "Personality tags", text: $draftTags)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("voiceProfile.draft.tags")
              Text(locale.identifier.lowercased().hasPrefix("ja") ? "短い自己紹介（1,000文字以内）" : "Short bio (up to 1,000 characters)")
                .font(.subheadline.weight(.semibold))
              TextEditor(text: $draftBio).frame(minHeight: 100)
                .padding(8).background(VoiceProfilePalette.field)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("voiceProfile.draft.bio")
              Button {
                Task {
                  let tags = draftTags.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                  await store.saveDraftProfile(tags: tags, bio: draftBio.trimmingCharacters(in: .whitespacesAndNewlines))
                  if !store.draftNeedsRefresh && store.draftEditError == nil { editsDraft = false }
                }
              } label: {
                Label(locale.identifier.lowercased().hasPrefix("ja") ? "下書きを保存" : "Save draft", systemImage: "checkmark")
              }
              .buttonStyle(VoiceProfileSecondaryButtonStyle())
              .disabled(!store.canEditDraftProfile)
              .accessibilityIdentifier("voiceProfile.draft.save")
              Button(locale.identifier.lowercased().hasPrefix("ja") ? "編集を閉じる" : "Close editor") { editsDraft = false }
                .buttonStyle(VoiceProfileSecondaryButtonStyle()).disabled(store.isSavingDraft)
            } else if store.canEditDraftProfile {
              Button {
                draftTags = store.insight?.personalityTags.joined(separator: ", ") ?? ""
                draftBio = store.insight?.bio ?? ""
                editsDraft = true
              } label: {
                Label(locale.identifier.lowercased().hasPrefix("ja") ? "確認前に下書きを編集" : "Edit draft before confirming", systemImage: "pencil")
              }
              .buttonStyle(VoiceProfileSecondaryButtonStyle())
              .accessibilityIdentifier("voiceProfile.draft.edit")
            }
            if let error = store.draftEditError {
              Text(error).font(.footnote).foregroundStyle(VoiceProfilePalette.muted)
                .accessibilityIdentifier("voiceProfile.draft.error")
            }
            if store.draftNeedsRefresh && !store.isSavingDraft {
              Button(locale.identifier.lowercased().hasPrefix("ja") ? "プロフィールを再確認" : "Refresh profile status") {
                Task { await store.retryLoad().value }
              }
              .buttonStyle(VoiceProfileSecondaryButtonStyle())
              .accessibilityIdentifier("voiceProfile.draft.refresh")
            }
          }
        }

        if store.canCreateNewProfileFromThree {
          VStack(alignment: .leading, spacing: 10) {
            Text(copy.profileRevisionBody)
              .font(.footnote)
              .foregroundStyle(VoiceProfilePalette.muted)
              .fixedSize(horizontal: false, vertical: true)
            Button {
              Task { await store.createNewProfileFromThree().value }
            } label: {
              Label(copy.createNewProfileFromThree, systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(VoiceProfileSecondaryButtonStyle())
            .accessibilityIdentifier("voiceProfile.createNewProfileFromThree")
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(VoiceProfilePalette.field)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if store.profileRevisionBlocksConfirmation {
          VStack(alignment: .leading, spacing: 10) {
            Text(
              store.profileRevisionNeedsRefresh
                ? copy.profileRevisionRefreshBody
                : (store.profileRevisionStatus == .available
                  ? copy.profileRevisionUnavailableBody
                  : copy.profileRevisionClaimedBody)
            )
              .font(.footnote)
              .foregroundStyle(VoiceProfilePalette.muted)
              .fixedSize(horizontal: false, vertical: true)
            Button {
              Task { await store.retryLoad().value }
            } label: {
              Label(copy.refreshProfileRevision, systemImage: "arrow.clockwise")
            }
            .buttonStyle(VoiceProfileSecondaryButtonStyle())
            .accessibilityIdentifier("voiceProfile.refreshProfileRevision")
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(VoiceProfilePalette.field)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }

        NavigationLink {
          WatercolorProfileView(ownerID: ownerID, api: module.photoAPI)
        } label: {
          HStack(alignment: .top, spacing: 12) {
            VoiceProfileIconBadge(systemImage: "paintbrush.pointed.fill", size: 44)
            VStack(alignment: .leading, spacing: 5) {
              Text(copy.watercolorTitle)
                .font(.subheadline.weight(.bold))
              Text(copy.watercolorBody)
                .font(.caption)
                .foregroundStyle(VoiceProfilePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
              .font(.caption.weight(.bold))
              .foregroundStyle(VoiceProfilePalette.muted)
          }
          .padding(13)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(VoiceProfilePalette.field)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("voiceProfile.watercolor.open")

        if let error = store.lastError,
          error == .partnerGenerationFailed || error == .confirmationFailed
            || error == .generationFailed || error == .temporarilyUnavailable
        {
          inlineError(error)
            .accessibilityIdentifier("voiceProfile.reviewError")
        }

        if store.canConfirmProfile && store.needsWingfoxGeneration {
          Text(copy.wingfoxNote)
            .font(.footnote)
            .foregroundStyle(VoiceProfilePalette.muted)
            .lineSpacing(4)
        }

        if store.canConfirmProfile {
          Button {
            Task { await store.confirmProfile().value }
          } label: {
            Label(
              store.needsWingfoxGeneration ? copy.confirmWithWingfox : copy.confirmProfile,
              systemImage: store.needsWingfoxGeneration ? "sparkles" : "checkmark"
            )
          }
          .buttonStyle(VoiceProfilePrimaryButtonStyle())
          .disabled(editsDraft)
          .accessibilityIdentifier("voiceProfile.confirmProfile")
        } else if store.phase == .confirming {
          VStack(alignment: .leading, spacing: 12) {
            ProgressView()
              .tint(VoiceProfilePalette.accentText)
              .accessibilityIdentifier("voiceProfile.confirming")
            Text(
              store.needsWingfoxGeneration
                ? copy.confirmingWingfox
                : copy.confirmingProfile
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(VoiceProfilePalette.muted)
          }
          .frame(minHeight: 46, alignment: .leading)
        } else {
          Text(copy.confirmedBody)
            .font(.footnote)
            .foregroundStyle(VoiceProfilePalette.muted)
          Button {
            if let onConfirmed {
              onConfirmed()
            } else {
              dismiss()
            }
          } label: {
            Label(copy.continueButton, systemImage: "arrow.right")
          }
          .buttonStyle(VoiceProfilePrimaryButtonStyle())
          .accessibilityIdentifier("voiceProfile.continue")
        }
      }
    }
  }

  private var transcriptSurface: some View {
    VStack(alignment: .leading, spacing: 10) {
      if store.transcript.isEmpty {
        Text(copy.transcriptWaiting)
          .font(.subheadline)
          .foregroundStyle(VoiceProfilePalette.muted)
          .padding(.vertical, 10)
      } else {
        ForEach(Array(store.transcript.enumerated()), id: \.offset) { _, entry in
          HStack(alignment: .top, spacing: 10) {
            Text(entry.source == .ai ? copy.partnerLabel : copy.youLabel)
              .font(.caption.weight(.bold))
              .foregroundStyle(VoiceProfilePalette.accentText)
              .frame(width: 42, alignment: .leading)
            Text(entry.message)
              .font(.body)
              .foregroundStyle(VoiceProfilePalette.ink)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(13)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            entry.source == .ai
              ? VoiceProfilePalette.field
              : VoiceProfilePalette.softYellow.opacity(0.7)
          )
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("voiceProfile.transcript")
  }

  private func errorBanner(_ error: VoiceProfileStoreError) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.headline)
        .foregroundStyle(VoiceProfilePalette.accentText)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 10) {
        Text(copy.errorTitle)
          .font(.subheadline.weight(.bold))
        Text(copy.errorMessage(error))
          .font(.footnote)
          .foregroundStyle(VoiceProfilePalette.muted)
          .fixedSize(horizontal: false, vertical: true)
        if error != .voiceUnavailable, error != .completionFailed {
          Button(copy.retry) {
            Task { await store.retryLoad().value }
          }
          .buttonStyle(VoiceProfileSecondaryButtonStyle())
          .accessibilityIdentifier("voiceProfile.retry")
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(VoiceProfilePalette.softYellow.opacity(0.72))
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(VoiceProfilePalette.yellow.opacity(0.7), lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
  }

  private func inlineError(_ error: VoiceProfileStoreError) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(VoiceProfilePalette.accentText)
        .accessibilityHidden(true)
      Text(copy.errorMessage(error))
        .font(.footnote)
        .foregroundStyle(VoiceProfilePalette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(VoiceProfilePalette.softYellow.opacity(0.72))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

struct VoiceProfileCard<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.white)
      .overlay {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .stroke(VoiceProfilePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
      .shadow(color: VoiceProfilePalette.ink.opacity(0.06), radius: 18, y: 8)
  }
}

struct VoiceProfileCardHeading: View {
  let systemImage: String
  let title: String
  let subtitle: String

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      VoiceProfileIconBadge(systemImage: systemImage, size: 48)
      VStack(alignment: .leading, spacing: 7) {
        Text(title)
          .font(.system(size: 25, weight: .bold, design: .rounded))
          .lineSpacing(2)
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(VoiceProfilePalette.muted)
          .lineSpacing(4)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
  }
}

struct VoiceProfileIconBadge: View {
  let systemImage: String
  let size: CGFloat

  init(systemImage: String, size: CGFloat = 64) {
    self.systemImage = systemImage
    self.size = size
  }

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: size * 0.34, weight: .bold))
      .foregroundStyle(VoiceProfilePalette.ink)
      .frame(width: size, height: size)
      .background(VoiceProfilePalette.yellow)
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: size * 0.28,
          bottomLeadingRadius: size * 0.10,
          bottomTrailingRadius: size * 0.28,
          topTrailingRadius: size * 0.28
        )
      )
      .accessibilityHidden(true)
  }
}

private struct VoiceProfilePersonaBadge: View {
  let name: String

  var body: some View {
    Text(String(name.prefix(1)))
      .font(.title3.weight(.bold))
      .foregroundStyle(VoiceProfilePalette.ink)
      .frame(width: 52, height: 52)
      .background(VoiceProfilePalette.softYellow)
      .clipShape(Circle())
      .overlay {
        Circle().stroke(VoiceProfilePalette.yellow.opacity(0.7), lineWidth: 1)
      }
      .accessibilityHidden(true)
  }
}

private struct VoiceProfileSignal: View {
  let isActive: Bool

  private let heights: [CGFloat] = [10, 22, 15, 30, 18, 26, 12]

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(isActive ? VoiceProfilePalette.yellow : VoiceProfilePalette.line)
          .frame(width: 5, height: isActive ? height : 8)
      }
    }
    .frame(width: 64, height: 32)
    .accessibilityHidden(true)
  }
}

private struct FlowTags: View {
  let tags: [String]

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 118), alignment: .leading)],
      alignment: .leading,
      spacing: 10
    ) {
      ForEach(tags, id: \.self) { tag in
        Text(tag)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(VoiceProfilePalette.ink)
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(VoiceProfilePalette.softYellow)
          .clipShape(Capsule())
      }
    }
  }
}

struct VoiceProfilePrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.bold))
      .foregroundStyle(VoiceProfilePalette.ink)
      .frame(maxWidth: .infinity, minHeight: 54)
      .background(VoiceProfilePalette.yellow)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .opacity(configuration.isPressed ? 0.82 : 1)
  }
}

struct VoiceProfileSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(VoiceProfilePalette.ink)
      .frame(maxWidth: .infinity, minHeight: 50)
      .background(VoiceProfilePalette.field)
      .overlay {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
          .stroke(VoiceProfilePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

struct VoiceProfileCopy {
  let language: OnboardingLanguage

  private var isJapanese: Bool { language == .ja }

  var navigationTitle: String { isJapanese ? "AIとの会話" : "AI conversation" }
  var eyebrow: String { isJapanese ? "会話プロフィール" : "VOICE PROFILE" }
  var headerTitle: String { isJapanese ? "あなたらしい会話を見つける" : "Find your conversation rhythm" }
  var headerBody: String {
    isJapanese
      ? "短い会話を重ねて、あなたに合う交流のかたちを一緒に整えます。"
      : "A few thoughtful conversations help shape a private profile that feels like you."
  }
  var progressLabel: String { isJapanese ? "インタビューの進み具合" : "Interview progress" }
  func progressValueLabel(_ count: Int, required: Int) -> String {
    isJapanese
      ? "\(count) / \(required) 件完了"
      : "\(count) of \(required) interviews complete"
  }

  var loadingTitle: String { isJapanese ? "会話の準備をしています" : "Preparing your conversation" }
  var loadingBody: String {
    isJapanese
      ? "保存された設定と会話オプションを確認しています。"
      : "We’re checking your saved language and interview options."
  }
  var loadingStatus: String { isJapanese ? "読み込み中…" : "Loading…" }

  var candidatesTitle: String {
    isJapanese ? "3つの会話スタイルに出会う" : "Meet three conversation styles"
  }
  var candidatesBody: String {
    isJapanese
      ? "ひとりずつ話してみましょう。回答は非公開で、プロフィールの準備に使います。"
      : "Choose one person at a time. Your answers stay private and are used to prepare your profile."
  }
  var voiceUnavailableTitle: String {
    isJapanese ? "音声インタビューは現在利用できません" : "Voice interviews are not available yet"
  }
  var voiceUnavailableBody: String {
    isJapanese
      ? "音声接続の準備ができたら、ここから会話を始められます。今は候補だけ確認できます。"
      : "The voice connection is not ready yet. You can review the conversation options and try again later."
  }
  var voiceUnavailableShort: String {
    isJapanese ? "音声接続が利用できるまで開始できません。" : "You can start when the voice connection is available."
  }
  var prepareTitle: String { isJapanese ? "会話相手を準備します" : "Your conversation partners are almost ready" }
  var prepareBody: String {
    isJapanese
      ? "あなたの回答に合った3つの会話パートナーを用意します。"
      : "We’ll prepare three conversation partners to help you explore your rhythm."
  }
  var prepareButton: String { isJapanese ? "候補を準備する" : "Prepare conversation options" }
  var startInterview: String { isJapanese ? "会話を始める" : "Start interview" }
  var completed: String { isJapanese ? "完了" : "Completed" }

  var interviewKicker: String { isJapanese ? "音声インタビュー" : "VOICE INTERVIEW" }
  var interviewFallbackTitle: String { isJapanese ? "あなたの会話" : "Your conversation" }
  var connectingStatus: String { isJapanese ? "安全に接続しています…" : "Connecting securely…" }
  var savingStatus: String { isJapanese ? "インタビューを保存しています…" : "Saving this interview…" }
  var partnerSpeaking: String { isJapanese ? "パートナーが話しています…" : "Your partner is speaking…" }
  var listening: String { isJapanese ? "聞いています…" : "Listening…" }
  var transcriptWaiting: String {
    isJapanese
      ? "会話が始まると、ここに記録が表示されます。"
      : "The conversation transcript will appear here once you begin."
  }
  var partnerLabel: String { isJapanese ? "AI" : "AI" }
  var youLabel: String { isJapanese ? "あなた" : "You" }
  var endAnytime: String {
    isJapanese
      ? "いつでも終了できます。終了すると会話を保存します。"
      : "You can end at any time. Ending the interview saves the conversation."
  }
  var endInterview: String { isJapanese ? "インタビューを終了" : "End interview" }
  var retryCompletion: String { isJapanese ? "保存をもう一度試す" : "Retry saving interview" }
  var discardInterview: String { isJapanese ? "このインタビューを破棄" : "Discard this interview" }

  var generationTitle: String { isJapanese ? "会話プロフィール" : "Your conversation profile" }
  var generatingBody: String {
    isJapanese
      ? "完了したインタビューから、非公開プロフィールを作成しています…"
      : "Turning your completed interviews into a private profile…"
  }
  func readyToGenerateBody(completed: Int, required: Int, waiverActive: Bool) -> String {
    if waiverActive {
      return isJapanese
        ? "\(completed)件のインタビューが保存されました。期限付きの特例でプロフィールを作成できます。"
        : "\(completed) interviews are saved. A temporary waiver lets you create your profile now."
    }
    return isJapanese
      ? "\(required)つのインタビューが保存されました。結果を確認するため、プロフィールを作成します。"
      : "Your \(required) interviews are complete. Generate a profile to review the saved result."
  }
  var generatingStatus: String { isJapanese ? "プロフィールを作成中…" : "Creating your profile…" }
  var generatingRevisionStatus: String {
    isJapanese ? "3件のインタビューから新しいプロフィールを作成中…" : "Creating a new profile from all 3 interviews…"
  }
  func allInterviewsSaved(completed: Int, required: Int, waiverActive: Bool) -> String {
    if waiverActive {
      return isJapanese
        ? "\(completed) / \(required) 件を保存済み（期限付き特例）"
        : "\(completed) of \(required) interviews saved (temporary waiver)"
    }
    return isJapanese
      ? "\(completed) / \(required) 件を保存済み"
      : "\(completed) of \(required) interviews saved"
  }
  var generateProfile: String { isJapanese ? "プロフィールを作成" : "Generate profile" }
  var createNewProfileFromThree: String {
    isJapanese ? "3回分から新しく作る" : "Create a new profile from all 3 interviews"
  }
  var profileRevisionBody: String {
    isJapanese
      ? "以前のプロフィールは保存したまま、新しい案を確認できます。AIパートナーは作り直しません。"
      : "Your previous profile stays saved while you review a new draft. Your AI partner stays as it is."
  }
  var profileRevisionClaimedBody: String {
    isJapanese
      ? "表示中は以前のプロフィールです。新しいプロフィールの保存は確認できていません。作成の再実行と確定はできません。「状態を再確認」で保存結果を確認してください。"
      : "You are viewing your OLD profile. Saving the new profile has not been confirmed. Generation cannot be repeated, and confirmation is blocked. Refresh profile status to check the saved result."
  }
  var profileRevisionUnavailableBody: String {
    isJapanese
      ? "サーバーから新しいプロフィールを作成する権限を確認できません。状態を再確認してください。"
      : "The server has not enabled a new profile request. Refresh to check the current status."
  }
  var profileRevisionRefreshBody: String {
    isJapanese
      ? "表示中は以前のプロフィールです。新しいプロフィールの保存は確認できていません。状態を確認できるまで、作成の再実行と確定はできません。「状態を再確認」で確認してください。"
      : "You are viewing your OLD profile. Saving the new profile has not been confirmed. Generation and confirmation are blocked until its status is checked. Refresh profile status to check again."
  }
  var refreshProfileRevision: String { isJapanese ? "状態を再確認" : "Refresh profile status" }

  var reviewTitle: String { isJapanese ? "プロフィールを確認" : "Review your profile" }
  var confirmedTitle: String { isJapanese ? "プロフィールを確認しました" : "Profile confirmed" }
  var draftLabel: String { isJapanese ? "下書き" : "DRAFT" }
  var confirmedLabel: String { isJapanese ? "保存済み" : "SAVED" }
  var traitsTitle: String { isJapanese ? "会話の特徴" : "Conversation traits" }
  var reviewSummaryReady: String {
    isJapanese
      ? "あなたの会話からプロフィールの要約を準備しました。"
      : "We prepared a profile summary from your conversations."
  }
  var watercolorTitle: String { isJapanese ? "水彩プロフィール画像" : "Watercolor profile image" }
  var watercolorBody: String {
    isJapanese
      ? "写真を端末で水彩に変換し、確認してから加工画像だけを保存します。"
      : "Convert a photo on this device, review it, then save only the processed image."
  }
  var wingfoxNote: String {
    isJapanese
      ? "あなたのプロフィールは保存されています。設定を完了するため、AIパートナーを作成します。"
      : "Your personal profile is saved. Create an AI partner to finish setup."
  }
  var confirmWithWingfox: String { isJapanese ? "AIパートナーを作成して確認" : "Create AI partner & confirm profile" }
  var confirmProfile: String { isJapanese ? "プロフィールを確認" : "Confirm profile" }
  var confirmingWingfox: String { isJapanese ? "AIパートナーを作成しています…" : "Creating your AI partner…" }
  var confirmingProfile: String { isJapanese ? "確認を保存しています…" : "Saving your confirmation…" }
  var confirmedBody: String {
    isJapanese
      ? "保存したプロフィールをWingwardで使える状態です。"
      : "Your saved profile is ready for Wingward."
  }
  var continueButton: String { isJapanese ? "続ける" : "Continue" }

  var errorTitle: String { isJapanese ? "続行できませんでした" : "We couldn’t continue" }
  var retry: String { isJapanese ? "もう一度試す" : "Try again" }

  func personaType(_ type: VoicePersonaType) -> String {
    switch type {
    case .similar:
      return isJapanese ? "似たリズム" : "A familiar rhythm"
    case .complementary:
      return isJapanese ? "補い合うリズム" : "A complementary rhythm"
    case .discovery:
      return isJapanese ? "新しい視点" : "A new perspective"
    }
  }

  func errorMessage(_ error: VoiceProfileStoreError) -> String {
    guard isJapanese == false else {
      switch error {
      case .microphonePermissionDenied:
        return "マイクへのアクセスを許可してから、もう一度お試しください。"
      case .voiceUnavailable:
        return "音声インタビューは現在利用できません。準備ができたら、もう一度お試しください。"
      case .voiceConnectionFailed:
        return "保存する前に音声接続が終了しました。"
      case .completionFailed:
        return "インタビューを保存できたか確認できませんでした。完了にはしていません。"
      case .generationFailed:
        return "プロフィールを準備できませんでした。時間をおいて、もう一度お試しください。"
      case .partnerGenerationFailed:
        return "プロフィールは保存されましたが、AIパートナーを準備できませんでした。もう一度お試しください。"
      case .confirmationFailed:
        return "プロフィールは保存されましたが、確認を保存できませんでした。もう一度お試しください。"
      case .settingsUnavailable:
        return "インタビューを始める前に、会話設定を完了してください。"
      case .ageVerificationRequired:
        return "インタビューを始める前に、年齢確認を完了してください。"
      case .rateLimited:
        return "少し待ってから、もう一度お試しください。"
      case .unauthenticated, .forbidden, .notFound, .ownerMismatch, .invalidResponse,
        .invalidState, .temporarilyUnavailable, .cancelled:
        return "インタビューを続けられません。もう一度お試しください。"
      }
    }

    switch error {
    case .microphonePermissionDenied:
      return "Allow microphone access to start the interview, then try again."
    case .voiceUnavailable:
      return "The voice interview is not available yet."
    case .voiceConnectionFailed:
      return "The interview connection ended before it could be saved."
    case .completionFailed:
      return "We couldn’t verify that this interview was saved. It is not marked complete."
    case .generationFailed:
      return "We couldn’t prepare your profile. Try again later."
    case .partnerGenerationFailed:
      return "Your personal profile is saved, but we couldn’t prepare your AI partner. Try again."
    case .confirmationFailed:
      return "Your personal profile is saved, but we couldn’t save your confirmation. Try again."
    case .settingsUnavailable:
      return "Complete your conversation settings before starting an interview."
    case .ageVerificationRequired:
      return "Verify your age before starting the interview."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .unauthenticated, .forbidden, .notFound, .ownerMismatch, .invalidResponse,
      .invalidState, .temporarilyUnavailable, .cancelled:
      return "We couldn’t continue the interview. Try again."
    }
  }
}

enum VoiceProfilePalette {
  static let cream = Color(red: 247 / 255, green: 247 / 255, blue: 244 / 255)
  static let ink = Color(red: 23 / 255, green: 23 / 255, blue: 25 / 255)
  static let yellow = Color(red: 1, green: 202 / 255, blue: 40 / 255)
  static let softYellow = Color(red: 1, green: 243 / 255, blue: 196 / 255)
  static let line = Color(red: 229 / 255, green: 229 / 255, blue: 226 / 255)
  static let muted = Color(red: 98 / 255, green: 98 / 255, blue: 102 / 255)
  static let field = Color(red: 251 / 255, green: 251 / 255, blue: 249 / 255)
  static let accentText = Color(red: 147 / 255, green: 113 / 255, blue: 0)
}
