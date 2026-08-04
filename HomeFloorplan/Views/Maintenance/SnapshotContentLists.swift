import SwiftUI

// MARK: - Accessori

/// Gli accessori di uno snapshot, raggruppati per stanza come li si pensa.
struct SnapshotAccessoryListView: View {
    let snapshot: HomeConfigurationSnapshot
    @State private var search = ""

    private var ambiguousStableKeys: Set<String> { snapshot.ambiguousStableKeys }

    private var grouped: [(room: String, accessories: [AccessorySnapshot])] {
        let filtered = snapshot.accessories.filter { matches($0) }
        return Dictionary(grouping: filtered) { $0.address.roomName ?? "—" }
            .map { (room: $0.key, accessories: $0.value.sorted { $0.address.name < $1.address.name }) }
            .sorted { $0.room < $1.room }
    }

    private func matches(_ accessory: AccessorySnapshot) -> Bool {
        guard !search.isEmpty else { return true }
        let haystack = [accessory.address.name, accessory.address.roomName,
                        accessory.address.manufacturer, accessory.address.model]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return haystack.contains(search.lowercased())
    }

    var body: some View {
        List {
            ForEach(grouped, id: \.room) { group in
                Section(group.room) {
                    // Indice e non nome: due accessori omonimi nella stessa
                    // stanza esistono, e un `id` duplicato fa sparire una riga.
                    ForEach(Array(group.accessories.enumerated()), id: \.offset) { _, accessory in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(accessory.address.name)
                                Text([accessory.address.manufacturer, accessory.address.model]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    if let firmware = accessory.firmwareVersion {
                                        Text("fw \(firmware)")
                                    }
                                    if let bridge = accessory.bridgeName {
                                        Label(bridge, systemImage: "point.3.connected.trianglepath.dotted")
                                    }
                                    Text("\(accessory.services.count) serv.")
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            identityMark(accessory)
                        }
                    }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle(String(localized: "snapshot.accessories", defaultValue: "Accessories"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Se questo accessorio sarebbe riconoscibile anche altrove.
    ///
    /// Un segno, non un'etichetta: **come** ci si riesce — numero di serie
    /// oppure produttore+modello+stanza — è affare nostro, e scriverlo sposta
    /// l'attenzione sul meccanismo invece che sull'esito.
    @ViewBuilder
    private func identityMark(_ accessory: AccessorySnapshot) -> some View {
        if accessory.isReliablyIdentifiable(ambiguousStableKeys: ambiguousStableKeys) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(String(localized: "snapshot.identity.sure",
                                           defaultValue: "surely identifiable"))
        } else {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.tertiary)
                .accessibilityLabel(String(localized: "snapshot.identity.unsure",
                                           defaultValue: "identified by name only"))
        }
    }
}

// MARK: - Scene

/// L'elenco delle scene: solo i nomi e quanto contengono. Il contenuto sta un
/// livello sotto — una scena su dieci accessori riempiva da sola una schermata,
/// e con quaranta scene l'elenco smetteva di essere un elenco.
struct SnapshotSceneListView: View {
    let snapshot: HomeConfigurationSnapshot
    @State private var search = ""

    private var scenes: [SceneSnapshot] {
        snapshot.userScenes
            .filter { search.isEmpty || $0.name.lowercased().contains(search.lowercased()) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            ForEach(Array(scenes.enumerated()), id: \.offset) { _, scene in
                NavigationLink {
                    SnapshotSceneDetailView(scene: scene)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scene.name)
                            if scene.isBuiltIn {
                                Text(String(localized: "snapshot.scene.builtIn", defaultValue: "built-in"))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        // Gli accessori toccati, non le azioni: è il numero che
                        // dice quanto è grande una scena a chi la sta cercando.
                        Text("\(SnapshotSceneDetailView.accessoryCount(scene))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle(String(localized: "snapshot.scenes", defaultValue: "Scenes"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Dettaglio di una scena

/// Cosa imposta una scena, **per accessorio**: è il contenuto che l'app Casa non
/// mostra da nessuna parte, e il motivo principale per cui uno snapshot serve.
struct SnapshotSceneDetailView: View {
    let scene: SceneSnapshot

    static func accessoryCount(_ scene: SceneSnapshot) -> Int {
        Set(scene.actions.map { $0.target.accessory.name }).count
    }

    var body: some View {
        List {
            if scene.actions.isEmpty {
                Section {
                    Text(String(localized: "snapshot.scene.noReadableActions",
                                defaultValue: "No action this app can read."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Una sezione per accessorio: il nome resta fuori dalla scheda e i
            // valori dentro, incolonnati. Sono poche coppie corte, e messe in
            // colonna si confrontano a colpo d'occhio — in fila su una riga no.
            ForEach(Self.byAccessory(scene.actions), id: \.name) { group in
                Section {
                    ForEach(group.services) { service in
                        if let label = service.label {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(Array(service.entries.enumerated()), id: \.offset) { _, entry in
                            LabeledContent(entry.characteristic, value: entry.value)
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .textCase(nil)
                        if let room = group.roomName {
                            Text(room)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                }
            }

            if scene.foreignActionCount > 0 {
                Section {
                    Text(String(format: String(localized: "snapshot.scene.foreign",
                                               defaultValue: "%d further actions this app cannot read."),
                                scene.foreignActionCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(scene.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Raggruppamento

    struct AccessoryGroup {
        let name: String
        let roomName: String?
        /// Un blocco per servizio. Restano separati solo quando servono: su una
        /// lampada c'è un servizio solo e mostrarlo sarebbe rumore, su una
        /// multipresa sono le singole prese e senza non si capisce quale.
        let services: [ServiceGroup]
    }

    struct ServiceGroup: Identifiable {
        let id: String
        let label: String?
        let entries: [(characteristic: String, value: String)]
    }

    /// Una scena è fatta di scritture su caratteristiche, ma si pensa per
    /// accessori: «in questa scena il Salotto è al 40%», non tre righe che
    /// ripetono «Lampada Salotto».
    static func byAccessory(_ actions: [SceneActionSnapshot]) -> [AccessoryGroup] {
        Dictionary(grouping: actions) { $0.target.accessory.name }
            .map { name, actions -> AccessoryGroup in
                let byService = Dictionary(grouping: actions) {
                    "\($0.target.service.serviceType)#\($0.target.service.ordinal)"
                }
                let showsService = byService.count > 1
                let services = byService
                    .map { key, actions -> ServiceGroup in
                        let first = actions[0].target.service
                        return ServiceGroup(
                            id: key,
                            label: showsService ? (first.name ?? "#\(first.ordinal + 1)") : nil,
                            entries: actions
                                .sorted { $0.target.characteristicType < $1.target.characteristicType }
                                .map { ($0.readableName, $0.readableValue) }
                        )
                    }
                    .sorted { ($0.label ?? "") < ($1.label ?? "") }
                return AccessoryGroup(name: name,
                                      roomName: actions[0].target.accessory.roomName,
                                      services: services)
            }
            .sorted { $0.name < $1.name }
    }
}

// MARK: - Automazioni

/// Le automazioni come **documentazione**: cosa scatta, a quali condizioni, e
/// se è qualcosa che si potrebbe rimettere in piedi o solo rifare a mano.
struct SnapshotAutomationListView: View {
    let snapshot: HomeConfigurationSnapshot
    @State private var search = ""

    private var automations: [AutomationSnapshot] {
        snapshot.automations
            .filter { search.isEmpty || $0.name.lowercased().contains(search.lowercased()) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            ForEach(Array(automations.enumerated()), id: \.offset) { _, automation in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        contentBadge(automation.content)
                        Text(automation.name)
                        if !automation.isEnabled {
                            Text(String(localized: "snapshot.automation.paused", defaultValue: "paused"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(automation.humanSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !automation.conditionSummaries.isEmpty {
                        Text(automation.conditionSummaries.joined(separator: " • "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if !automation.actionSetNames.isEmpty {
                        Text(automation.actionSetNames.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle(String(localized: "snapshot.automations", defaultValue: "Automations"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func contentBadge(_ content: AutomationSnapshot.Content) -> some View {
        switch content {
        case .scene:
            Image(systemName: "wand.and.sparkles").foregroundStyle(.green)
        case .readableInlineActions:
            Image(systemName: "slider.horizontal.3").foregroundStyle(.blue)
        case .shortcut:
            // Fuori portata per qualunque app di terze parti: si documenta, non
            // si ripristina.
            Image(systemName: "app.connected.to.app.below.fill").foregroundStyle(.orange)
        case .empty:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .other:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Stanze

/// Solo i nomi e quanto contenevano. Esploderle in elenchi di accessori
/// duplicava l'elenco accessori, che è già raggruppato per stanza.
struct SnapshotRoomListView: View {
    let snapshot: HomeConfigurationSnapshot

    var body: some View {
        List {
            ForEach(snapshot.rooms.sorted { $0.address.name < $1.address.name },
                    id: \.address.name) { room in
                HStack {
                    Text(room.address.name)
                    Spacer()
                    Text("\(room.accessoryNames.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .navigationTitle(String(localized: "snapshot.rooms", defaultValue: "Rooms"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Zone

struct SnapshotZoneListView: View {
    let snapshot: HomeConfigurationSnapshot

    var body: some View {
        List {
            ForEach(snapshot.zones.sorted { $0.name < $1.name }, id: \.name) { zone in
                HStack {
                    Text(zone.name)
                    Spacer()
                    Text("\(zone.roomNames.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .navigationTitle(String(localized: "snapshot.zones", defaultValue: "Zones"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Gruppi di servizi

/// I gruppi con **quali** servizi contengono, non quanti: è la differenza fra
/// poterli ripristinare e poterli solo constatare.
struct SnapshotServiceGroupListView: View {
    let snapshot: HomeConfigurationSnapshot

    private var groups: [ServiceGroupSnapshot] {
        snapshot.serviceGroups.sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Section {
                    if group.members.isEmpty {
                        Text(String(format: String(localized: "snapshot.group.unknownMembers",
                                                   defaultValue: "%d services, not recorded individually"),
                                    group.serviceCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(group.members.enumerated()), id: \.offset) { _, member in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.accessoryName)
                            if let name = member.serviceName, name != member.accessoryName {
                                Text(name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(group.name)
                }
            }
        }
        .navigationTitle(String(localized: "snapshot.serviceGroups", defaultValue: "Service groups"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
