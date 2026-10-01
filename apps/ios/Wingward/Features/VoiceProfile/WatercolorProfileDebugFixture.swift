#if DEBUG
import Foundation
import SwiftUI

/// Synthetic-only profile-photo destination used by the local native journey.
/// It accepts the in-memory transformed bytes and returns a fixed private test
/// URL; it never reads a library asset or performs a network request.
struct WatercolorProfileDebugPhotoAPI: ProfilePhotoAPI, Sendable {
  func fetchSavedAvatarURL() async throws -> URL? { nil }

  func saveWatercolorProfilePhoto(_ pngData: Data) async throws -> ProfilePhotoSaveResult {
    guard pngData.isEmpty == false else { throw APIClientError.invalidRequest }
    return ProfilePhotoSaveResult(
      avatarURL: URL(string: "https://debug.example.test/profile-watercolor.png")!
    )
  }
}

enum WatercolorProfileDebugFixture {
  static func ownerViewFactory() -> NativeFeatureIntegration.OwnerViewFactory {
    { ownerID, _ in
      AnyView(
        WatercolorProfileView(
          ownerID: ownerID,
          api: WatercolorProfileDebugPhotoAPI()
        )
      )
    }
  }
}
#endif
