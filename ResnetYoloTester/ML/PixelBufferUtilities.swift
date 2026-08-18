import CoreImage
import CoreVideo
import Vision

enum PixelBufferUtilities {
    /// Crops `pixelBuffer` to the region described by `normalizedRect`
    /// (Vision's bottom-left-origin, 0...1 normalized coordinate space)
    /// and returns a new `CVPixelBuffer` containing just that region.
    ///
    /// Used by Architecture A to hand each YOLO-proposed ROI to the ResNet
    /// classifier as its own buffer.
    static func crop(
        _ pixelBuffer: CVPixelBuffer,
        toNormalizedRect normalizedRect: CGRect,
        context: CIContext
    ) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelRect = VNImageRectForNormalizedRect(normalizedRect, width, height)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: pixelRect)
            .transformed(by: CGAffineTransform(translationX: -pixelRect.origin.x, y: -pixelRect.origin.y))

        var outputBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(pixelRect.width),
            Int(pixelRect.height),
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            attributes as CFDictionary,
            &outputBuffer
        )

        guard status == kCVReturnSuccess, let outputBuffer else { return nil }
        context.render(ciImage, to: outputBuffer)
        return outputBuffer
    }
}
