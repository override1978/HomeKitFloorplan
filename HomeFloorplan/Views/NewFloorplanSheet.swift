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
                Section("Nome") {
                    TextField("Es. Piano terra", text: $name)
                        .autocorrectionDisabled()
                }

                Section {
                    Button {
                        showDrawingEditor = true
                    } label: {
                        HStack {
                            Label(
                                selectedImage == nil
                                    ? "Disegna planimetria"
                                    : "Modifica planimetria",
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
                    Text("Planimetria")
                } footer: {
                    Text("Disegna le stanze e collegale agli ambienti HomeKit.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Nuovo floorplan")
            .navigationBarTitleDisplayMode(.inline)
            .tint(BrandColor.primary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crea") { save() }
                        .disabled(!canSave || isSaving)
                }
            }
            .fullScreenCover(isPresented: $showDrawingEditor) {
                DrawingFloorplanSheet(initialDocument: savedDrawingDocument) { drawnImage, rooms, doc in
                    selectedImage = drawnImage
                    linkedRooms = rooms
                    savedDrawingDocument = doc
                    if name.trimmingCharacters(in: .whitespaces).isEmpty {
                        name = "Planimetria disegnata"
                    }
                }
                .ignoresSafeArea()
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
