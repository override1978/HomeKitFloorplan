import SwiftUI
import HomeKit

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

            // MARK: Stanze configurate
            Section {
                if engine.profiles.isEmpty {
                    Text(String(localized: "smartlighting.rooms.empty",
                                defaultValue: "No rooms configured. Tap + to add one."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
                    Text("Sunrise \(Self.timeFmt.string(from: sr)) · Sunset \(Self.timeFmt.string(from: ss))")
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

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.roomName)
                Group {
                    if missingCount > 0 {
                        Text(String(format: String(localized: "smartlighting.row.missingScenes",
                                                   defaultValue: "%d missing scene(s)"),
                                    missingCount))
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
                .foregroundStyle(missingCount > 0 ? .orange : .secondary)
            }
            Spacer()
            if missingCount > 0 {
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

    let profileID: UUID
    @State private var draft: LightingProfile

    init(profileID: UUID, initial: LightingProfile) {
        self.profileID = profileID
        self._draft    = State(initialValue: initial)
    }

    private var generalFooter: String {
        if let sh = draft.sleepHour, let wh = draft.wakeHour {
            return String(format: String(localized: "smartlighting.edit.general.footer.window",
                                         defaultValue: "Engine silent from %1$02d:00 to %2$02d:00 — no scene will be activated in that window."),
                          sh, wh)
        } else if draft.sleepHour != nil || draft.wakeHour != nil {
            let sh = draft.sleepHour ?? 1
            let wh = draft.wakeHour  ?? 7
            return String(format: String(localized: "smartlighting.edit.general.footer.window",
                                         defaultValue: "Engine silent from %1$02d:00 to %2$02d:00 — no scene will be activated in that window."),
                          sh, wh)
        } else {
            return String(localized: "smartlighting.edit.general.footer",
                          defaultValue: "\"Night starts at\" sets when the Evening phase transitions to Night for this room. Enable \"Silence Window\" to define a time range during which no scene is activated — useful to avoid lights turning on before you wake up.")
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

    var body: some View {
        Form {
            // MARK: Generale
            Section {
                Toggle(String(localized: "smartlighting.edit.enabled",
                              defaultValue: "Enabled"),
                       isOn: $draft.isEnabled)

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
                                   draft.wakeHour  = draft.wakeHour  ?? 7
                               } else {
                                   draft.sleepHour = nil
                                   draft.wakeHour  = nil
                               }
                           }
                       ))

                if draft.sleepHour != nil || draft.wakeHour != nil {
                    Picker(String(localized: "smartlighting.edit.silenceWindow.from",
                                  defaultValue: "Silent from"),
                           selection: Binding(
                               get: { draft.sleepHour ?? 1 },
                               set: { draft.sleepHour = $0 }
                           )) {
                        ForEach([0, 1, 2, 3, 4, 5, 6], id: \.self) { h in
                            Text(String(format: "%02d:00", h)).tag(h)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker(String(localized: "smartlighting.edit.silenceWindow.to",
                                  defaultValue: "Resume at"),
                           selection: Binding(
                               get: { draft.wakeHour ?? 7 },
                               set: { draft.wakeHour = $0 }
                           )) {
                        ForEach(Array(5...10), id: \.self) { h in
                            Text(String(format: "%02d:00", h)).tag(h)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text(String(localized: "smartlighting.edit.general.header",
                            defaultValue: "General"))
            } footer: {
                Text(generalFooter)
            }

            // MARK: Scene per fase
            Section {
                ForEach(LightingPhase.allCases, id: \.self) { phase in
                    scenePicker(for: phase)
                }
            } header: {
                Text(String(localized: "smartlighting.edit.scenes.header",
                            defaultValue: "Scene per Phase"))
            } footer: {
                Text(String(localized: "smartlighting.edit.scenes.footer",
                            defaultValue: "\"None\" skips that phase — the engine makes no change. Only custom HomeKit scenes are listed. Times are based on today's sunrise/sunset."))
            }

            // MARK: Profile preview
            Section {
                if configuredSceneNames.isEmpty {
                    Label(
                        String(localized: "smartlighting.preview.noScenes",
                               defaultValue: "No scenes configured yet. This profile will not activate anything."),
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(configuredSceneNames, id: \.phase) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: missingSceneNames.contains(item.name) ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(missingSceneNames.contains(item.name) ? .orange : .green)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.phase.displayName)
                                    .font(.subheadline.weight(.medium))
                                Text(item.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let range = phaseTimeRange(for: item.phase) {
                                    Text(range)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    if !missingSceneNames.isEmpty {
                        Text(String(localized: "smartlighting.preview.missing.footer",
                                    defaultValue: "Missing scenes will be skipped until they are restored or replaced."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text(String(localized: "smartlighting.preview.header",
                            defaultValue: "Activation Preview"))
            } footer: {
                Text(String(localized: "smartlighting.preview.footer",
                            defaultValue: "Review what this room can do before enabling the profile."))
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
                            defaultValue: "Lux Sensor"))
            } footer: {
                Text(String(localized: "smartlighting.edit.lux.footer",
                            defaultValue: "If a lux sensor in this room reads above the threshold, the engine skips activation. If natural light returns after the engine already activated a scene, the selected scene will be triggered after 20 minutes."))
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
                        Button("1 ora") { applyOverride(hours: 1) }
                        Button("2 ore") { applyOverride(hours: 2) }
                        Button("4 ore") { applyOverride(hours: 4) }
                        Button("Fino al mattino (07:00)") { applyOverrideUntilMorning() }
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
        let binding = Binding<String>(
            get: { draft.sceneName(for: phase) ?? "" },
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
