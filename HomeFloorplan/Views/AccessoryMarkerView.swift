import SwiftUI
import HomeKit

struct AccessoryMarkerView: View {
    let accessory: HMAccessory?
    let isEditing: Bool
    let isOn: Bool
    let isToggleable: Bool
    let label: String
    let hasCustomLabel: Bool
    
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(fillStyle)
                    .overlay(Circle().stroke(strokeColor, lineWidth: 2))
                    .frame(width: 44, height: 44)
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 20, weight: .semibold))
            }
            .shadow(radius: isOn ? 6 : 2)
            
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
        .animation(.spring(response: 0.3), value: isEditing)
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .contentShape(Rectangle())
    }
    
    private var fillStyle: AnyShapeStyle {
        if accessory == nil { return AnyShapeStyle(.thinMaterial) }
        if isOn { return AnyShapeStyle(Color.yellow.opacity(0.85)) }
        return AnyShapeStyle(.thinMaterial)
    }
    
    private var strokeColor: Color {
        if accessory == nil { return .red }
        return isOn ? .orange : .accentColor
    }
    
    private var iconColor: Color {
        if accessory == nil { return .red }
        return isOn ? .white : .accentColor
    }
    
    private var iconName: String {
        guard let accessory else { return "questionmark.circle.fill" }
        switch accessory.category.categoryType {
        case HMAccessoryCategoryTypeLightbulb:
            return isOn ? "lightbulb.fill" : "lightbulb"
        case HMAccessoryCategoryTypeOutlet:
            return "powerplug.fill"
        case HMAccessoryCategoryTypeSwitch:
            return "switch.2"
        case HMAccessoryCategoryTypeThermostat:
            return "thermometer"
        case HMAccessoryCategoryTypeSensor:
            return "sensor.fill"
        case HMAccessoryCategoryTypeDoorLock:
            return isOn ? "lock.open.fill" : "lock.fill"
        case HMAccessoryCategoryTypeWindow,
             HMAccessoryCategoryTypeWindowCovering:
            return "blinds.horizontal.closed"
        case HMAccessoryCategoryTypeFan:
            return "fan.fill"
        case HMAccessoryCategoryTypeGarageDoorOpener:
            return "door.garage.closed"
        case HMAccessoryCategoryTypeIPCamera,
             HMAccessoryCategoryTypeVideoDoorbell:
            return "video.fill"
        default:
            return "circle.fill"
        }
    }
}
