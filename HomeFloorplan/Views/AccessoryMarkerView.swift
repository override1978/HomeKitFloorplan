import SwiftUI
import HomeKit

struct AccessoryMarkerView: View {
    let adapter: (any AccessoryAdapter)?
    let isEditing: Bool
    let isSelected: Bool
    let label: String
    let hasCustomLabel: Bool

    @AppStorage(MarkerSize.appStorageKey)
    private var markerSizeRaw: String = MarkerSize.regular.rawValue

    @Environment(IconOverrideStore.self) private var iconOverrides
    @Environment(HomeKitService.self) private var homeKit

    /// Angolo corrente del wiggle (cambia con animazione repeatForever).
    @State private var wiggleAngle: Double = 0
    
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
        urgency == .normal ? 0.18 : 0.30
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
    
    var body: some View {
        let _ = homeKit.characteristicValues
        VStack(spacing: 2) {
            shape
                .shadow(color: .black.opacity(shadowOpacity),
                        radius: urgency != .normal ? 5 : 3,
                        y: 1)
                .opacity(isLikelyOffline ? 0.6 : 1.0)

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
        .animation(.easeInOut(duration: 0.2), value: urgency)
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
        }
    }
    
    private var controllableShape: some View {
        ZStack {
            Circle()
                .fill(fillStyle)
                .overlay(controllableStrokeOverlay)
                .frame(width: size.controllableDiameter, height: size.controllableDiameter)
            
            AccessoryIconView(iconName: effectiveIconName)
                .foregroundStyle(iconColor)
                .frame(width: size.controllableDiameter * 0.5,
                       height: size.controllableDiameter * 0.5)
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
                .frame(width: size.sensorBoolDiameter, height: size.sensorBoolDiameter)
            
            AccessoryIconView(iconName: effectiveIconName)
                .foregroundStyle(iconColor)
                .frame(width: size.sensorBoolDiameter * 0.55,
                       height: size.sensorBoolDiameter * 0.55)
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
                .frame(width: pillSize.width, height: pillSize.height)
            
            Text(value)
                .foregroundStyle(iconColor)
                .font(size.numericValueFont)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)
        }
    }
    
    /// Bordo sottile per sensori (sempre presente, anche se discreto).
    /// Riprende il colore di stato quando c'è urgency, secondary quando neutro.
    private var sensorBorderColor: Color {
        if adapter == nil { return .red }
        let urgency = adapter?.visualUrgency ?? .normal
        switch urgency {
        case .normal:  return Color.secondary.opacity(0.5)
        case .ok:      return .green
        case .active:  return .yellow
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
}
