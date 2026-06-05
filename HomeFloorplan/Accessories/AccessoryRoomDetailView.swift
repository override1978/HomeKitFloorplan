import SwiftUI
import HomeKit
import SwiftData

// MARK: - AccessoryRoomDetailView
//
// Schermata di dettaglio per una stanza nel modulo Accessori.
// Sostituisce AccessoryRoomDetailPlaceholder (Sprint 3).
//
// Struttura verticale (scroll), organizzata per categoria funzionale:
//   1. Header card         — nome stanza, subtitle (count + health)
//   2. Sezione Luci        — LightsCard (se ci sono luci nella stanza)
//   3. Sezione Clima       — ClimateCard (termostati/AC)
//   4. Sezione Sensori     — SensorsCard (sensori read-only)
//   5. Sezione Sicurezza   — SecurityCard (antifurti + serrature)
//   6. Sezione Altro       — OtherCard (accessori non classificati)
//
// Navigazione:
//   Tap su riga accessorio  →  sheet  →  AccessoryDetailView (esistente)

struct AccessoryRoomDetailView: View {

    let room: RoomAccessoryData

    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides
    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(\.modelContext) private var modelContext

    @State private var selectedAccessory: HMAccessory?
    @State private var executingSceneID: UUID?
    @State private var recentlySucceededID: UUID?
    @State private var usageStore: SceneUsageStore?

    /// Scene che coinvolgono questa stanza.
    /// Ordine: suggerite contestualmente prima, poi per displayPriority.
    private var roomScenes: [SceneItem] {
        let filtered = scenesService.scenes.filter { $0.affiliatedRoomIDs.contains(room.id) }
        guard let store = usageStore else {
            return filtered.sorted { $0.displayPriority < $1.displayPriority }
        }
        let suggestedIDs = Set(store.suggestedScenes(from: filtered).map { $0.scene.id })
        return filtered.sorted { a, b in
            let aSuggested = suggestedIDs.contains(a.id)
            let bSuggested = suggestedIDs.contains(b.id)
            if aSuggested != bSuggested { return aSuggested }
            return a.displayPriority < b.displayPriority
        }
    }

    /// ID delle scene suggerite contestualmente (per badge nelle card).
    private var suggestedSceneIDs: Set<UUID> {
        guard let store = usageStore else { return [] }
        return Set(store.suggestedScenes(from: roomScenes).map { $0.scene.id })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // ── 1. Header stanza ───────────────────────────────────
                roomHeaderCard

                // ── 1b. Scene della stanza ────────────────────────────
                if !roomScenes.isEmpty {
                    RoomScenesStrip(
                        scenes: roomScenes,
                        suggestedIDs: suggestedSceneIDs,
                        roomID: room.id,
                        executingSceneID: $executingSceneID,
                        recentlySucceededID: $recentlySucceededID,
                        scenesService: scenesService
                    )
                }

                // ── 2. Luci ───────────────────────────────────────────
                let lights = accessories(in: .lights)
                if !lights.isEmpty {
                    DetailSectionCard(
                        title: String(localized: "accessories.section.lights", defaultValue: "Luci"),
                        symbol: "lightbulb.fill",
                        symbolColor: .yellow
                    ) {
                        ForEach(lights, id: \.uniqueIdentifier) { accessory in
                            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                            AccessoryDetailRow(
                                accessory: accessory,
                                adapter: adapter,
                                homeKit: homeKit,
                                iconOverrides: iconOverrides
                            ) {
                                selectedAccessory = accessory
                            }
                        }
                    }
                }

                // ── 3. Clima ──────────────────────────────────────────
                let climate = accessories(in: .climate)
                if !climate.isEmpty {
                    DetailSectionCard(
                        title: String(localized: "accessories.section.climate", defaultValue: "Clima"),
                        symbol: "thermometer.medium",
                        symbolColor: .cyan
                    ) {
                        ForEach(climate, id: \.uniqueIdentifier) { accessory in
                            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                            AccessoryDetailRow(
                                accessory: accessory,
                                adapter: adapter,
                                homeKit: homeKit,
                                iconOverrides: iconOverrides
                            ) {
                                selectedAccessory = accessory
                            }
                        }
                    }
                }

                // ── 4. Sensori ────────────────────────────────────────
                let sensors = accessories(in: .sensors)
                if !sensors.isEmpty {
                    DetailSectionCard(
                        title: String(localized: "accessories.section.sensors", defaultValue: "Sensori"),
                        symbol: "sensor.tag.radiowaves.forward",
                        symbolColor: .green
                    ) {
                        ForEach(sensors, id: \.uniqueIdentifier) { accessory in
                            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                            AccessoryDetailRow(
                                accessory: accessory,
                                adapter: adapter,
                                homeKit: homeKit,
                                iconOverrides: iconOverrides
                            ) {
                                selectedAccessory = accessory
                            }
                        }
                    }
                }

                // ── 5. Sicurezza ──────────────────────────────────────
                let security = accessories(in: .security)
                if !security.isEmpty {
                    DetailSectionCard(
                        title: String(localized: "accessories.section.security", defaultValue: "Sicurezza"),
                        symbol: "lock.shield.fill",
                        symbolColor: .red
                    ) {
                        ForEach(security, id: \.uniqueIdentifier) { accessory in
                            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                            AccessoryDetailRow(
                                accessory: accessory,
                                adapter: adapter,
                                homeKit: homeKit,
                                iconOverrides: iconOverrides
                            ) {
                                selectedAccessory = accessory
                            }
                        }
                    }
                }

                // ── 6. Altro ──────────────────────────────────────────
                let others = accessories(in: .others)
                if !others.isEmpty {
                    DetailSectionCard(
                        title: String(localized: "accessories.section.other", defaultValue: "Altro"),
                        symbol: "ellipsis.circle",
                        symbolColor: .secondary
                    ) {
                        ForEach(others, id: \.uniqueIdentifier) { accessory in
                            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                            AccessoryDetailRow(
                                accessory: accessory,
                                adapter: adapter,
                                homeKit: homeKit,
                                iconOverrides: iconOverrides
                            ) {
                                selectedAccessory = accessory
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .navigationTitle(room.roomName)
        .navigationBarTitleDisplayMode(.large)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onAppear {
            if usageStore == nil {
                let store = SceneUsageStore(modelContainer: modelContext.container)
                store.loadUsageData()
                usageStore = store
            }
        }
        .sheet(item: $selectedAccessory) { accessory in
            AccessoryDetailView(accessory: accessory)
        }
    }

    // MARK: - Room header card

    private var roomHeaderCard: some View {
        HStack(spacing: 16) {
            // Score ring
            ZStack {
                Circle()
                    .stroke(room.healthLevel.color.opacity(0.18), lineWidth: 5)
                    .frame(width: 52, height: 52)
                Circle()
                    .trim(from: 0, to: CGFloat(room.healthScore) / 100)
                    .stroke(room.healthLevel.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 52, height: 52)
                Text("\(room.healthScore)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(room.healthLevel.color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(room.roomName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                Text(room.subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let issue = room.primaryIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            // Health level badge
            Label(room.healthLevel.label, systemImage: room.healthLevel.sfSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(room.healthLevel.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(room.healthLevel.color.opacity(0.12), in: Capsule())
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Category filtering

    @MainActor
    private func accessories(in category: AccessoryCategory) -> [HMAccessory] {
        room.accessories(in: category, homeKit: homeKit)
    }
}

// MARK: - RoomScenesStrip

/// Strip orizzontale scorrevole con le scene che impattano questa stanza.
/// Ogni card mostra: icona scena, nome, cosa fa nella stanza, tasto play.
private struct RoomScenesStrip: View {

    let scenes: [SceneItem]
    let suggestedIDs: Set<UUID>
    let roomID: UUID
    @Binding var executingSceneID: UUID?
    @Binding var recentlySucceededID: UUID?
    let scenesService: HomeKitScenesService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header sezione
            HStack(spacing: 8) {
                Image(systemName: "wand.and.sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.purple)
                    .frame(width: 20)
                Text("Scene")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(scenes.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(scenes) { scene in
                        SceneRoomCard(
                            scene: scene,
                            isSuggested: suggestedIDs.contains(scene.id),
                            isExecuting: executingSceneID == scene.id,
                            didSucceed: recentlySucceededID == scene.id
                        ) {
                            runScene(scene)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func runScene(_ scene: SceneItem) {
        guard executingSceneID == nil else { return }
        executingSceneID = scene.id
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        Task {
            do {
                try await scenesService.run(scene)
                recentlySucceededID = scene.id
                let notify = UINotificationFeedbackGenerator()
                notify.notificationOccurred(.success)
                try? await Task.sleep(for: .seconds(1.5))
                recentlySucceededID = nil
            } catch {
                // Nessun feedback visivo di errore: non blocchiamo l'UI
            }
            executingSceneID = nil
        }
    }
}

// MARK: - SceneRoomCard

/// Singola card della strip: icona gradiente brand, nome, conteggio azioni, tasto play orange.
/// Le card suggerite mostrano un badge "★" in alto a sinistra sull'icona.
private struct SceneRoomCard: View {

    let scene: SceneItem
    let isSuggested: Bool
    let isExecuting: Bool
    let didSucceed: Bool
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── Riga superiore: icona + play ──────────────
            HStack(alignment: .top) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(didSucceed
                              ? LinearGradient(colors: [.green.opacity(0.8), .green], startPoint: .topLeading, endPoint: .bottomTrailing)
                              : BrandColor.heroGradient)
                        .frame(width: 44, height: 44)
                    if isExecuting {
                        ProgressView()
                            .scaleEffect(0.75)
                            .tint(.white)
                            .frame(width: 44, height: 44)
                    } else if didSucceed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: scene.symbolName)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    // Badge suggerita
                    if isSuggested && !isExecuting && !didSucceed {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.yellow)
                            .padding(3)
                            .background(Color.black.opacity(0.35), in: Circle())
                            .offset(x: -4, y: -4)
                    }
                }

                Spacer()

                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(isExecuting || didSucceed ? .secondary : Color.orange)
                }
                .buttonStyle(.plain)
                .disabled(isExecuting || didSucceed)
            }

            // ── Nome + conteggio azioni (occupa lo spazio rimanente) ──
            VStack(alignment: .leading, spacing: 3) {
                Text(scene.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Text(scene.actionCount == 1
                     ? String(localized: "count.action.singular", defaultValue: "1 azione")
                     : String(localized: "count.action.plural", defaultValue: "\(scene.actionCount) azioni"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .frame(width: 160, height: 130)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSuggested
                        ? Color.orange.opacity(0.5)
                        : Color(uiColor: .separator).opacity(0.45),
                        lineWidth: isSuggested ? 1.5 : 1)
        )
        .opacity(isExecuting ? 0.65 : 1.0)
        .animation(.spring(response: 0.3), value: isExecuting)
        .animation(.spring(response: 0.3), value: didSucceed)
    }
}

// MARK: - DetailSectionCard

/// Card container con titolo e lista di righe accessorio.
private struct DetailSectionCard<Content: View>: View {
    let title: String
    let symbol: String
    let symbolColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header sezione
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(symbolColor)
                    .frame(width: 20)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .padding(.horizontal, 16)

            content()
                .padding(.vertical, 4)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - AccessoryDetailRow

/// Riga singola per un accessorio nella detail view.
/// Mostra icona, nome, stato primario e — se non raggiungibile — un badge arancione.
/// Il tap apre AccessoryDetailView via sheet (delegato al parent).
private struct AccessoryDetailRow: View {

    let accessory: HMAccessory
    let adapter: any AccessoryAdapter
    let homeKit: HomeKitService
    let iconOverrides: IconOverrideStore
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {

                // Icona con sfondo colorato
                let iconName = iconOverrides.effectiveIcon(for: accessory, adapter: adapter)
                let appearance = AccessoryAppearance.from(adapter)
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(appearance.statusColor.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Image(systemName: iconName)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(appearance.statusColor)
                }

                // Nome + stato
                VStack(alignment: .leading, spacing: 2) {
                    Text(accessory.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let status = adapter.primaryStatusText {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !homeKit.isReachable(accessory) {
                        Text(String(localized: "accessories.row.offline", defaultValue: "Non raggiungibile"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                // Badge non raggiungibile
                if !homeKit.isReachable(accessory) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                // Freccia navigazione
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)

        Divider()
            .padding(.horizontal, 16)
    }
}

// MARK: - HMAccessory + Identifiable (già in HMAccessory+Identifiable.swift)
// Non serve riestendere qui.
