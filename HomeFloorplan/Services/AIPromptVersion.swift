import Foundation

// MARK: - AIPromptVersion

/// Versioning constants for AI system prompts.
///
/// Bump the relevant constant whenever the system prompt changes in a way that
/// invalidates previously cached insights (different output schema, new fields, etc.).
/// DataLifecycleService expires legacy environmental PersistedInsight records whose
/// promptVersion != currentEnvironmental; unified PersistedHomeInsight records are
/// backfilled from those legacy records and lifecycle-managed independently.
enum AIPromptVersion {
    /// Current version of the environmental analysis system prompt.
    nonisolated static let currentEnvironmental = "env_v3"
    /// Current version of the habit-analysis prompt (future use).
    nonisolated static let currentHabit = "habit_v1"
    /// Current version of the agent loop system prompt.
    /// v8: controlAccessory(room,type) used directly for explicit commands; listAccessories only for state queries/UUID needs.
    nonisolated static let currentAgentLoop = "agent_v8"
}
