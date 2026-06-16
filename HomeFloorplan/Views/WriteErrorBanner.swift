import SwiftUI

/// Inline orange banner shown when a HomeKit write command fails.
/// Visibility is driven by a parent @State bool; the parent calls
/// triggerWriteError() which sets the flag and auto-dismisses after 2.5 s.
struct WriteErrorBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.white)
            Text(String(localized: "accessory.write.error",
                        defaultValue: "Command failed. Check accessory connection."))
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.92))
        )
    }
}
