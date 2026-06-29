import SwiftUI
import PhotosUI

struct FloorplanImageDraftImportSheet: View {
    var onUseDraft: (DrawingDocument) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var generatedDocument: DrawingDocument?
    @State private var isLoadingImage = false
    @State private var isAnalyzing = false
    @State private var errorMessage: String?

    private let vectorizationService = FloorplanImageVectorizationService.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        imagePreview
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text(String(localized: "drawing.imageDraft.import.image.header", defaultValue: "Floorplan image"))
                } footer: {
                    Text(String(localized: "drawing.imageDraft.import.image.footer", defaultValue: "Local analysis detects clear horizontal and vertical wall segments. No image is sent to an AI provider."))
                }

                Section {
                    Button {
                        analyzeSelectedImage()
                    } label: {
                        HStack {
                            Label(
                                isAnalyzing
                                    ? String(localized: "drawing.imageDraft.import.analyzing", defaultValue: "Detecting walls...")
                                    : String(localized: "drawing.imageDraft.import.analyze", defaultValue: "Detect wall draft"),
                                systemImage: "wand.and.rays"
                            )
                            Spacer()
                            if isAnalyzing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(selectedImage == nil || isAnalyzing || isLoadingImage)
                } footer: {
                    Text(String(localized: "drawing.imageDraft.import.analyze.footer", defaultValue: "The result is only a starting point. Review and correct the walls before saving."))
                }

                if let generatedDocument {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(
                                String(localized: "drawing.imageDraft.import.ready", defaultValue: "Draft ready"),
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
                                Label(String(localized: "drawing.imageDraft.import.useDraft", defaultValue: "Open editable draft"), systemImage: "pencil.and.ruler")
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
            .navigationTitle(String(localized: "drawing.imageDraft.import.title", defaultValue: "Image wall draft"))
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
                    Text(String(localized: "drawing.imageDraft.import.pickImage", defaultValue: "Choose floorplan image"))
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
                errorMessage = String(localized: "drawing.imageDraft.import.loadFailed", defaultValue: "Unable to load the selected image.")
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoadingImage = false
    }

    private func analyzeSelectedImage() {
        guard let selectedImage else { return }
        isAnalyzing = true
        errorMessage = nil
        generatedDocument = nil

        Task {
            do {
                let document = try await vectorizationService.vectorize(image: selectedImage)
                generatedDocument = document
            } catch {
                errorMessage = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func summary(for document: DrawingDocument) -> String {
        let count = document.walls.count
        if count >= 180 {
            return String(
                localized: "drawing.imageDraft.import.summary.capped",
                defaultValue: "\(count) wall segments detected (limit reached — the draft may be incomplete)."
            )
        }
        return String(
            localized: "drawing.imageDraft.import.summary",
            defaultValue: "\(count) wall segments detected locally."
        )
    }
}
