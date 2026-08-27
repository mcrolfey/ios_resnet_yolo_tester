import SwiftUI
import UniformTypeIdentifiers

/// Wraps `UIDocumentPickerViewController` in export mode so an already-on-disk
/// file can be copied to a user-chosen location in the Files app — iCloud
/// Drive, "On My iPhone", a specific folder, etc.
///
/// Used to let a stress test's CSV be explicitly saved somewhere once the run
/// stops, rather than relying on the app's Documents directory merely being
/// *browsable* from Files (via `UIFileSharingEnabled`).
struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL
    var onFinish: () -> Void = {}

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: true — this leaves the original file in Documents untouched,
        // so exporting is non-destructive and can be repeated.
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        // Bias the picker to open directly on local "On My iPhone" storage
        // (the file's own folder) instead of wherever it last defaulted to —
        // there's no public API to hide iCloud Drive as an option entirely,
        // but this avoids needing to navigate there manually.
        picker.directoryURL = url.deletingLastPathComponent()
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish()
        }
    }
}
