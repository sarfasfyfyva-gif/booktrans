import Foundation
import ImageIO
import UniformTypeIdentifiers
import BookTransCore

/// Writes book images, shrinking oversized ones.
///
/// A 4000-pixel scan rendered in a 390-point-wide WebView costs memory for no
/// visible gain, so anything larger than `maxDimension` is re-encoded once at
/// import time. The output keeps the source format, because block `imageRef`
/// values were computed from the parser's file names before the bytes were
/// touched — renaming here would break every reference.
enum ImageDownscaler {
    static let maxDimension: CGFloat = 1600

    /// Writes `data` to `url`. Returns false when nothing could be written.
    @discardableResult
    static func write(_ data: Data, to url: URL, maxDimension: CGFloat = maxDimension) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }

        guard let size = pixelSize(of: source),
              max(size.width, size.height) > Int(maxDimension)
        else {
            // Already small enough, or the format cannot be inspected: keep the
            // original bytes so nothing is lost.
            return FileStore.writeData(data, to: url)
        }

        // Animated formats lose their frames when re-encoded, so they are kept.
        let type = (CGImageSourceGetType(source) as String?) ?? ""
        if type == UTType.gif.identifier { return FileStore.writeData(data, to: url) }

        guard let outputType = outputUniformType(for: url),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, outputType.identifier as CFString, 1, nil)
        else {
            return FileStore.writeData(data, to: url)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return FileStore.writeData(data, to: url)
        }
        CGImageDestinationAddImage(destination, thumbnail, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// The image type to encode as, derived from the destination extension so the
    /// file name stays exactly what the parser produced.
    private static func outputUniformType(for url: URL) -> UTType? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "heic", "heif": return .heic
        case "tiff", "tif": return .tiff
        default: return nil
        }
    }
}
