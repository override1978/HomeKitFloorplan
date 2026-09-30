import SwiftUI
import SwiftData

// MARK: - ICloudSettingsView

/// Il dettaglio della sincronizzazione: ruolo del dispositivo, stato e
/// diagnostica.
///
/// Il ruolo conta piu' di quanto sembri — il dispositivo primario e' l'unico
/// che fa girare l'analisi comportamentale — ma e' una cosa che si imposta una
/// volta e non si guarda piu': sta bene dietro una riga, non davanti.
struct ICloudSettingsView: View {

    @Environment(CloudKitSyncService.self) private var cloudKitSync
    @Query(sort: \SyncableSettings.modifiedAt) private var settingsArray: [SyncableSettings]

    private var syncableSettings: SyncableSettings? { settingsArray.first }

    private var isMasterDevice: Bool {
        guard let settings = syncableSettings else { return true }
        return settings.masterDeviceID.isEmpty || settings.masterDeviceID == DeviceIdentity.id
    }

    private var deviceRole: String {
        guard let settings = syncableSettings, !settings.masterDeviceID.isEmpty else {
            return String(localized: "settings.device.role.master", defaultValue: "Primary")
        }
        return settings.masterDeviceID == DeviceIdentity.id
            ? String(localized: "settings.device.role.master", defaultValue: "Primary")
            : String(localized: "settings.device.role.slave",  defaultValue: "Secondary")
    }

    private var status: SettingsSyncStatus { SettingsSyncStatus(service: cloudKitSync) }

    var body: some View {
        Form {
            Section {
                syncRow
            } footer: {
                if isMasterDevice {
                    Text(String(localized: "settings.icloud.master.footer", defaultValue: "Floorplans, settings, and automation opportunities sync automatically via iCloud. This device runs behavioral analysis and generates automation suggestions."))
                } else {
                    Text(String(localized: "settings.icloud.slave.footer", defaultValue: "Floorplans, settings, and automation opportunities sync automatically via iCloud. This device receives data from iCloud; tap \"Become Primary\" to run analysis here instead."))
                }
            }

            Section {
                HStack {
                    Label(String(localized: "settings.device.role.label", defaultValue: "Device Role"),
                          systemImage: isMasterDevice ? "iphone.badge.play" : "iphone")
                    Spacer()
                    Text(deviceRole)
                        .foregroundStyle(.secondary)
                }

                if !isMasterDevice {
                    Button {
                        cloudKitSync.becomeMaster()
                    } label: {
                        Label(String(localized: "settings.device.becomeMaster", defaultValue: "Become Primary Device"),
                              systemImage: "crown")
                            .foregroundStyle(.tint)
                    }
                }
            }

            Section {
                ShareLink(item: SyncDiagnosticsLogger.fileURL) {
                    Label(String(localized: "settings.icloud.diagnostics.export", defaultValue: "Export Sync Diagnostics"),
                          systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle(String(localized: "settings.icloud.header", defaultValue: "iCloud"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var syncRow: some View {
        HStack(spacing: 12) {
            Group {
                if cloudKitSync.isSyncing {
                    ProgressView()
                } else {
                    Image(systemName: status.symbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(status.color)
                }
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "settings.icloud.sync.title", defaultValue: "Sync status"))
                    .foregroundStyle(.primary)
                Text(status.detailText)
                    .font(.caption)
                    .foregroundStyle(status.color == .red ? .red : .secondary)
                    .lineLimit(2)
            }

            Spacer()

            SettingsStatusPill(text: status.shortLabel, color: status.color)
        }
        .padding(.vertical, 2)
    }
}
