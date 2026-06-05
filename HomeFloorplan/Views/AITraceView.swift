#if DEBUG
import SwiftUI

// MARK: - AITraceView
//
// Debug-only view che mostra il trace log del pipeline AI ambientale.
// Accessibile da Impostazioni → Sviluppatore → AI Pipeline Trace.
//
// Layout:
//   ┌─ Daily Summary (contatori aggregati) ─────────────────────────┐
//   │  Analyses run: 12   Skipped: 8 (40%)   Insights: 4           │
//   │  Severity clamps: 1  Intent filters: 2                        │
//   │  By sensor: humidity×9, temperature×6, carbonDioxide×5        │
//   └───────────────────────────────────────────────────────────────┘
//   ┌─ Entry recenti (ring buffer, ultimi 500 / 24h) ───────────────┐
//   │  [P1] Cucina  •  temperature=22.1, humidity=68.0              │
//   │  [P2] Cucina  •  roomType=indoor ceiling=warning shouldCall=true │
//   │  ...                                                           │
//   └───────────────────────────────────────────────────────────────┘

@MainActor
struct AITraceView: View {

    @State private var logger = AITraceLogger.shared
    @State private var showResetConfirm = false
    @State private var filterPhase: Int? = nil  // nil = tutti

    private var filteredEntries: [AITraceEntry] {
        let all = logger.entries.reversed()
        if let phase = filterPhase {
            return Array(all.filter { $0.phase == phase })
        }
        return Array(all)
    }

    var body: some View {
        List {
            // ── Daily Summary ──────────────────────────────────────────
            Section {
                summaryGrid
            } header: {
                Label("Riepilogo giornaliero", systemImage: "chart.bar.fill")
            } footer: {
                Text("I contatori si azzerano automaticamente a mezzanotte.")
                    .font(.caption)
            }

            // ── Phase filter chips ─────────────────────────────────────
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        PhaseChip(label: "Tutti", phase: nil, selected: filterPhase == nil) {
                            filterPhase = nil
                        }
                        ForEach(1...7, id: \.self) { phase in
                            PhaseChip(label: "P\(phase)", phase: phase, selected: filterPhase == phase) {
                                filterPhase = (filterPhase == phase) ? nil : phase
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            } header: {
                Label("Filtra per fase", systemImage: "line.3.horizontal.decrease.circle")
            }

            // ── Entry ring buffer ──────────────────────────────────────
            Section {
                if filteredEntries.isEmpty {
                    ContentUnavailableView(
                        "Nessun trace disponibile",
                        systemImage: "waveform.slash",
                        description: Text("Avvia un'analisi ambientale per vedere i dati qui.")
                    )
                } else {
                    ForEach(filteredEntries) { entry in
                        TraceEntryRow(entry: entry)
                    }
                }
            } header: {
                HStack {
                    Label("Trace recenti", systemImage: "list.bullet.rectangle")
                    Spacer()
                    Text("\(filteredEntries.count) entry")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("AI Pipeline Trace")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("Reset contatori", systemImage: "trash")
                }
            }
        }
        .confirmationDialog(
            "Reset contatori",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Azzera", role: .destructive) {
                logger.resetCounters()
            }
            Button("Annulla", role: .cancel) { }
        } message: {
            Text("Verranno azzerati tutti i contatori giornalieri. Le entry recenti rimarranno.")
        }
    }

    // MARK: - Summary Grid

    private var summaryGrid: some View {
        VStack(spacing: 12) {
            // Riga 1: analisi run/skip
            HStack(spacing: 0) {
                SummaryTile(
                    value: "\(logger.totalAnalysesRun)",
                    label: "Analisi",
                    icon: "brain",
                    color: .blue
                )
                Divider()
                SummaryTile(
                    value: "\(logger.totalAnalysesSkipped)",
                    label: "Saltate",
                    icon: "bolt.slash",
                    color: .secondary
                )
                Divider()
                SummaryTile(
                    value: skipRateString,
                    label: "Skip rate",
                    icon: "percent",
                    color: .orange
                )
            }
            .frame(height: 60)

            Divider()

            // Riga 2: insight/clamp/filter
            HStack(spacing: 0) {
                SummaryTile(
                    value: "\(logger.totalInsightsGenerated)",
                    label: "Insights",
                    icon: "sparkles",
                    color: .purple
                )
                Divider()
                SummaryTile(
                    value: "\(logger.totalSeverityClamps)",
                    label: "Clamps",
                    icon: "arrow.down.circle",
                    color: .red
                )
                Divider()
                SummaryTile(
                    value: "\(logger.totalIntentFilters)",
                    label: "Filtri",
                    icon: "xmark.circle",
                    color: .orange
                )
            }
            .frame(height: 60)

            Divider()

            // Riga 3: low anomalies (false positive indicator)
            HStack(spacing: 0) {
                SummaryTile(
                    value: "\(logger.totalLowAnomalies)",
                    label: "Low Anom.",
                    icon: "arrow.down.circle.dotted",
                    color: logger.totalLowAnomalies > 0 ? .yellow : .secondary
                )
                Divider()
                // Rapporto low-anomalie su analisi totali
                SummaryTile(
                    value: lowAnomalyRateString,
                    label: "FP rate",
                    icon: "exclamationmark.triangle",
                    color: lowAnomalyRateValue > 0.3 ? .red : (lowAnomalyRateValue > 0.1 ? .orange : .secondary)
                )
                Divider()
                SummaryTile(
                    value: "\(logger.totalAnalysesRun + logger.totalAnalysesSkipped)",
                    label: "Totale check",
                    icon: "checkmark.seal",
                    color: .teal
                )
            }
            .frame(height: 60)

            // Riga 3: by sensor (se disponibile)
            if !logger.analysesBySensor.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Per sensore")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(
                            logger.analysesBySensor.sorted(by: { $0.value > $1.value }),
                            id: \.key
                        ) { sensor, count in
                            SensorCountChip(sensor: sensor, count: count)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var skipRateString: String {
        let total = logger.totalAnalysesRun + logger.totalAnalysesSkipped
        guard total > 0 else { return "–" }
        let pct = Int(Double(logger.totalAnalysesSkipped) / Double(total) * 100)
        return "\(pct)%"
    }

    private var lowAnomalyRateValue: Double {
        let total = logger.totalAnalysesRun + logger.totalAnalysesSkipped
        guard total > 0 else { return 0 }
        return Double(logger.totalLowAnomalies) / Double(total)
    }

    private var lowAnomalyRateString: String {
        let total = logger.totalAnalysesRun + logger.totalAnalysesSkipped
        guard total > 0 else { return "–" }
        let pct = Int(lowAnomalyRateValue * 100)
        return "\(pct)%"
    }
}

// MARK: - SummaryTile

private struct SummaryTile: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - SensorCountChip

private struct SensorCountChip: View {
    let sensor: String
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(sensor)
                .font(.caption2.weight(.medium))
            Text("×\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
    }
}

// MARK: - PhaseChip

private struct PhaseChip: View {
    let label: String
    let phase: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    selected
                        ? Color.blue
                        : Color(.tertiarySystemGroupedBackground),
                    in: Capsule()
                )
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - TraceEntryRow

private struct TraceEntryRow: View {

    let entry: AITraceEntry

    private var phaseColor: Color {
        switch entry.phase {
        case 1: return .gray
        case 2: return .blue
        case 3: return .indigo
        case 4: return .purple
        case 5: return .orange
        case 6: return .teal
        case 7: return .green
        default: return .secondary
        }
    }

    private var phaseLabel: String {
        switch entry.phase {
        case 1: return "Raw"
        case 2: return "Pre"
        case 3: return "Pay"
        case 4: return "AI"
        case 5: return "Val"
        case 6: return "Res"
        case 7: return "Out"
        default: return "P\(entry.phase)"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Badge fase
            Text(phaseLabel)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(phaseColor, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.roomName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(entry.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text(entry.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - FlowLayout
// Layout a righe che va a capo automaticamente (per i chip sensore).

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > width, rowWidth > 0 {
                height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
