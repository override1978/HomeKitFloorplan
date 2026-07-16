import SwiftUI

struct FloorplanSmartLightingStatusPill: View {
    let status: SmartLightingFloorplanStatus
    let onPause: () -> Void
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon(status.state))
                    .font(.subheadline.weight(.semibold))
                Text(statusTitle(status))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if status.state == .active, status.activeCount > 0 {
                    Text("·")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(status.activeCount)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(statusColor(status.state))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if status.state == .active || status.isUserPaused {
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 16)

                Button {
                    onPause()
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(status.isUserPaused ? Color.secondary.opacity(0.4) : statusColor(status.state))
                        .frame(width: 44, height: 38)
                        .contentShape(Rectangle())
                }
                .disabled(status.isUserPaused)
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "smartlighting.floorplan.pause", defaultValue: "Pause Smart Lighting"))

                Button {
                    onResume()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(status.isUserPaused ? statusColor(status.state) : Color.secondary.opacity(0.4))
                        .frame(width: 44, height: 38)
                        .contentShape(Rectangle())
                        .padding(.trailing, 2)
                }
                .disabled(!status.isUserPaused)
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "smartlighting.floorplan.resume", defaultValue: "Resume Smart Lighting"))
            }
        }
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 3)
    }

    private func statusTitle(_ status: SmartLightingFloorplanStatus) -> String {
        switch status.state {
        case .active:
            return String(localized: "smartlighting.floorplan.status.active", defaultValue: "Smart Lighting active")
        case .paused:
            if status.isUserPaused {
                return String(localized: "smartlighting.floorplan.status.paused", defaultValue: "Smart Lighting paused")
            }
            if let nextResumeAt = status.nextResumeAt {
                return String(format: String(localized: "smartlighting.floorplan.status.pausedUntil",
                                             defaultValue: "Smart Lighting paused until %@"),
                              shortTime(nextResumeAt))
            }
            return String(localized: "smartlighting.floorplan.status.paused", defaultValue: "Smart Lighting paused")
        case .disabled:
            return String(localized: "smartlighting.floorplan.status.disabled", defaultValue: "Smart Lighting disabled")
        case .needsAttention:
            return String(format: String(localized: "smartlighting.floorplan.status.issues",
                                         defaultValue: "%d Smart Lighting issues"),
                          status.issueCount)
        }
    }

    private func statusIcon(_ state: SmartLightingFloorplanStatus.State) -> String {
        switch state {
        case .active: return "sparkles"
        case .paused: return "pause.circle.fill"
        case .disabled: return "power.circle"
        case .needsAttention: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ state: SmartLightingFloorplanStatus.State) -> Color {
        switch state {
        case .active: return BrandColor.primary
        case .paused: return BrandColor.secondary
        case .disabled: return .secondary
        case .needsAttention: return .orange
        }
    }

    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct FloorplanEditModeBanner: View {
    let onOpenDiagnostics: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.and.outline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BrandColor.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "floorplan.edit.banner.title", defaultValue: "Edit floorplan"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(String(localized: "floorplan.edit.banner.subtitle", defaultValue: "Tap a room to add there. Use + for free placement."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 8)

            Button {
                onOpenDiagnostics()
            } label: {
                Image(systemName: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "floorplan.status.accessibility", defaultValue: "Floorplan status"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, 20)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(BrandColor.primary.opacity(0.18), lineWidth: 1)
        )
    }
}

struct FloorplanTitleMenu: View {
    let currentFloorplan: Floorplan
    let pinnedFloorplans: [Floorplan]
    let primaryFloorplanID: String
    let onOpenSidebar: () -> Void
    let onSelectFloorplan: ((UUID) -> Void)?

    var body: some View {
        Menu {
            if pinnedFloorplans.isEmpty {
                Button {
                    onOpenSidebar()
                } label: {
                    Label(String(localized: "sidebar.open", defaultValue: "Open sidebar"), systemImage: "sidebar.left")
                }
            } else {
                Section(String(localized: "floorplan.quickAccess", defaultValue: "Quick Access")) {
                    ForEach(pinnedFloorplans) { item in
                        Button {
                            guard item.id != currentFloorplan.id else { return }
                            onSelectFloorplan?(item.id)
                        } label: {
                            Label {
                                HStack {
                                    Text(item.name)
                                    if item.id == currentFloorplan.id {
                                        Text(String(localized: "floorplan.current", defaultValue: "Current"))
                                    }
                                }
                            } icon: {
                                Image(systemName: titleMenuIcon(for: item))
                            }
                        }
                        .disabled(item.id == currentFloorplan.id || onSelectFloorplan == nil)
                    }
                }

                Button {
                    onOpenSidebar()
                } label: {
                    Label(String(localized: "sidebar.show", defaultValue: "Show sidebar"), systemImage: "sidebar.left")
                }
            }
        } label: {
            GlassTitlePill {
                HStack(spacing: 8) {
                    Text(currentFloorplan.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
    }

    private func titleMenuIcon(for item: Floorplan) -> String {
        if item.id == currentFloorplan.id {
            return "checkmark.circle.fill"
        }
        if item.id.uuidString == primaryFloorplanID {
            return "star.square.fill"
        }
        return "pin.circle.fill"
    }
}
