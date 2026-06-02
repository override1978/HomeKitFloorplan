import SwiftUI
import SwiftData
import PhotosUI
import HomeKit
import RoomPlan

struct NewFloorplanSheet: View {
    /// Called after a successful save with the new floorplan's UUID.
    /// Use this to navigate to the newly created floorplan.
    var onSaved: ((UUID) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(HomeKitService.self) private var homeKit
    
    @State private var name: String = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var isSaving = false
    @State private var errorMessage: String?
    
    @State private var showRoomCapture = false
    @State private var isProcessingScan = false
    @State private var debugPlan: Floorplan2D?

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
                    // Opzione 1: PhotosPicker
                    PhotosPicker(selection: $pickerItem,
                                 matching: .images,
                                 photoLibrary: .shared()) {
                        if let selectedImage {
                            Image(uiImage: selectedImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Label("Scegli dalla galleria", systemImage: "photo.on.rectangle")
                        }
                    }
                    
                    // Opzione 2: Editor 2D
                    Button {
                        showDrawingEditor = true
                    } label: {
                        HStack {
                            Label("Disegna planimetria", systemImage: "pencil.and.ruler")
                                .foregroundStyle(.tint)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                                .font(.caption.weight(.semibold))
                        }
                    }

                    // Opzione 3: RoomPlan scan (solo se LiDAR disponibile)
                    if RoomPlanSupport.isSupported {
                        Button {
                            showRoomCapture = true
                        } label: {
                            HStack {
                                Label("Scansiona con LiDAR", systemImage: "cube.transparent")
                                    .foregroundStyle(.tint)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                } header: {
                    Text("Immagine planimetria")
                } footer: {
                    if RoomPlanSupport.isSupported {
                        Text("Scansiona una stanza camminando lentamente attorno alle pareti. Verrà generato automaticamente un floorplan 2D.")
                    } else {
                        Text("Carica una foto o uno screenshot della tua planimetria.")
                    }
                }
                
                if let debugPlan {
                    Section("Debug planimetria") {
                        FloorplanDebugView(plan: debugPlan)
                            .listRowInsets(EdgeInsets())
                            .padding(.vertical, 4)
                    }
                }
                
                if isProcessingScan {
                    Section {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Elaborazione scansione…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crea") { save() }
                        .disabled(!canSave || isSaving)
                }
            }
            .task(id: pickerItem) {
                await loadSelectedImage()
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
            .fullScreenCover(isPresented: $showRoomCapture) {
                RoomCaptureSheetView(
                    onCompletion: { capturedStructure in
                        showRoomCapture = false
                        Task {
                            await processCapturedStructure(capturedStructure)
                        }
                    },
                    onCancel: {
                        showRoomCapture = false
                    },
                    onError: { message in
                        showRoomCapture = false
                        errorMessage = message
                    }
                )
                .ignoresSafeArea()
            }
        }
    }
    
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && selectedImage != nil
    }
    
    private func loadSelectedImage() async {
        guard let pickerItem else { return }
        do {
            if let data = try await pickerItem.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                selectedImage = image
                errorMessage = nil
            } else {
                errorMessage = "Impossibile caricare l'immagine selezionata."
            }
        } catch {
            errorMessage = "Errore: \(error.localizedDescription)"
        }
    }
    
    private func processCapturedStructure(_ structure: CapturedStructure) async {
        isProcessingScan = true
        defer { isProcessingScan = false }

        // Render 3D top-down via SceneKit — nessun throw, restituisce sempre un'immagine
        let image = RoomPlanExportService.exportAs3DTopDown(structure: structure)
        selectedImage = image
        errorMessage = nil

        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            let count = structure.rooms.count
            name = count > 1 ? "Piano (\(count) stanze)" : "Stanza scansionata"
        }

        // Debug plan 2D ancora visibile in basso (facoltativo, puoi rimuoverlo)
        debugPlan = try? RoomPlanExportService.buildPlan(structure: structure)
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
