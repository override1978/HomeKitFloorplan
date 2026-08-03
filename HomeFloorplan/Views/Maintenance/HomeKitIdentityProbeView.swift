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
    @State private var probe = HomeKitIdentityProbe()
    @State private var didCopy = false

    var body: some View {
        List {
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
