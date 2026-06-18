import Foundation

// MARK: - AccessoryChoice

/// Un singolo accessorio presentabile come pill di selezione nella chat.
struct AccessoryChoice: Equatable {
    let id:   String   // UUID HomeKit
    let name: String   // nome leggibile
}

// MARK: - AutomationDiagnosticItem

struct AutomationDiagnosticItem: Equatable {
    let title: String
    let trigger: String
    let action: String
    let mode: String
    let isEnabled: Bool
    let status: String
}

// MARK: - AgentActionPayload

/// Payload strutturato per un bottone azione nel ChatBot.
///
/// - `executeNow`: esegui azione HomeKit direttamente (imperativo da proposeAction).
/// - `createRule`: crea una regola di automazione dal chatbot (da proposeOpportunity).
/// - `undo`:       annulla un'azione appena eseguita (rimette lo stato precedente).
enum AgentActionPayload: Equatable {
    case executeNow(accessoryID: String, action: String, value: Double?, label: String)
    case createRule(opportunity: AutomationOpportunity)
    case undo(accessoryID: String, action: String, value: Double?, label: String)
    case automationDiagnostics(title: String, items: [AutomationDiagnosticItem])
    /// Presenta una lista di accessori come pills selezionabili per disambiguare.
    case choose(accessories: [AccessoryChoice], action: String, value: Double?, promptText: String)

    var label: String {
        switch self {
        case .executeNow(_, _, _, let l):    return l
        case .createRule(let opp):            return opp.title
        case .undo(_, _, _, let l):           return l
        case .automationDiagnostics(let title, _): return title
        case .choose(_, _, _, let prompt):    return prompt
        }
    }
}

// MARK: - ConversationTurn

/// Coppia user-text / assistant-text per la history multi-turn.
struct ConversationTurn: Equatable, Codable {
    let userText: String
    let assistantText: String
}

// MARK: - AgentResponse

/// Risultato di un singolo run() dell'agent loop.
struct AgentResponse {
    let text: String
    let actionPayload: AgentActionPayload?
}

// MARK: - AgentTurn

/// Result of a single LLM call: either a final text response or one-or-more tool calls.
enum AgentTurn {
    case textResponse(String)
    case toolCalls([ToolCall])

    struct ToolCall {
        let id: String
        let name: String
        let input: [String: Any]
    }
}

// MARK: - ToolSchema

/// Claude tool definition sent in the API request body.
struct ToolSchema {
    let name: String
    let description: String
    let inputSchema: [String: Any]

    func toJSON() -> [String: Any] {
        ["name": name, "description": description, "input_schema": inputSchema]
    }
}

// MARK: - AgentError

enum AgentError: LocalizedError {
    case providerNotSupported
    case iterationCapReached

    var errorDescription: String? {
        switch self {
        case .providerNotSupported:
            return String(
                localized: "agent.error.providerNotSupported",
                defaultValue: "Le funzioni agentiche richiedono il provider Claude. Configura Claude in Impostazioni → AI."
            )
        case .iterationCapReached:
            return String(
                localized: "agent.error.iterationCapReached",
                defaultValue: "Loop terminato: raggiunto il limite di 5 iterazioni."
            )
        }
    }
}

// MARK: - AgentLogEntry

struct AgentLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String

    init(_ message: String) {
        self.timestamp = Date()
        self.message = message
    }
}
