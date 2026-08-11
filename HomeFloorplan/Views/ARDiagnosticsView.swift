import SwiftUI
import ARKit
import CoreMotion

/// Una lettura di posa dalla sessione ARKit: posizione della camera in metri
/// nel sistema della sessione (origine = dove è partito il tracking).
struct ARPoseSample: Equatable {
    var position: SIMD3<Float>
    var forwardXZ: SIMD2<Float>
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
    var planRooms: [ARDiagnosticsPlanRoom] = []
    var planWalls: [ARDiagnosticsPlanWall] = []
    var pointsPerMeter: CGFloat = DrawingDocument.ptsPerMeter
    var savedCalibration: ARFloorCalibration?
    var applyARCalibration: ((ARFloorCalibration?) -> Void)?
}

struct ARDiagnosticsPlanRoom: Identifiable {
    var id: UUID
    var name: String
    var points: [CGPoint]
    var anchor: CGPoint

    func contains(_ point: CGPoint) -> Bool {
        guard points.count >= 3 else { return false }
        var inside = false
        var previousIndex = points.count - 1
        for index in points.indices {
            let current = points[index]
            let previous = points[previousIndex]
            let crossesY = (current.y > point.y) != (previous.y > point.y)
            if crossesY {
                let xIntersection = (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x
                if point.x < xIntersection { inside.toggle() }
            }
            previousIndex = index
        }
        return inside
    }
}

struct ARDiagnosticsPlanWall: Identifiable {
    var id: UUID
    var start: CGPoint
    var end: CGPoint
}

struct ARDiagnosticsRoom: Identifiable {
    var id: UUID
    var name: String
    var subtitle: String
    var metrics: [ARDiagnosticsMetric]
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
    @State private var calibrationOrigin: SIMD3<Float>?
    @State private var calibrationForwardXZ: SIMD2<Float>?
    @State private var calibrationMapOrigin: CGPoint?
    @State private var savedCalibration: ARFloorCalibration?
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
                if showsMiniFloorplan {
                    miniFloorplanPanel
                        .padding(.bottom, 10)
                }
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
            savedCalibration = snapshot.savedCalibration
            if selectedCalibrationRoomID == nil {
                selectedCalibrationRoomID = savedCalibration?.originRoomID
                    ?? snapshot.suggestedRoomID
                    ?? snapshot.rooms.first?.id
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
                Text(String(localized: "ar.locator.originRoom",
                            defaultValue: "Origin room"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

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
                    Text(verbatim: arPoseLabel(arPose))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(verbatim: arPoseDistanceLabel(arPose))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }

            HStack(spacing: 10) {
                if calibratedRoomID == nil {
                    ProgressView(value: scanState.progress)
                        .tint(locatorTint)
                } else {
                    Label(String(localized: "ar.locator.originLocked",
                                 defaultValue: "Origin locked"),
                          systemImage: "mappin.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(locatorTint)
                }

                if calibratedRoomID == nil {
                    if savedCalibration != nil {
                        Button {
                            useSavedFloorOriginHere()
                        } label: {
                            Label(String(localized: "ar.locator.useSavedOrigin",
                                         defaultValue: "Use saved origin here"),
                                  systemImage: "location.viewfinder")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(arPose?.isNormal != true)
                    }

                    Button {
                        setFloorOriginHere()
                    } label: {
                        Label(String(localized: "ar.locator.setFloorOrigin",
                                     defaultValue: "Set floor origin"),
                              systemImage: "mappin.and.ellipse")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(selectedCalibrationRoomID == nil || arPose?.isNormal != true)
                } else {
                    Button {
                        resetFloorCalibration()
                    } label: {
                        Label(String(localized: "ar.locator.resetFloor",
                                     defaultValue: "Reset floor"),
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

    private var locatedPlanRoom: ARDiagnosticsPlanRoom? {
        guard calibratedRoomID != nil, let point = planPointerPoint else { return nil }
        return snapshot.planRooms.first { $0.contains(point) }
    }

    private var locatedDiagnosticsRoom: ARDiagnosticsRoom? {
        guard let locatedPlanRoom else { return nil }
        return snapshot.rooms.first { $0.id == locatedPlanRoom.id }
            ?? snapshot.rooms.first {
                $0.name.localizedCaseInsensitiveCompare(locatedPlanRoom.name) == .orderedSame
            }
    }

    private var activeDiagnosticsRoom: ARDiagnosticsRoom? {
        locatedDiagnosticsRoom ?? calibratedRoom
    }

    private var locatorTint: Color {
        guard calibratedRoomID != nil else { return scanState.tint }
        return arPose?.isNormal == true ? .green : .orange
    }

    private var locatorSystemImage: String {
        calibratedRoomID == nil ? "location.magnifyingglass" : "location.fill.viewfinder"
    }

    private var locatorTitle: String {
        if let locatedPlanRoom {
            return String(localized: "ar.locator.estimatedRoom",
                          defaultValue: "Estimated room: \(locatedPlanRoom.name)")
        }
        if let calibratedRoom {
            return String(localized: "ar.locator.floorOrigin",
                          defaultValue: "Floor origin: \(calibratedRoom.name)")
        }
        if let savedCalibration {
            return String(localized: "ar.locator.savedFloor",
                          defaultValue: "Saved floor origin: \(savedCalibration.originRoomName)")
        }
        return String(localized: "ar.locator.chooseOrigin",
                      defaultValue: "Set a floor origin")
    }

    private var locatorDetail: String {
        if locatedPlanRoom != nil {
            return String(localized: "ar.locator.estimated.detail",
                          defaultValue: "Room data follows the local AR position on the floorplan.")
        }
        if calibratedRoom != nil {
            return String(localized: "ar.locator.local.detail",
                          defaultValue: "One origin and alignment map the whole floor.")
        }
        if savedCalibration != nil {
            return String(localized: "ar.locator.saved.detail",
                          defaultValue: "Stand at the saved origin and reuse it for this AR session.")
        }
        return selectedCalibrationRoom.map {
            String(localized: "ar.locator.calibrate.detail",
                   defaultValue: "Stand in \($0.name), set the floor origin, then align the map once.")
        } ?? String(localized: "ar.locator.noRooms",
                    defaultValue: "No rooms are available for calibration.")
    }

    private var locatorValue: String {
        if calibratedRoomID != nil {
            guard let arPose else { return "--" }
            return String(format: "%.1f m", localDistance(from: arPose))
        }
        return arPose?.isNormal == true
            ? String(localized: "ar.locator.ready", defaultValue: "Ready")
            : String(localized: "ar.locator.waiting", defaultValue: "Waiting")
    }

    private var activeDiagnosticsTitle: String {
        locatedPlanRoom?.name ?? activeDiagnosticsRoom?.name ?? snapshot.title
    }

    private var activeDiagnosticsSubtitle: String {
        if locatedPlanRoom != nil {
            return String(localized: "ar.diagnostics.estimated.subtitle",
                          defaultValue: "Room diagnostics from calibrated AR map position.")
        }
        guard let activeDiagnosticsRoom else { return snapshot.subtitle }
        return activeDiagnosticsRoom.subtitle
    }

    private var activeDiagnosticsMetrics: [ARDiagnosticsMetric] {
        if let activeDiagnosticsRoom {
            if !activeDiagnosticsRoom.metrics.isEmpty { return activeDiagnosticsRoom.metrics }
            return [
                ARDiagnosticsMetric(title: String(localized: "ar.diagnostics.roomSensors",
                                                  defaultValue: "Room sensors"),
                                    value: String(localized: "common.none", defaultValue: "None"),
                                    systemImage: "sensor",
                                    tint: .secondary),
                ARDiagnosticsMetric(title: String(localized: "ar.diagnostics.localOrigin",
                                                  defaultValue: "Local origin"),
                                    value: arPose.map { String(format: "%.1f m", localDistance(from: $0)) } ?? "--",
                                    systemImage: "mappin.circle.fill",
                                    tint: locatorTint)
            ]
        }
        return snapshot.metrics
    }

    private var showsMiniFloorplan: Bool {
        calibratedRoomID != nil && !snapshot.planRooms.isEmpty
    }

    private var miniFloorplanPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(String(localized: "ar.plan.localMap", defaultValue: "Local map"),
                      systemImage: "map")
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                Text(planRoomName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(planRoomTint)
                    .lineLimit(1)

                Button {
                    calibrationForwardXZ = arPose?.forwardXZ
                } label: {
                    Label(String(localized: "ar.plan.align", defaultValue: "Align"),
                          systemImage: "location.north.line")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(arPose?.isNormal != true)
            }

            ARDiagnosticsMiniFloorplanView(rooms: snapshot.planRooms,
                                           walls: snapshot.planWalls,
                                           calibratedRoomID: calibratedRoomID,
                                           pointerPoint: planPointerPoint)
                .frame(height: 118)
        }
        .foregroundStyle(Color.primary)
        .padding(14)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    private var planPointerPoint: CGPoint? {
        guard let calibratedRoomID,
              let arPose,
              let calibratedPlanRoom = snapshot.planRooms.first(where: { $0.id == calibratedRoomID })
        else { return nil }

        let offset = localOffset(from: arPose)
        let projectedOffset = projectedPlanOffset(from: offset)
        let origin = calibrationMapOrigin ?? calibratedPlanRoom.anchor
        return CGPoint(
            x: origin.x + projectedOffset.x * snapshot.pointsPerMeter,
            y: origin.y + projectedOffset.y * snapshot.pointsPerMeter
        )
    }

    private var planRoomName: String {
        guard let point = planPointerPoint else {
            return String(localized: "ar.plan.waiting", defaultValue: "Waiting")
        }
        if let room = snapshot.planRooms.first(where: { $0.contains(point) }) {
            return room.name
        }
        return String(localized: "ar.plan.outside", defaultValue: "Outside mapped rooms")
    }

    private var planRoomTint: Color {
        guard let calibratedRoomID, let point = planPointerPoint else { return .secondary }
        if snapshot.planRooms.first(where: { $0.id == calibratedRoomID })?.contains(point) == true {
            return .green
        }
        if snapshot.planRooms.contains(where: { $0.contains(point) }) {
            return .orange
        }
        return .red
    }

    private func localDistance(from pose: ARPoseSample) -> Float {
        guard let calibrationOrigin else { return 0 }
        return simd_distance(pose.position, calibrationOrigin)
    }

    private func localOffset(from pose: ARPoseSample) -> SIMD3<Float> {
        guard let calibrationOrigin else { return .zero }
        return pose.position - calibrationOrigin
    }

    private func projectedPlanOffset(from offset: SIMD3<Float>) -> CGPoint {
        let worldOffset = SIMD2<Float>(offset.x, offset.z)
        guard let calibrationForwardXZ,
              simd_length(calibrationForwardXZ) > 0.001
        else {
            return CGPoint(x: CGFloat(offset.x), y: CGFloat(offset.z))
        }

        let mapUp = simd_normalize(calibrationForwardXZ)
        let mapRight = SIMD2<Float>(-mapUp.y, mapUp.x)
        return CGPoint(
            x: CGFloat(simd_dot(worldOffset, mapRight)),
            y: CGFloat(-simd_dot(worldOffset, mapUp))
        )
    }

    private func setFloorOriginHere() {
        guard let roomID = selectedCalibrationRoomID,
              let arPose,
              let planRoom = snapshot.planRooms.first(where: { $0.id == roomID })
        else { return }

        calibratedRoomID = roomID
        calibrationOrigin = arPose.position
        calibrationForwardXZ = arPose.forwardXZ
        calibrationMapOrigin = planRoom.anchor

        let now = Date()
        let calibration = ARFloorCalibration(
            originRoomID: roomID,
            originRoomName: planRoom.name,
            originPoint: planRoom.anchor,
            mapForward: CGPoint(x: 0, y: -1),
            createdAt: savedCalibration?.createdAt ?? now,
            updatedAt: now
        )
        savedCalibration = calibration
        snapshot.applyARCalibration?(calibration)
    }

    private func useSavedFloorOriginHere() {
        guard let savedCalibration, let arPose else { return }
        calibratedRoomID = savedCalibration.originRoomID
            ?? snapshot.planRooms.first {
                $0.name.localizedCaseInsensitiveCompare(savedCalibration.originRoomName) == .orderedSame
            }?.id
        selectedCalibrationRoomID = calibratedRoomID
        calibrationOrigin = arPose.position
        calibrationForwardXZ = arPose.forwardXZ
        calibrationMapOrigin = savedCalibration.originPoint
    }

    private func resetFloorCalibration() {
        calibratedRoomID = nil
        calibrationOrigin = nil
        calibrationForwardXZ = nil
        calibrationMapOrigin = nil
        savedCalibration = nil
        snapshot.applyARCalibration?(nil)
    }

    private func arPoseLabel(_ pose: ARPoseSample) -> String {
        guard calibratedRoomID != nil else {
            return "AR · \(pose.trackingLabel) · f\(pose.frameCount)"
        }
        return "AR local · \(pose.trackingLabel)"
    }

    private func arPoseDistanceLabel(_ pose: ARPoseSample) -> String {
        guard calibratedRoomID != nil else {
            return String(format: "x %+.1f  z %+.1f m", pose.position.x, pose.position.z)
        }
        let offset = localOffset(from: pose)
        return String(format: "%.1f m · x %+.1f z %+.1f",
                      localDistance(from: pose), offset.x, offset.z)
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(activeDiagnosticsTitle)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(activeDiagnosticsSubtitle)
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
                ForEach(activeDiagnosticsMetrics) { metric in
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

private struct ARDiagnosticsMiniFloorplanView: View {
    var rooms: [ARDiagnosticsPlanRoom]
    var walls: [ARDiagnosticsPlanWall]
    var calibratedRoomID: UUID?
    var pointerPoint: CGPoint?

    var body: some View {
        Canvas { context, size in
            guard let bounds = drawingBounds, bounds.width > 1, bounds.height > 1 else { return }

            let inset: CGFloat = 10
            let available = CGSize(width: max(1, size.width - inset * 2),
                                   height: max(1, size.height - inset * 2))
            let scale = min(available.width / bounds.width, available.height / bounds.height)
            let drawnSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let origin = CGPoint(x: (size.width - drawnSize.width) / 2,
                                 y: (size.height - drawnSize.height) / 2)

            func map(_ point: CGPoint) -> CGPoint {
                CGPoint(x: origin.x + (point.x - bounds.minX) * scale,
                        y: origin.y + (point.y - bounds.minY) * scale)
            }

            for room in rooms {
                guard let path = path(for: room.points, map: map) else { continue }
                let isCalibrated = room.id == calibratedRoomID
                context.fill(path, with: .color(isCalibrated ? Color.green.opacity(0.26) : Color.white.opacity(0.22)))
                context.stroke(path,
                               with: .color(isCalibrated ? Color.green.opacity(0.85) : Color.primary.opacity(0.18)),
                               lineWidth: isCalibrated ? 2.2 : 1)
            }

            for wall in walls {
                var path = Path()
                path.move(to: map(wall.start))
                path.addLine(to: map(wall.end))
                context.stroke(path, with: .color(Color.primary.opacity(0.34)), lineWidth: 2)
            }

            if let pointerPoint {
                let mappedPointer = map(pointerPoint)
                context.fill(Path(ellipseIn: CGRect(x: mappedPointer.x - 6,
                                                    y: mappedPointer.y - 6,
                                                    width: 12,
                                                    height: 12)),
                             with: .color(.blue))
                context.stroke(Path(ellipseIn: CGRect(x: mappedPointer.x - 12,
                                                      y: mappedPointer.y - 12,
                                                      width: 24,
                                                      height: 24)),
                               with: .color(Color.blue.opacity(0.45)),
                               lineWidth: 3)
            }
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if pointerPoint != nil {
                Label(String(localized: "ar.plan.pointer", defaultValue: "AR offset"),
                      systemImage: "location.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
            }
        }
    }

    private var drawingBounds: CGRect? {
        let roomPoints = rooms.flatMap(\.points)
        let wallPoints = walls.flatMap { [$0.start, $0.end] }
        let allPoints = roomPoints + wallPoints
        guard let first = allPoints.first else { return nil }

        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y

        for point in allPoints.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        return CGRect(x: minX,
                      y: minY,
                      width: max(1, maxX - minX),
                      height: max(1, maxY - minY))
            .insetBy(dx: -24, dy: -24)
    }

    private func path(for points: [CGPoint], map: (CGPoint) -> CGPoint) -> Path? {
        guard let first = points.first else { return nil }
        var path = Path()
        path.move(to: map(first))
        for point in points.dropFirst() {
            path.addLine(to: map(point))
        }
        path.closeSubpath()
        return path
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

    func makeUIView(context: Context) -> CameraFrameView {
        let view = CameraFrameView()
        context.coordinator.configure(on: view)
        return view
    }

    func updateUIView(_ uiView: CameraFrameView, context: Context) { }

    static func dismantleUIView(_ uiView: CameraFrameView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class CameraFrameView: UIView {
        let imageView = UIImageView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                imageView.topAnchor.constraint(equalTo: topAnchor),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        private var status: Binding<ARDiagnosticsCameraStatus>
        private let onPose: ((ARPoseSample) -> Void)?
        private let session = ARSession()
        private let ciContext = CIContext()
        private var lastReported = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        private var didReportReady = false
        private var frameCount = 0
        private var lastImageTime: CFAbsoluteTime = 0
        private weak var view: CameraFrameView?

        init(status: Binding<ARDiagnosticsCameraStatus>,
             onPose: ((ARPoseSample) -> Void)?) {
            self.status = status
            self.onPose = onPose
        }

        func configure(on view: CameraFrameView) {
            guard ARWorldTrackingConfiguration.isSupported else {
                update(.unavailable(String(
                    localized: "ar.status.unsupported.detail",
                    defaultValue: "This device does not support AR world tracking."
                )))
                return
            }
            self.view = view
            session.delegate = self

            let configuration = ARWorldTrackingConfiguration()
            configuration.planeDetection = [.horizontal, .vertical]
            configuration.environmentTexturing = .automatic
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            update(.starting)
        }

        func stop() {
            session.pause()
        }

        // MARK: ARSessionDelegate

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            frameCount += 1
            if !didReportReady {
                didReportReady = true
                update(.ready)
            }
            updateCameraImage(from: frame)
            let transform = frame.camera.transform
            let translation = transform.columns.3
            let position = SIMD3(translation.x, translation.y, translation.z)
            let forwardXZ = Self.forwardXZ(from: transform)
            // Si riporta oltre 3 cm di spostamento, o comunque ogni 60 frame:
            // il contatore deve avanzare a video anche da fermi.
            guard simd_distance(position, lastReported) > 0.03
                || frameCount % 60 == 0 else { return }
            lastReported = position
            let (label, isNormal) = Self.describe(frame.camera.trackingState)
            let count = frameCount
            DispatchQueue.main.async { [onPose, weak view] in
                onPose?(ARPoseSample(position: position,
                                     forwardXZ: forwardXZ,
                                     trackingLabel: label,
                                     isNormal: isNormal,
                                     frameCount: count,
                                     viewSize: view?.bounds.size ?? .zero))
            }
        }

        private func updateCameraImage(from frame: ARFrame) {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastImageTime > 1.0 / 15.0 else { return }
            lastImageTime = now

            let pixelBuffer = frame.capturedImage
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
            let orientation = Self.imageOrientationForCurrentDevice()
            let uiImage = UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
            DispatchQueue.main.async { [weak view] in
                view?.imageView.image = uiImage
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

        private static func forwardXZ(from transform: simd_float4x4) -> SIMD2<Float> {
            let cameraForward = SIMD2<Float>(-transform.columns.2.x, -transform.columns.2.z)
            let length = simd_length(cameraForward)
            guard length > 0.001 else { return SIMD2<Float>(0, -1) }
            return cameraForward / length
        }

        private static func imageOrientationForCurrentDevice() -> UIImage.Orientation {
            switch UIDevice.current.orientation {
            case .landscapeLeft: return .up
            case .landscapeRight: return .down
            case .portraitUpsideDown: return .left
            default: return .right
            }
        }

        private func update(_ kind: ARDiagnosticsCameraStatus.Kind) {
            DispatchQueue.main.async {
                self.status.wrappedValue = ARDiagnosticsCameraStatus(kind: kind)
            }
        }
    }
}
