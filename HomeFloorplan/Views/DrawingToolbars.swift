import SwiftUI

// MARK: - Scudo tocchi della chrome

/// Una UIView vera dietro la chrome. I recognizer del canvas (la scrollview
/// a tutto schermo là sotto) ricevono ogni tocco il cui hit-test UIKit cade
/// su di loro o sui loro discendenti — e i controlli SwiftUI, disegnati come
/// layer della hosting view, **non partecipano all'hit-test UIKit**: un tap
/// su Undo faceva l'undo E piazzava un punto di muro. Lo scudo vince
/// l'hit-test e il canvas non vede il tocco; i bottoni continuano a
/// funzionare perché i gesti SwiftUI vivono sulla hosting view, che dello
/// scudo è antenata.
private struct CanvasTouchShield: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension View {
    /// Da applicare a ogni blocco di chrome che galleggia sopra il canvas.
    func shieldsCanvasTouches() -> some View {
        background(CanvasTouchShield())
    }
}

// MARK: - DrawingTopBar

/// Top navigation bar for the 2D drawing editor.
    /// Shows: cancel (X), undo/redo, spacer, "Fatto" done button.
struct DrawingTopBar: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var topBarIconSide: CGFloat { 48 }

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
        if isCompact {
            compactBar
        } else {
            regularBar
        }
    }

    /// La barra da pollice: una riga sola ma corta — X, poi undo/redo,
    /// menu stile e Fatto. L'aiuto vive dentro il menu: cinque bersagli
    /// stanno comodi su 390 punti, sette no. (La versione a due gruppi
    /// flottanti è stata bocciata sul campo: «brutta così spezzata».)
    private var compactBar: some View {
        HStack(spacing: 10) {
            cancelButton
            Spacer()
            undoButton
            redoButton
            compactStyleMenu
            doneButton
        }
    }

    private var regularBar: some View {
        // Anche su iPad usiamo lo stesso modello operativo dell'iPhone: un solo
        // menu per impostazioni/stile e target da dito pieni. I menu multipli
        // funzionavano visivamente, ma in pratica rendevano la top bar troppo
        // difficile da colpire quando il canvas sottostante prendeva gesti.
        //
        // Manteniamo comunque il contenitore regolare per lasciare alla barra
        // iPad una larghezza prevedibile e una superficie legacy coerente.
        LiquidGlassContainer(spacing: 12) {
            HStack(spacing: 12) {
                cancelButton

                Spacer()

                undoButton
                redoButton
                compactStyleMenu

                doneButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .modifier(BarSheetOnlyWhenLegacy(
            shape: RoundedRectangle(cornerRadius: 22, style: .continuous),
            border: Color.white.opacity(0.28),
            shadow: GlassChromeShadow(color: .black.opacity(0.14), radius: 18, y: 8)
        ))
    }

    private var cancelButton: some View {
        topBarCircleButton(icon: "xmark", action: onCancel)
    }

    private var helpButton: some View {
        topBarCircleButton(icon: "info.circle", action: onHelp)
    }

    private var undoButton: some View {
        topBarCircleButton(icon: "arrow.uturn.backward",
                           foreground: canUndo ? .primary : .secondary,
                           isEnabled: canUndo,
                           action: onUndo)
    }

    private var redoButton: some View {
        topBarCircleButton(icon: "arrow.uturn.forward",
                           foreground: canRedo ? .primary : .secondary,
                           isEnabled: canRedo,
                           action: onRedo)
    }

    private func topBarCircleButton(icon: String,
                                    foreground: Color = .primary,
                                    isEnabled: Bool = true,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: topBarIconSide, height: topBarIconSide)
                .background(.regularMaterial, in: Circle())
                .background(Color.primary.opacity(isEnabled ? 0.06 : 0.025), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    /// I tre menu di stile dell'iPad, ognuno con la propria superficie: è la
    /// condizione perché il sollevamento del popover prenda solo lui.
    @ViewBuilder
    private var styleMenus: some View {
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
                        .frame(width: topBarIconSide, height: topBarIconSide)
                        .modifier(ToolbarItemSurface(
                            shape: Circle(),
                            tint: exportRotation == .asDrawn ? nil : BrandColor.primary,
                            legacyFill: exportRotation == .asDrawn
                                ? Color.primary.opacity(0.07)
                                : BrandColor.primary.opacity(0.12)
                        ))
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
                    .frame(height: topBarIconSide)
                    // Lo stile "architectural dark" resta un riempimento pieno
                    // anche col vetro: qui il colore non decora, mostra quale
                    // fondo avrà l'export. Una tinta traslucida lo falserebbe.
                    .modifier(ToolbarItemSurface(
                        shape: Capsule(),
                        tint: isDark ? nil : (isNonStandard ? BrandColor.primary : nil),
                        opaqueFill: isDark ? Color(red: 0.10, green: 0.13, blue: 0.18) : nil,
                        legacyFill: isDark
                            ? Color(red: 0.10, green: 0.13, blue: 0.18)
                            : (isNonStandard ? BrandColor.primary.opacity(0.14) : Color.primary.opacity(0.10))
                    ))
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
                            .frame(width: topBarIconSide, height: topBarIconSide)
                            .modifier(ToolbarItemSurface(
                                shape: Circle(),
                                tint: exteriorFillColorIndex >= 0 ? BrandColor.primary : nil,
                                legacyFill: exteriorFillColorIndex >= 0
                                    ? BrandColor.primary.opacity(0.12)
                                    : Color.primary.opacity(0.07)
                            ))
                    }
                    .buttonStyle(.plain)
                    .disabled(isExporting)
                }
    }

    /// Done resta un riempimento pieno di brand, non vetro: è l'azione
    /// primaria della schermata e deve staccare dagli altri item.
    private var doneButton: some View {
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
            .frame(minHeight: topBarIconSide)
            .padding(.vertical, isCompact ? 0 : 8)
            .background(isExporting ? Color.secondary : BrandColor.primary, in: Capsule())
        }
        .disabled(isExporting)
        .buttonStyle(.plain)
    }

    /// Su iPhone tre menu affiancati sono la barra intera: diventano sottomenu
    /// di un unico bottone. Essendo UN solo `Menu`, la regola «mai due Menu
    /// sulla stessa superficie» è rispettata gratis.
    private var compactStyleMenu: some View {
        Menu {
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
                Label(String(localized: "drawing.topbar.rotation", defaultValue: "Rotation"),
                      systemImage: exportRotation.iconName)
            }

            Menu {
                ForEach(DrawingVisualExportStyle.toolbarVisibleStyles) { style in
                    Button {
                        onVisualExportStyleChange(style)
                    } label: {
                        Label {
                            Text(style.localizedTitle)
                        } icon: {
                            Image(systemName: style == visualExportStyle ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            } label: {
                Label(String(localized: "drawing.topbar.style", defaultValue: "Style"),
                      systemImage: visualExportStyle.toolbarIconName)
            }

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
                    Label(String(localized: "drawing.topbar.exterior", defaultValue: "Surroundings"),
                          systemImage: "building.2")
                }
            }
            Divider()
            Button(action: onHelp) {
                Label(String(localized: "drawing.topbar.help", defaultValue: "Guide"),
                      systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: topBarIconSide, height: topBarIconSide)
                .modifier(ToolbarItemSurface(shape: Circle(),
                                             legacyFill: Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .disabled(isExporting)
    }
}

// MARK: - Superfici delle barre di disegno

/// Sfondo della barra, presente **solo** senza vetro.
///
/// Col vetro la barra non ha superficie propria: ce l'hanno i singoli item. È
/// la condizione perché un `Menu` sollevi solo sé stesso invece dell'intera
/// barra — vedi la nota in `ToolbarItemSurface`.
private struct BarSheetOnlyWhenLegacy<S: InsettableShape>: ViewModifier {
    let shape: S
    var fill: AnyShapeStyle = AnyShapeStyle(.regularMaterial)
    var border: Color?
    var shadow: GlassChromeShadow?

    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
    private var isLiquidGlassEnabled = false
    @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLiquidGlassEnabled, !isLiquidGlassSuppressed, #available(iOS 26.0, *) {
            content
        } else {
            content
                .background(fill, in: shape)
                .overlay {
                    if let border {
                        shape.strokeBorder(border, lineWidth: 1)
                    }
                }
                .shadow(color: shadow?.color ?? .clear,
                        radius: shadow?.radius ?? 0,
                        x: 0,
                        y: shadow?.y ?? 0)
        }
    }
}

/// Superficie di un singolo item di barra.
///
/// **Ogni item ne ha una propria, e questo è un requisito funzionale, non una
/// scelta estetica.** Un `Menu` solleva dentro il proprio popover la superficie
/// di vetro a cui è ancorato: con una lastra condivisa spariscono tutti gli item
/// che la condividono finché il menu resta aperto. Con una superficie per item
/// si solleva solo il bottone toccato.
///
/// `opaqueFill` serve al caso in cui il colore non decora ma **informa** — la
/// pastiglia dello stile "architectural dark" mostra il fondo che avrà l'export,
/// e una tinta traslucida lo rappresenterebbe male.
private struct ToolbarItemSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?
    var opaqueFill: Color?
    var legacyFill: Color

    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
    private var isLiquidGlassEnabled = false
    @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLiquidGlassEnabled, !isLiquidGlassSuppressed, #available(iOS 26.0, *) {
            if let opaqueFill {
                content.background(opaqueFill, in: shape)
            } else {
                content.glassEffect(tint.map { .regular.tint($0.opacity(0.22)) } ?? .regular,
                                    in: shape)
            }
        } else {
            content.background(legacyFill, in: shape)
        }
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
        .glassChromeSurface(
            in: Capsule(),
            legacyBorder: tint.opacity(0.28),
            legacyShadow: GlassChromeShadow(color: .black.opacity(0.10), radius: 10, y: 4)
        )
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
            Image(systemName: kind.systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(BrandColor.primary)

            Text(String(localized: "drawing.banner.opening",
                        defaultValue: "Tap a wall to add: \(kind.localizedName)"))
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
        .glassChromeSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }

    @Binding var mode: DrawingMode
    @Binding var wallKind: WallKind
    @Binding var vertexSnapEnabled: Bool
    @Binding var furnitureKind: FurnitureKind
    @Binding var showDimensions: Bool
    var hasSelection: Bool
    var onDelete: () -> Void

    var body: some View {
        if isCompact {
            compactToolbar
        } else {
            regularToolbar
        }
    }

    // MARK: iPad — tutto espanso

    private var regularToolbar: some View {
        // Stessa struttura della barra superiore: nessuna superficie sulla
        // barra, una per item o per gruppo, tutto dentro un container che ne
        // fonde le superfici vicine. Qui c'è un `Menu` (scelta del mobile) e
        // vale la stessa regola: tiene la propria superficie, così il
        // sollevamento nel popover prende solo lui.
        LiquidGlassContainer(spacing: 16) {
            toolbarItems
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(BarSheetOnlyWhenLegacy(
            shape: Rectangle(),
            fill: AnyShapeStyle(.ultraThinMaterial)
        ))
        .animation(.spring(response: 0.3), value: hasSelection)
    }

    private var toolbarItems: some View {
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
            // Il gruppo segmentato tiene UNA superficie condivisa: non contiene
            // Menu, quindi non c'è nulla da sollevare, e la lettura "segmenti di
            // un unico controllo" è proprio ciò che deve dare.
            .glassChromeSurface(
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                legacyFill: AnyShapeStyle(.ultraThinMaterial),
                legacyBorder: Color.white.opacity(0.2)
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
                    wallKindButton(kind: .logical, icon: "divide",
                                   label: String(localized: "drawing.toolbar.wall.logical", defaultValue: "Logico"))
                }
                .glassChromeSurface(
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                    legacyFill: AnyShapeStyle(.ultraThinMaterial),
                    legacyBorder: Color.white.opacity(0.2)
                )
                // Sola opacità, mai scala: scalare una superficie di vetro ne
                // cambia la geometria a ogni fotogramma e la costringe a
                // rivalutarsi altrettante volte.
                .transition(.opacity)
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
                // Sola opacità: questi elementi entrano ed escono DENTRO la
                // barra, che ora è una superficie di vetro. Scalarli le cambia
                // la geometria a ogni fotogramma e la costringe a rivalutarsi
                // altrettante volte.
                .transition(.opacity)
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
                openingButton(kind: .slidingDoor,
                              icon: "door.sliding.right.hand.closed",
                              label: String(localized: "drawing.toolbar.slidingDoor", defaultValue: "Sliding"))
                openingButton(kind: .frenchDoor,
                              icon: "door.french.open",
                              label: String(localized: "drawing.toolbar.frenchDoor", defaultValue: "French"))
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
                        .glassChromeSurface(
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                            legacyFill: AnyShapeStyle(.ultraThinMaterial)
                        )
                }
                // Sola opacità, mai scala: vale per ogni superficie di vetro.
                .transition(.opacity)
            }
        }
    }


    // MARK: iPhone — il dock

    /// Gli stessi strumenti dell'iPad, compressi per il pollice: le quattro
    /// aperture dietro un menu, snap e quote dietro «Altro», il tipo di muro
    /// come pillola che compare solo col Muro in mano. Su iPad tutto espanso
    /// è comodo; qui i compromessi sono il design, non un ripiego.
    private var compactToolbar: some View {
        LiquidGlassContainer(spacing: 10) {
            HStack(spacing: 8) {
                compactSlot(icon: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left",
                            label: String(localized: "drawing.toolbar.mode.select", defaultValue: "Select"),
                            active: mode == .select) {
                    mode = .select
                }

                compactWallKindMenu

                compactOpeningMenu

                compactSlot(icon: "rectangle.dashed",
                            label: String(localized: "drawing.toolbar.roomArea", defaultValue: "Room"),
                            active: mode == .drawRoomArea) {
                    mode = mode == .drawRoomArea ? .select : .drawRoomArea
                }

                compactFurnitureMenu

                if hasSelection {
                    Button(action: onDelete) {
                        compactIconLabel(icon: "trash",
                                         label: String(localized: "common.delete", defaultValue: "Delete"),
                                         active: false,
                                         foreground: .red)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                } else {
                    compactMoreMenu
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .modifier(BarSheetOnlyWhenLegacy(
            shape: Rectangle(),
            fill: AnyShapeStyle(.ultraThinMaterial)
        ))
        .animation(.spring(response: 0.3), value: hasSelection)
        .animation(.spring(response: 0.3), value: mode)
    }

    private var compactWallKindMenu: some View {
        Menu {
            compactWallKindEntry(kind: .exterior,
                                 icon: "square.on.square",
                                 label: String(localized: "drawing.toolbar.wall.exterior", defaultValue: "Perim."))
            compactWallKindEntry(kind: .interior,
                                 icon: "square.dashed",
                                 label: String(localized: "drawing.toolbar.wall.interior", defaultValue: "Interior"))
            compactWallKindEntry(kind: .balcony,
                                 icon: "line.diagonal",
                                 label: String(localized: "drawing.toolbar.wall.balcony", defaultValue: "Balcony"))
            compactWallKindEntry(kind: .logical,
                                 icon: "divide",
                                 label: String(localized: "drawing.toolbar.wall.logical", defaultValue: "Logical"))
        } label: {
            compactIconLabel(icon: wallKindIconName,
                             label: String(localized: "drawing.toolbar.mode.draw", defaultValue: "Wall"),
                             active: mode == .draw)
        }
        .buttonStyle(.plain)
    }

    private func compactWallKindEntry(kind: WallKind, icon: String, label: String) -> some View {
        Button {
            wallKind = kind
            mode = .draw
        } label: {
            Label {
                Text(label)
            } icon: {
                Image(systemName: wallKind == kind ? "checkmark.circle.fill" : icon)
            }
        }
    }

    private var wallKindIconName: String {
        switch wallKind {
        case .exterior: return "square.on.square"
        case .interior: return "square.dashed"
        case .balcony: return "line.diagonal"
        case .logical: return "divide"
        }
    }

    /// Le quattro aperture dietro un solo slot: su 390 punti quattro bottoni
    /// da 68 sarebbero la barra intera.
    private var compactOpeningMenu: some View {
        let isPlacing: Bool
        if case .placeOpening = mode { isPlacing = true } else { isPlacing = false }
        return Menu {
            compactOpeningEntry(.door, icon: "door.left.hand.open",
                                label: String(localized: "drawing.toolbar.door", defaultValue: "Door"))
            compactOpeningEntry(.slidingDoor, icon: "door.sliding.right.hand.closed",
                                label: String(localized: "drawing.toolbar.slidingDoor", defaultValue: "Sliding"))
            compactOpeningEntry(.frenchDoor, icon: "door.french.open",
                                label: String(localized: "drawing.toolbar.frenchDoor", defaultValue: "French"))
            compactOpeningEntry(.window, icon: "rectangle.split.2x1",
                                label: String(localized: "drawing.toolbar.window", defaultValue: "Window"))
        } label: {
            compactIconLabel(icon: "door.left.hand.open",
                             label: String(localized: "drawing.toolbar.opening", defaultValue: "Opening"),
                             active: isPlacing)
        }
        .buttonStyle(.plain)
    }

    private func compactOpeningEntry(_ kind: OpeningKind, icon: String, label: String) -> some View {
        let isActive: Bool
        if case .placeOpening(let k) = mode { isActive = k == kind } else { isActive = false }
        return Button {
            mode = isActive ? .select : .placeOpening(kind)
        } label: {
            Label {
                Text(label)
            } icon: {
                Image(systemName: isActive ? "checkmark.circle.fill" : icon)
            }
        }
    }

    private var compactFurnitureMenu: some View {
        Menu {
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
            compactIconLabel(icon: furnitureKind.systemImage,
                             label: furnitureKind.localizedName,
                             active: mode == .placeFurniture)
        }
        .buttonStyle(.plain)
    }

    /// Snap e quote: interruttori che si toccano una volta a sessione, non
    /// meritano uno slot ciascuno sulla larghezza di un telefono.
    private var compactMoreMenu: some View {
        Menu {
            Toggle(isOn: $vertexSnapEnabled) {
                Label(String(localized: "drawing.toolbar.snap", defaultValue: "Snap"),
                      systemImage: "point.topleft.down.curvedto.point.bottomright.up")
            }
            Toggle(isOn: $showDimensions) {
                Label(String(localized: "drawing.toolbar.dimensions", defaultValue: "Quote"),
                      systemImage: "ruler")
            }
        } label: {
            compactIconLabel(icon: "ellipsis",
                             label: String(localized: "drawing.toolbar.more", defaultValue: "More"),
                             active: false)
        }
        .buttonStyle(.plain)
    }

    private func compactSlot(icon: String, label: String, active: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            compactIconLabel(icon: icon, label: label, active: active)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25), value: active)
    }

    private func compactIconLabel(icon: String,
                                  label: String,
                                  active: Bool,
                                  foreground: Color = Color.primary) -> some View {
        Image(systemName: icon)
            .font(.system(size: 20, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? BrandColor.primary : foreground)
            .frame(width: 52, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(active ? BrandColor.primary.opacity(0.15) : Color(.systemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(active ? BrandColor.primary.opacity(0.5) : Color.clear,
                                  lineWidth: 1.5)
            )
            .contentShape(Rectangle())
            .accessibilityLabel(label)
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
        .glassChromeSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                            defaultValue: "Tap inside a closed room, or drag an area"))
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
        .glassChromeSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        case .erba:       return Color(red: 0.62, green: 0.78, blue: 0.55).opacity(0.65)
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
        .glassChromeSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    /// Called with the exact new geometry: length in canvas points and the
    /// direction angle in canvas radians. Rotates/resizes around the start point.
    var onSetGeometry: (CGFloat, Double) -> Void

    @AppStorage(DimensionUnit.appStorageKey)
    private var dimensionUnitRaw: String = DimensionUnit.metric.rawValue

    @State private var lengthInput: Double = 0
    @State private var angleInput: Double = 0

    private var dimensionUnit: DimensionUnit {
        DimensionUnit(rawValue: dimensionUnitRaw) ?? .metric
    }

    private var gridUnits: Int {
        max(1, Int(round(wall.length / DrawingDocument.gridSpacing)))
    }

    /// Wall length expressed in the user's unit (metres or decimal feet).
    private var currentLengthInUnit: Double {
        let meters = Double(wall.length / DrawingDocument.ptsPerMeter)
        return dimensionUnit == .metric ? meters : meters / 0.3048
    }

    /// Direction angle in protractor convention (counterclockwise positive,
    /// 0° pointing right), folded to [0, 360).
    private var currentAngleDegrees: Double {
        let deg = -atan2(Double(wall.end.y - wall.start.y),
                         Double(wall.end.x - wall.start.x)) * 180 / .pi
        return (deg < 0 ? deg + 360 : deg)
    }

    private func applyGeometry() {
        let meters = dimensionUnit == .metric ? lengthInput : lengthInput * 0.3048
        let lengthPt = CGFloat(meters) * DrawingDocument.ptsPerMeter
        guard lengthPt >= 5 else { return }
        let angleRadians = -angleInput * .pi / 180
        onSetGeometry(lengthPt, angleRadians)
    }

    private func setLengthKeepingAngle(_ value: Double) {
        let meters = dimensionUnit == .metric ? value : value * 0.3048
        let lengthPt = CGFloat(meters) * DrawingDocument.ptsPerMeter
        guard lengthPt >= 5 else { return }
        let angleRadians = -currentAngleDegrees * .pi / 180
        onSetGeometry(lengthPt, angleRadians)
    }

    private func refreshInputs() {
        lengthInput = (currentLengthInUnit * 100).rounded() / 100
        angleInput = (currentAngleDegrees * 10).rounded() / 10
    }

    private var kindLabel: String {
        switch wall.kind {
        case .exterior: return String(localized: "drawing.inspector.wall.kind.exterior", defaultValue: "Exterior wall")
        case .interior: return String(localized: "drawing.inspector.wall.kind.interior", defaultValue: "Interior wall")
        case .balcony:  return String(localized: "drawing.inspector.wall.kind.balcony",  defaultValue: "Balcony / terrace")
        case .logical:  return String(localized: "drawing.inspector.wall.kind.logical",  defaultValue: "Logical divider")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    value: Binding(
                        get: { currentLengthInUnit },
                        set: { setLengthKeepingAngle($0) }
                    ),
                    in: (dimensionUnit == .metric ? 0.05 : 0.16)...50,
                    step: dimensionUnit == .metric ? 0.05 : 0.25
                ) { EmptyView() }
                .labelsHidden()
            }

            // Precise geometry input: length in the current unit + protractor angle.
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    TextField("", value: $lengthInput, format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        .onSubmit(applyGeometry)
                    Text(dimensionUnit == .metric ? "m" : "ft")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 3) {
                    TextField("", value: $angleInput, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        .onSubmit(applyGeometry)
                    Text("°")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    applyGeometry()
                } label: {
                    Text(String(localized: "drawing.inspector.wall.apply", defaultValue: "Set"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(BrandColor.primary.opacity(0.12), in: Capsule())
                        .foregroundStyle(BrandColor.primary)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear { refreshInputs() }
        .onChange(of: wall) { _, _ in refreshInputs() }
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
