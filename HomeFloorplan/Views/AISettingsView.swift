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
            if settings.isAIEnabled {
                featuresSection
            }
            infoSection
        }
        .navigationTitle(String(localized: "ai.settings.title", defaultValue: "Intelligenza Artificiale"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear { loadAPIKeyDraft() }
    }

    // MARK: - Provider section

    @ViewBuilder
    private var providerSection: some View {
        Section {
            // Master switch
            Toggle(isOn: $settings.isAIEnabled) {
                Label(
                    String(localized: "ai.settings.masterToggle", defaultValue: "Abilita AI"),
                    systemImage: "brain"
                )
            }

            // Selezione provider
            Picker(
                String(localized: "ai.settings.provider", defaultValue: "Provider"),
                selection: $settings.selectedProvider
            ) {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Text(provider.localizedName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: settings.selectedProvider) { _, _ in
                loadAPIKeyDraft()
                // Reset stato test quando si cambia provider
                settings.lastConnectionTest    = nil
                settings.lastConnectionSuccess = nil
                testError = nil
            }

            // API Key field
            apiKeyRow

            // Testa connessione
            testConnectionRow

        } header: {
            Text(String(localized: "ai.settings.provider.header", defaultValue: "Provider"))
        } footer: {
            Text(String(localized: "ai.settings.provider.footer",
                        defaultValue: "Seleziona il provider AI e inserisci la tua API key per abilitare le funzioni intelligenti."))
        }
    }

    // MARK: - API Key row

    @ViewBuilder
    private var apiKeyRow: some View {
        HStack {
            if isKeyVisible {
                TextField(
                    String(localized: "ai.settings.apiKey.placeholder", defaultValue: "Incolla qui la API key"),
                    text: $apiKeyDraft
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { saveAPIKey() }
            } else {
                SecureField(
                    String(localized: "ai.settings.apiKey.placeholder", defaultValue: "Incolla qui la API key"),
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
                    Text(String(localized: "ai.settings.apiKey.save", defaultValue: "Salva"))
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
                Text(String(localized: "ai.settings.testConnection", defaultValue: "Testa connessione"))
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
                Text(String(localized: "ai.settings.lastTest", defaultValue: "Ultimo test"))
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
                    String(localized: "ai.settings.suggestions", defaultValue: "Suggerimenti abitudini"),
                    systemImage: "lightbulb"
                )
            }
            .disabled(!settings.isOperational)

            Toggle(isOn: $settings.anomalyDetectionEnabled) {
                Label(
                    String(localized: "ai.settings.anomaly", defaultValue: "Rilevamento anomalie"),
                    systemImage: "exclamationmark.triangle"
                )
            }
            .disabled(!settings.isOperational)

            Toggle(isOn: $settings.ruleEngineEnabled) {
                Label(
                    String(localized: "ai.settings.ruleEngine", defaultValue: "Regole predittive"),
                    systemImage: "gearshape.2"
                )
            }
            .disabled(!settings.isOperational)

        } header: {
            Text(String(localized: "ai.settings.features.header", defaultValue: "Funzioni AI"))
        } footer: {
            if !settings.isOperational {
                Text(String(localized: "ai.settings.features.noKey",
                            defaultValue: "Configura una API key valida per abilitare le funzioni AI."))
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
                           defaultValue: "La tua API key è salvata in modo sicuro nel Keychain del dispositivo."),
                    systemImage: "lock.shield"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Label(
                    String(localized: "ai.settings.privacy.data",
                           defaultValue: "I dati inviati sono solo valori numerici aggregati, mai dati personali."),
                    systemImage: "chart.bar"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            Link(destination: settings.selectedProvider.pricingURL) {
                Label(
                    String(localized: "ai.settings.pricing",
                           defaultValue: "Prezzi e piani \(settings.selectedProvider.localizedName)"),
                    systemImage: "arrow.up.right.square"
                )
                .foregroundStyle(.tint)
            }
        } header: {
            Text(String(localized: "ai.settings.info.header", defaultValue: "Privacy e costi"))
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
                         defaultValue: "Test fallito. Verifica la API key e la connessione.")
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
                            defaultValue: "API key AI non configurata"))
                .font(.subheadline).bold()

                Text(String(localized: "ai.banner.subtitle",
                            defaultValue: "Configura la chiave in Impostazioni per usare le funzioni AI."))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(String(localized: "ai.banner.action", defaultValue: "Configura")) {
                showSettings = true
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
