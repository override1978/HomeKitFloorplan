import SwiftUI

struct OperationalIntelligencePolicySettingsView: View {
    @State private var policy = OperationalIntelligencePolicy.load()

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "operationalPolicy.enabled", defaultValue: "Operational anomaly detection"), isOn: $policy.isEnabled)
                    .onChange(of: policy.isEnabled) { _, _ in save() }
            } footer: {
                Text(String(localized: "operationalPolicy.enabled.footer", defaultValue: "These rules refine lights, plugs, doors, windows, and security signals before they appear in Intelligence, Floorplan, or notifications."))
            }

            Section {
                durationStepper(
                    title: String(localized: "operationalPolicy.lights.longOn", defaultValue: "Lights on for"),
                    systemImage: "lightbulb.fill",
                    value: $policy.lightLongOnMinutes,
                    range: 15...720,
                    step: 15
                )
                durationStepper(
                    title: String(localized: "operationalPolicy.loads.longActive", defaultValue: "Plugs/loads active for"),
                    systemImage: "bolt.fill",
                    value: $policy.loadLongActiveMinutes,
                    range: 30...1440,
                    step: 30
                )
            } header: {
                Text(String(localized: "operationalPolicy.power.header", defaultValue: "Lights and Loads"))
            } footer: {
                Text(String(localized: "operationalPolicy.power.footer", defaultValue: "Always-on accessories should be ignored later from the accessory detail or policy list."))
            }

            Section {
                durationStepper(
                    title: String(localized: "operationalPolicy.contacts.open", defaultValue: "Open contact after"),
                    systemImage: "rectangle.portrait.and.arrow.right",
                    value: $policy.contactOpenMinutes,
                    range: 5...240,
                    step: 5
                )
                durationStepper(
                    title: String(localized: "operationalPolicy.contacts.escalation", defaultValue: "Aumenta priorità dopo"),
                    systemImage: "exclamationmark.triangle.fill",
                    value: $policy.contactEscalationMinutes,
                    range: 10...480,
                    step: 5
                )
                Toggle(String(localized: "operationalPolicy.contacts.nightEscalation", defaultValue: "Priorità alta di notte"), isOn: $policy.escalatesAtNight)
                    .onChange(of: policy.escalatesAtNight) { _, _ in save() }
                if policy.escalatesAtNight {
                    hourStepper(
                        title: String(localized: "operationalPolicy.contacts.nightStart", defaultValue: "Notte da"),
                        systemImage: "moon.fill",
                        value: $policy.nightStartHour
                    )
                    hourStepper(
                        title: String(localized: "operationalPolicy.contacts.nightEnd", defaultValue: "Notte fino a"),
                        systemImage: "sunrise.fill",
                        value: $policy.nightEndHour
                    )
                }
            } header: {
                Text(String(localized: "operationalPolicy.contacts.header", defaultValue: "Doors, Windows, Security"))
            } footer: {
                Text(String(localized: "operationalPolicy.contacts.footer", defaultValue: "Nella finestra notturna configurata, un contatto aperto supera subito la priorità base dopo la prima soglia."))
            }

            Section {
                Toggle(String(localized: "operationalPolicy.daylight.enabled", defaultValue: "Report lights on in bright rooms"), isOn: $policy.daylightWasteEnabled)
                    .onChange(of: policy.daylightWasteEnabled) { _, _ in save() }
                if policy.daylightWasteEnabled {
                    luxStepper(
                        title: String(localized: "operationalPolicy.daylight.threshold", defaultValue: "Brightness threshold"),
                        systemImage: "sun.max.fill",
                        value: $policy.daylightLuxThreshold,
                        range: 200...1500,
                        step: 50
                    )
                    hourStepper(
                        title: String(localized: "operationalPolicy.daylight.dayStart", defaultValue: "Daytime from"),
                        systemImage: "sunrise.fill",
                        value: $policy.daylightStartHour
                    )
                    hourStepper(
                        title: String(localized: "operationalPolicy.daylight.dayEnd", defaultValue: "Daytime until"),
                        systemImage: "sunset.fill",
                        value: $policy.daylightEndHour
                    )
                }
            } header: {
                Text(String(localized: "operationalPolicy.daylight.header", defaultValue: "Lights and Daylight"))
            } footer: {
                Text(String(localized: "operationalPolicy.daylight.footer", defaultValue: "Within this window, rooms brighter than the threshold with lights on are reported as an incoherence. Requires a light sensor in the room. The window keeps evening artificial light from triggering itself."))
            }

            Section {
                degreesStepper(
                    title: String(localized: "operationalPolicy.climate.coolingDelta", defaultValue: "Ineffective cooling threshold"),
                    systemImage: "thermometer.medium",
                    value: $policy.coolingIneffectiveDeltaCelsius,
                    range: 0.3...3.0,
                    step: 0.1
                )
                ppmStepper(
                    title: String(localized: "operationalPolicy.climate.co2Rise", defaultValue: "CO2 rise threshold"),
                    systemImage: "carbon.dioxide.cloud.fill",
                    value: $policy.co2RiseThresholdPPM,
                    range: 60...500,
                    step: 20
                )
            } header: {
                Text(String(localized: "operationalPolicy.climate.header", defaultValue: "Climate and Air"))
            } footer: {
                Text(String(localized: "operationalPolicy.climate.footer", defaultValue: "These are TREND thresholds: how fast a value changes over the last 90 minutes. Absolute levels (how much is \"too much\") come from your sensor thresholds in the Environment tab — incoherences activate at 90% of your CO2 warning level and escalate at 120%."))
            }

            if !policy.ignoredRoomNames.isEmpty {
                Section {
                    ForEach(policy.ignoredRoomNames, id: \.self) { room in
                        HStack {
                            Label(room, systemImage: "square.slash")
                            Spacer()
                            Button(role: .destructive) {
                                policy.ignoredRoomNames.removeAll { $0 == room }
                                save()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text(String(localized: "operationalPolicy.ignoredRooms.header", defaultValue: "Ignored Rooms"))
                } footer: {
                    Text(String(localized: "operationalPolicy.ignoredRooms.footer", defaultValue: "These rooms are excluded from all intelligence checks (anomalies, sensor faults, incoherences). Useful for technical rooms hosting virtual switches."))
                }
            }

            if !policy.ignoredAccessoryIDs.isEmpty {
                Section {
                    Button(role: .destructive) {
                        policy.ignoredAccessoryIDs.removeAll()
                        save()
                    } label: {
                        Label(String(localized: "operationalPolicy.ignored.clear", defaultValue: "Clear ignored accessories"), systemImage: "trash")
                    }
                } header: {
                    Text(String(localized: "operationalPolicy.ignored.header", defaultValue: "Ignored Accessories"))
                } footer: {
                    Text(String(format: String(localized: "operationalPolicy.ignored.count", defaultValue: "%d accessories ignored"), policy.ignoredAccessoryIDs.count))
                }
            }
        }
        .navigationTitle(String(localized: "operationalPolicy.title", defaultValue: "Operational Intelligence"))
        .navigationBarTitleDisplayMode(.large)
    }

    private func durationStepper(
        title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer()
            HStack(spacing: 0) {
                Button {
                    decrement(value, step: step, in: range)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 44, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue <= range.lowerBound)

                Divider()
                    .frame(height: 22)

                Text(durationText(value.wrappedValue))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 72)

                Divider()
                    .frame(height: 22)

                Button {
                    increment(value, step: step, in: range)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue >= range.upperBound)
            }
            .background(.quaternary, in: Capsule())
        }
    }

    private func luxStepper(
        title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer()
            HStack(spacing: 0) {
                Button {
                    decrement(value, step: step, in: range)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 44, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue <= range.lowerBound)

                Divider()
                    .frame(height: 22)

                Text(luxText(value.wrappedValue))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 72)

                Divider()
                    .frame(height: 22)

                Button {
                    increment(value, step: step, in: range)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue >= range.upperBound)
            }
            .background(.quaternary, in: Capsule())
        }
    }

    private func degreesStepper(
        title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer()
            HStack(spacing: 0) {
                Button {
                    decrement(value, step: step, in: range)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 44, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue <= range.lowerBound)

                Divider()
                    .frame(height: 22)

                Text(degreesText(value.wrappedValue))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 72)

                Divider()
                    .frame(height: 22)

                Button {
                    increment(value, step: step, in: range)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue >= range.upperBound)
            }
            .background(.quaternary, in: Capsule())
        }
    }

    private func ppmStepper(
        title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer()
            HStack(spacing: 0) {
                Button {
                    decrement(value, step: step, in: range)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 44, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue <= range.lowerBound)

                Divider()
                    .frame(height: 22)

                Text(String(format: "%d ppm", Int(value.wrappedValue)))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 72)

                Divider()
                    .frame(height: 22)

                Button {
                    increment(value, step: step, in: range)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue >= range.upperBound)
            }
            .background(.quaternary, in: Capsule())
        }
    }

    private func degreesText(_ value: Double) -> String {
        String(format: "%.1f °C", value)
    }

    private func luxText(_ value: Double) -> String {
        String(format: String(localized: "operationalPolicy.daylight.luxValue", defaultValue: "%d lux"), Int(value))
    }

    private func hourStepper(
        title: String,
        systemImage: String,
        value: Binding<Int>
    ) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer()
            HStack(spacing: 0) {
                Button {
                    adjustHour(value, by: -1)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 44, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                Divider()
                    .frame(height: 22)

                Text(hourText(value.wrappedValue))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 72)

                Divider()
                    .frame(height: 22)

                Button {
                    adjustHour(value, by: 1)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            .background(.quaternary, in: Capsule())
        }
    }

    private func decrement(_ value: Binding<Double>, step: Double, in range: ClosedRange<Double>) {
        adjust(value, by: -step, in: range)
    }

    private func increment(_ value: Binding<Double>, step: Double, in range: ClosedRange<Double>) {
        adjust(value, by: step, in: range)
    }

    private func adjust(_ value: Binding<Double>, by delta: Double, in range: ClosedRange<Double>) {
        let nextValue = min(max(value.wrappedValue + delta, range.lowerBound), range.upperBound)
        guard nextValue != value.wrappedValue else { return }
        value.wrappedValue = nextValue
        save()
    }

    private func adjustHour(_ value: Binding<Int>, by delta: Int) {
        let nextValue = (value.wrappedValue + delta + 24) % 24
        guard nextValue != value.wrappedValue else { return }
        value.wrappedValue = nextValue
        save()
    }

    private func hourText(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    private func durationText(_ minutes: Double) -> String {
        let totalMinutes = Int(minutes.rounded())
        if totalMinutes < 60 {
            return String(format: String(localized: "duration.minutes.short", defaultValue: "%dm"), totalMinutes)
        }
        let hours = totalMinutes / 60
        let remaining = totalMinutes % 60
        if remaining == 0 {
            return String(format: String(localized: "duration.hours.short", defaultValue: "%dh"), hours)
        }
        return String(format: String(localized: "duration.hoursMinutes.short", defaultValue: "%dh %dm"), hours, remaining)
    }

    private func save() {
        policy.save()
    }
}
