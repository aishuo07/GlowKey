import CoreGraphics
import Foundation
import GlowKeyCore

final class GlowKeyDaemon: @unchecked Sendable {
    private let stateStore = RuntimeStateStore()
    private let controller = GlowKeyController()
    private var lastApply = Date.distantPast

    func run() {
        writePID()
        installDisplayCallback()
        reapply(reason: "startup")
        CFRunLoopRun()
    }

    private func writePID() {
        let paths = RuntimePaths()
        try? paths.ensureDirectory()
        try? "\(getpid())\n".write(to: paths.daemonPIDURL, atomically: true, encoding: .utf8)
    }

    private func installDisplayCallback() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard flags.intersection([.addFlag, .removeFlag, .setModeFlag, .enabledFlag, .disabledFlag]) != [] else {
                return
            }
            guard let userInfo else {
                return
            }
            let daemon = Unmanaged<GlowKeyDaemon>.fromOpaque(userInfo).takeUnretainedValue()
            daemon.scheduleReapply()
        }, pointer)
    }

    private func scheduleReapply() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.reapply(reason: "display-change")
        }
    }

    private func reapply(reason: String) {
        guard Date().timeIntervalSince(lastApply) > 0.5 else {
            return
        }
        lastApply = Date()

        guard let state = try? stateStore.load() else {
            return
        }

        let displays = (try? controller.displays()) ?? []
        var appliedDisplayIDs = Set<String>()
        for display in displays {
            let id = String(display.id)
            guard let brightness = state.displayBrightness[id] ?? state.displayBrightness[display.uuid] else {
                continue
            }
            appliedDisplayIDs.insert(id)
            applyStoredBrightness(brightness, selector: id)
        }

        if appliedDisplayIDs.isEmpty {
            applyStoredBrightness(state.brightness, selector: state.selector)
        }
    }

    private func applyStoredBrightness(_ percentage: Int, selector: String) {
        _ = try? controller.applyBrightness(Brightness(percentage), selector: DisplaySelector(selector))
    }
}

GlowKeyDaemon().run()
