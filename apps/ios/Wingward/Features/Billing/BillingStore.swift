import Foundation
import Observation
import SwiftUI

enum BillingStorePhase: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case failed(BillingStoreError)
}

enum BillingStoreNotice: Equatable, Sendable {
  case purchasesUnavailable
  case purchaseAwaitingServer
  case serverStatusConfirmed
  case restoreChecked
  case restoreNoActivePlan

  var userMessage: String {
    switch self {
    case .purchasesUnavailable:
      return "Purchases are currently unavailable."
    case .purchaseAwaitingServer:
      return "The purchase is still being confirmed."
    case .serverStatusConfirmed:
      return "Your plan status is confirmed."
    case .restoreChecked:
      return "Restore check complete."
    case .restoreNoActivePlan:
      return "No active plan was found for this account."
    }
  }
}

enum BillingStoreError: Error, Equatable, Sendable {
  case unauthenticated
  case ownerMismatch
  case invalidResponse
  case invalidPackage
  case purchasesUnavailable
  case rateLimited
  case temporarilyUnavailable
  case cancelled

  var userMessage: String {
    switch self {
    case .unauthenticated:
      return "Sign in again before checking billing."
    case .ownerMismatch:
      return "Billing is unavailable for this account."
    case .invalidResponse:
      return "Billing status is unavailable right now."
    case .invalidPackage:
      return "That purchase option is unavailable."
    case .purchasesUnavailable:
      return "Purchases are currently unavailable."
    case .rateLimited:
      return "Please wait a moment, then try again."
    case .temporarilyUnavailable:
      return "We couldn't check billing right now. Try again."
    case .cancelled:
      return ""
    }
  }
}

@MainActor
@Observable
final class BillingStore {
  private(set) var ownerID: String
  private(set) var phase: BillingStorePhase = .idle
  private(set) var status: BillingStatus?
  private(set) var offerings: [BillingOffering] = []
  private(set) var notice: BillingStoreNotice?
  private(set) var isPurchasing = false
  private(set) var isRestoring = false

  private let client: any BillingClient
  private let boundOwnerID: String
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var actionTask: Task<Void, Never>?
  private var generation = 0

  init(ownerID: String, client: any BillingClient) {
    self.ownerID = ownerID
    self.boundOwnerID = ownerID
    self.client = client
  }

  var isBusy: Bool {
    phase == .loading || isPurchasing || isRestoring
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    guard ownerID == boundOwnerID else {
      clearProtectedStatus()
      phase = .failed(.ownerMismatch)
      return Task {}
    }
    invalidateOperations()
    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    clearProtectedStatus()
    phase = .loading

    let task = Task { [weak self] in
      guard let self else { return }
      await self.performLoad(ownerID: capturedOwnerID, generation: capturedGeneration)
    }
    loadTask = task
    return task
  }

  @discardableResult
  func retry() -> Task<Void, Never> {
    load()
  }

  /// Starts a vendor purchase, then discards its local status and re-reads the
  /// server mirror.  A local SDK result never grants access by itself.
  @discardableResult
  func purchase(packageID: String) -> Task<Void, Never> {
    guard ownerID == boundOwnerID else {
      clearProtectedStatus()
      phase = .failed(.ownerMismatch)
      return Task {}
    }
    guard !isBusy else { return Task {} }
    guard offerings.contains(where: { $0.packageID == packageID }) else {
      phase = .failed(.invalidPackage)
      return Task {}
    }

    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    notice = nil
    isPurchasing = true
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await client.purchase(packageID: packageID)
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        guard result.packageID == packageID else {
          throw BillingStoreError.invalidResponse
        }
        let serverStatus = try await client.currentStatus()
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        try BillingStatus.validate(serverStatus)
        status = serverStatus
        phase = .loaded
        notice = serverStatus.isActive
          ? .serverStatusConfirmed
          : .purchaseAwaitingServer
        isPurchasing = false
        actionTask = nil
      } catch {
        finishAction(error: error, ownerID: capturedOwnerID, generation: capturedGeneration)
      }
    }
    actionTask = task
    return task
  }

  /// Restore is followed by a server read as well.  The vendor return value is
  /// treated as a signal to refresh, never as entitlement authority.
  @discardableResult
  func restore() -> Task<Void, Never> {
    guard ownerID == boundOwnerID else {
      clearProtectedStatus()
      phase = .failed(.ownerMismatch)
      return Task {}
    }
    guard !isBusy else { return Task {} }

    let capturedOwnerID = ownerID
    let capturedGeneration = generation
    notice = nil
    isRestoring = true
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await client.restore()
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        let serverStatus = try await client.currentStatus()
        guard isCurrent(ownerID: capturedOwnerID, generation: capturedGeneration) else { return }
        try BillingStatus.validate(serverStatus)
        status = serverStatus
        phase = .loaded
        notice = serverStatus.isActive ? .restoreChecked : .restoreNoActivePlan
        isRestoring = false
        actionTask = nil
      } catch {
        finishAction(error: error, ownerID: capturedOwnerID, generation: capturedGeneration)
      }
    }
    actionTask = task
    return task
  }

  func cancel() {
    invalidateOperations()
    clearProtectedStatus()
    phase = .idle
  }

  func updateOwner(_ newOwnerID: String) {
    guard ownerID != newOwnerID else { return }
    cancel()
    ownerID = newOwnerID
  }

  private func performLoad(ownerID: String, generation: Int) async {
    do {
      let serverStatus = try await client.currentStatus()
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      try BillingStatus.validate(serverStatus)

      var fetchedOfferings: [BillingOffering] = []
      do {
        fetchedOfferings = try await client.offerings()
      } catch let error as BillingClientError {
        guard error == .unavailable || error == .notConfigured else { throw error }
        notice = .purchasesUnavailable
      }

      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      status = serverStatus
      offerings = fetchedOfferings
      phase = .loaded
      loadTask = nil
    } catch {
      guard isCurrent(ownerID: ownerID, generation: generation) else { return }
      clearProtectedStatus()
      let mapped = Self.map(error)
      phase = mapped == .cancelled ? .idle : .failed(mapped)
      loadTask = nil
    }
  }

  private func finishAction(error: Error, ownerID: String, generation: Int) {
    guard isCurrent(ownerID: ownerID, generation: generation) else { return }
    isPurchasing = false
    isRestoring = false
    actionTask = nil
    let mapped = Self.map(error)
    if mapped == .cancelled {
      clearProtectedStatus()
      phase = .idle
    } else {
      // A failed purchase or restore must not leave a stale premium mirror in
      // memory that a view could mistake for a confirmed entitlement.
      clearProtectedStatus()
      phase = .failed(mapped)
    }
  }

  private func clearProtectedStatus() {
    status = nil
    offerings = []
    notice = nil
  }

  private func invalidateOperations() {
    loadTask?.cancel()
    actionTask?.cancel()
    loadTask = nil
    actionTask = nil
    isPurchasing = false
    isRestoring = false
    generation &+= 1
  }

  private func isCurrent(ownerID: String, generation: Int) -> Bool {
    !Task.isCancelled && self.ownerID == ownerID && self.generation == generation
  }

  private static func map(_ error: Error) -> BillingStoreError {
    if let storeError = error as? BillingStoreError { return storeError }
    if error is CancellationError || (error as? URLError)?.code == .cancelled {
      return .cancelled
    }
    if let clientError = error as? BillingClientError {
      switch clientError {
      case .unavailable, .notConfigured: return .purchasesUnavailable
      case .invalidPackage: return .invalidPackage
      case .cancelled: return .cancelled
      case .api(let apiError): return map(apiError)
      }
    }
    if let apiError = error as? APIClientError { return map(apiError) }
    if error is BillingDTOValidationError || error is APIDTOValidationError {
      return .invalidResponse
    }
    return .temporarilyUnavailable
  }

  private static func map(_ error: APIClientError) -> BillingStoreError {
    switch error {
    case .unauthenticated: return .unauthenticated
    case .rateLimited: return .rateLimited
    case .cancelled: return .cancelled
    case .invalidResponse, .invalidRequest, .invalidURL: return .invalidResponse
    case .forbidden, .ageVerificationRequired, .notFound, .invalidState,
      .quotaExhausted, .transportFailure, .temporarilyUnavailable:
      return .temporarilyUnavailable
    }
  }
}

struct BillingView: View {
  let ownerID: String
  @Environment(\.locale) private var locale
  @State private var store: BillingStore

  init(ownerID: String, client: any BillingClient) {
    self.ownerID = ownerID
    _store = State(initialValue: BillingStore(ownerID: ownerID, client: client))
  }

  private var copy: BillingCopy {
    BillingCopy(locale: locale)
  }

  var body: some View {
    ZStack {
      ReferencePalette.cream.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          header
          content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
    }
    .foregroundStyle(ReferencePalette.ink)
    .tint(ReferencePalette.ink)
    .navigationTitle(copy.navigationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .preferredColorScheme(.light)
    .task(id: ownerID) {
      await store.load().value
    }
    .onDisappear {
      store.cancel()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
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
        Image(systemName: "creditcard.fill")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(ReferencePalette.ink)
          .frame(width: 48, height: 48)
          .background(ReferencePalette.yellow)
          .clipShape(Circle())
          .accessibilityHidden(true)
      }

      if let status = store.status {
        HStack(spacing: 9) {
          Image(systemName: status.isActive ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(status.isActive ? ReferencePalette.ink : ReferencePalette.muted)
            .accessibilityHidden(true)
          Text(copy.status(isActive: status.isActive))
            .font(.headline.weight(.bold))
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("billing.status")
        if status.consumableCredits > 0 {
          Text(copy.credits(status.consumableCredits))
            .font(.subheadline)
            .foregroundStyle(ReferencePalette.muted)
        }
      } else {
        Text(copy.statusUnavailable)
          .font(.subheadline)
          .foregroundStyle(ReferencePalette.muted)
      }
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ReferencePalette.yellowSoft)
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var content: some View {
    switch store.phase {
    case .idle, .loading:
      billingCard {
        HStack(spacing: 12) {
          ProgressView()
            .tint(ReferencePalette.yellow)
          Text(copy.checking)
            .font(.subheadline.weight(.semibold))
        }
        .frame(minHeight: 56, alignment: .leading)
        .accessibilityIdentifier("billing.loading")
      }
    case .failed(let error):
      billingCard {
        VStack(alignment: .leading, spacing: 14) {
          Image(systemName: "arrow.clockwise.circle")
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(ReferencePalette.yellow)
            .accessibilityHidden(true)
          Text(copy.billingUnavailable)
            .font(.title3.weight(.bold))
          if !copy.error(error).isEmpty {
            Text(copy.error(error))
              .font(.body)
              .foregroundStyle(ReferencePalette.muted)
          }
          if error != .cancelled {
            Button(copy.retry) {
              Task { await store.retry().value }
            }
            .buttonStyle(ReferencePrimaryButtonStyle())
            .accessibilityIdentifier("billing.retry")

            Button {
              Task { await store.restore().value }
            } label: {
              HStack(spacing: 9) {
                if store.isRestoring {
                  ProgressView()
                    .tint(ReferencePalette.ink)
                } else {
                  Image(systemName: "arrow.clockwise")
                    .accessibilityHidden(true)
                }
                Text(copy.restore)
              }
            }
            .buttonStyle(ReferenceSecondaryButtonStyle())
            .disabled(store.isBusy)
            .accessibilityIdentifier("billing.restore.retry")
          }
          Link(
            destination: URL(string: "https://apps.apple.com/account/subscriptions")!
          ) {
            Text(copy.manageSubscriptions)
              .font(.subheadline.weight(.semibold))
              .underline()
          }
          .accessibilityIdentifier("billing.manageSubscriptions")
          Text(copy.cancellationNote)
            .font(.footnote)
            .foregroundStyle(ReferencePalette.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    case .loaded:
      purchaseContent
    }
  }

  private var purchaseContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let notice = store.notice {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "info.circle.fill")
            .foregroundStyle(ReferencePalette.ink)
            .accessibilityHidden(true)
          Text(copy.notice(notice))
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReferencePalette.yellowSoft)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("billing.notice")
      }

      if store.offerings.isEmpty {
        billingCard {
          VStack(alignment: .leading, spacing: 9) {
            Image(systemName: "bag.badge.questionmark")
              .font(.system(size: 28, weight: .medium))
              .foregroundStyle(ReferencePalette.yellow)
              .accessibilityHidden(true)
            Text(copy.noOptionsTitle)
              .font(.title3.weight(.bold))
            Text(copy.noOptionsDetail)
              .font(.body)
              .foregroundStyle(ReferencePalette.muted)
          }
          .accessibilityIdentifier("billing.optionsUnavailable")
        }
      } else {
        ForEach(store.offerings) { offering in
          Button {
            Task { await store.purchase(packageID: offering.packageID).value }
          } label: {
            HStack(alignment: .center, spacing: 14) {
              VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: offering.title)
                  .font(.headline.weight(.bold))
                Text(verbatim: offering.localizedPrice)
                  .font(.subheadline.weight(.semibold))
                  .foregroundStyle(ReferencePalette.muted)
              }
              Spacer(minLength: 10)
              if store.isPurchasing {
                ProgressView()
                  .tint(ReferencePalette.ink)
                  .accessibilityLabel(copy.purchasing)
              } else {
                Image(systemName: "arrow.right")
                  .font(.subheadline.weight(.bold))
                  .accessibilityHidden(true)
              }
            }
            .foregroundStyle(ReferencePalette.ink)
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(.white)
            .overlay {
              RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(ReferencePalette.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
          }
          .buttonStyle(.plain)
          .disabled(store.isBusy)
          .accessibilityIdentifier("billing.purchase.\(offering.packageID)")
        }
      }

      Button {
        Task { await store.restore().value }
      } label: {
        HStack(spacing: 9) {
          if store.isRestoring {
            ProgressView()
              .tint(ReferencePalette.ink)
          } else {
            Image(systemName: "arrow.clockwise")
              .accessibilityHidden(true)
          }
          Text(copy.restore)
        }
      }
      .buttonStyle(ReferenceSecondaryButtonStyle())
      .disabled(store.isBusy)
      .accessibilityIdentifier("billing.restore")

      Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
        Text(copy.manageSubscriptions)
          .font(.subheadline.weight(.semibold))
          .underline()
      }
      .accessibilityIdentifier("billing.manageSubscriptions")

      Text(copy.cancellationNote)
        .font(.footnote)
        .foregroundStyle(ReferencePalette.muted)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)

      Text(copy.storePriceNote)
        .font(.footnote)
        .foregroundStyle(ReferencePalette.muted)
        .lineSpacing(3)
        .padding(.horizontal, 3)
    }
  }

  private func billingCard<Content: View>(
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

private struct BillingCopy {
  let isJapanese: Bool

  init(locale: Locale) {
    let identifier = locale.identifier.lowercased()
    isJapanese = identifier == "ja"
      || identifier.hasPrefix("ja_")
      || identifier.hasPrefix("ja-")
  }

  var navigationTitle: String { isJapanese ? "プラン" : "Plan" }
  var eyebrow: String { isJapanese ? "プランと利用状況" : "PLAN & ACCESS" }
  var title: String { isJapanese ? "あなたのプラン" : "Your plan" }
  var subtitle: String {
    isJapanese
      ? "サーバーで確認できた利用状況と、ストアのプランを表示します。"
      : "Server-confirmed access and store plans, in one place."
  }
  var statusUnavailable: String {
    isJapanese ? "利用状況をまだ確認できません。" : "Billing status isn't available yet."
  }
  var checking: String { isJapanese ? "利用状況を確認しています…" : "Checking your plan…" }
  var billingUnavailable: String {
    isJapanese ? "課金情報を読み込めませんでした" : "We couldn't load billing"
  }
  var retry: String { isJapanese ? "再試行" : "Try again" }
  var noOptionsTitle: String {
    isJapanese ? "購入プランは現在利用できません" : "Purchase options aren't available"
  }
  var noOptionsDetail: String {
    isJapanese
      ? "ストアから価格を取得できるまで、購入操作は利用できません。"
      : "Purchase options will appear when store-supplied pricing is available."
  }
  var restore: String { isJapanese ? "購入を復元" : "Restore purchases" }
  var manageSubscriptions: String {
    isJapanese ? "Appleのサブスクリプションを管理・解約" : "Manage or cancel in Apple Subscriptions"
  }
  var cancellationNote: String {
    isJapanese
      ? "Appleで購入したプランの管理・解約はAppleアカウントで行います。更新日や解約後の扱いはAppleの画面で確認してください。アプリの利用状況はサーバー同期後に更新されます。"
      : "Manage or cancel plans purchased through Apple in your Apple Account. Check Apple's screen for renewal dates and cancellation timing. App access updates after the server syncs."
  }
  var purchasing: String { isJapanese ? "購入処理中" : "Processing purchase" }
  var storePriceNote: String {
    isJapanese
      ? "価格はストアから提供されます。プレミアム利用はサーバー確認後に反映されます。"
      : "Prices come from the store. Premium access is applied only after server confirmation."
  }

  func status(isActive: Bool) -> String {
    if isJapanese {
      return isActive ? "プレミアム有効" : "無料プラン"
    }
    return isActive ? "Premium active" : "Free plan"
  }

  func credits(_ count: Int) -> String {
    isJapanese ? "ミートアップクレジット: \(count)" : "Meetup credits: \(count)"
  }

  func notice(_ notice: BillingStoreNotice) -> String {
    switch notice {
    case .purchasesUnavailable:
      return isJapanese ? "購入は現在利用できません。" : "Purchases are currently unavailable."
    case .purchaseAwaitingServer:
      return isJapanese
        ? "購入の確認をサーバーで待っています。"
        : "The purchase is still being confirmed by the server."
    case .serverStatusConfirmed:
      return isJapanese
        ? "プランの状態をサーバーで確認しました。"
        : "Your plan status is confirmed by the server."
    case .restoreChecked:
      return isJapanese
        ? "購入を復元し、サーバーで有効なプランを確認しました。"
        : "Purchases were restored and an active plan was confirmed by the server."
    case .restoreNoActivePlan:
      return isJapanese
        ? "復元は確認しましたが、このアカウントで有効なプランは見つかりませんでした。購入時のAppleアカウントで再試行してください。"
        : "Restore finished, but no active plan was found for this account. Try again with the Apple Account used to purchase."
    }
  }

  func error(_ error: BillingStoreError) -> String {
    switch error {
    case .unauthenticated:
      return isJapanese
        ? "課金を確認するには、もう一度サインインしてください。"
        : "Sign in again before checking billing."
    case .ownerMismatch:
      return isJapanese
        ? "このアカウントでは課金情報を利用できません。"
        : "Billing is unavailable for this account."
    case .invalidResponse:
      return isJapanese
        ? "課金状態を確認できません。"
        : "Billing status is unavailable right now."
    case .invalidPackage:
      return isJapanese ? "この購入プランは利用できません。" : "That purchase option is unavailable."
    case .purchasesUnavailable:
      return isJapanese ? "購入は現在利用できません。" : "Purchases are currently unavailable."
    case .rateLimited:
      return isJapanese ? "少し待ってから、もう一度お試しください。" : "Please wait a moment, then try again."
    case .temporarilyUnavailable:
      return isJapanese
        ? "課金情報を確認できませんでした。もう一度お試しください。"
        : "We couldn't check billing right now. Try again."
    case .cancelled:
      return ""
    }
  }
}
