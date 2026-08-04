import SwiftUI

// MARK: - Accessori

/// Gli accessori di uno snapshot, raggruppati per stanza come li si pensa.
struct SnapshotAccessoryListView: View {
    let snapshot: HomeConfigurationSnapshot
    @State private var search = ""

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
                        VStack(alignment: .leading, spacing: 3) {
                            Text(accessory.address.name)
                            Text([accessory.address.manufacturer, accessory.address.model]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                identityBadge(accessory)
                                if let firmware = accessory.firmwareVersion {
                                    Text("fw \(firmware)")
                                }
                                Text("\(accessory.services.count) serv.")
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle(String(localized: "snapshot.accessories", defaultValue: "Accessories"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Su cosa si regge l'identità di questo accessorio, che è quanto dire se
    /// sopravviverebbe a un ripristino su un altro device.
    @ViewBuilder
    private func identityBadge(_ accessory: AccessorySnapshot) -> some View {
        if !(accessory.address.serialNumber ?? "").isEmpty {
            Label(String(localized: "snapshot.identity.serial", defaultValue: "serial"),
                  systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } else {
            Label(String(localized: "snapshot.identity.byName", defaultValue: "no serial"),
                  systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Scene

/// Le scene con **i valori** che impostano: è il contenuto che l'app Casa non
/// mostra da nessuna parte, e il motivo principale per cui uno snapshot serve.
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
                Section {
                    if scene.actions.isEmpty {
                        Text(String(localized: "snapshot.scene.noReadableActions",
                                    defaultValue: "No action this app can read."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Self.byAccessory(scene.actions), id: \.name) { group in
                        SceneAccessoryRow(group: group)
                    }
                } header: {
                    HStack {
                        Text(scene.name)
                        if scene.isBuiltIn {
                            Text(String(localized: "snapshot.scene.builtIn", defaultValue: "built-in"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } footer: {
                    if scene.foreignActionCount > 0 {
                        Text(String(format: String(localized: "snapshot.scene.foreign",
                                                   defaultValue: "%d further actions this app cannot read."),
                                    scene.foreignActionCount))
                    }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle(String(localized: "snapshot.scenes", defaultValue: "Scenes"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Raggruppamento

    struct AccessoryGroup {
        let name: String
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
    /// accessori: «in questa scena il Salotto è al 40%», non «tre righe che
    /// ripetono Lampada Salotto». Qui le azioni si raggruppano come le si pensa.
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
                                .map { (SnapshotCharacteristicNames.readable($0.target.characteristicType),
                                        $0.value.displayText) }
                        )
                    }
                    .sorted { ($0.label ?? "") < ($1.label ?? "") }
                return AccessoryGroup(name: name, services: services)
            }
            .sorted { $0.name < $1.name }
    }
}

private struct SceneAccessoryRow: View {
    let group: SnapshotSceneListView.AccessoryGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.name)
            ForEach(group.services) { service in
                VStack(alignment: .leading, spacing: 2) {
                    if let label = service.label {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    // Su una riga sola: sono poche coppie corte, e impilarle
                    // riporterebbe la lista lunga che si voleva togliere.
                    Text(service.entries.map { "\($0.characteristic) \($0.value)" }
                        .joined(separator: "  ·  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
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

/// Le stanze con chi ci stava dentro. È l'elenco che serve dopo aver spostato
/// accessori per sbaglio: dice dov'erano, per nome.
struct SnapshotRoomListView: View {
    let snapshot: HomeConfigurationSnapshot

    private var rooms: [RoomSnapshot] {
        snapshot.rooms.sorted { $0.address.name < $1.address.name }
    }

    var body: some View {
        List {
            ForEach(Array(rooms.enumerated()), id: \.offset) { _, room in
                Section {
                    if room.accessoryNames.isEmpty {
                        Text(String(localized: "snapshot.room.empty", defaultValue: "No accessory"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(room.accessoryNames.sorted(), id: \.self) { name in
                        Text(name)
                    }
                } header: {
                    HStack {
                        Text(room.address.name)
                        Spacer()
                        Text("\(room.accessoryNames.count)")
                            .monospacedDigit()
                    }
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

    private var zones: [ZoneSnapshot] {
        snapshot.zones.sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            ForEach(Array(zones.enumerated()), id: \.offset) { _, zone in
                Section(zone.name) {
                    ForEach(zone.roomNames.sorted(), id: \.self) { name in
                        Label(name, systemImage: "door.left.hand.closed")
                    }
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
