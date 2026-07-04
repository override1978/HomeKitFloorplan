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
