import SwiftUI

struct ValveControl: View {
    let adapter: ValveAdapter

    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides

    @State private var writeError = false

    private var iconName: String {
        iconOverrides.effectiveIcon(for: adapter.accessory, adapter: adapter)
    }

    private var isReachable: Bool {
        !homeKit.isLikelyOffline(adapter.accessory)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                valveButton(
                    title: String(localized: "valve.action.close", defaultValue: "Close"),
                    icon: "xmark",
                    isActive: !adapter.isOn,
                    action: { setActive(false) }
                )

                valveButton(
                    title: String(localized: "valve.action.open", defaultValue: "Open"),
                    icon: iconName,
                    isActive: adapter.isOn,
                    action: { setActive(true) }
                )
            }

            VStack(spacing: 8) {
                statusRow(
                    title: String(localized: "valve.detail.type", defaultValue: "Type"),
                    value: adapter.valveType.localizedLabel
                )

                statusRow(
                    title: String(localized: "valve.detail.inUse", defaultValue: "In use"),
                    value: adapter.isInUse
                        ? String(localized: "common.yes", defaultValue: "Yes")
                        : String(localized: "common.no", defaultValue: "No")
                )

                if let remaining = adapter.remainingDurationSeconds {
                    statusRow(
                        title: String(localized: "valve.detail.remainingDuration", defaultValue: "Remaining"),
                        value: formattedDuration(remaining)
                    )
                }

                if let duration = adapter.setDurationSeconds {
                    statusRow(
                        title: String(localized: "valve.detail.setDuration", defaultValue: "Set duration"),
                        value: formattedDuration(duration)
                    )
                }
            }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if writeError { WriteErrorBanner() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func valveButton(title: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AccessoryIconView(iconName: icon)
                    .foregroundStyle(isActive && isReachable ? .white : .primary)
                    .frame(width: 24, height: 24)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isActive && isReachable ? .white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 82)
            .background(buttonFill(isActive: isActive), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isReachable || isActive)
        .opacity(isReachable ? 1 : 0.45)
    }

    private func buttonFill(isActive: Bool) -> AnyShapeStyle {
        guard isReachable else { return AnyShapeStyle(.thinMaterial) }
        return isActive ? AnyShapeStyle(Color.blue.opacity(0.9)) : AnyShapeStyle(.thinMaterial)
    }

    private func statusRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func setActive(_ active: Bool) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            do {
                try await adapter.setActive(active)
            } catch {
                triggerWriteError()
            }
        }
    }

    private func triggerWriteError() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.easeInOut(duration: 0.25)) { writeError = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeInOut(duration: 0.25)) { writeError = false }
        }
    }

    private func formattedDuration(_ seconds: Int) -> String {
        guard seconds > 0 else {
            return String(localized: "duration.none", defaultValue: "None")
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 {
            return String(format: String(localized: "duration.seconds", defaultValue: "%d sec"), seconds)
        }
        if remainder == 0 {
            return String(format: String(localized: "duration.minutes", defaultValue: "%d min"), minutes)
        }
        return String(format: String(localized: "duration.minutesSeconds", defaultValue: "%d min %d sec"), minutes, remainder)
    }
}
