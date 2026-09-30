import SwiftUI

// MARK: - SettingsStatusPill

/// La pastiglia di stato delle Impostazioni.
///
/// Vive in un file suo perche' la usano tre schermate diverse: l'elenco
/// principale, il dettaglio iCloud e quello dei dati. Era una funzione privata
/// dentro `SettingsView`, e portarla altrove per copia e' il modo in cui due
/// pastiglie identiche cominciano a divergere di un punto di padding.
struct SettingsStatusPill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Stato della sincronizzazione

/// Come sta iCloud adesso, in una forma che sia la riga di riepilogo sia la
/// schermata di dettaglio possono mostrare.
///
/// Sono la stessa informazione in due posti: se la calcolassero per conto
/// proprio, prima o poi l'elenco direbbe "in pari" mentre il dettaglio dice
/// "errore".
enum SettingsSyncStatus {
    case syncing
    case failed(String)
    case synced(Date)
    case never

    init(service: CloudKitSyncService) {
        if service.isSyncing {
            self = .syncing
        } else if let error = service.lastError {
            self = .failed(error.localizedDescription)
        } else if let date = service.lastSyncedAt {
            self = .synced(date)
        } else {
            self = .never
        }
    }

    var shortLabel: String {
        switch self {
        case .syncing: return String(localized: "settings.icloud.status.active", defaultValue: "Active")
        case .failed:  return String(localized: "settings.icloud.status.error", defaultValue: "Error")
        case .synced:  return String(localized: "settings.icloud.status.ok", defaultValue: "In sync")
        case .never:   return String(localized: "settings.icloud.status.notYet", defaultValue: "Not yet synced")
        }
    }

    var color: Color {
        switch self {
        case .syncing: return BrandColor.primary
        case .failed:  return .red
        case .synced:  return .green
        case .never:   return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .failed: return "exclamationmark.icloud"
        case .synced: return "checkmark.icloud"
        default:      return "icloud"
        }
    }

    /// La riga lunga del dettaglio: dice *quando*, non solo *come*.
    var detailText: String {
        switch self {
        case .syncing:
            return String(localized: "settings.icloud.status.syncing", defaultValue: "Syncing…")
        case .failed(let message):
            return message
        case .synced(let date):
            return String(format: String(localized: "settings.icloud.status.lastSync",
                                         defaultValue: "Last synced %@"),
                          date.formatted(.relative(presentation: .named)))
        case .never:
            return String(localized: "settings.icloud.status.notYet", defaultValue: "Not yet synced")
        }
    }
}
