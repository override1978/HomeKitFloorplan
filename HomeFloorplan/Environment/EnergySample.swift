import Foundation
import SwiftData

// MARK: - EnergySample

/// Una riga di storico energia: il contatore cumulativo e la potenza istantanea
/// di un dispositivo misurato, come stavano in QUEL momento.
///
/// Fino a qui l'app leggeva questi numeri e li buttava via a ogni lettura: la
/// card della scheda accessorio mostrava il live e nient'altro. È da queste
/// righe — e in particolare dai **delta del cumulativo** fra una riga e
/// l'altra — che nascono i kWh di oggi, di ieri, la sparkline e i costi.
///
/// Il cumulativo è il dato d'oro perché vive SUL DEVICE: se l'app resta chiusa
/// una notte, il delta del mattino contiene comunque tutta l'energia della
/// notte. I buchi di campionamento non perdono energia, la spalmano.
///
/// ⚠️ Il cumulativo può SCENDERE: ri-pairing o reset del device azzerano il
/// contatore. Qui si salva il grezzo così com'è — è il lato lettura
/// (EnergyStatsBuilder) a spezzare i segmenti sui decrementi, così una riga
/// «sporca» non avvelena mai lo storico già scritto.
@Model
final class EnergySample {
    #Index<EnergySample>([\.timestamp], [\.deviceID], [\.deviceID, \.timestamp])

    @Attribute(.unique) var id: UUID
    /// Identità del *misuratore*, stabile fra sessioni: il nodeID Matter
    /// esadecimale, o `eve-<uuid>` per i device legacy HAP. È lo stesso `id`
    /// di `MatterEnergyDeviceSnapshot`, così live e storico parlano la
    /// stessa lingua.
    var deviceID: String
    /// L'accessorio HomeKit principale del nodo, per marker e schede.
    var accessoryUUID: String
    var accessoryName: String
    var roomName: String
    var timestamp: Date
    /// Contatore cumulativo del device in kWh. `nil` se il device espone solo
    /// la potenza.
    var cumulativeKilowattHours: Double?
    /// Potenza istantanea in W. `nil` se non esposta.
    var activePowerWatts: Double?
    /// "Matter" o "Eve legacy" — da dove arriva il numero.
    var sourceRaw: String
    /// Contabilità di sync, mai dentro il CKRecord: true = nata qui e da
    /// spingere; false = già sul server (spinta o arrivata da un altro
    /// device). È il flag che evita l'eco: le righe applicate da remoto non
    /// vengono mai ri-caricate.
    ///
    /// ⚠️ Il default sta QUI, sulla proprietà, non solo nell'init: è il valore
    /// che la migrazione lightweight scrive nelle righe già esistenti. Senza,
    /// l'attributo è «mandatory senza valore» e il container muore all'avvio
    /// (Code=134110) — successo davvero, il 13/08, sulle righe v31.
    var needsSync: Bool = true

    init(
        id: UUID = UUID(),
        deviceID: String,
        accessoryUUID: String,
        accessoryName: String,
        roomName: String,
        timestamp: Date = Date(),
        cumulativeKilowattHours: Double?,
        activePowerWatts: Double?,
        sourceRaw: String,
        needsSync: Bool = true
    ) {
        self.id = id
        self.deviceID = deviceID
        self.accessoryUUID = accessoryUUID
        self.accessoryName = accessoryName
        self.roomName = roomName
        self.timestamp = timestamp
        self.cumulativeKilowattHours = cumulativeKilowattHours
        self.activePowerWatts = activePowerWatts
        self.sourceRaw = sourceRaw
        self.needsSync = needsSync
    }
}
