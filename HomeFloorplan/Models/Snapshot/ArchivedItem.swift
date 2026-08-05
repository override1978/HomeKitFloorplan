import Foundation

// MARK: - ArchivedItem

/// Una **singola** scena o automazione messa da parte.
///
/// Non è un backup ridotto: è l'altro gesto. Uno snapshot si fa prima di toccare
/// *la casa*, questo si fa prima di toccare *una cosa* — sto per rimettere mano
/// a «Cinema», la salvo com'è adesso. Per pescare una scena da un backup intero
/// esiste già il ripristino selettivo, e duplicarlo qui aggiungerebbe un
/// passaggio senza aggiungere capacità.
struct ArchivedItem: Codable, Identifiable, Sendable {

    enum Content: Codable, Sendable {
        case scene(SceneSnapshot)
        /// Solo automazioni che l'app sa ricreare: archiviarne una che non
        /// tornerà indietro sarebbe una promessa che non possiamo mantenere.
        case automation(RestorableAutomation)
    }

    let id: UUID
    /// Il nome che aveva quando è stata archiviata. Resta quello anche se in
    /// casa nel frattempo cambia: è l'etichetta della copia, non un riferimento.
    let name: String
    let archivedAt: Date
    let deviceName: String
    let homeName: String
    /// Perché è stata messa da parte. Facoltativo, e come per gli snapshot vale
    /// più della data.
    var note: String
    let content: Content

    init(name: String,
         homeName: String,
         deviceName: String,
         note: String = "",
         content: Content,
         now: Date = Date()) {
        self.id = UUID()
        self.name = name
        self.homeName = homeName
        self.deviceName = deviceName
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.content = content
        self.archivedAt = now
    }
}

extension ArchivedItem {

    var isScene: Bool {
        if case .scene = content { return true }
        return false
    }

    var symbolName: String { isScene ? "wand.and.sparkles" : "gearshape.2" }

    /// Cosa contiene, in una riga: è quello che si legge scorrendo l'elenco per
    /// ritrovare la copia giusta.
    var summary: String {
        switch content {
        case .scene(let scene):
            let accessories = Set(scene.actions.map { $0.target.accessory.name }).count
            return String(format: String(localized: "archive.scene.summary",
                                         defaultValue: "%1$d accessories · %2$d values"),
                          accessories, scene.actions.count)
        case .automation(let plan):
            return plan.confirmationLines.first ?? ""
        }
    }
}
