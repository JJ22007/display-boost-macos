import AppKit
import CoreGraphics

extension NSScreen {
    var displayBoostID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

enum DisplayLookup {
    static var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let displayID = screen.displayBoostID else { return false }
            return CGDisplayIsBuiltin(displayID) != 0
        }
    }

    static func screen(displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayBoostID == displayID }
    }
}
