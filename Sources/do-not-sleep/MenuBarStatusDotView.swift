import AppKit

final class MenuBarStatusDotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class MenuBarSetupProgressView: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
