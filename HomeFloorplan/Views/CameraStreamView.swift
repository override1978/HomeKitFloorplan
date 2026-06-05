import SwiftUI
import HomeKit

// MARK: - HMCameraSourceView

/// Wrapper SwiftUI generico attorno a HMCameraView.
///
/// Sia HMCameraSnapshot che HMCameraStream sono sottoclassi di HMCameraSource,
/// quindi questo wrapper funziona per snapshot statici e live stream.
/// Apple renderizza il contenuto in un processo di sistema separato —
/// l'app non può accedere o catturare i frame.
struct HMCameraSourceView: UIViewRepresentable {

    let source: HMCameraSource

    func makeUIView(context: Context) -> HMCameraView {
        let view = HMCameraView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.cameraSource = source
        return view
    }

    func updateUIView(_ uiView: HMCameraView, context: Context) {
        uiView.cameraSource = source
    }
}

// MARK: - CameraStreamView

/// Wrapper per il live stream: gestisce start/stop del flusso nel ciclo di vita della view.
/// `streamState` è un Binding aggiornato direttamente dal delegate ObjC,
/// perché HMCameraStreamControl.streamState non è osservabile da SwiftUI.
struct CameraStreamView: UIViewRepresentable {

    let streamControl: HMCameraStreamControl
    @Binding var streamState: HMCameraStreamState

    func makeCoordinator() -> Coordinator {
        Coordinator(streamState: $streamState)
    }

    func makeUIView(context: Context) -> HMCameraView {
        let view = HMCameraView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        // Disabilita interazione UIKit così i touch passano a SwiftUI (pulsanti overlay, gesture)
        view.isUserInteractionEnabled = false
        streamControl.delegate = context.coordinator
        context.coordinator.onStreamStarted = { [weak streamControl] in
            guard let stream = streamControl?.cameraStream else { return }
            view.cameraSource = stream
        }
        streamControl.startStream()
        return view
    }

    func updateUIView(_ uiView: HMCameraView, context: Context) {
        if streamControl.streamState == .streaming,
           let stream = streamControl.cameraStream {
            uiView.cameraSource = stream
        }
    }

    static func dismantleUIView(_ uiView: HMCameraView, coordinator: Coordinator) {
        // Stoppa lo stream solo se questo coordinator è ancora il delegate attivo.
        // Se SwiftUI ha già costruito un nuovo CameraStreamView (es. dopo chiusura fullscreen),
        // il suo makeUIView ha già riassegnato il delegate — non dobbiamo uccidere il nuovo stream.
        guard let sc = coordinator.streamControl,
              sc.delegate === coordinator else { return }
        sc.stopStream()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, HMCameraStreamControlDelegate {

        weak var streamControl: HMCameraStreamControl?
        var onStreamStarted: (() -> Void)?
        @Binding var streamState: HMCameraStreamState

        /// True solo dopo che questo coordinator ha ricevuto didStartStream.
        /// Impedisce che un didStopStreamWithError residuo (da un vecchio stream)
        /// sporchi lo stato prima che il nuovo stream sia effettivamente partito.
        private var hasStarted = false

        init(streamState: Binding<HMCameraStreamState>) {
            self._streamState = streamState
        }

        func cameraStreamControlDidStartStream(_ cameraStreamControl: HMCameraStreamControl) {
            self.streamControl = cameraStreamControl
            self.hasStarted = true
            DispatchQueue.main.async {
                self.streamState = .streaming
                self.onStreamStarted?()
            }
        }

        func cameraStreamControl(_ cameraStreamControl: HMCameraStreamControl,
                                 didStopStreamWithError error: (any Error)?) {
            // Ignora callback residui da stream precedenti che arrivano
            // dopo che un nuovo coordinator ha già preso il controllo.
            guard hasStarted else { return }
            // Verifica che lo stream sia effettivamente fermo anche lato HomeKit.
            // Se streamState è ancora .streaming significa che questo stop è
            // un callback tardivo di un ciclo precedente — lo ignoriamo.
            guard cameraStreamControl.streamState != .streaming else { return }
            DispatchQueue.main.async {
                self.streamState = .notStreaming
            }
        }
    }
}

// MARK: - CameraSnapshotController

/// Gestisce la richiesta di snapshot via HMCameraSnapshotControl (delegate-based).
///
/// HMCameraSnapshot è una HMCameraSource — non espone UIImage.
/// Il risultato viene mostrato tramite HMCameraSourceView.
@MainActor
@Observable
final class CameraSnapshotController: NSObject, HMCameraSnapshotControlDelegate {

    /// Snapshot più recente, pronto per essere mostrato in HMCameraSourceView.
    var snapshot: HMCameraSnapshot?
    var isLoading: Bool = false
    var error: String?

    func requestSnapshot(from control: HMCameraSnapshotControl) {
        control.delegate = self
        isLoading = true
        error = nil
        snapshot = nil
        control.takeSnapshot()
    }

    // MARK: - HMCameraSnapshotControlDelegate

    nonisolated func cameraSnapshotControl(_ cameraSnapshotControl: HMCameraSnapshotControl,
                                           didTake snapshot: HMCameraSnapshot?,
                                           error: (any Error)?) {
        let capturedSnapshot = snapshot
        let errorMessage = error?.localizedDescription
        Task { @MainActor in
            self.isLoading = false
            if let capturedSnapshot {
                self.snapshot = capturedSnapshot
                self.error = nil
            } else {
                self.error = errorMessage ?? String(
                    localized: "camera.snapshot.error.unknown",
                    defaultValue: "Snapshot non disponibile"
                )
            }
        }
    }

    nonisolated func cameraSnapshotControlDidUpdateMostRecentSnapshot(
        _ cameraSnapshotControl: HMCameraSnapshotControl
    ) {
        let latest = cameraSnapshotControl.mostRecentSnapshot
        Task { @MainActor in
            if let latest { self.snapshot = latest }
        }
    }
}
