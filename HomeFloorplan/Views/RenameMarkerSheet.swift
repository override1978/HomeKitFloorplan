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
                    TextField(String(localized: "marker.rename.placeholder", defaultValue: "Custom label"), text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit {
                            onSave(text)
                        }
                } header: {
                    Text(String(localized: "marker.rename.section", defaultValue: "Label"))
                } footer: {
                    Text(String(localized: "marker.rename.footer", defaultValue: "Leave empty to use the original HomeKit accessory name."))
                }
                
                if !initialText.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            onReset()
                        } label: {
                            Label(String(localized: "marker.rename.resetOriginal", defaultValue: "Restore original name"), systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "marker.rename.title", defaultValue: "Rename marker"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.save", defaultValue: "Save")) { onSave(text) }
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
