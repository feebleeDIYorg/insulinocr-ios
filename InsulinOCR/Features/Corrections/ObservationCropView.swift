import InsulinOCRCore
import SwiftUI
import UIKit

/// Enlarged part of the original screenshot around one observation, so the
/// signal in question can be read while its value is confirmed.
struct ObservationCropView: View {
    let screenshot: UIImage
    let kind: ObservationKind
    let boundingBox: NormalizedBoundingBox

    var body: some View {
        if let region = ObservationCropRegion.region(for: kind, boundingBox: boundingBox),
           let crop = Self.crop(screenshot, to: region) {
            Image(uiImage: crop)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .overlay {
                    if let mark = ObservationCropRegion.highlight(of: boundingBox, in: region) {
                        GeometryReader { proxy in
                            Rectangle()
                                .stroke(Color.accentColor, lineWidth: 2)
                                .frame(
                                    width: max(6, mark.width * proxy.size.width),
                                    height: max(6, mark.height * proxy.size.height)
                                )
                                .position(
                                    x: (mark.x + mark.width / 2) * proxy.size.width,
                                    y: (mark.y + mark.height / 2) * proxy.size.height
                                )
                        }
                        .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 160)
                .background(Color(.secondarySystemBackground))
                .clipShape(.rect(cornerRadius: 10))
                .accessibilityLabel("Bildausschnitt des ausgewählten Signals aus dem Original-Screenshot")
                .accessibilityIdentifier("correction.crop")
        }
    }

    private static func crop(_ image: UIImage, to region: NormalizedBoundingBox) -> UIImage? {
        guard let source = image.cgImage else { return nil }
        let width = Double(source.width), height = Double(source.height)
        let rect = CGRect(
            x: (region.x * width).rounded(.down),
            y: (region.y * height).rounded(.down),
            width: (region.width * width).rounded(.up),
            height: (region.height * height).rounded(.up)
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width >= 1, rect.height >= 1, let cropped = source.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }
}
