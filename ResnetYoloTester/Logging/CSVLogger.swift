import Foundation

/// Thread-safe, append-only CSV logger.
///
/// Modeled as an `actor` so concurrent calls from the camera's inference
/// pipeline serialize automatically — no locks needed, and callers never
/// block the video-data-output queue since `log(_:)` is invoked via a
/// fire-and-forget `Task`.
///
/// Files are written to the app's Documents directory, so with
/// `UIFileSharingEnabled` set in Info.plist they can be pulled off the
/// device over Finder/USB or the Files app.
actor CSVLogger {
    enum CSVLoggerError: Error {
        case unableToOpenFile
    }

    private static let header = "Timestamp,Frame_ID,Architecture,Detections_Count,Latency_ms,FPS,Thermal_State,Memory_MB\n"

    private var fileHandle: FileHandle?
    private(set) var currentFileURL: URL?

    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Starts a new benchmark session: creates a fresh timestamped CSV file
    /// in Documents and writes the header row. Any previously open session
    /// is closed first.
    @discardableResult
    func startSession() throws -> URL {
        closeCurrentFile()

        let documentsURL = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let filename = "benchmark_\(Int(Date().timeIntervalSince1970)).csv"
        let fileURL = documentsURL.appendingPathComponent(filename)

        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw CSVLoggerError.unableToOpenFile
        }
        handle.write(Data(Self.header.utf8))

        fileHandle = handle
        currentFileURL = fileURL
        return fileURL
    }

    /// Closes the active session, if any. Safe to call even if no session is running.
    func stopSession() {
        closeCurrentFile()
    }

    /// Appends a single frame's metrics as one CSV row. No-ops if no session is active
    /// (i.e. "Start Stress Test" hasn't been pressed).
    func log(_ metrics: FrameMetrics) {
        guard let fileHandle else { return }

        let row = [
            timestampFormatter.string(from: metrics.timestamp),
            String(metrics.frameID),
            metrics.architecture.shortLabel,
            String(metrics.detectionsCount),
            String(format: "%.2f", metrics.latencyMs),
            String(format: "%.2f", metrics.fps),
            metrics.thermalState.label,
            String(format: "%.2f", metrics.memoryMB)
        ].joined(separator: ",")

        fileHandle.write(Data((row + "\n").utf8))
    }

    private func closeCurrentFile() {
        try? fileHandle?.close()
        fileHandle = nil
        currentFileURL = nil
    }
}
