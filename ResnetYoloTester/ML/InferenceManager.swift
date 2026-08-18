import CoreImage
import CoreML
import CoreVideo
import Foundation
import Vision

/// Owns the two CoreML/Vision pipelines under study:
///
/// - **Architecture B**: a single-stage, 7-class YOLO11n detector
///   (`YOLONanoDetector`), run standalone on the full frame.
/// - **Architecture A**: a 4-stage cascade —
///   1. `ROIDetector` (YOLO11n) proposes one top-1 region of interest on the
///      full frame.
///   2. `PADetector` (YOLO11m) runs on that ROI crop (not the full frame)
///      and proposes up to `maxPABoxes` candidate particles.
///   3. `ResNetBinary` classifies each particle crop as asbestos (`A`) vs.
///      not (`NA-OF`). If `P(A) < asbestosPresenceThreshold` the cascade
///      stops there and reports `NA-OF`.
///   4. `ResNetSubtype` only runs when `P(A) >=` that threshold, refining to
///      a subtype (`A-AM` / `A-C` / `A-CRO`); if its top confidence is below
///      `subtypeConfidenceThreshold` it falls back to the generic `A` label.
///
/// Every detector's confidence/IoU thresholds are baked into its `.mlpackage`
/// at export time (see `MLModels/export_to_coreml.ipynb`) via CoreML's NMS
/// pipeline — Vision hands back `VNRecognizedObjectObservation`s directly, no
/// manual decode/NMS here. The per-particle box cap and the P(A) routing
/// logic, however, are runtime behavior and live in this file.
///
/// Models are resolved by filename from the app bundle at runtime (rather
/// than through Xcode's auto-generated Swift model classes) — see
/// `MLModels/README.md`.
///
/// All methods here are synchronous and CPU-bound; callers are expected to
/// invoke them from a dedicated background queue (the camera's
/// video-data-output queue), never from the main thread.
final class InferenceManager {

    enum ModelFile {
        static let roiDetector = "ROIDetector"
        static let paDetector = "PADetector"
        static let resnetBinary = "ResNetBinary"
        static let resnetSubtype = "ResNetSubtype"
        static let yoloNanoDetector = "YOLONanoDetector"
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

    /// Architecture A: reported as "NA-OF" whenever P(A) falls below this.
    private static let asbestosPresenceThreshold: Float = 0.4
    /// Architecture A: subtype label is only trusted at/above this confidence,
    /// otherwise the cascade falls back to the generic "A" label.
    private static let subtypeConfidenceThreshold: Float = 0.25
    /// Architecture A: PADetector isn't capped at export time, so this is
    /// enforced here.
    private static let maxPABoxes = 100

    private var roiDetectorModel: VNCoreMLModel?
    private var paDetectorModel: VNCoreMLModel?
    private var resnetBinaryModel: VNCoreMLModel?
    private var resnetSubtypeModel: VNCoreMLModel?
    private var yoloNanoDetectorModel: VNCoreMLModel?
    private let ciContext = CIContext()

    /// Loads all five CoreML models from the app bundle. Safe to call
    /// repeatedly; a missing model just leaves the pipelines that depend on
    /// it unavailable until `run(architecture:on:)` throws
    /// `InferenceError.modelNotLoaded`.
    func loadModelsIfNeeded() {
        if roiDetectorModel == nil {
            roiDetectorModel = Self.loadModel(named: ModelFile.roiDetector)
        }
        if paDetectorModel == nil {
            paDetectorModel = Self.loadModel(named: ModelFile.paDetector)
        }
        if resnetBinaryModel == nil {
            resnetBinaryModel = Self.loadModel(named: ModelFile.resnetBinary)
        }
        if resnetSubtypeModel == nil {
            resnetSubtypeModel = Self.loadModel(named: ModelFile.resnetSubtype)
        }
        if yoloNanoDetectorModel == nil {
            yoloNanoDetectorModel = Self.loadModel(named: ModelFile.yoloNanoDetector)
        }
    }

    /// Runs the requested pipeline against one frame. Synchronous/blocking —
    /// call from a background queue only.
    func run(architecture: PipelineArchitecture, on pixelBuffer: CVPixelBuffer) throws -> [Detection] {
        switch architecture {
        case .architectureB:
            return try runArchitectureB(pixelBuffer: pixelBuffer)
        case .architectureA:
            return try runArchitectureA(pixelBuffer: pixelBuffer)
        }
    }

    // MARK: - Architecture B: standalone 7-class detector

    private func runArchitectureB(pixelBuffer: CVPixelBuffer) throws -> [Detection] {
        guard let yoloNanoDetectorModel else { throw InferenceError.modelNotLoaded(ModelFile.yoloNanoDetector) }

        return try detect(in: pixelBuffer, using: yoloNanoDetectorModel).map {
            Detection(boundingBox: $0.boundingBox, label: $0.label, confidence: $0.confidence)
        }
    }

    // MARK: - Architecture A: ROI -> PA -> binary -> subtype cascade

    private func runArchitectureA(pixelBuffer: CVPixelBuffer) throws -> [Detection] {
        guard let roiDetectorModel else { throw InferenceError.modelNotLoaded(ModelFile.roiDetector) }
        guard let paDetectorModel else { throw InferenceError.modelNotLoaded(ModelFile.paDetector) }
        guard let resnetBinaryModel else { throw InferenceError.modelNotLoaded(ModelFile.resnetBinary) }
        guard let resnetSubtypeModel else { throw InferenceError.modelNotLoaded(ModelFile.resnetSubtype) }

        // Stage 1: top-1 ROI on the full frame.
        guard let roi = try detect(in: pixelBuffer, using: roiDetectorModel).max(by: { $0.confidence < $1.confidence }) else {
            return []
        }
        guard let roiCrop = PixelBufferUtilities.crop(pixelBuffer, toNormalizedRect: roi.boundingBox, context: ciContext) else {
            return []
        }

        // Stage 2: up to maxPABoxes candidate particles, run on the ROI crop.
        let paBoxes = try detect(in: roiCrop, using: paDetectorModel)
            .sorted { $0.confidence > $1.confidence }
            .prefix(Self.maxPABoxes)

        var detections: [Detection] = []
        detections.reserveCapacity(paBoxes.count)

        for pa in paBoxes {
            guard let paCrop = PixelBufferUtilities.crop(roiCrop, toNormalizedRect: pa.boundingBox, context: ciContext) else {
                continue
            }
            guard let classification = try? classifyParticle(
                paCrop,
                binaryModel: resnetBinaryModel,
                subtypeModel: resnetSubtypeModel
            ) else {
                continue
            }

            let fullFrameBox = Self.map(pa.boundingBox, fromNormalizedSpaceOf: roi.boundingBox)
            detections.append(Detection(boundingBox: fullFrameBox, label: classification.label, confidence: classification.confidence))
        }

        return detections
    }

    // Stages 3 & 4: P(A) binary gate, then subtype refinement.
    private func classifyParticle(
        _ pixelBuffer: CVPixelBuffer,
        binaryModel: VNCoreMLModel,
        subtypeModel: VNCoreMLModel
    ) throws -> (label: String, confidence: Float) {
        let binary = try classifyAll(pixelBuffer, using: binaryModel)
        let pOfA = binary.first(where: { $0.label == "A" })?.confidence ?? 0

        guard pOfA >= Self.asbestosPresenceThreshold else {
            let pOfNAOF = binary.first(where: { $0.label == "NA-OF" })?.confidence ?? (1 - pOfA)
            return ("NA-OF", pOfNAOF)
        }

        let subtype = try classifyAll(pixelBuffer, using: subtypeModel)
        if let top = subtype.max(by: { $0.confidence < $1.confidence }), top.confidence >= Self.subtypeConfidenceThreshold {
            return (top.label, top.confidence)
        }
        return ("A", pOfA)
    }

    // MARK: - Vision requests

    /// Runs a YOLO object detector (NMS baked in at export time) and returns
    /// its raw boxes/labels/confidences. Shared by `ROIDetector`,
    /// `PADetector`, and `YOLONanoDetector`.
    private func detect(
        in pixelBuffer: CVPixelBuffer,
        using model: VNCoreMLModel
    ) throws -> [(boundingBox: CGRect, label: String, confidence: Float)] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        let observations = request.results as? [VNRecognizedObjectObservation] ?? []
        return observations.compactMap { observation in
            guard let topLabel = observation.labels.first else { return nil }
            return (observation.boundingBox, topLabel.identifier, topLabel.confidence)
        }
    }

    /// Runs a ResNet classifier and returns every class's confidence (Vision
    /// ranks them, but the cascade needs P(A) specifically, not just top-1).
    private func classifyAll(
        _ pixelBuffer: CVPixelBuffer,
        using model: VNCoreMLModel
    ) throws -> [(label: String, confidence: Float)] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        guard let results = request.results as? [VNClassificationObservation], !results.isEmpty else {
            throw InferenceError.noResult
        }
        return results.map { ($0.identifier, $0.confidence) }
    }

    /// Maps a box normalized to a crop's own bounds (0...1, bottom-left
    /// origin) back into full-frame normalized coordinates, given the
    /// normalized rect that crop came from. Cropping never rescales, so this
    /// fraction-of-a-fraction math is exact — no aspect distortion to
    /// correct for.
    private static func map(_ rect: CGRect, fromNormalizedSpaceOf container: CGRect) -> CGRect {
        CGRect(
            x: container.origin.x + rect.origin.x * container.width,
            y: container.origin.y + rect.origin.y * container.height,
            width: rect.width * container.width,
            height: rect.height * container.height
        )
    }

    private static func loadModel(named name: String) -> VNCoreMLModel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            print("InferenceManager: could not find compiled model '\(name).mlmodelc' in bundle.")
            return nil
        }
        do {
            // .cpuOnly rules out a Metal/ANE graph-compiler crash (MTLReportFailure inside
            // MPSGraphExecutable) seen on-device with these NMS-pipeline exports on iOS 26.
            // Revert to .all once re-exported models are confirmed stable on the ANE — running
            // CPU-only defeats the point of an ANE benchmark, this is a diagnostic step only.
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: url, configuration: configuration)
            return try VNCoreMLModel(for: model)
        } catch {
            print("InferenceManager: failed to load model '\(name)': \(error)")
            return nil
        }
    }
}
