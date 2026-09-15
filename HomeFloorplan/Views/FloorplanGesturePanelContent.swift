import SwiftUI

// MARK: - FloorplanGesturePanelContent

/// Il dettaglio di un gesto umano, nel pannello di destra.
///
/// Sopra l'asse il verbo è «fermala»: le automazioni le hai già decise, e
/// l'unica cosa che serve è poter dire di no. Sotto l'asse il verbo è opposto.
/// Un gesto è una cosa che hai fatto a mano, di solito più di una volta, e che
/// nessuno ha mai scritto da nessuna parte — la casa la esegue ogni sera e non
/// se ne ricorda mai.
///
/// Qui si chiude quel cerchio: la lista dice cosa è successo, e i tre verbi lo
/// rendono ripetibile a tre livelli di impegno crescente — rifarlo adesso,
/// tenerlo come scena, farlo diventare un'abitudine della casa. È la sola
/// parte dell'app in cui l'osservazione diventa memoria, e vale la pena che
/// costi un tocco.
struct FloorplanGesturePanelContent: View {

    let gesture: HumanGesture
    @Bindable var overlayVM: FloorplanOverlayViewModel

    @Environment(HomeKitService.self) private var homeKit
    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(HomeKitAutomationsService.self) private var automationsService

    private enum Outcome: Equatable {
        case replayed
        case saved(String)
        case remembered(String)
        case failed(String)
    }

    @State private var isWorking = false
    @State private var outcome: Outcome?
    /// Il nome proposto, aperto solo quando serve.
    @State private var draftName: String?
    /// Vero quando il campo nome è aperto per creare anche l'automazione.
    @State private var namingForAutomation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            gestureInsight
            changeList
            if let draftName { naming(draftName) } else { verbs }
            if let outcome { outcomeNote(outcome) }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: Testa

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: gesture.isScene ? "square.stack.3d.up.fill" : "hand.tap")
                    .font(.caption.weight(.semibold))
                Text(gesture.at.formatted(date: .omitted, time: .shortened))
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
            Text(gesture.shortTitle)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            // «A mano» e non «Tu»: HomeKit dice soltanto che il comando non è
            // arrivato da quest'app, non chi l'ha dato. Potrebbe essere un
            // altro di casa, o Siri. Dirlo com'è costa una parola.
            //
            // E su una scena riconosciuta non si dice affatto «a mano»: una
            // scena può averla lanciata una persona, Siri o un automatismo che
            // non avevamo previsto. «Scena eseguita» è vero in tutti e tre i
            // casi.
            Text(gesture.isScene
                 ? String(format: String(localized: "gesture.subtitle.scene",
                                         defaultValue: "Scena eseguita · %d accessori"),
                          gesture.changes.count)
                 : String(format: String(localized: "gesture.subtitle",
                                         defaultValue: "%d comandi, a mano"),
                          gesture.changes.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var gestureInsight: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: insightIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(insightTint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(insightTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(insightDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(insightTint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(insightTint.opacity(0.22), lineWidth: 0.6)
        }
    }

    private var isSceneCandidate: Bool {
        !gesture.isScene && gesture.changes.count > 1
    }

    private var insightIcon: String {
        if gesture.isScene { return "checkmark.seal" }
        return isSceneCandidate ? "square.stack.3d.up" : "hand.tap"
    }

    private var insightTint: Color {
        if gesture.isScene { return .green }
        return isSceneCandidate ? BrandColor.primary : .secondary
    }

    private var insightTitle: String {
        if gesture.isScene {
            return String(localized: "gesture.insight.scene",
                          defaultValue: "Scena riconosciuta")
        }
        if isSceneCandidate {
            return String(localized: "gesture.insight.sceneCandidate",
                          defaultValue: "Possibile scena")
        }
        return String(localized: "gesture.insight.single",
                      defaultValue: "Comando singolo")
    }

    private var insightDetail: String {
        if gesture.isScene {
            return String(localized: "gesture.insight.scene.detail",
                          defaultValue: "Il rombo rappresenta una scena gia esistente.")
        }
        if isSceneCandidate {
            let rooms = gesture.roomNames.count
            if rooms > 1 {
                return String(format: String(localized: "gesture.insight.sceneCandidate.rooms",
                                             defaultValue: "%d comandi in %d stanze: puo diventare una scena o un promemoria."),
                              gesture.changes.count, rooms)
            }
            return String(format: String(localized: "gesture.insight.sceneCandidate.detail",
                                         defaultValue: "%d comandi ravvicinati: puo diventare una scena o un promemoria."),
                          gesture.changes.count)
        }
        return String(localized: "gesture.insight.single.detail",
                      defaultValue: "Evento utile per capire cosa e successo, ma non abbastanza ricco per proporre una scena.")
    }

    // MARK: La lista

    private var changeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(gesture.changes) { change in
                HStack(spacing: 10) {
                    Image(systemName: Self.symbol(for: change))
                        .font(.footnote)
                        .frame(width: 18)
                        .foregroundStyle(change.state ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(change.accessoryName)
                            .font(.subheadline)
                            .lineLimit(1)
                        if let room = change.roomName {
                            Text(room)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 6)
                    Text(Self.stateLabel(for: change))
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private static func symbol(for change: HumanGesture.Change) -> String {
        switch AccessoryEventType(rawValue: change.eventType) {
        case .light:       return change.state ? "lightbulb.fill" : "lightbulb"
        case .blind:       return change.state ? "blinds.horizontal.open" : "blinds.horizontal.closed"
        case .fan:         return "fan"
        case .airPurifier: return "air.purifier"
        case .humidifier:  return "humidifier"
        case .thermostat:  return "thermometer"
        case .outlet:      return "powerplug"
        default:           return change.state ? "power" : "power.dotted"
        }
    }

    private static func stateLabel(for change: HumanGesture.Change) -> String {
        guard change.state else {
            return String(localized: "gesture.state.off", defaultValue: "Spento")
        }
        if let brightness = change.brightness, brightness > 0, brightness < 1 {
            return "\(Int((brightness * 100).rounded()))%"
        }
        return String(localized: "gesture.state.on", defaultValue: "Acceso")
    }

    // MARK: I verbi

    /// I verbi, che non sono gli stessi per una mano e per una scena.
    ///
    /// Su una scena riconosciuta «salva come scena» sarebbe una seconda copia
    /// della stessa cosa, e «rifai adesso» quarantasette scritture separate
    /// dove ne basta una: HomeKit sa eseguire un insieme di azioni, e farlo
    /// passare per la porta giusta è anche l'unico modo perché arrivi atomico.
    @ViewBuilder
    private var verbs: some View {
        VStack(spacing: 8) {
            Button {
                Task { await replay() }
            } label: {
                Label(gesture.isScene
                      ? String(localized: "gesture.runScene", defaultValue: "Esegui adesso")
                      : String(localized: "gesture.replay", defaultValue: "Rifai adesso"),
                      systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)

            if isSceneCandidate {
                Button {
                    namingForAutomation = false
                    draftName = HumanGestureBuilder.suggestedName(for: gesture)
                } label: {
                    Label(String(localized: "gesture.saveScene", defaultValue: "Salva come scena"),
                          systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }

            Button {
                namingForAutomation = true
                draftName = gesture.sceneName ?? HumanGestureBuilder.suggestedName(for: gesture)
            } label: {
                Label(String(localized: "gesture.remember", defaultValue: "Ricordalo a quest'ora"),
                      systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isWorking)

            Text(verbsExplanation)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var verbsExplanation: String {
        if gesture.isScene {
            return String(localized: "gesture.verbs.explain.scene",
                          defaultValue: "La scena esiste gia: qui puoi solo rilanciarla o darle un orario fisso.")
        }
        if isSceneCandidate {
            return String(localized: "gesture.verbs.explain",
                          defaultValue: "Si salva lo stato finale, non la sequenza: una scena e una configurazione.")
        }
        return String(localized: "gesture.verbs.explain.single",
                      defaultValue: "Un comando singolo si puo rifare o programmare, senza creare una scena.")
    }

    /// Il campo nome, che compare solo quando qualcosa sta per essere creato.
    ///
    /// Sta qui e non in un foglio modale perché il pannello è già il posto in
    /// cui si guarda il gesto: aprire una finestra sopra vorrebbe dire coprire
    /// la lista proprio mentre si decide come chiamarla.
    private func naming(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(String(localized: "gesture.name.placeholder", defaultValue: "Nome"),
                      text: Binding(get: { name }, set: { draftName = $0 }))
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)

            if namingForAutomation {
                Label(String(format: String(localized: "gesture.remember.explain",
                                            defaultValue: "Ogni giorno alle %@, questa scena si eseguirà da sola."),
                             gesture.at.formatted(date: .omitted, time: .shortened)),
                      systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(String(localized: "common.cancel", defaultValue: "Annulla")) {
                    draftName = nil
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await confirmNaming(name) }
                } label: {
                    Text(String(localized: "common.save", defaultValue: "Salva"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func outcomeNote(_ outcome: Outcome) -> some View {
        switch outcome {
        case .replayed:
            note(String(localized: "gesture.replayed", defaultValue: "Rifatto."),
                 icon: "checkmark.circle", tint: .green)
        case .saved(let name):
            note(String(format: String(localized: "gesture.saved",
                                       defaultValue: "«%@» è ora una scena."), name),
                 icon: "checkmark.circle", tint: .green)
        case .remembered(let name):
            note(String(format: String(localized: "gesture.remembered",
                                       defaultValue: "«%@» si ripeterà ogni giorno a quest'ora."), name),
                 icon: "checkmark.circle", tint: .green)
        case .failed(let message):
            note(message, icon: "exclamationmark.circle", tint: .red)
        }
    }

    private func note(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Azioni

    /// Riapplica lo stato finale del gesto.
    ///
    /// Con `origin: "engine"`: è una ripetizione chiesta dall'app, non un gesto
    /// nuovo. Marcarla «user» la farebbe rientrare nella corsia come se
    /// qualcuno l'avesse fatta a mano, e domani il nastro racconterebbe un
    /// gesto che non è mai esistito.
    private func replay() async {
        isWorking = true
        defer { isWorking = false }

        // Una scena si esegue, non si ricostruisce: HomeKit la applica in un
        // colpo solo, senza la finestra di mezzo secondo in cui metà casa è
        // già cambiata e metà no.
        if let sceneID = gesture.sceneID,
           let scene = scenesService.scenes.first(where: { $0.id == sceneID }) {
            do {
                try await scenesService.run(scene)
                outcome = .replayed
            } catch {
                outcome = .failed(String(localized: "gesture.replay.failed",
                                         defaultValue: "Non sono riuscito a rifarlo."))
            }
            return
        }

        var failures = 0
        for change in gesture.changes {
            guard let accessory = homeKit.accessory(for: change.accessoryUUID),
                  let power = HomeKitScenesService.powerCharacteristic(of: accessory) else {
                failures += 1
                continue
            }
            do {
                try await homeKit.write(NSNumber(value: change.state), to: power, origin: "engine")
                if change.state, let brightness = change.brightness,
                   let dimmer = HomeKitScenesService.brightnessCharacteristic(of: accessory) {
                    try await homeKit.write(NSNumber(value: Int((brightness * 100).rounded())),
                                            to: dimmer, origin: "engine")
                }
            } catch {
                failures += 1
            }
        }
        if failures == 0 {
            outcome = .replayed
        } else if failures == gesture.changes.count {
            outcome = .failed(String(localized: "gesture.replay.failed",
                                     defaultValue: "Non sono riuscito a rifarlo."))
        } else {
            // Il parziale si dice: «fatto» su metà casa è la bugia che porta
            // qualcuno a non controllare la porta.
            outcome = .failed(String(format: String(localized: "gesture.replay.partial",
                                                    defaultValue: "Rifatto in parte: %d comandi non sono passati."),
                                     failures))
        }
    }

    private func confirmNaming(_ name: String) async {
        isWorking = true
        defer { isWorking = false }
        let wantsAutomation = namingForAutomation
        do {
            // Se la scena esiste già si riusa: creare un duplicato con lo
            // stesso contenuto vorrebbe dire che d'ora in poi vanno tenute
            // allineate a mano tutte e due.
            let existing = gesture.sceneID.flatMap { id in
                scenesService.scenes.first(where: { $0.id == id })
            }
            let scene: SceneItem
            if let existing {
                scene = existing
            } else {
                scene = try await scenesService.createScene(named: name, capturing: gesture.changes)
            }
            if wantsAutomation {
                var schedule = AutomationScheduleTrigger()
                schedule.kind = .fixedTime
                schedule.time = gesture.at
                _ = try await automationsService.createScheduledSceneAutomation(name: name,
                                                                                  schedule: schedule,
                                                                                  scene: scene)
                outcome = .remembered(name)
            } else {
                outcome = .saved(name)
            }
            draftName = nil
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }
}
