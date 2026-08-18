import CoreGraphics
import Foundation

/// The two inference pipelines under study.
enum PipelineArchitecture: String, CaseIterable, Identifiable {
    /// YOLOv11n (ROI detector) -> per-box crop -> ResNet classifier.
    case architectureA = "Architecture A (ROI + ResNet)"
    /// Standalone YOLOv11n detector.
    case architectureB = "Architecture B (YOLO Only)"

    var id: String { rawValue }

    /// Compact form used in the HUD and CSV rows.
    var shortLabel: String {
        switch self {
        case .architectureA: return "A"
        case .architectureB: return "B"
        }
    }
}

/// A single detected/classified object for one processed frame.
struct Detection: Identifiable {
    let id = UUID()
    /// Normalized bounding box in Vision's coordinate space (origin bottom-left, 0...1).
    let boundingBox: CGRect
    let label: String
    let confidence: Float
}

/// One row of the benchmark CSV — everything measured for a single processed frame.
struct FrameMetrics {
    let timestamp: Date
    let frameID: Int
    let architecture: PipelineArchitecture
    let detectionsCount: Int
    let latencyMs: Double
    let fps: Double
    let thermalState: ProcessInfo.ThermalState
    let memoryMB: Double
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}
