import SwiftUI
import HomeKit
import AVKit
#if canImport(Lottie)
import Lottie
#endif

private enum SmartLightingSceneValidator {
    static func warnings(for scene: SceneItem, targetRoomName: String) -> [String] {
        let targetKey = normalizedRoomName(targetRoomName)
        let roomNames = Set(scene.actionSet.actions.compactMap { action -> String? in
            guard let write = action.homeFloorplanCharacteristicWrite,
                  let roomName = write.characteristic.service?.accessory?.room?.name else {
                return nil
            }
            return roomName
        })
        var warnings: [String] = []
        let outsideRooms = roomNames
            .filter { normalizedRoomName($0) != targetKey }
            .sorted()
        if !outsideRooms.isEmpty {
            warnings.append(String(format: String(localized: "smartlighting.warning.sceneOutsideRooms",
                                                  defaultValue: "Scene also affects: %@"),
                                   outsideRooms.joined(separator: ", ")))
        }
        if containsOffWrites(scene) {
            warnings.append(String(localized: "smartlighting.warning.sceneContainsOff",
                                   defaultValue: "Scene contains off commands"))
        }
        if roomNames.count > 2 {
            warnings.append(String(format: String(localized: "smartlighting.warning.sceneManyRooms",
                                                  defaultValue: "Scene spans %d rooms"),
                                   roomNames.count))
        }
        return warnings
    }

    private static func containsOffWrites(_ scene: SceneItem) -> Bool {
        scene.actionSet.actions.contains { action in
            guard let write = action.homeFloorplanCharacteristicWrite else { return false }
            let type = write.characteristic.characteristicType
            guard type == HMCharacteristicTypePowerState || type == HMCharacteristicTypeActive else {
                return false
            }
            return boolValue(write.targetValue) == false || intValue(write.targetValue) == 0
        }
    }

    private static func normalizedRoomName(_ roomName: String) -> String {
        roomName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let i = raw as? Int { return i != 0 }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        return nil
    }
}

private struct SmartLightingSceneReviewItem: Identifiable {
    let id = UUID()
    let label: String
    let sceneName: String
    let isMissing: Bool
    let warnings: [String]
}

private struct SmartLightingPresenceSensorInfo: Identifiable {
    let id: UUID
    let accessoryName: String
    let kind: String
    let isActive: Bool
}

private enum SmartLightingExplainerStyle {
    case emptyState
    case compact
}

private struct SmartLightingExplainerView: View {
    let style: SmartLightingExplainerStyle

    private var isCompact: Bool {
        style == .compact
    }

    var body: some View {
        Group {
            if isCompact {
                VStack(alignment: .leading, spacing: 10) {
                    SmartLightingExplainerMediaView(width: 260, height: 152)
                        .frame(maxWidth: .infinity)
                    textStack
                }
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    SmartLightingExplainerMediaView(width: 300, height: 176)
                        .frame(maxWidth: .infinity)
                    textStack
                }
                .padding(.vertical, 10)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var textStack: some View {
        VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
            Text(String(localized: "smartlighting.explainer.title",
                        defaultValue: "Room-aware lighting"))
                .font(isCompact ? .subheadline.weight(.semibold) : .headline)
            Text(String(localized: "smartlighting.explainer.subtitle",
                        defaultValue: "Scenes follow the day phase, then daylight, weather and room sensors decide whether a change is actually needed."))
                .font(isCompact ? .caption : .subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SmartLightingExplainerMediaView: View {
    let width: CGFloat
    let height: CGFloat

    private let lottieName = "adaptive-lighting-v2.lottie"
    private let lottieExtension = "json"
    private let videoName = "smart_lighting_ios_card_loop"
    private let videoExtension = "mp4"

    var body: some View {
        Group {
            #if canImport(Lottie)
            if Bundle.main.url(forResource: lottieName, withExtension: lottieExtension) != nil {
                SmartLightingLottieView(animationName: lottieName)
                    .frame(width: width, height: height)
            } else if Bundle.main.url(forResource: videoName, withExtension: videoExtension) != nil {
                SmartLightingLoopingVideoView(resourceName: videoName, fileExtension: videoExtension)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                    )
            } else {
                SmartLightingExplainerArtwork(size: width)
            }
            #else
            if Bundle.main.url(forResource: videoName, withExtension: videoExtension) != nil {
                SmartLightingLoopingVideoView(resourceName: videoName, fileExtension: videoExtension)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                    )
            } else {
                SmartLightingExplainerArtwork(size: width)
            }
            #endif
        }
        .frame(width: width, height: height)
    }
}

#if canImport(Lottie)
private struct SmartLightingLottieView: View {
    let animationName: String

    var body: some View {
        LottieView(animation: .named(animationName))
            .playing(loopMode: .loop)
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}
#endif

private struct SmartLightingLoopingVideoView: UIViewRepresentable {
    let resourceName: String
    let fileExtension: String

    func makeCoordinator() -> Coordinator {
        Coordinator(resourceName: resourceName, fileExtension: fileExtension)
    }

    func makeUIView(context: Context) -> LoopingVideoContainerView {
        let view = LoopingVideoContainerView()
        view.backgroundColor = .clear
        view.playerLayer?.videoGravity = .resizeAspectFill
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: LoopingVideoContainerView, context: Context) {
        context.coordinator.attach(to: uiView)
        context.coordinator.play()
    }

    final class Coordinator {
        private let resourceName: String
        private let fileExtension: String
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?

        init(resourceName: String, fileExtension: String) {
            self.resourceName = resourceName
            self.fileExtension = fileExtension
        }

        func attach(to view: LoopingVideoContainerView) {
            if player == nil {
                configurePlayer()
            }
            view.playerLayer?.player = player
            play()
        }

        func play() {
            player?.play()
        }

        private func configurePlayer() {
            guard let url = Bundle.main.url(forResource: resourceName, withExtension: fileExtension) else {
                return
            }
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.actionAtItemEnd = .none
            queue.preventsDisplaySleepDuringVideoPlayback = false
            player = queue
            looper = AVPlayerLooper(player: queue, templateItem: item)
        }
    }
}

private final class LoopingVideoContainerView: UIView {
    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer? {
        layer as? AVPlayerLayer
    }
}

private struct SmartLightingExplainerArtwork: View {
    let size: CGFloat
    @State private var isAnimating = false
    @State private var step = 0

    private var compactScale: CGFloat {
        size < 120 ? 0.82 : 1.0
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(.systemBlue).opacity(0.14),
                            Color(.systemYellow).opacity(0.18),
                            Color(.systemGreen).opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )

            Circle()
                .fill(Color.yellow.opacity(isAnimating ? 0.34 : 0.18))
                .frame(width: size * 0.62, height: size * 0.62)
                .blur(radius: size * 0.08)
                .offset(x: size * 0.08, y: size * 0.1)

            VStack(spacing: size * 0.08) {
                HStack(spacing: size * 0.055) {
                    explainerSignal(
                        icon: "sun.max.fill",
                        label: String(localized: "smartlighting.explainer.phase", defaultValue: "Phase"),
                        color: .orange,
                        isActive: step == 0
                    )
                    explainerArrow(isActive: step == 0)
                    explainerSignal(
                        icon: "cloud.sun.fill",
                        label: String(localized: "smartlighting.explainer.light", defaultValue: "Light"),
                        color: .yellow,
                        isActive: step == 1
                    )
                    explainerArrow(isActive: step == 1)
                    explainerSignal(
                        icon: "figure.walk.motion",
                        label: String(localized: "smartlighting.explainer.presence", defaultValue: "Presence"),
                        color: .green,
                        isActive: step == 2
                    )
                }

                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1.5)
                        .frame(height: size * 0.38)

                    HStack(alignment: .bottom, spacing: size * 0.13) {
                        VStack(spacing: size * 0.025) {
                            Image(systemName: "sensor.fill")
                                .font(.system(size: size * 0.14, weight: .semibold))
                                .foregroundStyle(step == 2 ? Color.green : Color.secondary)
                            Circle()
                                .fill(step == 2 ? Color.green.opacity(0.7) : Color.secondary.opacity(0.3))
                                .frame(width: size * 0.025, height: size * 0.025)
                        }
                        VStack(spacing: size * 0.035) {
                            Image(systemName: "lamp.floor.fill")
                                .font(.system(size: size * 0.2, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.78))
                            Capsule()
                                .fill(Color.primary.opacity(0.16))
                                .frame(width: size * 0.22, height: 3)
                        }
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: size * 0.16, weight: .semibold))
                            .foregroundStyle(step == 1 || step == 2 ? Color.yellow : Color.secondary)
                            .shadow(color: .yellow.opacity(step == 1 || step == 2 ? 0.55 : 0), radius: 8)
                            .scaleEffect(step == 1 ? 1.16 : 1)
                    }
                    .padding(.bottom, size * 0.06)
                }
            }
            .padding(size * 0.12)
        }
        .frame(width: size, height: size * 0.72)
        .overlay(alignment: .bottomTrailing) {
            Text(decisionLabel)
                .font(.system(size: max(9, 11 * compactScale), weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, max(7, size * 0.055))
                .padding(.vertical, max(4, size * 0.032))
                .background(.thinMaterial, in: Capsule())
                .padding(max(6, size * 0.045))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.65).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1150))
                withAnimation(.easeInOut(duration: 0.45)) {
                    step = (step + 1) % 3
                }
            }
        }
    }

    private var decisionLabel: String {
        switch step {
        case 0:
            return String(localized: "smartlighting.explainer.decision.phase", defaultValue: "Day phase")
        case 1:
            return String(localized: "smartlighting.explainer.decision.light", defaultValue: "Need light?")
        default:
            return String(localized: "smartlighting.explainer.decision.scene", defaultValue: "Apply scene")
        }
    }

    private func explainerSignal(icon: String, label: String, color: Color, isActive: Bool) -> some View {
        VStack(spacing: max(2, size * 0.015)) {
            Image(systemName: icon)
                .font(.system(size: size * 0.115, weight: .semibold))
                .foregroundStyle(isActive ? color : Color.secondary)
                .scaleEffect(isActive ? 1.14 : 0.94)
            if size >= 120 {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isActive ? color : Color.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(isActive ? 1 : 0.55)
    }

    private func explainerArrow(isActive: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: size * 0.075, weight: .bold))
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.45))
            .offset(x: isActive && isAnimating ? 3 : 0)
    }
}

// MARK: - SmartLightingSettingsView

struct SmartLightingSettingsView: View {

    @Environment(SmartLightingEngine.self)   private var engine
    @Environment(HomeKitService.self)        private var homeKit
    @Environment(HomeKitScenesService.self)  private var scenesService
    @Environment(WeatherKitService.self)     private var weatherKit

    @State private var showAddRoom = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        @Bindable var eng = engine
        Form {
            // MARK: Globale
            Section {
                Toggle(String(localized: "smartlighting.global.toggle",
                              defaultValue: "Smart Lighting enabled"),
                       isOn: $eng.isGloballyEnabled)

                if engine.isGloballyEnabled {
                    sunStatusRow
                }
            } header: {
                Text(String(localized: "smartlighting.section.general",
                            defaultValue: "General"))
            } footer: {
                Text(String(localized: "smartlighting.section.general.footer",
                            defaultValue: "HomeFloorplan can apply lighting scenes when the app evaluates your home context. iOS may limit background checks."))
            }

            // MARK: Ultima valutazione
            if engine.isGloballyEnabled && !engine.lastEvaluationLog.isEmpty {
                Section {
                    Text(engine.lastEvaluationLog)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(String(localized: "smartlighting.section.lastEval",
                                defaultValue: "Last Evaluation"))
                }
            }

            if engine.isGloballyEnabled && !engine.recentDecisions.isEmpty {
                Section {
                    ForEach(Array(engine.recentDecisions.prefix(8))) { decision in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(decision.roomName)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(Self.timeFmt.string(from: decision.evaluatedAt))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(decisionLine(decision))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(String(localized: "smartlighting.section.decisions",
                                defaultValue: "Decision History"))
                }
            }

            // MARK: Stanze configurate
            Section {
                if engine.profiles.isEmpty {
                    SmartLightingExplainerView(style: .emptyState)
                } else {
                    ForEach(engine.profiles) { profile in
                        NavigationLink {
                            LightingProfileEditView(profileID: profile.id, initial: profile)
                        } label: {
                            profileRow(profile)
                        }
                    }
                    .onDelete { indexSet in
                        indexSet.forEach { engine.removeProfile(id: engine.profiles[$0].id) }
                    }
                }

                Button {
                    showAddRoom = true
                } label: {
                    Label(String(localized: "smartlighting.rooms.add",
                                 defaultValue: "Add Room"),
                          systemImage: "plus")
                }
            } header: {
                Text(String(localized: "smartlighting.section.rooms",
                            defaultValue: "Configured Rooms"))
            } footer: {
                Text(String(localized: "smartlighting.section.rooms.footer",
                            defaultValue: "Swipe left to remove a room profile. Disabled profiles are skipped by the engine."))
            }
        }
        .navigationTitle(String(localized: "smartlighting.title",
                                defaultValue: "Smart Lighting"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear { scenesService.refresh() }
        .sheet(isPresented: $showAddRoom) {
            AddLightingRoomSheet()
        }
    }

    // MARK: - Sunrise/Sunset row

    @ViewBuilder
    private var sunStatusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.and.horizon.fill")
                .foregroundStyle(.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                if let sr = weatherKit.todaySunrise, let ss = weatherKit.todaySunset {
                    Text(String(format: String(localized: "smartlighting.sunStatus",
                                               defaultValue: "Sunrise %@ · Sunset %@"),
                                Self.timeFmt.string(from: sr),
                                Self.timeFmt.string(from: ss)))
                        .font(.subheadline)
                    if let at = engine.lastEvaluationAt {
                        Text(String(format: String(localized: "smartlighting.lastEvalAt",
                                                   defaultValue: "Last check: %@"),
                                    Self.timeFmt.string(from: at)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(String(localized: "smartlighting.noSunData",
                                defaultValue: "Sunrise/sunset not available — configure home location in Settings."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Profile list row

    private func profileRow(_ profile: LightingProfile) -> some View {
        let configuredCount = LightingPhase.allCases
            .compactMap { profile.sceneName(for: $0) }
            .count
        let missingCount = missingScenes(for: profile).count
        let warningCount = sceneWarningCount(for: profile)

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.roomName)
                Group {
                    if missingCount > 0 {
                        Text(String(format: String(localized: "smartlighting.row.missingScenes",
                                                   defaultValue: "%d missing scene(s)"),
                                    missingCount))
                    } else if warningCount > 0 {
                        Text(String(format: String(localized: "smartlighting.row.sceneWarnings",
                                                   defaultValue: "%d scene warning(s)"),
                                    warningCount))
                    } else if configuredCount == 0 {
                        Text(String(localized: "smartlighting.row.noScenes",
                                    defaultValue: "No scenes assigned"))
                    } else {
                        Text(String(format: String(localized: "smartlighting.row.scenesCount",
                                                   defaultValue: "%d phases configured"),
                                    configuredCount))
                    }
                }
                .font(.caption)
                .foregroundStyle(missingCount > 0 || warningCount > 0 ? .orange : .secondary)
            }
            Spacer()
            if missingCount > 0 || warningCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
            } else if profile.isEnabled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            } else {
                Text(String(localized: "smartlighting.row.disabled",
                            defaultValue: "Off"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func missingScenes(for profile: LightingProfile) -> [String] {
        let available = Set(scenesService.scenes.map { $0.name.lowercased() })
        return LightingPhase.allCases
            .compactMap { profile.sceneName(for: $0) }
            .filter { !available.contains($0.lowercased()) }
    }

    private func sceneWarningCount(for profile: LightingProfile) -> Int {
        let sceneNames = LightingPhase.allCases
            .compactMap { profile.sceneName(for: $0) } + [profile.luxOffSceneName].compactMap { $0 }
        return sceneNames.reduce(0) { count, sceneName in
            guard let scene = scenesService.scenes.first(where: { $0.name.lowercased() == sceneName.lowercased() }) else {
                return count
            }
            return count + SmartLightingSceneValidator.warnings(for: scene, targetRoomName: profile.roomName).count
        }
    }

    private func decisionLine(_ decision: SmartLightingDecisionRecord) -> String {
        var parts = [decision.action.rawValue]
        if let sceneName = decision.sceneName {
            parts.append(sceneName)
        }
        parts.append(decision.reason)
        if let lux = decision.luxValue {
            parts.append("\(Int(lux)) lx")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - AddLightingRoomSheet

private struct AddLightingRoomSheet: View {

    @Environment(SmartLightingEngine.self) private var engine
    @Environment(HomeKitService.self)      private var homeKit
    @Environment(\.dismiss)               private var dismiss

    private var unconfiguredRooms: [String] {
        let configured = Set(engine.profiles.map { $0.roomName.lowercased() })
        return (homeKit.currentHome?.rooms.map(\.name) ?? [])
            .filter { !configured.contains($0.lowercased()) }
            .sorted()
    }

    var body: some View {
        NavigationStack {
            Group {
                if unconfiguredRooms.isEmpty {
                    ContentUnavailableView(
                        String(localized: "smartlighting.addroom.empty.title",
                               defaultValue: "All Rooms Added"),
                        systemImage: "checkmark.circle",
                        description: Text(String(localized: "smartlighting.addroom.empty.desc",
                                                 defaultValue: "Every HomeKit room already has a Smart Lighting profile."))
                    )
                } else {
                    List(unconfiguredRooms, id: \.self) { name in
                        Button {
                            engine.addOrUpdateProfile(LightingProfile(roomName: name))
                            dismiss()
                        } label: {
                            Label(name, systemImage: "lightbulb")
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "smartlighting.addroom.title",
                                    defaultValue: "Select Room"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - LightingProfileEditView

struct LightingProfileEditView: View {

    @Environment(SmartLightingEngine.self)  private var engine
    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(WeatherKitService.self)    private var weatherKit
    @Environment(HomeKitService.self)        private var homeKit

    let profileID: UUID
    @State private var draft: LightingProfile

    init(profileID: UUID, initial: LightingProfile) {
        self.profileID = profileID
        self._draft    = State(initialValue: initial)
    }

    private var scheduleFooter: String {
        if let sh = draft.sleepHour, let wh = draft.wakeHour {
            return String(format: String(localized: "smartlighting.edit.schedule.footer.window",
                                         defaultValue: "Engine silent from %1$@ to %2$@ — no scene will be activated in that window."),
                          formattedTime(minutes: minutesSinceMidnight(hour: sh, minute: draft.sleepMinute ?? 0)),
                          formattedTime(minutes: minutesSinceMidnight(hour: wh, minute: draft.wakeMinute ?? 0)))
        } else if draft.sleepHour != nil || draft.wakeHour != nil {
            let sh = draft.sleepHour ?? 1
            let wh = draft.wakeHour  ?? 7
            return String(format: String(localized: "smartlighting.edit.schedule.footer.window",
                                         defaultValue: "Engine silent from %1$@ to %2$@ — no scene will be activated in that window."),
                          formattedTime(minutes: minutesSinceMidnight(hour: sh, minute: draft.sleepMinute ?? 0)),
                          formattedTime(minutes: minutesSinceMidnight(hour: wh, minute: draft.wakeMinute ?? 0)))
        } else {
            return String(localized: "smartlighting.edit.schedule.footer",
                          defaultValue: "Set when Evening becomes Night. The silence window prevents automatic scene activation while you want manual control.")
        }
    }

    private var customSceneNames: [String] {
        scenesService.scenes
            .filter { !$0.isBuiltIn }
            .map(\.name)
            .sorted()
    }

    private var configuredSceneNames: [(phase: LightingPhase, name: String)] {
        LightingPhase.allCases.compactMap { phase in
            guard let name = draft.sceneName(for: phase), !name.isEmpty else { return nil }
            return (phase, name)
        }
    }

    private var missingSceneNames: [String] {
        let available = Set(customSceneNames.map { $0.lowercased() })
        return configuredSceneNames
            .map(\.name)
            .filter { !available.contains($0.lowercased()) }
    }

    private var sceneReviewItems: [SmartLightingSceneReviewItem] {
        var items: [SmartLightingSceneReviewItem] = []
        for item in configuredSceneNames {
            items.append(reviewItem(label: item.phase.displayName, sceneName: item.name))
        }
        if let luxOffSceneName = draft.luxOffSceneName, !luxOffSceneName.isEmpty {
            items.append(reviewItem(
                label: String(localized: "smartlighting.review.naturalLightReturn",
                              defaultValue: "Natural light return"),
                sceneName: luxOffSceneName
            ))
        }
        return items.filter { !$0.warnings.isEmpty || $0.isMissing }
    }

    private var luxActivationThreshold: Int {
        max(80, Int((draft.luxBypassThreshold * 0.8).rounded()))
    }

    private var luxDeactivationThreshold: Int {
        max(120, Int((draft.luxBypassThreshold * 1.2).rounded()))
    }

    private var presenceSensors: [SmartLightingPresenceSensorInfo] {
        guard let home = homeKit.currentHome else { return [] }
        let roomKey = normalizedRoomName(draft.roomName)
        let targetRooms = home.rooms.filter {
            normalizedRoomName($0.name) == roomKey || normalizedRoomName($0.name).contains(roomKey)
        }
        return targetRooms
            .flatMap(\.accessories)
            .flatMap(presenceSensors(in:))
            .sorted {
                if $0.isActive != $1.isActive {
                    return $0.isActive && !$1.isActive
                }
                return $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
            }
    }

    private var sleepTimeOptions: [Int] {
        stride(from: 0, through: 6 * 60 + 30, by: 30).map { $0 }
    }

    private var wakeTimeOptions: [Int] {
        stride(from: 5 * 60, through: 10 * 60, by: 30).map { $0 }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private func applyOverride(hours: Double) {
        draft.manualOverrideUntil = Date().addingTimeInterval(hours * 3_600)
        engine.addOrUpdateProfile(draft)
    }

    private func applyOverrideUntilMorning() {
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = 7; comps.minute = 0; comps.second = 0
        var morning = cal.date(from: comps) ?? now.addingTimeInterval(6 * 3_600)
        if morning <= now {
            morning = cal.date(byAdding: .day, value: 1, to: morning) ?? morning
        }
        draft.manualOverrideUntil = morning
        engine.addOrUpdateProfile(draft)
    }

    private func minutesSinceMidnight(hour: Int?, minute: Int?) -> Int {
        (hour ?? 0) * 60 + (minute ?? 0)
    }

    private func setSleepTime(minutes: Int) {
        draft.sleepHour = minutes / 60
        draft.sleepMinute = minutes % 60
    }

    private func setWakeTime(minutes: Int) {
        draft.wakeHour = minutes / 60
        draft.wakeMinute = minutes % 60
    }

    private func formattedTime(minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private func reviewItem(label: String, sceneName: String) -> SmartLightingSceneReviewItem {
        let scene = scenesService.scenes.first { $0.name.lowercased() == sceneName.lowercased() }
        return SmartLightingSceneReviewItem(
            label: label,
            sceneName: sceneName,
            isMissing: scene == nil,
            warnings: scene.map {
                SmartLightingSceneValidator.warnings(for: $0, targetRoomName: draft.roomName)
            } ?? []
        )
    }

    private func presenceSensors(in accessory: HMAccessory) -> [SmartLightingPresenceSensorInfo] {
        accessory.services.flatMap { service in
            service.characteristics.compactMap { characteristic in
                let kind: String
                if characteristic.characteristicType == HMCharacteristicTypeMotionDetected {
                    kind = String(localized: "smartlighting.presence.motion", defaultValue: "Motion sensor")
                } else if characteristic.characteristicType == HMCharacteristicTypeOccupancyDetected {
                    kind = String(localized: "smartlighting.presence.occupancy", defaultValue: "Occupancy sensor")
                } else {
                    return nil
                }
                let rawValue = homeKit.value(for: characteristic) ?? characteristic.value
                return SmartLightingPresenceSensorInfo(
                    id: characteristic.uniqueIdentifier,
                    accessoryName: accessory.name,
                    kind: kind,
                    isActive: boolValue(rawValue) == true || intValue(rawValue) == 1
                )
            }
        }
    }

    private func normalizedRoomName(_ roomName: String) -> String {
        roomName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func boolValue(_ raw: Any?) -> Bool? {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let i = raw as? Int { return i != 0 }
        return nil
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        return nil
    }

    var body: some View {
        Form {
            Section {
                SmartLightingExplainerView(style: .compact)
            }

            // MARK: Generale
            Section {
                Toggle(String(localized: "smartlighting.edit.enabled",
                              defaultValue: "Enabled"),
                       isOn: $draft.isEnabled)
                Label(
                    draft.isEnabled
                    ? String(localized: "smartlighting.edit.general.enabledStatus",
                             defaultValue: "Automatic lighting is active for this room.")
                    : String(localized: "smartlighting.edit.general.disabledStatus",
                             defaultValue: "This room is skipped by Smart Lighting."),
                    systemImage: draft.isEnabled ? "checkmark.circle.fill" : "pause.circle"
                )
                .font(.caption)
                .foregroundStyle(draft.isEnabled ? Color.green : Color.secondary)
            } header: {
                Text(String(localized: "smartlighting.edit.general.header",
                            defaultValue: "General"))
            } footer: {
                Text(String(localized: "smartlighting.edit.general.footer",
                            defaultValue: "Enable or disable Smart Lighting for this room without changing its configuration."))
            }

            // MARK: Schedule
            Section {
                Picker(String(localized: "smartlighting.edit.nightHour",
                              defaultValue: "Night starts at"),
                       selection: $draft.nightHour) {
                    ForEach([18, 19, 20, 21, 22, 23], id: \.self) { h in
                        Text("\(h):00").tag(h)
                    }
                }
                .pickerStyle(.menu)

                Toggle(String(localized: "smartlighting.edit.silenceWindow.toggle",
                              defaultValue: "Silence Window"),
                       isOn: Binding(
                           get: { draft.sleepHour != nil || draft.wakeHour != nil },
                           set: {
                               if $0 {
                                   draft.sleepHour = draft.sleepHour ?? 1
                                   draft.sleepMinute = draft.sleepMinute ?? 0
                                   draft.wakeHour  = draft.wakeHour  ?? 7
                                   draft.wakeMinute = draft.wakeMinute ?? 0
                               } else {
                                   draft.sleepHour = nil
                                   draft.sleepMinute = nil
                                   draft.wakeHour  = nil
                                   draft.wakeMinute = nil
                               }
                           }
                       ))

                if draft.sleepHour != nil || draft.wakeHour != nil {
                    Picker(String(localized: "smartlighting.edit.silenceWindow.from",
                                  defaultValue: "Silent from"),
                           selection: Binding(
                               get: { minutesSinceMidnight(hour: draft.sleepHour ?? 1, minute: draft.sleepMinute ?? 0) },
                               set: { setSleepTime(minutes: $0) }
                           )) {
                        ForEach(sleepTimeOptions, id: \.self) { minutes in
                            Text(formattedTime(minutes: minutes)).tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker(String(localized: "smartlighting.edit.silenceWindow.to",
                                  defaultValue: "Resume at"),
                           selection: Binding(
                               get: { minutesSinceMidnight(hour: draft.wakeHour ?? 7, minute: draft.wakeMinute ?? 0) },
                               set: { setWakeTime(minutes: $0) }
                           )) {
                        ForEach(wakeTimeOptions, id: \.self) { minutes in
                            Text(formattedTime(minutes: minutes)).tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text(String(localized: "smartlighting.edit.schedule.header",
                            defaultValue: "Schedule"))
            } footer: {
                Text(scheduleFooter)
            }

            // MARK: Scene per fase
            Section {
                ForEach(LightingPhase.allCases, id: \.self) { phase in
                    scenePicker(for: phase)
                }
            } header: {
                Text(String(localized: "smartlighting.edit.scenes.header",
                            defaultValue: "Scenes per Phase"))
            } footer: {
                Text(String(localized: "smartlighting.edit.scenes.footer",
                            defaultValue: "\"None\" skips that phase — the engine makes no change. Only custom HomeKit scenes are listed. Times are based on today's sunrise/sunset."))
            }

            // MARK: Today timeline
            Section {
                if customSceneNames.isEmpty {
                    Label(
                        String(localized: "smartlighting.timeline.noScenes",
                               defaultValue: "No custom HomeKit scenes available yet."),
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(LightingPhase.allCases, id: \.self) { phase in
                        timelineRow(for: phase)
                    }
                    if !missingSceneNames.isEmpty {
                        Text(String(localized: "smartlighting.timeline.missing.footer",
                                    defaultValue: "Missing scenes are skipped until they are restored or replaced."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text(String(localized: "smartlighting.timeline.header",
                            defaultValue: "Today's Timeline"))
            } footer: {
                Text(String(localized: "smartlighting.timeline.footer",
                            defaultValue: "Shows today's phase windows and the scene Smart Lighting will apply in each one."))
            }

            if !sceneReviewItems.isEmpty {
                Section {
                    ForEach(sceneReviewItems) { item in
                        sceneReviewRow(item)
                    }
                } header: {
                    Text(String(localized: "smartlighting.review.header",
                                defaultValue: "Scene Review"))
                } footer: {
                    Text(String(localized: "smartlighting.review.footer",
                                defaultValue: "Warnings are informational. Scenes can still be used for open areas or grouped zones."))
                }
            }

            // MARK: Lux bypass
            Section {
                Toggle(String(localized: "smartlighting.edit.luxBypass",
                              defaultValue: "Natural Light Bypass"),
                       isOn: Binding(
                           get: { draft.luxBypassThreshold > 0 },
                           set: { draft.luxBypassThreshold = $0 ? 150.0 : 0.0 }
                       ))

                if draft.luxBypassThreshold > 0 {
                    Stepper(value: $draft.luxBypassThreshold, in: 50...2000, step: 50) {
                        HStack {
                            Text(String(localized: "smartlighting.edit.luxThreshold",
                                        defaultValue: "Threshold"))
                            Spacer()
                            Text("\(Int(draft.luxBypassThreshold)) lx")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Label(
                        String(format: String(localized: "smartlighting.edit.luxHysteresis",
                                              defaultValue: "Acts below %1$d lx · pauses above %2$d lx"),
                               luxActivationThreshold,
                               luxDeactivationThreshold),
                        systemImage: "arrow.left.and.right"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Picker(selection: Binding(
                        get: { draft.luxOffSceneName ?? "" },
                        set: { draft.luxOffSceneName = $0.isEmpty ? nil : $0 }
                    )) {
                        Text(String(localized: "smartlighting.edit.luxOffScene.none",
                                    defaultValue: "None (keep lights on)")).tag("")
                        ForEach(customSceneNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    } label: {
                        Label(String(localized: "smartlighting.edit.luxOffScene",
                                     defaultValue: "Scene when light returns"),
                              systemImage: "sun.max")
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text(String(localized: "smartlighting.edit.lux.header",
                            defaultValue: "Natural Light"))
            } footer: {
                Text(String(localized: "smartlighting.edit.lux.footer",
                            defaultValue: "Smart Lighting uses a stability band around the lux threshold, so small sensor changes do not cause repeated on/off changes."))
            }

            // MARK: Presence guard
            Section {
                if presenceSensors.isEmpty {
                    Label(String(localized: "smartlighting.presence.none",
                                 defaultValue: "No motion or occupancy sensors found in this room"),
                          systemImage: "sensor")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(presenceSensors) { sensor in
                        HStack(spacing: 12) {
                            Image(systemName: sensor.isActive ? "person.fill.checkmark" : "person")
                                .foregroundStyle(sensor.isActive ? Color.green : Color.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sensor.accessoryName)
                                Text(sensor.kind)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(sensor.isActive
                                 ? String(localized: "smartlighting.presence.active", defaultValue: "Active")
                                 : String(localized: "smartlighting.presence.idle", defaultValue: "Idle"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(sensor.isActive ? Color.green : Color.secondary)
                        }
                    }
                }
            } header: {
                Text(String(localized: "smartlighting.presence.header",
                            defaultValue: "Presence Guard"))
            } footer: {
                Text(presenceSensors.isEmpty
                     ? String(localized: "smartlighting.presence.footer.none",
                              defaultValue: "Smart Lighting still works without presence sensors. Auto-off remains conservative.")
                     : String(localized: "smartlighting.presence.footer.active",
                              defaultValue: "These sensors are used only to prevent automatic turn-off while activity is detected."))
            }

            // MARK: Override manuale
            Section {
                if let until = draft.manualOverrideUntil, until > Date() {
                    HStack {
                        Label(String(localized: "smartlighting.edit.override.until",
                                     defaultValue: "Active until"),
                              systemImage: "pause.circle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Text(Self.timeFmt.string(from: until))
                            .foregroundStyle(.secondary)
                    }
                    Button(String(localized: "smartlighting.edit.override.clear",
                                  defaultValue: "Resume engine"),
                           role: .destructive) {
                        draft.manualOverrideUntil = nil
                        engine.addOrUpdateProfile(draft)
                    }
                } else {
                    Menu {
                        Button(String(localized: "smartlighting.edit.override.30m",
                                      defaultValue: "30 minutes")) { applyOverride(hours: 0.5) }
                        Button(String(localized: "smartlighting.edit.override.1h",
                                      defaultValue: "1 hour")) { applyOverride(hours: 1) }
                        Button(String(localized: "smartlighting.edit.override.2h",
                                      defaultValue: "2 hours")) { applyOverride(hours: 2) }
                        Button(String(localized: "smartlighting.edit.override.4h",
                                      defaultValue: "4 hours")) { applyOverride(hours: 4) }
                        Button(String(localized: "smartlighting.edit.override.untilMorning",
                                      defaultValue: "Until morning (07:00)")) { applyOverrideUntilMorning() }
                    } label: {
                        Label(String(localized: "smartlighting.edit.override.pause",
                                     defaultValue: "Pause engine…"),
                              systemImage: "pause.circle")
                    }
                }
            } header: {
                Text(String(localized: "smartlighting.edit.override.header",
                            defaultValue: "Manual Override"))
            } footer: {
                if let until = draft.manualOverrideUntil, until > Date() {
                    Text(String(localized: "smartlighting.edit.override.footer.active",
                                defaultValue: "The engine is paused — no scenes will be activated until the override expires."))
                } else {
                    Text(String(localized: "smartlighting.edit.override.footer",
                                defaultValue: "Temporarily suspends automatic lighting for this room. Useful when you want full manual control without disabling the profile."))
                }
            }
        }
        .navigationTitle(draft.roomName)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            engine.addOrUpdateProfile(draft)
        }
    }

    @ViewBuilder
    private func timelineRow(for phase: LightingPhase) -> some View {
        let sceneName = draft.sceneName(for: phase)
        let hasScene = sceneName?.isEmpty == false
        let isMissing = sceneName.map { missingSceneNames.contains($0) } ?? false

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isMissing ? "exclamationmark.triangle.fill" : (hasScene ? "checkmark.circle.fill" : "minus.circle"))
                .foregroundStyle(isMissing ? Color.orange : (hasScene ? Color.green : Color.secondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(phase.displayName)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let range = phaseTimeRange(for: phase) {
                        Text(range)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(sceneName ?? String(localized: "smartlighting.timeline.noSceneForPhase",
                                         defaultValue: "No scene"))
                    .font(.caption)
                    .foregroundStyle(hasScene ? .secondary : .tertiary)
            }
        }
    }

    @ViewBuilder
    private func sceneReviewRow(_ item: SmartLightingSceneReviewItem) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if item.isMissing {
                    Label(String(localized: "smartlighting.review.missing",
                                 defaultValue: "Scene not found in HomeKit"),
                          systemImage: "xmark.circle.fill")
                }
                ForEach(item.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.top, 6)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.isMissing ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label)
                        .font(.subheadline.weight(.medium))
                    Text(item.sceneName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.isMissing
                     ? String(localized: "smartlighting.review.badge.missing", defaultValue: "Missing")
                     : String(format: String(localized: "smartlighting.review.badge.warningCount",
                                             defaultValue: "%d warning(s)"),
                              item.warnings.count))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
        }
    }

    // MARK: - Phase time range (computed from today's sunrise/sunset)

    private func phaseTimeRange(for phase: LightingPhase) -> String? {
        guard let sunrise = weatherKit.todaySunrise,
              let sunset  = weatherKit.todaySunset else { return nil }
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        func s(_ d: Date) -> String { fmt.string(from: d) }
        func h(_ hour: Int) -> String { String(format: "%02d:00", hour) }
        switch phase {
        case .dawn:      return "\(s(sunrise.addingTimeInterval(-3600))) – \(s(sunrise.addingTimeInterval(5400)))"
        case .morning:   return "\(s(sunrise.addingTimeInterval(5400))) – \(s(sunset.addingTimeInterval(-7200)))"
        case .preSunset: return "\(s(sunset.addingTimeInterval(-7200))) – \(s(sunset.addingTimeInterval(-1800)))"
        case .sunset:    return "\(s(sunset.addingTimeInterval(-1800))) – \(s(sunset.addingTimeInterval(2700)))"
        case .evening:   return "\(s(sunset.addingTimeInterval(2700))) – \(h(draft.nightHour))"
        case .night:     return "\(h(draft.nightHour)) – \(s(sunrise.addingTimeInterval(-3600)))"
        }
    }

    // MARK: - Scene picker for a single phase

    @ViewBuilder
    private func scenePicker(for phase: LightingPhase) -> some View {
        let selectedSceneName = draft.sceneName(for: phase)
        let binding = Binding<String>(
            get: { selectedSceneName ?? "" },
            set: { val in
                let v = val.isEmpty ? nil : val
                switch phase {
                case .dawn:      draft.sceneDawn      = v
                case .morning:   draft.sceneMorning   = v
                case .preSunset: draft.scenePreSunset = v
                case .sunset:    draft.sceneSunset    = v
                case .evening:   draft.sceneEvening   = v
                case .night:     draft.sceneNight     = v
                }
            }
        )
        Picker(selection: binding) {
            Text(String(localized: "smartlighting.edit.scene.none",
                        defaultValue: "None")).tag("")
            ForEach(customSceneNames, id: \.self) { name in
                Text(name).tag(name)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(phase.displayName)
                if let range = phaseTimeRange(for: phase) {
                    Text(range)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .pickerStyle(.menu)
    }
}
