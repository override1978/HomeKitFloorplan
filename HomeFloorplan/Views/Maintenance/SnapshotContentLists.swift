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
                    ForEach(Array(scene.actions.sorted(by: { $0.sortKey < $1.sortKey }).enumerated()),
                            id: \.offset) { _, action in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.target.accessory.name)
                                Text(SnapshotCharacteristicNames.readable(action.target.characteristicType))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(action.value.displayText)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                        }
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
