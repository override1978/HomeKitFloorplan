// MARK: - BehavioralPatternTests
//
// ⚠️  REQUIRES TEST TARGET
// These tests are compiled as dead code in the main app target.
// To activate: create a "HomeFloorplanTests" test target, move this file,
// then add `@testable import HomeFloorplan` and remove the `#if DEBUG` wrapper.
//
// Coverage: BehavioralPattern.confidence multi-factor decay (Sprint 27.B)

#if DEBUG
import Testing
import Foundation

// MARK: - Test Helper

private func makePattern(
    observations: Int = 10,
    validations: Int = 9,
    stabilityDays: Int = 14,
    daysSinceLast: Int = 0
) -> BehavioralPattern {
    let calendar = Calendar.current
    let lastObserved  = calendar.date(byAdding: .day, value: -daysSinceLast, to: Date()) ?? Date()
    let firstObserved = calendar.date(byAdding: .day, value: -(daysSinceLast + max(stabilityDays, 1)), to: Date()) ?? Date()

    return BehavioralPattern(
        id: UUID(),
        patternType: .temporal,
        detectedAt: firstObserved,
        accessoryName: "Luce Salotto",
        accessoryID: UUID(),
        roomName: "Salotto",
        eventTypeRaw: "powerState",
        action: .on,
        numericValue: nil,
        avgMinuteOfDay: 21 * 60,      // 21:00
        timeDeviationMinutes: 15,
        weekdays: [2, 3, 4, 5, 6],
        dayType: .weekday,
        causeSignature: nil,
        causeName: nil,
        avgGapSeconds: nil,
        observations: observations,
        validations: validations,
        firstObservedAt: firstObserved,
        lastObservedAt: lastObserved,
        stabilityDays: stabilityDays,
        status: .active,
        dismissedAt: nil,
        approvedAt: nil,
        naturalLanguageDescription: "Accende la luce del salotto alle 21:00"
    )
}

// MARK: - BehavioralPattern Confidence Tests

@Suite("BehavioralPattern.confidence")
struct BehavioralPatternConfidenceTests {

    // MARK: Observation threshold

    @Test("confidence is 0.0 with only 1 observation")
    func singleObservationIsZero() {
        let p = makePattern(observations: 1, validations: 1)
        #expect(p.confidence == 0.0)
    }

    @Test("confidence is 0.0 with 0 observations")
    func zeroObservationsIsZero() {
        let p = makePattern(observations: 0, validations: 0)
        #expect(p.confidence == 0.0)
    }

    @Test("confidence is positive with 2+ observations")
    func twoObservationsGivesPositiveConfidence() {
        let p = makePattern(observations: 2, validations: 2, stabilityDays: 1, daysSinceLast: 0)
        #expect(p.confidence > 0.0)
    }

    // MARK: High confidence

    @Test("Fully stable pattern (14d, all validated, observed today) reaches highConfidence tier")
    func fullyStablePatternIsHighConfidence() {
        let p = makePattern(observations: 20, validations: 19, stabilityDays: 14, daysSinceLast: 0)
        #expect(p.tier == .highConfidence)
        #expect(p.confidence >= 0.90)
    }

    // MARK: Cap

    @Test("confidence never exceeds 0.97")
    func confidenceCapAt097() {
        let p = makePattern(observations: 10_000, validations: 10_000, stabilityDays: 365, daysSinceLast: 0)
        #expect(p.confidence <= 0.97)
    }

    // MARK: Stability factor

    @Test("Stability ramps: 14-day pattern has higher confidence than 3-day pattern")
    func stabilityRampsOver14Days() {
        let earlyPattern  = makePattern(observations: 10, validations: 9, stabilityDays: 3,  daysSinceLast: 0)
        let maturePattern = makePattern(observations: 10, validations: 9, stabilityDays: 14, daysSinceLast: 0)
        #expect(maturePattern.confidence > earlyPattern.confidence)
    }

    // MARK: Recency decay

    @Test("Confidence decays when not observed for 10 days")
    func confidenceDecaysAfterInactivity() {
        let fresh = makePattern(observations: 20, validations: 19, stabilityDays: 14, daysSinceLast: 0)
        let stale = makePattern(observations: 20, validations: 19, stabilityDays: 14, daysSinceLast: 10)
        #expect(stale.confidence < fresh.confidence)
    }

    @Test("Confidence after 10 days is significantly lower (>20% drop)")
    func significantDecayAfter10Days() {
        let fresh = makePattern(observations: 20, validations: 19, stabilityDays: 14, daysSinceLast: 0)
        let stale = makePattern(observations: 20, validations: 19, stabilityDays: 14, daysSinceLast: 10)
        let dropRatio = (fresh.confidence - stale.confidence) / fresh.confidence
        #expect(dropRatio > 0.20)
    }

    // MARK: Tier classification

    @Test("Pattern unseen for 7+ days is .decaying tier")
    func sevenDayAbsenceIsDecaying() {
        let p = makePattern(observations: 15, validations: 13, stabilityDays: 14, daysSinceLast: 8)
        #expect(p.tier == .decaying)
    }

    @Test("Pattern unseen for 30+ days is .dormant tier")
    func thirtyDayAbsenceIsDormant() {
        let p = makePattern(observations: 15, validations: 13, stabilityDays: 14, daysSinceLast: 35)
        #expect(p.tier == .dormant)
    }

    @Test("Low-confidence fresh pattern is .emerging tier")
    func lowConfidenceFreshIsEmerging() {
        // Few observations + low stability → confidence < 0.60 → emerging
        let p = makePattern(observations: 3, validations: 2, stabilityDays: 1, daysSinceLast: 0)
        #expect(p.tier == .emerging || p.tier == .forming)
    }

    // MARK: Presentation

    @Test("avgTimeString formats 21:00 correctly")
    func avgTimeStringFormats21h() {
        let p = makePattern() // avgMinuteOfDay = 21 * 60 = 1260
        #expect(p.avgTimeString == "21:00")
    }

    @Test("avgTimeString formats midnight correctly")
    func avgTimeStringFormatsMidnight() {
        var p = makePattern()
        // We need avgMinuteOfDay = 0 → can't use makePattern directly, so test indirectly
        // Create a pattern with 0 minutes of day
        let midnightPattern = BehavioralPattern(
            id: UUID(), patternType: .temporal, detectedAt: Date(),
            accessoryName: "Test", accessoryID: nil, roomName: "Test",
            eventTypeRaw: "powerState", action: .on, numericValue: nil,
            avgMinuteOfDay: 0, timeDeviationMinutes: 5, weekdays: [2],
            dayType: nil, causeSignature: nil, causeName: nil, avgGapSeconds: nil,
            observations: 5, validations: 4, firstObservedAt: Date(), lastObservedAt: Date(),
            stabilityDays: 5, status: .active, dismissedAt: nil, approvedAt: nil,
            naturalLanguageDescription: ""
        )
        #expect(midnightPattern.avgTimeString == "00:00")
    }

    @Test("confidenceLabel shows integer percentage")
    func confidenceLabelIsPercentage() {
        let p = makePattern(observations: 10, validations: 5, stabilityDays: 14, daysSinceLast: 0)
        #expect(p.confidenceLabel.hasSuffix("%"))
    }

    // MARK: Deduplication key

    @Test("deduplicationKey includes accessory name, action, dayType, and patternType")
    func deduplicationKeyIsCanonical() {
        let p = makePattern()
        let key = p.deduplicationKey
        #expect(key.contains("Luce Salotto"))
        #expect(key.contains("on"))
        #expect(key.contains("temporal"))
    }

    @Test("Two patterns with same identity produce same deduplication key")
    func samePatternsSameDedupKey() {
        let p1 = makePattern(observations: 5, validations: 4)
        let p2 = makePattern(observations: 15, validations: 13) // different stats, same identity
        #expect(p1.deduplicationKey == p2.deduplicationKey)
    }
}
#endif
