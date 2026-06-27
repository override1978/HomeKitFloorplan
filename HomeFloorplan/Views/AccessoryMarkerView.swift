import SwiftUI
import HomeKit

enum AccessoryMarkerEditIssue {
    case missingHomeKitAccessory
    case duplicateMarker
    case outsideLinkedRoom
    case roomLinkMismatch

    var systemImage: String {
        switch self {
        case .missingHomeKitAccessory:
            return "exclamationmark"
        case .duplicateMarker:
            return "square.on.square"
        case .outsideLinkedRoom:
            return "location.slash"
        case .roomLinkMismatch:
            return "link"
        }
    }

    var color: Color {
        switch self {
        case .missingHomeKitAccessory:
            return .red
        case .duplicateMarker, .outsideLinkedRoom, .roomLinkMismatch:
            return Color(.systemOrange)
        }
    }
}

struct AccessoryMarkerView: View {
    let adapter: (any AccessoryAdapter)?
    let isEditing: Bool
    let isSelected: Bool
    let isExecuting: Bool
    let editIssue: AccessoryMarkerEditIssue?
    let label: String
    let hasCustomLabel: Bool

    @AppStorage(MarkerSize.appStorageKey)
    private var markerSizeRaw: String = MarkerSize.regular.rawValue

    @Environment(IconOverrideStore.self) private var iconOverrides
    @Environment(HomeKitService.self) private var homeKit

    /// Angolo corrente del wiggle (cambia con animazione repeatForever).
    @State private var wiggleAngle: Double = 0
    @State private var runtimePulse: Bool = false

    init(adapter: (any AccessoryAdapter)?,
         isEditing: Bool,
         isSelected: Bool,
         isExecuting: Bool,
         editIssue: AccessoryMarkerEditIssue? = nil,
         label: String,
         hasCustomLabel: Bool) {
        self.adapter = adapter
        self.isEditing = isEditing
        self.isSelected = isSelected
        self.isExecuting = isExecuting
        self.editIssue = editIssue
        self.label = label
        self.hasCustomLabel = hasCustomLabel
    }
    
    private var size: MarkerSize {
        MarkerSize(rawValue: markerSizeRaw) ?? .regular
    }
    
    private var style: MarkerStyle {
        adapter?.markerStyle ?? .controllable
    }
    
    private var urgency: MarkerUrgency {
        adapter?.visualUrgency ?? .normal
    }
    
    /// Nome icona da renderizzare: override utente se presente, altrimenti adapter.
    private var effectiveIconName: String {
        guard let adapter else { return "questionmark.circle.fill" }
        return iconOverrides.effectiveIcon(for: adapter.accessory, adapter: adapter)
    }
    
    private var shadowOpacity: Double {
        urgency == .normal ? 0.24 : 0.36
    }
    
    /// True se l'accessorio dichiara di non essere raggiungibile.
    /// Distinto da "adapter == nil" che indica accessorio rimosso/sconosciuto.
    private var isOffline: Bool {
        guard let adapter else { return false }
        return !homeKit.isReachable(adapter.accessory)
    }
    
    private var isLikelyOffline: Bool {
        guard let adapter else { return false }
        return homeKit.isLikelyOffline(adapter.accessory)
    }

    private var batteryInfo: BatteryInfo? {
        adapter?.batteryInfo
    }

    private var runtimeState: MarkerRuntimeState? {
        if isUnreachableButNotLikelyOffline {
            return .unreachable
        }

        return (adapter as? MarkerRuntimeStateProviding)?.markerRuntimeState
    }

    private var isUnreachableButNotLikelyOffline: Bool {
        isOffline && !isLikelyOffline
    }
    
    var body: some View {
        let _ = homeKit.characteristicValues
        markerContent
    }

    @ViewBuilder
    private var markerContent: some View {
        // Telecamere: rettangolo con snapshot periodica — gestisce label e wiggle internamente.
        if style == .camera, let cameraAdapter = adapter as? CameraAdapter {
            CameraMarkerView(
                adapter: cameraAdapter,
                size: size.cameraMarkerSize,
                isEditing: isEditing,
                isSelected: isEditing && isSelected,
                isExecuting: isExecuting,
                editIssue: editIssue,
                label: label,
                hasCustomLabel: hasCustomLabel
            )
        } else {
            standardMarkerContent
        }
    }

    private var standardMarkerContent: some View {
        VStack(spacing: 2) {
            shape
                .shadow(color: .black.opacity(shadowOpacity),
                        radius: urgency != .normal ? 9 : 7,
                        x: 0,
                        y: urgency != .normal ? 4 : 3)
                .shadow(color: .white.opacity(0.18),
                        radius: 1,
                        x: 0,
                        y: -1)
                .opacity(isLikelyOffline ? 0.6 : 1.0)
                .scaleEffect(runtimeState == .sensorTriggered && runtimePulse ? 1.16 : 1.0)
                .animation(
                    runtimeState == .sensorTriggered
                        ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                        : .default,
                    value: runtimePulse
                )

            HStack(spacing: 3) {
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
        .animation(.spring(response: 0.2), value: isExecuting)
        .animation(.easeInOut(duration: 0.2), value: urgency)
        .onAppear {
            updateRuntimePulse()
        }
        .onChange(of: runtimeState?.systemImage) { _, _ in
            updateRuntimePulse()
        }
        .contentShape(Rectangle())
        .onChange(of: isSelected) { _, selected in
            if selected {
                // Avvia wiggle: oscilla da -4° a +4°
                wiggleAngle = -4
                withAnimation(
                    .easeInOut(duration: 0.13)
                    .repeatForever(autoreverses: true)
                ) {
                    wiggleAngle = 4
                }
            } else {
                // Ferma wiggle con spring verso 0
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
    }

    private func updateRuntimePulse() {
        guard runtimeState == .sensorTriggered || runtimeState == .transitioning else {
            runtimePulse = false
            return
        }

        runtimePulse = false
        let animation: Animation = runtimeState == .transitioning
            ? .linear(duration: 1.1).repeatForever(autoreverses: false)
            : .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
        withAnimation(animation) {
            runtimePulse = true
        }
    }
    
    // MARK: - Forma del marker (varia per style)

    @ViewBuilder
    private var shape: some View {
        switch style {
        case .controllable:
            controllableShape
        case .sensorBoolean:
            sensorBooleanShape
        case .sensorNumeric:
            sensorNumericShape
        case .camera:
            // CameraMarkerView si auto-gestisce (label, wiggle, snapshot cycle).
            // Viene reso direttamente nel body; qui non emittiamo nulla.
            EmptyView()
        }
    }
    
    private var controllableShape: some View {
        ZStack {
            Circle()
                .fill(fillStyle)
                .overlay(controllableStrokeOverlay)
                .overlay(markerDepthHighlight.clipShape(Circle()))
                .frame(width: size.controllableDiameter, height: size.controllableDiameter)
            
            if isExecuting {
                ProgressView()
                    .tint(iconColor)
                    .scaleEffect(0.7)
            } else if runtimeState == .transitioning {
                Image(systemName: MarkerRuntimeState.transitioning.systemImage)
                    .font(.system(size: size.controllableDiameter * 0.38, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .rotationEffect(.degrees(runtimePulse ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: runtimePulse)
            } else {
                AccessoryIconView(iconName: effectiveIconName)
                    .foregroundStyle(iconColor)
                    .frame(width: size.controllableDiameter * 0.5,
                           height: size.controllableDiameter * 0.5)
            }

            markerBadges
        }
    }

    /// Bordo rosso solo per stati anomali (adapter nil OR offline). Negli altri
    /// casi nessun bordo: il fill colorato fa già il suo lavoro.
    @ViewBuilder
    private var controllableStrokeOverlay: some View {
        if adapter == nil || isLikelyOffline {
            Circle().stroke(Color.red, lineWidth: 2)
        }
    }

    /// Bordo rosso solo quando l'adapter è nil (accessorio rimosso/errore).
    /// Negli altri casi nessun bordo: il fill colorato o il material
    /// sono già sufficienti a distinguere il marker.
    @ViewBuilder
    private var noAdapterStroke: some View {
        if adapter == nil {
            Circle().stroke(Color.red, lineWidth: 1.5)
        }
    }
    
    // Sensore booleano: cerchio piccolo discreto, diventa visibile in trigger
    private var sensorBooleanShape: some View {
        ZStack {
            Circle()
                .fill(fillStyle)
                .overlay(
                    Circle().stroke(sensorBorderColor, lineWidth: 1.5)
                )
                .overlay(markerDepthHighlight.clipShape(Circle()))
                .frame(width: size.sensorBoolDiameter, height: size.sensorBoolDiameter)
            
            AccessoryIconView(iconName: effectiveIconName)
                .foregroundStyle(iconColor)
                .frame(width: size.sensorBoolDiameter * 0.55,
                       height: size.sensorBoolDiameter * 0.55)

            markerBadges
        }
    }

    // Sensore numerico: pill larga con valore
    private var sensorNumericShape: some View {
        let value = adapter?.primaryStatusText ?? "—"
        let pillSize = size.sensorNumericSize
        
        return ZStack {
            Capsule()
                .fill(fillStyle)
                .overlay(
                    Capsule().stroke(sensorBorderColor, lineWidth: 1.5)
                )
                .overlay(markerDepthHighlight.clipShape(Capsule()))
                .frame(width: pillSize.width, height: pillSize.height)
            
            Text(value)
                .foregroundStyle(iconColor)
                .font(size.numericValueFont)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)

            markerBadges
        }
    }

    @ViewBuilder
    private var markerBadges: some View {
        let topTrailing = badgeTopTrailingOffset
        let bottomTrailing = badgeBottomTrailingOffset

        if adapter == nil {
            statusBadge(systemImage: "exclamationmark", color: .red)
                .offset(topTrailing)
        } else if isLikelyOffline {
            statusBadge(systemImage: "wifi.slash", color: .red)
                .offset(topTrailing)
        } else if runtimeState == .unreachable {
            statusBadge(systemImage: MarkerRuntimeState.unreachable.systemImage, color: MarkerRuntimeState.unreachable.tint)
                .offset(topTrailing)
        } else if let runtimeState {
            statusBadge(systemImage: runtimeState.systemImage, color: runtimeState.tint)
                .offset(topTrailing)
        }

        if let batteryInfo, batteryInfo.isLow {
            statusBadge(systemImage: batteryInfo.symbolName, color: batteryInfo.tintColor)
                .offset(bottomTrailing)
        }

        if isEditing, let editIssue {
            statusBadge(systemImage: editIssue.systemImage, color: editIssue.color)
                .offset(badgeTopLeadingOffset)
        }
    }

    private var badgeTopTrailingOffset: CGSize {
        switch style {
        case .controllable:
            return CGSize(width: size.controllableDiameter * 0.33, height: -size.controllableDiameter * 0.33)
        case .sensorBoolean:
            return CGSize(width: size.sensorBoolDiameter * 0.34, height: -size.sensorBoolDiameter * 0.34)
        case .sensorNumeric:
            return CGSize(width: size.sensorNumericSize.width * 0.42, height: -size.sensorNumericSize.height * 0.42)
        case .camera:
            return .zero
        }
    }

    private var badgeTopLeadingOffset: CGSize {
        switch style {
        case .controllable:
            return CGSize(width: -size.controllableDiameter * 0.33, height: -size.controllableDiameter * 0.33)
        case .sensorBoolean:
            return CGSize(width: -size.sensorBoolDiameter * 0.34, height: -size.sensorBoolDiameter * 0.34)
        case .sensorNumeric:
            return CGSize(width: -size.sensorNumericSize.width * 0.42, height: -size.sensorNumericSize.height * 0.42)
        case .camera:
            return .zero
        }
    }

    private var badgeBottomTrailingOffset: CGSize {
        switch style {
        case .controllable:
            return CGSize(width: size.controllableDiameter * 0.34, height: size.controllableDiameter * 0.34)
        case .sensorBoolean:
            return CGSize(width: size.sensorBoolDiameter * 0.34, height: size.sensorBoolDiameter * 0.34)
        case .sensorNumeric:
            return CGSize(width: size.sensorNumericSize.width * 0.42, height: size.sensorNumericSize.height * 0.42)
        case .camera:
            return .zero
        }
    }

    private func statusBadge(systemImage: String, color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(color, in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
    
    /// Bordo sottile per sensori (sempre presente, anche se discreto).
    /// Riprende il colore di stato quando c'è urgency, secondary quando neutro.
    private var sensorBorderColor: Color {
        if adapter == nil { return .red }
        let urgency = adapter?.visualUrgency ?? .normal
        switch urgency {
        case .normal:  return Color.secondary.opacity(0.5)
        case .ok:      return .green
        case .active:  return adapter?.markerTint ?? .yellow
        case .warning: return Color(.systemOrange)
        case .alarm:   return .red
        }
    }
    
    // MARK: - Colori derivati da urgency + adapter null state
    
    private var appearance: AccessoryAppearance {
        AccessoryAppearance.from(adapter)
    }

    private var fillStyle: AnyShapeStyle {
        if adapter == nil { return AnyShapeStyle(.thinMaterial) }
        return appearance.markerFill
    }

    private var iconColor: Color {
        if adapter == nil { return .red }
        return appearance.markerIconColor
    }

    private var markerDepthHighlight: some View {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(urgency == .normal ? 0.24 : 0.34), location: 0.0),
                .init(color: .white.opacity(urgency == .normal ? 0.08 : 0.12), location: 0.34),
                .init(color: .clear, location: 0.58),
                .init(color: .black.opacity(urgency == .normal ? 0.06 : 0.13), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}
