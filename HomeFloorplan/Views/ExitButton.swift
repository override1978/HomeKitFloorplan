import SwiftUI

/// Bottone circolare Liquid Glass con X rossa per uscire dall'editor.
struct ExitButton: View {
    let action: () -> Void
    
    var body: some View {
        GlassIconButton(size: 28, action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.red)
        }
    }
}

#Preview {
    ZStack {
        LinearGradient(colors: [.orange, .pink],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        ExitButton(action: {})
    }
}
