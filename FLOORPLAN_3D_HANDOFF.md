# Floorplan 3D Handoff

Data: 2026-08-06
Branch: `floorplan-3d`

## Obiettivo

Valutare se continuare con un 3D generato dal Drawing Context esistente o passare a RoomPlan. Per ora stiamo spingendo un MVP RealityKit da planimetria 2D, con muri bianchi, pavimenti, porte, finestre, balcone, ombre, selezione stanza e materiali base.

## Direzione Prodotto

- Restare per ora su Drawing Context + RealityKit per validare il potenziale visivo.
- Non usare SceneKit: scelta esplicita verso RealityKit.
- RoomPlan resta candidato per una fase successiva, soprattutto per scansione reale, identificazione porte/finestre/mobili e rifinitura planimetria.
- Il modello 3D deve restare pulito, leggibile e vicino allo stile di una app concorrente: muri bianchi, pavimenti chiari, ombre morbide, infissi leggibili.

## Stato Implementazione

File principali:

- `HomeFloorplan/Models/FloorplanScene.swift`
- `HomeFloorplan/Services/Drawing/FloorplanExtruder.swift`
- `HomeFloorplan/Services/Drawing/FloorplanMaterialCatalog.swift`
- `HomeFloorplan/Services/Drawing/FloorplanSceneBuilder.swift`
- `HomeFloorplan/Views/FloorplanRealityPreviewView.swift`
- `HomeFloorplan/Views/FloorplanListView.swift`
- `HomeFloorplan/Resources/Materials/oak_veneer_01_diff_1k.jpg`
- `HomeFloorplan/Resources/Models/White_Double_Windowed_Door.usdz`

Funzionalità già introdotte:

- Preview 3D fullscreen con RealityKit e `ARView(cameraMode: .nonAR)`.
- Generazione `FloorplanScene` renderer-agnostic da `DrawingDocument`.
- Estrusione muri e pavimenti dal modello 2D.
- Porte e finestre generate dal Drawing Context.
- Porte leggermente aperte, con materiale più contrastato.
- Finestre con vetro meno azzurro e frame.
- Balcone rappresentato con parapetto semi-trasparente.
- Pavimento presente e separato dallo sfondo.
- Ombra generale della casa, non più rettangolo nero pieno.
- Camera custom con pan/pinch/tap, più fluida rispetto ai gesti SwiftUI iniziali.
- Selezione stanza via tap: usa room ID/room name già associati nel Drawing Context/HomeKit.
- Pavimenti base ereditati dal Drawing Context tramite `FloorKind`.
- Primo test materiale: marmo procedurale texture-based con UV sui pavimenti.
- Catalogo materiali dedicato in `FloorplanMaterialCatalog`, separato dal renderer RealityKit.
- Texture parquet reale 1K applicata a `FloorKind.legno`.
- Asset porta-finestra USDZ aggiunto al bundle come riferimento/demo, ma non più usato automaticamente nel renderer.
- Porte parametriche differenziate tramite dati Drawing Context: porta ingresso esterna, porta-finestra/scorrevole e porte interne.

## Ultima Modifica

È stato implementato un singolo materiale dimostrativo per capire quanto ci si può spingere:

- aggiunte coordinate UV ai mesh dei pavimenti in `FloorplanRealityPreviewView.swift`;
- `FloorKind.marmo` ora usa una texture procedurale runtime;
- rimossa la vecchia riga geometrica sovrapposta al marmo;
- estratto `FloorplanMaterialCatalog` per preparare materiali veri senza appesantire il renderer;
- aumentato il contrasto della texture procedurale marmo;
- aggiunta texture legno reale ottimizzata 1K per `FloorKind.legno`;
- rimosso l'overlay geometrico delle doghe quando il legno usa texture reale;
- aggiunto asset `White_Double_Windowed_Door.usdz` come riferimento di import USDZ;
- disattivato il rendering automatico del primo USDZ demo, per valutare invece porte generate dalla planimetria;
- propagati `OpeningKind`, `WallKind` e `flipSide` fino al renderer 3D;
- aggiunta resa parametrica differenziata per porte interne, porta ingresso e porta-finestra/scorrevole;
- aggiunti dettagli porta: cornici/incassi, vetri per porta-finestra, maniglia, verso di apertura basato su `flipSide`;
- build Xcode completata con successo dopo questa modifica.

Nota: il materiale marmo è ancora una texture base, non un PBR completo con normal/roughness/specular map. Serve come proof of concept per capire il salto rispetto ai colori piatti.

## Feedback Visivo Utente

Problemi osservati e già affrontati:

- mobili fuori dai muri e caotici: disattivati dall'MVP 3D;
- balcone poco riconoscibile: aggiunto trattamento dedicato;
- ombre brutte/non realistiche: iterato verso ombra generale più morbida;
- sfondo troppo scuro: schiarito verso verde più neutro;
- pavimento nero/invisibile: aggiunto materiale pavimento;
- movimento camera invertito: corretto;
- movimento inizialmente a scatti: migliorato spostando i gesti su UIKit/Coordinator;
- porte poco visibili: aumentato contrasto;
- finestre troppo azzurre: rese meno sature;
- cornici finestre visibili solo da un lato: gestite double-sided.

Feedback ancora aperto:

- il materiale marmo attuale probabilmente va valutato su device; potrebbe servire più contrasto o texture reali;
- le ombre sono ancora stilizzate, non fisicamente corrette;
- le porte aperte dipendono molto dalla prospettiva e possono sembrare strane;
- ora le porte distinguono interno/esterno/porta-finestra, ma resta da rifinire il livello di realismo e le proporzioni dei dettagli;
- il realismo complessivo resta limitato senza asset/materiali PBR veri.

## Decisioni Tecniche

- RealityKit è la base.
- `ARView` è non-AR, per evitare log e overhead ARKit non necessari.
- Materiali principali per ora sono `UnlitMaterial`, perché il modello deve restare leggibile e stabile senza pipeline luce complessa.
- Le ombre attuali sono mesh planari semi-trasparenti, non shadow map fisiche.
- La selezione stanza cambia il materiale del pavimento della stanza selezionata.
- Le stanze vengono riusate dal Drawing Context/HomeKit dove disponibili.

## Limiti Attuali

- Non abbiamo ancora una pipeline PBR completa.
- Sono presenti solo pochi asset reali in bundle: parquet 1K e una porta-finestra USDZ di riferimento.
- La geometria è ancora semplice: muri come prismi, finestre/porte come pannelli.
- Non ci sono cornici dettagliate, battiscopa, spessori realistici avanzati, telai porta/finestra completi.
- Le ombre interne non sono calcolate in base al sole reale.
- La posizione sole può essere simulata, ma per farla bene servono orientamento planimetria, data/ora, posizione geografica e una scelta chiara tra ombre decorative e ombre fisiche.

## Prossimi Step Consigliati

1. Valutare su iPad/device il marmo procedurale appena aggiunto.
2. Se il materiale convince come direzione, sostituire il procedurale con un piccolo set di texture asset reali:
   - parquet chiaro;
   - gres/piastrella;
   - marmo con venature più nette;
   - legno porta;
   - vetro più neutro.
3. Rifinire le tre famiglie di porta:
   - ingresso più piena e materica;
   - porta-finestra con telaio/vetro più realistici;
   - interne più leggere e meno scure.
4. Estendere `FloorplanMaterialCatalog` con texture asset reali e varianti controllabili.
5. Migliorare i materiali con PBR dove utile:
   - base color;
   - roughness;
   - normal map;
   - metallic/specular solo se necessario.
6. Migliorare ombra casa:
   - ombra esterna morbida e direzionale;
   - niente mesh scure sotto la casa visibili come artefatti;
   - eventuale shadow receiver RealityKit se stabile e performante.
7. Aggiungere un solo oggetto dimostrativo realistico, ad esempio:
   - divano minimale;
   - tavolo;
   - cucina blocco semplice;
   - sanitari base.
8. Solo dopo questa validazione, valutare integrazione RoomPlan.

## Nota RoomPlan

RoomPlan è interessante se la priorità diventa:

- scansione reale degli ambienti;
- riconoscimento automatico di muri, porte, finestre e mobili;
- esportazione di geometrie più fedeli;
- flusso utente di scansione/rifinitura.

Però non sostituisce automaticamente il problema visuale/prodotto: anche con RoomPlan serviranno una pipeline materiali, editing, semplificazione geometrica e mapping con stanze/HomeKit.

## Build

Ultimo build eseguito dopo la differenziazione delle porte parametriche: riuscito.

## Stato Git Osservato

Il branch corrente era `floorplan-3d`.

File modificati/non tracciati osservati:

- `HomeFloorplan/Services/Drawing/FloorplanExtruder.swift`
- `HomeFloorplan/Services/Drawing/FloorplanMaterialCatalog.swift`
- `HomeFloorplan/Views/FloorplanListView.swift`
- `HomeFloorplan/Models/FloorplanScene.swift`
- `HomeFloorplan/Services/Drawing/FloorplanSceneBuilder.swift`
- `HomeFloorplan/Views/FloorplanRealityPreviewView.swift`

Nota: alcuni file risultavano non tracciati in Git perché creati durante questa fase di prototipo. Non fare reset o checkout distruttivi.
