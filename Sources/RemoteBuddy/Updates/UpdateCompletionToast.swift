import SwiftUI

/// A passive completion notice shared by the main window and isolated previews.
struct UpdateCompletionToast: ViewModifier {
    @EnvironmentObject private var localization: LocalizationStore
    @State private var showsUpdateCompletion = true
    let version: String?
    var contentLeadingInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if showsUpdateCompletion, let version {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(localization.text("update.completed.title"))
                                .font(.headline)
                            Text(String(format: localization.text("update.completed.message"),
                                        locale: localization.locale, arguments: [version]))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .padding(.top, 4)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.leading, contentLeadingInset)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .task {
                guard version != nil else { return }
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    showsUpdateCompletion = false
                }
            }
    }
}
