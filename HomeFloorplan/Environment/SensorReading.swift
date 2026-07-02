import Foundation
import SwiftData

// MARK: - SensorReading

/// Lettura puntuale di un sensore ambientale.
/// Persiste ogni campionamento eseguito da SensorLogger.
@Model
final class SensorReading {
    #Index<SensorReading>([\.timestamp], [\.roomName], [\.serviceTypeRaw], [\.roomName, \.serviceTypeRaw])

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
        SensorServiceType.allCases.filter(\.hasAlertThreshold).map { type in
            SensorAlertThreshold(
                id: defaultID(for: type),
                serviceType: type,
                warningValue: type.defaultWarning,
                dangerValue: type.defaultDanger
            )
        }
    }

    private static func defaultID(for serviceType: SensorServiceType) -> UUID {
        func uuid(_ value: String) -> UUID {
            UUID(uuidString: value) ?? UUID()
        }

        switch serviceType {
        case .temperature:        return uuid("F4F54862-7F06-4E7D-B58F-6454A2DE4D7E")
        case .humidity:           return uuid("97679203-9E0B-4E34-9C9C-55A7F89B7A2B")
        case .airQuality:         return uuid("B4039288-1F4E-4CC6-AF4D-4C17AC913C1E")
        case .carbonMonoxide:     return uuid("28E1AB42-6218-4142-B0CE-A7D9A9573C94")
        case .carbonDioxide:      return uuid("40EBFF5C-D273-47BF-A653-41496E2959FD")
        case .smoke:              return uuid("DBB0A1D5-6F68-4580-A7B7-02BFB0F81D19")
        case .vocDensity:         return uuid("55F2E76A-3B97-49F0-AB33-950B7D51A8C2")
        case .pm25:               return uuid("3A08633E-127E-434A-B27D-9F50AA9B7B26")
        case .pm10:               return uuid("B76A7411-3314-49C4-A515-BCE353DFB51B")
        case .lightSensor,
             .outdoorTemperature,
             .outdoorHumidity:
            return uuid("00000000-0000-0000-0000-000000000000")
        }
    }
}
