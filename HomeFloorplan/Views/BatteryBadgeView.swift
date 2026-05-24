import SwiftUI

/// Badge compatto per visualizzare lo stato batteria di un accessorio.
/// Mostra icona colorata + percentuale (se disponibile).
struct BatteryBadgeView: View {
    let info: BatteryInfo
    var compact: Bool = false
    
    var body: some View {
        HStack(spacing: compact ? 3 : 5) {
            Image(systemName: info.symbolName)
                .foregroundStyle(info.tintColor)
            
            Text(info.displayText)
                .foregroundStyle(info.tintColor)
                .monospacedDigit()
        }
        .font(compact ? .caption2.weight(.medium) : .subheadline.weight(.medium))
    }
}
