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
                    TextField("Nome planimetria", text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                } header: {
                    Text("Nome")
                } footer: {
                    Text("Es. \"Piano terra\", \"Mansarda\", \"Garage\".")
                }
            }
            .navigationTitle("Rinomina planimetria")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") { save() }
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
