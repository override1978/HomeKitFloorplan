import Foundation

// MARK: - AIPromptVersion

/// Versioning constants for AI system prompts.
///
/// Bump the relevant constant whenever the system prompt changes in a way that
/// invalidates previously cached insights (different output schema, new fields, etc.).
/// DataLifecycleService expires PersistedInsights whose promptVersion != currentEnvironmental.
enum AIPromptVersion {
    /// Current version of the environmental analysis system prompt.
    static let currentEnvironmental = "env_v3"
    /// Current version of the habit-analysis prompt (future use).
    static let currentHabit = "habit_v1"
    /// Current version of the agent loop system prompt.
    /// v8: controlAccessory(room,type) used directly for explicit commands; listAccessories only for state queries/UUID needs.
    static let currentAgentLoop = "agent_v8"
}
