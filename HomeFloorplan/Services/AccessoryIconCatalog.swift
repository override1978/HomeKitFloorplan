import Foundation

/// Catalogo curato di icone disponibili per la scelta utente.
/// Diviso per categoria smart home, mixa SF Symbols di sistema e asset custom (Lucide).
/// Il render decide a runtime se l'icona è SF o asset via AccessoryIconView.
enum AccessoryIconCatalog {
    
    struct IconCategory: Identifiable, Hashable {
        let id: String
        let title: String
        let icons: [String]
    }
    
    // MARK: - Solo SF Symbols di sistema
    
    static let systemCategories: [IconCategory] = [
        IconCategory(id: "lighting", title: "Illuminazione", icons: [
            "lightbulb.fill",
            "lightbulb.2.fill",
            "lightbulb.led.fill",
            "lightbulb.led.wide.fill",
            "lamp.desk.fill",
            "lamp.floor.fill",
            "lamp.table.fill",
            "lamp.ceiling.fill",
            "lamp.ceiling.inverse",
            "light.recessed.fill",
            "light.recessed.3.fill",
            "light.strip.2.fill",
            "light.panel.fill",
            "light.cylindrical.ceiling.fill",
            "chandelier.fill",
            "spigot.fill",
            "fiberchannel"
        ]),
        IconCategory(id: "switches", title: "Switch & Prese", icons: [
            "lightswitch.on.fill",
            "lightswitch.off",
            "switch.2",
            "togglepower",
            "powerplug.fill",
            "powercord.fill",
            "poweroutlet.type.l.fill",
            "poweroutlet.type.f.fill",
            "poweroutlet.strip.fill",
            "button.programmable"
        ]),
        IconCategory(id: "climate", title: "Clima & Aria", icons: [
            "thermometer.medium",
            "thermometer.high",
            "thermometer.low",
            "thermometer.sun.fill",
            "thermometer.snowflake",
            "thermometer.variable.and.figure",
            "humidity.fill",
            "drop.degreesign.fill",
            "wind",
            "wind.snow",
            "fan.fill",
            "fan.ceiling.fill",
            "fan.floor.fill",
            "fan.oscillation.fill",
            "fan.desk.fill",
            "air.conditioner.horizontal.fill",
            "air.conditioner.vertical.fill",
            "air.purifier.fill",
            "humidifier.fill",
            "dehumidifier.fill",
            "heater.vertical.fill",
            "fireplace.fill",
            "flame.fill",
            "snowflake"
        ]),
        IconCategory(id: "covers", title: "Tende, Porte & Finestre", icons: [
            "blinds.horizontal.open",
            "blinds.horizontal.closed",
            "blinds.vertical.open",
            "blinds.vertical.closed",
            "window.horizontal",
            "window.horizontal.closed",
            "window.vertical.open",
            "window.vertical.closed",
            "window.casement",
            "window.awning",
            "curtains.closed",
            "curtains.open",
            "door.left.hand.closed",
            "door.left.hand.open",
            "door.french.closed",
            "door.sliding.left.hand.closed",
            "door.garage.closed",
            "door.garage.open"
        ]),
        IconCategory(id: "security", title: "Sicurezza", icons: [
            "shield.fill",
            "shield.checkered",
            "lock.fill",
            "lock.open.fill",
            "lock.shield.fill",
            "key.fill",
            "key.horizontal.fill",
            "video.fill",
            "video.doorbell.fill",
            "web.camera.fill",
            "bell.fill",
            "bell.badge.fill",
            "alarm.waves.left.and.right.fill",
            "exclamationmark.shield.fill"
        ]),
        IconCategory(id: "sensors", title: "Sensori", icons: [
            "sensor.fill",
            "sensor.tag.radiowaves.forward.fill",
            "drop.fill",
            "drop.degreesign",
            "leaf.fill",
            "flame.fill",
            "carbon.dioxide.cloud.fill",
            "carbon.monoxide.cloud.fill",
            "smoke.fill",
            "smoke.circle.fill",
            "figure.walk",
            "figure.run",
            "person.fill.viewfinder",
            "person.crop.circle.badge.questionmark.fill",
            "eye.fill",
            "sun.max.fill",
            "moon.fill",
            "thermometer.transmission",
            "humidity",
            "wave.3.right",
            "dot.radiowaves.up.forward",
            "antenna.radiowaves.left.and.right"
        ]),
        IconCategory(id: "kitchen", title: "Cucina & Bagno", icons: [
            "stove.fill",
            "oven.fill",
            "microwave.fill",
            "refrigerator.fill",
            "dishwasher.fill",
            "washer.fill",
            "dryer.fill",
            "sink.fill",
            "shower.fill",
            "toilet.fill",
            "spigot.fill",
            "drop.keypad.rectangle.fill",
            "kettle.fill",
            "frying.pan.fill",
            "wineglass.fill",
            "cup.and.saucer.fill"
        ]),
        IconCategory(id: "entertainment", title: "Intrattenimento", icons: [
            "tv.fill",
            "tv.inset.filled",
            "play.tv.fill",
            "appletv.fill",
            "homepod.fill",
            "homepodmini.fill",
            "hifispeaker.fill",
            "hifispeaker.2.fill",
            "speaker.wave.2.fill",
            "speaker.wave.3.fill",
            "airplayaudio",
            "airplayvideo",
            "headphones",
            "music.note",
            "music.quarternote.3",
            "gamecontroller.fill"
        ]),
        IconCategory(id: "network", title: "Rete & Smart", icons: [
            "wifi.router.fill",
            "wifi",
            "antenna.radiowaves.left.and.right",
            "network",
            "personalhotspot",
            "cpu.fill",
            "memorychip.fill",
            "bonjour",
            "homekit"
        ]),
        IconCategory(id: "outdoor", title: "Esterno", icons: [
            "leaf.fill",
            "tree.fill",
            "drop.fill",
            "drop.halffull",
            "umbrella.fill",
            "sun.max.fill",
            "cloud.sun.fill",
            "cloud.rain.fill",
            "thermometer.sun.fill",
            "thermometer.snowflake"
        ]),
        IconCategory(id: "other", title: "Altro", icons: [
            "questionmark.circle.fill",
            "circle.dotted",
            "arrow.triangle.2.circlepath.circle.fill",
            "gear",
            "wrench.adjustable.fill",
            "bolt.fill",
            "bolt.batteryblock.fill",
            "battery.100",
            "powerplug.portrait.fill",
            "ev.charger.fill",
            "ev.plug.ac.type.2.fill",
            "house.fill",
            "house.lodge.fill",
            "building.2.fill",
            "stairs"
        ])
    ]
    // MARK: - Asset Lucide custom (importati come asset catalog)
    
    /// I nomi qui sotto DEVONO corrispondere ai nomi degli asset nel catalog di Xcode.
    /// Convenzione: prefisso `lucide.` per non collidere con SF Symbols.
    static let customCategories: [IconCategory] = [
        IconCategory(id: "custom.lighting", title: "Illuminazione", icons: [
            "tabler.bulb",
            "tabler.bulb-filled",
            "tabler.bulb-off",
            "tabler.ceiling-light",
            "tabler.lamp",
            "tabler.lamp-2"
        ]),
        IconCategory(id: "custom.climate", title: "Clima & Riscaldamento", icons: [
            "tabler.air-conditioning",
            "tabler.air-conditioning-disabled",
            "tabler.heat-pump"
        ]),
        IconCategory(id: "custom.appliances", title: "Elettrodomestici", icons: [
            "lucide.vacuum",
            "lucide.washing-machine",
            "lucide.microwave",
            "lucide.refrigerator",
            "lucide.oven",
            "lucide.coffee",
            "lucide.toaster",
            "tabler.wash-machine",
            "tabler.bbq",
            "tabler.tools-kitchen-2",
            "tabler.bath"
        ]),
        IconCategory(id: "custom.security", title: "Sicurezza & Sensori", icons: [
            "tabler.device-cctv",
            "tabler.motion",
            "tabler.alarm-smoke",
            "tabler.wave-saw-tool"
        ]),
        IconCategory(id: "custom.outdoor", title: "Esterno & Giardino", icons: [
            "lucide.sprout",
            "lucide.trees",
            "lucide.umbrella",
            "tabler.plant-2",
            "tabler.garden-cart",
            "tabler.pool",
            "tabler.mower"
        ]),
        IconCategory(id: "custom.smart", title: "Robot & Tech", icons: [
            "lucide.bot",
            "lucide.cpu",
            "lucide.router",
            "tabler.vacuum-cleaner",
            "tabler.robot-face",
            "tabler.qrcode",
            "tabler.wifi-2"
        ]),
        IconCategory(id: "custom.mobility", title: "Mobilità & Auto", icons: [
            "tabler.charging-pile",
            "tabler.car-electric",
            "tabler.plug-connected"
        ]),
        IconCategory(id: "custom.entertainment", title: "Intrattenimento", icons: [
            "lucide.gamepad",
            "lucide.headphones",
            "lucide.radio",
            "lucide.disc"
        ])
    ]
}
