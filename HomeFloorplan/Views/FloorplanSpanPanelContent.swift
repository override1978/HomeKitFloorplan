import SwiftUI

// MARK: - FloorplanSpanPanelContent

/// Il dettaglio di un periodo: quanto è durato, e se sta ancora durando.
///
/// Il pannello più corto dei tre, ed è giusto così. Un'automazione futura
/// chiede «la fermo?», un gesto chiede «lo ripeto?», ma un periodo per lo più
/// non chiede niente: dice per quanto una cosa è stata accesa, che è
/// un'informazione completa in sé. L'unico verbo appare quando sta ancora
/// girando — perché è l'unico momento in cui c'è qualcosa da fare.
struct FloorplanSpanPanelContent: View {

    let span: DaySpan
    @Bindable var overlayVM: FloorplanOverlayViewModel

    @Environment(HomeKitService.self) private var homeKit

    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            facts
            if span.isRunning { stopVerb }
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: span.isRunning ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                Text(Self.durationText(span.duration(now: Date())))
                    .font(.title3.weight(.bold).monospacedDigit())
                Spacer()
                Button { overlayVM.closeDetailContent() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(span.name)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let room = span.roomName {
                Text(room).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(icon: span.startedByHand ? "hand.tap" : "play.circle",
                // Il bordo della finestra non è un inizio: dirlo «dalle 00:00»
                // sarebbe inventare un'accensione che non abbiamo visto.
                text: span.startsBeforeWindow
                    ? String(localized: "span.startedEarlier", defaultValue: "Era già acceso a inizio giornata")
                    : String(format: span.startedByHand
                                ? String(localized: "span.startedAtByHand", defaultValue: "Acceso a mano alle %@")
                                : String(localized: "span.startedAt", defaultValue: "Acceso alle %@"),
                             span.start.formatted(date: .omitted, time: .shortened)))

            if let end = span.end {
                row(icon: "stop.circle",
                    text: String(format: String(localized: "span.endedAt", defaultValue: "Spento alle %@"),
                                 end.formatted(date: .omitted, time: .shortened)))
            } else {
                row(icon: "waveform",
                    text: String(localized: "span.stillRunning", defaultValue: "Sta ancora girando"))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var stopVerb: some View {
        Button {
            Task { await stop() }
        } label: {
            Label(String(localized: "span.stopNow", defaultValue: "Spegni adesso"),
                  systemImage: "power")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isWorking)
    }

    /// Quanto è durato, detto come lo direbbe una persona.
    nonisolated static func durationText(_ interval: TimeInterval) -> String {
        let minutes = max(Int(interval / 60), 0)
        if minutes < 60 {
            return String(format: String(localized: "span.minutes", defaultValue: "%d min"), minutes)
        }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 {
            return String(format: String(localized: "span.hours", defaultValue: "%dh"), hours)
        }
        return String(format: String(localized: "span.hoursMinutes", defaultValue: "%dh %02d"), hours, rest)
    }

    private func stop() async {
        isWorking = true
        defer { isWorking = false }
        guard let accessory = homeKit.accessory(for: span.accessoryUUID),
              let power = HomeKitScenesService.powerCharacteristic(of: accessory) else {
            failure = String(localized: "span.stop.failed", defaultValue: "Non sono riuscito a spegnerlo.")
            return
        }
        do {
            try await homeKit.write(NSNumber(value: false), to: power)
            failure = nil
            overlayVM.closeDetailContent()
        } catch {
            failure = String(localized: "span.stop.failed", defaultValue: "Non sono riuscito a spegnerlo.")
        }
    }
}

// MARK: - FloorplanRunningSpansPanelContent

/// Riepilogo dei processi ancora in corso scelto dalla testata del nastro.
struct FloorplanRunningSpansPanelContent: View {

    let spans: [DaySpan]
    @Bindable var overlayVM: FloorplanOverlayViewModel

    private var sortedSpans: [DaySpan] {
        spans.sorted(by: DaySpanBuilder.precedes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            list
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                Text(String(localized: "runningSpans.title",
                            defaultValue: "In corso · \(sortedSpans.count)"))
                    .font(.title3.weight(.bold).monospacedDigit())
                Spacer()
                Button { overlayVM.closeDetailContent() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(String(localized: "runningSpans.subtitle",
                        defaultValue: "Processi attivi adesso"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sortedSpans) { span in
                HStack(spacing: 10) {
                    Image(systemName: DayRibbonView.spanSymbol(for: span))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DayRibbonView.spanTint(for: span))
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(span.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if let room = span.roomName {
                                Text(room)
                            }
                            Text(FloorplanSpanPanelContent.durationText(span.duration(now: Date())))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 6)

                    Text(String(localized: "runningSpans.active", defaultValue: "Attivo"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
