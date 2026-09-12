import SwiftUI

// MARK: - FloorplanMomentPanelContent

/// Il dettaglio di un momento della giornata, nel pannello di destra.
///
/// Il suo mestiere non è descrivere. Se toccando «Attivo Antifurto» delle 22:00
/// si aprisse una scheda che dice *che alle 22:00 si attiva l'antifurto*, il
/// tocco sarebbe servito a rileggere l'etichetta. Qui serve a **fare qualcosa**
/// — e su un momento futuro la cosa da fare è una sola: poterlo fermare.
///
/// È il momento in cui si perde fiducia in una casa che si muove da sola: fa
/// una cosa che non volevi, e la reazione è disattivare l'automazione per
/// sempre, buttando via anche tutte le volte in cui andava bene. Un rifiuto che
/// dura una sera salva l'automazione invece di ucciderla.
struct FloorplanMomentPanelContent: View {

    let moment: DayMoment
    @Bindable var overlayVM: FloorplanOverlayViewModel

    @Environment(HomeKitAutomationsService.self) private var automationsService
    @Environment(AutomationSkipStore.self) private var skipStore

    @State private var isWorking = false
    @State private var failure: String?

    private var isSkipped: Bool {
        guard let id = moment.automationID else { return false }
        return skipStore.isSkipped(id)
    }

    /// L'orario scritto nel nome, quando non coincide con quello vero.
    ///
    /// È informazione che nessun'altra app dà, e nasce da un comportamento di
    /// Casa: una volta rinominata a mano, un'automazione smette di aggiornare
    /// il proprio nome, quindi se poi ne cambi l'ora il nome resta congelato su
    /// quella vecchia. Da fuori sembra che l'app sbagli; in realtà sta dicendo
    /// la verità più di quanto faccia il nome.
    private var declaredTimeMismatch: String? {
        guard case .automation = moment.kind,
              let declared = HomeKitAutomationsService.leadingTime(in: moment.title)
        else { return nil }
        let actual = Calendar.current.dateComponents([.hour, .minute], from: moment.at)
        guard declared.hour != actual.hour || declared.minute != actual.minute else { return nil }
        return String(format: "%02d:%02d", declared.hour, declared.minute)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let detail = moment.detail { detailRow(detail) }
            if let declared = declaredTimeMismatch { mismatchNote(declared) }
            if case .automation(true) = moment.kind { conditionalNote }
            verb
            if let failure { failureNote(failure) }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: Testa

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: moment.symbolName)
                    .font(.caption.weight(.semibold))
                Text(moment.at.formatted(date: .omitted, time: .shortened))
                    .font(.title3.weight(.bold).monospacedDigit())
                Spacer()
                Button {
                    overlayVM.closeDetailContent()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(moment.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(tenseLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tenseLabel: String {
        if isSkipped {
            return String(localized: "moment.tense.skipped", defaultValue: "Saltata per stavolta")
        }
        if moment.isPast {
            return moment.isAutomationKind
                // «Era previsto» e non «è successo»: il registro di ciò che è
                // davvero accaduto non esiste ancora, e prometterlo qui
                // sarebbe la bugia più facile.
                ? String(localized: "moment.tense.wasScheduled", defaultValue: "Era previsto")
                : String(localized: "moment.tense.past", defaultValue: "Già passato")
        }
        return String(localized: "moment.tense.upcoming", defaultValue: "Deve ancora arrivare")
    }

    // MARK: Righe

    private func detailRow(_ detail: String) -> some View {
        Label(detail, systemImage: "play.rectangle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func mismatchNote(_ declared: String) -> some View {
        Label {
            Text(String(format: String(localized: "moment.mismatch",
                                       defaultValue: "Il nome dice %@, ma scatta alle %@."),
                        declared,
                        moment.at.formatted(date: .omitted, time: .shortened)))
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(.orange)
    }

    private var conditionalNote: some View {
        Label(String(localized: "moment.conditional",
                     defaultValue: "Ha delle condizioni: potrebbe non agire."),
              systemImage: "questionmark.diamond")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func failureNote(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.red)
    }

    // MARK: Il verbo

    /// Un solo verbo, e solo dove ha senso.
    ///
    /// Sul passato non c'è niente da fare — disfare ieri non è un'operazione — e
    /// alba e tramonto non si negoziano. Resta il futuro delle automazioni, che
    /// è esattamente il posto in cui poter dire di no vale qualcosa.
    @ViewBuilder
    private var verb: some View {
        if let automationID = moment.automationID, !moment.isPast {
            if isSkipped {
                Button {
                    Task { await restore(automationID) }
                } label: {
                    Label(String(localized: "moment.restore", defaultValue: "Rimettila in funzione"),
                          systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            } else {
                Button {
                    Task { await skip(automationID) }
                } label: {
                    Label(String(localized: "moment.skip", defaultValue: "Stavolta no"),
                          systemImage: "moon.zzz")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }

            Text(String(localized: "moment.skip.explain",
                        defaultValue: "L'automazione resta, salta solo questo scatto e torna attiva subito dopo."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Azioni

    private func skip(_ automationID: String) async {
        guard let item = automationsService.automations.first(where: { $0.id == automationID }) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await automationsService.setEnabled(false, for: item)
            // Solo dopo che HomeKit ha accettato: registrare prima lascerebbe
            // una promessa di ripristino per qualcosa che non è mai stato spento.
            skipStore.recordSkip(automationID, firingAt: moment.at)
            failure = nil
        } catch {
            failure = String(localized: "moment.skip.failed",
                             defaultValue: "Non sono riuscito a sospenderla.")
        }
    }

    private func restore(_ automationID: String) async {
        guard let item = automationsService.automations.first(where: { $0.id == automationID }) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await automationsService.setEnabled(true, for: item)
            skipStore.clearSkip(automationID)
            failure = nil
        } catch {
            failure = String(localized: "moment.restore.failed",
                             defaultValue: "Non sono riuscito a riattivarla.")
        }
    }
}
