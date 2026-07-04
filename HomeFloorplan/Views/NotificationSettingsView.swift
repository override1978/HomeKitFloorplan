import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
    @Environment(AISettings.self) private var aiSettings

    @AppStorage("alertNotificationsEnabled")
    private var alertNotificationsEnabled: Bool = false

    @AppStorage(SecurityNotificationService.enabledKey)
    private var securityNotificationsEnabled: Bool = false

    @AppStorage("proactiveIntelligenceNotificationsEnabled")
    private var proactiveIntelligenceNotificationsEnabled: Bool = false

    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section {
                notificationPermissionRow
            } header: {
                Text(String(localized: "settings.notifications.permission.header", defaultValue: "System Permission"))
            } footer: {
                Text(permissionFooter)
            }

            Section {
                NavigationLink {
                    SecurityNotificationsSettingsView()
                } label: {
                    notificationLinkRow(
                        icon: "lock.shield.fill",
                        title: String(localized: "settings.notifications.security.link", defaultValue: "Security Alerts"),
                        subtitle: String(localized: "settings.security.notifications.summary", defaultValue: "Critical alerts for alarms, smoke, CO, and water leaks."),
                        status: statusText(isEnabled: securityNotificationsEnabled),
                        statusColor: statusColor(isEnabled: securityNotificationsEnabled)
                    )
                }

                NavigationLink {
                    EnvironmentSettingsView()
                } label: {
                    notificationLinkRow(
                        icon: "leaf.fill",
                        title: String(localized: "settings.notifications.environment.link", defaultValue: "Environment Alerts"),
                        subtitle: String(localized: "settings.notifications.environment.subtitle", defaultValue: "Threshold alerts for temperature, humidity, air quality, and sensors."),
                        status: statusText(isEnabled: alertNotificationsEnabled),
                        statusColor: statusColor(isEnabled: alertNotificationsEnabled)
                    )
                }
            } header: {
                Text(String(localized: "settings.notifications.categories.header", defaultValue: "Alert Categories"))
            } footer: {
                Text(String(localized: "settings.notifications.categories.footer", defaultValue: "Security and environmental alerts can request system notifications when enabled."))
            }

            Section {
                Toggle(isOn: $proactiveIntelligenceNotificationsEnabled) {
                    Label(
                        String(localized: "settings.notifications.intelligence.toggle", defaultValue: "Home Intelligence Notifications"),
                        systemImage: "brain"
                    )
                }
                .onChange(of: proactiveIntelligenceNotificationsEnabled) { _, enabled in
                    if enabled {
                        requestNotificationPermissionIfNeeded()
                    }
                }
                .disabled(!aiSettings.isOperational)

                HStack {
                    Label(
                        String(localized: "settings.notifications.intelligence.feed", defaultValue: "Intelligence Feed"),
                        systemImage: "list.bullet.rectangle"
                    )
                    Spacer()
                    Text(String(localized: "settings.notifications.status.inApp", defaultValue: "In-app"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(BrandColor.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(BrandColor.primary.opacity(0.12), in: Capsule())
                }

                NavigationLink {
                    OperationalIntelligencePolicySettingsView()
                } label: {
                    notificationLinkRow(
                        icon: "slider.horizontal.3",
                        title: String(localized: "settings.notifications.operationalPolicy.link", defaultValue: "Operational Intelligence"),
                        subtitle: String(localized: "settings.notifications.operationalPolicy.subtitle", defaultValue: "Rules for lights, plugs, doors, windows, and security evidence."),
                        status: String(localized: "settings.status.configurable", defaultValue: "Configurable"),
                        statusColor: BrandColor.primary
                    )
                }
            } header: {
                Text(String(localized: "settings.notifications.intelligence.header", defaultValue: "Home Intelligence"))
            } footer: {
                Text(intelligenceFooter)
            }
        }
        .tint(BrandColor.primary)
        .navigationTitle(String(localized: "settings.notifications.title", defaultValue: "Notifications"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear { refreshAuthorizationStatus() }
    }

    private var notificationPermissionRow: some View {
        HStack(spacing: 12) {
            Image(systemName: permissionIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(permissionColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "settings.notifications.permission.title", defaultValue: "iOS Notifications"))
                    .foregroundStyle(.primary)
                Text(permissionStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if authorizationStatus == .notDetermined {
                Button(String(localized: "settings.notifications.permission.request", defaultValue: "Allow")) {
                    requestNotificationPermissionIfNeeded()
                }
                .font(.subheadline.weight(.semibold))
            } else {
                Text(permissionStatusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(permissionColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(permissionColor.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    private var permissionStatusText: String {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return String(localized: "settings.notifications.status.allowed", defaultValue: "Allowed")
        case .denied:
            return String(localized: "settings.notifications.status.denied", defaultValue: "Denied")
        case .notDetermined:
            return String(localized: "settings.notifications.status.notAsked", defaultValue: "Not asked")
        @unknown default:
            return String(localized: "settings.notifications.status.unknown", defaultValue: "Unknown")
        }
    }

    private var permissionFooter: String {
        switch authorizationStatus {
        case .denied:
            return String(localized: "settings.notifications.permission.footer.denied", defaultValue: "Notifications are blocked in iOS Settings. Re-enable them there to receive alerts.")
        case .notDetermined:
            return String(localized: "settings.notifications.permission.footer.notAsked", defaultValue: "You can review categories before allowing system notifications.")
        default:
            return String(localized: "settings.notifications.permission.footer.allowed", defaultValue: "Category toggles below decide which alerts HomeFloorplan can send.")
        }
    }

    private var intelligenceFooter: String {
        if !aiSettings.isOperational {
            return String(localized: "settings.notifications.intelligence.footer.disabled", defaultValue: "Set up Home Intelligence before enabling proactive notification delivery.")
        }
        return proactiveIntelligenceNotificationsEnabled
        ? String(localized: "settings.notifications.intelligence.footer.on", defaultValue: "High-priority intelligence events can be delivered as notifications. Lower-priority items stay in the feed.")
        : String(localized: "settings.notifications.intelligence.footer.off", defaultValue: "Home Intelligence items remain visible in the in-app feed until you enable push delivery.")
    }

    private var permissionIcon: String {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "checkmark.circle.fill"
        case .denied:
            return "xmark.octagon.fill"
        case .notDetermined:
            return "questionmark.circle.fill"
        @unknown default:
            return "bell"
        }
    }

    private var permissionColor: Color {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .green
        case .denied:
            return .red
        case .notDetermined:
            return .orange
        @unknown default:
            return .secondary
        }
    }

    private func statusText(isEnabled: Bool) -> String {
        guard isEnabled else {
            return String(localized: "settings.status.off", defaultValue: "Off")
        }
        return permissionStatusText
    }

    private func statusColor(isEnabled: Bool) -> Color {
        guard isEnabled else { return .secondary }
        return permissionColor
    }

    private func notificationLinkRow(
        icon: String,
        title: String,
        subtitle: String,
        status: String,
        statusColor: Color
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(status)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 2)
    }

    private func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                authorizationStatus = settings.authorizationStatus
            }
        }
    }

    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                Task { @MainActor in
                    authorizationStatus = settings.authorizationStatus
                }
                return
            }
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge, .criticalAlert]
            ) { _, _ in
                refreshAuthorizationStatus()
            }
        }
    }
}
