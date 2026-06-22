import CoreGraphics
import Foundation
import GlowKeyCore

final class GlowKeyDaemon: @unchecked Sendable {
    private let stateStore = RuntimeStateStore()
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

        let displays = (try? GlowKeyController().displays()) ?? []
        var appliedDisplayIDs = Set<String>()
        for display in displays {
            let id = String(display.id)
            guard let brightness = state.displayBrightness[id] ?? state.displayBrightness[display.uuid] else {
                continue
            }
            appliedDisplayIDs.insert(id)
            runCLI(arguments: ["set", id, String(brightness)])
        }

        if appliedDisplayIDs.isEmpty {
            runCLI(arguments: ["set", state.selector, String(state.brightness)])
        }
    }

    private func runCLI(arguments: [String]) {
        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
        let candidate = currentExecutable.deletingLastPathComponent().appendingPathComponent("glowkey")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            return
        }

        let process = Process()
        process.executableURL = candidate
        process.arguments = arguments
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try? process.run()
        process.waitUntilExit()
    }
}

GlowKeyDaemon().run()
