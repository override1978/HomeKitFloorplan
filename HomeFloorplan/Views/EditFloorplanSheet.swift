import SwiftUI
import PhotosUI
import SwiftData

/// Pannello unico per modificare nome e immagine di un Floorplan.
/// Anteprima immagine in cima (tappabile per cambiarla), campo nome sotto,
/// Salva/Annulla in toolbar.
struct EditFloorplanSheet: View {
    @Bindable var floorplan: Floorplan
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var nameDraft: String = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var pendingImage: UIImage?
    @State private var hasUnsavedChanges: Bool = false
    @FocusState private var nameFieldFocused: Bool
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        currentImagePreview
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text(String(localized: "floorplan.image.header", defaultValue: "Image"))
                } footer: {
                    Text(String(localized: "floorplan.image.footer",
                                defaultValue: "Tap the image to replace it. Existing markers will keep their relative position."))
                }
                
                Section {
                    TextField(String(localized: "floorplan.name.placeholder", defaultValue: "Floorplan name"), text: $nameDraft)
                        .focused($nameFieldFocused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                        .onChange(of: nameDraft) { _, _ in
                            hasUnsavedChanges = true
                        }
                } header: {
                    Text(String(localized: "common.name", defaultValue: "Name"))
                } footer: {
                    Text(String(localized: "floorplan.name.examples",
                                defaultValue: "E.g. \"Ground floor\", \"Attic\", \"Garage\"."))
                }
            }
            .navigationTitle(String(localized: "floorplan.edit.title", defaultValue: "Edit floorplan"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.save", defaultValue: "Save")) { save() }
                        .disabled(!canSave)
                }
            }
            .task(id: pickerItem) {
                await loadSelectedImage()
            }
            .onAppear {
                nameDraft = floorplan.name
            }
        }
        .suppressesIdleScreensaver(.modalPresentation)
    }
    
    @ViewBuilder
    private var currentImagePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.secondary.opacity(0.1))
            
            if let pendingImage {
                // Anteprima della nuova immagine selezionata, non ancora salvata
                Image(uiImage: pendingImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if let current = ImageStorageService.load(filename: floorplan.imageFilename) {
                Image(uiImage: current)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(4/3, contentMode: .fit)
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                Image(systemName: "photo.badge.plus")
                    .font(.caption)
                Text(pendingImage != nil ? "Nuova" : "Tocca per cambiare")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
        }
    }
    
    private var canSave: Bool {
        let trimmedName = nameDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return false }
        // Si può salvare se c'è almeno una modifica reale
        return trimmedName != floorplan.name || pendingImage != nil
    }
    
    private func loadSelectedImage() async {
        guard let pickerItem else { return }
        do {
            if let data = try await pickerItem.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                pendingImage = image
                hasUnsavedChanges = true
            }
        } catch {
            dprint("Errore caricamento immagine: \(error)")
        }
    }
    
    private func save() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        
        // Aggiorna nome se cambiato
        if !trimmed.isEmpty && trimmed != floorplan.name {
            floorplan.name = trimmed
        }
        
        // Aggiorna immagine se cambiata
        if let pendingImage {
            do {
                ImageStorageService.delete(filename: floorplan.imageFilename)
                let newFilename = try ImageStorageService.save(pendingImage)
                floorplan.imageFilename = newFilename
            } catch {
                dprint("Errore salvataggio nuova immagine: \(error)")
            }
        }
        
        floorplan.updatedAt = .now
        try? modelContext.save()
        dismiss()
    }
}
