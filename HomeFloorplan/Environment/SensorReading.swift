import Foundation
import SwiftData

// MARK: - SensorReading

/// Lettura puntuale di un sensore ambientale.
/// Persiste ogni campionamento eseguito da SensorLogger.
@Model
final class SensorReading {
    @Attribute(.unique) var id: UUID
    var accessoryUUID: String
    var serviceTypeRaw: String
    var roomName: String
    var value: Double
    var timestamp: Date

    init(
        id: UUID = UUID(),
        accessoryUUID: String,
        serviceType: SensorServiceType,
        roomName: String,
        value: Double,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.accessoryUUID = accessoryUUID
        self.serviceTypeRaw = serviceType.rawValue
        self.roomName = roomName
        self.value = value
        self.timestamp = timestamp
    }

    /// Tipo sensore tipizzato (fallback su .temperature se stringa non riconosciuta).
    var serviceType: SensorServiceType {
        SensorServiceType(rawValue: serviceTypeRaw) ?? .temperature
    }
}

// MARK: - AlertEvent

/// Evento di alert generato quando un valore supera una soglia critica.
@Model
final class SensorAlertEvent {
    @Attribute(.unique) var id: UUID
    var accessoryUUID: String
    var serviceTypeRaw: String
    var roomName: String
    var triggeredAt: Date
    var resolvedAt: Date?
    var peakValue: Double
    var thresholdValue: Double

    init(
        id: UUID = UUID(),
        accessoryUUID: String,
        serviceType: SensorServiceType,
        roomName: String,
        triggeredAt: Date = Date(),
        resolvedAt: Date? = nil,
        peakValue: Double,
        thresholdValue: Double
    ) {
        self.id = id
        self.accessoryUUID = accessoryUUID
        self.serviceTypeRaw = serviceType.rawValue
        self.roomName = roomName
        self.triggeredAt = triggeredAt
        self.resolvedAt = resolvedAt
        self.peakValue = peakValue
        self.thresholdValue = thresholdValue
    }

    var serviceType: SensorServiceType {
        SensorServiceType(rawValue: serviceTypeRaw) ?? .temperature
    }
}

// MARK: - AlertThreshold

/// Configurazione soglie di alert per tipo di sensore, opzionalmente per stanza.
@Model
final class SensorAlertThreshold {
    @Attribute(.unique) var id: UUID
    var serviceTypeRaw: String
    /// Nil = soglia globale, non-nil = soglia per stanza specifica.
    var roomName: String?
    var warningValue: Double
    var dangerValue: Double
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        serviceType: SensorServiceType,
        roomName: String? = nil,
        warningValue: Double,
        dangerValue: Double,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.serviceTypeRaw = serviceType.rawValue
        self.roomName = roomName
        self.warningValue = warningValue
        self.dangerValue = dangerValue
        self.isEnabled = isEnabled
    }

    var serviceType: SensorServiceType {
        SensorServiceType(rawValue: serviceTypeRaw) ?? .temperature
    }

    /// Crea i threshold di default per tutti i tipi di sensore.
    static func defaultThresholds() -> [SensorAlertThreshold] {
        SensorServiceType.allCases.map { type in
            SensorAlertThreshold(
                serviceType: type,
                warningValue: type.defaultWarning,
                dangerValue: type.defaultDanger
            )
        }
    }
}
