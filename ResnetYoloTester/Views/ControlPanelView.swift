import SwiftUI

/// Architecture toggle + Start/Stop Stress Test controls.
struct ControlPanelView: View {
    @Binding var selectedArchitecture: PipelineArchitecture
    let isStressTesting: Bool
    let loggedFileURL: URL?
    let onStart: () -> Void
    let onStop: () -> Void

    /// Wraps the renamed export copy so `.sheet(item:)` can drive presentation
    /// directly off this optional — no separate Bool to race against.
    private struct ExportItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    @State private var isNamingExport = false
    @State private var exportFileName = ""
    @State private var exportItem: ExportItem?

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

                // Only offered once the run has actually stopped — the file
                // handle is closed by then, so what gets exported is complete.
                if !isStressTesting {
                    Button {
                        exportFileName = loggedFileURL.deletingPathExtension().lastPathComponent
                        isNamingExport = true
                    } label: {
                        Label("Save to Files", systemImage: "folder")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .alert("Name This File", isPresented: $isNamingExport) {
            TextField("File name", text: $exportFileName)
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard let loggedFileURL else { return }
                let name = exportFileName
                // A hair of delay avoids racing the alert's own dismissal —
                // presenting a sheet in the exact same tick UIKit is still
                // animating the alert away can silently no-op.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let renamed = Self.renamedCopy(of: loggedFileURL, named: name) else { return }
                    exportItem = ExportItem(url: renamed)
                }
            }
        } message: {
            Text("This is the name the CSV will be saved as.")
        }
        .sheet(item: $exportItem) { item in
            DocumentExporter(url: item.url)
        }
    }

    /// Copies `sourceURL` into a temp file named `name.csv` so the export
    /// picker offers the user's chosen name instead of the original
    /// timestamped filename. The original in Documents is left untouched.
    private static func renamedCopy(of sourceURL: URL, named name: String) -> URL? {
        let sanitized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !sanitized.isEmpty else { return nil }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(sanitized)
            .appendingPathExtension("csv")

        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            print("ControlPanelView: failed to prepare renamed export copy: \(error)")
            return nil
        }
    }
}
