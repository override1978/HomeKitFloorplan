import SwiftUI

// MARK: - AISettingsView

/// View dedicata alle impostazioni del motore AI.
/// Raggiungibile da SettingsView tramite NavigationLink.
struct AISettingsView: View {

    // MARK: - State

    @State private var settings = AISettings()
    @State private var service: AIService

    /// Testo della API key mostrato nel SecureField.
    @State private var apiKeyDraft: String = ""
    /// True = mostra la chiave in chiaro (temporaneo).
    @State private var isKeyVisible: Bool = false
    /// True durante il test di connessione.
    @State private var isTesting: Bool = false
    /// Errore dell'ultimo test, se presente.
    @State private var testError: String?
    /// True = mostra il consent sheet prima di attivare l'AI.
    @State private var showConsentSheet = false

    // MARK: - Init

    init() {
        let s = AISettings()
        _settings = State(initialValue: s)
        _service = State(initialValue: AIService(settings: s))
    }

    // MARK: - Body

    var body: some View {
        Form {
            providerSection
            providerCapabilitiesSection
            if settings.isAIEnabled {
                featuresSection
            }
            infoSection
        }
        .navigationTitle(String(localized: "ai.settings.title", defaultValue: "Artificial Intelligence"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear { loadAPIKeyDraft() }
        .sheet(isPresented: $showConsentSheet) {
            AIConsentView(settings: settings)
        }
    }

    // MARK: - Provider section

    @ViewBuilder
    private var providerSection: some View {
        Section {
            // Master switch — intercetta la prima attivazione per mostrare il consent screen
            Toggle(isOn: $settings.isAIEnabled) {
                Label(
                    String(localized: "ai.settings.masterToggle", defaultValue: "Enable AI"),
                    systemImage: "brain"
                )
            }
            .onChange(of: settings.isAIEnabled) { _, newValue in
                if newValue && !settings.hasAIDataConsent {
                    settings.isAIEnabled = false
                    showConsentSheet = true
                }
            }

            HStack {
                Label(
                    String(localized: "ai.settings.provider", defaultValue: "Provider"),
                    systemImage: "sparkles"
                )
                Spacer()
                Text(settings.selectedProvider.localizedName)
                    .foregroundStyle(.secondary)
            }

            // API Key field
            apiKeyRow

            // Testa connessione
            testConnectionRow

        } header: {
            Text(String(localized: "ai.settings.provider.header", defaultValue: "Provider"))
        } footer: {
            Text(String(localized: "ai.settings.provider.footer",
                        defaultValue: "Claude is currently the supported AI provider for smart HomeKit features. Additional providers may be added later."))
        }
    }

    @ViewBuilder
    private var providerCapabilitiesSection: some View {
        Section {
            capabilityRow(
                title: String(localized: "ai.settings.capability.analysis", defaultValue: "Environmental and habit insights"),
                detail: String(localized: "ai.settings.capability.analysis.detail", defaultValue: "Used for room analysis, anomaly summaries, and habit naming."),
                isAvailable: settings.selectedProvider.supportsPromptAnalysis
            )

            capabilityRow(
                title: String(localized: "ai.settings.capability.assistant", defaultValue: "Voice assistant with HomeKit tools"),
                detail: settings.selectedProvider.supportsHomeAssistantTools
                    ? String(localized: "ai.settings.capability.assistant.detail.enabled", defaultValue: "Can read devices, propose actions, and create scenes or rules.")
                    : String(localized: "ai.settings.capability.assistant.detail.disabled", defaultValue: "Currently requires Claude because this feature depends on tool-use loops."),
                isAvailable: settings.selectedProvider.supportsHomeAssistantTools
            )
        } header: {
            Text(String(localized: "ai.settings.capabilities.header", defaultValue: "Provider Capabilities"))
        } footer: {
            if !settings.selectedProvider.supportsHomeAssistantTools {
                Text(String(localized: "ai.settings.capabilities.footer.openai",
                            defaultValue: "OpenAI can be used for AI analysis features. The in-app voice assistant will remain unavailable until OpenAI tool-use routing is implemented."))
            }
        }
    }

    private func capabilityRow(title: String, detail: String, isAvailable: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isAvailable ? "checkmark.circle.fill" : "minus.circle.fill")
                .foregroundStyle(isAvailable ? .green : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - API Key row

    @ViewBuilder
    private var apiKeyRow: some View {
        HStack {
            if isKeyVisible {
                TextField(
                    String(localized: "ai.settings.apiKey.placeholder", defaultValue: "Paste your API key here"),
                    text: $apiKeyDraft
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { saveAPIKey() }
            } else {
                SecureField(
                    String(localized: "ai.settings.apiKey.placeholder", defaultValue: "Paste your API key here"),
                    text: $apiKeyDraft
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { saveAPIKey() }
            }

            Spacer(minLength: 8)

            // Toggle visibilità
            Button {
                isKeyVisible.toggle()
            } label: {
                Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Salva / Cancella
            if !apiKeyDraft.isEmpty {
                Button {
                    saveAPIKey()
                } label: {
                    Text(String(localized: "ai.settings.apiKey.save", defaultValue: "Save"))
                        .font(.callout)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Test connection row

    @ViewBuilder
    private var testConnectionRow: some View {
        Button {
            Task { await runConnectionTest() }
        } label: {
            HStack {
                if isTesting {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.tint)
                        .frame(width: 20)
                }
                Text(String(localized: "ai.settings.testConnection", defaultValue: "Test Connection"))
                    .foregroundStyle(settings.hasAPIKey ? .primary : .secondary)

                Spacer()

                // Risultato ultimo test
                if !isTesting, let success = settings.lastConnectionSuccess {
                    Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(success ? .green : .red)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!settings.hasAPIKey || isTesting)

        // Ultimo test timestamp
        if let lastTest = settings.lastConnectionTest {
            HStack {
                Text(String(localized: "ai.settings.lastTest", defaultValue: "Last Test"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(lastTest, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let success = settings.lastConnectionSuccess {
                    Text(success ? "✅" : "❌")
                        .font(.caption)
                }
            }
        }

        // Messaggio di errore leggibile
        if let error = testError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Features section

    @ViewBuilder
    private var featuresSection: some View {
        Section {
            Toggle(isOn: $settings.suggestionsEnabled) {
                Label(
                    String(localized: "ai.settings.suggestions", defaultValue: "Habit Suggestions"),
                    systemImage: "lightbulb"
                )
            }
            .disabled(!settings.isOperational)

            Toggle(isOn: $settings.anomalyDetectionEnabled) {
                Label(
                    String(localized: "ai.settings.anomaly", defaultValue: "Anomaly Detection"),
                    systemImage: "exclamationmark.triangle"
                )
            }
            .disabled(!settings.isOperational)

            Toggle(isOn: $settings.ruleEngineEnabled) {
                Label(
                    String(localized: "ai.settings.ruleEngine", defaultValue: "Predictive Rules"),
                    systemImage: "gearshape.2"
                )
            }
            .disabled(!settings.isOperational)

        } header: {
            Text(String(localized: "ai.settings.features.header", defaultValue: "AI Features"))
        } footer: {
            if !settings.isOperational {
                Text(String(localized: "ai.settings.features.noKey",
                            defaultValue: "Set up a valid API key to enable AI features."))
            }
        }
    }

    // MARK: - Info section

    @ViewBuilder
    private var infoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    String(localized: "ai.settings.privacy.keychain",
                           defaultValue: "Your API key is stored securely in the device Keychain."),
                    systemImage: "lock.shield"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Label(
                    String(localized: "ai.settings.privacy.data",
                           defaultValue: "Only aggregated numeric values are sent — never personal data."),
                    systemImage: "chart.bar"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            Link(destination: settings.selectedProvider.pricingURL) {
                Label(
                    String(localized: "ai.settings.pricing",
                           defaultValue: "Pricing & Plans \(settings.selectedProvider.localizedName)"),
                    systemImage: "arrow.up.right.square"
                )
                .foregroundStyle(.tint)
            }

            if settings.hasAIDataConsent {
                Button(role: .destructive) {
                    settings.revokeConsent()
                } label: {
                    Label(
                        String(localized: "ai.settings.revokeConsent",
                               defaultValue: "Revoke AI Data Consent"),
                        systemImage: "hand.raised.slash"
                    )
                }
            } else {
                Button {
                    showConsentSheet = true
                } label: {
                    Label(
                        String(localized: "ai.settings.grantConsent",
                               defaultValue: "Show AI Data Notice"),
                        systemImage: "hand.raised"
                    )
                    .foregroundStyle(.tint)
                }
            }

        } header: {
            Text(String(localized: "ai.settings.info.header", defaultValue: "Privacy & Costs"))
        }
    }

    // MARK: - Actions

    private func loadAPIKeyDraft() {
        apiKeyDraft = KeychainHelper.load(key: settings.selectedProvider.keychainKey) ?? ""
    }

    private func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.delete(key: settings.selectedProvider.keychainKey)
        } else {
            KeychainHelper.save(key: settings.selectedProvider.keychainKey, value: trimmed)
        }
        // Reset stato test dopo una nuova chiave
        settings.lastConnectionTest    = nil
        settings.lastConnectionSuccess = nil
        testError = nil
        isKeyVisible = false
    }

    @MainActor
    private func runConnectionTest() async {
        isTesting = true
        testError = nil
        let success = await service.testConnection()
        isTesting = false
        if !success {
            testError = settings.lastConnectionSuccess == false
                ? String(localized: "ai.settings.testFailed",
                         defaultValue: "Test failed. Check your API key and connection.")
                : nil
        }
    }
}

// MARK: - AISettingsBannerView

/// Banner compatto da mostrare quando una feature AI viene usata senza API key configurata.
/// Fornisce un deep link diretto ad AISettingsView.
struct AISettingsBannerView: View {
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "ai.banner.title",
                            defaultValue: "AI API Key Not Configured"))
                .font(.subheadline).bold()

                Text(String(localized: "ai.banner.subtitle",
                            defaultValue: "Configure your key in Settings to use AI features."))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(String(localized: "ai.banner.action", defaultValue: "Configure")) {
                showSettings = true
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
