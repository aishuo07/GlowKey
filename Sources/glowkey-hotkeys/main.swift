import ApplicationServices
import CoreGraphics
import Foundation

private let defaultDownShortcut = "fn+f1"
private let defaultUpShortcut = "fn+f2"
private let fallbackDownShortcut = "cmd+opt+-"
private let fallbackUpShortcut = "cmd+opt+="

final class HotkeyAgent {
    private let glowkeyPath: String
    private let step: Int
    private let selector: String
    private let downShortcuts: [KeyboardShortcut]
    private let upShortcuts: [KeyboardShortcut]
    private let debug: Bool

    init(arguments: [String]) {
        self.glowkeyPath = Self.value(after: "--glowkey", in: arguments) ?? "glowkey"
        self.step = max(1, Int(Self.value(after: "--step", in: arguments) ?? "5") ?? 5)
        self.selector = Self.value(after: "--selector", in: arguments) ?? "cursor"
        self.downShortcuts = [
            KeyboardShortcut(Self.value(after: "--down", in: arguments) ?? defaultDownShortcut),
            KeyboardShortcut(fallbackDownShortcut)
        ].deduplicated()
        self.upShortcuts = [
            KeyboardShortcut(Self.value(after: "--up", in: arguments) ?? defaultUpShortcut),
            KeyboardShortcut(fallbackUpShortcut)
        ].deduplicated()
        self.debug = arguments.contains("--debug")
    }

    func run() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if debug {
            print("GlowKey hotkey helper")
            print("Accessibility trusted: \(trusted)")
            print("Down: \(downShortcuts.map(\.description).joined(separator: ", "))")
            print("Up: \(upShortcuts.map(\.description).joined(separator: ", "))")
            print("Target: \(selector)")
            print("Step: \(step)%")
            print("Listening. Press Control-C to stop.")
        }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            fputs("Unable to start hotkey listener. Enable Accessibility/Input Monitoring for glowkey-hotkeys or Terminal.\n", stderr)
            Foundation.exit(1)
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        CFRunLoopRun()
    }

    fileprivate func handle(event: CGEvent) {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if let shortcut = downShortcuts.first(where: { $0.matches(keyCode: keyCode, flags: flags) }) {
            if debug {
                print("Matched down: \(shortcut.description)")
            }
            runGlowKey(direction: "down")
        } else if let shortcut = upShortcuts.first(where: { $0.matches(keyCode: keyCode, flags: flags) }) {
            if debug {
                print("Matched up: \(shortcut.description)")
            }
            runGlowKey(direction: "up")
        } else if debug, flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty == false {
            print("Ignored keyCode=\(keyCode) flags=\(flags.rawValue)")
        }
    }

    private func runGlowKey(direction: String) {
        guard let resolvedSelector = resolvedSelector() else {
            if debug {
                print("No external display under cursor.")
            }
            return
        }

        runGlowKey(arguments: [direction, resolvedSelector, String(step)])
    }

    private func resolvedSelector() -> String? {
        switch selector.lowercased() {
        case "cursor", "mouse", "pointer", "active":
            cursorExternalDisplayID().map(String.init)
        default:
            selector
        }
    }

    private func runGlowKey(arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: glowkeyPath)
        process.arguments = arguments
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        if debug {
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        } else {
            process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        }

        try? process.run()
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }

        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return nil
        }

        return arguments[valueIndex]
    }
}

private struct KeyboardShortcut: Equatable {
    let keyCode: UInt32
    let requiredFlags: CGEventFlags
    let description: String

    init(_ rawValue: String) {
        self.description = rawValue

        let parts = rawValue
            .lowercased()
            .split(separator: "+")
            .map(String.init)

        var flags: CGEventFlags = []
        var keyToken = parts.last ?? "="

        for part in parts.dropLast() {
            switch part {
            case "cmd", "command":
                flags.insert(.maskCommand)
            case "opt", "option", "alt":
                flags.insert(.maskAlternate)
            case "ctrl", "control":
                flags.insert(.maskControl)
            case "shift":
                flags.insert(.maskShift)
            case "fn", "function":
                flags.insert(.maskSecondaryFn)
            default:
                keyToken = part
            }
        }

        self.requiredFlags = flags
        self.keyCode = keyboardKeyCode(for: keyToken)
    }

    func matches(keyCode: UInt32, flags: CGEventFlags) -> Bool {
        guard keyCode == self.keyCode else {
            return false
        }

        return flags.contains(requiredFlags)
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let agent = Unmanaged<HotkeyAgent>.fromOpaque(userInfo).takeUnretainedValue()
    agent.handle(event: event)
    return Unmanaged.passUnretained(event)
}

private func keyboardKeyCode(for key: String) -> UInt32 {
    switch key {
    case "f1":
        return 122
    case "f2":
        return 120
    case "-", "minus":
        return 27
    case "=", "plus", "equal", "equals":
        return 24
    case "[", "leftbracket":
        return 33
    case "]", "rightbracket":
        return 30
    case ";", "semicolon":
        return 41
    case "'", "quote":
        return 39
    case ",", "comma":
        return 43
    case ".", "period":
        return 47
    case "/", "slash":
        return 44
    default:
        return key.count == 1 ? letterKeyCode(for: key) : 24
    }
}

private func cursorExternalDisplayID() -> CGDirectDisplayID? {
    guard let point = CGEvent(source: nil)?.location else {
        return nil
    }

    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
        return nil
    }

    var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
    guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
        return nil
    }

    return displays
        .prefix(Int(count))
        .filter { CGDisplayIsBuiltin($0) == 0 }
        .first { CGDisplayBounds($0).contains(point) }
}

private extension Array where Element == KeyboardShortcut {
    func deduplicated() -> [KeyboardShortcut] {
        reduce(into: []) { result, shortcut in
            if !result.contains(shortcut) {
                result.append(shortcut)
            }
        }
    }
}

private func letterKeyCode(for key: String) -> UInt32 {
    switch key {
    case "a": return 0
    case "s": return 1
    case "d": return 2
    case "f": return 3
    case "h": return 4
    case "g": return 5
    case "z": return 6
    case "x": return 7
    case "c": return 8
    case "v": return 9
    case "b": return 11
    case "q": return 12
    case "w": return 13
    case "e": return 14
    case "r": return 15
    case "y": return 16
    case "t": return 17
    case "o": return 31
    case "u": return 32
    case "i": return 34
    case "p": return 35
    case "l": return 37
    case "j": return 38
    case "k": return 40
    case "n": return 45
    case "m": return 46
    default: return 24
    }
}

let agent = HotkeyAgent(arguments: Array(CommandLine.arguments.dropFirst()))
agent.run()
