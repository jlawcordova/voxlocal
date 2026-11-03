import AppKit
import SwiftUI
import VoxlocalCore

/// A borderless, click-through panel that floats above everything and never takes focus,
/// so the app you're typing in stays key.
final class OverlayPanel: NSPanel {
    init(size: CGSize, content: some View) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        alphaValue = 0
        let host = NSHostingView(rootView: content)
        // Keep the panel at the size we position it by; by default the hosting view would
        // resize the window to fit its content and shift the anchor.
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the pill and caret dot while a dictation is active, and follows the caret.
/// Everything here is display only: the pipeline never waits on it.
@MainActor
final class OverlayController {
    private let state: DictationState
    private let settings: AppSettings
    private let placement = OverlayPlacement()
    private lazy var pill = OverlayPanel(size: OverlayLayout.pillPanelSize,
                                         content: OverlayView(state: state, settings: settings, placement: placement))
    private lazy var dot = OverlayPanel(size: OverlayLayout.dotPanelSize, content: CaretDotView(state: state))

    private var pollTimer: Timer?
    private let axQueue = DispatchQueue(label: "voxlocal.caret", qos: .userInteractive)
    private var queryInFlight = false
    private var lastResult: CaretLocator.Result = .unavailable
    private var visible = false

    init(state: DictationState, settings: AppSettings) {
        self.state = state
        self.settings = settings
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = state.phase
            _ = settings.showPill
            _ = settings.showCaret
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.phaseChanged()
                self?.observe()
            }
        }
    }

    private func phaseChanged() {
        let wantsOverlay = state.phase.isActive && (settings.showPill || settings.showCaret)
        if wantsOverlay {
            startPolling()
        } else {
            stopPolling()
            setVisible(false)
        }
    }

    // MARK: - Caret polling (~15 Hz, only while active)

    private func startPolling() {
        guard pollTimer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard !queryInFlight else { return }
        guard Permissions.accessibilityGranted else {
            apply(.unavailable)
            return
        }
        queryInFlight = true
        let screens = NSScreen.screens.map(\.frame)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        axQueue.async { [weak self] in
            let result = CaretLocator.locate(primaryHeight: primaryHeight, screens: screens)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.queryInFlight = false
                    self?.apply(result)
                }
            }
        }
    }

    // MARK: - Placement

    private func apply(_ result: CaretLocator.Result) {
        lastResult = result
        guard state.phase.isActive else { return }

        // Never draw over a password field; the menu-bar icon still shows the state.
        if result == .secure {
            setVisible(false)
            return
        }

        let screens = NSScreen.screens
        let frames = screens.map(\.frame)
        let pillSize = OverlayLayout.pillPanelSize

        switch result {
        case .caret(let caret):
            let screen = ScreenGeometry.screen(containing: CGPoint(x: caret.midX, y: caret.midY), screens: frames)
            let visibleFrame = screens.first { $0.frame == screen }?.visibleFrame ?? screen ?? .zero
            // The panel has 6 pt of transparent margin above the pill (room for its shadow).
            let origin = ScreenGeometry.panelOrigin(below: caret, size: pillSize, visibleFrame: visibleFrame, gap: -2)
            placement.belowCaret = origin.y < caret.minY
            pill.setFrameOrigin(origin)
            let d = OverlayLayout.dotPanelSize
            dot.setFrameOrigin(CGPoint(x: caret.maxX + 3, y: caret.midY - d.height / 2))
            show(pill: settings.showPill, dot: settings.showCaret)

        case .unavailable, .secure:
            // Near the mouse pointer, else top-center of the screen it's on.
            let mouse = NSEvent.mouseLocation
            let screen = screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            guard let visibleFrame = screen?.visibleFrame else {
                setVisible(false)
                return
            }
            let anchor = CGRect(x: mouse.x, y: mouse.y - 12, width: 0, height: 24)
            let origin = visibleFrame.contains(mouse)
                ? ScreenGeometry.panelOrigin(below: anchor, size: pillSize, visibleFrame: visibleFrame, gap: 8)
                : ScreenGeometry.topCenterOrigin(size: pillSize, visibleFrame: visibleFrame)
            placement.belowCaret = true
            pill.setFrameOrigin(origin)
            show(pill: settings.showPill, dot: false)
        }
    }

    private func show(pill showPill: Bool, dot showDot: Bool) {
        if showPill { pill.orderFrontRegardless() } else { pill.orderOut(nil) }
        if showDot { dot.orderFrontRegardless() } else { dot.orderOut(nil) }
        if !visible { setVisible(true) }
    }

    private func setVisible(_ on: Bool) {
        visible = on
        let duration = 0.15
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            pill.animator().alphaValue = on ? 1 : 0
            dot.animator().alphaValue = on ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.visible else { return }
                self.pill.orderOut(nil)
                self.dot.orderOut(nil)
            }
        }
    }
}
