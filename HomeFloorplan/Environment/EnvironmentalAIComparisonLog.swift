#if DEBUG
import SwiftUI

// MARK: - EnvironmentalAIComparisonLog

/// Confronto sul campo fra Apple Intelligence locale e Claude — solo DEBUG.
///
/// Sui dispositivi con Apple Intelligence e Claude configurato, ogni analisi
/// di stanza gira con entrambi i motori sugli stessi dati; qui restano le
/// ultime 40 coppie, per decidere leggendo le risposte vere invece che a
/// intuito. In Release questo file non esiste.
enum EnvironmentalAIComparisonLog {

    struct Entry: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let roomName: String
        let onDevice: Reply
        let claude: Reply?
        let onDeviceSeconds: Double
        let claudeSeconds: Double?
    }

    struct Reply: Codable {
        let hasInsight: Bool
        let message: String
        let severity: String
        let intents: [String]

        init(json: String) {
            let object = json.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            hasInsight = object["hasInsight"] as? Bool ?? false
            message = object["message"] as? String ?? String(json.prefix(160))
            severity = object["severity"] as? String ?? "—"
            intents = object["intents"] as? [String] ?? []
        }
    }

    private static let key = "debug.environmentalAIComparison"
    private static let limit = 40

    static var entries: [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func record(roomName: String, onDevice: String, onDeviceDuration: Duration,
                       claude: String?, claudeDuration: Duration) {
        let entry = Entry(
            date: Date(),
            roomName: roomName,
            onDevice: Reply(json: onDevice),
            claude: claude.map { Reply(json: $0) },
            onDeviceSeconds: onDeviceDuration.seconds,
            claudeSeconds: claude == nil ? nil : claudeDuration.seconds
        )
        let updated = Array(([entry] + entries).prefix(limit))
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: key)
        }
        dprint("🆚 [AI A/B] \(roomName)\n   on-device (\(String(format: "%.1f", entry.onDeviceSeconds))s): \(entry.onDevice.message)\n   claude: \(entry.claude?.message ?? "—")")
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

// MARK: - EnvironmentalAIComparisonView

/// Le coppie di risposte, la più recente in alto.
struct EnvironmentalAIComparisonView: View {
    @State private var entries = EnvironmentalAIComparisonLog.entries

    var body: some View {
        List {
            if entries.isEmpty {
                Text(verbatim: "Nessun confronto ancora. Serve un dispositivo con Apple Intelligence e Claude configurato: le coppie arrivano con le analisi ambientali.")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(verbatim: entry.roomName).font(.headline)
                        Spacer()
                        Text(entry.date, format: .dateTime.day().month().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    replyRow(engine: "Apple Intelligence", seconds: entry.onDeviceSeconds,
                             reply: entry.onDevice, symbol: "apple.intelligence")
                    if let claude = entry.claude {
                        replyRow(engine: "Claude", seconds: entry.claudeSeconds,
                                 reply: claude, symbol: "cloud")
                    } else {
                        Label { Text(verbatim: "Claude: nessuna risposta") } icon: { Image(systemName: "cloud") }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(Text(verbatim: "Confronto motori AI"))
        .toolbar {
            Button {
                EnvironmentalAIComparisonLog.clear()
                entries = []
            } label: {
                Text(verbatim: "Svuota")
            }
            .disabled(entries.isEmpty)
        }
    }

    private func replyRow(engine: String, seconds: Double?, reply: EnvironmentalAIComparisonLog.Reply,
                          symbol: String) -> some View {
        let timing = seconds.map { String(format: "%.1f s", $0) } ?? "—"
        let intents = reply.intents.isEmpty ? "" : " · " + reply.intents.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(verbatim: "\(engine) · \(timing) · \(reply.severity)\(intents)")
            } icon: {
                Image(systemName: symbol)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Text(verbatim: reply.hasInsight ? reply.message : "(nessun insight)")
                .font(.subheadline)
                .foregroundStyle(reply.hasInsight ? .primary : .secondary)
        }
    }
}
#endif
