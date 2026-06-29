import SwiftUI
import SwiftData
import HomeKit

struct NewFloorplanSheet: View {
    /// Called after a successful save with the new floorplan's UUID.
    var onSaved: ((UUID) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(HomeKitService.self) private var homeKit
    @Query(sort: \Floorplan.createdAt, order: .reverse) private var existingFloorplans: [Floorplan]
    @AppStorage("primaryFloorplanID") private var primaryFloorplanID: String = ""
    @AppStorage("pinnedFloorplanIDs") private var pinnedFloorplanIDsRaw: String = "[]"

    @State private var name: String = ""
    @State private var selectedImage: UIImage?
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var showDrawingEditor = false
    @State private var showImageDraftImport = false
    @State private var linkedRooms: [LinkedRoom] = []
    @State private var savedDrawingDocument: DrawingDocument?
    @State private var savedExteriorFillColorIndex: Int = -1
    @State private var savedVisualExportStyle: DrawingVisualExportStyle = .standard
    @State private var savedExportRotation: DrawingExportRotation = .asDrawn

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "common.name", defaultValue: "Name")) {
                    TextField(String(localized: "floorplan.name.example", defaultValue: "E.g. Ground floor"), text: $name)
                        .autocorrectionDisabled()
                }

                Section {
                    Button {
                        showDrawingEditor = true
                    } label: {
                        HStack {
                            Label(
                                selectedImage == nil
                                    ? String(localized: "floorplan.draw.title", defaultValue: "Draw floorplan")
                                    : String(localized: "floorplan.edit.title", defaultValue: "Edit floorplan"),
                                systemImage: "pencil.and.ruler"
                            )
                            .foregroundStyle(BrandColor.primary)
                            Spacer()
                            if selectedImage != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(BrandColor.primary)
                                    .font(.subheadline)
                            } else {
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                } header: {
                    Text(String(localized: "floorplan.section.floorplan", defaultValue: "Floorplan"))
                } footer: {
                    Text(String(localized: "floorplan.draw.footer", defaultValue: "Draw rooms and link them to HomeKit rooms."))
                }

                Section {
                    Button {
                        showImageDraftImport = true
                    } label: {
                        HStack {
                            Label(String(localized: "floorplan.imageDraft.title", defaultValue: "Detect wall draft from image"), systemImage: "wand.and.rays")
                                .foregroundStyle(BrandColor.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                                .font(.caption.weight(.semibold))
                        }
                    }
                } footer: {
                    Text(String(localized: "floorplan.imageDraft.footer", defaultValue: "Import an existing image and detect clear wall segments locally. Review the draft in the 2D editor before saving."))
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "floorplan.new.title", defaultValue: "New floorplan"))
            .navigationBarTitleDisplayMode(.inline)
            .tint(BrandColor.primary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.create", defaultValue: "Create")) { save() }
                        .disabled(!canSave || isSaving)
                }
            }
            .fullScreenCover(isPresented: fullScreenDrawingEditorBinding) {
                drawingEditor
                    .environment(homeKit)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showImageDraftImport) {
                FloorplanImageDraftImportSheet { draftDocument in
                    savedDrawingDocument = draftDocument
                    linkedRooms = []
                    savedExteriorFillColorIndex = -1
                    savedVisualExportStyle = .standard
                    savedExportRotation = .asDrawn
                    if name.trimmingCharacters(in: .whitespaces).isEmpty {
                        name = String(localized: "floorplan.imageDraft.defaultName", defaultValue: "Image wall draft")
                    }
                    showDrawingEditor = true
                }
            }
        }
        .suppressesIdleScreensaver(.modalPresentation)
    }

    private var usesMacModalPresentation: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac
    }

    private var fullScreenDrawingEditorBinding: Binding<Bool> {
        Binding(
            get: { showDrawingEditor },
            set: { if !$0 { showDrawingEditor = false } }
        )
    }

    private var drawingEditor: some View {
        DrawingFloorplanSheet(
            initialDocument: savedDrawingDocument,
            initialExteriorFillColorIndex: savedExteriorFillColorIndex,
            initialVisualExportStyle: savedVisualExportStyle,
            initialExportRotation: savedExportRotation
        ) { drawnImage, rooms, doc, colorIndex, visualStyle, exportRotation in
            selectedImage = drawnImage
            linkedRooms = rooms
            savedDrawingDocument = doc
            savedExteriorFillColorIndex = colorIndex
            savedVisualExportStyle = visualStyle
            savedExportRotation = exportRotation
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                name = String(localized: "floorplan.drawn.defaultName", defaultValue: "Drawn floorplan")
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && selectedImage != nil
    }

    private func save() {
        guard let image = selectedImage else { return }
        isSaving = true
        do {
            let filename = try ImageStorageService.save(image)
            let floorplan = Floorplan(
                name: name.trimmingCharacters(in: .whitespaces),
                imageFilename: filename,
                homeUUID: homeKit.currentHome?.uniqueIdentifier
            )
            if !linkedRooms.isEmpty {
                floorplan.linkedRooms = linkedRooms
            }
            if let doc = savedDrawingDocument {
                floorplan.drawingDocument = doc
            }
            floorplan.exteriorFillColorIndex = savedExteriorFillColorIndex
            floorplan.drawingVisualExportStyleRaw = savedVisualExportStyle.rawValue
            floorplan.drawingExportRotation = savedExportRotation
            modelContext.insert(floorplan)
            try modelContext.save()
            let savedID = floorplan.id
            pinAfterCreation(floorplan)
            dismiss()
            onSaved?(savedID)
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }

    private func pinAfterCreation(_ floorplan: Floorplan) {
        var ids = decodePinnedIDs()
        let key = floorplan.id.uuidString
        if !ids.contains(key) {
            ids.append(key)
            encodePinnedIDs(ids)
        }

        if primaryFloorplanID.isEmpty || isFirstFloorplanInCurrentHome(excluding: floorplan) {
            primaryFloorplanID = key
        }
    }

    private func isFirstFloorplanInCurrentHome(excluding floorplan: Floorplan) -> Bool {
        existingFloorplans.allSatisfy { existing in
            existing.id == floorplan.id || existing.homeUUID != floorplan.homeUUID
        }
    }

    private func decodePinnedIDs() -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(pinnedFloorplanIDsRaw.utf8))) ?? []
    }

    private func encodePinnedIDs(_ ids: [String]) {
        pinnedFloorplanIDsRaw = (try? String(data: JSONEncoder().encode(ids), encoding: .utf8)) ?? "[]"
    }
}
