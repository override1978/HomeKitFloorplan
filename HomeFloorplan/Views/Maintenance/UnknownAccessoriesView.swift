import SwiftUI

// MARK: - UnknownAccessoriesView

/// Gli accessori che l'app non sa più dove collocare, e le risposte possibili.
///
/// Qui c'è **solo ciò che è aperto**: quando non c'è niente da risolvere la
/// schermata lo dice e finisce lì. Ogni proposta porta scritto **perché** è
/// stata fatta — «stesso numero di serie» e «stesso modello nella stessa
/// stanza» portano a decisioni diverse, e senza il motivo due pulsanti identici
/// sembrano equivalenti quando non lo sono.
struct UnknownAccessoriesView: View {

    @Environment(AccessoryReconciliationService.self) private var reconciliation

    @State private var manualPickFor: AccessoryReconciliationService.Review?
    @State private var confirmingDiscard: AccessoryReconciliationService.Review?

    private var grouped: [(room: String, reviews: [AccessoryReconciliationService.Review])] {
        Dictionary(grouping: reconciliation.reviews) { $0.roomName ?? "—" }
            .map { (room: $0.key, reviews: $0.value) }
            .sorted { $0.room < $1.room }
    }

    var body: some View {
        Group {
            if reconciliation.reviews.isEmpty {
                ContentUnavailableView(
                    String(localized: "reconcile.empty.title", defaultValue: "Everything is where it should be"),
                    systemImage: "checkmark.circle",
                    description: Text(String(localized: "reconcile.empty.message",
                                             defaultValue: "Every accessory the app knows is still in HomeKit. Nothing to sort out."))
                )
            } else {
                list
            }
        }
        .maintenanceScreen()
        .navigationTitle(String(localized: "sidebar.unknownAccessories", defaultValue: "Unknown Accessories"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reconciliation.refresh() }
        .sheet(item: $manualPickFor) { review in
            ManualPickSheet(review: review)
        }
        // Stesso motivo del dettaglio snapshot: su iPad il foglio d'azione si
        // ancora alla lista invece che alla scheda da cui è partito.
        .alert(
            String(format: String(localized: "reconcile.discard.title",
                                  defaultValue: "Remove “%@”?"),
                   confirmingDiscard?.name ?? ""),
            isPresented: Binding(get: { confirmingDiscard != nil },
                                 set: { if !$0 { confirmingDiscard = nil } })
        ) {
            Button(String(localized: "reconcile.discard.confirm", defaultValue: "Remove"),
                   role: .destructive) {
                if let review = confirmingDiscard { reconciliation.discard(review) }
                confirmingDiscard = nil
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {
                confirmingDiscard = nil
            }
        } message: {
            if let review = confirmingDiscard, review.markerCount > 0 {
                Text(String(format: String(localized: "reconcile.discard.message",
                                           defaultValue: "%d markers will be removed from your floorplans."),
                            review.markerCount))
            }
        }
    }

    private var list: some View {
        List {
            Section {
                Text(String(localized: "reconcile.intro",
                            defaultValue: "These accessories are no longer in HomeKit. Saying what happened to them is what resolves their identity — and moves their markers to the right place."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(grouped, id: \.room) { group in
                Section(group.room.uppercased()) {
                    ForEach(group.reviews) { review in
                        ReviewCard(
                            review: review,
                            onReplace: { candidate in
                                reconciliation.replace(review, with: candidate.id, reason: candidate.reason)
                            },
                            onManualPick: { manualPickFor = review },
                            onDiscard: { confirmingDiscard = review }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Scheda

private struct ReviewCard: View {
    let review: AccessoryReconciliationService.Review
    let onReplace: (AccessoryReconciliationService.Candidate) -> Void
    let onManualPick: () -> Void
    let onDiscard: () -> Void

    private var symbol: String {
        AccessoryCategory.category(forCategoryType: review.categoryType).symbolName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.name)
                        .font(.headline)
                    let description = [review.manufacturer, review.model]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Cosa si sposta risolvendo. Un rimappaggio è invisibile, e senza
            // questo numero non c'è modo di accorgersi di uno sbagliato.
            if review.markerCount > 0 {
                Label(String(format: String(localized: "references.markers",
                                            defaultValue: "%d markers on floorplans"), review.markerCount),
                      systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(review.candidates) { candidate in
                    Button { onReplace(candidate) } label: {
                        VStack(spacing: 2) {
                            Text(candidateTitle(candidate))
                                .multilineTextAlignment(.center)
                            Text(candidate.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(candidate.strength == .hardware ? .green : BrandColor.primary)
                }

                Button(String(localized: "reconcile.action.other",
                              defaultValue: "I replaced it with another accessory"),
                       action: onManualPick)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                Button(String(localized: "reconcile.action.removed",
                              defaultValue: "It is gone for good"),
                       role: .destructive, action: onDiscard)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
        .buttonStyle(.bordered)
    }

    private func candidateTitle(_ candidate: AccessoryReconciliationService.Candidate) -> String {
        if let room = candidate.roomName, !room.isEmpty {
            return String(format: String(localized: "reconcile.action.replacedByInRoom",
                                         defaultValue: "Replaced by “%1$@” in %2$@"),
                          candidate.name, room)
        }
        return String(format: String(localized: "reconcile.action.replacedBy",
                                     defaultValue: "Replaced by “%@”"), candidate.name)
    }
}

// MARK: - Scelta manuale

private struct ManualPickSheet: View {
    let review: AccessoryReconciliationService.Review

    @Environment(AccessoryReconciliationService.self) private var reconciliation
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var targets: [AccessoryReconciliationService.Candidate] {
        let all = reconciliation.manualTargets()
        guard !search.isEmpty else { return all }
        let needle = search.lowercased()
        return all.filter {
            ($0.name + " " + ($0.roomName ?? "")).lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(targets) { target in
                        Button {
                            reconciliation.replace(review, with: target.id,
                                                   reason: String(localized: "reconcile.reason.manual",
                                                                  defaultValue: "chosen by hand"))
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.name)
                                if let room = target.roomName, !room.isEmpty {
                                    Text(room)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    // L'invariante, detto dove serve: gli accessori già
                    // abbinati non compaiono, e senza dirlo sembrerebbe che ne
                    // manchino.
                    Text(String(localized: "reconcile.manual.footer",
                                defaultValue: "Accessories already matched to something else are not listed."))
                }
            }
            .searchable(text: $search)
            .navigationTitle(String(format: String(localized: "reconcile.manual.title",
                                                   defaultValue: "Replacement for “%@”"), review.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
                }
            }
        }
    }
}
