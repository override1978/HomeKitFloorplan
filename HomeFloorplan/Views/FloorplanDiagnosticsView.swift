import SwiftUI

struct FloorplanDiagnosticsView: View {
    let report: FloorplanHealthReport
    var onAddAccessories: (UUID) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryGrid

                    if !report.unplacedGroups.isEmpty {
                        unplacedAccessoriesSection
                    }

                    if report.issues.isEmpty {
                        healthyState
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(String(localized: "floorplan.diagnostics.toCheck", defaultValue: "Needs attention"))
                                .font(.headline)

                            ForEach(report.issues) { issue in
                                issueRow(issue)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle(String(localized: "floorplan.diagnostics.title", defaultValue: "Floorplan Status"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.close", defaultValue: "Close")) { dismiss() }
                }
            }
        }
    }

    private var unplacedAccessoriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "floorplan.diagnostics.unplaced.title", defaultValue: "Accessories to add"))
                    .font(.headline)
                Text(String(localized: "floorplan.diagnostics.unplaced.description", defaultValue: "Grouped by room, prioritizing the most useful items for overlays and automations."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(report.unplacedGroups) { group in
                unplacedGroupRow(group)
            }
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            metricCard(
                value: "\(report.placedCount)",
                label: "Marker",
                icon: "sensor.tag.radiowaves.forward",
                color: .blue
            )
            metricCard(
                value: "\(report.linkedRoomCount)",
                label: String(localized: "environment.rooms", defaultValue: "Rooms"),
                icon: "rectangle.3.group",
                color: .green
            )
            metricCard(
                value: "\(report.linkableUnplacedCount)",
                label: String(localized: "floorplan.metric.toPlace", defaultValue: "To place"),
                icon: "plus.viewfinder",
                color: report.linkableUnplacedCount == 0 ? .green : .orange
            )
            metricCard(
                value: "\(report.criticalCount + report.warningCount)",
                label: String(localized: "floorplan.diagnostics.issues", defaultValue: "Issues"),
                icon: report.isHealthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                color: report.isHealthy ? .green : .orange
            )
        }
    }

    private var healthyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(String(localized: "floorplan.diagnostics.healthy.title", defaultValue: "The floorplan is consistent"), systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(String(localized: "floorplan.diagnostics.healthy.description", defaultValue: "Markers, rooms, and HomeKit accessories are aligned."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metricCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func issueRow(_ issue: FloorplanHealthIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.severity.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color(for: issue.severity))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.subheadline.weight(.semibold))
                Text(issue.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(for: issue.severity).opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func unplacedGroupRow(_ group: FloorplanUnplacedAccessoryGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: group.highPriorityCount > 0 ? "sensor.tag.radiowaves.forward" : "plus.viewfinder")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(group.highPriorityCount > 0 ? .orange : .blue)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(group.roomName)
                            .font(.subheadline.weight(.semibold))
                        Text("\(group.accessories.count)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange))
                    }

                    if group.highPriorityCount > 0 {
                        Text(String(localized: "floorplan.diagnostics.highPriorityCount", defaultValue: "\(group.highPriorityCount) high priority for overlays and automations."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "floorplan.diagnostics.supportedMissing", defaultValue: "Supported accessories not yet present on the floorplan."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    dismiss()
                    onAddAccessories(group.roomID)
                } label: {
                    Label(String(localized: "common.add", defaultValue: "Add"), systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.accessories.prefix(4)) { accessory in
                    HStack(spacing: 8) {
                        priorityDot(accessory.priority)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(accessory.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text(String(
                                format: String(localized: "floorplan.diagnostics.accessoryPriority", defaultValue: "%1$@ · %2$@ priority"),
                                accessory.categoryName,
                                accessory.priority.label.lowercased()
                            ))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }

                let remaining = group.accessories.count - 4
                if remaining > 0 {
                    Text(String(format: String(localized: "floorplan.diagnostics.moreAccessories", defaultValue: "+%lld more accessories"), remaining))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                }
            }
            .padding(.leading, 32)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func priorityDot(_ priority: FloorplanPlacementPriority) -> some View {
        Circle()
            .fill(priorityColor(priority))
            .frame(width: 8, height: 8)
    }

    private func priorityColor(_ priority: FloorplanPlacementPriority) -> Color {
        switch priority {
        case .high: return .orange
        case .medium: return .blue
        case .low: return .secondary
        }
    }

    private func color(for severity: FloorplanHealthSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}
