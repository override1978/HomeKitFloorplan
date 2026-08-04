import Foundation

// MARK: - HomeSnapshotDiff

/// Cosa è cambiato fra uno snapshot e la casa di adesso.
///
/// Puro: due `HomeConfigurationSnapshot` in ingresso — quello archiviato e uno
/// catturato ora — e nessun `import HomeKit`. È quindi verificabile senza
/// simulatore, che per il pezzo su cui poggia un ripristino conta.
///
/// Il verso del confronto non è simmetrico ed è quello che conta: si guarda
/// **cosa succederebbe ripristinando**. Perciò `mancante` significa «c'era, un
/// ripristino lo rimetterebbe» e `nuovo` significa «è arrivato dopo, un
/// ripristino non lo tocca» — mai «da cancellare».
struct HomeSnapshotDiff: Sendable {

    enum Change: String, Sendable {
        /// Nello snapshot ma non più in casa: un ripristino lo rimetterebbe.
        case missingNow
        /// In casa ma non nello snapshot: arrivato dopo, resta dov'è.
        case newSinceThen
        /// In entrambi, ma diverso: un ripristino riporterebbe i valori di allora.
        case changed
    }

    enum Category: String, CaseIterable, Sendable, Identifiable {
        case scenes, rooms, zones, serviceGroups, accessories, automations
        var id: String { rawValue }

        var title: String {
            switch self {
            case .scenes:        String(localized: "snapshot.scenes", defaultValue: "Scenes")
            case .rooms:         String(localized: "snapshot.rooms", defaultValue: "Rooms")
            case .zones:         String(localized: "snapshot.zones", defaultValue: "Zones")
            case .serviceGroups: String(localized: "snapshot.serviceGroups", defaultValue: "Service groups")
            case .accessories:   String(localized: "snapshot.accessories", defaultValue: "Accessories")
            case .automations:   String(localized: "snapshot.automations", defaultValue: "Automations")
            }
        }

        var symbol: String {
            switch self {
            case .scenes:        "wand.and.sparkles"
            case .rooms:         "door.left.hand.closed"
            case .zones:         "square.grid.3x3"
            case .serviceGroups: "rectangle.3.group"
            case .accessories:   "lightbulb"
            case .automations:   "gearshape.2"
            }
        }

        /// Se un ripristino può farci qualcosa.
        ///
        /// Gli **accessori** no: nessuna app può ri-accoppiare un dispositivo,
        /// quindi si mostrano per sapere cosa manca, non per rimetterlo. Le
        /// **automazioni** nemmeno: misurato sull'impianto di riferimento, 39 su
        /// 78 eseguono `HMShortcutAction`, che non esiste nell'SDK pubblico.
        ///
        /// I **gruppi di servizi** nemmeno, ma per colpa nostra: la cattura ne
        /// salva solo il conteggio, non quali servizi contenevano. Ricrearli
        /// vuoti sarebbe peggio che non ricrearli.
        ///
        /// Le **automazioni** dipendono dalla singola voce: si ricreano quelle
        /// che portano con sé una forma ricostruibile, e sono una minoranza.
        var isRestorable: Bool {
            switch self {
            case .scenes, .rooms, .zones, .automations:  true
            case .accessories, .serviceGroups:           false
            }
        }
    }

    struct Item: Identifiable, Sendable {
        let id: String
        let category: Category
        let change: Change
        let title: String
        /// In lingua, non in conteggi: «Lampada Studio · Luminosità → 40» dice
        /// cosa si sta per rimettere; «14 azioni su 15» non dice niente.
        let details: [String]
        /// Di norma discende dalla categoria, ma la singola voce può negarlo:
        /// una scena di cui lo snapshot non ha letto nessuna azione risulta
        /// diversa e **non** è ripristinabile, perché non c'è niente da
        /// rimettere. Offrirla sarebbe una spunta che non fa niente.
        let isRestorable: Bool

        init(id: String, category: Category, change: Change,
             title: String, details: [String], isRestorable: Bool? = nil) {
            self.id = id
            self.category = category
            self.change = change
            self.title = title
            self.details = details
            self.isRestorable = isRestorable ?? (category.isRestorable && change != .newSinceThen)
        }
    }

    let items: [Item]

    var isEmpty: Bool { items.isEmpty }

    func items(in category: Category) -> [Item] {
        items.filter { $0.category == category }
    }

    var categoriesWithChanges: [Category] {
        Category.allCases.filter { !items(in: $0).isEmpty }
    }

    var restorableItems: [Item] { items.filter(\.isRestorable) }

    // MARK: - Calcolo

    static func compute(restoring snapshot: HomeConfigurationSnapshot,
                        onto current: HomeConfigurationSnapshot) -> HomeSnapshotDiff {
        var items: [Item] = []
        items += roomItems(snapshot, current)
        items += zoneItems(snapshot, current)
        items += serviceGroupItems(snapshot, current)
        items += sceneItems(snapshot, current)
        items += accessoryItems(snapshot, current)
        items += automationItems(snapshot, current)
        return HomeSnapshotDiff(items: items)
    }

    // MARK: Stanze

    private static func roomItems(_ snapshot: HomeConfigurationSnapshot,
                                  _ current: HomeConfigurationSnapshot) -> [Item] {
        var items: [Item] = []
        let currentByName = Dictionary(current.rooms.map { ($0.address.name, $0) }, uniquingKeysWith: { a, _ in a })
        let currentByUUID = Dictionary(
            current.rooms.compactMap { room in room.address.localUUID.map { ($0, room) } },
            uniquingKeysWith: { a, _ in a })
        let snapshotNames = Set(snapshot.rooms.map(\.address.name))

        for room in snapshot.rooms {
            if currentByName[room.address.name] != nil { continue }
            // Stesso identificatore, nome diverso: è una rinomina, non una
            // stanza sparita più una comparsa. Vale solo sullo stesso device —
            // fra device gli identificatori non coincidono — ed è esattamente
            // dove serve.
            if let uuid = room.address.localUUID, let renamed = currentByUUID[uuid] {
                items.append(Item(id: "room.renamed.\(room.address.name)",
                                  category: .rooms, change: .changed,
                                  title: room.address.name,
                                  details: [String(format: String(localized: "diff.room.renamedTo",
                                                                  defaultValue: "now called “%@”"),
                                                   renamed.address.name)]))
            } else {
                items.append(Item(id: "room.missing.\(room.address.name)",
                                  category: .rooms, change: .missingNow,
                                  title: room.address.name, details: []))
            }
        }
        for room in current.rooms where !snapshotNames.contains(room.address.name) {
            let isRename = room.address.localUUID.map { uuid in
                snapshot.rooms.contains { $0.address.localUUID == uuid }
            } ?? false
            guard !isRename else { continue }
            items.append(Item(id: "room.new.\(room.address.name)",
                              category: .rooms, change: .newSinceThen,
                              title: room.address.name, details: []))
        }
        return items
    }

    // MARK: Zone e gruppi

    private static func zoneItems(_ snapshot: HomeConfigurationSnapshot,
                                  _ current: HomeConfigurationSnapshot) -> [Item] {
        let currentByName = Dictionary(current.zones.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let snapshotByName = Dictionary(snapshot.zones.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [Item] = []

        for zone in snapshot.zones {
            guard let now = currentByName[zone.name] else {
                items.append(Item(id: "zone.missing.\(zone.name)", category: .zones,
                                  change: .missingNow, title: zone.name,
                                  details: zone.roomNames.sorted()))
                continue
            }
            if Set(now.roomNames) != Set(zone.roomNames) {
                items.append(Item(id: "zone.changed.\(zone.name)", category: .zones,
                                  change: .changed, title: zone.name,
                                  details: roomListDifference(was: zone.roomNames, now: now.roomNames)))
            }
        }
        for zone in current.zones where snapshotByName[zone.name] == nil {
            items.append(Item(id: "zone.new.\(zone.name)", category: .zones,
                              change: .newSinceThen, title: zone.name, details: []))
        }
        return items
    }

    private static func serviceGroupItems(_ snapshot: HomeConfigurationSnapshot,
                                          _ current: HomeConfigurationSnapshot) -> [Item] {
        let currentNames = Set(current.serviceGroups.map(\.name))
        let snapshotNames = Set(snapshot.serviceGroups.map(\.name))
        return snapshot.serviceGroups
            .filter { !currentNames.contains($0.name) }
            .map { Item(id: "group.missing.\($0.name)", category: .serviceGroups,
                        change: .missingNow, title: $0.name, details: []) }
        + current.serviceGroups
            .filter { !snapshotNames.contains($0.name) }
            .map { Item(id: "group.new.\($0.name)", category: .serviceGroups,
                        change: .newSinceThen, title: $0.name, details: []) }
    }

    private static func roomListDifference(was: [String], now: [String]) -> [String] {
        let removed = Set(was).subtracting(now).sorted()
        let added = Set(now).subtracting(was).sorted()
        var lines: [String] = []
        for name in removed {
            lines.append(String(format: String(localized: "diff.zone.roomBack",
                                               defaultValue: "%@ would come back in"), name))
        }
        for name in added {
            lines.append(String(format: String(localized: "diff.zone.roomOut",
                                               defaultValue: "%@ was not in it"), name))
        }
        return lines
    }

    // MARK: Scene

    private static func sceneItems(_ snapshot: HomeConfigurationSnapshot,
                                   _ current: HomeConfigurationSnapshot) -> [Item] {
        let currentByName = Dictionary(current.scenes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let snapshotNames = Set(snapshot.scenes.map(\.name))
        var items: [Item] = []

        for scene in snapshot.scenes where !scene.isBuiltIn {
            // Se la cattura non ha letto nessuna azione, di questa scena
            // sappiamo solo che esisteva. Va detto, e non va offerta al
            // ripristino: non c'è niente da rimettere.
            let isReadable = !scene.actions.isEmpty

            guard let now = currentByName[scene.name] else {
                items.append(Item(id: "scene.missing.\(scene.name)", category: .scenes,
                                  change: .missingNow, title: scene.name,
                                  details: isReadable
                                    ? scene.actions.sorted { $0.sortKey < $1.sortKey }.map(actionDescription)
                                    : [unreadableNote(scene)],
                                  isRestorable: isReadable))
                continue
            }
            guard isReadable else {
                guard !now.actions.isEmpty || now.foreignActionCount != scene.foreignActionCount else { continue }
                items.append(Item(id: "scene.opaque.\(scene.name)", category: .scenes,
                                  change: .changed, title: scene.name,
                                  details: [unreadableNote(scene)], isRestorable: false))
                continue
            }
            let details = actionDifferences(was: scene.actions, now: now.actions)
            guard !details.isEmpty else { continue }
            items.append(Item(id: "scene.changed.\(scene.name)", category: .scenes,
                              change: .changed, title: scene.name, details: details))
        }
        for scene in current.scenes where !scene.isBuiltIn && !snapshotNames.contains(scene.name) {
            items.append(Item(id: "scene.new.\(scene.name)", category: .scenes,
                              change: .newSinceThen, title: scene.name, details: []))
        }
        return items
    }

    /// Le differenze fra le azioni di una scena, dette come le direbbe una
    /// persona. Il verso è sempre «cosa tornerebbe»: un'azione presente allora e
    /// non ora si rimette, una presente ora e non allora **resta** — non si
    /// cancella niente in un ripristino.
    private static func actionDifferences(was: [SceneActionSnapshot],
                                          now: [SceneActionSnapshot]) -> [String] {
        let nowByKey = Dictionary(now.map { ($0.sortKey, $0) }, uniquingKeysWith: { a, _ in a })
        var lines: [String] = []

        for action in was.sorted(by: { $0.sortKey < $1.sortKey }) {
            guard let current = nowByKey[action.sortKey] else {
                lines.append(String(format: String(localized: "diff.scene.actionBack",
                                                   defaultValue: "%@ would come back"),
                                    actionDescription(action)))
                continue
            }
            if current.value.canonicalText != action.value.canonicalText {
                lines.append(String(format: String(localized: "diff.scene.actionValue",
                                                   defaultValue: "%1$@: %2$@ instead of %3$@"),
                                    actionLabel(action),
                                    action.value.displayText,
                                    current.value.displayText))
            }
        }
        let wasKeys = Set(was.map(\.sortKey))
        for action in now.sorted(by: { $0.sortKey < $1.sortKey }) where !wasKeys.contains(action.sortKey) {
            lines.append(String(format: String(localized: "diff.scene.actionKept",
                                               defaultValue: "%@ was added later and stays"),
                                actionDescription(action)))
        }
        return lines
    }

    private static func unreadableNote(_ scene: SceneSnapshot) -> String {
        String(format: String(localized: "diff.scene.unreadable",
                              defaultValue: "The snapshot holds no readable action for it: its %d actions were of a kind this app cannot read."),
               scene.foreignActionCount)
    }

    private static func actionLabel(_ action: SceneActionSnapshot) -> String {
        "\(action.target.accessory.name) · "
            + SnapshotCharacteristicNames.readable(action.target.characteristicType)
    }

    private static func actionDescription(_ action: SceneActionSnapshot) -> String {
        "\(actionLabel(action)) → \(action.value.displayText)"
    }

    // MARK: Accessori

    private static func accessoryItems(_ snapshot: HomeConfigurationSnapshot,
                                       _ current: HomeConfigurationSnapshot) -> [Item] {
        var items: [Item] = []
        var unmatched = current.accessories

        for accessory in snapshot.accessories {
            guard let index = matchIndex(of: accessory, in: unmatched) else {
                items.append(Item(id: "acc.missing.\(accessory.address.name)", category: .accessories,
                                  change: .missingNow, title: accessory.address.name,
                                  details: [accessory.address.roomName].compactMap { $0 }))
                continue
            }
            let now = unmatched.remove(at: index)
            var details: [String] = []
            if now.address.name != accessory.address.name {
                details.append(String(format: String(localized: "diff.accessory.renamed",
                                                     defaultValue: "now called “%@”"), now.address.name))
            }
            if now.address.roomName != accessory.address.roomName {
                details.append(String(format: String(localized: "diff.accessory.moved",
                                                     defaultValue: "moved from %1$@ to %2$@"),
                                      accessory.address.roomName ?? "—", now.address.roomName ?? "—"))
            }
            guard !details.isEmpty else { continue }
            items.append(Item(id: "acc.changed.\(accessory.address.name)", category: .accessories,
                              change: .changed, title: accessory.address.name, details: details))
        }
        for accessory in unmatched {
            items.append(Item(id: "acc.new.\(accessory.address.name)", category: .accessories,
                              change: .newSinceThen, title: accessory.address.name,
                              details: [accessory.address.roomName].compactMap { $0 }))
        }
        return items
    }

    /// Seriale se c'è, altrimenti nome. Ogni criterio deve essere univoco: se
    /// due candidati rispondono, quel criterio non identifica niente.
    private static func matchIndex(of accessory: AccessorySnapshot,
                                   in candidates: [AccessorySnapshot]) -> Int? {
        if let serial = accessory.address.serialNumber, !serial.isEmpty {
            let matches = candidates.indices.filter { candidates[$0].address.serialNumber == serial }
            if matches.count == 1 { return matches[0] }
        }
        let matches = candidates.indices.filter {
            candidates[$0].address.name == accessory.address.name
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Perché questa automazione non tornerà indietro. La ragione più
    /// frequente è fuori dalla nostra portata — esegue un comando rapido — e
    /// dirlo evita di farlo sembrare un difetto dell'app.
    private static func unrestorableNote(_ automation: AutomationSnapshot) -> String {
        switch automation.content {
        case .shortcut:
            String(localized: "diff.automation.cannot.shortcut",
                   defaultValue: "cannot be recreated: it runs a Shortcut, which no third-party app can read")
        case .empty:
            String(localized: "diff.automation.cannot.empty",
                   defaultValue: "cannot be recreated: it had no action left to run")
        default:
            String(localized: "diff.automation.cannot.other",
                   defaultValue: "cannot be recreated: this app could not read its trigger in full")
        }
    }

    private static func describe(_ values: [String]) -> String {
        values.isEmpty
            ? String(localized: "diff.automation.nothing", defaultValue: "nothing")
            : values.sorted().joined(separator: ", ")
    }

    private static func contentLabel(_ content: AutomationSnapshot.Content) -> String {
        switch content {
        case .scene:                 String(localized: "diff.automation.content.scene", defaultValue: "a scene")
        case .readableInlineActions: String(localized: "diff.automation.content.inline", defaultValue: "direct actions")
        case .shortcut:              String(localized: "diff.automation.content.shortcut", defaultValue: "a shortcut")
        case .empty:                 String(localized: "diff.automation.content.empty", defaultValue: "nothing")
        case .other:                 String(localized: "diff.automation.content.other", defaultValue: "something unknown")
        }
    }

    // MARK: Automazioni

    private static func automationItems(_ snapshot: HomeConfigurationSnapshot,
                                        _ current: HomeConfigurationSnapshot) -> [Item] {
        let currentByName = Dictionary(current.automations.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let snapshotNames = Set(snapshot.automations.map(\.name))
        var items: [Item] = []

        for automation in snapshot.automations {
            guard let now = currentByName[automation.name] else {
                // Solo qui la voce può essere ripristinabile, e solo se la
                // cattura ne ha salvato la forma ricostruibile.
                let plan = automation.restorable
                items.append(Item(id: "auto.missing.\(automation.name)", category: .automations,
                                  change: .missingNow, title: automation.name,
                                  details: plan?.confirmationLines
                                    ?? [automation.humanSummary, unrestorableNote(automation)],
                                  isRestorable: plan != nil))
                continue
            }
            var details: [String] = []

            if now.isEnabled != automation.isEnabled {
                details.append(automation.isEnabled
                               ? String(localized: "diff.automation.wasOn",
                                        defaultValue: "was on, is now paused")
                               : String(localized: "diff.automation.wasOff",
                                        defaultValue: "was paused, is now on"))
            }
            // Cosa esegue. È la modifica che si fa davvero — «ora lancia
            // un'altra scena» — e confrontare solo nome e stato attivo la
            // lasciava passare del tutto inosservata.
            if Set(now.actionSetNames) != Set(automation.actionSetNames) {
                details.append(String(format: String(localized: "diff.automation.runs",
                                                     defaultValue: "ran %1$@, now runs %2$@"),
                                      describe(automation.actionSetNames), describe(now.actionSetNames)))
            }
            if now.content != automation.content {
                details.append(String(format: String(localized: "diff.automation.content",
                                                     defaultValue: "what it executes changed (%1$@ → %2$@)"),
                                      contentLabel(automation.content), contentLabel(now.content)))
            }
            // Quando scatta e a quali condizioni: la cattura le tiene già in
            // lingua, quindi il confronto è sul testo che l'utente leggerebbe.
            if now.humanSummary != automation.humanSummary {
                details.append(String(format: String(localized: "diff.automation.trigger",
                                                     defaultValue: "fired %1$@, now fires %2$@"),
                                      automation.humanSummary, now.humanSummary))
            }
            if Set(now.conditionSummaries) != Set(automation.conditionSummaries) {
                details.append(String(format: String(localized: "diff.automation.conditions",
                                                     defaultValue: "conditions: %1$@ → %2$@"),
                                      describe(automation.conditionSummaries), describe(now.conditionSummaries)))
            }

            if !details.isEmpty {
                // Modificata, non sparita: ricrearla produrrebbe un doppione.
                // Si mostra la differenza e ci si ferma lì.
                items.append(Item(id: "auto.changed.\(automation.name)", category: .automations,
                                  change: .changed, title: automation.name,
                                  details: details, isRestorable: false))
            }
        }
        for automation in current.automations where !snapshotNames.contains(automation.name) {
            items.append(Item(id: "auto.new.\(automation.name)", category: .automations,
                              change: .newSinceThen, title: automation.name, details: []))
        }
        return items
    }
}
