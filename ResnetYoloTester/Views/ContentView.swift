import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()

    var body: some View {
        ZStack {
            CameraPreviewView(previewLayer: cameraManager.previewLayer)
                .ignoresSafeArea()

            BoundingBoxOverlay(detections: cameraManager.detections)
                .ignoresSafeArea()

            VStack {
                HStack {
                    HUDView(
                        architecture: cameraManager.selectedArchitecture,
                        fps: cameraManager.currentFPS,
                        latencyMs: cameraManager.currentLatencyMs,
                        thermalState: cameraManager.thermalState,
                        memoryMB: cameraManager.memoryUsageMB
                    )
                    Spacer()
                }
                .padding()

                Spacer()

                ControlPanelView(
                    selectedArchitecture: $cameraManager.selectedArchitecture,
                    isStressTesting: cameraManager.isStressTesting,
                    loggedFileURL: cameraManager.loggedFileURL,
                    onStart: cameraManager.startStressTest,
                    onStop: cameraManager.stopStressTest
                )
                .padding()
            }
        }
        .statusBarHidden()
        .onAppear { cameraManager.requestPermissionAndConfigure() }
        .onDisappear { cameraManager.stopSession() }
    }
}

#Preview {
    ContentView()
}
