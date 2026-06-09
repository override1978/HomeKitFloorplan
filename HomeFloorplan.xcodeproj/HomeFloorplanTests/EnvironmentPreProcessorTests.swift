// MARK: - EnvironmentPreProcessorTests
//
// ⚠️  REQUIRES TEST TARGET
// These tests are currently compiled as dead code inside the main app target.
// To activate them:
//   1. Add a new "Unit Testing Bundle" target named "HomeFloorplanTests" in Xcode
//   2. Move this file to that target (uncheck main app, check HomeFloorplanTests)
//   3. Add `@testable import HomeFloorplan` at the top of this file
//   4. The `#if DEBUG` wrapper below can then be removed
//
// Coverage: RoomClassifier + EnvironmentPreProcessor (Sprint 27.B)

#if DEBUG
import Testing
import Foundation

// MARK: - Test Helpers

private func makeSensor(
    type: SensorServiceType,
    value: Double,
    warning: Double,
    danger: Double,
    lastUpdated: Date = Date()
) -> SensorData {
    SensorData(
        id: UUID(),
        accessoryUUIDs: ["test-accessory-uuid"],
        serviceType: type,
        roomName: "TestRoom",
        currentValue: value,
        lastUpdated: lastUpdated,
        warningThreshold: warning,
        dangerThreshold: danger,
        sourceCount: 1
    )
}

private func makeRoom(name: String, sensors: [SensorData]) -> RoomEnvironmentData {
    RoomEnvironmentData(id: UUID(), roomName: name, sensors: sensors)
}

// MARK: - RoomClassifier Tests

@Suite("RoomClassifier")
struct RoomClassifierTests {

    @Test("Kitchen classifies as indoor")
    func kitchenIsIndoor() {
        #expect(RoomClassifier.classify(roomName: "Cucina") == .indoor)
    }

    @Test("Balcony classifies as outdoor via keyword")
    func balconyIsOutdoor() {
        #expect(RoomClassifier.classify(roomName: "Balcone") == .outdoor)
    }

    @Test("Garden classifies as outdoor via keyword")
    func gardenIsOutdoor() {
        #expect(RoomClassifier.classify(roomName: "Giardino") == .outdoor)
    }

    @Test("Garage classifies as utility")
    func garageIsUtility() {
        #expect(RoomClassifier.classify(roomName: "Garage") == .utility)
    }

    @Test("Laundry room classifies as utility")
    func laundryIsUtility() {
        #expect(RoomClassifier.classify(roomName: "Lavanderia") == .utility)
    }

    @Test("Corridor classifies as transit")
    func corridorIsTransit() {
        #expect(RoomClassifier.classify(roomName: "Corridoio") == .transit)
    }

    @Test("User-defined outdoor name overrides keyword-free room")
    func userDefinedOutdoorOverridesIndoor() {
        // "Salone" has no outdoor keyword, but user explicitly set it as outdoor
        #expect(RoomClassifier.classify(roomName: "Salone", outdoorRoomName: "Salone") == .outdoor)
    }

    @Test("User-defined outdoor match is case-insensitive")
    func outdoorMatchIsCaseInsensitive() {
        #expect(RoomClassifier.classify(roomName: "terrazza", outdoorRoomName: "Terrazza") == .outdoor)
    }

    @Test("User-defined outdoor name does NOT affect other rooms")
    func outdoorNameDoesNotAffectOtherRooms() {
        #expect(RoomClassifier.classify(roomName: "Cucina", outdoorRoomName: "Terrazzo") == .indoor)
    }
}

// MARK: - EnvironmentPreProcessor Tests

@Suite("EnvironmentPreProcessor")
struct EnvironmentPreProcessorTests {

    // MARK: AI Gate

    @Test("Normal sensors with no baseline → shouldCallAI = false")
    func normalSensorsNoAICall() {
        let room = makeRoom(name: "Cucina", sensors: [
            makeSensor(type: .temperature, value: 21.0, warning: 27.0, danger: 30.0)
        ])
        let result = EnvironmentPreProcessor.preProcess(room: room, baselineByType: [:])
        #expect(!result.shouldCallAI)
    }

    @Test("Warning-level sensor triggers AI call")
    func warningSensorTriggersAI() {
        let room = makeRoom(name: "Bagno", sensors: [
            makeSensor(type: .humidity, value: 70.0, warning: 65.0, danger: 80.0)
        ])
        let result = EnvironmentPreProcessor.preProcess(room: room, baselineByType: [:])
        #expect(result.shouldCallAI)
    }

    @Test("Danger-level sensor triggers AI call")
    func dangerSensorTriggersAI() {
        let room = makeRoom(name: "Cucina", sensors: [
            makeSensor(type: .humidity, value: 85.0, warning: 65.0, danger: 80.0)
        ])
        let result = EnvironmentPreProcessor.preProcess(room: room, baselineByType: [:])
        #expect(result.shouldCallAI)
    }

    // MARK: Statistical Anomaly

    @Test("Value >1.5σ above baseline is anomalous and triggers AI")
    func highSigmaIsAnomaly() {
        let room = makeRoom(name: "Camera", sensors: [
            makeSensor(type: .humidity, value: 72.0, warning: 80.0, danger: 90.0)
        ])
        // baseline avg=50, stdDev=10 → deviation=(72−50)/10 = 2.2σ > 1.5
        let result = EnvironmentPreProcessor.preProcess(room: room, baselineByType: [
            "humidity": (avg: 50.0, stdDev: 10.0)
        ])
        #expect(result.shouldCallAI)
        #expect(result.sensorStatuses.first?.isAnomaly == true)
        #expect(result.sensorStatuses.first?.anomalyDirection == "high")
        #expect(result.sensorStatuses.first?.actionableAnomaly == true)
    }

    @Test("Value within 1.5σ of baseline is not anomalous")
    func withinBaselineIsNotAnomaly() {
        let room = makeRoom(name: "Soggiorno", sensors: [
            makeSensor(type: .temperature, value: 21.0, warning: 27.0, danger: 30.0)
        ])
        // baseline avg=20, stdDev=2 → deviation=(21−20)/2 = 0.5σ < 1.5
        let result = EnvironmentPreProcessor.preProcess(room: room, baselineByType: [
            "temperature": (avg: 20.0, stdDev: 2.0)
        ])
        #expect(!result.sensorStatuses[0].isAnomaly)
        #expect(!result.shouldCallAI)
    }

    @Test("Zero stdDev baseline is skipped (no anomaly detection)")
    func zeroStdDevSkipsAnomaly() {
        let room = makeRoom(name: "Cucina", sensors: [
            makeSensor(type: .temperature, value: 25.0, warning: 27.0, danger: 30.0)
        ])
        let result = EnvironmentPreProcessor.preProcess(room: room, baselineByType: [
            "temperature": (avg: 25.0, stdDev: 0.0) // division by zero guard
        ])
        #expect(!result.sensorStatuses[0].isAnomaly)
    }

    // MARK: Stale Sensor

    @Test("Sensor not updated in 60+ minutes is stale and triggers AI")
    func staleSensorTriggersAI() {
        let staleDate = Date().addingTimeInterval(-(61 * 60))
        let room = makeRoom(name: "Mansarda", sensors: [
            makeSensor(type: .temperature, value: 20.0, warning: 27.0, danger: 30.0, lastUpdated: staleDate)
        ])
        let result = EnvironmentPreProcessor.preProcess(room: room, baselineByType: [:])
        #expect(result.shouldCallAI)
        #expect(result.sensorStatuses.first?.isStale == true)
        #expect(result.sensorStatuses.first?.staleMinutes != nil)
    }

    @Test("Sensor updated 30 minutes ago is not stale")
    func freshSensorIsNotStale() {
        let recentDate = Date().addingTimeInterval(-(30 * 60))
        let room = makeRoom(name: "Cucina", sensors: [
            makeSensor(type: .temperature, value: 20.0, warning: 27.0, danger: 30.0, lastUpdated: recentDate)
        ])
        let result = EnvironmentPreProcessor.preProcess(room: room, baselineByType: [:])
        #expect(result.sensorStatuses.first?.isStale == false)
    }

    // MARK: Severity Ceiling

    @Test("Normal urgency yields .info severity ceiling")
    func normalUrgencyInfoCeiling() {
        let room = makeRoom(name: "Cucina", sensors: [
            makeSensor(type: .temperature, value: 21.0, warning: 27.0, danger: 30.0)
        ])
        let result = EnvironmentPreProcessor.preProcess(room: room, baselineByType: [:])
        #expect(result.severityCeiling == .info)
    }

    @Test("Warning urgency yields .warning severity ceiling")
    func warningUrgencyWarningCeiling() {
        let room = makeRoom(name: "Bagno", sensors: [
            makeSensor(type: .humidity, value: 70.0, warning: 65.0, danger: 80.0)
        ])
        let result = EnvironmentPreProcessor.preProcess(room: room, baselineByType: [:])
        #expect(result.severityCeiling == .warning)
    }

    @Test("Danger urgency yields .anomaly severity ceiling")
    func dangerUrgencyAnomalyCeiling() {
        let room = makeRoom(name: "Bagno", sensors: [
            makeSensor(type: .humidity, value: 85.0, warning: 65.0, danger: 80.0)
        ])
        let result = EnvironmentPreProcessor.preProcess(room: room, baselineByType: [:])
        #expect(result.severityCeiling == .anomaly)
    }

    // MARK: Severity Clamping

    @Test("clampSeverity reduces anomaly to warning when ceiling is warning")
    func clampAnomalyToWarning() {
        #expect(EnvironmentPreProcessor.clampSeverity(.anomaly, ceiling: .warning) == .warning)
    }

    @Test("clampSeverity reduces warning to info when ceiling is info")
    func clampWarningToInfo() {
        #expect(EnvironmentPreProcessor.clampSeverity(.warning, ceiling: .info) == .info)
    }

    @Test("clampSeverity does not raise severity above ceiling")
    func clampDoesNotRaiseSeverity() {
        #expect(EnvironmentPreProcessor.clampSeverity(.info, ceiling: .anomaly) == .info)
    }

    // MARK: Outdoor Intent Filtering

    @Test("heatRoom and ventilateRoom are blocked for outdoor rooms")
    func hvacBlockedOutdoors() {
        let filtered = EnvironmentPreProcessor.filterIntents([.heatRoom, .coolRoom, .ventilateRoom], for: .outdoor)
        #expect(!filtered.contains(.heatRoom))
        #expect(!filtered.contains(.ventilateRoom))
    }

    @Test("coolRoom passes through for outdoor rooms (has outdoor fallback tip)")
    func coolRoomPassesOutdoors() {
        let filtered = EnvironmentPreProcessor.filterIntents([.heatRoom, .coolRoom, .ventilateRoom], for: .outdoor)
        #expect(filtered.contains(.coolRoom))
    }

    @Test("Indoor rooms have no intent filtering")
    func indoorNoFiltering() {
        let intents: [ActionIntent] = [.heatRoom, .coolRoom, .ventilateRoom, .reduceHumidity]
        let filtered = EnvironmentPreProcessor.filterIntents(intents, for: .indoor)
        #expect(filtered.count == intents.count)
    }

    // MARK: Room Type

    @Test("Balcony room is classified as outdoor in PreProcessorResult")
    func balconyRoomIsOutdoor() {
        let room = makeRoom(name: "Balcone", sensors: [])
        let result = EnvironmentPreProcessor.preProcess(room: room, baselineByType: [:])
        #expect(result.roomType == .outdoor)
    }
}
#endif
