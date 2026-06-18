import SwiftUI
import SwiftData
import HomeKit

// MARK: - ChatMessage

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id      = UUID()
    let role:     Role
    let content:  String
    /// Bottone azione strutturato allegato al messaggio (solo assistant).
    /// `.executeNow` → proposta, `.undo` → annullamento, `.createRule` → crea automazione.
    var actionPayload: AgentActionPayload? = nil
}

// MARK: - ChatBotView
//
// Production sheet for the home assistant (read-only, Phase 1.5).
// Presented via FAB from ContentView — survives navigation in the split view
// because the task is anchored to the sheet's @State, not to any detail view.
//
// Lifecycle:
//   - onAppear → setupViewModels() (creates EnvironmentVM + AccessoriesVM)
//   - onDisappear → loopTask?.cancel() (CancellationError is innocuous)
//
// Each sendQuery() call starts an independent AgentLoopService run.
// No cross-turn memory in Phase 1.5 — each Q&A pair is self-contained.

struct ChatBotView: View {

    @Environment(HomeKitService.self)            private var homeKit
    @Environment(WeatherKitService.self)         private var weatherKit
    @Environment(BehavioralAnalysisService.self) private var behavioralService
    @Environment(RuleEngineService.self)         private var ruleEngine
    @Environment(AISettings.self)               private var aiSettings
    @Environment(SmartLightingEngine.self)       private var smartLightingEngine
    @Environment(HomeKitScenesService.self)      private var scenesService
    @Environment(\.modelContext)                private var modelContext

    @State private var messages:        [ChatMessage] = []
    @State private var query:           String = ""
    @State private var isRunning:       Bool   = false
    @State private var loopTask:        Task<Void, Never>?
    @State private var envVM:           EnvironmentViewModel?
    @State private var accessoriesVM:   AccessoriesViewModel?
    /// A1 — ultimi 4 turni user/assistant passati al loop come history.
    @State private var turnHistory:     [ConversationTurn] = []
    /// ID messaggio per cui è in corso l'esecuzione del bottone azione (loading state).
    @State private var executingActionID: UUID?
    /// UUID stringa dell'accessorio pill attualmente in esecuzione (loading state per pills).
    @State private var executingPillID: String?
    /// Controls the entry animation (scale + fade on appear).
    @State private var appeared      = false
    /// True once setupViewModels() has run — gates the message list so the heavy
    /// VM initialisation doesn't compete with the sheet entry animation.
    @State private var isReady       = false
    @State private var speechService = SpeechRecognitionService()
    @State private var micPulse      = false
    @State private var isPreparing   = false
    @State private var voiceSubmitTask: Task<Void, Never>?

    #if DEBUG
    @State private var debugLogs: [AgentLogEntry] = []
    @State private var showDebugLogs = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider().opacity(0.35)
            if !isClaudeOperational { providerWarningBanner }
            // Show a lightweight loading placeholder until VMs are ready so the
            // sheet entry animation is not blocked by AccessoriesViewModel.refresh().
            ZStack {
                if isReady || !messages.isEmpty {
                    messageList.transition(.opacity)
                } else {
                    assistantLoadingView.transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: isReady || !messages.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputBar
        }
        .onChange(of: speechService.transcript) { _, t in
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                query = t
            }
        }
        .onChange(of: speechService.isRecording) { _, recording in
            isPreparing = false
            if recording {
                withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                    micPulse = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { micPulse = false }
                scheduleVoiceSubmit()
            }
        }
        .interactiveDismissDisabled(speechService.isRecording || isPreparing)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96, anchor: .top)
        .onAppear {
            // Auto-resume previous session on every open (no banner needed)
            if messages.isEmpty, let session = ChatSessionStore.load(), !session.isEmpty {
                messages = session.messages.map { p in
                    ChatMessage(role: p.role == "user" ? .user : .assistant, content: p.content)
                }
                turnHistory = session.turns
            }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                appeared = true
            }
        }
        .task {
            // Sleep through the sheet entry spring (~380 ms) so VM setup and its
            // re-renders don't compete with the animation. The placeholder ensures
            // the user sees something immediately.
            try? await Task.sleep(for: .milliseconds(320))
            setupViewModels()
            withAnimation(.easeOut(duration: 0.25)) { isReady = true }
        }
        .onDisappear {
            loopTask?.cancel()
            voiceSubmitTask?.cancel()
            ChatSessionStore.save(messages: messages, turns: turnHistory)
        }
    }

    // MARK: - Chat header

    private var chatHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BrandColor.primary)
            Text(String(localized: "agent.title", defaultValue: "Home"))
                .font(.headline)
            Spacer()
            if !messages.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        messages = []
                        turnHistory = []
                        ChatSessionStore.clear()
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(Color(.tertiarySystemBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
            #if DEBUG
            Button { showDebugLogs.toggle() } label: {
                Image(systemName: showDebugLogs ? "ladybug.fill" : "ladybug")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color(.tertiarySystemBackground), in: Circle())
            }
            .buttonStyle(.plain)
            #endif
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    // MARK: - Message list

    @ViewBuilder
    private var messageList: some View {
        if messages.isEmpty && !isRunning && !speechService.isRecording {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { msg in
                            messageBubble(msg).id(msg.id)
                        }
                        if speechService.isRecording {
                            liveTranscriptBubble
                                .id("liveTranscript")
                        }
                        if isRunning {
                            ThinkingDotsView().id("thinking")
                        }
                        #if DEBUG
                        if showDebugLogs && !debugLogs.isEmpty {
                            debugLogSection
                        }
                        #endif
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isRunning) {
                    if isRunning {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("thinking", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: speechService.isRecording) { _, recording in
                    if recording {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("liveTranscript", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 0) {
                if msg.role == .user { Spacer(minLength: 48) }
                renderedText(msg)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        msg.role == .user
                            ? AnyShapeStyle(BrandColor.primary)
                            : AnyShapeStyle(Color(.secondarySystemBackground)),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                    .foregroundStyle(msg.role == .user ? Color.white : Color.primary)
                if msg.role == .assistant { Spacer(minLength: 48) }
            }

            if msg.role == .assistant, let payload = msg.actionPayload {
                HStack(spacing: 0) {
                    actionButtonView(payload: payload, messageID: msg.id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func actionButtonView(payload: AgentActionPayload, messageID: UUID) -> some View {
        let isExecuting = executingActionID == messageID

        switch payload {
        case .executeNow:
            actionButton(
                icon: "bolt.fill", label: payload.label,
                tint: .accentColor, isExecuting: isExecuting
            ) {
                Task { @MainActor in await executeHomeKitAction(payload, messageID: messageID) }
            }

        case .createRule(let opp):
            automationPreviewCard(
                opportunity: opp,
                messageID: messageID,
                isExecuting: isExecuting
            )

        case .undo:
            actionButton(
                icon: "arrow.uturn.backward", label: payload.label,
                tint: .orange, isExecuting: isExecuting
            ) {
                Task { @MainActor in await executeHomeKitAction(payload, messageID: messageID) }
            }

        case .automationDiagnostics(let title, let items):
            automationDiagnosticsCard(title: title, items: items)

        case .choose(let accessories, let action, let value, let promptText):
            accessoryPillsView(
                accessories: accessories, action: action,
                value: value, promptText: promptText, messageID: messageID
            )
        }
    }

    private func automationDiagnosticsCard(title: String, items: [AutomationDiagnosticItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
            }

            if items.isEmpty {
                Text(String(localized: "chat.diagnostics.empty", defaultValue: "Nessuna automazione trovata."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        automationDiagnosticRow(item)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.blue.opacity(0.18), lineWidth: 1)
        )
    }

    private func automationDiagnosticRow(_ item: AutomationDiagnosticItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: item.isEnabled ? "checkmark.circle.fill" : "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(item.isEnabled ? .green : .secondary)
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(item.mode)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.mode == "HomeKit" ? .blue : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background((item.mode == "HomeKit" ? Color.blue : Color.secondary).opacity(0.10), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 3) {
                Label(item.trigger, systemImage: "calendar.badge.clock")
                Label(item.action, systemImage: "bolt.fill")
                Label(item.status, systemImage: item.status == "ok" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func automationPreviewCard(
        opportunity: AutomationOpportunity,
        messageID: UUID,
        isExecuting: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "wand.and.sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BrandColor.secondary)
                Text(String(localized: "chat.automation.preview.title", defaultValue: "Automation preview"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
            }

            VStack(alignment: .leading, spacing: 7) {
                previewRow(
                    icon: opportunity.triggerIcon,
                    title: String(localized: "chat.automation.preview.when", defaultValue: "When"),
                    value: automationTriggerSummary(for: opportunity)
                )

                if let condition = automationConditionSummary(for: opportunity) {
                    previewRow(
                        icon: "sensor.tag.radiowaves.forward",
                        title: String(localized: "chat.automation.preview.condition", defaultValue: "Condition"),
                        value: condition
                    )
                }

                previewRow(
                    icon: automationActionIcon(for: opportunity),
                    title: String(localized: "chat.automation.preview.action", defaultValue: "Action"),
                    value: automationActionSummary(for: opportunity)
                )

                if !opportunity.naturalLanguage.isEmpty {
                    previewRow(
                        icon: "quote.bubble.fill",
                        title: String(localized: "chat.automation.preview.request", defaultValue: "Request"),
                        value: opportunity.naturalLanguage
                    )
                }
            }

            actionButton(
                icon: "checkmark.circle.fill",
                label: String(localized: "chat.automation.createRule", defaultValue: "Crea regola"),
                tint: BrandColor.secondary,
                isExecuting: isExecuting
            ) {
                createRuleAction(opportunity, messageID: messageID)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColor.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(BrandColor.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private func previewRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(BrandColor.secondary)
                .frame(width: 16, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func automationTriggerSummary(for opportunity: AutomationOpportunity) -> String {
        switch opportunity.triggerType {
        case "calendar":
            let time = opportunity.triggerTime ?? "--:--"
            let days = weekdaySummary(for: opportunity.triggerWeekdays)
            return days.isEmpty ? time : "\(days) · \(time)"
        case "characteristic":
            return opportunity.scheduleSummary
                ?? String(localized: "chat.automation.trigger.sensor", defaultValue: "Sensor threshold")
        default:
            return String(localized: "chat.automation.trigger.manual", defaultValue: "Manual / in-app")
        }
    }

    private func automationConditionSummary(for opportunity: AutomationOpportunity) -> String? {
        guard opportunity.triggerType == "calendar",
              let sensor = opportunity.triggerSensorType,
              let threshold = opportunity.triggerThreshold else {
            return nil
        }

        let sensorName = SensorServiceType(rawValue: sensor)?.displayName ?? sensor
        let room = opportunity.roomName.isEmpty ? "" : " (\(opportunity.roomName))"
        let symbol = opportunity.triggerDirection == "above" ? ">" : "<"
        return "\(sensorName)\(room) \(symbol) \(String(format: "%.1f", threshold))"
    }

    private func automationActionSummary(for opportunity: AutomationOpportunity) -> String {
        if let sceneName = opportunity.effectSceneName, !sceneName.isEmpty {
            return String(
                format: String(localized: "chat.automation.action.scene", defaultValue: "Run scene %@"),
                sceneName
            )
        }

        let action = opportunity.effectActionRaw
        switch action {
        case "on": return String(localized: "chat.automation.action.on", defaultValue: "Turn on accessory")
        case "off": return String(localized: "chat.automation.action.off", defaultValue: "Turn off accessory")
        case "dim":
            let percent = Int((opportunity.effectValue ?? 0.3) * 100)
            return String(
                format: String(localized: "chat.automation.action.dim", defaultValue: "Set brightness to %d%%"),
                percent
            )
        case "setSpeed":
            let percent = Int((opportunity.effectValue ?? 0.5) * 100)
            return String(
                format: String(localized: "chat.automation.action.speed", defaultValue: "Set speed to %d%%"),
                percent
            )
        case "setTemp":
            let temp = Int(opportunity.effectValue ?? 22.0)
            return String(
                format: String(localized: "chat.automation.action.temp", defaultValue: "Set temperature to %d°C"),
                temp
            )
        case "setMode":
            return String(localized: "chat.automation.action.mode", defaultValue: "Set mode")
        case "open": return String(localized: "chat.automation.action.open", defaultValue: "Open")
        case "close": return String(localized: "chat.automation.action.close", defaultValue: "Close")
        default: return action
        }
    }

    private func automationActionIcon(for opportunity: AutomationOpportunity) -> String {
        if opportunity.effectSceneName != nil { return "sparkles" }

        switch opportunity.effectActionRaw {
        case "on": return "power"
        case "off": return "poweroff"
        case "dim": return "sun.min.fill"
        case "setSpeed": return "wind"
        case "setTemp": return "thermometer.medium"
        case "setMode": return "slider.horizontal.3"
        case "open": return "arrow.up.square"
        case "close": return "arrow.down.square"
        default: return "bolt.fill"
        }
    }

    private func weekdaySummary(for weekdays: [Int]) -> String {
        guard !weekdays.isEmpty else { return "" }
        let normalized = Set(weekdays)
        if normalized == Set(1...7) {
            return String(localized: "chat.weekdays.everyDay", defaultValue: "Every day")
        }
        if normalized == Set([2, 3, 4, 5, 6]) {
            return String(localized: "chat.weekdays.weekdays", defaultValue: "Weekdays")
        }
        if normalized == Set([1, 7]) {
            return String(localized: "chat.weekdays.weekend", defaultValue: "Weekend")
        }

        let symbols = Calendar.current.shortWeekdaySymbols
        return weekdays.sorted().compactMap { day in
            guard day >= 1, day <= symbols.count else { return nil }
            return symbols[day - 1]
        }.joined(separator: ", ")
    }

    @ViewBuilder
    private func accessoryPillsView(
        accessories: [AccessoryChoice],
        action: String,
        value: Double?,
        promptText: String,
        messageID: UUID
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(promptText)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(accessories, id: \.id) { choice in
                        let isRunning = executingPillID == choice.id
                        Button {
                            Task { @MainActor in
                                await executePillAction(
                                    choice: choice, action: action,
                                    value: value, messageID: messageID
                                )
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if isRunning {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "bolt.fill").imageScale(.small)
                                }
                                Text(choice.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                        }
                        .disabled(isRunning || executingPillID != nil)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actionButton(
        icon: String, label: String, tint: Color,
        isExecuting: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isExecuting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon).imageScale(.small)
                }
                Text(label).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
        }
        .disabled(isExecuting)
    }

    // MARK: - Button execution / undo / create rule

    /// Executes a HomeKit action for `.executeNow` or `.undo` payload cases.
    private func executeHomeKitAction(_ payload: AgentActionPayload, messageID: UUID) async {
        let (accessoryID, action, value): (String, String, Double?)
        switch payload {
        case .executeNow(let id, let act, let val, _):
            accessoryID = id; action = act; value = val
        case .undo(let id, let act, let val, _):
            accessoryID = id; action = act; value = val
        case .createRule, .choose, .automationDiagnostics:
            return
        }

        guard let home = homeKit.currentHome else {
            appendAssistantStatus(String(
                localized: "chat.action.noHome",
                defaultValue: "Non riesco ad accedere alla casa HomeKit in questo momento."
            ))
            return
        }
        executingActionID = messageID

        // Snapshot current characteristic state BEFORE execution so undo is precise.
        let undoPayload = captureCurrentStateForUndo(accessoryID: accessoryID, executedAction: action)

        let nextAction = AINextAction(
            label: payload.label,
            actionType: "executeNow",
            accessoryID: accessoryID,
            accessoryActionType: action,
            accessoryValue: value
        )
        let executor = NextActionExecutor()
        let success = await executor.execute(nextAction, in: home)
        executingActionID = nil

        guard success else {
            appendAssistantStatus(String(
                localized: "chat.action.failed",
                defaultValue: "Non sono riuscito a eseguire l'azione su HomeKit. Controlla che l'accessorio sia online e supporti questo comando."
            ))
            return
        }

        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }

        switch payload {
        case .undo:
            messages[idx].actionPayload = nil
        case .executeNow:
            messages[idx].actionPayload = undoPayload
        case .createRule, .choose, .automationDiagnostics:
            break
        }
    }

    /// Executes a HomeKit action on a specific pill choice, then replaces the pills with an undo button.
    private func executePillAction(
        choice: AccessoryChoice,
        action: String,
        value: Double?,
        messageID: UUID
    ) async {
        guard let home = homeKit.currentHome else {
            appendAssistantStatus(String(
                localized: "chat.action.noHome",
                defaultValue: "Non riesco ad accedere alla casa HomeKit in questo momento."
            ))
            return
        }
        executingPillID = choice.id

        let undoPayload = captureCurrentStateForUndo(accessoryID: choice.id, executedAction: action)

        let nextAction = AINextAction(
            label: choice.name,
            actionType: "executeNow",
            accessoryID: choice.id,
            accessoryActionType: action,
            accessoryValue: value
        )
        let executor = NextActionExecutor()
        let success = await executor.execute(nextAction, in: home)
        executingPillID = nil

        guard success else {
            appendAssistantStatus(String(
                localized: "chat.action.failed",
                defaultValue: "Non sono riuscito a eseguire l'azione su HomeKit. Controlla che l'accessorio sia online e supporti questo comando."
            ))
            return
        }

        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[idx].actionPayload = undoPayload
    }

    /// Approves a conversational opportunity and inserts the rule — one tap, no HabitsView needed.
    private func createRuleAction(_ opportunity: AutomationOpportunity, messageID: UUID) {
        executingActionID = messageID
        let rule = opportunity.buildRule()
        Task { @MainActor in
            do {
                let result = try await ruleEngine.insertRule(rule, home: homeKit.currentHome)
                behavioralService.approve(opportunity)
                if let idx = messages.firstIndex(where: { $0.id == messageID }) {
                    messages[idx].actionPayload = nil
                }
                executingActionID = nil
                let statusText: String
                if result.didSyncHomeKit {
                    statusText = String(
                        localized: "chat.rule.created.homekit",
                        defaultValue: "Regola creata e sincronizzata con HomeKit."
                    )
                } else {
                    statusText = String(
                        localized: "chat.rule.created.inapp",
                        defaultValue: "Regola creata nell'app. HomeKit non l'ha accettata, quindi verrà gestita internamente quando l'app può valutarla."
                    )
                }
                appendAssistantStatus(statusText)
            } catch {
                executingActionID = nil
                appendAssistantStatus(String(
                    localized: "chat.rule.create.failed",
                    defaultValue: "Non sono riuscito a creare la regola. La proposta resta disponibile: puoi riprovare tra poco."
                ))
            }
        }
    }

    private func appendAssistantStatus(_ content: String) {
        messages.append(ChatMessage(role: .assistant, content: content))
    }

    /// Reads homeKit.characteristicValues at call time so the undo payload reflects
    /// the actual pre-execution state. Falls back to action inversion if the value
    /// is not yet cached (accessory not observed).
    private func captureCurrentStateForUndo(
        accessoryID: String,
        executedAction: String
    ) -> AgentActionPayload? {
        let id = accessoryID
        guard let uuid = UUID(uuidString: accessoryID),
              let accessory = homeKit.allAccessories.first(where: { $0.uniqueIdentifier == uuid }) else {
            return undoFallback(action: executedAction, accessoryID: id)
        }

        let allChars = accessory.services.flatMap(\.characteristics)

        func intVal(_ charUUID: String) -> Int? {
            guard let char = allChars.first(where: { $0.characteristicType.lowercased() == charUUID }),
                  let raw = homeKit.characteristicValues[char.uniqueIdentifier] else { return nil }
            if let i = raw as? Int { return i }
            if let n = raw as? NSNumber { return n.intValue }
            return nil
        }

        func doubleVal(_ charUUID: String) -> Double? {
            guard let char = allChars.first(where: { $0.characteristicType.lowercased() == charUUID }),
                  let raw = homeKit.characteristicValues[char.uniqueIdentifier] else { return nil }
            if let d = raw as? Double { return d }
            if let n = raw as? NSNumber { return n.doubleValue }
            return nil
        }

        switch executedAction {
        case "on", "off":
            if let current = intVal("000000b0-0000-1000-8000-0026bb765291")
                           ?? intVal("00000025-0000-1000-8000-0026bb765291") {
                let undoAction = current == 1 ? "on" : "off"
                let undoLabel  = current == 1 ? "Riaccendi" : "Spegni"
                return .undo(accessoryID: id, action: undoAction, value: nil, label: undoLabel)
            }
            return undoFallback(action: executedAction, accessoryID: id)

        case "dim":
            if let raw = intVal("00000008-0000-1000-8000-0026bb765291") {
                let normalized = Double(raw) / 100.0
                return .undo(accessoryID: id, action: "dim",
                             value: normalized, label: "Ripristina \(raw)%")
            }
            return .undo(accessoryID: id, action: "off", value: nil, label: "Spegni")

        case "setSpeed":
            if let raw = intVal("00000029-0000-1000-8000-0026bb765291") {
                return .undo(accessoryID: id, action: "setSpeed",
                             value: Double(raw) / 100.0, label: "Ripristina")
            }
            return nil

        case "setTemp":
            if let temp = doubleVal("00000035-0000-1000-8000-0026bb765291") {
                return .undo(accessoryID: id, action: "setTemp",
                             value: temp, label: "Ripristina \(Int(temp))°C")
            }
            return nil

        case "open":
            return .undo(accessoryID: id, action: "close", value: nil, label: "Chiudi")
        case "close":
            return .undo(accessoryID: id, action: "open", value: nil, label: "Riapri")

        default:
            return nil
        }
    }

    /// Pure action inversion — used when characteristicValues is not cached.
    private func undoFallback(action: String, accessoryID: String) -> AgentActionPayload? {
        let id = accessoryID
        switch action {
        case "on":    return .undo(accessoryID: id, action: "off",   value: nil, label: "Spegni")
        case "off":   return .undo(accessoryID: id, action: "on",    value: nil, label: "Riaccendi")
        case "open":  return .undo(accessoryID: id, action: "close", value: nil, label: "Chiudi")
        case "close": return .undo(accessoryID: id, action: "open",  value: nil, label: "Riapri")
        default: return nil
        }
    }

    /// Renders assistant messages with inline markdown (bold, italic, code).
    /// User messages stay as plain text. Falls back to plain text if parsing fails.
    @ViewBuilder
    private func renderedText(_ msg: ChatMessage) -> some View {
        if msg.role == .assistant,
           let attributed = try? AttributedString(
               markdown: msg.content,
               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            Text(attributed)
        } else {
            Text(msg.content)
        }
    }

    private var liveTranscriptBubble: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 48)
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                Text(query.isEmpty ? "…" : query)
                    .font(.body)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(BrandColor.primary.opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.red.opacity(0.35), lineWidth: 1))
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
    }

    private var emptyState: some View {
        defaultEmptyStateView
    }

    private var defaultEmptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "house.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(String(localized: "agent.emptyState.title", defaultValue: "How's the house?"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(String(localized: "agent.emptyState.description",
                        defaultValue: "Ask about temperature, devices, security, or energy usage."))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private var assistantLoadingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(.secondary)
            Text(String(localized: "agent.loading",
                        defaultValue: "Preparing your home data…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Debug logs (#if DEBUG only)

    #if DEBUG
    private var debugLogSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Debug — \(debugLogs.count) eventi")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            ForEach(debugLogs) { entry in
                Text(entry.message)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
    #endif

    // MARK: - Provider warning

    private var isClaudeOperational: Bool {
        aiSettings.selectedProvider == .claude && aiSettings.isOperational
    }

    private var providerWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(warningText)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }

    private var warningText: String {
        if aiSettings.selectedProvider != .claude {
            let provider = aiSettings.selectedProvider.localizedName
            let base = String(localized: "agent.warning.wrongProvider",
                              defaultValue: "Home intelligence requires Claude AI.")
            return "\(base) (\(provider))"
        }
        return String(localized: "agent.warning.notOperational",
                      defaultValue: "AI not operational. Check API key and consent in Settings → AI.")
    }

    // MARK: - Input bar (voice-only)

    private var inputBar: some View {
        VStack(spacing: 8) {
            if let errorMessage = speechService.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
            }
            if speechService.isRecording {
                Text(query.isEmpty ? String(localized: "speech.listening", defaultValue: "Listening…") : query)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack {
                Spacer()
                voiceMicButton
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: speechService.errorMessage)
        .animation(.easeInOut(duration: 0.2), value: speechService.isRecording)
    }

    private var voiceMicButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            ZStack {
                // Ambient pulse ring — only while recording
                if speechService.isRecording {
                    Circle()
                        .fill(Color.red.opacity(micPulse ? 0.18 : 0.0))
                        .frame(width: 96, height: 96)
                        .scaleEffect(micPulse ? 1.08 : 0.85)
                }
                // Core content with Liquid Glass
                Group {
                    if isRunning {
                        ProgressView().controlSize(.regular).tint(.secondary)
                    } else if isPreparing {
                        ProgressView().controlSize(.regular).tint(.primary)
                    } else {
                        Image(systemName: speechService.isRecording ? "mic.fill" : "mic")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(speechService.isRecording ? .white : .primary)
                    }
                }
                .frame(width: 68, height: 68)
                .glassEffect(
                    speechService.isRecording
                        ? .regular.tint(.red).interactive()
                        : .regular.interactive(),
                    in: Circle()
                )
                // Rainbow ring — only during AI processing
                if isRunning {
                    RainbowBorderView(cornerRadius: 34)
                        .frame(width: 68, height: 68)
                }
            }
            .frame(width: 104, height: 104)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isRunning || isPreparing)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: speechService.isRecording)
        .animation(.easeInOut(duration: 0.2), value: isRunning)
        .animation(.easeInOut(duration: 0.15), value: isPreparing)
    }

    private func toggleRecording() async {
        if speechService.isRecording {
            speechService.stopRecording()
            scheduleVoiceSubmit()
            return
        }
        speechService.clearError()
        if speechService.permissionState == .undetermined {
            await speechService.requestPermissionsIfNeeded()
        }
        guard speechService.permissionState == .authorized else {
            speechService.setError(SpeechRecognitionService.SpeechRecognitionError.permissionsDenied)
            return
        }
        guard speechService.isAvailable else {
            speechService.setError(SpeechRecognitionService.SpeechRecognitionError.recognizerUnavailable)
            return
        }
        isPreparing = true
        defer { isPreparing = false }
        do {
            try await speechService.startRecording()
        } catch {
            speechService.setError(error)
        }
    }

    // MARK: - Setup

    private func setupViewModels() {
        let evm = EnvironmentViewModel()
        evm.configure(modelContainer: modelContext.container)
        evm.loadFromCoreData()
        envVM = evm

        let avm = AccessoriesViewModel(homeKit: homeKit)
        accessoriesVM = avm
        // Defer HomeKit introspection to the next run loop so the main actor
        // is not blocked during view ready transition.
        Task { avm.refresh() }
    }

    // MARK: - Send

    private func scheduleVoiceSubmit() {
        voiceSubmitTask?.cancel()
        voiceSubmitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            submitVoiceQueryIfNeeded()
        }
    }

    private func submitVoiceQueryIfNeeded() {
        guard !isRunning,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if envVM == nil || accessoriesVM == nil {
            setupViewModels()
            isReady = true
        }
        sendQuery()
    }

    private func sendQuery() {
        if envVM == nil || accessoriesVM == nil {
            setupViewModels()
            isReady = true
        }
        guard let envVM, let accessoriesVM else {
            speechService.setError(SpeechRecognitionService.SpeechRecognitionError.startFailed(
                NSError(
                    domain: "HomeFloorplan.ChatBotView",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "agent.error.notReady", defaultValue: "Assistant is not ready yet. Try again.")]
                )
            ))
            return
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        messages.append(ChatMessage(role: .user, content: trimmed))
        query    = ""
        isRunning = true
        #if DEBUG
        debugLogs = []
        #endif

        let dispatcher = ToolDispatcher(
            environmentVM:       envVM,
            accessoriesVM:       accessoriesVM,
            homeKit:             homeKit,
            weatherKit:          weatherKit,
            behavioralService:   behavioralService,
            ruleEngine:          ruleEngine,
            modelContainer:      modelContext.container,
            smartLightingEngine: smartLightingEngine,
            scenesService:       scenesService
        )
        let service = AgentLoopService(settings: aiSettings)

        let historySnapshot = turnHistory

        loopTask = Task { @MainActor [service, dispatcher] in
            let result = await service.run(
                query: trimmed,
                history: historySnapshot,
                dispatcher: dispatcher
            ) { message in
                #if DEBUG
                debugLogs.append(AgentLogEntry(message))
                #endif
            }
            isRunning = false
            switch result {
            case .success(let response):
                var msg = ChatMessage(role: .assistant, content: response.text)
                msg.actionPayload = response.actionPayload
                messages.append(msg)
                // A1 — aggiorna history (max 4 turni)
                var updated = turnHistory
                updated.append(ConversationTurn(userText: trimmed, assistantText: response.text))
                if updated.count > 4 { updated.removeFirst() }
                turnHistory = updated
                ChatSessionStore.save(messages: messages, turns: updated)
            case .failure(let error):
                messages.append(ChatMessage(role: .assistant, content: "⚠️ \(error.localizedDescription)"))
            }
        }
    }
}

// MARK: - ThinkingDotsView

private struct ThinkingDotsView: View {
    @State private var phase = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                        .offset(y: phase ? -5 : 0)
                        .animation(
                            .easeInOut(duration: 0.5)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.18),
                            value: phase
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            Spacer(minLength: 48)
        }
        .onAppear { phase = true }
    }
}

// MARK: - RainbowBorderView

/// Continuously-rotating angular gradient border — Apple Intelligence style.
/// Uses TimelineView for per-frame 60fps updates without withAnimation drift.
private struct RainbowBorderView: View {
    var cornerRadius: CGFloat = 20
    var lineWidth: CGFloat    = 2

    @State private var startDate = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let phase   = elapsed.truncatingRemainder(dividingBy: 3.0) / 3.0
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    AngularGradient(
                        colors: [
                            Color(hue: 0.76, saturation: 0.80, brightness: 0.90),
                            Color(hue: 0.62, saturation: 0.85, brightness: 0.95),
                            Color(hue: 0.52, saturation: 0.78, brightness: 0.92),
                            Color(hue: 0.42, saturation: 0.70, brightness: 0.88),
                            Color(hue: 0.14, saturation: 0.82, brightness: 0.97),
                            Color(hue: 0.06, saturation: 0.85, brightness: 0.92),
                            Color(hue: 0.93, saturation: 0.78, brightness: 0.92),
                            Color(hue: 0.76, saturation: 0.80, brightness: 0.90),
                        ],
                        center: .center,
                        startAngle: .degrees(phase * 360),
                        endAngle:   .degrees(phase * 360 + 360)
                    ),
                    lineWidth: lineWidth
                )
                .blur(radius: 0.8)
        }
    }
}
