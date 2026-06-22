import AppKit
import CoreGraphics
import Foundation
import GlowKeyCore

@MainActor
final class ShadeAgent: NSObject, NSApplicationDelegate {
    private let store = RuntimeStateStore()
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var timer: Timer?
    private var currentOpacity: CGFloat = 0
    private var idleTicks = 0

    private let tickInterval: TimeInterval = 1.0 / 60.0
    private let fadeFactor: CGFloat = 0.32
    private let idleExitTicks = 18

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        update()
        timer = Timer.scheduledTimer(
            timeInterval: tickInterval,
            target: self,
            selector: #selector(timerFired(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func timerFired(_ timer: Timer) {
        update()
    }

    private func update() {
        let state = (try? store.load()) ?? .defaultValue
        let shadeBrightness = state.overlayBrightness ?? state.brightness
        let targetOpacity = state.overlayEnabled && shadeBrightness < 100
            ? min(0.95, max(0, CGFloat(100 - shadeBrightness) / 100))
            : 0
        currentOpacity += (targetOpacity - currentOpacity) * fadeFactor
        if abs(currentOpacity - targetOpacity) < 0.002 {
            currentOpacity = targetOpacity
        }

        if currentOpacity <= 0.002, targetOpacity == 0 {
            closeAllWindows()
            idleTicks += 1
            if idleTicks >= idleExitTicks {
                NSApp.terminate(nil)
            }
            return
        }

        idleTicks = 0
        var activeDisplayIDs = Set<CGDirectDisplayID>()

        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else {
                continue
            }

            guard shouldShade(displayID: displayID, state: state) else {
                continue
            }

            activeDisplayIDs.insert(displayID)
            let window = windows[displayID] ?? makeWindow(for: screen)
            windows[displayID] = window

            if window.frame != screen.frame {
                window.setFrame(screen.frame, display: true)
            }

            window.contentView?.layer?.backgroundColor = NSColor.black.withAlphaComponent(currentOpacity).cgColor
            window.orderFrontRegardless()
        }

        for (displayID, window) in windows where !activeDisplayIDs.contains(displayID) {
            window.close()
            windows.removeValue(forKey: displayID)
        }
    }

    private func shouldShade(displayID: CGDirectDisplayID, state: RuntimeState) -> Bool {
        let selector = state.selector.lowercased()
        if selector == "all" {
            return true
        }

        if selector == "external" || selector == "externals" {
            return CGDisplayIsBuiltin(displayID) == 0
        }

        if let selectedDisplayID = CGDirectDisplayID(selector) {
            return selectedDisplayID == displayID
        }

        let displayFingerprint = "\(CGDisplayVendorNumber(displayID))-\(CGDisplayModelNumber(displayID))-\(CGDisplaySerialNumber(displayID))-\(displayID)"
        return displayFingerprint.localizedCaseInsensitiveContains(selector)
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]

        let contentView = NSView(frame: screen.frame)
        contentView.wantsLayer = true
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        return window
    }

    private func closeAllWindows() {
        for window in windows.values {
            window.close()
        }
        windows.removeAll()
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}

let app = NSApplication.shared
let delegate = ShadeAgent()
app.delegate = delegate
app.run()
