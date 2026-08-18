import CoreImage
import CoreML
import CoreVideo
import Foundation
import Vision

/// Owns the two CoreML/Vision pipelines under study:
///
/// - **Architecture B**: a single-stage YOLOv11n object detector.
/// - **Architecture A**: the same YOLOv11n model used as an ROI proposer,
///   followed by cropping each detected region out of the source
///   `CVPixelBuffer` and running it through a ResNet classifier.
///
/// Models are resolved by filename from the app bundle at runtime (rather
/// than through Xcode's auto-generated Swift model classes), so this file
/// compiles cleanly before the real `.mlpackage` models are dropped in —
/// see `MLModels/README.md`.
///
/// All methods here are synchronous and CPU-bound; callers are expected to
/// invoke them from a dedicated background queue (the camera's
/// video-data-output queue), never from the main thread.
final class InferenceManager {

    enum ModelFile {
        /// Update these to match the compiled model filenames once the real
        /// `.mlpackage` models are added to the Xcode target.
        static let roiDetector = "YOLOv11nDetector"
        static let resnetClassifier = "ResNetClassifier"
    }

    enum InferenceError: LocalizedError {
        case modelNotLoaded(String)
        case noResult

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded(let name):
                return "Model '\(name)' is not loaded. Add its .mlpackage to the Xcode target."
            case .noResult:
                return "Vision request produced no result."
            }
        }
    }

    private var detectorModel: VNCoreMLModel?
    private var classifierModel: VNCoreMLModel?
    private let ciContext = CIContext()

    var isDetectorReady: Bool { detectorModel != nil }
    var isClassifierReady: Bool { classifierModel != nil }

    /// Loads both CoreML models from the app bundle. Safe to call repeatedly;
    /// a missing model just leaves the corresponding pipeline unavailable
    /// until `run(architecture:on:)` throws `InferenceError.modelNotLoaded`.
    func loadModelsIfNeeded() {
        if detectorModel == nil {
            detectorModel = Self.loadModel(named: ModelFile.roiDetector)
        }
        if classifierModel == nil {
            classifierModel = Self.loadModel(named: ModelFile.resnetClassifier)
        }
    }

    /// Runs the requested pipeline against one frame. Synchronous/blocking —
    /// call from a background queue only.
    func run(architecture: PipelineArchitecture, on pixelBuffer: CVPixelBuffer) throws -> [Detection] {
        switch architecture {
        case .architectureB:
            return try detectROIs(in: pixelBuffer)
        case .architectureA:
            return try runArchitectureA(pixelBuffer: pixelBuffer)
        }
    }

    // MARK: - Architecture A: YOLO ROI proposer + ResNet classifier

    private func runArchitectureA(pixelBuffer: CVPixelBuffer) throws -> [Detection] {
        let rois = try detectROIs(in: pixelBuffer)
        guard !rois.isEmpty else { return [] }

        return rois.map { roi in
            guard
                let cropped = PixelBufferUtilities.crop(pixelBuffer, toNormalizedRect: roi.boundingBox, context: ciContext),
                let classification = try? classify(cropped)
            else {
                // Classifier unavailable or crop failed — fall back to the
                // raw ROI detection so the box is still visible/loggable.
                return roi
            }
            return Detection(boundingBox: roi.boundingBox, label: classification.label, confidence: classification.confidence)
        }
    }

    // MARK: - Vision requests

    /// Runs the YOLOv11n detector. Used standalone for Architecture B and as
    /// the ROI proposer for Architecture A.
    private func detectROIs(in pixelBuffer: CVPixelBuffer) throws -> [Detection] {
        guard let detectorModel else { throw InferenceError.modelNotLoaded(ModelFile.roiDetector) }

        let request = VNCoreMLRequest(model: detectorModel)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        let observations = request.results as? [VNRecognizedObjectObservation] ?? []
        return observations.compactMap { observation in
            guard let topLabel = observation.labels.first else { return nil }
            return Detection(boundingBox: observation.boundingBox, label: topLabel.identifier, confidence: topLabel.confidence)
        }
    }

    private func classify(_ pixelBuffer: CVPixelBuffer) throws -> (label: String, confidence: Float) {
        guard let classifierModel else { throw InferenceError.modelNotLoaded(ModelFile.resnetClassifier) }

        let request = VNCoreMLRequest(model: classifierModel)
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        guard let top = (request.results as? [VNClassificationObservation])?.first else {
            throw InferenceError.noResult
        }
        return (top.identifier, top.confidence)
    }

    private static func loadModel(named name: String) -> VNCoreMLModel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            print("InferenceManager: could not find compiled model '\(name).mlmodelc' in bundle.")
            return nil
        }
        do {
            let model = try MLModel(contentsOf: url)
            return try VNCoreMLModel(for: model)
        } catch {
            print("InferenceManager: failed to load model '\(name)': \(error)")
            return nil
        }
    }
}
