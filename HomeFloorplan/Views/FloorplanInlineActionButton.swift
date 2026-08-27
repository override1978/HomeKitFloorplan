import SwiftUI

/// Bottone-azione compatto per le azioni in-place della planimetria (fase 5):
/// chip sulla mappa e CTA nelle righe del pannello.
///
/// Gestisce da sé l'esecuzione: spinner mentre il comando è in volo, nessuno
/// stato di successo persistente — a comando riuscito la chip o la riga che lo
/// ospita scompare perché lo stato che la generava si è risolto. Al fallimento
/// haptic d'errore e il bottone torna tappabile.
struct FloorplanInlineActionButton: View {
    let label: String
    var symbol: String? = nil
    let color: Color
    /// true = capsula piena, testo bianco (le chip sulla mappa, dove serve
    /// contrasto sul disegno); false = bordo e testo colorati (le righe nel
    /// pannello, come da design).
    var isProminent: Bool = false
    /// Ritorna il successo dell'azione.
    let action: @MainActor () async -> Bool

    @State private var isExecuting = false

    var body: some View {
        Button {
            guard !isExecuting else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            isExecuting = true
            Task {
                let success = await action()
                if !success {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
                isExecuting = false
            }
        } label: {
            HStack(spacing: 5) {
                if isExecuting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .tint(isProminent ? .white : color)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .bold))
                }
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isProminent ? .white : color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isProminent ? color : color.opacity(0.10))
            )
            .overlay(
                Capsule().strokeBorder(
                    isProminent ? .white.opacity(0.35) : color.opacity(0.55),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isExecuting ? 0.75 : 1)
        .accessibilityLabel(label)
    }
}
