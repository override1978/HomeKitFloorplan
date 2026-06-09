import Foundation

// MARK: - DebugLog — Privacy Audit (Sprint 26.E)
//
// ┌─────────────────────────────────────────────────────────────────┐
// │  PRIVACY CLASSIFICATION: DEBUG-ONLY — RELEASE SAFE              │
// └─────────────────────────────────────────────────────────────────┘
//
// All debug output in this app is funnelled through one of two paths:
//
//   1. dprint()         — this file, #if DEBUG body, @inline(__always)
//   2. AITraceLogger    — entirely wrapped in #if DEBUG at file level
//
// RELEASE BUILDS: dprint() is a zero-body function. @inline(__always)
// eliminates every call site from the binary. No strings are evaluated,
// no output is produced. AITraceLogger is fully compiled out.
//
// ── What MAY appear in debug logs ───────────────────────────────────
//   • HomeKit room names and accessory names (user-defined labels)
//   • Sensor numeric values (temperature, humidity, CO₂, air quality)
//   • HomeKit event types and accessory UUIDs
//   • SwiftData schema version numbers and container lifecycle events
//   • AI pipeline phase summaries (sensor anomaly scores, severity, intents)
//   • Service lifecycle events (start, stop, background task scheduling)
//   • Rule evaluation results and occupancy prediction confidence scores
//
// ── What is NEVER logged ────────────────────────────────────────────
//   • API keys or Keychain values (never held in memory beyond Keychain ops)
//   • Apple ID, iCloud account details, or user identity
//   • GPS coordinates or precise location data
//   • HomeKit video / audio streams or camera metadata
//   • Family member names or profile identifiers
//
// ── Raw print() audit ───────────────────────────────────────────────
//   No raw print() calls exist outside of #if DEBUG guards.
//   Verified via codebase grep (Sprint 26.E, 2026-06-09).
//   AITraceLogger.log() and printDailySummary() use print() internally
//   but are unreachable in Release because the entire file is #if DEBUG.

/// Stampa messaggi di debug solo nelle build DEBUG.
/// In Release (App Store / TestFlight) il corpo è vuoto e la funzione viene ottimizzata via.
@inline(__always)
func dprint(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
    let output = items.map { "\($0)" }.joined(separator: separator)
    print(output, terminator: terminator)
#endif
}
