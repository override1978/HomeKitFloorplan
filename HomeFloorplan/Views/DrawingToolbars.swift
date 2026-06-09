import SwiftUI

// MARK: - DrawingTopBar

/// Top navigation bar for the 2D drawing editor.
/// Shows: cancel (X), undo, spacer, "Fatto" done button.
struct DrawingTopBar: View {

    var canUndo: Bool
    var onCancel: () -> Void
    var onUndo: () -> Void
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Cancel
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            // Undo
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(canUndo ? .primary : .secondary)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(!canUndo)

            // Done
            Button(action: onDone) {
                Text(String(localized: "drawing.topbar.done", defaultValue: "Fatto"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(BrandColor.primary, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
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
                     ? String(localized: "drawing.inspector.opening.door", defaultValue: "Porta")
                     : String(localized: "drawing.inspector.opening.window", defaultValue: "Finestra"))
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
                            String(localized: "drawing.inspector.opening.flip", defaultValue: "Inverti"),
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
                 ? String(localized: "drawing.banner.door",   defaultValue: "Tocca un muro per aggiungere una porta")
                 : String(localized: "drawing.banner.window", defaultValue: "Tocca un muro per aggiungere una finestra"))
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
    var hasSelection: Bool
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 16) {

            // ── Left: mode toggle (Muro / Seleziona) ──────────────────────────
            HStack(spacing: 0) {
                modeButton(icon: "pencil.tip",
                           label: String(localized: "drawing.toolbar.mode.draw",   defaultValue: "Muro"),
                           active: mode == .draw) {
                    mode = .draw
                }
                modeButton(icon: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left",
                           label: String(localized: "drawing.toolbar.mode.select", defaultValue: "Seleziona"),
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
                                   label: String(localized: "drawing.toolbar.wall.interior", defaultValue: "Interno"))
                    wallKindButton(kind: .balcony,  icon: "line.diagonal",
                                   label: String(localized: "drawing.toolbar.wall.balcony",  defaultValue: "Balcone"))
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
                        Image(systemName: vertexSnapEnabled ? "magnet.fill" : "magnet")
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

            Spacer()

            // ── Centre: Porta, Finestra, Stanza, Area, Arredo ────────────────
            HStack(spacing: 8) {
                openingButton(kind: .door,
                              icon: "door.left.hand.open",
                              label: String(localized: "drawing.toolbar.door",      defaultValue: "Porta"))
                openingButton(kind: .window,
                              icon: "rectangle.split.2x1",
                              label: String(localized: "drawing.toolbar.window",    defaultValue: "Finestra"))
                roomLabelButton()
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
                Text(String(localized: "drawing.toolbar.room", defaultValue: "Stanza"))
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
                Image(systemName: "rectangle.dashed.badge.plus")
                    .font(.system(size: 18, weight: isActive ? .semibold : .regular))
                Text(String(localized: "drawing.toolbar.area", defaultValue: "Area"))
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
        return Button {
            mode = isActive ? .select : .placeFurniture
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "sofa.fill")
                    .font(.system(size: 18, weight: isActive ? .semibold : .regular))
                Text(String(localized: "drawing.toolbar.furniture", defaultValue: "Arredo"))
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

            Text(String(localized: "drawing.banner.roomLabel", defaultValue: "Tocca per posizionare l'etichetta"))
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
                Text(String(localized: "drawing.inspector.roomLabel.subtitle", defaultValue: "Stanza HomeKit"))
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
            Image(systemName: "rectangle.dashed.badge.plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(BrandColor.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "drawing.banner.roomArea.title",
                            defaultValue: "Trascina per disegnare l'area della stanza"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(String(localized: "drawing.banner.roomArea.subtitle",
                            defaultValue: "Collega a HomeKit per abilitare il layer Ambiente"))
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

    var body: some View {
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - PlaceFurnitureBanner

/// Contextual banner shown when mode == .placeFurniture.
struct PlaceFurnitureBanner: View {
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sofa.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(BrandColor.primary)

            Text(String(localized: "drawing.banner.furniture", defaultValue: "Tocca per posizionare il mobile"))
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

// MARK: - FurnitureInspectorPanel

/// Panel shown above the toolbar when a furniture item is selected.
/// Includes an editable TextField for the furniture name.
struct FurnitureInspectorPanel: View {
    let item: FurnitureItem
    var onNameChange: (String) -> Void

    @State private var editingName: String = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sofa.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                TextField(
                    String(localized: "drawing.inspector.furniture.namePlaceholder", defaultValue: "Nome mobile"),
                    text: $editingName
                )
                .font(.subheadline.weight(.semibold))
                .textFieldStyle(.plain)
                .onSubmit {
                    let trimmed = editingName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onNameChange(trimmed) }
                }
                let w = Int(item.rect.width), h = Int(item.rect.height)
                Text("\(w) × \(h) pt")
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
        .onAppear { editingName = item.name }
        .onChange(of: item.name) { _, newName in editingName = newName }
        .onChange(of: editingName) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { onNameChange(trimmed) }
        }
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
                        String(localized: "drawing.picker.room.empty.title",       defaultValue: "Nessuna stanza"),
                        systemImage: "rectangle.split.3x3",
                        description: Text(String(localized: "drawing.picker.room.empty.description",
                                                 defaultValue: "Configura le stanze nell'app Casa di iOS."))
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
            .navigationTitle(String(localized: "drawing.picker.room.title", defaultValue: "Scegli stanza"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "drawing.picker.cancel", defaultValue: "Annulla")) {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
    }
}
