import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageImportMetadata: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let uniformTypeIdentifier: String
    let captureTime: Date?
}

enum ImageMetadataReader {
    static func read(data: Data, fallbackTypeIdentifier: String? = nil) -> ImageImportMetadata? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let detectedType = (CGImageSourceGetType(source) as String?)
            ?? fallbackTypeIdentifier
            ?? UTType.png.identifier

        let captureTime = exifCaptureDate(properties: properties)
            ?? tiffCaptureDate(properties: properties)
        return ImageImportMetadata(
            pixelWidth: width,
            pixelHeight: height,
            uniformTypeIdentifier: detectedType,
            captureTime: captureTime
        )
    }

    private static func exifCaptureDate(properties: [CFString: Any]) -> Date? {
        guard let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else {
            return nil
        }
        let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
        return value.flatMap(parseImageDate)
    }

    private static func tiffCaptureDate(properties: [CFString: Any]) -> Date? {
        guard let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
              let value = tiff[kCGImagePropertyTIFFDateTime] as? String else {
            return nil
        }
        return parseImageDate(value)
    }

    private static func parseImageDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: value)
    }
}
