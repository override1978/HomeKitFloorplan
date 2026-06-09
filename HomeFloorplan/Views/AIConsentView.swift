import SwiftUI

// MARK: - AIConsentView
//
// Consent screen mostrata prima della prima attivazione AI.
// Spiega esattamente quali dati ambientali vengono inviati al provider
// e cosa NON viene mai trasmesso (identità, GPS, media).
//
// Flusso:
//   1. Utente attiva il toggle AI in AISettingsView
//   2. AISettingsView rileva !hasAIDataConsent → reverte toggle + mostra questo sheet
//   3. Utente legge e tocca "Accetto" → grantConsent() + isAIEnabled = true + dismiss
//   4. Utente tocca "Non accetto" → dismiss (AI rimane disabilitata)

struct AIConsentView: View {

    let settings: AISettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    sentDataSection
                    notSentSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
            .navigationTitle(String(localized: "ai.consent.nav.title", defaultValue: "AI Data Consent"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "ai.consent.decline", defaultValue: "Decline")) {
                        dismiss()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                acceptButton
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Image(systemName: "brain.filled.head.profile")
                        .font(.system(size: 26))
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "ai.consent.headline",
                                defaultValue: "How your data is used"))
                        .font(.title3.weight(.bold))
                    Text(String(format: String(localized: "ai.consent.provider",
                                              defaultValue: "Provider: %@"),
                                settings.selectedProvider.localizedName))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text(String(format: String(localized: "ai.consent.intro",
                                       defaultValue: "To generate smart environmental insights, the app sends some room data to %@. Review what is transmitted before proceeding."),
                        settings.selectedProvider.localizedName))
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private var sentDataSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(String(localized: "ai.consent.sent.header", defaultValue: "What is sent"),
                  systemImage: "arrow.up.circle.fill")
                .font(.headline)
                .foregroundStyle(.blue)

            ConsentDataRow(
                icon: "house.fill",
                color: .blue,
                title: String(localized: "ai.consent.sent.roomNames",
                              defaultValue: "Room names"),
                detail: String(localized: "ai.consent.sent.roomNames.detail",
                               defaultValue: "The names you assigned to HomeKit rooms (e.g. \"Kitchen\", \"Bedroom\").")
            )

            ConsentDataRow(
                icon: "thermometer.medium",
                color: .orange,
                title: String(localized: "ai.consent.sent.sensorData",
                              defaultValue: "Environmental values"),
                detail: String(localized: "ai.consent.sent.sensorData.detail",
                               defaultValue: "Numeric readings of temperature, humidity, CO₂ and air quality from the last 24–48 hours.")
            )

            ConsentDataRow(
                icon: "chart.xyaxis.line",
                color: .indigo,
                title: String(localized: "ai.consent.sent.baseline",
                              defaultValue: "Baseline statistics"),
                detail: String(localized: "ai.consent.sent.baseline.detail",
                               defaultValue: "Historical averages and standard deviations (up to 30 days) to contextualise anomalies.")
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.blue.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.blue.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var notSentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(String(localized: "ai.consent.notSent.header", defaultValue: "What is NEVER sent"),
                  systemImage: "checkmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.green)

            ConsentDataRow(
                icon: "person.crop.circle.badge.xmark",
                color: .green,
                title: String(localized: "ai.consent.notSent.identity",
                              defaultValue: "User identities"),
                detail: String(localized: "ai.consent.notSent.identity.detail",
                               defaultValue: "No name, Apple ID, email or family profile is transmitted to the AI provider.")
            )

            ConsentDataRow(
                icon: "location.slash.fill",
                color: .green,
                title: String(localized: "ai.consent.notSent.location",
                              defaultValue: "GPS Location"),
                detail: String(localized: "ai.consent.notSent.location.detail",
                               defaultValue: "No geographic or location information is included in AI requests.")
            )

            ConsentDataRow(
                icon: "camera.slash.fill",
                color: .green,
                title: String(localized: "ai.consent.notSent.media",
                              defaultValue: "Video, audio and images"),
                detail: String(localized: "ai.consent.notSent.media.detail",
                               defaultValue: "No data from cameras, microphones or multimedia sensors.")
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.green.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.12), lineWidth: 1)
                )
        )
    }

    // MARK: - Accept button

    private var acceptButton: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                settings.grantConsent()
                settings.isAIEnabled = true
                dismiss()
            } label: {
                Text(String(localized: "ai.consent.accept",
                            defaultValue: "Accept and enable AI"))
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(.regularMaterial)
    }
}

// MARK: - ConsentDataRow

private struct ConsentDataRow: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Preview

#Preview("AI Consent") {
    AIConsentView(settings: AISettings())
}
