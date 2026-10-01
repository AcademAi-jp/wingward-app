import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Observation
import UIKit

enum WatercolorProfileRendererError: Error, Equatable, Sendable {
  case invalidPhoto
  case outputTooLarge
  case renderFailed
}

/// Performs the watercolor conversion entirely on the device.  The renderer
/// returns encoded output only; it never writes the source image to disk.
struct WatercolorProfileRenderer: Sendable {
  static let maxInputBytes = 20 * 1024 * 1024
  static let maxOutputBytes = 5 * 1024 * 1024
  static let maxPixelDimension: CGFloat = 1_200
  static let maxSourcePixelCount = 40_000_000

  func render(data: Data) throws -> Data {
    guard data.isEmpty == false, data.count <= Self.maxInputBytes else {
      throw WatercolorProfileRendererError.invalidPhoto
    }

    // ImageIO reads the dimensions and creates a bounded thumbnail before
    // UIKit or Core Image can decode the source. This prevents a small,
    // highly-compressed image with an enormous pixel canvas from being
    // expanded at full size in memory.
    guard let source = CGImageSourceCreateWithData(
      data as CFData,
      [kCGImageSourceShouldCache: false] as CFDictionary
    ), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 1, height > 1,
      width <= Self.maxSourcePixelCount / max(height, 1)
    else {
      throw WatercolorProfileRendererError.invalidPhoto
    }

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: Int(Self.maxPixelDimension),
      kCGImageSourceShouldCacheImmediately: false
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
      source,
      0,
      thumbnailOptions as CFDictionary
    ) else {
      throw WatercolorProfileRendererError.invalidPhoto
    }
    let sourceCI = CIImage(cgImage: thumbnail)

    let context = CIContext(options: nil)
    let resized = resize(sourceCI)
    guard resized.extent.width > 1, resized.extent.height > 1 else {
      throw WatercolorProfileRendererError.invalidPhoto
    }

    let luminance = try averageLuminance(of: resized, context: context)
    let result = try watercolorImage(
      from: resized,
      luminance: luminance,
      context: context
    )
    guard let cgImage = context.createCGImage(result, from: result.extent.integral),
      let pngData = UIImage(cgImage: cgImage).pngData()
    else {
      throw WatercolorProfileRendererError.renderFailed
    }
    guard pngData.count <= Self.maxOutputBytes else {
      throw WatercolorProfileRendererError.outputTooLarge
    }
    return pngData
  }

  private func resize(_ image: CIImage) -> CIImage {
    let extent = image.extent.integral
    let longest = max(extent.width, extent.height)
    guard longest > Self.maxPixelDimension else { return image.cropped(to: extent) }
    let scale = Self.maxPixelDimension / longest
    return image
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .cropped(to: CGRect(
        x: 0,
        y: 0,
        width: extent.width * scale,
        height: extent.height * scale
      ).integral)
  }

  private func averageLuminance(of image: CIImage, context: CIContext) throws -> CGFloat {
    let filter = CIFilter.areaAverage()
    filter.inputImage = image
    filter.extent = image.extent
    guard let average = filter.outputImage else {
      throw WatercolorProfileRendererError.renderFailed
    }

    var pixel = [UInt8](repeating: 0, count: 4)
    context.render(
      average,
      toBitmap: &pixel,
      rowBytes: 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    let red = CGFloat(pixel[0]) / 255
    let green = CGFloat(pixel[1]) / 255
    let blue = CGFloat(pixel[2]) / 255
    return min(max((red * 0.2126) + (green * 0.7152) + (blue * 0.0722), 0), 1)
  }

  private func watercolorImage(
    from image: CIImage,
    luminance: CGFloat,
    context: CIContext
  ) throws -> CIImage {
    let extent = image.extent.integral
    let brightnessAdjustment = (0.5 - luminance) * 0.12
    let noiseLevel = 0.015 + ((1 - luminance) * 0.02)
    let posterizeLevels = 5.0 + (luminance * 2.0)

    let smoothing = CIFilter.noiseReduction()
    smoothing.inputImage = image
    smoothing.noiseLevel = Float(noiseLevel)
    smoothing.sharpness = Float(0.35 + (luminance * 0.2))

    let posterize = CIFilter.colorPosterize()
    posterize.inputImage = smoothing.outputImage
    posterize.levels = Float(posterizeLevels)

    let controls = CIFilter.colorControls()
    controls.inputImage = posterize.outputImage
    controls.saturation = 0.82
    controls.contrast = Float(0.94 + (luminance * 0.08))
    controls.brightness = Float(brightnessAdjustment)

    let temperature = CIFilter.temperatureAndTint()
    temperature.inputImage = controls.outputImage
    temperature.neutral = CIVector(x: 6500, y: 0)
    temperature.targetNeutral = CIVector(x: 6100, y: 0)

    let edges = CIFilter.edges()
    edges.inputImage = smoothing.outputImage
    edges.intensity = Float(0.65 + (luminance * 0.2))

    let invertedEdges = CIFilter.colorInvert()
    invertedEdges.inputImage = edges.outputImage

    let edgeControls = CIFilter.colorControls()
    edgeControls.inputImage = invertedEdges.outputImage
    edgeControls.saturation = 0
    edgeControls.contrast = 0.7
    edgeControls.brightness = 0.04

    let multiply = CIFilter.multiplyBlendMode()
    multiply.inputImage = temperature.outputImage
    multiply.backgroundImage = edgeControls.outputImage

    guard let outlined = multiply.outputImage
    else {
      throw WatercolorProfileRendererError.renderFailed
    }

    let textured = addingPaperTexture(to: outlined, extent: extent)
    let mask = radialMask(extent: extent)
    let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
      .cropped(to: extent)
    guard let faded = applying(
      "CIBlendWithMask",
      to: textured,
      values: [
        kCIInputBackgroundImageKey: transparent,
        kCIInputMaskImageKey: mask
      ]
    ) else {
      throw WatercolorProfileRendererError.renderFailed
    }
    // `CIContext` is intentionally supplied to keep the render path explicit
    // and to prevent future changes from accidentally using a UIKit image
    // renderer that could retain the source orientation/data.
    _ = context
    return faded.cropped(to: extent)
  }

  private func addingPaperTexture(to image: CIImage, extent: CGRect) -> CIImage {
    guard let random = CIFilter.randomGenerator().outputImage,
      let neutral = applying(
        "CIColorControls",
        to: random.cropped(to: extent),
        values: [
          kCIInputSaturationKey: 0,
          kCIInputContrastKey: 0.1,
          kCIInputBrightnessKey: 0.45
        ]
      ), let translucent = applying(
        "CIColorMatrix",
        to: neutral,
        values: [
          "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.055)
        ]
      ), let result = applying(
        "CISourceOverCompositing",
        to: translucent,
        values: [kCIInputBackgroundImageKey: image]
      ) else {
      return image
    }
    return result.cropped(to: extent)
  }

  private func radialMask(extent: CGRect) -> CIImage {
    let center = CGPoint(x: extent.midX, y: extent.midY)
    let minimumDimension = min(extent.width, extent.height)
    let radius0 = minimumDimension * 0.34
    let radius1 = max(extent.width, extent.height) * 0.56
    let filter = CIFilter.radialGradient()
    filter.center = center
    filter.radius0 = Float(radius0)
    filter.radius1 = Float(radius1)
    filter.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
    filter.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
    return (filter.outputImage ?? CIImage(
      color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)
    )).cropped(to: extent)
  }

  private func applying(_ name: String, to image: CIImage, values: [String: Any]) -> CIImage? {
    guard let filter = CIFilter(name: name) else { return nil }
    filter.setValue(image, forKey: kCIInputImageKey)
    for (key, value) in values {
      filter.setValue(value, forKey: key)
    }
    return filter.outputImage
  }
}

protocol WatercolorProfileRendering: Sendable {
  func render(data: Data) throws -> Data
}

extension WatercolorProfileRenderer: WatercolorProfileRendering {}

enum WatercolorProfilePhase: Equatable, Sendable {
  case idle
  case loadingSaved
  case processing
  case preview
  case saving
  case saved
  case failed(WatercolorProfileError)
}

enum WatercolorProfileError: Error, Equatable, Sendable {
  case invalidPhoto
  case conversionFailed
  case uploadFailed
  case loadFailed
  case unavailable
  case cancelled
}

@MainActor
@Observable
final class WatercolorProfileStore {
  private(set) var phase: WatercolorProfilePhase = .idle
  private(set) var previewImage: UIImage?
  private(set) var savedAvatarURL: URL?

  private(set) var api: any ProfilePhotoAPI
  private let renderer: any WatercolorProfileRendering
  private var pendingPNGData: Data?
  @ObservationIgnored private var operation: Task<Void, Never>?
  private var generation: UInt64 = 0

  init(
    api: any ProfilePhotoAPI,
    renderer: any WatercolorProfileRendering = WatercolorProfileRenderer()
  ) {
    self.api = api
    self.renderer = renderer
  }

  var hasPreview: Bool { previewImage != nil && pendingPNGData != nil }
  var canSave: Bool {
    guard pendingPNGData != nil else { return false }
    return phase == .preview || phase == .failed(.uploadFailed) || phase == .failed(.unavailable)
  }

  func loadSavedAvatar() -> Task<Void, Never> {
    let operationGeneration = beginOperation()
    phase = .loadingSaved
    previewImage = nil
    pendingPNGData = nil
    savedAvatarURL = nil

    operation = Task { [weak self, api] in
      do {
        let avatarURL = try await api.fetchSavedAvatarURL()
        guard !Task.isCancelled else {
          self?.finish(.failed(.cancelled), generation: operationGeneration)
          return
        }
        self?.finishLoadedAvatar(url: avatarURL, generation: operationGeneration)
      } catch is CancellationError {
        self?.finish(.failed(.cancelled), generation: operationGeneration)
      } catch {
        self?.finish(.failed(.loadFailed), generation: operationGeneration)
      }
    }
    return operation!
  }

  func retryLoadSavedAvatar() -> Task<Void, Never> { loadSavedAvatar() }

  func prepare(sourceData: Data) -> Task<Void, Never> {
    let operationGeneration = beginOperation()
    phase = .processing
    previewImage = nil
    pendingPNGData = nil
    savedAvatarURL = nil

    let renderer = self.renderer
    operation = Task { [weak self] in
      do {
        let rendered = try await Task.detached(priority: .userInitiated) {
          try renderer.render(data: sourceData)
        }.value
        guard !Task.isCancelled else {
          self?.finish(.failed(.cancelled), generation: operationGeneration)
          return
        }
        guard let image = UIImage(data: rendered) else {
          self?.finish(.failed(.conversionFailed), generation: operationGeneration)
          return
        }
        self?.finishPreview(
          image: image,
          pngData: rendered,
          generation: operationGeneration
        )
      } catch is CancellationError {
        self?.finish(.failed(.cancelled), generation: operationGeneration)
      } catch let error as WatercolorProfileRendererError {
        let mapped: WatercolorProfileError = error == .invalidPhoto
          ? .invalidPhoto
          : .conversionFailed
        self?.finish(.failed(mapped), generation: operationGeneration)
      } catch {
        self?.finish(.failed(.conversionFailed), generation: operationGeneration)
      }
    }
    return operation!
  }

  func save() -> Task<Void, Never> {
    guard canSave, let data = pendingPNGData else { return Task {} }
    let operationGeneration = beginOperation()
    phase = .saving
    operation = Task { [weak self, api] in
      do {
        let result = try await api.saveWatercolorProfilePhoto(data)
        guard !Task.isCancelled else {
          self?.finish(.failed(.cancelled), generation: operationGeneration)
          return
        }
        self?.finishSaved(url: result.avatarURL, generation: operationGeneration)
      } catch is CancellationError {
        self?.finish(.failed(.cancelled), generation: operationGeneration)
      } catch let error as APIClientError {
        let mapped: WatercolorProfileError = error == .temporarilyUnavailable
          ? .unavailable
          : .uploadFailed
        self?.finish(.failed(mapped), generation: operationGeneration)
      } catch {
        self?.finish(.failed(.uploadFailed), generation: operationGeneration)
      }
    }
    return operation!
  }

  func retrySave() -> Task<Void, Never> { save() }

  func markPhotoLoadFailed() {
    beginOperation()
    phase = .failed(.invalidPhoto)
    previewImage = nil
    pendingPNGData = nil
    savedAvatarURL = nil
  }

  func replace() {
    beginOperation()
    phase = .idle
    previewImage = nil
    pendingPNGData = nil
    savedAvatarURL = nil
  }

  func cancel() {
    _ = beginOperation()
  }

  func resetForOwnerChange(api: any ProfilePhotoAPI) {
    beginOperation()
    self.api = api
    phase = .idle
    previewImage = nil
    pendingPNGData = nil
    savedAvatarURL = nil
  }

  private func beginOperation() -> UInt64 {
    operation?.cancel()
    operation = nil
    generation &+= 1
    return generation
  }

  private func isCurrent(_ operationGeneration: UInt64) -> Bool {
    operationGeneration == generation && !Task.isCancelled
  }

  private func finish(_ phase: WatercolorProfilePhase, generation: UInt64) {
    guard isCurrent(generation) else { return }
    self.phase = phase
    if case .failed(.conversionFailed) = phase {
      previewImage = nil
      pendingPNGData = nil
    }
    if case .failed(.invalidPhoto) = phase {
      previewImage = nil
      pendingPNGData = nil
    }
  }

  private func finishPreview(image: UIImage, pngData: Data, generation: UInt64) {
    guard isCurrent(generation) else { return }
    previewImage = image
    pendingPNGData = pngData
    phase = .preview
  }

  private func finishLoadedAvatar(url: URL?, generation: UInt64) {
    guard isCurrent(generation) else { return }
    savedAvatarURL = url
    phase = url == nil ? .idle : .saved
  }

  private func finishSaved(url: URL, generation: UInt64) {
    guard isCurrent(generation) else { return }
    savedAvatarURL = url
    phase = .saved
    // Keep the transformed preview visible for the confirmation state, but
    // release its upload buffer so a retry cannot accidentally resend stale
    // bytes after the user chooses another image.
    pendingPNGData = nil
  }

  deinit { operation?.cancel() }
}
