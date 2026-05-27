import SwiftUI
import SwiftData
import PhotosUI
import HomeKit
import RoomPlan

struct NewFloorplanSheet: View {
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
                    
                    // Opzione 2: RoomPlan scan (solo se LiDAR disponibile)
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
            .fullScreenCover(isPresented: $showRoomCapture) {
                RoomCaptureSheetView(
                    onCompletion: { capturedStructure in        // 👈 ora CapturedStructure
                        showRoomCapture = false
                        Task {
                            await processCapturedStructure(capturedStructure)   // 👈 nuovo nome
                        }
                    },
                    onCancel: {
                        showRoomCapture = false
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
        
        do {
            // Genera debug plan PRIMA del render
            let plan = try RoomPlanExportService.buildPlan(structure: structure)
            debugPlan = plan
            
            let image = try RoomPlanExportService.exportAsImage(structure: structure)
            selectedImage = image
            errorMessage = nil
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                let count = structure.rooms.count
                name = count > 1 ? "Piano (\(count) stanze)" : "Stanza scansionata"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
            modelContext.insert(floorplan)
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
