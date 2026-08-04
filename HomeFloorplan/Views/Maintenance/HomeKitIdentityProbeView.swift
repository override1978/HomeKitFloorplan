import SwiftUI

// MARK: - HomeKitIdentityProbeView

/// Schermata della **Fase 0a**: misura su quali basi si può identificare un
/// accessorio HomeKit fra device diversi.
///
/// Va eseguita **sullo stesso impianto da due device**, e si confrontano le due
/// impronte in cima. Non serve leggere l'elenco: è lì solo per capire *quali*
/// accessori mancano di seriale quando la copertura non è piena.
struct HomeKitIdentityProbeView: View {

    @Environment(HomeKitService.self) private var homeKit
    @Environment(HomeKitAutomationsService.self) private var automationsService
    @Environment(HomeKitScenesService.self) private var scenesService
    @State private var probe = HomeKitIdentityProbe()
    @State private var didCopy = false

    @State private var captureSummary: CaptureSummary?
    @State private var isCapturing = false

    /// Quello che il piano chiede di misurare per primo: **tempo e peso**. Se il
    /// tempo fosse nell'ordine dei minuti significherebbe che la cattura sta
    /// leggendo i valori delle caratteristiche invece della sola identità — il
    /// difetto da intercettare subito.
    struct CaptureSummary {
        let elapsed: TimeInterval
        let rawBytes: Int
        let compressedBytes: Int
        let counts: HomeConfigurationSnapshot.Counts
        let coverage: Double
    }

    var body: some View {
        List {
            captureProbe
            deadAutomations
            automations

            Section {
                if probe.isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: probe.progress)
                        Text(String(localized: "identityProbe.running",
                                    defaultValue: "Reading serial numbers…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        Task { await probe.run(homeKit: homeKit) }
                    } label: {
                        Label(
                            probe.report == nil
                                ? String(localized: "identityProbe.start", defaultValue: "Run measurement")
                                : String(localized: "identityProbe.rerun", defaultValue: "Run again"),
                            systemImage: "waveform.badge.magnifyingglass"
                        )
                    }
                }
            } footer: {
                Text(String(localized: "identityProbe.footer",
                            defaultValue: "Run this on both devices with the same home, then compare the two fingerprints."))
            }

            if let report = probe.report {
                fingerprints(report)
                counts(report)

                if !report.nameOnly.isEmpty {
                    Section {
                        ForEach(report.nameOnly) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text([entry.roomName, entry.manufacturer, entry.model]
                                    .compactMap { $0 }
                                    .joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text(String(localized: "identityProbe.nameOnly.header",
                                    defaultValue: "Identified by name alone"))
                    } footer: {
                        Text(String(localized: "identityProbe.nameOnly.footer",
                                    defaultValue: "These have an identical twin in the same room and no serial number. Renaming one makes it unrecognisable to a restore."))
                    }
                }

                if !report.withoutSerial.isEmpty {
                    Section {
                        ForEach(report.withoutSerial) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text([entry.roomName, entry.manufacturer, entry.model]
                                    .compactMap { $0 }
                                    .joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text(String(localized: "identityProbe.noSerial.header",
                                    defaultValue: "Without a serial number"))
                    } footer: {
                        Text(String(localized: "identityProbe.noSerial.footer",
                                    defaultValue: "Typically everything behind a bridge or on a cloud account. They cannot be recognised after re-pairing."))
                    }
                }

                Section {
                    Button {
                        UIPasteboard.general.string = report.plainText()
                        didCopy = true
                    } label: {
                        Label(
                            didCopy
                                ? String(localized: "identityProbe.copied", defaultValue: "Copied")
                                : String(localized: "identityProbe.copy", defaultValue: "Copy full report"),
                            systemImage: didCopy ? "checkmark" : "doc.on.doc"
                        )
                    }
                }
            }
        }
        .navigationTitle(String(localized: "identityProbe.title", defaultValue: "Accessory identity"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: probe.report?.capturedAt) { _, _ in didCopy = false }
    }

    // MARK: - Cattura di prova

    @ViewBuilder
    private var captureProbe: some View {
        Section {
            Button {
                Task { await runCaptureProbe() }
            } label: {
                if isCapturing {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "captureProbe.running", defaultValue: "Capturing…"))
                    }
                } else {
                    Label(String(localized: "captureProbe.run", defaultValue: "Test a snapshot"),
                          systemImage: "camera.viewfinder")
                }
            }
            .disabled(isCapturing)

            if let s = captureSummary {
                LabeledContent(String(localized: "captureProbe.elapsed", defaultValue: "Time"),
                               value: String(format: "%.1f s", s.elapsed))
                LabeledContent(String(localized: "captureProbe.size", defaultValue: "Size"),
                               value: "\(s.compressedBytes / 1024) KB · \(s.rawBytes / 1024) KB raw")
                LabeledContent(String(localized: "captureProbe.contents", defaultValue: "Contents"),
                               value: "\(s.counts.accessories) · \(s.counts.scenes) · \(s.counts.automations) · \(s.counts.rooms)")
                LabeledContent(String(localized: "captureProbe.coverage", defaultValue: "Reliable identity"),
                               value: "\(Int((s.coverage * 100).rounded()))%")
            }
        } header: {
            Text(String(localized: "captureProbe.header", defaultValue: "Snapshot"))
        } footer: {
            Text(String(localized: "captureProbe.footer",
                        defaultValue: "Accessories · scenes · automations · rooms. A few seconds is expected — the serial numbers cost one read each. Minutes would mean characteristic values are being read, which they must not be."))
        }
    }

    private func runCaptureProbe() async {
        isCapturing = true
        defer { isCapturing = false }
        let capture = HomeSnapshotCapture(homeKit: homeKit,
                                          scenesService: scenesService,
                                          automationsService: automationsService)
        let started = Date()
        do {
            let snapshot = try await capture.capture()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let raw = try encoder.encode(snapshot)
            let compressed = (try? (raw as NSData).compressed(using: .zlib)) ?? NSData()
            captureSummary = CaptureSummary(
                elapsed: Date().timeIntervalSince(started),
                rawBytes: raw.count,
                compressedBytes: compressed.length,
                counts: snapshot.counts,
                coverage: snapshot.reliableIdentityCoverage
            )
        } catch {
            captureSummary = nil
        }
    }

    // MARK: - Automazioni morte

    /// Automazioni che scattano e non fanno niente: hanno perso il proprio
    /// contenuto e ne è rimasto il guscio. Se sono ancora **attive** scattano a
    /// vuoto, ed è il caso che vale la pena mostrare per primo — è l'unico di
    /// tutta questa schermata su cui l'utente può agire subito.
    @ViewBuilder
    private var deadAutomations: some View {
        let dead = automationsService.actionDiagnostics().dead
        if !dead.isEmpty {
            Section {
                ForEach(dead) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.isEnabled ? "exclamationmark.triangle.fill" : "moon.zzz")
                            .foregroundStyle(item.isEnabled ? .orange : .secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            Text(item.isEnabled
                                 ? String(localized: "deadAutomation.enabled",
                                          defaultValue: "Active — it fires and does nothing")
                                 : String(localized: "deadAutomation.disabled",
                                          defaultValue: "Paused"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: String(localized: "deadAutomation.detail",
                                                       defaultValue: "0 actions across %d action set(s)"),
                                        item.actionSetCount))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text(String(localized: "deadAutomation.header", defaultValue: "Automations with no effect"))
            } footer: {
                Text(String(localized: "deadAutomation.footer",
                            defaultValue: "They lost their actions; the trigger survived. On a programmable button that trigger is the part worth keeping — which button, which gesture, under which conditions — so give it a scene rather than delete it. Delete only if you no longer want that gesture."))
            }
        }
    }

    // MARK: - Automazioni: su cosa puntano davvero

    /// Dice se la migrazione delle azioni dirette ha un caso d'uso in questa
    /// casa. Se «attaccate al trigger» è zero, il pulsante non compare da
    /// nessuna parte — ed è corretto così, non un difetto.
    private var automations: some View {
        let d = automationsService.actionDiagnostics()
        return Section {
            LabeledContent(String(localized: "automationDiag.total", defaultValue: "Automations"),
                           value: "\(d.total)")
            LabeledContent(String(localized: "automationDiag.namedScenes", defaultValue: "Point at a scene"),
                           value: "\(d.namedScenes)")
            LabeledContent(String(localized: "automationDiag.triggerOwned", defaultValue: "Actions attached to the trigger"),
                           value: "\(d.triggerOwned)")
            LabeledContent(String(localized: "automationDiag.unreadable", defaultValue: "…of which unreadable by the app"),
                           value: "\(d.withUnreadableActions)")
            LabeledContent(String(localized: "automationDiag.migratable", defaultValue: "Migration can act on"),
                           value: "\(d.migratable)")
            if d.withoutActions > 0 {
                LabeledContent(String(localized: "automationDiag.noActions", defaultValue: "Without any action"),
                               value: "\(d.withoutActions)")
            }
            if d.emptyTriggerOwnedSets > 0 {
                LabeledContent(String(localized: "automationDiag.emptySets", defaultValue: "Empty containers"),
                               value: "\(d.emptyTriggerOwnedSets)")
            }
            ForEach(d.unreadableActionClasses.sorted(by: { $0.value > $1.value }), id: \.key) { entry in
                LabeledContent(entry.key, value: "\(entry.value)")
                    .font(.footnote.monospaced())
            }
        } header: {
            Text(String(localized: "automationDiag.header", defaultValue: "Automation actions"))
        } footer: {
            Text(d.triggerOwned == 0
                 ? String(localized: "automationDiag.footer.none",
                          defaultValue: "Every automation points at a real scene, so it is already editable and restorable. The migration has nothing to do here.")
                 : String(localized: "automationDiag.footer.some",
                          defaultValue: "Actions attached to a trigger cannot be rewritten by a third-party app, nor restored from a backup. Moving them into a scene fixes both."))
        }
    }

    // MARK: - Le due impronte: sono la risposta

    private func fingerprints(_ report: HomeKitIdentityProbe.Report) -> some View {
        Section {
            fingerprintRow(
                title: String(localized: "identityProbe.uuidFingerprint", defaultValue: "UUID fingerprint"),
                value: report.uuidFingerprint,
                explanation: String(localized: "identityProbe.uuidFingerprint.detail",
                                    defaultValue: "If this matches on both devices, HomeKit identifiers are stable and nothing else is needed.")
            )
        } header: {
            Text(String(localized: "identityProbe.fingerprints.header", defaultValue: "Compare these"))
        } footer: {
            Text(String(format: String(localized: "identityProbe.capturedOn",
                                       defaultValue: "%@ · %@ · %.1f s"),
                        report.deviceName, report.homeName, probe.elapsed))
        }
    }

    private func fingerprintRow(title: String, value: String, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(value)
                .font(.system(.title3, design: .monospaced))
                .textSelection(.enabled)
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Copertura

    private func counts(_ report: HomeKitIdentityProbe.Report) -> some View {
        Section {
            LabeledContent(String(localized: "identityProbe.total", defaultValue: "Accessories"),
                           value: "\(report.total)")
            tierRow(
                title: String(localized: "identityProbe.tier.hardware", defaultValue: "Hardware identity"),
                subtitle: String(localized: "identityProbe.tier.hardware.detail",
                                 defaultValue: "Serial number: survives renaming, moving and re-pairing"),
                count: report.count(of: .hardware),
                total: report.total,
                tint: .green
            )
            tierRow(
                title: String(localized: "identityProbe.tier.stable", defaultValue: "Stable identity"),
                subtitle: String(localized: "identityProbe.tier.stable.detail",
                                 defaultValue: "Make, model and room: holds unless moved to another room"),
                count: report.count(of: .stable),
                total: report.total,
                tint: .blue
            )
            tierRow(
                title: String(localized: "identityProbe.tier.nameOnly", defaultValue: "Name only"),
                subtitle: String(localized: "identityProbe.tier.nameOnly.detail",
                                 defaultValue: "An identical twin in the same room: renaming breaks it"),
                count: report.count(of: .nameOnly),
                total: report.total,
                tint: .orange
            )
        } header: {
            Text(String(localized: "identityProbe.coverage.header", defaultValue: "What identity rests on"))
        } footer: {
            Text(verdict(for: report.reliableCoverage))
        }
    }

    private func tierRow(title: String, subtitle: String, count: Int, total: Int, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(tint)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text("\(count) · \(Int((Double(count) / Double(max(1, total)) * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// La soglia non è estetica: sotto il 60% il ripristino fra device diversi
    /// non regge, e la conclusione giusta è restringere la funzione invece di
    /// abbassare l'asticella dell'identità abbinando per nome.
    private func verdict(for coverage: Double) -> String {
        switch coverage {
        case 0.9...:
            return String(localized: "identityProbe.verdict.high",
                          defaultValue: "Enough to identify accessories across devices without relying on names.")
        case 0.6..<0.9:
            return String(localized: "identityProbe.verdict.medium",
                          defaultValue: "Partial: restoring across devices works only for identified accessories; the others must be marked as unidentifiable.")
        default:
            return String(localized: "identityProbe.verdict.low",
                          defaultValue: "Too low: restoring across devices does not hold up. Snapshots stay visible everywhere, but restore belongs to the device that captured them.")
        }
    }
}
