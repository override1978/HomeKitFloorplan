// MARK: - CircularMeanTests
//
// ⚠️  REQUIRES TEST TARGET
// These tests are compiled as dead code in the main app target.
// To activate: create a "HomeFloorplanTests" test target, move this file,
// then add `@testable import HomeFloorplan` and remove the `#if DEBUG` wrapper.
//
// Coverage: Circular mean algorithm used by HabitAnalysisService.averageTimeString(from:)
// (Sprint 27.B — "Test per circular mean in averageTimeString")
//
// The function under test is private to HabitAnalysisService, so this file
// re-implements the same algorithm and validates its properties independently.
// When moved to a test target, consider making averageTimeString(from:) `internal`
// and testing it directly with `@testable import HomeFloorplan`.

#if DEBUG
import Testing
import Foundation

// MARK: - Circular Mean Implementation (mirrors HabitAnalysisService.averageTimeString)

/// Returns the circular mean of a list of minute-of-day values (0–1439).
/// Uses vector averaging on the unit circle to correctly handle wrap-around at midnight.
private func circularMeanMinuteOfDay(from minutes: [Int]) -> Int {
    guard !minutes.isEmpty else { return 0 }
    var sinSum = 0.0
    var cosSum = 0.0
    for m in minutes {
        let radians = (Double(m) / 1440.0) * 2 * .pi
        sinSum += sin(radians)
        cosSum += cos(radians)
    }
    let avgAngle   = atan2(sinSum, cosSum)
    let normalized = avgAngle < 0 ? avgAngle + 2 * .pi : avgAngle
    return Int((normalized / (2 * .pi)) * 1440) % 1440
}

// MARK: - Tests

@Suite("Circular Mean — averageTimeString")
struct CircularMeanTests {

    // MARK: Basic correctness

    @Test("Mean of identical times equals that time")
    func identicalTimesGiveSelf() {
        let result = circularMeanMinuteOfDay(from: [21 * 60, 21 * 60, 21 * 60])
        #expect(result == 21 * 60)
    }

    @Test("Mean of two symmetric times equals midpoint")
    func symmetricTimesGiveMidpoint() {
        // 08:00 (480) and 10:00 (600) → mean = 09:00 (540)
        let result = circularMeanMinuteOfDay(from: [480, 600])
        #expect(abs(result - 540) <= 1)
    }

    @Test("Mean of single time is that time (within rounding)")
    func singleTimeGivesSelf() {
        let input = 9 * 60 + 15  // 09:15 = 555
        let result = circularMeanMinuteOfDay(from: [input])
        #expect(abs(result - input) <= 1) // allow 1-minute rounding
    }

    // MARK: Midnight wrap-around (critical case)

    @Test("Mean of 23:00 and 01:00 is near midnight — not midday")
    func midnightWrapAroundIsCorrect() {
        // Naïve mean of 1380 and 60 = 720 (12:00) — WRONG
        // Circular mean should be ≈0 (00:00) — CORRECT
        let result = circularMeanMinuteOfDay(from: [23 * 60, 1 * 60])
        let isNearMidnight = result <= 60 || result >= 1380
        #expect(isNearMidnight, "Expected result ≈ 00:00, got \(result / 60):\(result % 60)")
    }

    @Test("Mean of 22:30, 23:00, 23:30, 00:00 stays in late evening / midnight")
    func lateEveningGroupStaysNearMidnight() {
        let minutes = [22 * 60 + 30, 23 * 60, 23 * 60 + 30, 0]
        let result = circularMeanMinuteOfDay(from: minutes)
        let isNearMidnight = result >= 22 * 60 || result <= 30
        #expect(isNearMidnight, "Expected result near 23:00, got \(result / 60):\(result % 60)")
    }

    @Test("Mean of three morning times stays in morning")
    func morningGroupStaysInMorning() {
        let minutes = [7 * 60, 7 * 60 + 30, 8 * 60]
        let result = circularMeanMinuteOfDay(from: minutes)
        #expect(result >= 7 * 60 && result <= 8 * 60,
                "Expected 07:00–08:00, got \(result / 60):\(result % 60)")
    }

    @Test("Mean of evening times stays in evening")
    func eveningGroupStaysInEvening() {
        let minutes = [20 * 60, 21 * 60, 22 * 60]
        let result = circularMeanMinuteOfDay(from: minutes)
        #expect(result >= 20 * 60 && result <= 22 * 60,
                "Expected 20:00–22:00, got \(result / 60):\(result % 60)")
    }

    // MARK: Edge cases

    @Test("Empty input returns 0")
    func emptyInputReturnsZero() {
        #expect(circularMeanMinuteOfDay(from: []) == 0)
    }

    @Test("Midnight (0) is preserved correctly")
    func midnightPreserved() {
        let result = circularMeanMinuteOfDay(from: [0, 0, 0])
        #expect(result == 0 || result == 1439) // 0 and 1439 are equivalent at midnight
    }

    @Test("Result is always in range 0..<1440")
    func resultInValidRange() {
        let testCases = [[0], [720], [1439], [23 * 60, 1 * 60], [1380, 60, 30]]
        for tc in testCases {
            let result = circularMeanMinuteOfDay(from: tc)
            #expect(result >= 0 && result < 1440, "Out of range for input \(tc): \(result)")
        }
    }

    // MARK: Symmetry

    @Test("Algorithm is symmetric: mean(A, B) ≈ mean(B, A)")
    func algorithmIsSymmetric() {
        let r1 = circularMeanMinuteOfDay(from: [480, 600])
        let r2 = circularMeanMinuteOfDay(from: [600, 480])
        #expect(r1 == r2)
    }

    @Test("Duplicate times do not change the mean")
    func duplicatesDoNotChangeMean() {
        let r1 = circularMeanMinuteOfDay(from: [600])
        let r2 = circularMeanMinuteOfDay(from: [600, 600, 600, 600])
        #expect(r1 == r2)
    }
}
#endif
