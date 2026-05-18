import SwiftUI
import SwiftData
import PhotosUI

struct NewFloorplanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var name: String = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var isSaving = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") {
                    TextField("Es. Piano terra", text: $name)
                        .autocorrectionDisabled()
                }
                
                Section("Immagine planimetria") {
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
                            Label("Scegli immagine", systemImage: "photo.badge.plus")
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
    
    private func save() {
        guard let image = selectedImage else { return }
        isSaving = true
        do {
            let filename = try ImageStorageService.save(image)
            let floorplan = Floorplan(
                name: name.trimmingCharacters(in: .whitespaces),
                imageFilename: filename
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
