import AVFoundation
import Combine
import CoreVideo
import Foundation
import QuartzCore

/// Drives the camera session, dispatches every frame to `InferenceManager`,
/// measures per-frame telemetry (latency, FPS, thermal state, memory), and
/// publishes it for SwiftUI while streaming it to `CSVLogger` when a stress
/// test is active.
///
/// Concurrency model: `AVCaptureVideoDataOutputSampleBufferDelegate` calls
/// land on `videoDataOutputQueue` (a serial background queue), where
/// inference also runs synchronously — keeping both off the main thread.
/// `@Published` properties are only ever mutated via `DispatchQueue.main`,
/// and the two values the capture callback must read (`selectedArchitecture`,
/// `isStressTesting`) are mirrored into lock-protected `ThreadSafeBox`es to
/// avoid touching main-thread-owned state from the background queue.
final class CameraManager: NSObject, ObservableObject {

    // MARK: - Published state (HUD / UI)

    @Published var detections: [Detection] = []
    @Published var currentFPS: Double = 0
    @Published var currentLatencyMs: Double = 0
    @Published var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published var memoryUsageMB: Double = 0
    @Published var loggedFileURL: URL?

    @Published var isStressTesting = false {
        didSet { stressTestBox.value = isStressTesting }
    }

    @Published var selectedArchitecture: PipelineArchitecture = .architectureB {
        didSet { architectureBox.value = selectedArchitecture }
    }

    // MARK: - AVFoundation

    let previewLayer = AVCaptureVideoPreviewLayer()

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.mcrolfey.ResnetYoloTester.session")
    private let videoDataOutputQueue = DispatchQueue(label: "com.mcrolfey.ResnetYoloTester.videoData", qos: .userInitiated)

    // MARK: - Inference / logging

    private let inferenceManager = InferenceManager()
    private let csvLogger = CSVLogger()
    private let architectureBox = ThreadSafeBox<PipelineArchitecture>(.architectureB)
    private let stressTestBox = ThreadSafeBox<Bool>(false)

    // MARK: - Frame bookkeeping (touched only from videoDataOutputQueue)

    private var frameID = 0
    private var lastFrameHostTime: CFTimeInterval?

    private var thermalObserver: NSObjectProtocol?

    override init() {
        super.init()
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.session = session
        inferenceManager.loadModelsIfNeeded()
        observeThermalState()
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    // MARK: - Session lifecycle

    func requestPermissionAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                self?.configureSession()
            }
        default:
            print("CameraManager: camera access not authorized.")
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            session.beginConfiguration()
            session.sessionPreset = .hd1280x720

            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }

            videoOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }

            session.commitConfiguration()

            if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if let previewConnection = previewLayer.connection, previewConnection.isVideoRotationAngleSupported(90) {
                previewConnection.videoRotationAngle = 90
            }

            session.startRunning()
        }
    }

    // MARK: - Stress test control

    func startStressTest() {
        videoDataOutputQueue.async { [weak self] in self?.frameID = 0 }
        Task {
            do {
                let url = try await csvLogger.startSession()
                await MainActor.run {
                    self.loggedFileURL = url
                    self.isStressTesting = true
                }
            } catch {
                print("CameraManager: failed to start CSV session: \(error)")
            }
        }
    }

    func stopStressTest() {
        Task {
            await csvLogger.stopSession()
            await MainActor.run { self.isStressTesting = false }
        }
    }

    // MARK: - Thermal observation

    private func observeThermalState() {
        thermalState = ProcessInfo.processInfo.thermalState
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.thermalState = ProcessInfo.processInfo.thermalState
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let architecture = architectureBox.value
        let startTime = DispatchTime.now()

        let frameDetections: [Detection]
        do {
            frameDetections = try inferenceManager.run(architecture: architecture, on: pixelBuffer)
        } catch {
            frameDetections = []
        }

        let endTime = DispatchTime.now()
        let latencyMs = Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000

        let hostTime = CACurrentMediaTime()
        let fps: Double
        if let last = lastFrameHostTime, hostTime > last {
            fps = 1.0 / (hostTime - last)
        } else {
            fps = 0
        }
        lastFrameHostTime = hostTime

        let memoryMB = SystemMetrics.currentMemoryUsageMB()
        let thermal = ProcessInfo.processInfo.thermalState

        frameID += 1
        let currentFrameID = frameID

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            detections = frameDetections
            currentFPS = fps
            currentLatencyMs = latencyMs
            memoryUsageMB = memoryMB
        }

        guard stressTestBox.value else { return }
        let metrics = FrameMetrics(
            timestamp: Date(),
            frameID: currentFrameID,
            architecture: architecture,
            detectionsCount: frameDetections.count,
            latencyMs: latencyMs,
            fps: fps,
            thermalState: thermal,
            memoryMB: memoryMB
        )
        Task { await csvLogger.log(metrics) }
    }
}
