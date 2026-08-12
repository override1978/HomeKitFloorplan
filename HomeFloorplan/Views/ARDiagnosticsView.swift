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
    var northBearingDegrees: Double = 0
    var savedCalibration: ARFloorCalibration?
    var applyARCalibration: ((ARFloorCalibration?) -> Void)?
    /// Persiste il nord PRECISO della pianta (gradi continui, non gli scatti
    /// da 45° del menù esposizione). Lo scrive «Set direction»: vedi là.
    var applyNorthBearing: ((Double) -> Void)?
    var commissioningMarkers: [ARDiagnosticsCommissioningMarker] = []
    var performCommissioningAction: ((UUID) -> Void)?
}

struct ARDiagnosticsCommissioningMarker: Identifiable {
    var id: UUID { accessoryUUID }
    var accessoryUUID: UUID
    var name: String
    var category: String
    var systemImage: String
    var point: CGPoint
    var roomID: UUID?
    var roomName: String?
    var isReachable: Bool
    var supportsQuickToggle: Bool
    var statusText: String?
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
    @State private var lockedRoomID: UUID?
    @State private var calibratedRoomID: UUID?
    @State private var calibrationOrigin: SIMD3<Float>?
    @State private var calibrationForwardXZ: SIMD2<Float>?
    @State private var calibrationMapOrigin: CGPoint?
    @State private var pendingCalibrationMapOrigin: CGPoint?
    @State private var pendingAlignmentMapPoint: CGPoint?
    @State private var calibratedPointsPerMeter: CGFloat?
    @State private var isCalibrationMirrored = false
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
                if calibratedRoomID == nil {
                    scanPanel
                        .padding(.bottom, 8)
                    if showsMiniFloorplan {
                        miniFloorplanPanel
                            .padding(.bottom, 8)
                    }
                }
                diagnosticsPanel
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    Spacer()
                    cameraStatusPill
                }
                if calibratedRoomID != nil, showsMiniFloorplan {
                    compactMapCard
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
            if pendingCalibrationMapOrigin == nil,
               let roomID = selectedCalibrationRoomID,
               let planRoom = snapshot.planRooms.first(where: { $0.id == roomID }) {
                pendingCalibrationMapOrigin = planRoom.anchor
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
                                pendingCalibrationMapOrigin = snapshot.planRooms.first { $0.id == room.id }?.anchor
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
                        pendingAlignmentMapPoint = nil
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

    private var selectedCalibrationPlanRoom: ARDiagnosticsPlanRoom? {
        guard let selectedCalibrationRoomID else { return nil }
        return snapshot.planRooms.first { $0.id == selectedCalibrationRoomID }
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

    private var lockedPlanRoom: ARDiagnosticsPlanRoom? {
        guard let lockedRoomID else { return nil }
        return snapshot.planRooms.first { $0.id == lockedRoomID }
    }

    private var activePlanRoom: ARDiagnosticsPlanRoom? {
        lockedPlanRoom ?? locatedPlanRoom
    }

    private var activeDiagnosticsRoom: ARDiagnosticsRoom? {
        if let lockedRoomID {
            return snapshot.rooms.first { $0.id == lockedRoomID }
                ?? lockedPlanRoom.flatMap { planRoom in
                    snapshot.rooms.first {
                        $0.name.localizedCaseInsensitiveCompare(planRoom.name) == .orderedSame
                    }
                }
        }
        return locatedDiagnosticsRoom ?? calibratedRoom
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
        if selectedCalibrationRoom != nil {
            return String(localized: "ar.locator.calibrate.detail",
                          defaultValue: "Tap your real position on the map, then set the floor origin.")
        }
        return String(localized: "ar.locator.noRooms",
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
        activePlanRoom?.name ?? activeDiagnosticsRoom?.name ?? snapshot.title
    }

    private var activeDiagnosticsSubtitle: String {
        if lockedRoomID != nil {
            return String(localized: "ar.diagnostics.locked.subtitle",
                          defaultValue: "Room diagnostics from confirmed AR room.")
        }
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
        !snapshot.planRooms.isEmpty
    }

    private var miniFloorplanPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(String(localized: "ar.plan.localMap", defaultValue: "Local map"),
                      systemImage: "map")
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)
            }

            ARDiagnosticsMiniFloorplanView(rooms: snapshot.planRooms,
                                           walls: snapshot.planWalls,
                                           markers: snapshot.commissioningMarkers,
                                           calibratedRoomID: calibratedRoomID,
                                           activeRoomID: activePlanRoom?.id ?? selectedCalibrationRoomID,
                                           originPoint: calibrationMapOrigin ?? pendingCalibrationMapOrigin,
                                           alignmentPoint: pendingAlignmentMapPoint,
                                           pointerPoint: planPointerPoint,
                                           cameraDirection: cameraPlanDirection,
                                           allowsOriginSelection: calibratedRoomID == nil,
                                           allowsAlignmentSelection: calibratedRoomID != nil,
                                           onOriginSelected: { point in
                                               pendingCalibrationMapOrigin = point
                                           },
                                           onAlignmentSelected: { point in
                                               pendingAlignmentMapPoint = point
                                           })
                .frame(height: 88)
        }
        .foregroundStyle(Color.primary)
        .padding(12)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    /// La mappa in punta di piedi: fissata l'origine, il fondo dello schermo
    /// è degli accessori e la pianta si ritira in alto a destra, solo disegno.
    /// La cerimonia manuale (direzione, punto B, specchio, reset) vive dietro
    /// i tre puntini: è il fallback per le case dove la bussola mente, non il
    /// flusso — e in un Menu i titoli non collassano più a una lettera per
    /// riga come facevano i bottoni in linea su iPhone.
    private var compactMapCard: some View {
        ARDiagnosticsMiniFloorplanView(rooms: snapshot.planRooms,
                                       walls: snapshot.planWalls,
                                       markers: snapshot.commissioningMarkers,
                                       calibratedRoomID: calibratedRoomID,
                                       activeRoomID: activePlanRoom?.id ?? selectedCalibrationRoomID,
                                       originPoint: calibrationMapOrigin ?? pendingCalibrationMapOrigin,
                                       alignmentPoint: pendingAlignmentMapPoint,
                                       pointerPoint: planPointerPoint,
                                       cameraDirection: cameraPlanDirection,
                                       allowsAlignmentSelection: true,
                                       onAlignmentSelected: { pendingAlignmentMapPoint = $0 },
                                       isCompact: true)
            .frame(width: 176, height: 124)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                compactMapMenu
                    .padding(5)
            }
    }

    private var compactMapMenu: some View {
        Menu {
            Section {
                Button {
                    lockedRoomID = nil
                } label: {
                    Label(String(localized: "ar.plan.room.auto",
                                 defaultValue: "Auto estimate"),
                          systemImage: "location.fill.viewfinder")
                }
                ForEach(snapshot.planRooms) { room in
                    Button {
                        lockedRoomID = room.id
                    } label: {
                        Label(room.name,
                              systemImage: lockedRoomID == room.id ? "checkmark.circle.fill" : "circle")
                    }
                }
            }

            Divider()

            Button {
                applyCurrentViewAsMapTop()
            } label: {
                Label(String(localized: "ar.plan.direction.set",
                             defaultValue: "Set direction"),
                      systemImage: "scope")
            }
            .disabled(arPose?.isNormal != true)

            Button {
                setSecondCalibrationPoint()
            } label: {
                Label(String(localized: "ar.plan.direction.pointB",
                             defaultValue: "Set point B"),
                      systemImage: "point.3.connected.trianglepath.dotted")
            }
            .disabled(pendingAlignmentMapPoint == nil || arPose?.isNormal != true)

            Button {
                isCalibrationMirrored.toggle()
            } label: {
                Label(String(localized: "ar.plan.mirror",
                             defaultValue: "Mirror map"),
                      systemImage: "arrow.left.arrow.right")
            }

            Divider()

            Button(role: .destructive) {
                resetFloorCalibration()
            } label: {
                Label(String(localized: "ar.locator.resetFloor",
                             defaultValue: "Reset floor"),
                      systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.primary)
                .frame(width: 26, height: 26)
                .background(.thinMaterial, in: Circle())
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
            x: origin.x + projectedOffset.x * activePointsPerMeter,
            y: origin.y + projectedOffset.y * activePointsPerMeter
        )
    }

    private var planRoomName: String {
        guard let point = planPointerPoint else {
            return String(localized: "ar.plan.waiting", defaultValue: "Waiting")
        }
        if let lockedPlanRoom {
            return lockedPlanRoom.name
        }
        if let room = snapshot.planRooms.first(where: { $0.contains(point) }) {
            return room.name
        }
        return String(localized: "ar.plan.outside", defaultValue: "Outside mapped rooms")
    }

    private var planRoomTint: Color {
        guard let calibratedRoomID, let point = planPointerPoint else { return .secondary }
        if lockedRoomID != nil { return .blue }
        if snapshot.planRooms.first(where: { $0.id == calibratedRoomID })?.contains(point) == true {
            return .green
        }
        if snapshot.planRooms.contains(where: { $0.contains(point) }) {
            return .orange
        }
        return .red
    }

    private var nearbyCommissioningMarkers: [CommissioningMarkerDistance] {
        guard let point = planPointerPoint else { return [] }
        let activeRoomID = activePlanRoom?.id
        let ranked = snapshot.commissioningMarkers.map { marker in
            CommissioningMarkerDistance(
                marker: marker,
                distance: distanceInMeters(from: point, to: marker.point),
                isInEstimatedRoom: marker.roomID == activeRoomID,
                targetScore: targetScore(for: marker.point, from: point)
            )
        }
        // Solo la stanza attiva: la distanza non rispetta i muri, e al
        // confine la lista pescava i dispositivi della stanza accanto. La
        // vista risponde a «cosa c'è QUI», non a «cosa c'è vicino».
        .filter(\.isInEstimatedRoom)
        let sorted = ranked
            .sorted { lhs, rhs in
                if lhs.isTargetCandidate != rhs.isTargetCandidate {
                    return lhs.isTargetCandidate && !rhs.isTargetCandidate
                }
                if let lhsScore = lhs.targetScore, let rhsScore = rhs.targetScore,
                   abs(lhsScore - rhsScore) > 0.001 {
                    return lhsScore > rhsScore
                }
                if lhs.isInEstimatedRoom != rhs.isInEstimatedRoom {
                    return lhs.isInEstimatedRoom && !rhs.isInEstimatedRoom
                }
                return lhs.distance < rhs.distance
            }

        if var target = sorted.first(where: { $0.isTargetCandidate }) {
            target.isTargeted = true
            let alternatives = sorted
                .filter { $0.id != target.id }
                .prefix(1)
            return [target] + alternatives
        }

        return sorted.prefix(2).map { $0 }
    }

    private func distanceInMeters(from lhs: CGPoint, to rhs: CGPoint) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return Double(sqrt(dx * dx + dy * dy) / max(activePointsPerMeter, 1))
    }

    private var activePointsPerMeter: CGFloat {
        calibratedPointsPerMeter ?? snapshot.pointsPerMeter
    }

    private var cameraPlanDirection: CGVector? {
        guard let arPose else { return nil }
        let projected = projectedPlanOffset(from: SIMD3<Float>(arPose.forwardXZ.x, 0, arPose.forwardXZ.y))
        let length = sqrt(projected.x * projected.x + projected.y * projected.y)
        guard length > 0.001 else { return nil }
        return CGVector(dx: projected.x / length, dy: projected.y / length)
    }

    private func targetScore(for markerPoint: CGPoint, from origin: CGPoint) -> Double? {
        guard let direction = cameraPlanDirection else { return nil }
        let dx = markerPoint.x - origin.x
        let dy = markerPoint.y - origin.y
        let distancePoints = sqrt(dx * dx + dy * dy)
        let distance = Double(distancePoints / max(snapshot.pointsPerMeter, 1))
        guard distance >= 0.15, distance <= 4.0 else { return nil }

        let targetX = dx / distancePoints
        let targetY = dy / distancePoints
        let dot = Double(targetX * direction.dx + targetY * direction.dy)
        guard dot >= 0.86 else { return nil }
        return dot - distance * 0.035
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
        let lateralSign: Float = isCalibrationMirrored ? -1 : 1
        let mapRight = SIMD2<Float>(-mapUp.y, mapUp.x) * lateralSign
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
        applyAutoHeadingDirection()
        let originPoint = pendingCalibrationMapOrigin ?? planRoom.anchor
        calibrationMapOrigin = originPoint
        calibratedPointsPerMeter = nil
        pendingAlignmentMapPoint = nil
        isCalibrationMirrored = false

        let now = Date()
        let calibration = ARFloorCalibration(
            originRoomID: roomID,
            originRoomName: planRoom.name,
            originPoint: originPoint,
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
        applyAutoHeadingDirection()
        calibrationMapOrigin = savedCalibration.originPoint
        pendingCalibrationMapOrigin = savedCalibration.originPoint
        calibratedPointsPerMeter = nil
        pendingAlignmentMapPoint = nil
        isCalibrationMirrored = false
    }

    private func applyAutoHeadingDirection() {
        calibrationForwardXZ = automaticMapForwardXZ()
    }

    /// «Set direction»: l'utente guarda il lato alto reale della pianta e
    /// tocca. Due effetti, non uno:
    ///
    /// 1. La sessione corrente si allinea ESATTA (il forward diventa il
    ///    map-up in assi di sessione — qui la bussola non c'entra più).
    /// 2. Con gli assi geografici (.gravityAndHeading) quel forward HA un
    ///    rilevamento vero: atan2(x, −z), 0 = nord. Lo si persiste come nord
    ///    preciso della pianta — 110° invece dello scatto a 135 del menù —
    ///    così TUTTE le sessioni future partono giuste in automatico.
    ///
    /// È la calibrazione fine una-tantum: l'errore da quantizzazione (fino a
    /// ±22°, che a 3 m sono già 1,2 m di scarto sui punti) muore qui; resta
    /// solo il rumore di bussola fra una sessione e l'altra (~±10°).
    private func applyCurrentViewAsMapTop() {
        guard let forwardXZ = arPose?.forwardXZ else { return }
        calibrationForwardXZ = forwardXZ

        let bearing = atan2(Double(forwardXZ.x), Double(-forwardXZ.y)) * 180 / .pi
        snapshot.applyNorthBearing?((bearing + 360)
            .truncatingRemainder(dividingBy: 360))
    }

    private func setSecondCalibrationPoint() {
        guard let calibrationOrigin,
              let calibrationMapOrigin,
              let pendingAlignmentMapPoint,
              let arPose
        else { return }

        let worldDelta = SIMD2<Float>(
            arPose.position.x - calibrationOrigin.x,
            arPose.position.z - calibrationOrigin.z
        )
        let worldDistance = simd_length(worldDelta)
        let mapDelta = CGPoint(
            x: pendingAlignmentMapPoint.x - calibrationMapOrigin.x,
            y: pendingAlignmentMapPoint.y - calibrationMapOrigin.y
        )
        let mapDistance = sqrt(mapDelta.x * mapDelta.x + mapDelta.y * mapDelta.y)
        guard worldDistance > 0.35, mapDistance > 6 else { return }

        let worldAngle = atan2(worldDelta.y, worldDelta.x)
        let mapAngle = atan2(Float(mapDelta.y), Float(mapDelta.x))
        let mapUpWorldAngle = worldAngle - mapAngle - Float.pi / 2
        calibrationForwardXZ = simd_normalize(SIMD2<Float>(
            cos(mapUpWorldAngle),
            sin(mapUpWorldAngle)
        ))
        calibratedPointsPerMeter = mapDistance / CGFloat(worldDistance)
        isCalibrationMirrored = false
        self.pendingAlignmentMapPoint = nil
    }

    private func automaticMapForwardXZ() -> SIMD2<Float> {
        let bearing = snapshot.northBearingDegrees * .pi / 180
        return simd_normalize(SIMD2<Float>(
            Float(sin(bearing)),
            Float(-cos(bearing))
        ))
    }

    private func resetFloorCalibration() {
        calibratedRoomID = nil
        calibrationOrigin = nil
        calibrationForwardXZ = nil
        calibrationMapOrigin = nil
        pendingCalibrationMapOrigin = selectedCalibrationPlanRoom?.anchor
        pendingAlignmentMapPoint = nil
        calibratedPointsPerMeter = nil
        isCalibrationMirrored = false
        lockedRoomID = nil
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
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(activeDiagnosticsTitle)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    Text(activeDiagnosticsSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: "viewfinder.circle.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(activeDiagnosticsMetrics.prefix(4)) { metric in
                        metricPill(metric)
                    }
                }
            }

            if calibratedRoomID != nil && !snapshot.commissioningMarkers.isEmpty {
                commissioningSection
            }
        }
        .foregroundStyle(Color.primary)
        .padding(14)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    private func metricPill(_ metric: ARDiagnosticsMetric) -> some View {
        HStack(spacing: 8) {
            Image(systemName: metric.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(metric.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(metric.value)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(metric.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 132, alignment: .leading)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }

    private var commissioningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(nearbyCommissioningMarkers.contains(where: \.isTargeted)
                      ? String(localized: "ar.commissioning.targetTitle", defaultValue: "Pointed device")
                      : String(localized: "ar.commissioning.title", defaultValue: "Commissioning"),
                      systemImage: nearbyCommissioningMarkers.contains(where: \.isTargeted)
                        ? "scope"
                        : "checklist.checked")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(activeDiagnosticsTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(planRoomTint)
                    .lineLimit(1)
            }

            if nearbyCommissioningMarkers.isEmpty {
                Text(String(localized: "ar.commissioning.noNearby",
                            defaultValue: "No mapped devices near this room."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(nearbyCommissioningMarkers) { item in
                        commissioningRow(item)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func commissioningRow(_ item: CommissioningMarkerDistance) -> some View {
        let marker = item.marker
        return HStack(spacing: 8) {
            Image(systemName: marker.systemImage)
                .font(.system(size: item.isTargeted ? 17 : 15, weight: .semibold))
                .foregroundStyle(commissioningTint(for: item))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(marker.name)
                    .font(item.isTargeted ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                    .lineLimit(1)
                Text(commissioningSubtitle(for: item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(String(format: "%.1f m", item.distance))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)

            if marker.supportsQuickToggle {
                Button {
                    snapshot.performCommissioningAction?(marker.accessoryUUID)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!marker.isReachable)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, item.isTargeted ? 8 : 6)
        .background(commissioningBackground(for: item), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func commissioningSubtitle(for item: CommissioningMarkerDistance) -> String {
        let marker = item.marker
        if !marker.isReachable {
            return String(localized: "ar.commissioning.missing",
                          defaultValue: "Missing from HomeKit")
        }
        if item.isTargeted {
            return marker.statusText.map {
                String(localized: "ar.commissioning.target.status",
                       defaultValue: "Pointed · \($0)")
            } ?? String(localized: "ar.commissioning.target",
                        defaultValue: "Pointed from camera")
        }
        if item.isInEstimatedRoom {
            return marker.statusText.map {
                String(localized: "ar.commissioning.inRoom.status",
                       defaultValue: "In this room · \($0)")
            } ?? String(localized: "ar.commissioning.inRoom",
                        defaultValue: "In this room")
        }
        if let roomName = marker.roomName {
            return String(localized: "ar.commissioning.mappedRoom",
                          defaultValue: "Mapped in \(roomName)")
        }
        return String(localized: "ar.commissioning.unassigned",
                      defaultValue: "Not inside a room")
    }

    private func commissioningTint(for item: CommissioningMarkerDistance) -> Color {
        if item.isTargeted { return .blue }
        if !item.marker.isReachable { return .red }
        if item.isInEstimatedRoom { return .green }
        if item.marker.roomID == nil { return .orange }
        return .blue
    }

    private func commissioningBackground(for item: CommissioningMarkerDistance) -> Color {
        item.isTargeted ? Color.blue.opacity(0.12) : Color.primary.opacity(0.055)
    }
}

private struct CommissioningMarkerDistance: Identifiable {
    var id: UUID { marker.accessoryUUID }
    var marker: ARDiagnosticsCommissioningMarker
    var distance: Double
    var isInEstimatedRoom: Bool
    var targetScore: Double?
    var isTargeted = false

    var isTargetCandidate: Bool {
        targetScore != nil
    }
}

private struct ARDiagnosticsMiniFloorplanView: View {
    var rooms: [ARDiagnosticsPlanRoom]
    var walls: [ARDiagnosticsPlanWall]
    var markers: [ARDiagnosticsCommissioningMarker]
    var calibratedRoomID: UUID?
    var activeRoomID: UUID?
    var originPoint: CGPoint?
    var alignmentPoint: CGPoint?
    var pointerPoint: CGPoint?
    var cameraDirection: CGVector?
    var allowsOriginSelection = false
    var allowsAlignmentSelection = false
    var onOriginSelected: ((CGPoint) -> Void)?
    var onAlignmentSelected: ((CGPoint) -> Void)?
    /// Nel riquadro in alto a destra i chip di aiuto non entrano: la mappa
    /// compatta mostra solo il disegno, le istruzioni restano al setup.
    var isCompact = false

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
                let isActive = room.id == activeRoomID
                context.fill(path, with: .color(isActive ? Color.blue.opacity(0.24) : (isCalibrated ? Color.green.opacity(0.20) : Color.white.opacity(0.22))))
                context.stroke(path,
                               with: .color(isActive ? Color.blue.opacity(0.85) : (isCalibrated ? Color.green.opacity(0.65) : Color.primary.opacity(0.18))),
                               lineWidth: isActive ? 2.4 : (isCalibrated ? 1.8 : 1))
            }

            for wall in walls {
                var path = Path()
                path.move(to: map(wall.start))
                path.addLine(to: map(wall.end))
                context.stroke(path, with: .color(Color.primary.opacity(0.34)), lineWidth: 2)
            }

            for marker in markers {
                let point = map(marker.point)
                let tint = marker.isReachable ? Color.primary.opacity(0.42) : Color.red.opacity(0.72)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 3,
                                                    y: point.y - 3,
                                                    width: 6,
                                                    height: 6)),
                             with: .color(tint))
            }

            if let originPoint {
                let point = map(originPoint)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 5,
                                                    y: point.y - 5,
                                                    width: 10,
                                                    height: 10)),
                             with: .color(Color.green.opacity(0.95)))
                context.stroke(Path(ellipseIn: CGRect(x: point.x - 13,
                                                      y: point.y - 13,
                                                      width: 26,
                                                      height: 26)),
                               with: .color(Color.green.opacity(0.55)),
                               lineWidth: 3)
            }

            if let alignmentPoint {
                let point = map(alignmentPoint)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 5,
                                                    y: point.y - 5,
                                                    width: 10,
                                                    height: 10)),
                             with: .color(Color.orange.opacity(0.95)))
                context.stroke(Path(ellipseIn: CGRect(x: point.x - 13,
                                                      y: point.y - 13,
                                                      width: 26,
                                                      height: 26)),
                               with: .color(Color.orange.opacity(0.60)),
                               lineWidth: 3)
            }

            if let pointerPoint {
                let mappedPointer = map(pointerPoint)
                let guideLength: CGFloat = 34
                let guideEnd = CGPoint(x: mappedPointer.x, y: mappedPointer.y - guideLength)
                var guidePath = Path()
                guidePath.move(to: mappedPointer)
                guidePath.addLine(to: guideEnd)
                context.stroke(guidePath,
                               with: .color(Color.green.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 2.5,
                                                  lineCap: .round,
                                                  dash: [5, 4]))
                context.stroke(Path(ellipseIn: CGRect(x: guideEnd.x - 9,
                                                      y: guideEnd.y - 9,
                                                      width: 18,
                                                      height: 18)),
                               with: .color(Color.green.opacity(0.85)),
                               lineWidth: 2.5)
                context.fill(Path(ellipseIn: CGRect(x: guideEnd.x - 3,
                                                    y: guideEnd.y - 3,
                                                    width: 6,
                                                    height: 6)),
                             with: .color(Color.green.opacity(0.85)))

                if let cameraDirection {
                    let length: CGFloat = 34
                    let end = CGPoint(x: mappedPointer.x + cameraDirection.dx * length,
                                      y: mappedPointer.y + cameraDirection.dy * length)
                    var directionPath = Path()
                    directionPath.move(to: mappedPointer)
                    directionPath.addLine(to: end)
                    context.stroke(directionPath,
                                   with: .color(Color.blue.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: 3, lineCap: .round))

                    let angle = atan2(cameraDirection.dy, cameraDirection.dx)
                    let wing: CGFloat = 8
                    let left = CGPoint(x: end.x - cos(angle - .pi / 6) * wing,
                                       y: end.y - sin(angle - .pi / 6) * wing)
                    let right = CGPoint(x: end.x - cos(angle + .pi / 6) * wing,
                                        y: end.y - sin(angle + .pi / 6) * wing)
                    var arrowHead = Path()
                    arrowHead.move(to: end)
                    arrowHead.addLine(to: left)
                    arrowHead.move(to: end)
                    arrowHead.addLine(to: right)
                    context.stroke(arrowHead,
                                   with: .color(Color.blue.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
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
        .overlay {
            if allowsOriginSelection || allowsAlignmentSelection {
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    guard let point = unmap(value.location, in: proxy.size) else { return }
                                    if allowsOriginSelection {
                                        onOriginSelected?(point)
                                    } else if allowsAlignmentSelection {
                                        onAlignmentSelected?(point)
                                    }
                                }
                        )
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if pointerPoint != nil, !isCompact {
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
        .overlay(alignment: .topLeading) {
            if isCompact {
            } else if allowsOriginSelection {
                Label(String(localized: "ar.plan.origin.target", defaultValue: "Tap position"),
                      systemImage: "mappin.circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
            } else if allowsAlignmentSelection {
                Label(String(localized: "ar.plan.alignment.target", defaultValue: "Tap point B"),
                      systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
            } else if pointerPoint != nil {
                Label(String(localized: "ar.plan.direction.target", defaultValue: "Aim target"),
                      systemImage: "scope")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
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

    private func unmap(_ location: CGPoint, in size: CGSize) -> CGPoint? {
        guard let bounds = drawingBounds, bounds.width > 1, bounds.height > 1 else { return nil }

        let inset: CGFloat = 10
        let available = CGSize(width: max(1, size.width - inset * 2),
                               height: max(1, size.height - inset * 2))
        let scale = min(available.width / bounds.width, available.height / bounds.height)
        guard scale > 0.001 else { return nil }

        let drawnSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let origin = CGPoint(x: (size.width - drawnSize.width) / 2,
                             y: (size.height - drawnSize.height) / 2)
        return CGPoint(x: bounds.minX + (location.x - origin.x) / scale,
                       y: bounds.minY + (location.y - origin.y) / scale)
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
        case .ready: return "checkmark.circle.fill"
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
        progress >= 0.85 ? "checkmark.circle.fill" : "viewfinder"
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
            configuration.worldAlignment = .gravityAndHeading
            // Niente planeDetection e niente environmentTexturing: qui serve
            // solo la posa 6DOF, che il tracking base fornisce da solo. Piani
            // su due assi e texture ambientali erano i due lavori più costosi
            // di GPU/Neural Engine della sessione — calore puro, mai letto da
            // nessuno (l'iPhone 17 Pro bollente dopo minuti di AR nasce qui).
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
            guard now - lastImageTime > 1.0 / 12.0 else { return }
            lastImageTime = now

            let pixelBuffer = frame.capturedImage
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            // Il frame arriva a piena risoluzione (~1920×1440) ma qui fa da
            // FONDALE dietro i pannelli, non da mirino: 1280 di lato lungo
            // bastano, e scalare PRIMA di createCGImage dimezza abbondante i
            // pixel copiati a ogni frame — era la seconda fonte di calore
            // della vista AR, dopo la configurazione della sessione.
            let sourceLong = max(image.extent.width, image.extent.height)
            let targetLong: CGFloat = 1280
            if sourceLong > targetLong {
                let factor = targetLong / sourceLong
                image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            }
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
