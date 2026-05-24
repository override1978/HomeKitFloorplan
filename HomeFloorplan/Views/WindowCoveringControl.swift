import SwiftUI
import HomeKit

/// Controllo Apple-Home style per copertura finestre.
/// Slider orizzontale spesso con riempimento giallo + percentuale al centro,
/// trascinabile da qualsiasi punto. Sotto: bottoni Chiudi / Apri.
/// Lo slider scrive a HomeKit solo al rilascio (debounce).
struct WindowCoveringControl: View {
    let adapter: WindowCoveringAdapter
    
    @Environment(HomeKitService.self) private var homeKit
    
    @State private var sliderDraft: Double = 0
    @State private var isDragging: Bool = false
    
    private let sliderHeight: CGFloat = 60
    
    private var currentValue: Int { adapter.currentPositionValue }
    private var targetValue: Int { adapter.targetPositionValue }
    private var isReachable: Bool { adapter.accessory.isReachable }
    private var isMoving: Bool { currentValue != targetValue }
    
    var body: some View {
        VStack(spacing: 14) {
            stateLabel
            slider
            quickActions
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .onAppear {
            sliderDraft = Double(currentValue)
        }
        .onChange(of: currentValue) { _, newValue in
            if !isDragging {
                sliderDraft = Double(newValue)
            }
        }
    }
    
    // MARK: - Label di stato
    
    private var stateLabel: some View {
        HStack {
            Text("Posizione")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(stateText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }
    
    private var stateText: String {
        if !isReachable { return "Non raggiungibile" }
        if isMoving { return "In movimento → \(targetValue)%" }
        if currentValue >= 90 { return "Aperta" }
        if currentValue <= 10 { return "Chiusa" }
        return "Aperta al \(currentValue)%"
    }
    
    // MARK: - Slider Apple-Home-style
    
    private var slider: some View {
        GeometryReader { geo in
            let fillWidth = geo.size.width * CGFloat(sliderDraft / 100)
            
            ZStack(alignment: .leading) {
                // Background della pillola (vetrino)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial)
                
                // Fill giallo dinamico
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.yellow.opacity(0.85))
                    .frame(width: max(0, fillWidth))
                    .animation(isDragging ? nil : .spring(response: 0.4), value: fillWidth)
                
                // Percentuale sovrimpressa
                HStack {
                    Spacer()
                    Text("\(Int(sliderDraft))%")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(textColorForPercentage(fillWidth: fillWidth, totalWidth: geo.size.width))
                        .contentTransition(.numericText())
                    Spacer()
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let pct = (value.location.x / geo.size.width) * 100
                        sliderDraft = min(100, max(0, pct))
                    }
                    .onEnded { _ in
                        isDragging = false
                        writePosition(Int(sliderDraft.rounded()))
                    }
            )
        }
        .frame(height: sliderHeight)
        .disabled(!isReachable)
        .opacity(isReachable ? 1.0 : 0.5)
    }
    
    /// La percentuale è bianca quando il fill la "raggiunge" (passa oltre il centro),
    /// altrimenti resta primary. Effetto Apple Home: il testo "vive" sul fill.
    private func textColorForPercentage(fillWidth: CGFloat, totalWidth: CGFloat) -> Color {
        let textCenter = totalWidth / 2
        return fillWidth >= textCenter ? .white : .primary
    }
    
    // MARK: - Quick actions
    
    private var quickActions: some View {
        HStack(spacing: 12) {
            quickButton(label: "Chiudi", systemImage: "arrow.down.to.line", target: 0)
            quickButton(label: "Apri", systemImage: "arrow.up.to.line", target: 100)
        }
    }
    
    private func quickButton(label: String, systemImage: String, target: Int) -> some View {
        Button {
            sliderDraft = Double(target)
            writePosition(target)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(label)
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!isReachable)
    }
    
    // MARK: - Write
    
    private func writePosition(_ value: Int) {
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()
        Task {
            do {
                try await adapter.setPosition(value)
            } catch {
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
            }
        }
    }
}
