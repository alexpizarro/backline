import AppKit
import BacklineKit
import SwiftUI

/// Floating mini player as an AppKit panel: stays above other apps (and full-screen spaces), can take
/// keyboard focus for Space / pedals without activating Backline, and remembers where it was put.
@MainActor
final class MiniPlayerController {
    private var panel: MiniPanel?
    private weak var model: AppModel?
    private weak var mainWindow: NSWindow?
    private var mainFrame: NSRect?

    init(model: AppModel) { self.model = model }

    var isShown: Bool { panel?.isVisible == true }

    func show(from main: NSWindow?) {
        guard let model else { return }
        mainWindow = main ?? mainWindow
        if let w = mainWindow {
            mainFrame = w.frame
            w.orderOut(nil)
        }
        let p = panel ?? makePanel(model: model)
        panel = p
        p.orderFrontRegardless()
        p.makeKey()
        model.enterMiniPlayer()
    }

    func hide() {
        panel?.orderOut(nil)
        model?.exitMiniPlayer()
        if let w = mainWindow {
            if let f = mainFrame { w.setFrame(f, display: false) }
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func toggle(from main: NSWindow?) { isShown ? hide() : show(from: main) }

    private func makePanel(model: AppModel) -> MiniPanel {
        let host = NSHostingView(rootView: MiniPlayerView(onExpand: { [weak self] in self?.hide() })
            .environment(model)
            .preferredColorScheme(.dark))
        host.sizingOptions = [.intrinsicContentSize]
        let size = host.fittingSize
        let p = MiniPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                          backing: .buffered, defer: false)
        p.contentView = host
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.title = "Backline Mini Player"
        if !p.setFrameUsingName("BacklineMiniPlayer") {
            if let screen = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.minY + 16))
            }
        }
        p.setFrameAutosaveName("BacklineMiniPlayer")
        // Keep it on screen if displays changed since last time.
        if let vf = (p.screen ?? NSScreen.main)?.visibleFrame, !vf.intersects(p.frame) {
            p.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 16, y: vf.minY + 16))
        }
        return p
    }
}

final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
