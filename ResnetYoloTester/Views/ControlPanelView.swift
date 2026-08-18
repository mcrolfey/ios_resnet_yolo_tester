import SwiftUI

/// Architecture toggle + Start/Stop Stress Test controls.
struct ControlPanelView: View {
    @Binding var selectedArchitecture: PipelineArchitecture
    let isStressTesting: Bool
    let loggedFileURL: URL?
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Picker("Architecture", selection: $selectedArchitecture) {
                ForEach(PipelineArchitecture.allCases) { architecture in
                    Text(architecture.shortLabel).tag(architecture)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isStressTesting)

            Button(action: isStressTesting ? onStop : onStart) {
                Text(isStressTesting ? "Stop Stress Test" : "Start Stress Test")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(isStressTesting ? .red : .green)

            if let loggedFileURL {
                Text(loggedFileURL.lastPathComponent)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
