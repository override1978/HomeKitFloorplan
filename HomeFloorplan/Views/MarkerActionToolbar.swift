import SwiftUI

struct MarkerAuditNotice {
    let systemImage: String
    let title: String
    let message: String
    let tint: Color
    let actionTitle: String?
}

struct MarkerActionToolbar: View {
    let markerName: String
    let initialRenameText: String
    let onRename: (String) -> Void
    let onResetName: () -> Void
    let onRecenter: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void
    let onChangeIcon: () -> Void
    let auditNotice: MarkerAuditNotice?
    let onResolveAudit: (() -> Void)?
    
    @State private var renamePopoverPresented: Bool = false
    @State private var auditPopoverPresented: Bool = false
    @State private var renameDraft: String = ""
    @FocusState private var renameFieldFocused: Bool

    init(markerName: String,
         initialRenameText: String,
         onRename: @escaping (String) -> Void,
         onResetName: @escaping () -> Void,
         onRecenter: @escaping () -> Void,
         onDelete: @escaping () -> Void,
         onDismiss: @escaping () -> Void,
         onChangeIcon: @escaping () -> Void,
         auditNotice: MarkerAuditNotice? = nil,
         onResolveAudit: (() -> Void)? = nil) {
        self.markerName = markerName
        self.initialRenameText = initialRenameText
        self.onRename = onRename
        self.onResetName = onResetName
        self.onRecenter = onRecenter
        self.onDelete = onDelete
        self.onDismiss = onDismiss
        self.onChangeIcon = onChangeIcon
        self.auditNotice = auditNotice
        self.onResolveAudit = onResolveAudit
    }
    
    var body: some View {
        GlassTitlePill {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "marker.toolbar.selected", defaultValue: "Selected"))
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

                if let auditNotice {
                    Button {
                        auditPopoverPresented = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: auditNotice.systemImage)
                            Text(String(localized: "marker.toolbar.audit", defaultValue: "Check"))
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(auditNotice.tint)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $auditPopoverPresented,
                             attachmentAnchor: .point(.top),
                             arrowEdge: .bottom) {
                        auditPopoverContent(auditNotice)
                    }

                    Divider().frame(height: 24)
                }
                
                Button {
                    renameDraft = initialRenameText
                    renamePopoverPresented = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                        Text(String(localized: "common.rename", defaultValue: "Rename"))
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
                
                toolbarButton(systemImage: "scope", label: String(localized: "marker.toolbar.center", defaultValue: "Center"), action: onRecenter)
                
                Divider().frame(height: 24)
                
                toolbarButton(systemImage: "photo.on.rectangle", label: String(localized: "marker.toolbar.icon", defaultValue: "Icon"), action: onChangeIcon)

                Divider().frame(height: 24)
                
                toolbarButton(systemImage: "trash", label: String(localized: "common.delete", defaultValue: "Delete"),
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
        .suppressesIdleScreensaver(
            .floorplanInteraction,
            when: renamePopoverPresented || auditPopoverPresented
        )
    }

    private func auditPopoverContent(_ notice: MarkerAuditNotice) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.systemImage)
                    .font(.headline)
                    .foregroundStyle(notice.tint)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title)
                        .font(.subheadline.weight(.semibold))
                    Text(notice.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let actionTitle = notice.actionTitle, let onResolveAudit {
                HStack {
                    Spacer()
                    Button(actionTitle) {
                        onResolveAudit()
                        auditPopoverPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }
    
    private var renamePopoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "marker.rename.title", defaultValue: "Rename marker"))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(String(localized: "marker.rename.shortHelp", defaultValue: "Leave empty to use the original name"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            TextField(String(localized: "marker.rename.placeholder", defaultValue: "Label"), text: $renameDraft)
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
                
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    renamePopoverPresented = false
                }
                .buttonStyle(.bordered)
                
                Button(String(localized: "common.save", defaultValue: "Save")) {
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
