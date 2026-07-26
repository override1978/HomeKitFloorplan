import Foundation
import CloudKit
import SwiftData

// MARK: - PlacedAccessory snapshot (Codable bridge for CloudKit serialization)

/// Lightweight Codable mirror of PlacedAccessory used to embed markers
/// in the parent Floorplan CKRecord as JSON (no separate CloudKit record type needed).
struct PlacedAccessorySnapshot: Codable {
    var id: UUID
    var homeKitAccessoryUUID: UUID
    var accessoryName: String?
    var roomName: String?
    var positionX: Double
    var positionY: Double
    var linkedRoomUUID: UUID?
    var customLabel: String?
    var iconOverride: String?
}

// MARK: - Floorplan → CKRecord

extension Floorplan {

    /// Encodes the floorplan's fields into a CKRecord.
    /// Large binary fields (imageData, drawingDocumentJSON) are written to temp files
    /// and attached as CKAssets to stay within CloudKit's 1 MB per-field limit.
    func toCKRecord(recordID: CKRecord.ID) -> CKRecord {
        toCKRecord(recordID: recordID, accessorySnapshotProvider: nil)
    }

    func toCKRecord(
        recordID: CKRecord.ID,
        accessorySnapshotProvider: ((UUID) -> (name: String?, roomName: String?))?,
        iconOverrideProvider: ((UUID) -> String?)? = nil
    ) -> CKRecord {
        let record = CKRecord(recordType: "Floorplan", recordID: recordID)

        record["name"]                        = name
        record["createdAt"]                   = createdAt
        record["updatedAt"]                   = updatedAt
        record["tapModeRaw"]                  = tapModeRaw
        record["exteriorFillColorIndex"]      = exteriorFillColorIndex
        record["drawingVisualExportStyleRaw"] = drawingVisualExportStyleRaw
        record["drawingExportRotationRaw"]    = drawingExportRotationRaw
        record["homeUUID"]                    = homeUUID?.uuidString
        record["linkedRoomsJSON"]             = linkedRoomsJSON

        // Markers: serialize all PlacedAccessory objects as JSON inline.
        // Typical size: ~200 bytes/marker × 30 markers ≈ 6 KB — well under the 1 MB field limit.
        let snapshots = accessories.map {
            let identity = accessorySnapshotProvider?($0.homeKitAccessoryUUID)
            return PlacedAccessorySnapshot(
                id:                   $0.id,
                homeKitAccessoryUUID: $0.homeKitAccessoryUUID,
                accessoryName:        identity?.name,
                roomName:             identity?.roomName,
                positionX:            $0.positionX,
                positionY:            $0.positionY,
                linkedRoomUUID:       $0.linkedRoomUUID,
                customLabel:          $0.customLabel,
                iconOverride:         iconOverrideProvider?($0.homeKitAccessoryUUID)
            )
        }
        if let data = try? JSONEncoder().encode(snapshots) {
            record["placedAccessoriesJSON"] = data
        }

        // imageData → CKAsset (avoids the 1 MB per-field limit)
        if let data = currentImageData {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(id.uuidString)_ckimg")
            if (try? data.write(to: url)) != nil {
                record["imageData"] = CKAsset(fileURL: url)
            }
        }

        // drawingDocumentJSON → CKAsset (can grow large with many drawing paths)
        if let data = drawingDocumentJSON {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(id.uuidString)_ckdrawing")
            if (try? data.write(to: url)) != nil {
                record["drawingDocumentJSON"] = CKAsset(fileURL: url)
            }
        }

        return record
    }
}

// MARK: - SensorAlertThreshold → CKRecord

extension SensorAlertThreshold {

    func toCKRecord(recordID: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: "SensorAlertThreshold", recordID: recordID)
        record["id"]             = id.uuidString
        record["serviceTypeRaw"] = serviceTypeRaw
        record["roomName"]       = roomName
        record["warningValue"]   = warningValue
        record["dangerValue"]    = dangerValue
        record["isEnabled"]      = NSNumber(value: isEnabled)
        return record
    }
}

// MARK: - SyncableSettings → CKRecord

extension SyncableSettings {

    /// Encodes all syncable settings fields into a CKRecord.
    /// Booleans are stored as NSNumber to ensure reliable round-trip through CloudKit.
    func toCKRecord(recordID: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: "SyncableSettings", recordID: recordID)

        record["aiProviderRaw"]             = aiProviderRaw
        record["aiIsEnabled"]               = NSNumber(value: aiIsEnabled)
        record["aiSuggestionsEnabled"]      = NSNumber(value: aiSuggestionsEnabled)
        record["aiAnomalyDetectionEnabled"] = NSNumber(value: aiAnomalyDetectionEnabled)
        record["aiRuleEngineEnabled"]       = NSNumber(value: aiRuleEngineEnabled)
        record["aiHasDataConsent"]          = NSNumber(value: aiHasDataConsent)
        record["securityMonitoredUUIDsRaw"] = securityMonitoredUUIDsRaw
        record["masterDeviceID"]            = masterDeviceID
        record["modifiedAt"]                = modifiedAt

        return record
    }
}

// MARK: - PersistedInsight -> CKRecord

extension PersistedInsight {

    func toCKRecord(recordID: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: "PersistedInsight", recordID: recordID)
        record["id"]                   = id.uuidString
        record["roomName"]             = roomName
        record["generatedAt"]          = generatedAt
        record["expiresAt"]            = expiresAt
        record["message"]              = message
        record["severityRaw"]          = severityRaw
        record["intentsRaw"]           = intentsRaw.joined(separator: ",")
        record["nextActionsJSON"]      = nextActionsJSON
        record["statusRaw"]            = statusRaw
        record["intelligenceLevelRaw"] = intelligenceLevelRaw
        record["patternKey"]           = patternKey
        record["whyExplanation"]       = whyExplanation
        record["confidenceScore"]      = confidenceScore
        record["sourceAccessoryID"]    = sourceAccessoryID
        record["sourceAccessoryName"]  = sourceAccessoryName
        record["sourceServiceType"]    = sourceServiceType
        record["promptVersion"]        = promptVersion
        return record
    }
}

