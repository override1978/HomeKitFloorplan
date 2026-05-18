import SwiftUI
import SwiftData

struct FloorplanListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Floorplan.createdAt, order: .reverse) private var floorplans: [Floorplan]
    
    @State private var showingNewSheet = false
    
    @Binding var columnVisibility: NavigationSplitViewVisibility
    
    var body: some View {
        NavigationStack {
            Group {
                if floorplans.isEmpty {
                    ContentUnavailableView {
                        Label("Nessuna planimetria", systemImage: "map")
                    } description: {
                        Text("Crea la tua prima planimetria toccando il pulsante in alto a destra.")
                    } actions: {
                        Button {
                            showingNewSheet = true
                        } label: {
                            Label("Nuovo floorplan", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Planimetrie")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewSheet = true
                    } label: {
                        Label("Nuovo", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewSheet) {
                NewFloorplanSheet()
            }
        }
    }
    
    private var list: some View {
        List {
            ForEach(floorplans) { floorplan in
                NavigationLink {
                    FloorplanEditorView(floorplan: floorplan, columnVisibility: $columnVisibility)
                } label: {
                    HStack(spacing: 12) {
                        thumbnail(for: floorplan)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(floorplan.name)
                                .font(.headline)
                            Text("\(floorplan.accessories.count) accessori")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
            .onDelete(perform: delete)
        }
    }
    
    @ViewBuilder
    private func thumbnail(for floorplan: Floorplan) -> some View {
        if let image = ImageStorageService.load(filename: floorplan.imageFilename) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.2))
                .frame(width: 72, height: 72)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
    
    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let fp = floorplans[index]
            ImageStorageService.delete(filename: fp.imageFilename)
            modelContext.delete(fp)
        }
        try? modelContext.save()
    }
}
