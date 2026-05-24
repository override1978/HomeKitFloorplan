import SwiftUI

struct MarkerActionToolbar: View {
    let markerName: String
    let initialRenameText: String
    let onRename: (String) -> Void
    let onResetName: () -> Void
    let onRecenter: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void
    let onChangeIcon: () -> Void
    
    @State private var renamePopoverPresented: Bool = false
    @State private var renameDraft: String = ""
    @FocusState private var renameFieldFocused: Bool
    
    var body: some View {
        GlassPill {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Selezionato")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(markerName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                
                Divider().frame(height: 24)
                
                Button {
                    renameDraft = initialRenameText
                    renamePopoverPresented = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                        Text("Rinomina")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $renamePopoverPresented,
                         attachmentAnchor: .point(.top),
                         arrowEdge: .bottom) {
                    renamePopoverContent
                }
                
                Divider().frame(height: 24)
                
                toolbarButton(systemImage: "scope", label: "Centra", action: onRecenter)
                
                Divider().frame(height: 24)
                
                toolbarButton(systemImage: "photo.on.rectangle", label: "Icona", action: onChangeIcon)   // 👈 NUOVO

                Divider().frame(height: 24)
                
                toolbarButton(systemImage: "trash", label: "Elimina",
                              tint: .red, action: onDelete)
                
                Divider().frame(height: 24)
                
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 52)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    
    private var renamePopoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rinomina marker")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("Lascia vuoto per usare il nome originale")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            TextField("Etichetta", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .focused($renameFieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    onRename(renameDraft)
                    renamePopoverPresented = false
                }
            
            HStack(spacing: 8) {
                if !initialRenameText.isEmpty {
                    Button(role: .destructive) {
                        onResetName()
                        renamePopoverPresented = false
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.bordered)
                }
                
                Spacer()
                
                Button("Annulla") {
                    renamePopoverPresented = false
                }
                .buttonStyle(.bordered)
                
                Button("Salva") {
                    onRename(renameDraft)
                    renamePopoverPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                renameFieldFocused = true
            }
        }
    }
    
    @ViewBuilder
    private func toolbarButton(systemImage: String,
                               label: String,
                               tint: Color? = nil,
                               action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(label)
            }
            .font(.subheadline)
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
