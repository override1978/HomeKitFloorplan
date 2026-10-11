import SwiftUI

// MARK: - HomeAnalysisSnippetView

/// Scheda mostrata da Siri e Comandi sotto la risposta di "Analizza casa".
///
/// La disegna il sistema, fuori dall'app: solo colori e stili di sistema, e
/// nessun controllo con closure (in uno snippet statico non eseguirebbe nulla).
struct HomeAnalysisSnippetView: View {
    let summary: HomeAnalysisSummary

    private var roomsToCheck: Int {
        summary.rooms.filter { $0.urgency != .normal }.count
    }

    private var worstUrgency: SensorUrgency {
        summary.rooms.map(\.urgency).max() ?? .normal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            // La frase complessiva della casa: il clima in numeri. Il verdetto
            // per stanza non serve qui, lo porta già la lista sotto.
            if let climate = summary.climate {
                Text(climate)
                    .font(.subheadline)
            }

            if !summary.rooms.isEmpty {
                VStack(spacing: 0) {
                    ForEach(summary.rooms) { row in
                        roomRow(row)
                        if row.id != summary.rooms.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }

            if summary.aiPending {
                Label(HomeAnalysisSummary.aiPendingText, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    /// Lo stato generale per primo, grande: è la risposta alla domanda.
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: roomsToCheck == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(Self.color(for: worstUrgency))
            VStack(alignment: .leading, spacing: 1) {
                Text(statusLabel)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Self.color(for: worstUrgency))
                Text(String(localized: "home.digest.environment.title", defaultValue: "Home environment"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusLabel: String {
        roomsToCheck == 0
            ? String(localized: "home.digest.status.stable", defaultValue: "Stable")
            : String(format: String(localized: "home.digest.environment.roomsToCheck", defaultValue: "%lld to check"),
                     roomsToCheck)
    }

    private func roomRow(_ row: HomeAnalysisSummary.RoomRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(Self.color(for: row.urgency))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.subheadline.weight(.medium))
                // Una sola spiegazione per stanza: quella dell'AI se c'è,
                // altrimenti il valore fuori norma — ma solo se la riga non lo
                // mostra già a destra (temperatura e umidità si colorano lì).
                if let note = row.aiNote {
                    Label(note, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let issue = row.issue, !Self.isShownInline(row.issueType) {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(Self.color(for: row.urgency))
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                if let temperature = row.temperature {
                    Label(temperature, systemImage: "thermometer.medium")
                        .foregroundStyle(valueColor(row, for: .temperature))
                }
                if let humidity = row.humidity {
                    Label(humidity, systemImage: "humidity")
                        .foregroundStyle(valueColor(row, for: .humidity))
                }
            }
            .font(.subheadline.monospacedDigit())
            .labelStyle(CompactValueLabelStyle())
        }
        .padding(.vertical, 8)
    }

    private static func isShownInline(_ type: SensorServiceType?) -> Bool {
        type == .temperature || type == .humidity
    }

    private func valueColor(_ row: HomeAnalysisSummary.RoomRow, for type: SensorServiceType) -> Color {
        row.issueType == type ? Self.color(for: row.urgency) : .primary
    }

    private static func color(for urgency: SensorUrgency) -> Color {
        switch urgency {
        case .normal:  return .green
        case .warning: return .orange
        case .danger:  return .red
        }
    }
}

/// Icona piccola e valore vicini: in una riga stretta l'etichetta standard spreca spazio.
private struct CompactValueLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
                .font(.caption)
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}

#Preview("Analizza casa") {
    HomeAnalysisSnippetView(summary: HomeAnalysisSummary(
        verdict: "Bagno richiede attenzione: umidità è a 78%.",
        climate: "Dentro casa: 21.4°C di media (Camera 19.8°C – Soggiorno 23.1°C) · umidità 55%",
        rooms: [
            .init(name: "Bagno", temperature: "22.6°C", humidity: "78%", issue: "Umidità: 78%",
                  issueType: .humidity, urgency: .warning,
                  aiNote: "Umidità alta dopo la doccia → Accendi aspiratore"),
            .init(name: "Cucina", temperature: "21.9°C", humidity: "52%", issue: "CO₂: 1350 ppm",
                  issueType: .carbonDioxide, urgency: .warning),
            .init(name: "Camera", temperature: "19.8°C", humidity: "49%", issue: nil,
                  issueType: nil, urgency: .normal),
            .init(name: "Soggiorno", temperature: "23.1°C", humidity: "47%", issue: nil,
                  issueType: nil, urgency: .normal)
        ]
    ))
}
