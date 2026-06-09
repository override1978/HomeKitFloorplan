import SwiftUI
import HomeKit

struct CameraControlSection: View {

    let adapter: CameraAdapter

    @Environment(HomeKitService.self) private var homeKit
    @State private var streamState: HMCameraStreamState = .starting
    @State private var showFullscreen = false

    var body: some View {
        VStack(spacing: 16) {

            if adapter.supportsStream, let streamControl = adapter.cameraProfile?.streamControl {
                liveStreamCard(streamControl: streamControl)
            }

            if adapter.hasMotionSensor || adapter.hasOccupancySensor {
                sensorsCard
            }

            if adapter.hasNightVision || adapter.hasLedIndicator {
                controlsCard
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        // fullScreenCover senza CameraStreamView: mostra il cameraStream già avviato
        // tramite FullscreenCameraOverlay (read-only) — nessun stop/start aggiuntivo.
        .fullScreenCover(isPresented: $showFullscreen) {
            if let streamControl = adapter.cameraProfile?.streamControl {
                FullscreenCameraOverlay(
                    adapter: adapter,
                    streamControl: streamControl,
                    streamState: streamState
                )
            }
        }
    }

    // MARK: - Live stream card

    private func liveStreamCard(streamControl: HMCameraStreamControl) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "camera.card.live.title", defaultValue: "Live"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(streamState == .streaming ? Color.red : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(streamStateLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(streamState == .streaming ? .primary : .secondary)
                }
            }

            ZStack(alignment: .bottomTrailing) {
                Color.black
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // CameraStreamView sempre presente — mai smontato.
                // showFullscreen lo nasconde visivamente ma non lo distrugge,
                // così lo stream rimane attivo e il coordinator non cambia mai.
                CameraStreamView(streamControl: streamControl, streamState: $streamState)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .opacity(streamState == .streaming && !showFullscreen ? 1 : 0)

                if streamState == .starting && !showFullscreen {
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text(String(localized: "camera.stream.connecting", defaultValue: "Connecting…"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if (streamState == .stopping || streamState == .notStreaming) && !showFullscreen {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.5))
                        Text(String(localized: "camera.stream.stopped", defaultValue: "Stream ended"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Button {
                    showFullscreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var streamStateLabel: String {
        switch streamState {
        case .starting:     return String(localized: "camera.stream.state.starting",  defaultValue: "Starting…")
        case .streaming:    return String(localized: "camera.stream.state.live",       defaultValue: "LIVE")
        case .stopping:     return String(localized: "camera.stream.state.stopping",  defaultValue: "Stopping…")
        case .notStreaming: return String(localized: "camera.stream.state.stopped",   defaultValue: "Inactive")
        @unknown default:   return ""
        }
    }

    // MARK: - Sensors card

    private var sensorsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "camera.card.sensors.title", defaultValue: "Built-in Sensors"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if adapter.hasMotionSensor {
                sensorRow(
                    icon: adapter.motionDetected ? "figure.walk.motion" : "figure.stand",
                    label: String(localized: "camera.sensor.motion", defaultValue: "Motion"),
                    value: adapter.motionDetected
                        ? String(localized: "camera.sensor.detected", defaultValue: "Detected")
                        : String(localized: "camera.sensor.none", defaultValue: "None"),
                    active: adapter.motionDetected
                )
            }

            if adapter.hasOccupancySensor {
                sensorRow(
                    icon: adapter.occupancyDetected ? "person.fill" : "person",
                    label: String(localized: "camera.sensor.occupancy", defaultValue: "Occupancy"),
                    value: adapter.occupancyDetected
                        ? String(localized: "camera.sensor.detected", defaultValue: "Detected")
                        : String(localized: "camera.sensor.none", defaultValue: "None"),
                    active: adapter.occupancyDetected
                )
            }

            if !adapter.hasMotionSensor && !adapter.hasOccupancySensor {
                let isOffline = !homeKit.isReachable(adapter.accessory)
                sensorRow(
                    icon: isOffline ? "video.slash.fill" : "video.fill",
                    label: String(localized: "camera.sensor.status", defaultValue: "Status"),
                    value: isOffline
                        ? String(localized: "camera.status.offline", defaultValue: "Offline")
                        : String(localized: "camera.status.idle", defaultValue: "Online"),
                    active: false
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Controls card

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "camera.card.controls.title", defaultValue: "Controls"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if adapter.hasNightVision {
                    controlTile(
                        icon: adapter.nightVisionOn ? "moon.fill" : "moon",
                        label: String(localized: "camera.control.nightvision", defaultValue: "Night Vision"),
                        isOn: adapter.nightVisionOn,
                        tint: .indigo
                    ) {
                        Task { await adapter.setNightVision(!adapter.nightVisionOn) }
                    }
                }
                if adapter.hasLedIndicator {
                    controlTile(
                        icon: adapter.ledIndicatorOn ? "light.beacon.max.fill" : "light.beacon.max",
                        label: String(localized: "camera.control.led", defaultValue: "LED Indicator"),
                        isOn: adapter.ledIndicatorOn,
                        tint: .yellow
                    ) {
                        Task { await adapter.setLedIndicator(!adapter.ledIndicatorOn) }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func controlTile(icon: String, label: String, isOn: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isOn ? tint : Color.secondary)
                Text(label)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn ? tint.opacity(0.12) : Color(.tertiarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }

    private func sensorRow(icon: String, label: String, value: String, active: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(active ? Color.orange : Color.secondary)
                .frame(width: 22)
            Text(label)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(active ? Color.orange : Color.secondary)
        }
    }
}

// MARK: - FullscreenCameraOverlay

/// Vista fullscreen che mostra il cameraStream già avviato dall'inline CameraStreamView.
/// Non crea un nuovo stream — usa HMCameraView in modalità read-only assegnando
/// il cameraStream già attivo. Nessun stop/start, nessun delegate.
struct FullscreenCameraOverlay: View {

    let adapter: CameraAdapter
    let streamControl: HMCameraStreamControl
    let streamState: HMCameraStreamState

    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            FullscreenCameraView(streamControl: streamControl, streamState: streamState)
                .ignoresSafeArea()
                .opacity(streamState == .streaming ? 1 : 0)

            if streamState == .starting {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(String(localized: "camera.stream.connecting", defaultValue: "Connecting…"))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            // Header: nome + pulsante chiudi
            VStack(spacing: 0) {
                HStack {
                    Text(adapter.accessory.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.leading, 20)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                }
                .padding(.top, 56)
                .padding(.bottom, 12)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.55), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                )
                Spacer()

                // Footer: pulsanti controllo (solo se supportati dall'hardware)
                if adapter.hasNightVision || adapter.hasLedIndicator {
                    HStack(spacing: 20) {
                        if adapter.hasNightVision {
                            fullscreenControlButton(
                                icon: adapter.nightVisionOn ? "moon.fill" : "moon",
                                label: String(localized: "camera.control.nightvision.short", defaultValue: "Night"),
                                active: adapter.nightVisionOn
                            ) {
                                Task { await adapter.setNightVision(!adapter.nightVisionOn) }
                            }
                        }
                        if adapter.hasLedIndicator {
                            fullscreenControlButton(
                                icon: adapter.ledIndicatorOn ? "light.beacon.max.fill" : "light.beacon.max",
                                label: String(localized: "camera.control.led.short", defaultValue: "LED"),
                                active: adapter.ledIndicatorOn
                            ) {
                                Task { await adapter.setLedIndicator(!adapter.ledIndicatorOn) }
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 24)
                    .background(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.5)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea()
                    )
                }
            }
        }
        .offset(y: max(0, dragOffset))
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in dragOffset = value.translation.height }
                .onEnded { value in
                    if value.translation.height > 100 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                    }
                }
        )
        .animation(.interactiveSpring(), value: dragOffset)
    }

    private func fullscreenControlButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(active ? .white : .white.opacity(0.4))
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(active ? .white.opacity(0.9) : .white.opacity(0.4))
            }
            .frame(minWidth: 52)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Color.white.opacity(0.2) : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FullscreenCameraView

/// HMCameraView read-only che mostra il cameraStream già avviato dal CameraStreamView inline.
/// Non gestisce start/stop — si limita ad assegnare la sorgente già attiva.
struct FullscreenCameraView: UIViewRepresentable {

    let streamControl: HMCameraStreamControl
    let streamState: HMCameraStreamState

    func makeUIView(context: Context) -> HMCameraView {
        let view = HMCameraView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        if streamState == .streaming, let stream = streamControl.cameraStream {
            view.cameraSource = stream
        }
        return view
    }

    func updateUIView(_ uiView: HMCameraView, context: Context) {
        if streamState == .streaming, let stream = streamControl.cameraStream {
            uiView.cameraSource = stream
        }
    }
}
