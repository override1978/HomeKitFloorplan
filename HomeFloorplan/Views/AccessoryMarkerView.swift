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
    let allowsCameraSnapshot: Bool

    @AppStorage(MarkerSize.appStorageKey)
    private var markerSizeRaw: String = MarkerSize.regular.rawValue

    @AppStorage(MarkerLabelVisibility.appStorageKey)
    private var markerLabelVisibilityRaw: String = MarkerLabelVisibility.smart.rawValue

    @Environment(\.colorScheme) private var colorScheme
    @Environment(IconOverrideStore.self) private var iconOverrides
    @Environment(HomeKitService.self) private var homeKit
    @Environment(MatterEnergyLiveStore.self) private var matterEnergy

    /// Angolo corrente del wiggle (cambia con animazione repeatForever).
    @State private var wiggleAngle: Double = 0
    @State private var runtimePulse: Bool = false

    init(adapter: (any AccessoryAdapter)?,
         isEditing: Bool,
         isSelected: Bool,
         isExecuting: Bool,
         editIssue: AccessoryMarkerEditIssue? = nil,
         label: String,
         hasCustomLabel: Bool,
         allowsCameraSnapshot: Bool = false) {
        self.adapter = adapter
        self.isEditing = isEditing
        self.isSelected = isSelected
        self.isExecuting = isExecuting
        self.editIssue = editIssue
        self.label = label
        self.hasCustomLabel = hasCustomLabel
        self.allowsCameraSnapshot = allowsCameraSnapshot
    }
    
    private var size: MarkerSize {
        MarkerSize(rawValue: markerSizeRaw) ?? .regular
    }

    private var labelVisibility: MarkerLabelVisibility {
        MarkerLabelVisibility(rawValue: markerLabelVisibilityRaw) ?? .smart
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

    private var energySnapshot: MatterEnergyDeviceSnapshot? {
        guard let adapter else { return nil }
        return matterEnergy.snapshot(for: adapter.accessory.uniqueIdentifier)
    }

    private var runtimeState: MarkerRuntimeState? {
        if isUnreachableButNotLikelyOffline {
            return .unreachable
        }

        return (adapter as? MarkerRuntimeStateProviding)?.markerRuntimeState
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
                || isActiveState
                || hasLiveMetric
        }
    }

    private var hasAttentionState: Bool {
        adapter == nil
            || isLikelyOffline
            || isUnreachableButNotLikelyOffline
            || runtimeState != nil
            || batteryInfo?.isLow == true
            || editIssue != nil
            || urgency == .warning
            || urgency == .alarm
    }

    private var isActiveState: Bool {
        guard let adapter else { return false }
        return adapter.isOn || urgency == .active || urgency == .ok
    }

    private var hasLiveMetric: Bool {
        style == .sensorNumeric || energySnapshot?.activePowerWatts != nil
    }

    private var hasStrongLabelState: Bool {
        isEditing || isSelected || hasAttentionState || hasLiveMetric
    }

    private var hasHighContrastLabelState: Bool {
        hasStrongLabelState || isActiveState
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

    private var isUnreachableButNotLikelyOffline: Bool {
        isOffline && !isLikelyOffline
    }
    
    var body: some View {
        let _ = homeKit.characteristicValues
        markerContent
    }

    @ViewBuilder
    private var markerContent: some View {
        // Telecamere: snapshot periodica solo quando il layer chiamante la abilita
        // (Security). Negli altri contesti restano marker leggeri.
        if allowsCameraSnapshot, style == .camera, let cameraAdapter = adapter as? CameraAdapter {
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

            if shouldShowLabel {
                labelPill
            }
        }
        .scaleEffect(isEditing ? 1.1 : 1.0)
        .rotationEffect(.degrees(wiggleAngle))
        .animation(.spring(response: 0.3), value: isEditing)
        .animation(.spring(response: 0.2), value: isExecuting)
        .animation(.easeInOut(duration: 0.2), value: urgency)
        .animation(.easeInOut(duration: 0.18), value: shouldShowLabel)
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
            controllableShape
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

        if !hasPriorityBadge,
           let energySnapshot,
           let activePowerWatts = energySnapshot.activePowerWatts {
            energyBadge(formattedMarkerWatts(activePowerWatts))
                .offset(energyBadgeTopTrailingOffset)
        }

        if let batteryInfo, batteryInfo.isLow {
            statusBadge(systemImage: batteryInfo.symbolName, color: batteryInfo.tintColor)
                .offset(badgeBottomTrailingOffset)
        }

        if isEditing, let editIssue {
            statusBadge(systemImage: editIssue.systemImage, color: editIssue.color)
                .offset(badgeTopLeadingOffset)
        }
    }

    private var hasPriorityBadge: Bool {
        adapter == nil || isLikelyOffline || runtimeState != nil
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

    private var energyBadgeTopTrailingOffset: CGSize {
        switch style {
        case .controllable:
            return CGSize(width: size.controllableDiameter * 0.47, height: -size.controllableDiameter * 0.32)
        case .sensorBoolean:
            return CGSize(width: size.sensorBoolDiameter * 0.49, height: -size.sensorBoolDiameter * 0.34)
        case .sensorNumeric:
            return CGSize(width: size.sensorNumericSize.width * 0.45, height: -size.sensorNumericSize.height * 0.4)
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

    private func energyBadge(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 7.5, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 3.5)
            .frame(height: 14)
            .background(Color(.systemGreen).opacity(0.94), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.88), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.8)
    }

    private func formattedMarkerWatts(_ watts: Double) -> String {
        if abs(watts) >= 100 {
            return "\(Int(watts.rounded()))W"
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return "\(formatter.string(from: NSNumber(value: watts)) ?? "\(watts)")W"
    }
    
    /// Bordo sottile per sensori (sempre presente, anche se discreto).
    /// Riprende il colore di stato quando c'è urgency, secondary quando neutro.
    private var sensorBorderColor: Color {
        if adapter == nil { return .red }
        let urgency = adapter?.visualUrgency ?? .normal
        switch urgency {
        case .normal:  return Color(red: 0.70, green: 0.73, blue: 0.76).opacity(0.5)
        case .ok:      return .green
        case .active:  return adapter?.markerTint ?? .yellow
        case .warning: return Color.orange
        case .alarm:   return .red
        }
    }
    
    // MARK: - Colori derivati da urgency + adapter null state
    
    private var appearance: AccessoryAppearance {
        AccessoryAppearance.from(adapter)
    }

    private var fillStyle: AnyShapeStyle {
        if adapter == nil { return AnyShapeStyle(Color(red: 0.72, green: 0.74, blue: 0.78).opacity(0.86)) }
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
