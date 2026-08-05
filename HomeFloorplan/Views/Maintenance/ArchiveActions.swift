import SwiftUI
import HomeKit

// MARK: - Archiviare dal vivo

/// Il gesto «mettila da parte», dove si guarda la cosa da mettere da parte.
///
/// Sta qui e non in Manutenzione perché il momento in cui serve è quello in cui
/// si sta per cambiare qualcosa — si è nell'elenco delle scene, non in un
/// pannello di backup. Chiedere di andare altrove *prima* di modificare è il
/// modo migliore per non farlo fare a nessuno.
private struct ArchiveSceneModifier: ViewModifier {
    let scene: SceneItem

    @Environment(ArchiveStore.self) private var archive
    @Environment(HomeSnapshotCapture.self) private var capture
    @Environment(HomeKitService.self) private var homeKit

    @State private var justArchived = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    Task { await archiveScene() }
                } label: {
                    Label(String(localized: "archive.action", defaultValue: "Set aside for later"),
                          systemImage: "archivebox")
                }
            }
            // Una copia salvata non cambia niente a schermo, quindi senza un
            // segnale il gesto sembra non aver fatto nulla.
            .sensoryFeedback(.success, trigger: justArchived)
    }

    private func archiveScene() async {
        guard let home = homeKit.currentHome else { return }
        let snapshot = await capture.snapshot(of: scene.actionSet)
        archive.add(ArchivedItem(name: scene.name,
                                 homeName: home.name,
                                 deviceName: AppDeviceIdentity.displayName,
                                 content: .scene(snapshot)))
        justArchived.toggle()
    }
}

private struct ArchiveAutomationModifier: ViewModifier {
    let automation: AutomationItem

    @Environment(ArchiveStore.self) private var archive
    @Environment(HomeSnapshotCapture.self) private var capture
    @Environment(HomeKitService.self) private var homeKit

    @State private var justArchived = false
    @State private var refusal: String?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    Task { await archiveAutomation() }
                } label: {
                    Label(String(localized: "archive.action", defaultValue: "Set aside for later"),
                          systemImage: "archivebox")
                }
            }
            .sensoryFeedback(.success, trigger: justArchived)
            // Se non è ricreabile lo si dice **adesso**, non scoprendolo il
            // giorno in cui la si vuole rimettere: una copia che non torna
            // indietro è una promessa che non possiamo mantenere.
            .alert(String(localized: "archive.cannot.title", defaultValue: "Cannot be set aside"),
                   isPresented: Binding(get: { refusal != nil },
                                        set: { if !$0 { refusal = nil } })) {
                Button("OK", role: .cancel) { refusal = nil }
            } message: {
                Text(refusal ?? "")
            }
    }

    private func archiveAutomation() async {
        guard let home = homeKit.currentHome else { return }
        let result = await capture.restorablePlan(of: automation.trigger)
        guard let plan = result.plan else {
            refusal = result.reason
                ?? String(localized: "restorableAutomation.fail.unsupported",
                          defaultValue: "this trigger cannot be recreated")
            return
        }
        archive.add(ArchivedItem(name: automation.name,
                                 homeName: home.name,
                                 deviceName: AppDeviceIdentity.displayName,
                                 content: .automation(plan)))
        justArchived.toggle()
    }
}

extension View {
    func archivable(scene: SceneItem) -> some View {
        modifier(ArchiveSceneModifier(scene: scene))
    }

    func archivable(automation: AutomationItem) -> some View {
        modifier(ArchiveAutomationModifier(automation: automation))
    }
}
