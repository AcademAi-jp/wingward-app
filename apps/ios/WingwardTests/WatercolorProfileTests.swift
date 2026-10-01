import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Wingward

@MainActor
final class WatercolorProfileTests: XCTestCase {
  func testRendererDownsamplesSyntheticHighResolutionImageAndProducesPNG() throws {
    let source = syntheticPNG(width: 3_200, height: 2_400)
    let output = try WatercolorProfileRenderer().render(data: source)

    XCTAssertEqual(Array(output.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    let image = try XCTUnwrap(UIImage(data: output)?.cgImage)
    XCTAssertLessThanOrEqual(max(image.width, image.height), 1_200)
    XCTAssertGreaterThan(image.width, 1)
    XCTAssertGreaterThan(image.height, 1)
    XCTAssertLessThanOrEqual(output.count, WatercolorProfileRenderer.maxOutputBytes)
  }

  func testRendererAppliesImageOrientationBeforeRendering() throws {
    let source = try syntheticJPEG(width: 180, height: 120, orientation: 6)
    let output = try WatercolorProfileRenderer().render(data: source)
    let image = try XCTUnwrap(UIImage(data: output)?.cgImage)

    XCTAssertEqual(image.width, 120)
    XCTAssertEqual(image.height, 180)
  }

  func testRendererRejectsInvalidAndOversizedInputBeforeDecoding() {
    XCTAssertThrowsError(try WatercolorProfileRenderer().render(data: Data())) { error in
      XCTAssertEqual(error as? WatercolorProfileRendererError, .invalidPhoto)
    }

    let oversized = Data(repeating: 0, count: WatercolorProfileRenderer.maxInputBytes + 1)
    XCTAssertThrowsError(try WatercolorProfileRenderer().render(data: oversized)) { error in
      XCTAssertEqual(error as? WatercolorProfileRendererError, .invalidPhoto)
    }
  }

  func testLatePickerPreparationCannotOverwriteNewerSelection() async throws {
    let source = syntheticPNG(width: 120, height: 120)
    let renderer = BlockingWatercolorRenderer(output: source)
    let store = WatercolorProfileStore(
      api: TestProfilePhotoAPI(responses: [.success(.fixture)]),
      renderer: renderer
    )

    let oldTask = store.prepare(sourceData: source)
    let firstEntered = await Task.detached {
      renderer.firstEntered.wait(timeout: .now() + 5) == .success
    }.value
    XCTAssertTrue(firstEntered)
    let newTask = store.prepare(sourceData: source)
    let secondEntered = await Task.detached {
      renderer.secondEntered.wait(timeout: .now() + 5) == .success
    }.value
    XCTAssertTrue(secondEntered)

    renderer.firstRelease.signal()
    await oldTask.value
    XCTAssertEqual(store.phase, .processing)

    renderer.secondRelease.signal()
    await newTask.value
    XCTAssertEqual(store.phase, .preview)
  }

  func testReplaceInvalidatesLatePreparation() async throws {
    let source = syntheticPNG(width: 120, height: 120)
    let renderer = BlockingWatercolorRenderer(output: source)
    let store = WatercolorProfileStore(
      api: TestProfilePhotoAPI(responses: [.success(.fixture)]),
      renderer: renderer
    )

    let task = store.prepare(sourceData: source)
    let firstEntered = await Task.detached {
      renderer.firstEntered.wait(timeout: .now() + 5) == .success
    }.value
    XCTAssertTrue(firstEntered)
    store.replace()
    renderer.firstRelease.signal()
    await task.value

    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.previewImage)
    XCTAssertFalse(store.canSave)
  }

  func testOwnerChangeClearsPreviewAndUsesTheNewOwnerAPI() async throws {
    let source = syntheticPNG(width: 120, height: 120)
    let firstAPI = TestProfilePhotoAPI(responses: [.success(.fixture)])
    let secondAPI = TestProfilePhotoAPI(responses: [.success(.secondFixture)])
    let store = WatercolorProfileStore(
      api: firstAPI,
      renderer: ImmediateWatercolorRenderer()
    )

    await store.prepare(sourceData: source).value
    XCTAssertEqual(store.phase, .preview)
    store.resetForOwnerChange(api: secondAPI)
    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.previewImage)
    XCTAssertFalse(store.canSave)

    await store.prepare(sourceData: source).value
    await store.save().value
    XCTAssertEqual(store.savedAvatarURL, ProfilePhotoSaveResult.secondFixture.avatarURL)
    let firstUploads = await firstAPI.uploads()
    let secondUploads = await secondAPI.uploads()
    XCTAssertEqual(firstUploads.count, 0)
    XCTAssertEqual(secondUploads.count, 1)
  }

  func testStorePreviewsThenUploadsOnlyTheTransformedPNG() async throws {
    let source = syntheticPNG(width: 240, height: 180)
    let api = TestProfilePhotoAPI(responses: [.success(.fixture)])
    let store = WatercolorProfileStore(api: api)

    await store.prepare(sourceData: source).value
    XCTAssertEqual(store.phase, .preview)
    XCTAssertNotNil(store.previewImage)
    XCTAssertTrue(store.canSave)

    await store.save().value
    XCTAssertEqual(store.phase, .saved)
    XCTAssertEqual(store.savedAvatarURL, ProfilePhotoSaveResult.fixture.avatarURL)
    XCTAssertFalse(store.canSave)

    let uploads = await api.uploads()
    XCTAssertEqual(uploads.count, 1)
    XCTAssertNotEqual(uploads[0], source)
    XCTAssertEqual(Array(uploads[0].prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
  }

  func testSavedAvatarCanBeRestoredAfterRevisitingTheProfile() async throws {
    let api = TestProfilePhotoAPI(responses: [.success(.fixture)])
    let source = syntheticPNG(width: 160, height: 160)
    let firstVisit = WatercolorProfileStore(api: api, renderer: ImmediateWatercolorRenderer())
    await firstVisit.prepare(sourceData: source).value
    await firstVisit.save().value
    XCTAssertEqual(firstVisit.phase, .saved)

    await api.setAvatarReadError(.temporarilyUnavailable)
    let revisit = WatercolorProfileStore(api: api, renderer: ImmediateWatercolorRenderer())
    await revisit.loadSavedAvatar().value
    XCTAssertEqual(revisit.phase, .failed(.loadFailed))
    XCTAssertNil(revisit.savedAvatarURL)

    await api.setAvatarReadError(nil)
    await revisit.retryLoadSavedAvatar().value
    XCTAssertEqual(revisit.phase, .saved)
    XCTAssertEqual(revisit.savedAvatarURL, ProfilePhotoSaveResult.fixture.avatarURL)
    XCTAssertNil(revisit.previewImage)
    XCTAssertFalse(revisit.canSave)
    let readCount = await api.avatarReadCount()
    XCTAssertEqual(readCount, 2)
  }

  func testProfileAvatarStateAcceptsOnlyTheNewestSameOwnerRefresh() {
    let ownerID = "profile-owner"
    var state = BilingualProductionProfileAvatarState()
    let earlierGeneration = state.beginRefresh(ownerID: ownerID)
    let laterGeneration = state.beginRefresh(ownerID: ownerID)
    let latestURL = URL(string: "https://cdn.example.test/latest.png")!
    let staleURL = URL(string: "https://cdn.example.test/stale.png")!

    state.finishRefresh(avatarURL: latestURL, ownerID: ownerID, generation: laterGeneration)
    state.finishRefresh(avatarURL: staleURL, ownerID: ownerID, generation: earlierGeneration)

    XCTAssertEqual(state.avatarURL, latestURL)
    XCTAssertFalse(state.isCurrent(ownerID: ownerID, generation: earlierGeneration))
    XCTAssertTrue(state.isCurrent(ownerID: ownerID, generation: laterGeneration))

    let nextOwnerGeneration = state.beginRefresh(ownerID: "different-owner")
    state.finishRefresh(avatarURL: staleURL, ownerID: ownerID, generation: laterGeneration)
    XCTAssertNil(state.avatarURL)
    XCTAssertTrue(state.isCurrent(ownerID: "different-owner", generation: nextOwnerGeneration))
  }

  func testOwnerChangeRejectsLateSaveFromPreviousOwner() async throws {
    let oldAPI = SuspendedProfilePhotoAPI()
    let newAPI = TestProfilePhotoAPI(responses: [.success(.secondFixture)])
    let store = WatercolorProfileStore(api: oldAPI, renderer: ImmediateWatercolorRenderer())
    let source = syntheticPNG(width: 120, height: 120)
    await store.prepare(sourceData: source).value
    let oldSave = store.save()
    await oldAPI.waitForSave()

    store.resetForOwnerChange(api: newAPI)
    await store.prepare(sourceData: source).value
    await store.save().value
    await oldAPI.complete()
    await oldSave.value

    XCTAssertEqual(store.phase, .saved)
    XCTAssertEqual(store.savedAvatarURL, ProfilePhotoSaveResult.secondFixture.avatarURL)
    XCTAssertFalse(store.canSave)
  }

  func testReplaceRejectsLateSaveAndClearsPreview() async throws {
    let api = SuspendedProfilePhotoAPI()
    let store = WatercolorProfileStore(api: api, renderer: ImmediateWatercolorRenderer())
    await store.prepare(sourceData: syntheticPNG(width: 120, height: 120)).value
    let save = store.save()
    await api.waitForSave()
    store.replace()
    await api.complete()
    await save.value

    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.savedAvatarURL)
    XCTAssertNil(store.previewImage)
    XCTAssertFalse(store.canSave)
  }

  func testStoreKeepsPreviewForUnavailableUploadAndRetry() async throws {
    let api = TestProfilePhotoAPI(responses: [
      .failure(.temporarilyUnavailable),
      .success(.fixture)
    ])
    let store = WatercolorProfileStore(api: api)
    await store.prepare(sourceData: syntheticPNG(width: 160, height: 160)).value

    await store.save().value
    XCTAssertEqual(store.phase, .failed(.unavailable))
    XCTAssertTrue(store.hasPreview)
    XCTAssertTrue(store.canSave)

    await store.retrySave().value
    XCTAssertEqual(store.phase, .saved)
    let uploads = await api.uploads()
    XCTAssertEqual(uploads.count, 2)
  }

  func testProfilePhotoResponseRequiresHTTPSURL() throws {
    let valid = Data(#"{"data":{"avatar_url":"https://cdn.example.test/profile.png"}}"#.utf8)
    let result = try APIResponseDecoder.decode(valid, as: ProfilePhotoSaveResult.self)
    XCTAssertEqual(result.avatarURL.absoluteString, "https://cdn.example.test/profile.png")

    for rawURL in [
      "http://cdn.example.test/profile.png",
      "https://user:password@cdn.example.test/profile.png",
      "https://cdn.example.test/profile.png#private"
    ] {
      let data = Data(#"{"data":{"avatar_url":"\#(rawURL)"}}"#.utf8)
      XCTAssertThrowsError(
        try APIResponseDecoder.decode(data, as: ProfilePhotoSaveResult.self)
      ) { error in
        XCTAssertEqual(error as? APIClientError, .invalidResponse)
      }
    }
  }

  func testLivePhotoAPIUsesPNGContentTypeAndOwnerBoundClient() async throws {
    let body = Data(#"{"data":{"avatar_url":"https://cdn.example.test/profile.png"}}"#.utf8)
    let transport = FakeAPIHTTPTransport(
      outcome: .response(data: body, statusCode: 200, headers: [:])
    )
    let client = try AuthenticatedAPIClient(
      baseURL: URL(string: "https://api.example.test")!,
      tokenProvider: TestTokenProvider(),
      transport: transport
    )
    let api = LiveProfilePhotoAPI(
      client: client,
      expectedOwnerID: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
    )
    let png = Data([137, 80, 78, 71])

    _ = try await api.saveWatercolorProfilePhoto(png)

    let requests = await transport.requests()
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.url.absoluteString, "https://api.example.test/api/auth/me/photo")
    XCTAssertEqual(request.headers["Content-Type"], "image/png")
    XCTAssertEqual(request.headers["Accept"], "application/json")
    XCTAssertEqual(request.body, png)
    XCTAssertEqual(request.headers["Authorization"], "Bearer synthetic-token")
  }

  func testLivePhotoAPIReadsCurrentAvatarFromTheOwnerProfileEndpoint() async throws {
    let ownerID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
    let body = Data(
      #"{"data":{"id":"\#(ownerID.uuidString)","avatar_url":"https://cdn.example.test/current.png","age_verified":true}}"#.utf8
    )
    let transport = FakeAPIHTTPTransport(
      outcome: .response(data: body, statusCode: 200, headers: [:])
    )
    let client = try AuthenticatedAPIClient(
      baseURL: URL(string: "https://api.example.test")!,
      tokenProvider: TestTokenProvider(),
      transport: transport
    )
    let api = LiveProfilePhotoAPI(client: client, expectedOwnerID: ownerID)

    let avatarURL = try await api.fetchSavedAvatarURL()

    XCTAssertEqual(avatarURL?.absoluteString, "https://cdn.example.test/current.png")
    let requests = await transport.requests()
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.method, "GET")
    XCTAssertEqual(request.url.absoluteString, "https://api.example.test/api/auth/me")
    XCTAssertEqual(request.headers["Authorization"], "Bearer synthetic-token")
    XCTAssertEqual(request.headers["Accept"], "application/json")
  }

  func testLivePhotoAPIRejectsAProfileResponseForAnotherOwner() async throws {
    let expectedOwnerID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
    let otherOwnerID = UUID(uuidString: "00000000-0000-0000-0000-000000000456")!
    let body = Data(
      #"{"data":{"id":"\#(otherOwnerID.uuidString)","avatar_url":"https://cdn.example.test/other.png"}}"#.utf8
    )
    let transport = FakeAPIHTTPTransport(
      outcome: .response(data: body, statusCode: 200, headers: [:])
    )
    let client = try AuthenticatedAPIClient(
      baseURL: URL(string: "https://api.example.test")!,
      tokenProvider: TestTokenProvider(),
      transport: transport
    )
    let api = LiveProfilePhotoAPI(client: client, expectedOwnerID: expectedOwnerID)

    do {
      _ = try await api.fetchSavedAvatarURL()
      XCTFail("A profile response for another owner must be rejected")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidResponse)
    }
  }

  func testPhotoReadResultDistinguishesNoAvatarFromMalformedAvatarData() throws {
    let empty = try APIResponseDecoder.decode(
      Data(#"{"data":{"id":"00000000-0000-0000-0000-000000000123","avatar_url":null}}"#.utf8),
      as: ProfilePhotoReadResult.self
    )
    XCTAssertNil(empty.avatarURL)

    for body in [
      #"{"data":{"avatar_url":null}}"#,
      #"{"data":{"id":"not-a-uuid","avatar_url":null}}"#,
      #"{"data":{}}"#,
      #"{"data":{"id":"00000000-0000-0000-0000-000000000123"}}"#,
      #"{"data":{"id":"00000000-0000-0000-0000-000000000123","avatar_url":"http://cdn.example.test/profile.png"}}"#,
      #"{"data":{"id":"00000000-0000-0000-0000-000000000123","avatar_url":"https://user:password@cdn.example.test/profile.png"}}"#
    ] {
      XCTAssertThrowsError(
        try APIResponseDecoder.decode(Data(body.utf8), as: ProfilePhotoReadResult.self)
      ) { error in
        XCTAssertEqual(error as? APIClientError, .invalidResponse)
      }
    }
  }

  func testLivePhotoAPIRejectsOversizedPNGWithoutTransport() async throws {
    let transport = FakeAPIHTTPTransport()
    let client = try AuthenticatedAPIClient(
      baseURL: URL(string: "https://api.example.test")!,
      tokenProvider: TestTokenProvider(),
      transport: transport
    )
    let api = LiveProfilePhotoAPI(
      client: client,
      expectedOwnerID: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
    )
    let oversized = Data(repeating: 1, count: LiveProfilePhotoAPI.maxPNGBytes + 1)

    do {
      _ = try await api.saveWatercolorProfilePhoto(oversized)
      XCTFail("An oversized transformed image must fail before transport")
    } catch let error as APIClientError {
      XCTAssertEqual(error, .invalidRequest)
    }
    let requests = await transport.requests()
    XCTAssertEqual(requests.count, 0)
  }

  private func syntheticPNG(width: Int, height: Int) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(
      size: CGSize(width: width, height: height),
      format: format
    ).pngData { context in
      UIColor(red: 0.96, green: 0.91, blue: 0.75, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      UIColor(red: 0.15, green: 0.35, blue: 0.62, alpha: 1).setFill()
      UIBezierPath(
        ovalIn: CGRect(
          x: CGFloat(width) * 0.27,
          y: CGFloat(height) * 0.14,
          width: CGFloat(width) * 0.46,
          height: CGFloat(height) * 0.46
        )
      ).fill()
      UIColor(red: 0.74, green: 0.28, blue: 0.24, alpha: 1).setFill()
      UIBezierPath(
        roundedRect: CGRect(
          x: CGFloat(width) * 0.18,
          y: CGFloat(height) * 0.66,
          width: CGFloat(width) * 0.64,
          height: CGFloat(height) * 0.22
        ),
        cornerRadius: CGFloat(width) * 0.06
      ).fill()
    }
  }

  private func syntheticJPEG(width: Int, height: Int, orientation: Int) throws -> Data {
    let source = syntheticPNG(width: width, height: height)
    let image = try XCTUnwrap(UIImage(data: source)?.cgImage)
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    )
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImagePropertyOrientation: orientation] as CFDictionary
    )
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }
}

private struct TestTokenProvider: APIAccessTokenProvider, Sendable {
  func accessToken() async throws -> String? { "synthetic-token" }
}

private struct ImmediateWatercolorRenderer: WatercolorProfileRendering, Sendable {
  func render(data: Data) throws -> Data { data }
}

private final class BlockingWatercolorRenderer: WatercolorProfileRendering, @unchecked Sendable {
  let firstEntered = DispatchSemaphore(value: 0)
  let firstRelease = DispatchSemaphore(value: 0)
  let secondEntered = DispatchSemaphore(value: 0)
  let secondRelease = DispatchSemaphore(value: 0)

  private let lock = NSLock()
  private var renderCount = 0
  private let output: Data

  init(output: Data) {
    self.output = output
  }

  func render(data: Data) throws -> Data {
    lock.lock()
    renderCount += 1
    let current = renderCount
    lock.unlock()

    if current == 1 {
      firstEntered.signal()
      firstRelease.wait()
    } else if current == 2 {
      secondEntered.signal()
      secondRelease.wait()
    }
    return output
  }
}

private actor TestProfilePhotoAPI: ProfilePhotoAPI {
  enum StubError: Error, Sendable {
    case failed
  }

  private var responses: [Result<ProfilePhotoSaveResult, APIClientError>]
  private var savedAvatarURL: URL?
  private var avatarReadError: APIClientError?
  private var avatarReadCalls = 0
  private var recordedUploads: [Data] = []

  init(responses: [Result<ProfilePhotoSaveResult, APIClientError>]) {
    self.responses = responses
  }

  func fetchSavedAvatarURL() async throws -> URL? {
    avatarReadCalls += 1
    if let avatarReadError { throw avatarReadError }
    return savedAvatarURL
  }

  func saveWatercolorProfilePhoto(_ pngData: Data) async throws -> ProfilePhotoSaveResult {
    recordedUploads.append(pngData)
    let response = responses.isEmpty ? .success(.fixture) : responses.removeFirst()
    let saved = try response.get()
    savedAvatarURL = saved.avatarURL
    return saved
  }

  func setAvatarReadError(_ error: APIClientError?) { avatarReadError = error }
  func avatarReadCount() -> Int { avatarReadCalls }
  func uploads() -> [Data] { recordedUploads }
}

private actor SuspendedProfilePhotoAPI: ProfilePhotoAPI {
  private var completion: CheckedContinuation<ProfilePhotoSaveResult, Never>?
  private var started: CheckedContinuation<Void, Never>?

  func fetchSavedAvatarURL() async throws -> URL? { nil }

  func saveWatercolorProfilePhoto(_ pngData: Data) async throws -> ProfilePhotoSaveResult {
    await withCheckedContinuation { continuation in
      completion = continuation
      started?.resume()
      started = nil
    }
  }

  func waitForSave() async {
    if completion != nil { return }
    await withCheckedContinuation { started = $0 }
  }

  func complete() {
    completion?.resume(returning: .fixture)
    completion = nil
  }
}

private extension ProfilePhotoSaveResult {
  static let fixture = ProfilePhotoSaveResult(
    avatarURL: URL(string: "https://cdn.example.test/profile.png")!
  )

  static let secondFixture = ProfilePhotoSaveResult(
    avatarURL: URL(string: "https://cdn.example.test/profile-second.png")!
  )
}
