import SwiftUI
import ARKit
import RealityKit
import CoreMotion

/// Una lettura di posa dalla sessione ARKit: posizione della camera in metri
/// nel sistema della sessione (origine = dove è partito il tracking).
struct ARPoseSample: Equatable {
    var position: SIMD3<Float>
    var trackingLabel: String
    var isNormal: Bool
    /// Strumentazione per il feed nero: quanti frame ARKit ha consegnato e
    /// quanto è grande davvero la vista che dovrebbe disegnarli.
    var frameCount: Int = 0
    var viewSize: CGSize = .zero
}

struct ARDiagnosticsSnapshot: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String
    var metrics: [ARDiagnosticsMetric]
    var rooms: [ARDiagnosticsRoom] = []
    var suggestedRoomID: UUID?
}

struct ARDiagnosticsRoom: Identifiable, Hashable {
    var id: UUID
    var name: String
}

struct ARDiagnosticsMetric: Identifiable {
    let id = UUID()
    var title: String
    var value: String
    var systemImage: String
    var tint: Color
}

struct ARDiagnosticsView: View {
    let snapshot: ARDiagnosticsSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var cameraStatus = ARDiagnosticsCameraStatus.starting
    @State private var scanState = ARDiagnosticsScanState()
    @State private var motionTracker = DiagnosticsMotionTracker()
    @State private var selectedCalibrationRoomID: UUID?
    @State private var calibratedRoomID: UUID?
    @State private var arPose: ARPoseSample?

    var body: some View {
        ZStack {
            fallbackBackground

            DiagnosticsCameraPreview(status: $cameraStatus,
                                     onPose: { arPose = $0 })
                .ignoresSafeArea()
                .opacity(cameraStatus.showsCameraFeed ? 1 : 0)

            Color.black.opacity(0.08)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            reticle

            if cameraStatus.showsFallbackMessage {
                cameraFallbackMessage
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                scanPanel
                    .padding(.bottom, 10)
                diagnosticsPanel
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            VStack {
                HStack {
                    Spacer()
                    cameraStatusPill
                }
                Spacer()
            }
            .padding(.top, 18)
            .padding(.trailing, 18)
        }
        .statusBarHidden()
        .onAppear {
            if selectedCalibrationRoomID == nil {
                selectedCalibrationRoomID = snapshot.suggestedRoomID ?? snapshot.rooms.first?.id
            }
            motionTracker.start { state in
                scanState = state
            }
        }
        .onDisappear {
            motionTracker.stop()
        }
    }

    private var fallbackBackground: some View {
        LinearGradient(colors: [
            Color(red: 0.08, green: 0.10, blue: 0.12),
            Color(red: 0.16, green: 0.19, blue: 0.22),
            Color(red: 0.07, green: 0.08, blue: 0.10)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .frame(width: 46, height: 46)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "ar.diagnostics.title", defaultValue: "AR Diagnostics"))
                    .font(.headline.weight(.semibold))
                Text(snapshot.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .background(.thinMaterial, in: Capsule())

            Spacer(minLength: 0)
        }
    }

    private var cameraStatusPill: some View {
        Label(cameraStatus.title, systemImage: cameraStatus.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(.thinMaterial, in: Capsule())
    }

    private var cameraFallbackMessage: some View {
        VStack(spacing: 8) {
            Image(systemName: cameraStatus.systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(cameraStatus.tint)
            Text(cameraStatus.title)
                .font(.headline.weight(.semibold))
            Text(cameraStatus.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Color.primary)
        .padding(18)
        .frame(maxWidth: 390)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .offset(y: -70)
    }

    private var reticle: some View {
        ZStack {
            Circle()
                .strokeBorder(scanState.tint.opacity(0.85), lineWidth: 2)
                .frame(width: 58, height: 58)
            Circle()
                .trim(from: 0, to: scanState.progress)
                .stroke(scanState.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 74, height: 74)
                .rotationEffect(.degrees(-90))
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 5, height: 5)
            Rectangle()
                .fill(Color.white.opacity(0.65))
                .frame(width: 20, height: 1)
            Rectangle()
                .fill(Color.white.opacity(0.65))
                .frame(width: 1, height: 20)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .allowsHitTesting(false)
    }

    private var scanPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: locatorSystemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(locatorTint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(locatorTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(locatorDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(locatorValue)
                    .font(.headline.monospacedDigit().weight(.bold))
                    .foregroundStyle(locatorTint)
            }

            if calibratedRoomID == nil, !snapshot.rooms.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(snapshot.rooms) { room in
                            Button {
                                selectedCalibrationRoomID = room.id
                            } label: {
                                Text(room.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(selectedCalibrationRoomID == room.id ? Color.white : Color.primary)
                                    .padding(.horizontal, 12)
                                    .frame(height: 32)
                                    .background(selectedCalibrationRoomID == room.id ? Color.blue : Color.primary.opacity(0.08),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let arPose {
                HStack(spacing: 8) {
                    Image(systemName: arPose.isNormal ? "move.3d" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(arPose.isNormal ? Color.green : Color.orange)
                    Text(verbatim: "AR · \(arPose.trackingLabel) · f\(arPose.frameCount) · \(Int(arPose.viewSize.width))×\(Int(arPose.viewSize.height))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(verbatim: String(format: "x %+.1f  z %+.1f m",
                                          arPose.position.x, arPose.position.z))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }

            HStack(spacing: 10) {
                ProgressView(value: calibratedRoomID == nil ? scanState.progress : locatorConfidence)
                    .tint(locatorTint)

                if calibratedRoomID == nil {
                    Button {
                        calibratedRoomID = selectedCalibrationRoomID
                    } label: {
                        Label(String(localized: "ar.locator.calibrate",
                                     defaultValue: "Calibrate here"),
                              systemImage: "mappin.and.ellipse")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(selectedCalibrationRoomID == nil)
                } else {
                    Button {
                        calibratedRoomID = nil
                    } label: {
                        Label(String(localized: "ar.locator.reset",
                                     defaultValue: "Reset"),
                              systemImage: "arrow.counterclockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    private var selectedCalibrationRoom: ARDiagnosticsRoom? {
        snapshot.rooms.first { $0.id == selectedCalibrationRoomID }
    }

    private var calibratedRoom: ARDiagnosticsRoom? {
        snapshot.rooms.first { $0.id == calibratedRoomID }
    }

    private var locatorConfidence: Double {
        guard calibratedRoomID != nil else { return 0 }
        return min(0.92, 0.56 + scanState.progress * 0.32)
    }

    private var locatorTint: Color {
        calibratedRoomID == nil ? scanState.tint : .green
    }

    private var locatorSystemImage: String {
        calibratedRoomID == nil ? "location.magnifyingglass" : "location.fill.viewfinder"
    }

    private var locatorTitle: String {
        if let calibratedRoom {
            return String(localized: "ar.locator.calibratedRoom",
                          defaultValue: "Calibrated room: \(calibratedRoom.name)")
        }
        return String(localized: "ar.locator.chooseRoom",
                      defaultValue: "Choose the room you are in")
    }

    private var locatorDetail: String {
        if calibratedRoom != nil {
            return String(localized: "ar.locator.local.detail",
                          defaultValue: "Room data is tied to your explicit calibration, not automatic recognition.")
        }
        return selectedCalibrationRoom.map {
            String(localized: "ar.locator.calibrate.detail",
                   defaultValue: "Point inside \($0.name), then tap Calibrate here.")
        } ?? String(localized: "ar.locator.noRooms",
                    defaultValue: "No rooms are available for calibration.")
    }

    private var locatorValue: String {
        if calibratedRoomID != nil {
            return "\(Int(locatorConfidence * 100))%"
        }
        return "\(Int(scanState.progress * 100))%"
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(snapshot.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: "viewfinder.circle.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(snapshot.metrics) { metric in
                    metricTile(metric)
                }
            }
        }
        .foregroundStyle(Color.primary)
        .padding(18)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    private func metricTile(_ metric: ARDiagnosticsMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: metric.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(metric.tint)
            Text(metric.value)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(metric.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ARDiagnosticsCameraStatus: Equatable {
    enum Kind: Equatable {
        case starting
        case ready
        case denied
        case unavailable(String)
    }

    var kind: Kind

    static let starting = ARDiagnosticsCameraStatus(kind: .starting)

    var title: String {
        switch kind {
        case .starting:
            return String(localized: "camera.status.starting", defaultValue: "Starting camera")
        case .ready:
            return String(localized: "camera.status.ready", defaultValue: "Camera active")
        case .denied:
            return String(localized: "camera.status.denied", defaultValue: "Camera permission needed")
        case .unavailable:
            return String(localized: "ar.status.unavailable", defaultValue: "Camera unavailable")
        }
    }

    var detail: String {
        switch kind {
        case .starting:
            return String(localized: "camera.status.starting.detail",
                          defaultValue: "Preparing the live camera preview.")
        case .ready:
            return String(localized: "camera.status.ready.detail",
                          defaultValue: "Move the device around the room and keep diagnostics visible.")
        case .denied:
            return String(localized: "camera.status.denied.detail",
                          defaultValue: "Enable camera access in Settings to use live diagnostics.")
        case .unavailable(let reason):
            return reason
        }
    }

    var systemImage: String {
        switch kind {
        case .starting: return "camera.viewfinder"
        case .ready: return "checkmark.viewfinder"
        case .denied: return "lock.slash"
        case .unavailable: return "video.slash"
        }
    }

    var tint: Color {
        switch kind {
        case .ready: return .green
        case .starting: return .blue
        case .denied, .unavailable: return .red
        }
    }

    var showsCameraFeed: Bool {
        if case .ready = kind { return true }
        return false
    }

    var showsFallbackMessage: Bool {
        switch kind {
        case .ready: return false
        case .starting, .denied, .unavailable: return true
        }
    }
}

private struct ARDiagnosticsScanState: Equatable {
    var coveredSectors: Set<Int> = []
    var yawDegrees: Double = 0
    var pitchDegrees: Double = 0
    var motionLevel: Double = 0

    var progress: Double {
        min(1, Double(coveredSectors.count) / 10)
    }

    var tint: Color {
        switch progress {
        case 0.85...1: return .green
        case 0.35..<0.85: return .blue
        default: return .orange
        }
    }

    var systemImage: String {
        progress >= 0.85 ? "checkmark.viewfinder" : "viewfinder"
    }

    var title: String {
        if progress >= 0.85 {
            return String(localized: "ar.scan.good.title", defaultValue: "Room scan good")
        }
        if motionLevel < 0.01 {
            return String(localized: "ar.scan.waiting.title", defaultValue: "Move to scan")
        }
        return String(localized: "ar.scan.active.title", defaultValue: "Scanning room")
    }

    var detail: String {
        if progress >= 0.85 {
            return String(localized: "ar.scan.good.detail",
                          defaultValue: "Coverage is enough for a first diagnostic pass.")
        }
        if abs(pitchDegrees) > 55 {
            return String(localized: "ar.scan.level.detail",
                          defaultValue: "Lower the device slightly and pan across the room.")
        }
        return String(localized: "ar.scan.pan.detail",
                      defaultValue: "Pan slowly left and right to increase coverage.")
    }

    mutating func record(yaw: Double, pitch: Double, rotation: CMRotationRate) {
        yawDegrees = yaw * 180 / .pi
        pitchDegrees = pitch * 180 / .pi
        motionLevel = abs(rotation.x) + abs(rotation.y) + abs(rotation.z)

        let normalizedYaw = yaw >= 0 ? yaw : yaw + .pi * 2
        let sector = Int((normalizedYaw / (.pi * 2)) * 12).clamped(to: 0...11)
        coveredSectors.insert(sector)
    }
}

private final class DiagnosticsMotionTracker {
    private let motionManager = CMMotionManager()
    private var state = ARDiagnosticsScanState()

    func start(onUpdate: @escaping (ARDiagnosticsScanState) -> Void) {
        guard motionManager.isDeviceMotionAvailable else {
            onUpdate(state)
            return
        }

        motionManager.deviceMotionUpdateInterval = 0.12
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.state.record(yaw: motion.attitude.yaw,
                              pitch: motion.attitude.pitch,
                              rotation: motion.rotationRate)
            onUpdate(self.state)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private struct DiagnosticsCameraPreview: UIViewRepresentable {
    @Binding var status: ARDiagnosticsCameraStatus
    var onPose: ((ARPoseSample) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(status: $status, onPose: onPose)
    }

    func makeUIView(context: Context) -> ARView {
        // ARView in modalità **AR vera** (non il .nonAR della 3D): il feed
        // camera arriva da ARKit insieme alla posa 6DOF — è il salto da
        // «mostrare il mondo» a «sapere dove sei nel mondo».
        //
        // ⚠️ Sessione AUTO-configurata: col run() manuale dentro makeUIView
        // la sessione partiva prima che la vista entrasse nel render loop —
        // tracking vivo, feed nero («si ferma così»). Lasciandola all'ARView,
        // parte quando la vista è in finestra e i pixel arrivano.
        let view = ARView(frame: .zero, cameraMode: .ar,
                          automaticallyConfigureSession: true)
        context.coordinator.configure(on: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) { }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        private var status: Binding<ARDiagnosticsCameraStatus>
        private let onPose: ((ARPoseSample) -> Void)?
        private weak var session: ARSession?
        private var lastReported = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        private var didReportReady = false
        private var frameCount = 0
        private weak var view: ARView?

        init(status: Binding<ARDiagnosticsCameraStatus>,
             onPose: ((ARPoseSample) -> Void)?) {
            self.status = status
            self.onPose = onPose
        }

        func configure(on view: ARView) {
            guard ARWorldTrackingConfiguration.isSupported else {
                update(.unavailable(String(
                    localized: "ar.status.unsupported.detail",
                    defaultValue: "This device does not support AR world tracking."
                )))
                return
            }
            // Niente run() manuale: la configurazione world-tracking la avvia
            // l'ARView stessa quando entra in finestra. Qui solo osservazione.
            view.session.delegate = self
            session = view.session
            self.view = view
            update(.starting)
        }

        func stop() {
            session?.pause()
        }

        // MARK: ARSessionDelegate

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            frameCount += 1
            if !didReportReady {
                didReportReady = true
                update(.ready)
            }
            let translation = frame.camera.transform.columns.3
            let position = SIMD3(translation.x, translation.y, translation.z)
            // Si riporta oltre 3 cm di spostamento, o comunque ogni 60 frame:
            // il contatore deve avanzare a video anche da fermi.
            guard simd_distance(position, lastReported) > 0.03
                || frameCount % 60 == 0 else { return }
            lastReported = position
            let (label, isNormal) = Self.describe(frame.camera.trackingState)
            let count = frameCount
            DispatchQueue.main.async { [onPose, weak view] in
                onPose?(ARPoseSample(position: position,
                                     trackingLabel: label,
                                     isNormal: isNormal,
                                     frameCount: count,
                                     viewSize: view?.bounds.size ?? .zero))
            }
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            let nsError = error as NSError
            if nsError.domain == ARError.errorDomain,
               nsError.code == ARError.Code.cameraUnauthorized.rawValue {
                update(.denied)
            } else {
                update(.unavailable(error.localizedDescription))
            }
        }

        private static func describe(_ state: ARCamera.TrackingState) -> (String, Bool) {
            switch state {
            case .normal:                          return ("normal", true)
            case .notAvailable:                    return ("not available", false)
            case .limited(.initializing):          return ("initializing", false)
            case .limited(.excessiveMotion):       return ("excessive motion", false)
            case .limited(.insufficientFeatures):  return ("low features", false)
            case .limited(.relocalizing):          return ("relocalizing", false)
            case .limited:                         return ("limited", false)
            }
        }

        private func update(_ kind: ARDiagnosticsCameraStatus.Kind) {
            DispatchQueue.main.async {
                self.status.wrappedValue = ARDiagnosticsCameraStatus(kind: kind)
            }
        }
    }
}
