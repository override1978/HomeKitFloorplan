import SwiftUI

struct RenameFloorplanSheet: View {
    let currentName: String
    let onSave: (String) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var focused: Bool
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "floorplan.name.placeholder", defaultValue: "Floorplan name"), text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                } header: {
                    Text(String(localized: "common.name", defaultValue: "Name"))
                } footer: {
                    Text("Es. \"Piano terra\", \"Mansarda\", \"Garage\".")
                }
            }
            .navigationTitle(String(localized: "floorplan.rename.title", defaultValue: "Rename floorplan"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.save", defaultValue: "Save")) { save() }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                text = currentName
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    focused = true
                }
            }
        }
    }
    
    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
