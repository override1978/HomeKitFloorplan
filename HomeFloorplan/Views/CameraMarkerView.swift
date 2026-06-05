import SwiftUI
import HomeKit

// MARK: - CameraMarkerView

/// Marker rettangolare 16:9 per telecamere HomeKit sul floorplan.
///
/// Mostra una snapshot periodica (~30 s) via HMCameraSnapshotControl.
/// Quando la snapshot non è disponibile (hardware non supportato o offline)
/// cade su un placeholder scuro con icona videocamera.
///
/// Il tap non esegue alcun toggle ma apre AccessoryDetailView tramite il
/// meccanismo standard del FloorplanEditorView (supportsQuickToggle == false).
struct CameraMarkerView: View {

    let adapter: CameraAdapter
    let size: CGSize
    let isEditing: Bool
    let isSelected: Bool
    let label: String
    let hasCustomLabel: Bool

    @Environment(HomeKitService.self) private var homeKit

    @State private var snapshotController = CameraSnapshotController()
    @State private var refreshTimer: Timer?
    @State private var wiggleAngle: Double = 0

    private static let refreshInterval: TimeInterval = 30

    private var isOffline: Bool {
        !homeKit.isReachable(adapter.accessory)
    }

    private var cornerRadius: CGFloat { size.height * 0.15 }

    var body: some View {
        VStack(spacing: 2) {
            thumbnailFrame
                .shadow(color: .black.opacity(isOffline ? 0.12 : 0.22),
                        radius: 6, y: 2)
                .opacity(isOffline ? 0.6 : 1.0)

            // Label pill (mirrors AccessoryMarkerView)
            HStack(spacing: 3) {
                if hasCustomLabel {
                    Image(systemName: "pencil")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
        }
        .scaleEffect(isEditing ? 1.1 : 1.0)
        .rotationEffect(.degrees(wiggleAngle))
        .animation(.spring(response: 0.3), value: isEditing)
        .contentShape(Rectangle())
        .onChange(of: isSelected) { _, selected in
            if selected {
                wiggleAngle = -4
                withAnimation(
                    .easeInOut(duration: 0.13)
                    .repeatForever(autoreverses: true)
                ) { wiggleAngle = 4 }
            } else {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                    wiggleAngle = 0
                }
            }
        }
        .onChange(of: isEditing) { _, editing in
            if !editing {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                    wiggleAngle = 0
                }
            }
        }
        .onAppear { startSnapshotCycle() }
        .onDisappear { stopSnapshotCycle() }
    }

    // MARK: - Thumbnail frame

    private var thumbnailFrame: some View {
        ZStack {
            // Background: black (neutral for video content)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)

            // Snapshot image (when available)
            if let snapshot = snapshotController.snapshot, !isOffline {
                HMCameraSourceView(source: snapshot)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                // Placeholder: camera icon
                placeholder
            }

            // Status badge overlay (top-left): motion/occupancy indicator
            if adapter.motionDetected || adapter.occupancyDetected {
                HStack {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .padding(5)
                    Spacer()
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }

            // Offline badge (top-right)
            if isOffline {
                HStack {
                    Spacer()
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
                .frame(width: size.width, height: size.height, alignment: .topTrailing)
            }

            // Loading indicator while first snapshot is being fetched
            if snapshotController.isLoading && snapshotController.snapshot == nil {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.7)
            }

            // Border: selected (brand) or normal
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? BrandColor.primary.opacity(0.85)
                        : Color.white.opacity(0.25),
                    lineWidth: isSelected ? 2 : 0.75
                )
                .frame(width: size.width, height: size.height)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 4) {
            Image(systemName: isOffline ? "video.slash.fill" : "video.fill")
                .font(.system(size: size.height * 0.28, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: - Snapshot cycle

    private func startSnapshotCycle() {
        fetchSnapshot()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.refreshInterval,
            repeats: true
        ) { _ in
            fetchSnapshot()
        }
    }

    private func stopSnapshotCycle() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func fetchSnapshot() {
        guard let control = adapter.cameraProfile?.snapshotControl else { return }
        snapshotController.requestSnapshot(from: control)
    }
}
