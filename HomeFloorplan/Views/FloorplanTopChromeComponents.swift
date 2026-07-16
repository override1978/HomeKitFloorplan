import SwiftUI

struct TopBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct FloorplanTopBarView: View {
    let size: CGSize
    let floorplan: Floorplan
    let presentationStyle: FloorplanEditorView.PresentationStyle
    let columnVisibility: NavigationSplitViewVisibility
    let pinnedFloorplans: [Floorplan]
    let primaryFloorplanID: String
    let isEditing: Bool
    let overlayVM: FloorplanOverlayViewModel?
    let overlayContext: FloorplanOverlayContext
    let environmentSensorTypes: [SensorServiceType]
    let isCloudKitMaster: Bool
    let smartLightingStatus: SmartLightingFloorplanStatus?
    let securityAdapter: SecuritySystemAdapter?
    let securityActivationDate: Date?
    let onOpenSidebar: () -> Void
    let onDismiss: () -> Void
    let onSelectFloorplan: ((UUID) -> Void)?
    let onAddAccessory: () -> Void
    let onShowHelp: () -> Void
    let onShowDiagnostics: () -> Void
    let onEditDrawing: () -> Void
    let onShowScenes: () -> Void
    let onToggleEditing: () -> Void
    let onPauseSmartLighting: () -> Void
    let onResumeSmartLighting: () -> Void
    let onTopBarHeightChanged: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if !isEditing, let overlayVM {
                    FloorplanModePill(overlayVM: overlayVM, context: overlayContext)
                }

                HStack {
                    HStack(spacing: 10) {
                        leadingNavigationButton

                        FloorplanTitleMenu(
                            currentFloorplan: floorplan,
                            pinnedFloorplans: pinnedFloorplans,
                            primaryFloorplanID: primaryFloorplanID,
                            onOpenSidebar: onOpenSidebar,
                            onSelectFloorplan: onSelectFloorplan
                        )
                    }

                    Spacer()

                    FloorplanTopRightActions(
                        isEditing: isEditing,
                        isOverlayMode: (overlayVM?.activeMode ?? .controls) != .controls,
                        showsSceneText: size.width >= 760,
                        isDrawingAvailable: floorplan.drawingDocumentJSON != nil,
                        onAddAccessory: onAddAccessory,
                        onShowHelp: onShowHelp,
                        onShowDiagnostics: onShowDiagnostics,
                        onEditDrawing: onEditDrawing,
                        onShowScenes: onShowScenes,
                        onToggleEditing: onToggleEditing
                    )
                }
            }
            .animation(.spring(response: 0.4), value: columnVisibility)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            statusBanners

            Spacer().frame(height: 8)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.spring(response: 0.35), value: overlayVM?.activeMode)
        .animation(.spring(response: 0.35), value: floorplan.linkedRooms.isEmpty)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TopBarHeightKey.self,
                    value: geo.size.height
                )
            }
        )
        .onPreferenceChange(TopBarHeightKey.self, perform: onTopBarHeightChanged)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var leadingNavigationButton: some View {
        switch presentationStyle {
        case .splitView:
            if columnVisibility == .detailOnly {
                Button(action: onOpenSidebar) {
                    GlassCircle(size: 40) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        case .pushed:
            Button(action: onDismiss) {
                GlassCircle(size: 40) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.red)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if !isEditing,
           overlayVM?.activeMode == .controls,
           isCloudKitMaster,
           let smartLightingStatus {
            FloorplanSmartLightingStatusPill(
                status: smartLightingStatus,
                onPause: onPauseSmartLighting,
                onResume: onResumeSmartLighting
            )
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }

        if !isEditing, let overlayVM, overlayVM.activeMode == .environment {
            EnvironmentFilterBar(
                overlayVM: overlayVM,
                availableTypes: environmentSensorTypes
            )
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }

        if !isEditing,
           let overlayVM,
           overlayVM.activeMode == .security,
           let securityAdapter {
            AlarmStatusPill(
                adapter: securityAdapter,
                activationDate: securityActivationDate
            )
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }

        if isEditing {
            FloorplanEditModeBanner(onOpenDiagnostics: onShowDiagnostics)
                .padding(.top, 6)
                .transition(.opacity)
        }

        if !isEditing && floorplan.linkedRooms.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text(String(localized: "floorplan.editor.banner.noRooms",
                            defaultValue: "No rooms linked — open the 2D editor (✏️) to draw the areas and unlock the Environment layer."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

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

struct FloorplanTopRightActions: View {
    let isEditing: Bool
    let isOverlayMode: Bool
    let showsSceneText: Bool
    let isDrawingAvailable: Bool
    let onAddAccessory: () -> Void
    let onShowHelp: () -> Void
    let onShowDiagnostics: () -> Void
    let onEditDrawing: () -> Void
    let onShowScenes: () -> Void
    let onToggleEditing: () -> Void

    private var hidesActions: Bool {
        isOverlayMode && !isEditing
    }

    var body: some View {
        GlassTitlePill {
            HStack(spacing: 0) {
                if isEditing {
                    Button {
                        onAddAccessory()
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "floorplan.addAccessory", defaultValue: "Add accessory"))
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))

                    Divider().frame(height: 20)
                        .transition(.opacity)
                }

                if !hidesActions {
                    FloorplanToolsMenu(
                        isDrawingAvailable: isDrawingAvailable,
                        onShowHelp: onShowHelp,
                        onShowDiagnostics: onShowDiagnostics,
                        onEditDrawing: onEditDrawing
                    )

                    Divider().frame(height: 20)

                    Button {
                        onShowScenes()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.rectangle.on.rectangle")
                            if showsSceneText {
                                Text(String(localized: "scenes.title", defaultValue: "Scenes"))
                            }
                        }
                        .font(.subheadline)
                        .fontWeight(showsSceneText ? .medium : .regular)
                        .padding(.horizontal, showsSceneText ? 14 : 13)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .accessibilityLabel(String(localized: "scenes.title", defaultValue: "Scenes"))
                    .help(String(localized: "scenes.open", defaultValue: "Open scenes"))

                    Divider().frame(height: 20)

                    Button {
                        onToggleEditing()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isEditing ? "checkmark" : "pencil")
                            Text(isEditing
                                 ? String(localized: "common.done", defaultValue: "Done")
                                 : String(localized: "common.edit", defaultValue: "Edit"))
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(isEditing ? BrandColor.primary : Color.primary.opacity(0.55))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .opacity(hidesActions ? 0 : 1)
        .allowsHitTesting(!hidesActions)
        .animation(.easeInOut(duration: 0.2), value: hidesActions)
    }
}

struct FloorplanToolsMenu: View {
    let isDrawingAvailable: Bool
    let onShowHelp: () -> Void
    let onShowDiagnostics: () -> Void
    let onEditDrawing: () -> Void

    var body: some View {
        Menu {
            Button {
                onShowHelp()
            } label: {
                Label(String(localized: "floorplan.help.open", defaultValue: "Floorplan help"), systemImage: "info.circle")
            }

            Button {
                onShowDiagnostics()
            } label: {
                Label(String(localized: "floorplan.diagnostics.open", defaultValue: "Marker diagnostics"), systemImage: "checklist")
            }

            Button {
                onEditDrawing()
            } label: {
                Label(String(localized: "floorplan.drawing.edit", defaultValue: "Edit 2D drawing"), systemImage: "pencil.and.ruler")
            }
            .disabled(!isDrawingAvailable)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.subheadline)
                .foregroundStyle(Color.primary.opacity(0.55))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "floorplan.tools.open", defaultValue: "Floorplan tools"))
        .help(String(localized: "floorplan.tools.open", defaultValue: "Floorplan tools"))
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
