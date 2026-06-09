import SwiftUI

// MARK: - FeedFilter

private enum FeedFilter: String, CaseIterable, Identifiable {
    case all         = "all"
    case live        = "live"
    case aiLearning  = "aiLearning"
    case environment = "environment"
    case security    = "security"
    case automation  = "automation"
    case energy      = "energy"

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .all:         return String(localized: "feed.filter.all",         defaultValue: "All")
        case .live:        return String(localized: "feed.filter.live",        defaultValue: "Active")
        case .aiLearning:  return String(localized: "feed.filter.ai",          defaultValue: "AI")
        case .environment: return String(localized: "feed.filter.environment", defaultValue: "Environment")
        case .security:    return String(localized: "feed.filter.security",    defaultValue: "Security")
        case .automation:  return String(localized: "feed.filter.automation",  defaultValue: "Automations")
        case .energy:      return String(localized: "feed.filter.energy",      defaultValue: "Energy")
        }
    }

    var sfSymbol: String {
        switch self {
        case .all:         return "list.bullet"
        case .live:        return "circle.fill"
        case .aiLearning:  return "brain"
        case .environment: return "thermometer.medium"
        case .security:    return "lock.shield"
        case .automation:  return "wand.and.stars"
        case .energy:      return "bolt"
        }
    }

    func matches(_ notif: ProactiveNotification) -> Bool {
        switch self {
        case .all:         return true
        case .live:        return notif.status.isLive
        case .aiLearning:  return [.learning, .behavioralAI, .aiDiscovery].contains(notif.category)
        case .environment: return [.environment, .comfort, .hvac, .lighting, .presence, .weather].contains(notif.category)
        case .security:    return notif.category == .security || notif.category == .deviceHealth
        case .automation:  return [.automationOpportunity, .scenes].contains(notif.category)
        case .energy:      return notif.category == .energy || notif.category == .maintenance
        }
    }
}

// MARK: - FeedDateSection

private enum FeedDateSection: String, CaseIterable {
    case today, yesterday, thisWeek, earlier

    var localizedLabel: String {
        switch self {
        case .today:     return String(localized: "feed.section.today",     defaultValue: "Today")
        case .yesterday: return String(localized: "feed.section.yesterday", defaultValue: "Yesterday")
        case .thisWeek:  return String(localized: "feed.section.thisWeek",  defaultValue: "This Week")
        case .earlier:   return String(localized: "feed.section.earlier",   defaultValue: "Earlier")
        }
    }

    static func section(for date: Date) -> FeedDateSection {
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return .today }
        if cal.isDateInYesterday(date) { return .yesterday }
        if let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start,
           date >= weekStart           { return .thisWeek }
        return .earlier
    }
}

// MARK: - IntelligenceFeedView

/// Home Intelligence Timeline — Sprint 15B.
///
/// A chronological timeline of everything the AI observes, learns, predicts
/// and suggests. Items are shown newest-first with HH:mm time markers and a
/// connecting rail that makes the temporal flow immediately legible.
struct IntelligenceFeedView: View {

    @Environment(ProactiveIntelligenceService.self) private var service

    @State private var selectedFilter: FeedFilter = .all
    @State private var expandedID:     UUID?

    private var filtered: [ProactiveNotification] {
        service.feedNotifications.filter { selectedFilter.matches($0) }
    }

    private var grouped: [(section: FeedDateSection, notifications: [ProactiveNotification])] {
        var dict: [FeedDateSection: [ProactiveNotification]] = [:]
        for n in filtered {
            let sec = FeedDateSection.section(for: n.lastUpdatedAt)
            dict[sec, default: []].append(n)
        }
        return FeedDateSection.allCases.compactMap { sec in
            guard let items = dict[sec], !items.isEmpty else { return nil }
            return (sec, items)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                filterChips
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                if filtered.isEmpty {
                    emptyState
                } else {
                    timelineContent
                }
            }
            .padding(.bottom, 40)
        }
        .navigationTitle(String(localized: "feed.nav.title", defaultValue: "Home Diary"))
        .navigationBarTitleDisplayMode(.large)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FeedFilter.allCases) { filter in
                    Button {
                        withAnimation(.spring(response: 0.3)) { selectedFilter = filter }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: filter.sfSymbol)
                                .font(.caption.weight(.medium))
                            Text(filter.localizedLabel)
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(selectedFilter == filter ? .white : BrandColor.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(
                                selectedFilter == filter
                                    ? BrandColor.primary
                                    : BrandColor.primary.opacity(0.10)
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Timeline Content

    private var timelineContent: some View {
        VStack(spacing: 28) {
            ForEach(grouped, id: \.section.rawValue) { group in
                timelineSection(group.section, items: group.notifications)
            }
        }
        .padding(.horizontal, 16)
    }

    private func timelineSection(
        _ section: FeedDateSection,
        items: [ProactiveNotification]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Date section header
            HStack(spacing: 10) {
                Text(section.localizedLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 0.5)
            }
            .padding(.bottom, 6)

            // Timeline rows
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, notif in
                TimelineEventRow(
                    notification: notif,
                    isExpanded:   expandedID == notif.id,
                    isLast:       idx == items.count - 1,
                    onExpand: {
                        withAnimation(.spring(response: 0.35)) {
                            expandedID = expandedID == notif.id ? nil : notif.id
                        }
                        if notif.status.isLive { service.acknowledge(notif) }
                    },
                    onActedOn: { service.markActedOn(notif) },
                    onSnooze:  { service.snooze(notif) },
                    onDismiss: { service.dismiss(notif) }
                )
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary.opacity(0.5))
            Text(String(localized: "feed.empty.title", defaultValue: "No Events"))
                .font(.headline)
                .foregroundStyle(.primary)
            Text(String(localized: "feed.empty.subtitle",
                        defaultValue: "The diary will fill up as the AI observes your home."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(48)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - TimelineEventRow

private struct TimelineEventRow: View {

    let notification: ProactiveNotification
    let isExpanded:   Bool
    let isLast:       Bool
    let onExpand:  () -> Void
    let onActedOn: () -> Void
    let onSnooze:  () -> Void
    let onDismiss: () -> Void

    private var accentColor: Color { notificationColor(for: notification.category) }

    private var showsConfidence: Bool {
        [NotificationCategory.learning, .behavioralAI, .aiDiscovery, .automationOpportunity]
            .contains(notification.category)
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: notification.lastUpdatedAt)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Time column
            Text(timeString)
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)
                .padding(.top, 18)

            // Vertical rail
            rail

            // Content
            contentArea
                .padding(.leading, 10)
                .padding(.trailing, 2)
        }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 0) {
            // Connector from previous item
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 1.5)
                .frame(width: 28, height: 16)

            // Icon node
            ZStack {
                Circle()
                    .fill(accentColor.opacity(notification.status.isLive ? 0.18 : 0.10))
                    .frame(width: 30, height: 30)
                Image(systemName: notification.category.sfSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(accentColor)
            }
            .overlay {
                if notification.status.isLive {
                    Circle()
                        .strokeBorder(accentColor.opacity(0.6), lineWidth: 1.5)
                        .frame(width: 30, height: 30)
                }
            }
            .frame(width: 28)

            // Connector to next item
            if !isLast {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 1.5)
                    .frame(width: 28)
                    .frame(maxHeight: .infinity)
            } else {
                Spacer()
                    .frame(width: 28, height: 12)
            }
        }
    }

    // MARK: Content Area

    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onExpand) {
                VStack(alignment: .leading, spacing: 5) {
                    // Headline
                    HStack(alignment: .top, spacing: 6) {
                        Text(notification.displayHeadline)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(isExpanded ? nil : 2)
                        Spacer(minLength: 4)
                        statusPill
                    }

                    // Body
                    Text(notification.displayBody)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)

                    // Meta
                    metaRow

                    // Expand indicator
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            // Expanded detail
            if isExpanded {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.bottom, 14)
            }
        }
    }

    // MARK: Meta Row

    private var metaRow: some View {
        HStack(spacing: 6) {
            Text(notification.category.localizedTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(accentColor)

            if let score = notification.score, showsConfidence {
                Text("·").font(.caption2).foregroundStyle(.tertiary)
                confidenceBadge(score.confidence)
            }

            if let trend = notification.trend {
                Text("·").font(.caption2).foregroundStyle(.tertiary)
                Image(systemName: trend.sfSymbol)
                    .font(.caption2)
                    .foregroundStyle(accentColor)
                Text(trend.localizedLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func confidenceBadge(_ confidence: Double) -> some View {
        let pct   = Int(confidence * 100)
        let color: Color = confidence >= 0.80 ? .green
                         : confidence >= 0.55 ? .orange
                         : .secondary
        return HStack(spacing: 3) {
            Image(systemName: "checkmark.seal.fill")
                .font(.caption2)
                .foregroundStyle(color)
            Text(String(format: String(localized: "feed.confidence.pct",
                                       defaultValue: "Confidence %d%%"), pct))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Status Pill

    private var statusPill: some View {
        Text(notification.status.localizedLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(pillColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(pillColor.opacity(0.12), in: Capsule())
    }

    private var pillColor: Color {
        switch notification.status {
        case .live, .updated:   return accentColor
        case .resolved:         return .green
        case .actedOn:          return .green
        case .snoozed:          return .orange
        default:                return Color.secondary
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            // Current / peak values
            if notification.currentValue != nil || notification.peakValue != nil {
                HStack(spacing: 24) {
                    if let cur = notification.currentValue {
                        valueChip(
                            label: String(localized: "feed.row.current", defaultValue: "Current"),
                            value: cur
                        )
                    }
                    if let peak = notification.peakValue {
                        valueChip(
                            label: String(localized: "feed.row.peak", defaultValue: "Peak"),
                            value: peak
                        )
                    }
                }
            }

            // Explainability panel — "Perché questo evento?"
            if notification.displayWhyExplanation != nil || notification.score != nil {
                explainabilityPanel
            }

            // Recommendation / suggestion
            if let rec = notification.displayRecommendation {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(.top, 1)
                    Text(rec)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // User feedback actions
            if notification.status.isActionable {
                actionButtons
            }
        }
    }

    // MARK: Explainability Panel

    private var explainabilityPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                String(localized: "feed.why.title", defaultValue: "Why this event?"),
                systemImage: "questionmark.circle"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            if let why = notification.displayWhyExplanation {
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let score = notification.score {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "feed.why.aiScore", defaultValue: "AI Score"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.3)
                        .padding(.top, 4)
                    scoreBreakdown(score)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func scoreBreakdown(_ score: IntelligenceScore) -> some View {
        VStack(spacing: 5) {
            scoreBar(label: String(localized: "feed.score.confidence",    defaultValue: "Confidence"),    value: score.confidence)
            scoreBar(label: String(localized: "feed.score.relevance",     defaultValue: "Relevance"),     value: score.relevance)
            scoreBar(label: String(localized: "feed.score.urgency",       defaultValue: "Urgency"),       value: score.urgency)
            scoreBar(label: String(localized: "feed.score.actionability", defaultValue: "Actionability"), value: score.actionability)
            scoreBar(label: String(localized: "feed.score.novelty",       defaultValue: "Novelty"),       value: score.novelty)
        }
    }

    private func scoreBar(label: String, value: Double) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(accentColor.opacity(0.10)).frame(height: 3)
                    Capsule().fill(accentColor).frame(width: max(4, geo.size.width * value), height: 3)
                }
            }
            .frame(height: 3)
            Text("\(Int(value * 100))%")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
    }

    private func valueChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentColor)
                .monospacedDigit()
        }
    }

    // MARK: Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button(action: onActedOn) {
                Label(
                    String(localized: "feed.action.done", defaultValue: "Done"),
                    systemImage: "checkmark"
                )
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accentColor)
            .controlSize(.small)

            Button(action: onSnooze) {
                Text(String(localized: "feed.action.later", defaultValue: "Later"))
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .controlSize(.small)

            Button(action: onDismiss) {
                Text(String(localized: "feed.action.dismiss", defaultValue: "Dismiss"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .controlSize(.small)
        }
    }
}

// MARK: - Color mapping (module-level, used by HomeIntelligenceDashboardView)

func notificationColor(for category: NotificationCategory) -> Color {
    switch category.accentColorToken {
    case "blue":   return .blue
    case "purple": return .purple
    case "red":    return .red
    case "yellow": return Color(red: 0.85, green: 0.70, blue: 0.0)
    case "amber":  return Color(red: 0.90, green: 0.60, blue: 0.10)
    case "teal":   return .teal
    case "orange": return .orange
    case "indigo": return .indigo
    case "green":  return .green
    default:       return BrandColor.primary
    }
}
