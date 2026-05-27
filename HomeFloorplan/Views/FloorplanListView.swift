import SwiftUI
import SwiftData

/// Vista di gestione planimetrie: galleria con miniature.
/// Tap su miniatura → push a FloorplanEditorView (modalità .pushed).
/// Long press → menu con opzioni gestionali.
/// Swipe-to-delete su lista.
struct FloorplanListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Floorplan.createdAt, order: .reverse) private var floorplans: [Floorplan]
    @Namespace private var namespace
    @Binding var columnVisibility: NavigationSplitViewVisibility
    
    @State private var layout: GalleryLayout = .grid
    @State private var pendingDelete: Floorplan?
    @State private var showingNewSheet = false
    @State private var editingFloorplan: Floorplan?
    
    enum GalleryLayout: String, CaseIterable {
        case grid, list
        
        var systemImage: String {
            switch self {
            case .grid: return "square.grid.2x2"
            case .list: return "list.bullet"
            }
        }
        
        var localized: String {
            switch self {
            case .grid: return "Griglia"
            case .list: return "Lista"
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                contentView
                    .safeAreaPadding(.top, 70)
                
                floatingPillsOverlay
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingNewSheet) {
                NewFloorplanSheet()
            }
            .sheet(item: $editingFloorplan) { floorplan in
                EditFloorplanSheet(floorplan: floorplan)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .alert("Eliminare la planimetria?",
                   isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                   ),
                   presenting: pendingDelete) { fp in
                Button("Elimina", role: .destructive) {
                    delete(fp)
                }
                Button("Annulla", role: .cancel) {}
            } message: { _ in
                Text("L'immagine e tutti i marker piazzati saranno persi.")
            }
        }
    }

    // MARK: - Action pill (overlay)

    private var galleryActionPill: some View {
        GlassPill {
            HStack(spacing: 0) {
                layoutButton(.grid)
                
                Divider().frame(height: 20)
                
                layoutButton(.list)
                
                Divider().frame(height: 20)
                
                Button {
                    showingNewSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
                    
                    @ViewBuilder
                    private var contentView: some View {
                        if floorplans.isEmpty {
                            emptyState
                        } else {
                            switch layout {
                            case .grid: gridView
                            case .list: listView
                            }
                        }
                    }
    
    private var floatingPillsOverlay: some View {
        VStack {
            HStack {
                HStack(spacing: 10) {
                    if columnVisibility == .detailOnly {
                        Button {
                            withAnimation(.spring(response: 0.4)) {
                                columnVisibility = .all
                            }
                        } label: {
                            GlassCircle(size: 40) {
                                Image(systemName: "sidebar.left")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    }
                    
                    GlassTitlePill {
                        Text("Planimetrie")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                }
                .animation(.spring(response: 0.4), value: columnVisibility)
                
                Spacer()
                
                galleryActionPill
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            
            Spacer()
        }
    }

    @ViewBuilder
    private func layoutButton(_ target: GalleryLayout) -> some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                layout = target
            }
        } label: {
            Image(systemName: target.systemImage)
                .font(.subheadline)
                .fontWeight(layout == target ? .semibold : .regular)
                .foregroundStyle(layout == target ? Color.accentColor : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    // MARK: - Empty
    
    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nessuna planimetria", systemImage: "square.dashed")
        } description: {
            VStack(spacing: 12) {
                Text("Crea la tua prima planimetria per iniziare.")
                
                Text("Carica un'immagine (planimetria, foto della casa, schema) e posiziona i marker dei tuoi accessori HomeKit per controllarli con un colpo d'occhio.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
            }
        } actions: {
            VStack(spacing: 10) {
                Button {
                    showingNewSheet = true
                } label: {
                    Label("Crea planimetria", systemImage: "plus.circle.fill")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                Text("Suggerimento: una foto della planimetria stampata, uno screenshot dal piano dell'architetto, o un disegno schematico vanno bene.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 8)
            }
        }
    }
    
    // MARK: - Grid
    
    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 20)
            ], spacing: 20) {
                ForEach(floorplans) { floorplan in
                    NavigationLink {
                        editorPushed(for: floorplan)
                    } label: {
                        gridCard(for: floorplan)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        managementMenuItems(for: floorplan)
                    }
                }
            }
            .padding(20)
        }
    }
    
    private func gridCard(for floorplan: Floorplan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.secondary.opacity(0.1))
                
                if let image = ImageStorageService.load(filename: floorplan.imageFilename) {
                    Image(uiImage: image)
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
                // Badge contatore accessori
                HStack(spacing: 4) {
                    Image(systemName: "circle.grid.2x2")
                        .font(.caption2)
                    Text("\(floorplan.accessories.count)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                // Bottone "..." per il menu di gestione
                Menu {
                    managementMenuItems(for: floorplan)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
                }
                .padding(8)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(floorplan.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(floorplan.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }
    
    // MARK: - List
    
    private var listView: some View {
        List {
            ForEach(floorplans) { floorplan in
                NavigationLink {
                    editorPushed(for: floorplan)
                } label: {
                    HStack(spacing: 12) {
                        if let image = ImageStorageService.load(filename: floorplan.imageFilename) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 80, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.secondary.opacity(0.2))
                                .frame(width: 80, height: 60)
                                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(floorplan.name)
                                .font(.headline)
                            HStack(spacing: 8) {
                                Label("\(floorplan.accessories.count)", systemImage: "circle.grid.2x2")
                                Text("·")
                                Text(floorplan.updatedAt, format: .relative(presentation: .named))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = floorplan
                    } label: {
                        Label("Elimina", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        editingFloorplan = floorplan
                    } label: {
                        Label("Modifica", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    managementMenuItems(for: floorplan)
                }
            }
        }
    }
    
    // MARK: - Context menu
    
    @ViewBuilder
    private func managementMenuItems(for floorplan: Floorplan) -> some View {
        Button {
            editingFloorplan = floorplan
        } label: {
            Label("Modifica", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = floorplan
        } label: {
            Label("Elimina", systemImage: "trash")
        }
    }
    
    // MARK: - Editor push
    
    @ViewBuilder
    private func editorPushed(for floorplan: Floorplan) -> some View {
        // Per il push usiamo un binding "dummy" perché non c'è una sidebar da gestire
        // in questo contesto. La modalità .pushed mostra il bottone X invece del sidebar toggle.
        FloorplanEditorView(
            floorplan: floorplan,
            columnVisibility: .constant(.detailOnly),
            presentationStyle: .pushed
        )
    }
    
    // MARK: - Actions
    
    private func delete(_ floorplan: Floorplan) {
        ImageStorageService.delete(filename: floorplan.imageFilename)
        modelContext.delete(floorplan)
        try? modelContext.save()
    }
}
