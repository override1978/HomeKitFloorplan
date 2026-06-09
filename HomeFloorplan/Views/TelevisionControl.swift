import SwiftUI
import HomeKit

/// Controllo Apple-Home-style per televisori HomeKit.
/// Bottone tondo on/off + selezione ingresso (scroll orizzontale) + controlli volume/muto.
struct TelevisionControl: View {
    let adapter: TelevisionAdapter

    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides

    @State private var optimisticInputID: Int?
    @State private var optimisticMute: Bool?

    private let buttonDiameter: CGFloat = 80

    private var iconName: String {
        iconOverrides.effectiveIcon(for: adapter.accessory, adapter: adapter)
    }

    private var isOn: Bool { adapter.isOn }
    private var isReachable: Bool { !homeKit.isLikelyOffline(adapter.accessory) }
    private var isMuted: Bool { optimisticMute ?? adapter.isMuted }
    private var activeID: Int { optimisticInputID ?? adapter.activeIdentifier }

    var body: some View {
        VStack(spacing: 20) {
            toggleButton

            if !adapter.inputSources.isEmpty {
                inputSourceSection
            }

            if adapter.hasSpeaker {
                volumeSection
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .onChange(of: adapter.activeIdentifier) { _, _ in optimisticInputID = nil }
        .onChange(of: adapter.isMuted) { _, _ in optimisticMute = nil }
    }

    // MARK: - Toggle Button

    private var toggleButton: some View {
        VStack(spacing: 8) {
            Button(action: handleToggleTap) {
                ZStack {
                    Circle()
                        .fill(toggleFill)
                        .frame(width: buttonDiameter, height: buttonDiameter)

                    AccessoryIconView(iconName: iconName)
                        .foregroundStyle(toggleIconColor)
                        .frame(width: buttonDiameter * 0.45, height: buttonDiameter * 0.45)
                }
                .shadow(color: .black.opacity(isOn ? 0.22 : 0.12),
                        radius: isOn ? 6 : 3, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(!isReachable)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isOn)

            Text(stateLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var toggleFill: AnyShapeStyle {
        if !isReachable { return AnyShapeStyle(.thinMaterial) }
        return isOn ? AnyShapeStyle(Color.indigo.opacity(0.85)) : AnyShapeStyle(.thinMaterial)
    }

    private var toggleIconColor: Color {
        if !isReachable { return .secondary }
        return isOn ? .white : .primary
    }

    private var stateLabel: String {
        if !isReachable {
            return String(localized: "accessory.unreachable", defaultValue: "Non raggiungibile")
        }
        if !isOn {
            return String(localized: "accessory.state.off", defaultValue: "Spento")
        }
        if let source = adapter.inputSources.first(where: { $0.id == activeID }) {
            return source.name
        }
        return String(localized: "accessory.state.on", defaultValue: "Acceso")
    }

    // MARK: - Input Source Section

    private var inputSourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "cable.connector")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(String(localized: "television.input.label", defaultValue: "Ingresso"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(adapter.inputSources) { source in
                        inputSourcePill(source)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        }
        .opacity(isReachable && isOn ? 1.0 : 0.4)
        .disabled(!isReachable || !isOn)
    }

    private func inputSourcePill(_ source: TVInputSource) -> some View {
        let isSelected = source.id == activeID
        return Button {
            selectInput(source)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: source.symbolName)
                    .font(.caption.weight(.medium))
                Text(source.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? AnyShapeStyle(Color.indigo) : AnyShapeStyle(.thinMaterial))
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3), value: isSelected)
    }

    // MARK: - Volume Section

    private var volumeSection: some View {
        HStack(spacing: 12) {
            if adapter.supportsVolumeSelector {
                volumeStepButton(
                    symbol: "speaker.minus.fill",
                    label: String(localized: "television.volume.down", defaultValue: "Vol −")
                ) {
                    Task { try? await adapter.sendVolumeDown() }
                }
            }

            if adapter.supportsMute {
                muteButton
            }

            if adapter.supportsVolumeSelector {
                volumeStepButton(
                    symbol: "speaker.plus.fill",
                    label: String(localized: "television.volume.up", defaultValue: "Vol +")
                ) {
                    Task { try? await adapter.sendVolumeUp() }
                }
            }
        }
        .padding(.horizontal, 4)
        .opacity(isReachable && isOn ? 1.0 : 0.4)
        .disabled(!isReachable || !isOn)
    }

    private func volumeStepButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.thinMaterial))
        }
        .buttonStyle(.plain)
    }

    private var muteButton: some View {
        Button {
            let newMute = !isMuted
            optimisticMute = newMute
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task {
                do {
                    try await adapter.setMute(newMute)
                } catch {
                    optimisticMute = nil
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.title3)
                    .foregroundStyle(isMuted ? .red : .primary)
                Text(isMuted
                     ? String(localized: "television.mute.on",  defaultValue: "Muto")
                     : String(localized: "television.mute.off", defaultValue: "Audio"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isMuted ? AnyShapeStyle(Color.red.opacity(0.15)) : AnyShapeStyle(.thinMaterial))
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3), value: isMuted)
    }

    // MARK: - Actions

    private func handleToggleTap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { try? await adapter.setActive(!isOn) }
    }

    private func selectInput(_ source: TVInputSource) {
        guard source.id != activeID else { return }
        optimisticInputID = source.id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            do {
                try await adapter.setInputSource(source)
            } catch {
                optimisticInputID = nil
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
