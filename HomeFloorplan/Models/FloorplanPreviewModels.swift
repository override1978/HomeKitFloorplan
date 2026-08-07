import SwiftUI
import RealityKit
import HomeKit
import UIKit

// I modelli con cui la vista 3D parla col resto dell'app: valori puri, nessun
// SwiftData. Erano in testa a `FloorplanRealityPreviewView`, che era diventato
// un file da 3800 righe: qui si legge cosa attraversa il confine, la' come
// viene mostrato.

struct Preview3DMarker {
    let uuid: UUID
    /// Normalizzata sull'immagine esportata.
    let position: CGPoint
    /// Per i contatti: quale apertura sorvegliano.
    let openingID: UUID?
}

/// Quota e direzione di una luce, come stanno **adesso** nel modello.
struct LampSettings {
    var height: Double?
    var direction: LampDirection?
}

struct Preview3DFloorplan: Identifiable {
    let id: UUID
    let name: String
    let document: DrawingDocument
    /// Verso dove guarda il lato alto della pianta, in gradi da nord.
    let northBearingDegrees: Double
    /// La scrittura su SwiftData resta in `FloorplanListView`: l'anteprima
    /// riceve una chiusura e non conosce né il modello né il contesto.
    let applyNorthBearing: (Double) -> Void
    /// L'altezza dei muri di questo piano, e come salvarla.
    let ceilingHeight: Double
    let applyCeilingHeight: (Double) -> Void
    /// Gli accessori piazzati.
    let markers: [Preview3DMarker]
    /// Legge quota e direzione di una luce **dal modello**, ogni volta.
    ///
    /// ⚠️ Non un valore ma una chiusura, e non e' un dettaglio: i marker sono
    /// una fotografia scattata all'apertura, quindi un valore copiato qui
    /// resterebbe indietro appena lo si modifica. Tenere una copia nella vista
    /// per rimediare sarebbe stata una **terza** fonte di verita' accanto a
    /// SwiftData e alla fotografia. Leggendo si resta disaccoppiati e allineati.
    let lampSettings: (UUID) -> LampSettings
    /// Salva quota e direzione. La scrittura su SwiftData resta fuori: qui si
    /// sa cosa, non dove metterlo.
    let applyLampSettings: (UUID, Double, LampDirection?) -> Void
    /// Rotazione con cui l'immagine è stata esportata: serve a rimettere i
    /// marker in coordinate del disegno.
    let exportRotation: DrawingExportRotation
    /// Lo sfondo scelto nell'editor 2D.
    let background: UIColor
}

/// Richiesta di anteprima: **tutte** le planimetrie disegnate, più quale
/// mostrare per prima.
///
/// Portarle tutte permette di cambiare piano senza uscire dalla vista, come
/// nell'editor 2D — e senza che il foglio si chiuda e riapra, cosa che
/// succederebbe se cambiasse l'identità della richiesta.
struct Preview3DRequest: Identifiable {
    let id = UUID()
    let floorplans: [Preview3DFloorplan]
    let initialID: UUID
}

/// Una lampada accesa, pronta a illuminare.
struct FloorplanLamp: Equatable {
    /// Cambia solo quando il cono va rifatto davvero.
    var beamKey: String { "\(direction.rawValue)|\(Int(height * 20))" }
    /// La pozza dipende anche da quanto e' luminosa.
    var poolKey: String { "\(beamKey)|\(Int(brightness * 8))" }

    /// L'accessorio da comandare quando si tocca il bulbo.
    var accessoryUUID: UUID
    var name: String
    var isOn: Bool
    /// Quota da terra, in metri.
    var height: Double
    var direction: LampDirection
    /// In metri, nello spazio del disegno.
    var position: SIMD2<Double>
    /// 0…1, dalla luminosità impostata sull'accessorio.
    var brightness: Double
    var colour: UIColor
}

/// Un'unità di clima già collocata: dov'è, com'è fatta, cosa sta facendo.
struct FloorplanClimateUnit: Equatable {
    var accessoryUUID: UUID
    var name: String
    var form: FloorplanClimateReader.Form
    /// Il colore del corpo: lo stato gia' tradotto, qualunque famiglia sia —
    /// caldo/freddo per il clima, viola/rosso per l'antifurto.
    var tint: UIColor
    /// In metri, nello spazio del disegno, **già appoggiata al muro**.
    var position: SIMD2<Double>
    /// Quota da terra, in metri.
    var height: Double
    /// Rotazione attorno alla verticale, per stare in piano contro la parete.
    var bearing: Double
}

/// Cosa c'è sotto il dito.
///
/// Una lampada e uno split si identificano con l'accessorio; una tapparella e
/// una tenda con **il pezzo di casa che coprono**, perché la geometria conosce
/// il vano e la stanza, non l'UUID HomeKit. La traduzione la fa la vista, che è
/// quella che ha costruito il legame.
enum FloorplanTapTarget: Equatable {
    case accessory(UUID)
    case awning(roomID: UUID)
    case shutter(openingID: UUID)
}

/// Una tenda gia' collocata: la forma, l'accessorio che la muove, quanto e'
/// fuori.
struct FloorplanAwning: Equatable {
    var roomID: UUID
    var accessoryUUID: UUID
    /// 0 ritirata … 1 tutta stesa, dallo stato HomeKit.
    var extended: Double
    var geometry: FloorplanExtruder.AwningGeometry
}

/// Il campo visivo di una telecamera, appoggiato al pavimento.
struct FloorplanCameraCone: Equatable {
    var accessoryUUID: UUID
    /// In metri, nello spazio del disegno.
    var position: SIMD2<Double>
    /// Versore di dove guarda, nello spazio del disegno.
    var direction: SIMD2<Double>
}

/// Cosa mostra la bandierina di una stanza. Il contenuto arriva dal modello
/// condiviso con la 2D; qui resta solo come disegnarlo.
struct RoomFlag {
    /// Serve solo alla firma della mappa di calore: la macchia dipende dalla
    /// stanza e dal colore, non dal numero scritto sulla bandierina.
    var brightnessKey: Double { needsAttention ? 1 : 0 }
    var roomID: UUID
    var anchor: SIMD2<Double>
    var title: String
    var value: String
    /// `nil` quando la bandierina **non porta uno stato** ma solo un'etichetta:
    /// niente pallino, niente velatura, niente muri accesi.
    var accent: UIColor?
    /// Solo le stanze che chiedono attenzione prendono la velatura. Una tinta
    /// su una stanza che sta bene non dice niente: sporca il materiale e toglie
    /// forza all'unica che invece va vista.
    var needsAttention: Bool
}

/// Di cosa parla la vista in questo momento.
///
/// Sono **le stesse modalità della 2D**, non un vocabolario nuovo: se la casa
/// si racconta in due lingue diverse a seconda di dove la guardi, l'utente deve
/// imparare due volte.
enum PreviewMode: String, CaseIterable, Identifiable {
    case off, environment, security

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .off:         "eye.slash"
        case .environment: "leaf.fill"
        case .security:    "lock.shield.fill"
        }
    }

    var label: String {
        switch self {
        case .off:         String(localized: "overlay.off", defaultValue: "Off")
        case .environment: String(localized: "overlay.environment", defaultValue: "Environment")
        case .security:    String(localized: "overlay.security", defaultValue: "Security")
        }
    }

    /// Il colore dello strato, sulla capsula che lo seleziona.
    ///
    /// Serve a far dire alla cornice **cosa stai guardando**, che prima lo
    /// diceva solo il modello: capsule tutte uguali e glifi tutti bianchi non
    /// portavano nessuna informazione, ed e' per quello che la barra sembrava
    /// spenta — non perche' fosse poco decorata.
    ///
    /// Sono le stesse tinte degli strati nel modello, non una tavolozza nuova.
    /// Controlli resta senza, e non e' una rinuncia: li' davvero non c'e'
    /// nessuno strato acceso.
    var accent: Color? {
        switch self {
        case .off:         nil
        case .environment: Color(red: 0.24, green: 0.66, blue: 0.44)
        case .security:    Color(UIColor.systemPurple)
        }
    }
}

// MARK: - Camera

/// Le inquadrature pronte: ognuna e' solo una terna azimut/elevazione/distanza.
enum CameraPreset: Equatable {
    /// Quasi zenitale: la pianta viva, tutta la casa in un colpo.
    case top
    /// Il tre quarti da dashboard, l'inquadratura di apertura.
    case angle
    /// Bassa, ad altezza occhi: quella dove la casa sembra una casa.
    case front
}

/// Un comando di camera con identita': lo stesso preset chiesto due volte deve
/// eseguire due volte, ed e' l'`id` a distinguere le richieste.
struct CameraCommand: Equatable {
    var id: UUID
    var preset: CameraPreset
}

// MARK: - FloorplanSunLight

/// Il sole, già tradotto nello spazio del modello.
///
/// La vista fa l'astronomia una volta e passa al renderer un vettore: il
/// Coordinator non deve sapere niente di latitudini e ore.
struct FloorplanSunLight: Equatable {
    /// Versore che punta **verso** il sole. y in alto, come in RealityKit.
    var direction: SIMD3<Float>
    var elevationDegrees: Double
    var isAboveHorizon: Bool
}
