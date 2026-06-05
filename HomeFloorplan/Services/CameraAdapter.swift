import HomeKit
import Observation
import SwiftUI

/// Adapter per telecamere HomeKit.
///
/// Una telecamera HomeKit espone tipicamente:
/// - HMServiceTypeCamera (presenza del servizio camera)
/// - HMCharacteristicTypeMotionDetected (movimento rilevato)
/// - HMCharacteristicTypeOccupancyDetected (presenza rilevata)
/// - HMCameraProfile (snapshot e live stream, se supportato dall'hardware)
@MainActor
@Observable
final class CameraAdapter: AccessoryAdapter {

    let accessory: HMAccessory
    private let homeKit: HomeKitService

    private let motionCharacteristic: HMCharacteristic?
    private let occupancyCharacteristic: HMCharacteristic?

    // Controlli opzionali — presenti solo su hardware che li supporta
    let nightVisionCharacteristic: HMCharacteristic?
    let micMuteCharacteristic: HMCharacteristic?
    let micVolumeCharacteristic: HMCharacteristic?
    let speakerMuteCharacteristic: HMCharacteristic?
    let speakerVolumeCharacteristic: HMCharacteristic?
    let ledIndicatorCharacteristic: HMCharacteristic?

    // HAP UUIDs
    private static let cameraServiceUUID       = "00000111-0000-1000-8000-0026BB765291"
    private static let motionDetectedUUID      = "00000022-0000-1000-8000-0026BB765291"
    private static let occupancyDetectedUUID   = "00000071-0000-1000-8000-0026BB765291"
    private static let nightVisionUUID         = "0000011B-0000-1000-8000-0026BB765291"
    private static let muteUUID                = "0000011A-0000-1000-8000-0026BB765291"
    private static let volumeUUID              = "00000119-0000-1000-8000-0026BB765291"
    private static let ledIndicatorUUID        = "0000021D-0000-1000-8000-0026BB765291"
    private static let microphoneServiceUUID   = "00000112-0000-1000-8000-0026BB765291"
    private static let speakerServiceUUID      = "00000113-0000-1000-8000-0026BB765291"

    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        // Riconosce la telecamera dalla categoria HomeKit oppure dal servizio camera.
        let isCameraCategory = accessory.category.categoryType == HMAccessoryCategoryTypeIPCamera
            || accessory.category.categoryType == HMAccessoryCategoryTypeVideoDoorbell
        let hasCameraService = accessory.services.contains {
            $0.serviceType == Self.cameraServiceUUID
        }
        guard isCameraCategory || hasCameraService else { return nil }

        self.accessory = accessory
        self.homeKit = homeKit
        self.motionCharacteristic = AccessoryAdapterFactory.findCharacteristic(
            in: accessory, type: Self.motionDetectedUUID
        )
        self.occupancyCharacteristic = AccessoryAdapterFactory.findCharacteristic(
            in: accessory, type: Self.occupancyDetectedUUID
        )
        self.nightVisionCharacteristic = AccessoryAdapterFactory.findCharacteristic(
            in: accessory, type: Self.nightVisionUUID
        )
        self.ledIndicatorCharacteristic = AccessoryAdapterFactory.findCharacteristic(
            in: accessory, type: Self.ledIndicatorUUID
        )
        // Mic e speaker vivono su service separati — li cerchiamo nel service corretto
        let micService = accessory.services.first { $0.serviceType == Self.microphoneServiceUUID }
        self.micMuteCharacteristic   = micService?.characteristics.first { $0.characteristicType == Self.muteUUID }
        self.micVolumeCharacteristic = micService?.characteristics.first { $0.characteristicType == Self.volumeUUID }

        let speakerService = accessory.services.first { $0.serviceType == Self.speakerServiceUUID }
        self.speakerMuteCharacteristic   = speakerService?.characteristics.first { $0.characteristicType == Self.muteUUID }
        self.speakerVolumeCharacteristic = speakerService?.characteristics.first { $0.characteristicType == Self.volumeUUID }
    }

    // MARK: - AccessoryAdapter

    var supportsFloorplanPlacement: Bool { true }
    var supportsQuickToggle: Bool { false }
    var batteryInfo: BatteryInfo? { BatteryReader.read(from: accessory, via: homeKit) }
    var markerStyle: MarkerStyle { .camera }

    var iconName: String {
        if motionDetected || occupancyDetected {
            return "video.fill"
        }
        return "video"
    }

    /// "isOn" = c'è attività rilevata (movimento o presenza)
    var isOn: Bool { motionDetected || occupancyDetected }

    var visualUrgency: MarkerUrgency {
        guard homeKit.isReachable(accessory) else { return .alarm }
        if motionDetected || occupancyDetected { return .warning }
        return .normal
    }

    var primaryStatusText: String? {
        guard homeKit.isReachable(accessory) else {
            return String(localized: "camera.status.offline", defaultValue: "Offline")
        }
        if motionDetected {
            return String(localized: "camera.status.motion", defaultValue: "Movimento")
        }
        if occupancyDetected {
            return String(localized: "camera.status.occupancy", defaultValue: "Presenza")
        }
        return String(localized: "camera.status.idle", defaultValue: "Inattiva")
    }

    func performQuickToggle(via homeKit: HomeKitService) async throws {
        // Le telecamere sono read-only — nessuna azione.
    }

    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(CameraControlSection(adapter: self))
    }

    // MARK: - Stato corrente

    var motionDetected: Bool {
        guard let c = motionCharacteristic else { return false }
        let raw = homeKit.value(for: c) ?? c.value
        if let b = raw as? Bool { return b }
        if let i = raw as? Int { return i != 0 }
        if let n = raw as? NSNumber { return n.boolValue }
        return false
    }

    var occupancyDetected: Bool {
        guard let c = occupancyCharacteristic else { return false }
        let raw = homeKit.value(for: c) ?? c.value
        if let i = raw as? Int { return i == 1 }
        if let n = raw as? NSNumber { return n.intValue == 1 }
        return false
    }

    var hasMotionSensor: Bool { motionCharacteristic != nil }
    var hasOccupancySensor: Bool { occupancyCharacteristic != nil }

    // MARK: - HMCameraProfile

    /// Il primo profilo camera disponibile sull'accessorio, se supportato.
    /// Nil se l'hardware non espone HMCameraProfile (es. telecamere solo cloud).
    var cameraProfile: HMCameraProfile? {
        accessory.cameraProfiles?.first
    }

    var supportsSnapshot: Bool {
        cameraProfile?.snapshotControl != nil
    }

    var supportsStream: Bool {
        cameraProfile?.streamControl != nil
    }

    // MARK: - Controlli opzionali

    var hasNightVision: Bool { nightVisionCharacteristic != nil }
    var hasMicrophone:  Bool { micMuteCharacteristic != nil }
    var hasSpeaker:     Bool { speakerMuteCharacteristic != nil }
    var hasLedIndicator: Bool { ledIndicatorCharacteristic != nil }

    var nightVisionOn: Bool {
        guard let c = nightVisionCharacteristic else { return false }
        let raw = homeKit.value(for: c) ?? c.value
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        return false
    }

    var micMuted: Bool {
        guard let c = micMuteCharacteristic else { return false }
        let raw = homeKit.value(for: c) ?? c.value
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        return false
    }

    var micVolume: Int {
        guard let c = micVolumeCharacteristic else { return 50 }
        let raw = homeKit.value(for: c) ?? c.value
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        return 50
    }

    var speakerMuted: Bool {
        guard let c = speakerMuteCharacteristic else { return false }
        let raw = homeKit.value(for: c) ?? c.value
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        return false
    }

    var speakerVolume: Int {
        guard let c = speakerVolumeCharacteristic else { return 80 }
        let raw = homeKit.value(for: c) ?? c.value
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        return 80
    }

    var ledIndicatorOn: Bool {
        guard let c = ledIndicatorCharacteristic else { return false }
        let raw = homeKit.value(for: c) ?? c.value
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        return false
    }

    func setNightVision(_ on: Bool) async {
        guard let c = nightVisionCharacteristic else { return }
        try? await homeKit.write(on, to: c)
    }

    func setMicMute(_ muted: Bool) async {
        guard let c = micMuteCharacteristic else { return }
        try? await homeKit.write(muted, to: c)
    }

    func setSpeakerMute(_ muted: Bool) async {
        guard let c = speakerMuteCharacteristic else { return }
        try? await homeKit.write(muted, to: c)
    }

    func setLedIndicator(_ on: Bool) async {
        guard let c = ledIndicatorCharacteristic else { return }
        try? await homeKit.write(on, to: c)
    }
}
