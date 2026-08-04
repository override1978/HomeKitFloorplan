import SwiftUI

// MARK: - AccessoryReconciliationView

/// «Cosa è successo a questi accessori?»
///
/// Una scheda per accessorio sparito, raggruppate per stanza, e sotto ognuna le
/// risposte possibili. Due cose la distinguono da una lista di problemi: ogni
/// proposta dice **perché** è stata fatta — «stesso numero di serie» e «stesso
/// modello nella stessa stanza» portano a decisioni diverse — e ogni scheda dice
/// **cosa c'è in gioco**, perché un rimappaggio sbagliato è invisibile e senza
/// quel numero non c'è modo di accorgersene.
struct AccessoryReconciliationView: View {

    @Environment(AccessoryReconciliationService.self) private var reconciliation

    @State private var manualPickFor: AccessoryReconciliationService.Review?
    @State private var confirmingDiscard: AccessoryReconciliationService.Review?

    private var grouped: [(room: String, reviews: [AccessoryReconciliationService.Review])] {
        Dictionary(grouping: reconciliation.reviews) { $0.roomName ?? "—" }
            .map { (room: $0.key, reviews: $0.value) }
            .sorted { $0.room < $1.room }
    }

    var body: some View {
        List {
            if reconciliation.reviews.isEmpty {
                ContentUnavailableView(
                    String(localized: "reconcile.empty.title", defaultValue: "Nothing to sort out"),
                    systemImage: "checkmark.circle",
                    description: Text(String(localized: "reconcile.empty.message",
                                             defaultValue: "Every accessory this app relies on is still where it was."))
                )
            } else {
                Section {
                    Text(String(localized: "reconcile.intro",
                                defaultValue: "These accessories are gone from HomeKit, but this app still relies on them. Saying what happened is what keeps their markers and their history from being lost by accident."))
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
        .navigationTitle(String(localized: "reconcile.title", defaultValue: "What happened?"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reconciliation.refresh() }
        .sheet(item: $manualPickFor) { review in
            ManualPickSheet(review: review)
        }
        .confirmationDialog(
            String(format: String(localized: "reconcile.discard.title",
                                  defaultValue: "Remove “%@” and everything tied to it?"),
                   confirmingDiscard?.name ?? ""),
            isPresented: Binding(get: { confirmingDiscard != nil },
                                 set: { if !$0 { confirmingDiscard = nil } }),
            titleVisibility: .visible
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
            if let review = confirmingDiscard, !review.references.isEmpty {
                Text(review.references.summaryLines.joined(separator: " · "))
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

            // Cosa si perde se si sbaglia. È l'unica difesa contro un
            // abbinamento errato, che di suo non lascia traccia visibile.
            if !review.references.isEmpty {
                Text(review.references.summaryLines.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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
                    .tint(candidate.strength == .hardware ? .green : .accentColor)
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
