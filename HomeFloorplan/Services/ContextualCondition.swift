import Foundation

// MARK: - ContextualCondition

/// Condizione ambientale di un pattern contestuale, codificata nella
/// `causeSignature` del BehavioralPattern — zero schema change, stessa strategia dei
/// sequenziali P1.
///
/// Formato legacy (mono-condizione, stanza dell'effetto):
///     "context:<tipo>:<direzione>:<soglia>"
/// Formato esteso (P2 v2 — multi-condizione e/o stanza esplicita):
///     "context:<tipo>[@<stanza>]:<direzione>:<soglia>[+<tipo>[@<stanza>]:...]"
///
/// La stanza è percent-encoded sui caratteri riservati del formato (`@ : + %`).
/// Il formato legacy resta quello di SCRITTURA per il caso mono-condizione in stanza
/// dell'effetto: le decision key utente persistite dipendono dal parsing attuale.
/// NIENTE riferimenti ad accessori HomeKit: il binding è late, per (tipo, stanza),
/// fatto dal mapper contro le capability live.
struct ContextualCondition: Equatable {
    let sensorTypeRaw: String
    /// "above" | "below" — gli stessi valori che AutomationProposalMapper.sensorSelection si aspetta.
    let direction: String
    let threshold: Double
    /// Stanza della condizione. "" = stanza dell'effetto (formato legacy).
    /// Nome ORIGINALE HomeKit, non normalizzato: serve al matching del mapper.
    let roomName: String

    init(sensorTypeRaw: String, direction: String, threshold: Double, roomName: String = "") {
        self.sensorTypeRaw = sensorTypeRaw
        self.direction = direction
        self.threshold = threshold
        self.roomName = roomName
    }

    static let signaturePrefix = "context:"

    /// Caratteri con significato strutturale nella signature, da escapare nel nome stanza.
    private static let reservedCharacters = CharacterSet(charactersIn: "@:+%")

    /// True se la condizione può diventare un predicato HomeKit (i tipi WeatherKit
    /// come outdoorTemperature hanno hmCharacteristicType vuoto e non sono convertibili).
    var isHomeKitBacked: Bool {
        guard let type = SensorServiceType(rawValue: sensorTypeRaw) else { return true }
        return !type.hmCharacteristicType.isEmpty
    }

    private var element: String {
        let typePart: String
        if roomName.isEmpty {
            typePart = sensorTypeRaw
        } else {
            let escaped = roomName.addingPercentEncoding(
                withAllowedCharacters: Self.reservedCharacters.inverted
            ) ?? roomName
            typePart = "\(sensorTypeRaw)@\(escaped)"
        }
        return "\(typePart):\(direction):\(threshold)"
    }

    var signature: String { Self.signature(for: [self]) }

    /// Signature per una lista ordinata di condizioni (la prima è la primaria).
    /// Una condizione sola senza stanza produce il formato legacy, byte-identico a P2 v1.
    static func signature(for conditions: [ContextualCondition]) -> String {
        signaturePrefix + conditions.map(\.element).joined(separator: "+")
    }

    /// Parsa entrambi i formati. Nil se QUALSIASI elemento è malformato
    /// (una signature multi mezza-valida non deve degradare in silenzio).
    static func parseConditions(fromSignature signature: String) -> [ContextualCondition]? {
        guard signature.hasPrefix(signaturePrefix) else { return nil }
        let elements = signature
            .dropFirst(signaturePrefix.count)
            .split(separator: "+", omittingEmptySubsequences: false)
        guard !elements.isEmpty else { return nil }
        var result: [ContextualCondition] = []
        for element in elements {
            guard let condition = parseElement(element) else { return nil }
            result.append(condition)
        }
        return result
    }

    /// Condizione primaria della signature (compatibilità con i call-site P2 v1:
    /// decision key, opportunità, convertibilità leggono da qui).
    static func parse(fromSignature signature: String) -> ContextualCondition? {
        parseConditions(fromSignature: signature)?.first
    }

    private static func parseElement(_ element: Substring) -> ContextualCondition? {
        let parts = element.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty,
              parts[1] == "above" || parts[1] == "below",
              let threshold = Double(parts[2]) else {
            return nil
        }
        let typeField = parts[0]
        if let at = typeField.firstIndex(of: "@") {
            let type = String(typeField[..<at])
            let escapedRoom = String(typeField[typeField.index(after: at)...])
            guard !type.isEmpty,
                  let room = escapedRoom.removingPercentEncoding,
                  !room.isEmpty else { return nil }
            return ContextualCondition(
                sensorTypeRaw: type,
                direction: String(parts[1]),
                threshold: threshold,
                roomName: room
            )
        }
        return ContextualCondition(
            sensorTypeRaw: String(typeField),
            direction: String(parts[1]),
            threshold: threshold
        )
    }
}
