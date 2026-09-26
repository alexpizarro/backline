import BacklineKit
import AppKit

/// Single-key practice shortcuts (Space, L, K, R, 1–6, arrows, [ ]) handled with a local event monitor
/// instead of menu key equivalents, so they never steal keystrokes from a text field or a sheet.
@MainActor
final class KeyboardRouter {
    private var monitor: Any?
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let ev = event
            let handled = MainActor.assumeIsolated { self?.handle(ev) ?? false }
            return handled ? nil : event
        }
    }

    private func isEditingText() -> Bool {
        // Save/Open panels (remote views, not NSText) and any other modal session: hands off.
        if NSApp.modalWindow != nil { return true }
        guard let window = NSApp.keyWindow else { return !(model?.isMiniPlayer ?? false) }
        // Only the main window or the mini player may receive practice shortcuts.
        if !(window is MiniPanel) && window !== model?.mainWindow { return true }
        if window.attachedSheet != nil || window.isSheet { return true }
        return window.firstResponder is NSText
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let model, model.song != nil, model.screen == .mixer || model.isMiniPlayer, !isEditingText() else { return false }
        // ⌘⇧M and Esc leave the mini player from the panel too.
        if model.isMiniPlayer, event.keyCode == 53 { model.toggleMiniPlayer(); return true }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if mods == .command {
            switch event.keyCode {
            case 123: model.stepSpeed(-1); return true      // ⌘←
            case 124: model.stepSpeed(1); return true       // ⌘→
            case 125: model.stepPitch(-1); return true      // ⌘↓
            case 126: model.stepPitch(1); return true       // ⌘↑
            default: return false
            }
        }
        guard mods.isEmpty || mods == .shift else { return false }

        switch event.keyCode {
        case 49, 121: model.togglePlay(); return true                      // Space, PageDown (foot pedal)
        case 116: model.abPress(); return true                             // PageUp (foot pedal)
        case 123: model.nudge(bars: mods == .shift ? -4 : -1); return true // ←
        case 124: model.nudge(bars: mods == .shift ? 4 : 1); return true   // →
        case 36, 76: model.seek(to: model.loopRange?.lowerBound ?? 0); return true  // Return
        default: break
        }
        switch key {
        case "l": model.toggleLoop(); return true
        case "a": model.abPress(); return true
        case "g": if !model.settings.removed.isEmpty { model.settings.guide.toggle() }; return true
        case "k": model.settings.countIn.toggle(); return true
        case "c": model.settings.click.toggle(); return true
        case "r": model.settings.removed = []; model.settings.solo = nil; return true
        case "[": model.stepSpeed(-1); return true
        case "]": model.stepSpeed(1); return true
        case "-": model.stepPitch(-1); return true
        case "=", "+": model.stepPitch(1); return true
        default: break
        }
        // Digit row and keypad by physical key, so Shift (solo) and non-US layouts both work.
        let digitKeys: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6,
                                        83: 0, 84: 1, 85: 2, 86: 3, 87: 4, 88: 5, 89: 6]
        if let i = digitKeys[event.keyCode] {
            guard i < model.stems.count else { return false }
            if mods == .shift { model.toggleSolo(model.stems[i]) } else { model.toggle(model.stems[i]) }
            return true
        }
        return false
    }
}
