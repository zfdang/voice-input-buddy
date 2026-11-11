import SwiftUI

/// What a phrase key shows. Brand keys use plain text, never vendor logos.
enum CommonPhraseKeyGlyph: Equatable {
    case text(String)
    case symbol(String)
    case input

    static func glyph(for button: RemoteButton) -> CommonPhraseKeyGlyph {
        switch button {
        case .ok: .text("OK")
        case .youtube: .text("YouTube")
        case .netflix: .text("NETFLIX")
        case .up: .symbol("chevron.up")
        case .down: .symbol("chevron.down")
        case .left: .symbol("chevron.left")
        case .right: .symbol("chevron.right")
        case .home: .symbol("house")
        case .mute: .symbol("speaker.slash")
        case .power: .symbol("power")
        case .input: .input
        default: .symbol("circle")
        }
    }
}

struct CommonPhraseKeyGlyphView: View {
    let button: RemoteButton
    var symbolSize: CGFloat
    var textSize: CGFloat

    var body: some View {
        switch CommonPhraseKeyGlyph.glyph(for: button) {
        case let .text(value):
            Text(value).font(.system(size: textSize, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.5)
        case let .symbol(name):
            Image(systemName: name).symbolVariant(.fill)
                .font(.system(size: symbolSize, weight: .semibold))
        case .input:
            RemoteInputGlyph(size: symbolSize * 1.15)
        }
    }
}

/// The Chromecast-only keys below the directional pad, two per row as on the
/// remote. Like `CommonPhrasePad`, callers decide whether a press inserts text
/// or selects the assignment position.
struct CommonPhraseKeyGrid: View {
    @ObservedObject var store: CommonPhraseStore
    var buttons: [RemoteButton]
    var keyDiameter: CGFloat
    var selectedButton: RemoteButton? = nil
    var onSelect: (RemoteButton) -> Void
    @EnvironmentObject private var localization: LocalizationStore

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(stride(from: 0, to: buttons.count, by: 2)), id: \.self) { index in
                GridRow {
                    key(buttons[index])
                    if index + 1 < buttons.count { key(buttons[index + 1]) }
                }
            }
        }
    }

    private func key(_ button: RemoteButton) -> some View {
        let selected = selectedButton == button
        return Button { onSelect(button) } label: {
            VStack(spacing: 5) {
                CommonPhraseKeyGlyphView(button: button, symbolSize: keyDiameter * 0.38,
                                         textSize: keyDiameter * 0.27)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(width: keyDiameter, height: keyDiameter)
                    .background(
                        LinearGradient(colors: [Color(white: 0.19), Color(white: 0.085)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Circle()
                    )
                    .overlay(Circle().stroke(selected ? Color.accentColor : Color.white.opacity(0.22),
                                             lineWidth: selected ? 2 : 1))
                Text(store.phrase(for: button)?.label ?? localization.text("common_phrases.unassigned"))
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: keyDiameter * 1.6, maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localization.text("common_phrases.key.\(button.rawValue)"))
        .accessibilityValue(store.phrase(for: button)?.label ?? localization.text("common_phrases.unassigned"))
        .accessibilityIdentifier("common-phrases-position-\(button.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
