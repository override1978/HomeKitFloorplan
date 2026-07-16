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
    let isExecuting: Bool
    let editIssue: AccessoryMarkerEditIssue?
    let label: String
    let hasCustomLabel: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(HomeKitService.self) private var homeKit

    @AppStorage(MarkerLabelVisibility.appStorageKey)
    private var markerLabelVisibilityRaw: String = MarkerLabelVisibility.smart.rawValue

    @State private var snapshotController = CameraSnapshotController()
    @State private var refreshTimer: Timer?
    @State private var wiggleAngle: Double = 0

    private static let refreshInterval: TimeInterval = 30

    init(adapter: CameraAdapter,
         size: CGSize,
         isEditing: Bool,
         isSelected: Bool,
         isExecuting: Bool,
         editIssue: AccessoryMarkerEditIssue? = nil,
         label: String,
         hasCustomLabel: Bool) {
        self.adapter = adapter
        self.size = size
        self.isEditing = isEditing
        self.isSelected = isSelected
        self.isExecuting = isExecuting
        self.editIssue = editIssue
        self.label = label
        self.hasCustomLabel = hasCustomLabel
    }

    private var isOffline: Bool {
        !homeKit.isReachable(adapter.accessory)
    }

    private var cornerRadius: CGFloat { size.height * 0.15 }

    private var labelVisibility: MarkerLabelVisibility {
        MarkerLabelVisibility(rawValue: markerLabelVisibilityRaw) ?? .smart
    }

    private var shouldShowLabel: Bool {
        switch labelVisibility {
        case .always:
            return true
        case .compact:
            return isEditing || isSelected || hasAttentionState
        case .smart:
            return isEditing
                || isSelected
                || hasCustomLabel
                || hasAttentionState
                || adapter.isOn
        }
    }

    private var hasAttentionState: Bool {
        isOffline
            || adapter.visualUrgency == .warning
            || adapter.visualUrgency == .alarm
            || editIssue != nil
    }

    private var hasStrongLabelState: Bool {
        isEditing || isSelected || hasAttentionState
    }

    private var hasHighContrastLabelState: Bool {
        hasStrongLabelState || adapter.isOn
    }

    private var labelProminence: Double {
        hasHighContrastLabelState ? 1.0 : 0.88
    }

    private var labelBackgroundOpacity: Double {
        hasHighContrastLabelState ? 0.88 : 0.76
    }

    private var labelFillGradient: LinearGradient {
        let colors: [Color] = colorScheme == .dark
            ? [
                Color.white.opacity(hasHighContrastLabelState ? 0.16 : 0.10),
                Color.white.opacity(hasHighContrastLabelState ? 0.06 : 0.04)
            ]
            : [
                Color.white.opacity(0.42),
                Color(red: 0.82, green: 0.84, blue: 0.87).opacity(0.28)
            ]
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var labelTextColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(hasHighContrastLabelState ? 0.92 : 0.84)
        }
        return Color.black.opacity(hasHighContrastLabelState ? 0.90 : 0.82)
    }

    var body: some View {
        VStack(spacing: 2) {
            thumbnailFrame
                .shadow(color: .black.opacity(isOffline ? 0.16 : 0.30),
                        radius: isOffline ? 6 : 10,
                        x: 0,
                        y: isOffline ? 2 : 4)
                .shadow(color: .white.opacity(isOffline ? 0.08 : 0.16),
                        radius: 1,
                        x: 0,
                        y: -1)
                .opacity(isOffline ? 0.6 : 1.0)

            if shouldShowLabel {
                labelPill
            }
        }
        .scaleEffect(isEditing ? 1.1 : 1.0)
        .rotationEffect(.degrees(wiggleAngle))
        .animation(.spring(response: 0.3), value: isEditing)
        .animation(.easeInOut(duration: 0.18), value: shouldShowLabel)
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

    private var labelPill: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .fontWeight(hasStrongLabelState ? .medium : .regular)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(labelTextColor)
        .background(.thinMaterial, in: Capsule())
        .background(
            Capsule()
                .fill(labelFillGradient)
                .opacity(hasHighContrastLabelState ? 0.18 : 0.10)
        )
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.16 : 0.42), lineWidth: 0.5)
        )
        .overlay(
            Capsule()
                .strokeBorder(.black.opacity(colorScheme == .dark ? 0.18 : (hasStrongLabelState ? 0.12 : 0.08)), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.16), radius: 2, x: 0, y: 1)
        .opacity(labelProminence)
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
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

            if isEditing, let editIssue {
                HStack {
                    Image(systemName: editIssue.systemImage)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(editIssue.color.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                    Spacer()
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }

            // Loading indicator while first snapshot is being fetched
            if snapshotController.isLoading && snapshotController.snapshot == nil {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.7)
            }

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.22), location: 0.0),
                            .init(color: .white.opacity(0.06), location: 0.38),
                            .init(color: .clear, location: 0.72)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size.width, height: size.height)
                .blendMode(.screen)
                .allowsHitTesting(false)

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
