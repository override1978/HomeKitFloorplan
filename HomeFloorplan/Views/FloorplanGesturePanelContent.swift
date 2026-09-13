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
                Image(systemName: "hand.tap")
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
            Text(String(format: String(localized: "gesture.subtitle",
                                       defaultValue: "%d comandi, a mano"),
                        gesture.changes.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    private var verbs: some View {
        VStack(spacing: 8) {
            Button {
                Task { await replay() }
            } label: {
                Label(String(localized: "gesture.replay", defaultValue: "Rifai adesso"),
                      systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)

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

            Button {
                namingForAutomation = true
                draftName = HumanGestureBuilder.suggestedName(for: gesture)
            } label: {
                Label(String(localized: "gesture.remember", defaultValue: "Ricordalo a quest'ora"),
                      systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isWorking)

            Text(String(localized: "gesture.verbs.explain",
                        defaultValue: "Si salva lo stato finale, non la sequenza: una scena è una configurazione."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            let scene = try await scenesService.createScene(named: name, capturing: gesture.changes)
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
