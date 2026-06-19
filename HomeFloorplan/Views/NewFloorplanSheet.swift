import SwiftUI
import SwiftData
import HomeKit

struct NewFloorplanSheet: View {
    /// Called after a successful save with the new floorplan's UUID.
    var onSaved: ((UUID) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(HomeKitService.self) private var homeKit

    @State private var name: String = ""
    @State private var selectedImage: UIImage?
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var showDrawingEditor = false
    @State private var linkedRooms: [LinkedRoom] = []
    @State private var savedDrawingDocument: DrawingDocument?

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
            .fullScreenCover(isPresented: $showDrawingEditor) {
                DrawingFloorplanSheet(initialDocument: savedDrawingDocument) { drawnImage, rooms, doc in
                    selectedImage = drawnImage
                    linkedRooms = rooms
                    savedDrawingDocument = doc
                    if name.trimmingCharacters(in: .whitespaces).isEmpty {
                        name = String(localized: "floorplan.drawn.defaultName", defaultValue: "Drawn floorplan")
                    }
                }
                .ignoresSafeArea()
            }
        }
        .suppressesIdleScreensaver(.modalPresentation)
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
            modelContext.insert(floorplan)
            try modelContext.save()
            let savedID = floorplan.id
            dismiss()
            onSaved?(savedID)
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
