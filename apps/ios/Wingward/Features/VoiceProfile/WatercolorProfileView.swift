import PhotosUI
import SwiftUI

struct WatercolorProfileView: View {
  let ownerID: String
  let api: any ProfilePhotoAPI

  @State private var store: WatercolorProfileStore
  @State private var pickerItem: PhotosPickerItem?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale

  init(ownerID: String, api: any ProfilePhotoAPI) {
    self.ownerID = ownerID
    self.api = api
    _store = State(initialValue: WatercolorProfileStore(api: api))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          header
          content
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
    .id(ownerID)
    .tint(VoiceProfilePalette.ink)
    .task(id: ownerID) {
      await store.loadSavedAvatar().value
    }
    .task(id: pickerItem) {
      guard let item = pickerItem else { return }
      do {
        guard let data = try await item.loadTransferable(type: Data.self) else {
          guard !Task.isCancelled else { return }
          store.markPhotoLoadFailed()
          pickerItem = nil
          return
        }
        guard !Task.isCancelled else { return }
        await store.prepare(sourceData: data).value
        guard !Task.isCancelled else { return }
        // Release the Photos picker selection after this operation so the
        // same library item can be selected again for a later retry.
        pickerItem = nil
      } catch is CancellationError {
        // A new picker item or owner cancels this task. It must not turn into
        // an error state for the newer operation.
      } catch {
        guard !Task.isCancelled else { return }
        // The source bytes are intentionally not preserved for retry. The
        // user can choose the photo again without exposing picker errors.
        store.markPhotoLoadFailed()
        pickerItem = nil
      }
    }
    .onChange(of: ownerID) { _, _ in
      pickerItem = nil
      store.resetForOwnerChange(api: api)
    }
    .onDisappear { store.cancel() }
    .preferredColorScheme(.light)
  }

  private var language: OnboardingLanguage {
    locale.identifier.lowercased().hasPrefix("ja") ? .ja : .en
  }

  private var copy: WatercolorProfileCopy { WatercolorProfileCopy(language: language) }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 14) {
        VoiceProfileIconBadge(systemImage: "paintbrush.pointed.fill")
        VStack(alignment: .leading, spacing: 6) {
          Text(copy.eyebrow)
            .font(.caption.weight(.bold))
            .tracking(1.7)
            .foregroundStyle(VoiceProfilePalette.muted)
          Text(copy.title)
            .font(.system(size: 32, weight: .bold, design: .rounded))
            .tracking(-1)
        }
      }
      Text(copy.body)
        .font(.body)
        .foregroundStyle(VoiceProfilePalette.muted)
        .lineSpacing(5)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch store.phase {
    case .idle:
      chooseCard
    case .loadingSaved:
      progressCard(title: copy.loadingSavedTitle, body: copy.loadingSavedBody, identifier: "watercolor.loadingSaved")
    case .processing:
      progressCard(title: copy.processingTitle, body: copy.processingBody, identifier: "watercolor.processing")
    case .preview:
      previewCard
    case .saving:
      savingCard
    case .saved:
      savedCard
    case let .failed(error):
      failureCard(error)
    }
  }

  private var chooseCard: some View {
    card {
      VStack(alignment: .leading, spacing: 16) {
        VoiceProfileCardHeading(
          systemImage: "photo.on.rectangle.angled",
          title: copy.chooseTitle,
          subtitle: copy.chooseBody
        )
        pickerButton(title: copy.chooseButton, identifier: "watercolor.choose")
        privacyNote
      }
    }
  }

  private var previewCard: some View {
    card {
      VStack(alignment: .leading, spacing: 16) {
        VoiceProfileCardHeading(
          systemImage: "eye.fill",
          title: copy.previewTitle,
          subtitle: copy.previewBody
        )
        if let preview = store.previewImage {
          Image(uiImage: preview)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(minHeight: 220, maxHeight: 420)
            .background(VoiceProfilePalette.field)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityLabel(copy.previewAccessibility)
            .accessibilityIdentifier("watercolor.preview")
        }
        Button {
          Task { await store.save().value }
        } label: {
          Label(copy.saveButton, systemImage: "arrow.up.circle.fill")
        }
        .buttonStyle(VoiceProfilePrimaryButtonStyle())
        .disabled(!store.canSave)
        .accessibilityIdentifier("watercolor.save")

        pickerButton(title: copy.replaceButton, identifier: "watercolor.replace")
        privacyNote
      }
    }
  }

  private var savingCard: some View {
    card {
      VStack(alignment: .leading, spacing: 16) {
        VoiceProfileCardHeading(
          systemImage: "arrow.up.circle.fill",
          title: copy.savingTitle,
          subtitle: copy.savingBody
        )
        if let preview = store.previewImage {
          Image(uiImage: preview)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(minHeight: 180, maxHeight: 340)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        ProgressView()
          .tint(VoiceProfilePalette.accentText)
          .frame(minHeight: 42, alignment: .leading)
          .accessibilityIdentifier("watercolor.saving")
        privacyNote
      }
    }
  }

  private var savedCard: some View {
    card {
      VStack(alignment: .leading, spacing: 16) {
        VoiceProfileCardHeading(
          systemImage: "checkmark.circle.fill",
          title: copy.savedTitle,
          subtitle: copy.savedBody
        )
        if let preview = store.previewImage {
          Image(uiImage: preview)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(minHeight: 180, maxHeight: 340)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityIdentifier("watercolor.savedPreview")
        } else if let avatarURL = store.savedAvatarURL {
          AsyncImage(url: avatarURL) { phase in
            switch phase {
            case .success(let image):
              image.resizable().scaledToFit()
            case .empty:
              ProgressView()
                .frame(minHeight: 180, maxHeight: 340)
            case .failure:
              VStack(spacing: 10) {
                Image(systemName: "person.crop.square")
                  .resizable()
                  .scaledToFit()
                  .frame(width: 58, height: 58)
                  .foregroundStyle(VoiceProfilePalette.muted)
                  .accessibilityHidden(true)
                Text(copy.savedImageLoadFailed)
                  .font(.footnote)
                  .foregroundStyle(VoiceProfilePalette.muted)
                  .multilineTextAlignment(.center)
                Button {
                  Task { await store.retryLoadSavedAvatar().value }
                } label: {
                  Label(copy.retryLoadButton, systemImage: "arrow.clockwise")
                }
                .buttonStyle(VoiceProfileSecondaryButtonStyle())
                .accessibilityIdentifier("watercolor.retrySavedImage")
              }
              .padding(22)
              .frame(minHeight: 180, maxHeight: 340)
            @unknown default:
              EmptyView()
            }
          }
          .frame(maxWidth: .infinity)
          .frame(minHeight: 180, maxHeight: 340)
          .background(VoiceProfilePalette.field)
          .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
          .accessibilityLabel(copy.previewAccessibility)
          .accessibilityIdentifier("watercolor.savedRemotePreview")
        }
        Text(copy.savedDetail)
          .font(.footnote)
          .foregroundStyle(VoiceProfilePalette.muted)
          .fixedSize(horizontal: false, vertical: true)
        pickerButton(title: copy.replaceButton, identifier: "watercolor.replaceSaved")
        Button {
          dismiss()
        } label: {
          Label(copy.doneButton, systemImage: "checkmark")
        }
        .buttonStyle(VoiceProfilePrimaryButtonStyle())
        .accessibilityIdentifier("watercolor.done")
      }
    }
  }

  private func failureCard(_ error: WatercolorProfileError) -> some View {
    card {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(VoiceProfilePalette.accentText)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 6) {
            Text(error == .loadFailed ? copy.loadErrorTitle : copy.errorTitle)
              .font(.headline.weight(.bold))
            Text(copy.errorMessage(error))
              .font(.footnote)
              .foregroundStyle(VoiceProfilePalette.muted)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        if error == .loadFailed {
          Button {
            Task { await store.retryLoadSavedAvatar().value }
          } label: {
            Label(copy.retryLoadButton, systemImage: "arrow.clockwise")
          }
          .buttonStyle(VoiceProfilePrimaryButtonStyle())
          .accessibilityIdentifier("watercolor.retryLoad")
          pickerButton(title: copy.chooseButton, identifier: "watercolor.chooseAfterLoadFailure")
        } else if store.hasPreview, error == .uploadFailed || error == .unavailable {
          Button {
            Task { await store.retrySave().value }
          } label: {
            Label(copy.retryButton, systemImage: "arrow.clockwise")
          }
          .buttonStyle(VoiceProfilePrimaryButtonStyle())
          .accessibilityIdentifier("watercolor.retry")
          pickerButton(title: copy.replaceButton, identifier: "watercolor.replaceAfterFailure")
        } else {
          pickerButton(title: copy.chooseButton, identifier: "watercolor.chooseAfterFailure")
        }
      }
    }
  }

  private func progressCard(title: String, body: String, identifier: String) -> some View {
    card {
      VStack(alignment: .leading, spacing: 16) {
        VoiceProfileCardHeading(systemImage: "wand.and.stars", title: title, subtitle: body)
        ProgressView()
          .tint(VoiceProfilePalette.accentText)
          .frame(minHeight: 44, alignment: .leading)
          .accessibilityIdentifier(identifier)
      }
    }
  }

  private func pickerButton(title: String, identifier: String) -> some View {
    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
      Label(title, systemImage: "photo.on.rectangle")
    }
    .buttonStyle(VoiceProfileSecondaryButtonStyle())
    .accessibilityIdentifier(identifier)
  }

  private var privacyNote: some View {
    Label(copy.privacyNote, systemImage: "lock.shield")
      .font(.caption)
      .foregroundStyle(VoiceProfilePalette.muted)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("watercolor.privacyNote")
  }

  private func card<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
    VoiceProfileCard(content: content)
  }
}

private struct WatercolorProfileCopy {
  let language: OnboardingLanguage

  private var isJapanese: Bool { language == .ja }

  var navigationTitle: String { isJapanese ? "水彩プロフィール" : "Watercolor profile" }
  var eyebrow: String { isJapanese ? "あなたのプロフィール画像" : "YOUR PROFILE IMAGE" }
  var title: String { isJapanese ? "写真を、あなたらしい水彩に" : "Turn a photo into your watercolor" }
  var body: String {
    isJapanese
      ? "写真は端末上で水彩画調に変換します。確認してから、加工後の画像だけをプロフィールに保存できます。"
      : "Your photo is converted into a watercolor on this device. Review it before saving the processed image to your profile."
  }
  var chooseTitle: String { isJapanese ? "写真を選ぶ" : "Choose a photo" }
  var chooseBody: String {
    isJapanese
      ? "写真ライブラリから1枚選びます。元写真はこの画面の一時処理にだけ使います。"
      : "Choose one image from your library. The original is used only during this on-device conversion."
  }
  var chooseButton: String { isJapanese ? "写真を選択" : "Choose photo" }
  var processingTitle: String { isJapanese ? "水彩に変換しています" : "Making your watercolor" }
  var loadingSavedTitle: String { isJapanese ? "プロフィール画像を確認しています" : "Checking your profile image" }
  var loadingSavedBody: String { isJapanese ? "保存済みの画像があるか確認します。" : "Checking whether an image is already saved." }
  var processingBody: String {
    isJapanese ? "端末上で色と輪郭を整えています。" : "Color and edges are being refined on this device."
  }
  var previewTitle: String { isJapanese ? "仕上がりを確認" : "Review the result" }
  var previewBody: String {
    isJapanese ? "保存するまでプロフィールには反映されません。" : "Nothing changes on your profile until you save it."
  }
  var previewAccessibility: String { isJapanese ? "水彩プロフィール画像のプレビュー" : "Watercolor profile preview" }
  var saveButton: String { isJapanese ? "この画像を保存" : "Save this image" }
  var replaceButton: String { isJapanese ? "別の写真を選ぶ" : "Choose another photo" }
  var savingTitle: String { isJapanese ? "プロフィールに保存しています" : "Saving to your profile" }
  var savingBody: String {
    isJapanese
      ? "保存するのは加工後の画像だけです。顔認証や識別には使いません。"
      : "Only the processed image is uploaded. It is not used for face recognition or identification."
  }
  var savedTitle: String { isJapanese ? "水彩プロフィールを保存しました" : "Watercolor profile saved" }
  var savedBody: String {
    isJapanese ? "プロフィール画像を更新しました。" : "Your profile image has been updated."
  }
  var savedDetail: String {
    isJapanese
      ? "元写真はこのアプリの変換処理後に保持していません。公開範囲はプロフィール設定に従います。"
      : "The app does not retain the original after conversion. Visibility follows your profile settings."
  }
  var doneButton: String { isJapanese ? "完了" : "Done" }
  var retryButton: String { isJapanese ? "保存を再試行" : "Retry save" }
  var retryLoadButton: String { isJapanese ? "画像を再読み込み" : "Reload image" }
  var errorTitle: String { isJapanese ? "保存できませんでした" : "We couldn’t save this image" }
  var loadErrorTitle: String { isJapanese ? "画像を読み込めませんでした" : "We couldn’t load your profile image" }
  var savedImageLoadFailed: String {
    isJapanese ? "保存済みの画像を表示できません。もう一度読み込めます。" : "The saved image could not be displayed. You can reload it."
  }
  var privacyNote: String {
    isJapanese
      ? "元写真は端末内で変換し、保存時に加工画像だけを送信します。顔認証・識別には使いません。"
      : "The original stays on this device during conversion. Saving uploads only the processed image, never for face recognition or identification."
  }

  func errorMessage(_ error: WatercolorProfileError) -> String {
    switch error {
    case .invalidPhoto:
      return isJapanese ? "この画像を読み込めませんでした。別の写真を選んでください。" : "We couldn’t read that image. Choose another photo."
    case .conversionFailed:
      return isJapanese ? "水彩への変換に失敗しました。もう一度お試しください。" : "The watercolor conversion failed. Try again with another photo."
    case .loadFailed:
      return isJapanese ? "保存済みのプロフィール画像を確認できませんでした。もう一度お試しください。" : "We couldn’t check your saved profile image. Try again."
    case .uploadFailed:
      return isJapanese ? "加工画像をプロフィールに保存できませんでした。もう一度お試しください。" : "The processed image could not be saved to your profile. Try again."
    case .unavailable:
      return isJapanese ? "プロフィール画像の保存機能は現在利用できません。準備ができたら再試行してください。" : "Profile image saving is not available right now. Try again when it is ready."
    case .cancelled:
      return isJapanese ? "処理を中止しました。写真を選び直してください。" : "The conversion was cancelled. Choose a photo to try again."
    }
  }
}
