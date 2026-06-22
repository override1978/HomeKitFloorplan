import AppIntents
import Foundation

enum SmartLightingIntentBridge {
    private static weak var engine: SmartLightingEngine?
    private static let globalEnabledKey = "smartLighting.globalEnabled"
    private static let userPausedKey = "smartLighting.userPaused"

    @MainActor
    static func register(engine: SmartLightingEngine) {
        self.engine = engine
    }

    @MainActor
    static func pause() -> String {
        if let engine {
            engine.pauseFromFloorplan()
        } else {
            UserDefaults.standard.set(true, forKey: userPausedKey)
        }
        return "Luci automatiche messe in pausa."
    }

    @MainActor
    static func resume() -> String {
        if let engine {
            engine.resumeFromFloorplan()
        } else {
            UserDefaults.standard.set(false, forKey: userPausedKey)
        }
        return "Luci automatiche riattivate."
    }

    @MainActor
    static func status() -> String {
        if let engine {
            return engine.statusSummary
        }
        if UserDefaults.standard.bool(forKey: userPausedKey) {
            return "Luci automatiche in pausa."
        }
        if UserDefaults.standard.bool(forKey: globalEnabledKey) {
            return "Luci automatiche attive."
        }
        return "Luci automatiche disattivate."
    }
}

struct PauseSmartLightingIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Smart Lighting"
    static var description = IntentDescription("Pauses the Home Floorplan Smart Lighting engine.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await SmartLightingIntentBridge.pause()
        return .result(dialog: "\(message)")
    }
}

struct ResumeSmartLightingIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Smart Lighting"
    static var description = IntentDescription("Resumes the Home Floorplan Smart Lighting engine.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await SmartLightingIntentBridge.resume()
        return .result(dialog: "\(message)")
    }
}

struct SmartLightingStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Smart Lighting Status"
    static var description = IntentDescription("Returns the current Home Floorplan Smart Lighting status.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await SmartLightingIntentBridge.status()
        return .result(dialog: "\(message)")
    }
}

struct FloorplanPingIntent: AppIntent {
    static var title: LocalizedStringResource = "Floorplan Test"
    static var description = IntentDescription("Checks whether Home Floorplan App Intents are available.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        return .result(dialog: "Home Floorplan risponde.")
    }
}

struct SmartLightingAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PauseSmartLightingIntent(),
            phrases: [
                "Pausa luci con \(.applicationName)",
                "Ferma luci con \(.applicationName)",
                "Pausa luci automatiche con \(.applicationName)",
                "Ferma luci automatiche con \(.applicationName)",
                "Metti in pausa Smart Lighting con \(.applicationName)",
                "Pausa Smart Lighting con \(.applicationName)",
                "Pause Smart Lighting with \(.applicationName)"
            ],
            shortTitle: "Pause Lights",
            systemImageName: "pause.circle"
        )

        AppShortcut(
            intent: ResumeSmartLightingIntent(),
            phrases: [
                "Avvia luci con \(.applicationName)",
                "Riprendi luci con \(.applicationName)",
                "Avvia luci automatiche con \(.applicationName)",
                "Riprendi luci automatiche con \(.applicationName)",
                "Riattiva Smart Lighting con \(.applicationName)",
                "Avvia Smart Lighting con \(.applicationName)",
                "Resume Smart Lighting with \(.applicationName)",
                "Play Smart Lighting with \(.applicationName)"
            ],
            shortTitle: "Resume Lights",
            systemImageName: "play.circle"
        )

        AppShortcut(
            intent: SmartLightingStatusIntent(),
            phrases: [
                "Stato luci con \(.applicationName)",
                "Stato luci automatiche con \(.applicationName)",
                "Come sono le luci con \(.applicationName)",
                "Stato Smart Lighting con \(.applicationName)",
                "Dimmi lo stato Smart Lighting con \(.applicationName)",
                "Smart Lighting status with \(.applicationName)"
            ],
            shortTitle: "Lights Status",
            systemImageName: "lightbulb.circle"
        )

        AppShortcut(
            intent: FloorplanPingIntent(),
            phrases: [
                "Test \(.applicationName)",
                "Prova \(.applicationName)",
                "Test with \(.applicationName)"
            ],
            shortTitle: "Test Floorplan",
            systemImageName: "checkmark.circle"
        )
    }
}
