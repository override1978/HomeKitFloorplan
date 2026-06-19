import SwiftUI

/// Mini-preview live dei marker per la sezione Settings → Dimensione marker.
/// Mostra ogni stile e ogni stato di urgency, allineato visivamente
/// al rendering reale di `AccessoryMarkerView`.
struct MarkerPreviewView: View {
    let size: MarkerSize
    
    var body: some View {
        VStack(spacing: 18) {
            // Riga 1: controllable nei 4 stati principali
            HStack(spacing: 22) {
                mockupCell(label: String(localized: "marker.preview.off", defaultValue: "Off")) {
                    controllableMockup(state: .normal, icon: "lightbulb")
                }
                mockupCell(label: String(localized: "marker.preview.on", defaultValue: "On")) {
                    controllableMockup(state: .active, icon: "lightbulb.fill")
                }
                mockupCell(label: String(localized: "marker.preview.secured", defaultValue: "Secured")) {
                    controllableMockup(state: .ok, icon: "shield.fill")
                }
                mockupCell(label: String(localized: "marker.preview.open", defaultValue: "Open")) {
                    controllableMockup(state: .warning, icon: "lock.open.fill")
                }
                mockupCell(label: String(localized: "marker.preview.alarm", defaultValue: "Alarm")) {
                    controllableMockup(state: .alarm, icon: "exclamationmark.shield.fill")
                }
            }
            
            // Riga 2: sensor boolean + numeric
            HStack(spacing: 22) {
                mockupCell(label: String(localized: "marker.preview.numeric", defaultValue: "Numeric")) {
                    sensorNumericMockup()
                }
                mockupCell(label: String(localized: "marker.preview.sensor", defaultValue: "Sensor")) {
                    sensorBooleanMockup(triggered: false)
                }
                mockupCell(label: String(localized: "marker.preview.motion", defaultValue: "Motion")) {
                    sensorBooleanMockup(triggered: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
    
    // MARK: - Cell wrapper
    
    private func mockupCell<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 8) {
            content()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Mockups
    
    /// Stati di urgency mappati visivamente come in AccessoryMarkerView.
    private enum MockState {
        case normal, ok, active, warning, alarm
    }
    
    private func controllableMockup(state: MockState, icon: String) -> some View {
        ZStack {
            Circle()
                .fill(fillStyle(for: state))
                .frame(width: size.controllableDiameter, height: size.controllableDiameter)
            Image(systemName: icon)
                .foregroundStyle(iconColor(for: state))
                .font(size.iconFont)
        }
        .shadow(color: .black.opacity(state == .normal ? 0.12 : 0.22),
                radius: state == .normal ? 3 : 5,
                y: 1)
    }
    
    private func fillStyle(for state: MockState) -> AnyShapeStyle {
        switch state {
        case .normal:  return AnyShapeStyle(.thinMaterial)
        case .ok:      return AnyShapeStyle(Color.green.opacity(0.85))
        case .active:  return AnyShapeStyle(Color.yellow.opacity(0.85))
        case .warning: return AnyShapeStyle(Color.orange.opacity(0.85))
        case .alarm:   return AnyShapeStyle(Color.red.opacity(0.85))
        }
    }
    
    private func iconColor(for state: MockState) -> Color {
        state == .normal ? .primary : .white
    }
    
    /// Sensor boolean: stile invariato (bordo sottile, dimensione ridotta).
    private func sensorBooleanMockup(triggered: Bool) -> some View {
        ZStack {
            Circle()
                .fill(triggered ? AnyShapeStyle(Color.orange.opacity(0.85)) : AnyShapeStyle(.thinMaterial))
                .overlay(
                    Circle().stroke(triggered ? Color(.systemOrange) : Color.secondary.opacity(0.5),
                                    lineWidth: 1.5)
                )
                .frame(width: size.sensorBoolDiameter, height: size.sensorBoolDiameter)
            Image(systemName: triggered ? "figure.walk.motion" : "figure.stand")
                .foregroundStyle(triggered ? Color.white : Color.primary)
                .font(size.sensorBoolIconFont)
        }
        .shadow(radius: triggered ? 4 : 2)
    }
    
    /// Sensor numerico: pill con bordo sottile.
    private func sensorNumericMockup() -> some View {
        let pillSize = size.sensorNumericSize
        return ZStack {
            Capsule()
                .fill(.thinMaterial)
                .overlay(
                    Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
                )
                .frame(width: pillSize.width, height: pillSize.height)
            Text("21°")
                .foregroundStyle(.primary)
                .font(size.numericValueFont)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)
        }
        .shadow(radius: 2)
    }
}
