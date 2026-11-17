import Foundation
import ImageIO
import Observation
import UIKit

struct HomeBackgroundAdjustments: Codable, Equatable {
    var automatic = true
    var blur: Double = 14
    var dimming: Double = 0.12
    var visibility: Double = 0.5

    func resolved(dark: Bool, brightness: Double) -> Self {
        if automatic {
            return Self(automatic: true, blur: dark ? 16 : 12,
                        dimming: dark ? 0.24 + brightness * 0.22 : 0.04,
                        visibility: dark ? 0.65 : 0.32)
        }
        return clamped
    }

    var clamped: Self {
        Self(automatic: automatic, blur: Self.limit(blur, to: 0...30, fallback: 14),
             dimming: Self.limit(dimming, to: 0...0.8, fallback: 0.12),
             visibility: Self.limit(visibility, to: 0...1, fallback: 0.5))
    }

    private static func limit(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

/// Private home appearance files, independent of notebook metadata and original ink.
@MainActor
@Observable
final class HomeAppearanceModel {
    enum PhotoChange { case unchanged, replace(UIImage), remove }
    private struct Saved: Codable {
        var version = 1
        var adjustments: HomeBackgroundAdjustments
        var imageName: String?
    }

    private(set) var adjustments = HomeBackgroundAdjustments()
    private(set) var image: UIImage?
    private(set) var brightness = 0.5
    private(set) var problem: String?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var imageName: String?
    @ObservationIgnored private var canSave = true

    var settingsURL: URL { directory.appending(path: "home-appearance.json") }

    init(directory: URL) {
        self.directory = directory
        do {
            let data: Data
            do { data = try Data(contentsOf: settingsURL) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
            let saved = try JSONDecoder().decode(Saved.self, from: data)
            guard saved.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            if let name = saved.imageName {
                guard name.hasPrefix("home-background-"), name.hasSuffix(".jpg"),
                      URL(fileURLWithPath: name).lastPathComponent == name else { throw CocoaError(.fileReadCorruptFile) }
                let data = try Data(contentsOf: directory.appending(path: name))
                let loaded = try HomePhoto.decode(data)
                image = loaded
                brightness = HomePhoto.brightness(loaded)
            }
            imageName = saved.imageName
            adjustments = saved.adjustments.clamped
        } catch {
            canSave = false
            problem = "Your saved home background couldn't be opened. Its files have been kept."
        }
    }

    @discardableResult
    func save(_ settings: HomeBackgroundAdjustments, photo: PhotoChange = .unchanged) -> Bool {
        guard canSave else { return false }
        var nextName = imageName
        var nextImage = image
        var created: URL?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            switch photo {
            case .unchanged: break
            case .remove: nextName = nil; nextImage = nil
            case .replace(let image):
                guard let data = image.jpegData(compressionQuality: 0.9) else { throw CocoaError(.fileWriteUnknown) }
                let name = "home-background-\(UUID().uuidString).jpg"
                nextName = name
                let url = directory.appending(path: name)
                created = url
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                nextImage = image
            }
            let data = try JSONEncoder().encode(Saved(adjustments: settings.clamped, imageName: nextName))
            try data.write(to: settingsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let oldName = imageName
            adjustments = settings.clamped
            imageName = nextName
            image = nextImage
            brightness = nextImage.map(HomePhoto.brightness) ?? 0.5
            problem = nil
            if let oldName, oldName != nextName { try? FileManager.default.removeItem(at: directory.appending(path: oldName)) }
            return true
        } catch {
            if let created { try? FileManager.default.removeItem(at: created) }
            problem = "Couldn't save the home background. Your previous background is unchanged."
            return false
        }
    }
}

enum HomePhoto {
    /// Downsample before decoding: a full-resolution camera image needn't stay in memory behind the home.
    static func decode(_ data: Data) throws -> UIImage {
        guard data.count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        return UIImage(cgImage: image)
    }

    static func brightness(_ image: UIImage) -> Double {
        guard let image = image.cgImage else { return 0.5 }
        var pixel = [UInt8](repeating: 0, count: 4)
        let value = pixel.withUnsafeMutableBytes { bytes -> Double in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.5 }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let rgb = bytes.bindMemory(to: UInt8.self)
            return (0.2126 * Double(rgb[0]) + 0.7152 * Double(rgb[1]) + 0.0722 * Double(rgb[2])) / 255
        }
        return value
    }
}
