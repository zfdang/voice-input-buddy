import AppKit
import Combine
import CoreBluetooth
import SwiftUI

struct OnboardingTranscriptFocusSnapshot: Equatable {
    let editorMounted: Bool
    let windowKey: Bool
    let firstResponder: Bool
}

struct OnboardingTranscriptEditor: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let isActive: Bool
    let commitRequest: Int
    let onManualInput: () -> Void
    let onTextStateChanged: (String) -> Void
    let onFocusStateChanged: (OnboardingTranscriptFocusSnapshot) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = OnboardingTranscriptScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        let textView = OnboardingTranscriptTextView(frame: .zero)
        textView.onPhysicalEdit = { [weak coordinator = context.coordinator] in
            coordinator?.recordPhysicalEdit()
        }
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        scrollView.documentView = textView

        context.coordinator.attach(scrollView: scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(parent: self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: OnboardingTranscriptEditor
        private weak var scrollView: OnboardingTranscriptScrollView?
        private weak var textView: NSTextView?
        private var isDetached = false
        private var appliedFocusRequest: Int?
        private var appliedCommitRequest: Int?
        private var lastPublishedSnapshot: OnboardingTranscriptFocusSnapshot?

        init(parent: OnboardingTranscriptEditor) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowFocusChanged),
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowFocusChanged),
                name: NSWindow.didResignKeyNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        fileprivate func attach(scrollView: OnboardingTranscriptScrollView, textView: NSTextView) {
            isDetached = false
            self.scrollView = scrollView
            self.textView = textView
            scrollView.didMoveToWindowHandler = { [weak self] in
                self?.applyFocusRequestIfPossible()
                self?.publishFocusSnapshot()
            }
            applyFocusRequestIfPossible()
            publishFocusSnapshot()
        }

        func update(parent: OnboardingTranscriptEditor) {
            self.parent = parent
            if appliedCommitRequest != parent.commitRequest {
                appliedCommitRequest = parent.commitRequest
                commitMarkedTextIfNeeded()
            }
            if let textView,
               !textView.hasMarkedText(),
               textView.string != parent.text {
                textView.string = parent.text
            }
            applyFocusRequestIfPossible()
            publishFocusSnapshot()
        }

        func detach() {
            isDetached = true
            (textView as? OnboardingTranscriptTextView)?.onPhysicalEdit = nil
            textView?.delegate = nil
            scrollView?.didMoveToWindowHandler = nil
            scrollView = nil
            textView = nil
        }

        func recordPhysicalEdit() {
            guard !isDetached, parent.isActive else { return }
            parent.onManualInput()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let updatedText = textView.string
            parent.onTextStateChanged(updatedText)
            guard parent.text != updatedText else { return }
            parent.text = updatedText
        }

        func textDidBeginEditing(_ notification: Notification) {
            publishFocusSnapshot()
        }

        func textDidEndEditing(_ notification: Notification) {
            publishFocusSnapshot()
        }

        @objc private func windowFocusChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  window === scrollView?.window else { return }
            applyFocusRequestIfPossible()
            publishFocusSnapshot()
        }

        private func applyFocusRequestIfPossible() {
            guard parent.isActive,
                  appliedFocusRequest != parent.focusRequest,
                  let textView,
                  let window = textView.window else { return }
            if window.makeFirstResponder(textView) {
                appliedFocusRequest = parent.focusRequest
            }
        }

        private func commitMarkedTextIfNeeded() {
            guard let textView, textView.hasMarkedText() else { return }
            textView.unmarkText()
            let committedText = textView.string
            parent.onTextStateChanged(committedText)
            if parent.text != committedText {
                parent.text = committedText
            }
            AppLogger.shared.write(
                "ONBOARDING TRANSCRIPT marked_text_commit=true"
            )
        }

        private func publishFocusSnapshot() {
            let snapshot = OnboardingTranscriptFocusSnapshot(
                editorMounted: textView?.window != nil,
                windowKey: textView?.window?.isKeyWindow == true,
                firstResponder: textView?.window?.firstResponder === textView
            )
            guard snapshot != lastPublishedSnapshot else { return }
            lastPublishedSnapshot = snapshot
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDetached else { return }
                self.parent.onFocusStateChanged(snapshot)
            }
        }
    }
}

private final class OnboardingTranscriptScrollView: NSScrollView {
    var didMoveToWindowHandler: (() -> Void)?

    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        var frame = textView.frame
        let targetWidth = contentSize.width
        let targetHeight = max(frame.height, contentSize.height)
        guard frame.width != targetWidth || frame.height != targetHeight else { return }
        frame.size = NSSize(width: targetWidth, height: targetHeight)
        textView.frame = frame
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        didMoveToWindowHandler?()
    }
}

/// Observe the originating event before AppKit/IME processing or SwiftUI scheduling.
/// Keeping this at keyDown also covers IME marked text committed on a later event.
private final class OnboardingTranscriptTextView: NSTextView {
    var onPhysicalEdit: (() -> Void)?

    override func paste(_ sender: Any?) {
        recordPasteOrigin()
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        recordPasteOrigin()
        super.pasteAsPlainText(sender)
    }

    private func recordPasteOrigin() {
        let event = NSApp.currentEvent
        if OnboardingTranscriptInputPolicy.isManualPaste(
            eventTypeRawValue: event?.type.rawValue,
            sourceStateID: event?.cgEvent?.getIntegerValueField(.eventSourceStateID),
            sourceUnixProcessID: event?.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)) {
            onPhysicalEdit?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: event.type.rawValue,
            sourceStateID: event.cgEvent?.getIntegerValueField(.eventSourceStateID),
            sourceUnixProcessID: event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)
        ), OnboardingTranscriptInputPolicy.canEditText(keyCode: event.keyCode,
            characters: event.characters, commandHeld: event.modifierFlags.contains(.command)) {
            onPhysicalEdit?()
        }
        super.keyDown(with: event)
    }
}
