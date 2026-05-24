import SwiftUI
import HomeKit

struct AccessoryDetailView: View {
    let accessory: HMAccessory
    @Environment(HomeKitService.self) private var homeKit
    @State private var isObserving: Bool = false

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Stanza")
                    Spacer()
                    Text(accessory.room?.name ?? "—")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Raggiungibile")
                    Spacer()
                    Image(systemName: accessory.isReachable ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(accessory.isReachable ? .green : .red)
                }
            }

            ForEach(accessory.services, id: \.uniqueIdentifier) { service in
                Section(service.name) {
                    ForEach(service.characteristics, id: \.uniqueIdentifier) { ch in
                        characteristicRow(ch)
                    }
                }
            }
        }
        .navigationTitle(accessory.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !isObserving {
                homeKit.startObserving(accessoryUUIDs: [accessory.uniqueIdentifier])
                isObserving = true
            }
        }
        .onDisappear {
            if isObserving {
                homeKit.stopObserving(accessoryUUIDs: [accessory.uniqueIdentifier])
                isObserving = false
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func characteristicRow(_ ch: HMCharacteristic) -> some View {
        let value = homeKit.value(for: ch)
        let writePermitted = ch.properties.contains(HMCharacteristicPropertyWritable)
        let supportsReading = ch.properties.contains(HMCharacteristicPropertyReadable)

        switch ch.valueType {
        case .bool:
            Toggle(isOn: bindingBool(for: ch)) {
                Text(ch.localizedDescription)
            }
            .disabled(!writePermitted)
        case .int, .uint, .float, .double:
            if let minVal = ch.metadata?.minimumValue as? NSNumber,
               let maxVal = ch.metadata?.maximumValue as? NSNumber,
               let currentVal = numericValue(value) {
                HStack {
                    Text(ch.localizedDescription)
                    Spacer()
                    Slider(value: sliderBinding(for: ch, initial: currentVal, range: minVal.doubleValue...maxVal.doubleValue), in: minVal.doubleValue...maxVal.doubleValue)
                        .frame(width: 180)
                    Text("\(Int(currentVal))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                .disabled(!writePermitted)
            } else if let currentVal = numericValue(value) {
                Stepper(value: stepperBinding(for: ch, initial: currentVal), in: nil) {
                    HStack {
                        Text(ch.localizedDescription)
                        Spacer()
                        Text("\(Int(currentVal))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!writePermitted)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading) {
                        Text(ch.localizedDescription)
                        Text(ch.characteristicType)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formattedValue(value))
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    if supportsReading {
                        Button("Leggi ora") {
                            ch.readValue { _ in }
                        }
                    }
                }
            }
        case .string:
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text(ch.localizedDescription)
                    Text(ch.characteristicType)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(formattedValue(value))
                    .foregroundStyle(.secondary)
            }
            .contextMenu {
                if supportsReading {
                    Button("Leggi ora") {
                        ch.readValue { _ in }
                    }
                }
            }
        default:
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text(ch.localizedDescription)
                    Text(ch.characteristicType)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(formattedValue(value))
                    .foregroundStyle(.secondary)
            }
            .contextMenu {
                if supportsReading {
                    Button("Leggi ora") {
                        ch.readValue { _ in }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func bindingBool(for ch: HMCharacteristic) -> Binding<Bool> {
        Binding<Bool>(
            get: { (homeKit.value(for: ch) as? Bool) ?? false },
            set: { newValue in
                Task { try? await homeKit.write(newValue, to: ch) }
            }
        )
    }

    private func sliderBinding(for ch: HMCharacteristic, initial: Double, range: ClosedRange<Double>) -> Binding<Double> {
        Binding<Double>(
            get: { numericValue(homeKit.value(for: ch)) ?? initial },
            set: { newValue in
                let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                if ch.metadata?.format == .float || ch.metadata?.format == .double {
                    Task { try? await homeKit.write(clamped, to: ch) }
                } else {
                    Task { try? await homeKit.write(Int(clamped.rounded()), to: ch) }
                }
            }
        )
    }

    private func stepperBinding(for ch: HMCharacteristic, initial: Double) -> Binding<Int> {
        Binding<Int>(
            get: { (homeKit.value(for: ch) as? Int) ?? Int(initial) },
            set: { newValue in
                Task { try? await homeKit.write(newValue, to: ch) }
            }
        )
    }

    private func numericValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let f = any as? Float { return Double(f) }
        if let i = any as? Int { return Double(i) }
        if let u = any as? UInt { return Double(u) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private func formattedValue(_ any: Any?) -> String {
        switch any {
        case let b as Bool: return b ? "On" : "Off"
        case let i as Int: return "\(i)"
        case let d as Double: return String(format: "%.2f", d)
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case .none: return "—"
        default: return String(describing: any!)
        }
    }
}

#Preview {
    NavigationStack {
        Text("Seleziona un accessorio dalla lista")
    }
}
