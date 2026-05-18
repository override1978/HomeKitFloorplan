import SwiftUI

struct RenameMarkerSheet: View {
    let placed: PlacedAccessory
    let initialText: String
    let onSave: (String) -> Void
    let onReset: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var focused: Bool
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Etichetta personalizzata", text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit {
                            onSave(text)
                        }
                } header: {
                    Text("Etichetta")
                } footer: {
                    Text("Lascia vuoto per usare il nome originale dell'accessorio HomeKit.")
                }
                
                if !initialText.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            onReset()
                        } label: {
                            Label("Ripristina nome originale", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }
            .navigationTitle("Rinomina marker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") { onSave(text) }
                }
            }
            .onAppear {
                text = initialText
                // Piccolo delay per essere sicuri che la sheet sia visibile prima del focus
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focused = true
                }
            }
        }
    }
}
