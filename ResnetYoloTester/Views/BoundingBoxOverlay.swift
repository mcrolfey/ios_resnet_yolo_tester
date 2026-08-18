import SwiftUI

/// Draws detection boxes + labels over the camera preview, scaled from
/// Vision's normalized coordinate space into on-screen points.
struct BoundingBoxOverlay: View {
    let detections: [Detection]

    var body: some View {
        Canvas { context, size in
            for detection in detections {
                let rect = Self.convert(detection.boundingBox, to: size)
                context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(.green), lineWidth: 2)

                let label = "\(detection.label) \(Int(detection.confidence * 100))%"
                let resolvedText = context.resolve(
                    Text(label).font(.caption2.bold()).foregroundColor(.white)
                )
                let textSize = resolvedText.measure(in: size)
                let backgroundOrigin = CGPoint(x: rect.minX, y: max(rect.minY - textSize.height - 4, 0))
                let backgroundRect = CGRect(
                    origin: backgroundOrigin,
                    size: CGSize(width: textSize.width + 6, height: textSize.height + 4)
                )

                context.fill(Path(backgroundRect), with: .color(.green.opacity(0.85)))
                context.draw(resolvedText, at: CGPoint(x: backgroundRect.minX + 3, y: backgroundRect.midY), anchor: .leading)
            }
        }
        .allowsHitTesting(false)
    }

    /// Converts a Vision-space normalized rect (origin bottom-left, 0...1)
    /// into the Canvas's coordinate space (origin top-left, points).
    ///
    /// Assumes the preview uses `.resizeAspectFill` and fills the overlay's
    /// full bounds; if the buffer's aspect ratio ever differs materially
    /// from the screen's, add letterbox-offset correction here.
    private static func convert(_ boundingBox: CGRect, to size: CGSize) -> CGRect {
        CGRect(
            x: boundingBox.minX * size.width,
            y: (1 - boundingBox.maxY) * size.height,
            width: boundingBox.width * size.width,
            height: boundingBox.height * size.height
        )
    }
}
