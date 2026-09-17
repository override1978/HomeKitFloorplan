import SwiftUI

// MARK: - DayRibbonCard

/// La scheda che contiene il nastro: il vetro, la maniglia, e il riassunto di
/// una riga quando è chiusa.
///
/// Stava dentro l'editor e non c'era ragione: legge la giornata e il pannello
/// contestuale, nient'altro. Sono due dipendenze dichiarate in cima al tipo
/// invece di duecento righe che pescano dallo stato della vista — ed è la
/// condizione che rende un taglio possibile, come si è visto al contrario coi
/// collaboratori, dove le fabbriche leggevano mezza vista e spostarle avrebbe
/// voluto dire aprire quindici membri privati.
///
/// Lo stato di apertura resta invece all'editor: serve anche al calcolo degli
/// inset del canvas, che deve sapere quanto spazio si prende il nastro. Da qui
/// il `@Binding` — la scheda lo cambia, ma non lo possiede.
struct DayRibbonCard: View {

    let day: FloorplanDayModel
    let overlay: FloorplanOverlayViewModel?
    @Binding var isCollapsed: Bool

    var body: some View {
        VStack(spacing: isCollapsed ? 4 : 2) {
            ribbonDragHandle

            if isCollapsed {
                collapsedDayRibbonSummary
            }

            if !isCollapsed {
                let filter = overlay?.activeMode == .controls ? overlay?.categoryFilter : nil
                
                DayRibbonView(moments: filteredMoments(day.moments.filter { !$0.isSolarKind }, filter: filter),
                              day: day.visibleDay,
                              now: day.clock,
                              sunrise: day.solarTimes.todaySunrise,
                              sunset: day.solarTimes.todaySunset,
                              gestures: filteredGestures(day.gestures, filter: filter),
                              spans: filteredSpans(day.spans, filter: filter),
                              dayOffset: day.offset,
                              canGoBack: day.offset > -FloorplanDayModel.maxDaysBack,
                              canGoForward: day.offset < FloorplanDayModel.maxDaysForward,
                              onSelect: { moment in
                                  day.selectedMoment = moment
                                  day.selectedGesture = nil
                                  day.selectedSpan = nil
                                  day.selectedRunningSpans = []
                                  overlay?.showMomentDetail()
                              },
                              onSelectGesture: { gesture in
                                  day.selectedMoment = nil
                                  day.selectedGesture = gesture
                                  day.selectedSpan = nil
                                  day.selectedRunningSpans = []
                                  overlay?.showGestureDetail()
                              },
                              onSelectSpan: { span in
                                  day.selectedMoment = nil
                                  day.selectedGesture = nil
                                  day.selectedSpan = span
                                  day.selectedRunningSpans = []
                                  overlay?.showSpanDetail()
                              },
                              onSelectRunningSpans: { spans in
                                  day.selectedMoment = nil
                                  day.selectedGesture = nil
                                  day.selectedSpan = nil
                                  day.selectedRunningSpans = spans
                                  overlay?.showRunningSpansDetail()
                              },
                              onShiftDay: { day.shift(by: $0) },
                              onReturnToday: { day.shift(by: -day.offset) })
            }
        }
            .padding(.horizontal, 14)
            .padding(.top, isCollapsed ? 5 : 4)
            .padding(.bottom, isCollapsed ? 6 : 4)
            // Superficie di chrome, non più una card del colore del fondo.
            //
            // Era riempita con `floorplanBackgroundColor` da quando il fondo
            // era fisso: allora si staccava. Con la luce circadiana il fondo si
            // muove, e una card dello stesso identico colore sparisce —
            // letteralmente, alle nove del mattino restavano solo i pallini
            // sospesi nel vuoto. Il vetro invece prende identità da ciò che ha
            // sotto, che è esattamente la proprietà che serve a una superficie
            // che deve galleggiare su un fondo che cambia tutto il giorno.
            // Stessa superficie delle pill in alto: vetro senza tinta.
            //
            // Le tingevo con la superficie circadiana, e il risultato era una
            // lastra piena accanto a pillole di vetro — due materiali diversi
            // sulla stessa schermata. Ma è anche ridondante, e questa è la
            // parte che vale la pena ricordare: **il vetro segue già la luce da
            // solo**, perché rifrange ciò che ha sotto. La tinta serve dove il
            // vetro non c'è, cioè nel ramo legacy, e lì infatti resta.
            .glassChromeSurface(
                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                legacyFill: AnyShapeStyle(.regularMaterial),
                legacyBorder: Color.primary.opacity(0.08),
                legacyShadow: GlassChromeShadow(color: .black.opacity(0.18), radius: 14, y: 4))
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .animation(.spring(response: 0.32, dampingFraction: 0.88), value: isCollapsed)
    }

    private var ribbonDragHandle: some View {
        Capsule()
            .fill(.secondary.opacity(0.45))
            .frame(width: 68, height: 5)
            .frame(width: 140, height: 18)
            .contentShape(Rectangle())
            .onTapGesture {
                setCollapsed(!isCollapsed)
            }
            .gesture(ribbonCollapseDrag)
            .accessibilityLabel(isCollapsed
                                ? String(localized: "ribbon.expand", defaultValue: "Show day ribbon")
                                : String(localized: "ribbon.collapse", defaultValue: "Hide day ribbon"))
    }

    private var ribbonCollapseDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onEnded { value in
                if value.translation.height > 10 {
                    setCollapsed(true)
                } else if value.translation.height < -10 {
                    setCollapsed(false)
                }
            }
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            isCollapsed = collapsed
        }
    }

    private var collapsedDayRibbonSummary: some View {
        HStack(spacing: 10) {
            Text(collapsedNowText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if day.offset != 0 {
                Button { day.shift(by: -day.offset) } label: {
                    HStack(spacing: 4) {
                        Text(DayRibbonView.dayLabel(offset: day.offset, day: day.visibleDay.start))
                            .font(.system(size: 10, weight: .semibold))
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(BrandColor.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(BrandColor.primary.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                
                Spacer(minLength: 8)
            }

            Text(collapsedNextText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: 22)
    }

    private var collapsedNowText: String {
        if let span = day.spans.first(where: { $0.start <= day.clock && ($0.end ?? .distantFuture) > day.clock }) {
            return String(localized: "ribbon.collapsed.now.running",
                          defaultValue: "ADESSO · \(span.name) attivo")
        }
        return String(localized: "ribbon.collapsed.now",
                      defaultValue: "ADESSO · \(day.clock.formatted(date: .omitted, time: .shortened))")
    }

    private var collapsedNextText: String {
        guard let next = day.moments.filter({ !$0.isSolarKind }).first(where: { $0.at > day.clock }) else {
            return String(localized: "ribbon.collapsed.next.none", defaultValue: "PROSSIMO · nessun evento")
        }
        return String(localized: "ribbon.collapsed.next",
                      defaultValue: "PROSSIMO · \(next.at.formatted(date: .omitted, time: .shortened)) \(DayRibbonView.ribbonTitle(for: next))")
    }

    // MARK: - Filtri

    // MARK: - Filtri per DayRibbon

    private func filteredMoments(_ moments: [DayMoment], filter: AccessoryCategory?) -> [DayMoment] {
        guard let filter = filter else { return moments }
        return moments.filter { moment in
            switch moment.kind {
            case .calendar, .solar: return true // Eventi non filtrabili, li mostriamo a prescindere per contesto temporale
            case .automation: return true // Le automazioni per ora le mostriamo, idealmente andrebbero indagate se toccano la categoria
            }
        }
    }

    private func filteredGestures(_ gestures: [HumanGesture], filter: AccessoryCategory?) -> [HumanGesture] {
        guard let filter = filter else { return gestures }
        return gestures.filter { gesture in
            // Un gesto passa se almeno un suo cambio riguarda la categoria filtrata
            gesture.changes.contains { change in
                guard let adapterType = AccessoryEventType(rawValue: change.eventType) else { return false }
                // Semplificazione: mappa manuale dei tipi evento alle categorie principali
                switch filter {
                case .lights: return adapterType == .light
                case .climate: return adapterType == .thermostat || adapterType == .fan || adapterType == .airPurifier || adapterType == .humidifier
                case .outlets: return adapterType == .outlet || adapterType == .switch
                case .security: return adapterType == .contact || adapterType == .motion
                default: return false
                }
            }
        }
    }

    private func filteredSpans(_ spans: [DaySpan], filter: AccessoryCategory?) -> [DaySpan] {
        guard let filter = filter else { return spans }
        return spans.filter { span in
            guard let adapterType = AccessoryEventType(rawValue: span.eventType) else { return false }
            switch filter {
            case .lights: return adapterType == .light
            case .climate: return adapterType == .thermostat || adapterType == .fan || adapterType == .airPurifier || adapterType == .humidifier
            case .outlets: return adapterType == .outlet || adapterType == .switch
            case .security: return adapterType == .contact || adapterType == .motion
            default: return false
            }
        }
    }
}
