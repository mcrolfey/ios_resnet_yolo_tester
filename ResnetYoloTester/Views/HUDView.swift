import SwiftUI

/// Live telemetry overlay: architecture, FPS, latency, thermal state, memory.
struct HUDView: View {
    let architecture: PipelineArchitecture
    let fps: Double
    let latencyMs: Double
    let thermalState: ProcessInfo.ThermalState
    let memoryMB: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Pipeline", architecture.shortLabel)
            row("FPS", String(format: "%.1f", fps))
            row("Latency", String(format: "%.1f ms", latencyMs))
            row("Thermal", thermalState.label)
            row("Memory", String(format: "%.0f MB", memoryMB))
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundColor(.white)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).opacity(0.7)
            Spacer(minLength: 16)
            Text(value).bold()
        }
    }
}
