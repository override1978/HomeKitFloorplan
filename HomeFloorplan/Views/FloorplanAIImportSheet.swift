import SwiftUI
import PhotosUI

struct FloorplanAIImportSheet: View {
    var onUseDraft: (DrawingDocument) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var generatedDocument: DrawingDocument?
    @State private var isLoadingImage = false
    @State private var isAnalyzing = false
    @State private var errorMessage: String?

    private let analysisService = FloorplanImageAnalysisService.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        imagePreview
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text(String(localized: "drawing.ai.import.image.header", defaultValue: "Floorplan image"))
                } footer: {
                    Text(String(localized: "drawing.ai.import.image.footer", defaultValue: "The image is sent to the configured AI provider only when you tap Analyze. The result is an editable draft."))
                }

                Section {
                    Button {
                        Task { await analyzeSelectedImage() }
                    } label: {
                        HStack {
                            Label(
                                isAnalyzing
                                    ? String(localized: "drawing.ai.import.analyzing", defaultValue: "Analyzing...")
                                    : String(localized: "drawing.ai.import.analyze", defaultValue: "Analyze image")
                                ,
                                systemImage: "sparkles"
                            )
                            Spacer()
                            if isAnalyzing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(selectedImage == nil || isAnalyzing || isLoadingImage)
                } footer: {
                    Text(String(localized: "drawing.ai.import.analyze.footer", defaultValue: "AI can be wrong. Review and correct the generated draft before saving."))
                }

                if let generatedDocument {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(
                                String(localized: "drawing.ai.import.ready", defaultValue: "Draft ready"),
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundStyle(BrandColor.primary)

                            Text(summary(for: generatedDocument))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Button {
                                onUseDraft(generatedDocument)
                                dismiss()
                            } label: {
                                Label(String(localized: "drawing.ai.import.useDraft", defaultValue: "Open editable draft"), systemImage: "pencil.and.ruler")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(BrandColor.primary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "drawing.ai.import.title", defaultValue: "AI floorplan draft"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close", defaultValue: "Close")) { dismiss() }
                }
            }
            .task(id: pickerItem) {
                await loadSelectedImage()
            }
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.secondary.opacity(0.10))

            if let selectedImage {
                Image(uiImage: selectedImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if isLoadingImage {
                ProgressView()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                        .font(.largeTitle)
                    Text(String(localized: "drawing.ai.import.pickImage", defaultValue: "Choose floorplan image"))
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(4 / 3, contentMode: .fit)
    }

    private func loadSelectedImage() async {
        guard let pickerItem else { return }
        isLoadingImage = true
        errorMessage = nil
        generatedDocument = nil

        do {
            if let data = try await pickerItem.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                selectedImage = image
            } else {
                errorMessage = String(localized: "drawing.ai.import.loadFailed", defaultValue: "Unable to load the selected image.")
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoadingImage = false
    }

    private func analyzeSelectedImage() async {
        guard let selectedImage else { return }
        isAnalyzing = true
        errorMessage = nil
        generatedDocument = nil

        do {
            let document = try await analysisService.analyze(image: selectedImage)
            if document.walls.isEmpty {
                errorMessage = String(localized: "drawing.ai.import.emptyDraft", defaultValue: "The AI did not find enough floorplan structure. Try a clearer image.")
            } else {
                generatedDocument = document
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isAnalyzing = false
    }

    private func summary(for document: DrawingDocument) -> String {
        String(
            localized: "drawing.ai.import.summary",
            defaultValue: "\(document.walls.count) wall segments generated. Add room areas after correcting the walls."
        )
    }
}
