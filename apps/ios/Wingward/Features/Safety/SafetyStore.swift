import Foundation
import Observation
import SwiftUI

enum SafetyStorePhase: Equatable, Sendable {
  case idle
  case reporting
  case reportSubmitted
  case blocking
  case blocked
  case unblocking
  case unblocked
  case failed(SafetyAPIError)
}

@MainActor
@Observable
final class SafetyStore {
  private(set) var ownerID: String
  private(set) var targetID: UUID
  let context: ReportContext
  let messageID: UUID?
  private(set) var phase: SafetyStorePhase = .idle
  private(set) var isContentHidden = false
  private(set) var submittedReport: ModerationReportResponse?

  private let api: any SafetyAPI
  private let boundOwnerID: String
  @ObservationIgnored private var operationTask: Task<Void, Never>?
  private var generation = 0

  init(
    ownerID: String,
    targetID: UUID,
    context: ReportContext,
    messageID: UUID? = nil,
    api: any SafetyAPI
  ) {
    self.ownerID = ownerID
    self.boundOwnerID = ownerID
    self.targetID = targetID
    self.context = context
    self.messageID = messageID
    self.api = api
  }

  var isBusy: Bool {
    switch phase {
    case .reporting, .blocking, .unblocking: return true
    case .idle, .reportSubmitted, .blocked, .unblocked, .failed: return false
    }
  }

  var canRetryBlock: Bool {
    guard isContentHidden else { return false }
    if case .failed = phase { return true }
    return false
  }

  @discardableResult
  func submitReport(reason: ModerationReason, description: String?) -> Task<Void, Never> {
    guard ownerID == boundOwnerID else {
      phase = .failed(.ownerMismatch)
      return Task {}
    }
    guard !isBusy, !isContentHidden else { return Task {} }
    let capturedOwnerID = ownerID
    let capturedTargetID = targetID
    let capturedGeneration = generation
    submittedReport = nil
    phase = .reporting

    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let request = try ModerationReportRequest(
          userID: capturedTargetID,
          reason: reason,
          description: description,
          messageID: messageID
        )
        let result = try await api.report(request)
        try ModerationReportResponse.validate(result)
        guard isCurrent(
          ownerID: capturedOwnerID,
          targetID: capturedTargetID,
          generation: capturedGeneration
        ) else { return }
        submittedReport = result
        phase = .reportSubmitted
        operationTask = nil
      } catch {
        finish(error, ownerID: capturedOwnerID, targetID: capturedTargetID, generation: capturedGeneration)
      }
    }
    operationTask = task
    return task
  }

  /// The partner surface may hide content immediately, but the server result
  /// is the only success signal.  An uncertain failure keeps the content
  /// hidden until the parent reconciles the relationship with the server.
  @discardableResult
  func block() -> Task<Void, Never> {
    guard ownerID == boundOwnerID else {
      phase = .failed(.ownerMismatch)
      return Task {}
    }
    guard !isBusy, (!isContentHidden || canRetryBlock), targetID.uuidString.caseInsensitiveCompare(ownerID) != .orderedSame else {
      if targetID.uuidString.caseInsensitiveCompare(ownerID) == .orderedSame {
        phase = .failed(.invalidResponse)
      }
      return Task {}
    }

    let capturedOwnerID = ownerID
    let capturedTargetID = targetID
    let capturedGeneration = generation
    isContentHidden = true
    phase = .blocking

    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await api.block(userID: capturedTargetID)
        try ModerationBlockResponse.validate(result)
        guard isCurrent(
          ownerID: capturedOwnerID,
          targetID: capturedTargetID,
          generation: capturedGeneration
        ) else { return }
        phase = .blocked
        operationTask = nil
      } catch {
        guard isCurrent(
          ownerID: capturedOwnerID,
          targetID: capturedTargetID,
          generation: capturedGeneration
        ) else { return }
        // The server may have committed the block before a later room-close
        // step failed. Keep content hidden until the parent reloads the
        // authoritative relationship; a transport failure is not proof that
        // no block was written.
        isContentHidden = true
        phase = .failed(Self.map(error))
        operationTask = nil
      }
    }
    operationTask = task
    return task
  }

  @discardableResult
  func unblock() -> Task<Void, Never> {
    guard ownerID == boundOwnerID else {
      phase = .failed(.ownerMismatch)
      return Task {}
    }
    guard !isBusy, isContentHidden else { return Task {} }

    let capturedOwnerID = ownerID
    let capturedTargetID = targetID
    let capturedGeneration = generation
    phase = .unblocking

    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await api.unblock(userID: capturedTargetID)
        try ModerationUnblockResponse.validate(result)
        guard isCurrent(
          ownerID: capturedOwnerID,
          targetID: capturedTargetID,
          generation: capturedGeneration
        ) else { return }
        isContentHidden = false
        phase = .unblocked
        operationTask = nil
      } catch {
        guard isCurrent(
          ownerID: capturedOwnerID,
          targetID: capturedTargetID,
          generation: capturedGeneration
        ) else { return }
        // Keep blocked content hidden if the unblock did not commit.
        phase = .failed(Self.map(error))
        operationTask = nil
      }
    }
    operationTask = task
    return task
  }

  func cancel() {
    let wasHidden = isContentHidden
    let previousPhase = phase
    operationTask?.cancel()
    operationTask = nil
    generation &+= 1
    if wasHidden {
      switch previousPhase {
      case .blocked:
        phase = .blocked
      case .failed:
        phase = previousPhase
      default:
        phase = .failed(.temporarilyUnavailable)
      }
    } else {
      phase = .idle
    }
    submittedReport = nil
  }

  func updateOwner(_ newOwnerID: String) {
    guard ownerID != newOwnerID else { return }
    cancel()
    isContentHidden = false
    phase = .idle
    ownerID = newOwnerID
  }

  func updateTarget(_ newTargetID: UUID) {
    guard targetID != newTargetID else { return }
    cancel()
    isContentHidden = false
    phase = .idle
    targetID = newTargetID
  }

  private func finish(
    _ error: Error,
    ownerID: String,
    targetID: UUID,
    generation: Int
  ) {
    guard isCurrent(ownerID: ownerID, targetID: targetID, generation: generation) else { return }
    phase = .failed(Self.map(error))
    operationTask = nil
  }

  private func isCurrent(ownerID: String, targetID: UUID, generation: Int) -> Bool {
    !Task.isCancelled && self.ownerID == ownerID && self.targetID == targetID && self.generation == generation
  }

  private static func map(_ error: Error) -> SafetyAPIError {
    if let safetyError = error as? SafetyAPIError { return safetyError }
    if error is CancellationError || (error as? URLError)?.code == .cancelled {
      return .cancelled
    }
    if error is ModerationValidationError { return .invalidResponse }
    guard let apiError = error as? APIClientError else { return .temporarilyUnavailable }
    switch apiError {
    case .unauthenticated: return .unauthenticated
    case .notFound: return .notFound
    case .invalidState: return .invalidState
    case .rateLimited: return .rateLimited
    case .cancelled: return .cancelled
    case .invalidResponse, .invalidRequest, .invalidURL, .forbidden,
      .ageVerificationRequired, .quotaExhausted, .transportFailure,
      .temporarilyUnavailable:
      return .temporarilyUnavailable
    }
  }
}

enum AccountDeletionPhase: Equatable, Sendable {
  case idle
  case deleting
  case deleted
  case failed(AccountDeletionError)
}

@MainActor
@Observable
final class AccountDeletionCoordinator {
  private(set) var ownerID: String
  private(set) var phase: AccountDeletionPhase = .idle

  private let boundOwnerID: String
  private let api: any AccountLifecycleAPI
  private let cleanup: any SessionCleanup
  @ObservationIgnored private var deleteTask: Task<Void, Never>?
  private var generation = 0

  init(ownerID: String, api: any AccountLifecycleAPI, cleanup: any SessionCleanup) {
    self.ownerID = ownerID
    self.boundOwnerID = ownerID
    self.api = api
    self.cleanup = cleanup
  }

  @discardableResult
  func deleteAccount() -> Task<Void, Never> {
    guard ownerID == boundOwnerID else {
      phase = .failed(.ownerMismatch)
      return Task {}
    }
    guard phase != .deleting, phase != .deleted else { return Task {} }
    phase = .deleting
    let capturedOwnerID = ownerID
    let capturedGeneration = generation

    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let response = try await api.deleteAccount()
        guard response.deleted else { throw AccountDeletionError.notAcknowledged }
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }

        // This ordering is contractual: local session cleanup is reached only
        // after the server says durable deletion completed.
        await cleanup.clearAfterServerDeletion(ownerID: capturedOwnerID)
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        phase = .deleted
        deleteTask = nil
      } catch {
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        phase = .failed(Self.map(error))
        deleteTask = nil
      }
    }
    deleteTask = task
    return task
  }

  /// An auth owner change invalidates an in-flight deletion result. The next
  /// owner must receive a fresh API binding before deletion can be attempted.
  func updateOwner(_ newOwnerID: String) {
    guard ownerID != newOwnerID else { return }
    cancel()
    ownerID = newOwnerID
    phase = .idle
  }

  /// Invalidates a pending deletion without presenting cancellation as a
  /// failed or successful deletion. The server request may still finish, but
  /// its result cannot reach cleanup or the visible phase after this call.
  func cancel() {
    guard phase == .deleting else { return }
    deleteTask?.cancel()
    deleteTask = nil
    generation &+= 1
    phase = .idle
  }

  private func isCurrent(ownerID: String, generation: Int) -> Bool {
    !Task.isCancelled && self.ownerID == ownerID && self.generation == generation
  }

  private static func map(_ error: Error) -> AccountDeletionError {
    if let deletionError = error as? AccountDeletionError { return deletionError }
    if error is CancellationError || (error as? URLError)?.code == .cancelled {
      return .cancelled
    }
    if let apiError = error as? APIClientError {
      switch apiError {
      case .unauthenticated: return .unauthenticated
      case .rateLimited: return .rateLimited
      case .cancelled: return .cancelled
      case .invalidResponse, .invalidRequest, .invalidURL: return .invalidResponse
      case .forbidden, .ageVerificationRequired, .notFound, .invalidState,
        .quotaExhausted, .transportFailure, .temporarilyUnavailable:
        return .temporarilyUnavailable
      }
    }
    return .temporarilyUnavailable
  }
}

struct SafetyActionView: View {
  let ownerID: String
  let targetID: UUID
  let context: ReportContext
  let messageID: UUID?
  let onBlocked: () -> Void
  let onBlockNeedsReconciliation: () -> Void

  @Environment(\.locale) private var locale
  @State private var store: SafetyStore
  @State private var showsReportSheet = false
  @State private var showsBlockConfirmation = false
  @State private var reportReason: ModerationReason = .other
  @State private var reportDescription = ""

  init(
    ownerID: String,
    targetID: UUID,
    context: ReportContext,
    messageID: UUID? = nil,
    api: any SafetyAPI,
    onBlocked: @escaping () -> Void = {},
    onBlockNeedsReconciliation: @escaping () -> Void = {}
  ) {
    self.ownerID = ownerID
    self.targetID = targetID
    self.context = context
    self.messageID = messageID
    self.onBlocked = onBlocked
    self.onBlockNeedsReconciliation = onBlockNeedsReconciliation
    _store = State(
      initialValue: SafetyStore(
        ownerID: ownerID,
        targetID: targetID,
        context: context,
        messageID: messageID,
        api: api
      )
    )
  }

  private var copy: SafetyCopy {
    SafetyCopy(locale: locale)
  }

  var body: some View {
    ZStack {
      ReferencePalette.cream.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          header
          actionCard
          stateMessage
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
    }
    .foregroundStyle(ReferencePalette.ink)
    .tint(ReferencePalette.ink)
    .navigationTitle(copy.navigationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .preferredColorScheme(.light)
    .confirmationDialog(
      copy.blockConfirmationTitle,
      isPresented: $showsBlockConfirmation,
      titleVisibility: .visible
    ) {
      Button(copy.blockConfirmationAction, role: .destructive) {
        Task {
          await store.block().value
          switch store.phase {
          case .blocked:
            onBlocked()
          case .failed:
            onBlockNeedsReconciliation()
          default:
            break
          }
        }
      }
      .accessibilityIdentifier("safety.block.confirm")
      Button(copy.cancel, role: .cancel) {}
    }
    .sheet(isPresented: $showsReportSheet) {
      NavigationStack {
        ZStack {
          ReferencePalette.cream.ignoresSafeArea()
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              VStack(alignment: .leading, spacing: 8) {
                Text(copy.reportEyebrow)
                  .font(.caption2.weight(.bold))
                  .tracking(1.4)
                  .foregroundStyle(ReferencePalette.ink.opacity(0.72))
                Text(copy.reportTitle)
                  .font(.system(size: 30, weight: .bold, design: .rounded))
                  .tracking(-0.8)
                Text(copy.reportSubtitle)
                  .font(.subheadline)
                  .foregroundStyle(ReferencePalette.muted)
                  .lineSpacing(3)
              }
              .padding(.top, 8)

              safetyCard {
                VStack(alignment: .leading, spacing: 12) {
                  Text(copy.reasonLabel)
                    .font(.headline.weight(.bold))
                  Picker(copy.reasonLabel, selection: $reportReason) {
                    ForEach(ModerationReason.allCases, id: \.self) { reason in
                      Text(copy.reason(reason)).tag(reason)
                    }
                  }
                  .pickerStyle(.menu)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 14)
                  .frame(minHeight: 48)
                  .background(ReferencePalette.field)
                  .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                  .accessibilityIdentifier("safety.report.reason")

                  Text(copy.detailsLabel)
                    .font(.headline.weight(.bold))
                    .padding(.top, 4)
                  ZStack(alignment: .topLeading) {
                    if reportDescription.isEmpty {
                      Text(copy.detailsPlaceholder)
                        .font(.body)
                        .foregroundStyle(ReferencePalette.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                    }
                    TextEditor(text: $reportDescription)
                      .font(.body)
                      .scrollContentBackground(.hidden)
                      .padding(9)
                      .onChange(of: reportDescription) { _, newValue in
                        if newValue.count > ModerationReportRequest.maxDescriptionLength {
                          reportDescription = String(
                            newValue.prefix(ModerationReportRequest.maxDescriptionLength)
                          )
                        }
                      }
                  }
                  .frame(minHeight: 122)
                  .background(ReferencePalette.field)
                  .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                      .stroke(ReferencePalette.line, lineWidth: 1)
                  }
                  .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                  .accessibilityIdentifier("safety.report.details")

                  Text(copy.reviewNote)
                    .font(.footnote)
                    .foregroundStyle(ReferencePalette.muted)
                    .lineSpacing(3)
                    .padding(.top, 2)

                  if case .failed(let error) = store.phase, !copy.error(error).isEmpty {
                    Text(copy.error(error))
                      .font(.footnote.weight(.semibold))
                      .foregroundStyle(ReferencePalette.muted)
                      .accessibilityIdentifier("safety.error")
                  }

                  Button {
                    Task {
                      await store.submitReport(
                        reason: reportReason,
                        description: reportDescription
                      ).value
                      if case .reportSubmitted = store.phase {
                        showsReportSheet = false
                      }
                    }
                  } label: {
                    HStack(spacing: 9) {
                      if store.isBusy {
                        ProgressView()
                          .tint(ReferencePalette.ink)
                      }
                      Text(copy.sendReport)
                    }
                  }
                  .buttonStyle(ReferencePrimaryButtonStyle())
                  .disabled(store.isBusy)
                  .accessibilityIdentifier("safety.report.submit")
                }
              }
              .padding(.horizontal, 18)
              .padding(.vertical, 20)
            }
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
          }
        }
        .foregroundStyle(ReferencePalette.ink)
        .tint(ReferencePalette.ink)
        .navigationTitle(copy.reportTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(copy.cancel) { showsReportSheet = false }
          }
        }
      }
    }
    .onChange(of: showsReportSheet) { _, isPresented in
      if isPresented {
        reportReason = .other
        reportDescription = ""
      }
    }
    .onDisappear { store.cancel() }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 7) {
        Text(copy.eyebrow)
          .font(.caption2.weight(.bold))
          .tracking(1.5)
          .foregroundStyle(ReferencePalette.ink.opacity(0.72))
        Text(copy.title)
          .font(.system(size: 32, weight: .bold, design: .rounded))
          .tracking(-1)
        Text(copy.subtitle)
          .font(.subheadline)
          .foregroundStyle(ReferencePalette.muted)
          .lineSpacing(3)
      }
      Spacer(minLength: 8)
      Image(systemName: "checkmark.shield.fill")
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(ReferencePalette.ink)
        .frame(width: 48, height: 48)
        .background(ReferencePalette.yellow)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ReferencePalette.yellowSoft)
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
  }

  private var actionCard: some View {
    safetyCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text(copy.context(context))
            .font(.caption2.weight(.bold))
            .tracking(1.2)
            .foregroundStyle(ReferencePalette.ink.opacity(0.72))
          Spacer(minLength: 8)
          Image(systemName: "person.crop.circle.badge.checkmark")
            .foregroundStyle(ReferencePalette.yellow)
            .accessibilityHidden(true)
        }

        if store.isContentHidden {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: store.canRetryBlock ? "arrow.triangle.2.circlepath" : "eye.slash.fill")
              .foregroundStyle(ReferencePalette.yellow)
              .accessibilityHidden(true)
            Text(
              store.canRetryBlock
                ? copy.hiddenForReconciliation
                : copy.hiddenAfterBlock
            )
              .font(.subheadline.weight(.semibold))
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(ReferencePalette.yellowSoft)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          .accessibilityIdentifier("safety.contentHidden")
        }

        if store.isContentHidden {
          if case .blocked = store.phase {
            Button {
              Task { await store.unblock().value }
            } label: {
              HStack(spacing: 9) {
                if store.isBusy {
                  ProgressView()
                    .tint(ReferencePalette.ink)
                } else {
                  Image(systemName: "lock.open")
                    .accessibilityHidden(true)
                }
                Text(copy.unblock)
              }
            }
            .buttonStyle(ReferencePrimaryButtonStyle())
            .disabled(store.isBusy)
            .accessibilityIdentifier("safety.unblock")
          } else if store.canRetryBlock {
            Button {
              showsBlockConfirmation = true
            } label: {
              HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.2.circlepath")
                  .accessibilityHidden(true)
                Text(copy.retryBlock)
              }
            }
            .buttonStyle(ReferenceSecondaryButtonStyle())
            .disabled(store.isBusy)
            .accessibilityIdentifier("safety.block")
          }
        } else {
          HStack(spacing: 10) {
            Button {
              showsReportSheet = true
            } label: {
              Label(copy.report, systemImage: "flag")
            }
            .buttonStyle(ReferenceOutlineButtonStyle())
            .disabled(store.isBusy)
            .accessibilityIdentifier("safety.report")

            Button {
              showsBlockConfirmation = true
            } label: {
              Label(copy.block, systemImage: "hand.raised")
            }
            .buttonStyle(ReferenceSecondaryButtonStyle())
            .disabled(store.isBusy)
            .accessibilityIdentifier("safety.block")
          }
        }

        if store.canRetryBlock {
          Button(copy.reloadSafetyState) {
            onBlockNeedsReconciliation()
          }
          .buttonStyle(ReferenceOutlineButtonStyle())
          .accessibilityIdentifier("safety.reconcile")
        }
      }
    }
  }

  @ViewBuilder
  private var stateMessage: some View {
    if case .reportSubmitted = store.phase {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(ReferencePalette.ink)
          .accessibilityHidden(true)
        Text(copy.reportSubmitted)
          .font(.subheadline.weight(.semibold))
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ReferencePalette.yellowSoft)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .accessibilityIdentifier("safety.reportSubmitted")
    } else if case .failed(let error) = store.phase, !copy.error(error).isEmpty {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(ReferencePalette.yellow)
          .accessibilityHidden(true)
        Text(copy.error(error))
          .font(.subheadline.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.white)
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(ReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .accessibilityIdentifier("safety.error")
    }
  }

  private func safetyCard<Content: View>(
    @ViewBuilder _ content: () -> Content
  ) -> some View {
    content()
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.white)
      .overlay {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .stroke(ReferencePalette.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
  }
}

struct AccountDeletionView: View {
  let ownerID: String
  @Environment(\.locale) private var locale
  @State private var coordinator: AccountDeletionCoordinator
  @State private var showsConfirmation = false

  init(ownerID: String, api: any AccountLifecycleAPI, cleanup: any SessionCleanup) {
    self.ownerID = ownerID
    _coordinator = State(
      initialValue: AccountDeletionCoordinator(ownerID: ownerID, api: api, cleanup: cleanup)
    )
  }

  private var copy: SafetyCopy {
    SafetyCopy(locale: locale)
  }

  var body: some View {
    ZStack {
      ReferencePalette.cream.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
              Text(copy.deletionEyebrow)
                .font(.caption2.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(ReferencePalette.ink.opacity(0.72))
              Text(copy.deletionTitle)
                .font(.title2.weight(.bold))
              Text(copy.deletionBody)
                .font(.subheadline)
                .foregroundStyle(ReferencePalette.muted)
                .lineSpacing(3)
            }
            Spacer(minLength: 8)
            Image(systemName: "person.crop.circle.badge.xmark")
              .font(.system(size: 26, weight: .semibold))
              .foregroundStyle(ReferencePalette.ink)
              .frame(width: 48, height: 48)
              .background(ReferencePalette.yellow)
              .clipShape(Circle())
              .accessibilityHidden(true)
          }

          deletionStatus

          if coordinator.phase != .deleted {
            Button(copy.deleteAction, role: .destructive) {
              showsConfirmation = true
            }
            .buttonStyle(ReferencePrimaryButtonStyle())
            .disabled(coordinator.phase == .deleting)
            .accessibilityIdentifier("accountDeletion.delete")
          }
        }
        .padding(22)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
    }
    .foregroundStyle(ReferencePalette.ink)
    .tint(ReferencePalette.ink)
    .navigationTitle(copy.deletionNavigationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog(
      copy.deletionConfirmationTitle,
      isPresented: $showsConfirmation,
      titleVisibility: .visible
    ) {
      Button(copy.deleteAction, role: .destructive) {
        Task { await coordinator.deleteAccount().value }
      }
      .accessibilityIdentifier("accountDeletion.confirm")
      Button(copy.cancel, role: .cancel) {}
    }
    .preferredColorScheme(.light)
    .onDisappear {
      coordinator.cancel()
    }
  }

  @ViewBuilder
  private var deletionStatus: some View {
    switch coordinator.phase {
    case .idle:
      EmptyView()
    case .deleting:
      HStack(spacing: 10) {
        ProgressView()
          .tint(ReferencePalette.yellow)
        Text(copy.deleting)
          .font(.subheadline.weight(.semibold))
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ReferencePalette.yellowSoft)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .accessibilityIdentifier("accountDeletion.deleting")
    case .deleted:
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(ReferencePalette.ink)
          .accessibilityHidden(true)
        Text(copy.deleted)
          .font(.subheadline.weight(.semibold))
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ReferencePalette.yellowSoft)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .accessibilityIdentifier("accountDeletion.success")
    case .failed(let error):
      if !copy.deletionError(error).isEmpty {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(ReferencePalette.yellow)
            .accessibilityHidden(true)
          Text(copy.deletionError(error))
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .overlay {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(ReferencePalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("accountDeletion.error")
      }
    }
  }
}

private struct SafetyCopy {
  let isJapanese: Bool

  init(locale: Locale) {
    let identifier = locale.identifier.lowercased()
    isJapanese = identifier == "ja"
      || identifier.hasPrefix("ja_")
      || identifier.hasPrefix("ja-")
  }

  var navigationTitle: String { isJapanese ? "安全設定" : "Safety" }
  var eyebrow: String { isJapanese ? "安全" : "SAFETY" }
  var title: String { isJapanese ? "安心してつながるために" : "Stay in control" }
  var subtitle: String {
    isJapanese
      ? "困ったときは、通報やブロックをいつでも選べます。"
      : "Report or block a person whenever something feels wrong."
  }
  var report: String { isJapanese ? "通報する" : "Report" }
  var block: String { isJapanese ? "ブロック" : "Block" }
  var retryBlock: String { isJapanese ? "ブロックを再試行" : "Retry block" }
  var unblock: String { isJapanese ? "ブロックを解除" : "Unblock" }
  var reloadSafetyState: String {
    isJapanese ? "安全状態を再確認" : "Reload safety state"
  }
  var hiddenForReconciliation: String {
    isJapanese
      ? "ブロック状態を確認中のため、この相手を非表示にしています。"
      : "This person remains hidden while the block is reconciled."
  }
  var hiddenAfterBlock: String {
    isJapanese ? "ブロックしたため、この相手を非表示にしています。" : "This person is hidden after your block."
  }
  var reportSubmitted: String {
    isJapanese ? "通報を受け付けました。担当者が確認します。" : "Your report was sent for human review."
  }
  var blockConfirmationTitle: String {
    isJapanese ? "この相手をブロックしますか？" : "Block this person?"
  }
  var blockConfirmationAction: String { isJapanese ? "ブロックする" : "Block" }
  var cancel: String { isJapanese ? "キャンセル" : "Cancel" }
  var reportEyebrow: String { isJapanese ? "通報" : "REPORT" }
  var reportTitle: String { isJapanese ? "通報する" : "Report" }
  var reportSubtitle: String {
    isJapanese
      ? "安全のため、気になる内容を教えてください。"
      : "Tell us what happened so we can help keep the community safe."
  }
  var reasonLabel: String { isJapanese ? "理由" : "Reason" }
  var detailsLabel: String { isJapanese ? "補足（任意）" : "Details (optional)" }
  var detailsPlaceholder: String {
    isJapanese ? "状況を簡単に説明してください" : "Briefly describe what happened"
  }
  var reviewNote: String {
    isJapanese ? "通報は担当者が確認します。送信後もこの画面で状態を確認できます。" : "Reports are reviewed by humans. You can keep this screen open to see the result."
  }
  var sendReport: String { isJapanese ? "通報を送信" : "Send report" }

  var deletionNavigationTitle: String { isJapanese ? "アカウント" : "Account" }
  var deletionEyebrow: String { isJapanese ? "アカウント" : "ACCOUNT" }
  var deletionTitle: String { isJapanese ? "アカウントを削除" : "Delete account" }
  var deletionBody: String {
    isJapanese
      ? "確認後、アカウントと関連データをサーバーで削除します。"
      : "After confirmation, your account and associated data are deleted on the server."
  }
  var deleting: String { isJapanese ? "サーバーで削除を確認しています…" : "Confirming deletion with the server…" }
  var deleted: String { isJapanese ? "アカウントを削除しました。" : "Your account was deleted." }
  var deleteAction: String { isJapanese ? "アカウントを削除" : "Delete account" }
  var deletionConfirmationTitle: String {
    isJapanese ? "アカウントを完全に削除しますか？" : "Delete your account permanently?"
  }

  func context(_ context: ReportContext) -> String {
    switch context {
    case .match: return isJapanese ? "マッチ" : "MATCH"
    case .foxConversation: return isJapanese ? "フォックス会話" : "FOX CONVERSATION"
    case .partnerFoxChat: return isJapanese ? "パートナーフォックス" : "PARTNER FOX"
    case .directChat: return isJapanese ? "ダイレクトチャット" : "DIRECT CHAT"
    case .meetup: return isJapanese ? "ミートアップ" : "MEETUP"
    }
  }

  func reason(_ reason: ModerationReason) -> String {
    switch reason {
    case .harassment: return isJapanese ? "嫌がらせ" : "Harassment"
    case .inappropriate: return isJapanese ? "不適切な内容" : "Inappropriate content"
    case .spam: return isJapanese ? "スパム" : "Spam"
    case .other: return isJapanese ? "その他" : "Other"
    }
  }

  func error(_ error: SafetyAPIError) -> String {
    switch error {
    case .unauthenticated:
      return isJapanese
        ? "安全設定を変更するには、もう一度サインインしてください。"
        : "Sign in again before changing safety settings."
    case .ownerMismatch:
      return isJapanese
        ? "このアカウントでは安全設定を利用できません。"
        : "Safety settings are unavailable for this account."
    case .rateLimited:
      return isJapanese ? "少し待ってから、もう一度お試しください。" : "Please wait a moment, then try again."
    case .invalidResponse, .notFound, .invalidState, .temporarilyUnavailable:
      return isJapanese
        ? "安全設定を更新できませんでした。もう一度お試しください。"
        : "We couldn't update safety settings. Try again."
    case .cancelled:
      return ""
    }
  }

  func deletionError(_ error: AccountDeletionError) -> String {
    switch error {
    case .unauthenticated:
      return isJapanese
        ? "アカウントを削除するには、もう一度サインインしてください。"
        : "Sign in again before deleting your account."
    case .ownerMismatch:
      return isJapanese
        ? "このアカウントでは削除を実行できません。"
        : "Account deletion is unavailable for this account."
    case .notFound, .notAcknowledged, .invalidResponse, .temporarilyUnavailable:
      return isJapanese
        ? "アカウント削除を確認できませんでした。もう一度お試しください。"
        : "We couldn't confirm account deletion. Try again."
    case .rateLimited:
      return isJapanese ? "少し待ってから、もう一度お試しください。" : "Please wait a moment, then try again."
    case .cancelled:
      return ""
    }
  }
}
