import SwiftUI

// MARK: - DrawingTopBar

/// Top navigation bar for the 2D drawing editor.
/// Shows: cancel (X), undo/redo, spacer, "Fatto" done button.
struct DrawingTopBar: View {

    var canUndo: Bool
    var canRedo: Bool
    var isExporting: Bool
    var exportRotation: DrawingExportRotation
    var onExportRotationChange: (DrawingExportRotation) -> Void
    var visualExportStyle: DrawingVisualExportStyle
    var onVisualExportStyleChange: (DrawingVisualExportStyle) -> Void
    var exteriorFillColorIndex: Int
    var onExteriorFillChange: (Int) -> Void
    var onHelp: () -> Void
    var onCancel: () -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Cancel
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)

            Button(action: onHelp) {
                Image(systemName: "info.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Undo
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(canUndo ? .primary : .secondary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(canUndo ? 0.07 : 0.035), in: Circle())
            }
            .disabled(!canUndo)
            .buttonStyle(.plain)

            // Redo
            Button(action: onRedo) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(canRedo ? .primary : .secondary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(canRedo ? 0.07 : 0.035), in: Circle())
            }
            .disabled(!canRedo)
            .buttonStyle(.plain)

            Menu {
                ForEach(DrawingExportRotation.allCases) { rotation in
                    Button {
                        onExportRotationChange(rotation)
                    } label: {
                        Label {
                            Text(rotation.localizedTitle)
                        } icon: {
                            Image(systemName: rotation == exportRotation ? "checkmark.circle.fill" : rotation.iconName)
                        }
                    }
                }
            } label: {
                Image(systemName: exportRotation.iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(exportRotation == .asDrawn ? .primary : BrandColor.primary)
                    .frame(width: 36, height: 36)
                    .background(
                        exportRotation == .asDrawn ? Color.primary.opacity(0.07) : BrandColor.primary.opacity(0.12),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(isExporting)

            Menu {
                ForEach(DrawingVisualExportStyle.toolbarVisibleStyles) { style in
                    Button {
                        onVisualExportStyleChange(style)
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(style.localizedTitle)
                                Text(style.localizedSubtitle)
                            }
                        } icon: {
                            Image(systemName: style == visualExportStyle ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            } label: {
                let isDark = visualExportStyle == .architecturalDark
                let isNonStandard = visualExportStyle != .standard
                HStack(spacing: 6) {
                    Image(systemName: visualExportStyle.toolbarIconName)
                        .font(.system(size: 14, weight: .semibold))
                    Text(visualExportStyle.localizedTitle)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(isDark ? Color.white : (isNonStandard ? BrandColor.primary : Color.primary))
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(
                    isDark
                        ? Color(red: 0.10, green: 0.13, blue: 0.18)
                        : (isNonStandard ? BrandColor.primary.opacity(0.14) : Color.primary.opacity(0.10)),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .disabled(isExporting)

            if visualExportStyle != .architecturalDark {
                Menu {
                    Button {
                        onExteriorFillChange(-1)
                    } label: {
                        Label {
                            Text(String(localized: "exterior.fill.none", defaultValue: "None"))
                        } icon: {
                            Image(systemName: exteriorFillColorIndex < 0 ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    ForEach(ExteriorFillPalette.allCases, id: \.rawValue) { preset in
                        Button {
                            onExteriorFillChange(preset.rawValue)
                        } label: {
                            Label {
                                Text(preset.localizedName)
                            } icon: {
                                Image(systemName: exteriorFillColorIndex == preset.rawValue ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                } label: {
                    Image(systemName: exteriorFillColorIndex >= 0 ? "building.2.fill" : "building.2")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(exteriorFillColorIndex >= 0 ? BrandColor.primary : .primary)
                        .frame(width: 36, height: 36)
                        .background(
                            exteriorFillColorIndex >= 0 ? BrandColor.primary.opacity(0.12) : Color.primary.opacity(0.07),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(isExporting)
            }

            // Done
            Button(action: onDone) {
                HStack(spacing: 7) {
                    if isExporting {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.small)
                    }
                    Text(String(localized: "drawing.topbar.done", defaultValue: "Done"))
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(isExporting ? Color.secondary : BrandColor.primary, in: Capsule())
            }
            .disabled(isExporting)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 18, x: 0, y: 8)
    }
}

private extension DrawingExportRotation {
    var localizedTitle: String {
        switch self {
        case .asDrawn:
            return String(localized: "drawing.export.rotation.asDrawn", defaultValue: "As drawn")
        case .clockwise:
            return String(localized: "drawing.export.rotation.clockwise", defaultValue: "Rotate right")
        case .counterClockwise:
            return String(localized: "drawing.export.rotation.counterClockwise", defaultValue: "Rotate left")
        case .upsideDown:
            return String(localized: "drawing.export.rotation.upsideDown", defaultValue: "Upside down")
        }
    }

    var iconName: String {
        switch self {
        case .asDrawn:
            return "rectangle"
        case .clockwise:
            return "rotate.right"
        case .counterClockwise:
            return "rotate.left"
        case .upsideDown:
            return "arrow.2.circlepath"
        }
    }
}

private extension DrawingVisualExportStyle {
    static var toolbarVisibleStyles: [DrawingVisualExportStyle] {
        [.standard, .architecturalDark]
    }

    var toolbarIconName: String {
        switch self {
        case .standard:
            return "square"
        case .architectural:
            return "cube.transparent.fill"
        case .architecturalDark:
            return "moon.stars.fill"
        }
    }
}

// MARK: - DrawingEditorHelpSheet

struct DrawingEditorHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [DrawingHelpSection] = [
        DrawingHelpSection(
            icon: "pencil.tip",
            title: String(localized: "drawing.help.wall.title", defaultValue: "Walls"),
            message: String(localized: "drawing.help.wall.message", defaultValue: "Choose Wall, then drag on the canvas or tap two points. Snap keeps endpoints aligned to the grid or nearby vertices.")
        ),
        DrawingHelpSection(
            icon: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left",
            title: String(localized: "drawing.help.select.title", defaultValue: "Select and edit"),
            message: String(localized: "drawing.help.select.message", defaultValue: "Choose Select, tap an element, then drag it or use the inspector above the toolbar.")
        ),
        DrawingHelpSection(
            icon: "door.left.hand.open",
            title: String(localized: "drawing.help.openings.title", defaultValue: "Doors and windows"),
            message: String(localized: "drawing.help.openings.message", defaultValue: "Choose Door or Window, then tap a wall. Select the opening to move it, resize it, or flip the door swing.")
        ),
        DrawingHelpSection(
            icon: "square.dashed",
            title: String(localized: "drawing.help.rooms.title", defaultValue: "Room areas"),
            message: String(localized: "drawing.help.rooms.message", defaultValue: "Draw a room area, link it to a HomeKit room, then drag vertices to match the real shape.")
        ),
        DrawingHelpSection(
            icon: "point.topleft.down.curvedto.point.bottomright.up",
            title: String(localized: "drawing.help.vertices.title", defaultValue: "Polygon vertices"),
            message: String(localized: "drawing.help.vertices.message", defaultValue: "With a room area selected, tap an edge to add a vertex. Double-tap a vertex to remove it.")
        ),
        DrawingHelpSection(
            icon: "point.topleft.down.curvedto.point.bottomright.up",
            title: String(localized: "drawing.help.snap.title", defaultValue: "Snap"),
            message: String(localized: "drawing.help.snap.message", defaultValue: "Use the magnet to switch between grid-only snapping and smart snapping to nearby wall endpoints. Wall drawing also aligns to the nearest 45-degree angle.")
        ),
        DrawingHelpSection(
            icon: "rectangle.and.arrow.up.right.and.arrow.down.left",
            title: String(localized: "drawing.help.export.title", defaultValue: "Export"),
            message: String(localized: "drawing.help.export.message", defaultValue: "Legacy keeps the old screen-based export. Adaptive uses the newer stable landscape export for testing.")
        )
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sections) { section in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: section.icon)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(BrandColor.primary)
                                .frame(width: 28, height: 28)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(section.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text(String(localized: "drawing.help.footer", defaultValue: "You can reopen this guide from the info button in the top toolbar."))
                }
            }
            .navigationTitle(String(localized: "drawing.help.title", defaultValue: "Drawing guide"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct DrawingHelpSection: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let message: String
}

// MARK: - DrawingRoomLinkStatusPill

struct DrawingRoomLinkStatusPill: View {
    let linkedCount: Int
    let totalCount: Int
    let isActive: Bool

    private var tint: Color {
        linkedCount > 0 ? BrandColor.primary : .orange
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: linkedCount > 0 ? "checkmark.circle.fill" : "house.badge.exclamationmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            Text(statusText)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)

            if isActive {
                Text(String(localized: "drawing.roomLink.active", defaultValue: "Draw area"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tint, in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
    }

    private var statusText: String {
        guard totalCount > 0 else {
            return String(localized: "drawing.roomLink.noHomeRooms", defaultValue: "HomeKit Rooms: \(linkedCount) linked")
        }
        return String(localized: "drawing.roomLink.count", defaultValue: "HomeKit Rooms: \(linkedCount)/\(totalCount) linked")
    }
}

// MARK: - OpeningInspectorPanel

/// Panel shown above the toolbar when an opening is selected.
/// Allows resizing the opening width and flipping the door side.
struct OpeningInspectorPanel: View {

    let opening: PlacedOpening
    var onWidthChange: (CGFloat) -> Void
    var onFlip: () -> Void

    /// Local slider value in cm (1 canvas pt ≈ 1 cm at the chosen scale)
    @State private var sliderValue: Double = 0

    // Width limits in canvas points
    private let minWidth: CGFloat = 40
    private let maxWidth: CGFloat = 200

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                // Icon
                Image(systemName: opening.kind == .door ? "door.left.hand.open" : "rectangle.split.2x1")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 28)

                // Label
                Text(opening.kind == .door
                     ? String(localized: "drawing.inspector.opening.door", defaultValue: "Door")
                     : String(localized: "drawing.inspector.opening.window", defaultValue: "Window"))
                    .font(.subheadline.weight(.semibold))

                Spacer()

                // Width readout
                Text("\(Int(sliderValue)) cm")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                // Flip button (doors only)
                if opening.kind == .door {
                    Button(action: onFlip) {
                        Label(
                            String(localized: "drawing.inspector.opening.flip", defaultValue: "Flip"),
                            systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right"
                        )
                        .labelStyle(.iconOnly)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(BrandColor.primary)
                        .frame(width: 36, height: 36)
                        .background(BrandColor.primary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Width slider
            Slider(
                value: $sliderValue,
                in: Double(minWidth)...Double(maxWidth),
                step: 5
            ) {
                EmptyView()
            } minimumValueLabel: {
                Text("\(Int(minWidth))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("\(Int(maxWidth))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .tint(BrandColor.primary)
            .onChange(of: sliderValue) { _, newValue in
                onWidthChange(CGFloat(newValue))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear {
            sliderValue = Double(opening.width)
        }
        // Keep slider in sync if opening changes from outside (e.g. undo)
        .onChange(of: opening.width) { _, newW in
            sliderValue = Double(newW)
        }
    }
}

// MARK: - PlaceOpeningBanner

/// Contextual banner shown when mode == .placeOpening.
/// Tells the user to tap a wall and lets them cancel.
struct PlaceOpeningBanner: View {
    let kind: OpeningKind
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind == .door ? "door.left.hand.open" : "rectangle.split.2x1")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(BrandColor.primary)

            Text(kind == .door
                 ? String(localized: "drawing.banner.door",   defaultValue: "Tap a wall to add a door")
                 : String(localized: "drawing.banner.window", defaultValue: "Tap a wall to add a window"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - DrawingToolbar

/// Bottom palette toolbar for the 2D drawing editor.
/// Shows:
///   - draw/select mode toggle (left)
///   - Porta / Finestra tap buttons (centre)
///   - delete button when something is selected (right)
struct DrawingToolbar: View {

    @Binding var mode: DrawingMode
    @Binding var wallKind: WallKind
    @Binding var vertexSnapEnabled: Bool
    @Binding var furnitureKind: FurnitureKind
    @Binding var showDimensions: Bool
    var hasSelection: Bool
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 16) {

            // ── Left: mode toggle (Muro / Seleziona) ──────────────────────────
            HStack(spacing: 0) {
                modeButton(icon: "pencil.tip",
                           label: String(localized: "drawing.toolbar.mode.draw",   defaultValue: "Wall"),
                           active: mode == .draw) {
                    mode = .draw
                }
                modeButton(icon: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left",
                           label: String(localized: "drawing.toolbar.mode.select", defaultValue: "Select"),
                           active: mode == .select) {
                    mode = .select
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            )

            // ── Wall kind toggle (visible only in draw mode) ────────────────
            if mode == .draw {
                HStack(spacing: 0) {
                    wallKindButton(kind: .exterior, icon: "square.on.square",
                                   label: String(localized: "drawing.toolbar.wall.exterior", defaultValue: "Perim."))
                    wallKindButton(kind: .interior, icon: "square.dashed",
                                   label: String(localized: "drawing.toolbar.wall.interior", defaultValue: "Interior"))
                    wallKindButton(kind: .balcony,  icon: "line.diagonal",
                                   label: String(localized: "drawing.toolbar.wall.balcony",  defaultValue: "Balcony"))
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                )
                .transition(.scale.combined(with: .opacity))
            }

            // ── Snap toggle (draw + select modes) ────────────────────────────
            if mode == .draw || mode == .select {
                Button {
                    vertexSnapEnabled.toggle()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.system(size: 16, weight: vertexSnapEnabled ? .semibold : .regular))
                        Text(String(localized: "drawing.toolbar.snap", defaultValue: "Snap"))
                            .font(.system(size: 10, weight: vertexSnapEnabled ? .semibold : .regular))
                    }
                    .foregroundStyle(vertexSnapEnabled ? BrandColor.primary : .secondary)
                    .frame(width: 52, height: 48)
                    .background(vertexSnapEnabled ? BrandColor.primary.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }

            // ── Dimension labels toggle ───────────────────────────────────────
            Button {
                showDimensions.toggle()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: showDimensions ? "ruler.fill" : "ruler")
                        .font(.system(size: 16, weight: showDimensions ? .semibold : .regular))
                    Text(String(localized: "drawing.toolbar.dimensions", defaultValue: "Quote"))
                        .font(.system(size: 10, weight: showDimensions ? .semibold : .regular))
                }
                .foregroundStyle(showDimensions ? BrandColor.primary : .secondary)
                .frame(width: 52, height: 48)
                .background(showDimensions ? BrandColor.primary.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer()

            // ── Centre: Door, Window, HomeKit Room Area, Furniture ───────────
            HStack(spacing: 8) {
                openingButton(kind: .door,
                              icon: "door.left.hand.open",
                              label: String(localized: "drawing.toolbar.door",      defaultValue: "Door"))
                openingButton(kind: .window,
                              icon: "rectangle.split.2x1",
                              label: String(localized: "drawing.toolbar.window",    defaultValue: "Window"))
                roomAreaButton()
                furnitureButton()
            }

            Spacer()

            // ── Right: Delete (only when selection active) ────────────────────
            if hasSelection {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .animation(.spring(response: 0.3), value: hasSelection)
    }

    // MARK: Private helpers

    private func wallKindButton(kind: WallKind, icon: String, label: String) -> some View {
        let active = wallKind == kind
        return Button {
            wallKind = kind
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: active ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 10, weight: active ? .semibold : .regular))
            }
            .foregroundStyle(active ? BrandColor.primary : .secondary)
            .frame(width: 60, height: 48)
            .background(active ? BrandColor.primary.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func modeButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: active ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 10, weight: active ? .semibold : .regular))
            }
            .foregroundStyle(active ? BrandColor.primary : .secondary)
            .frame(width: 72, height: 48)
            .background(active ? BrandColor.primary.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func openingButton(kind: OpeningKind, icon: String, label: String) -> some View {
        let isActive: Bool
        if case .placeOpening(let k) = mode { isActive = k == kind } else { isActive = false }

        return Button {
            if isActive {
                mode = .select
            } else {
                mode = .placeOpening(kind)
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: isActive ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular))
            }
            .foregroundStyle(isActive ? BrandColor.primary : .primary)
            .frame(width: 68, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive
                          ? BrandColor.primary.opacity(0.15)
                          : Color(.systemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isActive ? BrandColor.primary.opacity(0.5) : Color.clear,
                                  lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25), value: isActive)
    }

    private func roomLabelButton() -> some View {
        let isActive = (mode == .placeRoomLabel)
        return Button {
            mode = isActive ? .select : .placeRoomLabel
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 18, weight: isActive ? .semibold : .regular))
                Text(String(localized: "drawing.toolbar.room", defaultValue: "Room"))
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular))
            }
            .foregroundStyle(isActive ? BrandColor.primary : .primary)
            .frame(width: 68, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive
                          ? BrandColor.primary.opacity(0.15)
                          : Color(.systemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isActive ? BrandColor.primary.opacity(0.5) : Color.clear,
                                  lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25), value: isActive)
    }

    private func roomAreaButton() -> some View {
        let isActive = (mode == .drawRoomArea)
        return Button {
            mode = isActive ? .select : .drawRoomArea
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 18, weight: isActive ? .semibold : .regular))
                Text(String(localized: "drawing.toolbar.roomArea", defaultValue: "Room"))
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular))
            }
            .foregroundStyle(isActive ? BrandColor.primary : .primary)
            .frame(width: 68, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive
                          ? BrandColor.primary.opacity(0.15)
                          : Color(.systemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isActive ? BrandColor.primary.opacity(0.5) : Color.clear,
                                  lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25), value: isActive)
    }

    private func furnitureButton() -> some View {
        let isActive = (mode == .placeFurniture)
        return Menu {
            ForEach(FurnitureKind.allCases) { kind in
                Button {
                    furnitureKind = kind
                    mode = .placeFurniture
                } label: {
                    Label {
                        Text(kind.localizedName)
                    } icon: {
                        Image(systemName: kind == furnitureKind ? "checkmark.circle.fill" : kind.systemImage)
                    }
                }
            }
        } label: {
            furnitureButtonLabel(isActive: isActive)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25), value: isActive)
    }

    private func furnitureButtonLabel(isActive: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: furnitureKind.systemImage)
                .font(.system(size: 18, weight: isActive ? .semibold : .regular))
            Text(furnitureKind.localizedName)
                .font(.system(size: 10, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .foregroundStyle(isActive ? BrandColor.primary : .primary)
        .frame(width: 68, height: 52)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive
                      ? BrandColor.primary.opacity(0.15)
                      : Color(.systemFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isActive ? BrandColor.primary.opacity(0.5) : Color.clear,
                              lineWidth: 1.5)
        )
    }
}

// MARK: - PlaceRoomLabelBanner

/// Contextual banner shown when mode == .placeRoomLabel.
struct PlaceRoomLabelBanner: View {
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(BrandColor.primary)

            Text(String(localized: "drawing.banner.roomLabel", defaultValue: "Tap to place the label"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - RoomLabelInspectorPanel

/// Panel shown above the toolbar when a room label is selected.
struct RoomLabelInspectorPanel: View {
    let label: RoomLabel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(label.name)
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "drawing.inspector.roomLabel.subtitle", defaultValue: "HomeKit Room"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - DrawRoomAreaBanner

/// Contextual banner shown when mode == .drawRoomArea.
struct DrawRoomAreaBanner: View {
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(BrandColor.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "drawing.banner.roomArea.title",
                            defaultValue: "Drag to draw a HomeKit room area"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(String(localized: "drawing.banner.roomArea.subtitle",
                            defaultValue: "Choose the matching HomeKit room after drawing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - RoomAreaInspectorPanel

/// Panel shown above the toolbar when a room area is selected.
struct RoomAreaInspectorPanel: View {
    let area: RoomArea
    var onFloorKindChange: (FloorKind?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top row: icon + name + dimensions
            HStack(spacing: 12) {
                Image(systemName: area.points != nil ? "pentagon.fill" : "rectangle.dashed")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(area.name)
                        .font(.subheadline.weight(.semibold))
                    if let pts = area.points {
                        let sqPt = Int(area.polygonArea)
                        Text("\(pts.count) vertici • ~\(sqPt) pt²")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        let w = Int(area.rect.width), h = Int(area.rect.height)
                        Text("\(w) × \(h) pt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let kind = area.floorKind {
                    Text(kind.localizedName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(BrandColor.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(BrandColor.primary.opacity(0.10), in: Capsule())
                }
            }

            Label(
                String(localized: "drawing.area.reshapeHint",
                       defaultValue: "Drag an edge to reshape — it snaps to walls. Double-tap a point to remove it."),
                systemImage: "hand.draw"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            // Floor picker row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // "Nessuno" tile — resets to colour fill
                    floorTile(
                        icon: "slash.circle",
                        label: String(localized: "drawing.floor.none", defaultValue: "None"),
                        swatch: Color.secondary.opacity(0.18),
                        isActive: area.floorKind == nil
                    ) { onFloorKindChange(nil) }

                    ForEach(FloorKind.allCases) { kind in
                        floorTile(
                            icon: kind.systemImage,
                            label: kind.localizedName,
                            swatch: kind.swatchColor,
                            isActive: area.floorKind == kind
                        ) {
                            onFloorKindChange(area.floorKind == kind ? nil : kind)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func floorTile(icon: String, label: String, swatch: Color,
                           isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(swatch)
                        .frame(width: 40, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isActive ? BrandColor.primary : Color.secondary)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isActive ? BrandColor.primary : Color.clear, lineWidth: 2)
                )
                Text(label)
                    .font(.system(size: 9, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? BrandColor.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(width: 44)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FloorKind visual helpers

extension FloorKind {
    var swatchColor: Color {
        switch self {
        case .legno:      return Color(red: 0.85, green: 0.72, blue: 0.52).opacity(0.55)
        case .piastrelle: return Color(red: 0.93, green: 0.91, blue: 0.87).opacity(0.80)
        case .gres:       return Color(red: 0.80, green: 0.78, blue: 0.72).opacity(0.70)
        case .marmo:      return Color(red: 0.96, green: 0.95, blue: 0.92).opacity(0.90)
        case .cemento:    return Color(red: 0.70, green: 0.69, blue: 0.67).opacity(0.60)
        }
    }
}

// MARK: - PlaceFurnitureBanner

/// Contextual banner shown when mode == .placeFurniture.
struct PlaceFurnitureBanner: View {
    let kind: FurnitureKind
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(BrandColor.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "drawing.banner.furniture", defaultValue: "Tap to place the furniture item"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(kind.localizedName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - FurnitureInspectorPanel

/// Panel shown above the toolbar when a furniture item is selected.
/// Includes an editable TextField for the furniture name.
struct FurnitureInspectorPanel: View {
    let item: FurnitureItem
    var onNameChange: (String) -> Void
    var onRotate: (Double) -> Void
    var onDuplicate: () -> Void
    var onToggleName: () -> Void
    var onTintChange: (Int?) -> Void

    @State private var editingName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                TextField(
                    String(localized: "drawing.inspector.furniture.namePlaceholder", defaultValue: "Furniture name"),
                    text: $editingName
                )
                .font(.subheadline.weight(.semibold))
                .textFieldStyle(.plain)
                .onSubmit {
                    let trimmed = editingName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onNameChange(trimmed) }
                }
                let w = Int(item.rect.width), h = Int(item.rect.height)
                HStack(spacing: 6) {
                    Text("\(w) × \(h) pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Menu {
                        ForEach([15.0, 30.0, 45.0], id: \.self) { step in
                            Button {
                                onRotate(step)
                            } label: {
                                Label("+\(Int(step))°", systemImage: "rotate.right")
                            }
                            Button {
                                onRotate(-step)
                            } label: {
                                Label("−\(Int(step))°", systemImage: "rotate.left")
                            }
                        }
                        Divider()
                        Button {
                            onRotate(-item.rotationDegrees)
                        } label: {
                            Label(String(localized: "drawing.inspector.furniture.resetRotation",
                                         defaultValue: "Reset to 0°"),
                                  systemImage: "arrow.uturn.backward")
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(Int(normalizedRotation(item.rotationDegrees)))°")
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BrandColor.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(BrandColor.primary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    onToggleName()
                } label: {
                    Image(systemName: item.showsName ? "textformat" : "eye.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(item.showsName ? BrandColor.primary : .secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            item.showsName ? BrandColor.primary.opacity(0.12) : Color.primary.opacity(0.07),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)

                Button {
                    onDuplicate()
                } label: {
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    onRotate(-90)
                } label: {
                    Image(systemName: "rotate.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    onRotate(90)
                } label: {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }

        if item.kind.supportsTint {
            tintRow
        }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear { editingName = item.name }
        .onChange(of: item.name) { _, newName in editingName = newName }
        .onChange(of: editingName) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { onNameChange(trimmed) }
        }
    }

    /// Swatch row for the furniture tint: a neutral option plus the curated palette.
    private var tintRow: some View {
        HStack(spacing: 8) {
            Button {
                onTintChange(nil)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 24, height: 24)
                    Image(systemName: "slash.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .overlay(
                    Circle().strokeBorder(item.tintIndex == nil ? BrandColor.primary : .clear,
                                          lineWidth: 2)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "drawing.tint.none", defaultValue: "No tint"))

            ForEach(FurnitureTint.allCases) { tint in
                let isSelected = item.tintIndex == tint.rawValue
                Button {
                    onTintChange(tint.rawValue)
                } label: {
                    Circle()
                        .fill(Color(UIColor { t in
                            UIColor(cgColor: t.userInterfaceStyle == .dark
                                    ? tint.darkCGColor : tint.lightCGColor)
                        }))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().strokeBorder(isSelected ? BrandColor.primary : Color.primary.opacity(0.12),
                                                  lineWidth: isSelected ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tint.localizedName)
            }

            Spacer()
        }
    }

    private func normalizedRotation(_ degrees: Double) -> Double {
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        return normalized < 0 ? normalized + 360 : normalized
    }
}

// MARK: - WallInspectorPanel

/// Panel shown above the toolbar when a wall is selected.
/// Displays the wall length in metres and allows stepper-based resizing (start is anchored).
struct WallInspectorPanel: View {
    let wall: WallSegment
    /// Called with the new length in grid units (each unit = 20 pt = 20 cm).
    var onResize: (Int) -> Void

    @AppStorage(DimensionUnit.appStorageKey)
    private var dimensionUnitRaw: String = DimensionUnit.metric.rawValue

    private var dimensionUnit: DimensionUnit {
        DimensionUnit(rawValue: dimensionUnitRaw) ?? .metric
    }

    private var gridUnits: Int {
        max(1, Int(round(wall.length / DrawingDocument.gridSpacing)))
    }

    private var kindLabel: String {
        switch wall.kind {
        case .exterior: return String(localized: "drawing.inspector.wall.kind.exterior", defaultValue: "Exterior wall")
        case .interior: return String(localized: "drawing.inspector.wall.kind.interior", defaultValue: "Interior wall")
        case .balcony:  return String(localized: "drawing.inspector.wall.kind.balcony",  defaultValue: "Balcony / terrace")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "ruler")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(dimensionUnit.format(pt: wall.length))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Stepper(
                value: Binding(get: { gridUnits }, set: { onResize($0) }),
                in: 1...100,
                step: 1
            ) { EmptyView() }
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - RoomPickerSheet

import HomeKit

/// Sheet that lists HMRoom entries for the user to pick when placing a room label.
struct RoomPickerSheet: View {
    let rooms: [HMRoom]
    var onPick: (HMRoom) -> Void
    var onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if rooms.isEmpty {
                    ContentUnavailableView(
                        String(localized: "drawing.picker.room.empty.title",       defaultValue: "No Rooms"),
                        systemImage: "rectangle.split.3x3",
                        description: Text(String(localized: "drawing.picker.room.empty.description",
                                                 defaultValue: "Set up rooms in the iOS Home app."))
                    )
                } else {
                    List(rooms) { room in
                        Button {
                            onPick(room)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "rectangle.split.3x3")
                                    .foregroundStyle(BrandColor.primary)
                                Text(room.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "drawing.picker.room.title", defaultValue: "Choose Room"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "drawing.picker.cancel", defaultValue: "Cancel")) {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
    }
}
