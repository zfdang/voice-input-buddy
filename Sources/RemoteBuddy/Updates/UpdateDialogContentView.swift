import AppKit

struct UpdateDialogVersionRow: Equatable {
    let label: String
    let version: String
}

/// A compact native dialog with separate status, version and action regions.
@MainActor
final class UpdateDialogContentView: NSView {
    let actionButtons: [NSButton]
    private(set) var progressIndicator: NSProgressIndicator?
    private var progressStatusLabel: NSTextField?
    private let content = NSStackView()
    private let preferredWidth: CGFloat

    func updateProgress(_ value: Double, text: String?) {
        guard let indicator = progressIndicator else { return }
        indicator.isIndeterminate = value < 0
        indicator.doubleValue = max(0, min(1, value))
        if indicator.isIndeterminate { indicator.startAnimation(nil) } else { indicator.stopAnimation(nil) }
        if let text { progressStatusLabel?.stringValue = text }
    }

    init(title: String, message: String, symbol: String, tint: NSColor,
         versions: [UpdateDialogVersionRow], progress: Double?, progressText: String?,
         diagnostic: String?, historyButton: NSButton?, actions: [NSButton]) {
        actionButtons = actions
        let actionRow = NSStackView(views: actions)
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 10
        for button in actions {
            button.font = .systemFont(ofSize: 13)
            button.controlSize = .large
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let historyWidth = historyButton.map { $0.intrinsicContentSize.width + 16 } ?? 0
        preferredWidth = max(520, actionRow.fittingSize.width + historyWidth + 56)
        super.init(frame: .zero)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 20
        let contentWidth = preferredWidth - 56

        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .medium))
        image.contentTintColor = tint
        image.imageScaling = .scaleProportionallyDown
        let icon = NSBox()
        icon.boxType = .custom
        icon.borderWidth = 0
        icon.cornerRadius = 15
        icon.fillColor = tint.withAlphaComponent(0.1)
        icon.contentViewMargins = .zero
        icon.contentView = image
        icon.widthAnchor.constraint(equalToConstant: 60).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 60).isActive = true

        let heading = Self.label(title, font: .systemFont(ofSize: 21, weight: .semibold))
        let description = Self.label(message, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
        let text = NSStackView(views: [heading, description])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 8
        for label in [heading, description] {
            label.widthAnchor.constraint(equalToConstant: contentWidth - 78).isActive = true
        }
        let header = NSStackView(views: [icon, text])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 18
        content.addArrangedSubview(header)

        let versionStack = NSStackView()
        versionStack.orientation = .vertical
        versionStack.alignment = .leading
        versionStack.spacing = 14
        for version in versions {
            let label = Self.label(version.label, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            let value = Self.label(version.version, font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium))
            value.isSelectable = true
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [label, spacer, value])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 12
            row.widthAnchor.constraint(equalToConstant: contentWidth - 32).isActive = true
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            versionStack.addArrangedSubview(row)
        }
        let card = NSBox()
        card.boxType = .custom
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        card.cornerRadius = 10
        card.contentViewMargins = NSSize(width: 16, height: 16)
        card.contentView = versionStack
        card.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        card.heightAnchor.constraint(equalToConstant: versionStack.fittingSize.height + 32).isActive = true
        content.addArrangedSubview(card)

        if let progress {
            let indicator = NSProgressIndicator()
            progressIndicator = indicator
            indicator.style = .bar
            indicator.isIndeterminate = progress < 0
            indicator.minValue = 0
            indicator.maxValue = 1
            indicator.doubleValue = progress
            indicator.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            let status = NSStackView(views: [indicator])
            status.orientation = .vertical
            status.alignment = .trailing
            status.spacing = 8
            if let progressText {
                let label = Self.label(progressText,
                    font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)
                progressStatusLabel = label
                status.addArrangedSubview(label)
            }
            content.addArrangedSubview(status)
            if indicator.isIndeterminate { indicator.startAnimation(nil) }
        }
        if let diagnostic {
            let label = Self.label(diagnostic, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
            label.isSelectable = true
            label.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            content.addArrangedSubview(label)
        }

        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        content.addArrangedSubview(divider)
        let footer = NSView()
        footer.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        if let historyButton {
            historyButton.isBordered = false
            historyButton.font = .systemFont(ofSize: 12)
            historyButton.contentTintColor = .linkColor
            footer.addSubview(historyButton)
            historyButton.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                historyButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
                historyButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            ])
        }
        footer.addSubview(actionRow)
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            actionRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            actionRow.topAnchor.constraint(equalTo: footer.topAnchor),
            actionRow.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            actionRow.leadingAnchor.constraint(greaterThanOrEqualTo: historyButton?.trailingAnchor ?? footer.leadingAnchor,
                                               constant: historyButton == nil ? 0 : 16),
        ])
        content.addArrangedSubview(footer)
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    var preferredSize: NSSize {
        NSSize(width: preferredWidth, height: max(252, content.fittingSize.height + 52))
    }

    private static func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
}
