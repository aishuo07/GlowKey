import AppKit
import Darwin
import Foundation
import GlowKeyCore

struct GlowKeyCLI {
    static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }

        let controller = GlowKeyController()
        let stateStore = RuntimeStateStore()
        let shadeProcessManager = ShadeProcessManager()
        let hotkeyProcessManager = HotkeyProcessManager()
        let daemonProcessManager = DaemonProcessManager()
        let menuBarProcessManager = MenuBarProcessManager()
        let rest = Array(arguments.dropFirst())

        switch command {
        case "displays", "list":
            let json = rest.contains("--json")
            let displays = try controller.displays()
            json ? printDisplaysJSON(displays) : printDisplays(displays)

        case "doctor":
            let json = rest.contains("--json")
            let statuses = try controller.controlStatuses()
            json ? printStatusesJSON(statuses) : printStatuses(statuses)

        case "status":
            let json = rest.contains("--json")
            let debug = rest.contains("--debug")
            let state = try stateStore.load()
            let displays = try controller.displays()
            let shadeStatus = shadeProcessManager.status()
            let hotkeyStatus = hotkeyProcessManager.status()
            if json {
                printRuntimeStatusJSON(state, displays: displays, shadeStatus: shadeStatus, hotkeyStatus: hotkeyStatus)
            } else if debug {
                printRuntimeStatusDebug(state, shadeStatus: shadeStatus, hotkeyStatus: hotkeyStatus)
            } else {
                printRuntimeStatus(state, displays: displays, hotkeyStatus: hotkeyStatus)
            }

        case "hotkeys":
            try handleHotkeysCommand(rest, manager: hotkeyProcessManager, controller: controller)

        case "daemon":
            try handleDaemonCommand(rest, manager: daemonProcessManager)

        case "menubar":
            try handleMenuBarCommand(rest, manager: menuBarProcessManager)

        case "sync":
            try handleSyncCommand(rest, stateStore: stateStore)

        case "install":
            let skipMenuBarStart = rest.contains("--skip-menubar-start")
            stopLegacyProcesses()
            let installedAppURL = try installUserArtifacts()
            try daemonProcessManager.installLaunchAgent()
            if !skipMenuBarStart {
                try menuBarProcessManager.start()
            }
            try hotkeyProcessManager.start(
                step: 5,
                selector: "cursor",
                downShortcut: "fn+f1",
                upShortcut: "fn+f2"
            )
            Thread.sleep(forTimeInterval: 0.2)
            print("GlowKey installed for this user.")
            print("App: \(installedAppURL.path)")
            print("CLI: ~/bin/glowkey")
            print("Background mode: on")
            print("Menu bar: \(skipMenuBarStart ? "already running" : (menuBarProcessManager.status().isRunning ? "on" : "off"))")
            print("Shortcuts: \(hotkeyProcessManager.status().isRunning ? "on" : "needs permission")")

        case "uninstall":
            hotkeyProcessManager.stop()
            menuBarProcessManager.stop()
            daemonProcessManager.uninstallLaunchAgent()
            shadeProcessManager.stopIfRunning()
            stopLegacyProcesses()
            print("GlowKey background services stopped.")

        case "debug":
            try handleDebugCommand(rest)

        case "set":
            let request = try parseSetRequest(rest)
            let selectorArgument = try resolveSelectorArgument(request.selectorArgument, controller: controller)
            let brightness = Brightness(request.percentage)
            try applyBrightness(
                brightness,
                selectorArgument: selectorArgument,
                controller: controller,
                stateStore: stateStore,
                shadeProcessManager: shadeProcessManager
            )
            print("Applied brightness \(brightness.percentage)%")

        case "up", "increase":
            let request = try parseRelativeRequest(rest)
            let selectorArgument = try resolveSelectorArgument(request.selectorArgument, controller: controller)
            let current = try stateStore.load()
            let brightness = Brightness(currentBrightness(in: current, selectorArgument: selectorArgument) + request.step)
            try applyBrightness(
                brightness,
                selectorArgument: selectorArgument,
                controller: controller,
                stateStore: stateStore,
                shadeProcessManager: shadeProcessManager
            )
            print("Applied brightness \(brightness.percentage)%")

        case "down", "decrease":
            let request = try parseRelativeRequest(rest)
            let selectorArgument = try resolveSelectorArgument(request.selectorArgument, controller: controller)
            let current = try stateStore.load()
            let brightness = Brightness(currentBrightness(in: current, selectorArgument: selectorArgument) - request.step)
            try applyBrightness(
                brightness,
                selectorArgument: selectorArgument,
                controller: controller,
                stateStore: stateStore,
                shadeProcessManager: shadeProcessManager
            )
            print("Applied brightness \(brightness.percentage)%")

        case "reset":
            let selectorArgument = try resolveSelectorArgument(rest.first ?? "all", controller: controller)
            let selector = DisplaySelector(selectorArgument)
            let previousState = (try? stateStore.load()) ?? .defaultValue
            let displayBrightness = try displayBrightnessAfterApplying(
                existing: previousState.displayBrightness,
                selectorArgument: selectorArgument,
                brightness: 100,
                controller: controller
            )
            shadeProcessManager.stopIfRunning()
            try stateStore.save(RuntimeState(
                brightness: 100,
                selector: selectorArgument,
                displayBrightness: displayBrightness,
                overlayEnabled: false,
                method: .normalBrightness,
                syncExternalDisplays: previousState.syncExternalDisplays
            ))
            try? controller.reset(selector: selector)
            print("Restored display color settings")

        case "help", "-h", "--help":
            printHelp()

        default:
            throw CLIError.invalidUsage("Unknown command '\(command)'. Run `glowkey help`.")
        }
    }

    private static func printDisplays(_ displays: [Display]) {
        if displays.isEmpty {
            print("No displays found. If you are running inside an automation or remote shell, macOS may hide the active display session.")
            return
        }

        for display in displays {
            print("\(display.name)")
            print("  id: \(display.id)")
            print("  uuid: \(display.uuid)")
            print("  type: \(display.kindDescription)")
            print("  resolution: \(display.resolutionDescription)")
            print("  vendor/model/serial: \(display.vendorID)/\(display.modelID)/\(display.serialNumber)")
        }
    }

    private static func printStatuses(_ statuses: [DisplayControlStatus]) {
        if statuses.isEmpty {
            print("No displays found. If you are running inside an automation or remote shell, macOS may hide the active display session.")
            return
        }

        for status in statuses {
            print("\(status.display.name): \(publicQualityLabel(for: status.quality))")
            print("  \(status.userMessage)")
            if let suggestion = status.suggestion {
                print("  Tip: \(suggestion)")
            }
        }
    }

    private static func printDisplaysJSON(_ displays: [Display]) {
        let rows = displays.map { display in
            [
                "id": String(display.id),
                "uuid": display.uuid,
                "name": display.name,
                "type": display.kindDescription,
                "resolution": display.resolutionDescription,
                "vendorID": String(display.vendorID),
                "modelID": String(display.modelID),
                "serialNumber": String(display.serialNumber)
            ]
        }
        printJSON(rows)
    }

    private static func printStatusesJSON(_ statuses: [DisplayControlStatus]) {
        let rows = statuses.map { status in
            [
                "id": String(status.display.id),
                "uuid": status.display.uuid,
                "name": status.display.name,
                "quality": status.quality.rawValue,
                "message": status.userMessage,
                "suggestion": status.suggestion ?? ""
            ]
        }
        printJSON(rows)
    }

    private static func printJSON(_ value: [[String: String]]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else {
            print("[]")
            return
        }
        print(string)
    }

    private static func printHelp() {
        print(
            """
            GlowKey

            Keyboard brightness control for external displays without breaking native Mac brightness.

            Commands:
              glowkey displays [--json]
              glowkey doctor [--json]
              glowkey status [--json|--debug]
              glowkey sync on|off|toggle
              glowkey daemon start|stop|status
              glowkey menubar start|stop|status
              glowkey hotkeys start [step] [target]
              glowkey hotkeys start --target <external|display-id|uuid>
              glowkey hotkeys start [step] [target] --down <shortcut> --up <shortcut>
              glowkey hotkeys debug [step] [target]
              glowkey hotkeys stop
              glowkey hotkeys status
              glowkey set <0-100>
              glowkey set <all|external|display-id|display-name|uuid> <0-100>
              glowkey up [step]
              glowkey up <all|external|display-id|display-name|uuid> [step]
              glowkey down [step]
              glowkey down <all|external|display-id|display-name|uuid> [step]
              glowkey reset [all|external|display-id|display-name|uuid]
              glowkey install
              glowkey uninstall
              glowkey help
            """
        )
    }

    private static func printRuntimeStatus(
        _ state: RuntimeState,
        displays: [Display],
        hotkeyStatus: HotkeyProcessStatus
    ) {
        if displays.isEmpty {
            print("No displays found.")
        } else {
            for display in displays {
                print("\(publicDisplayName(display)): \(brightness(for: display, in: state))%")
            }
        }
        print("Sync displays: \(state.syncExternalDisplays ? "on" : "off")")
        print("Shortcuts: \(hotkeyStatus.isRunning ? "on" : "off")")
    }

    private static func printRuntimeStatusDebug(
        _ state: RuntimeState,
        shadeStatus: ShadeProcessStatus,
        hotkeyStatus: HotkeyProcessStatus
    ) {
        print("Brightness: \(state.brightness)%")
        print("Target: \(state.selector)")
        print("Active method: \(state.method.rawValue)")
        if let overlayBrightness = state.overlayBrightness {
            print("Overlay brightness: \(overlayBrightness)%")
        } else {
            print("Overlay brightness: none")
        }

        if shadeStatus.isRunning {
            let pidText = shadeStatus.pid.map(String.init) ?? "unknown"
            let orphanText = shadeStatus.isOrphaned ? " orphaned" : ""
            print("Shade helper: running\(orphanText) (pid \(pidText))")
        } else {
            print("Shade helper: stopped")
        }

        if shadeStatus.stalePIDRemoved {
            print("Note: cleaned up a stale shade helper PID file.")
        }

        if hotkeyStatus.isRunning {
            let pidText = hotkeyStatus.pid.map(String.init) ?? "unknown"
            let orphanText = hotkeyStatus.isOrphaned ? " orphaned" : ""
            print("Hotkeys: running\(orphanText) (pid \(pidText))")
        } else {
            print("Hotkeys: stopped")
        }

        if hotkeyStatus.stalePIDRemoved {
            print("Note: cleaned up a stale hotkey helper PID file.")
        }
    }

    private static func printRuntimeStatusJSON(
        _ state: RuntimeState,
        displays: [Display],
        shadeStatus: ShadeProcessStatus,
        hotkeyStatus: HotkeyProcessStatus
    ) {
        let rows = displays.map { display in
            [
                "id": String(display.id),
                "uuid": display.uuid,
                "name": publicDisplayName(display),
                "type": display.kindDescription,
                "brightness": String(brightness(for: display, in: state)),
                "target": state.selector,
                "mode": state.method.rawValue,
                "syncDisplays": String(state.syncExternalDisplays),
                "overlayBrightness": state.overlayBrightness.map(String.init) ?? "",
                "shadeHelperRunning": String(shadeStatus.isRunning),
                "shadeHelperPID": shadeStatus.pid.map(String.init) ?? "",
                "shadeHelperOrphaned": String(shadeStatus.isOrphaned),
                "shadeStalePIDRemoved": String(shadeStatus.stalePIDRemoved),
                "hotkeysRunning": String(hotkeyStatus.isRunning),
                "hotkeysPID": hotkeyStatus.pid.map(String.init) ?? "",
                "hotkeysOrphaned": String(hotkeyStatus.isOrphaned),
                "hotkeysStalePIDRemoved": String(hotkeyStatus.stalePIDRemoved)
            ]
        }
        printJSON(rows)
    }

    private static func publicQualityLabel(for quality: ControlQuality) -> String {
        switch quality {
        case .realBrightness, .softwareDimming:
            return "Ready"
        case .limitedControl:
            return "Limited"
        }
    }

    private static func publicDisplayName(_ display: Display) -> String {
        if display.isBuiltin {
            return "MacBook Pro"
        }

        if display.name.lowercased().hasPrefix("external display") {
            return "External \(display.resolutionDescription)"
        }

        return display.name
    }

    private static func brightness(for display: Display, in state: RuntimeState) -> Int {
        if let value = state.displayBrightness[String(display.id)] ?? state.displayBrightness[display.uuid] {
            return value
        }

        if display.isBuiltin {
            return state.displayBrightness["all"] ?? (selectorMatches(display, selector: state.selector) ? state.brightness : 100)
        }

        if let groupedValue = state.displayBrightness["external"] ?? state.displayBrightness["all"] {
            return groupedValue
        }

        return selectorMatches(display, selector: state.selector) ? state.brightness : 100
    }

    private static func selectorMatches(_ display: Display, selector rawSelector: String) -> Bool {
        let selector = rawSelector.lowercased()
        if let id = UInt32(selector) {
            return display.id == id
        }

        return selector == String(display.id)
            || display.uuid.lowercased().contains(selector)
            || publicDisplayName(display).normalizedTargetName.contains(selector.normalizedTargetName)
            || (selector == "external" && !display.isBuiltin)
            || selector == "all"
    }

    private static func resolveSelectorArgument(_ rawSelector: String, controller: GlowKeyController) throws -> String {
        let selector = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = selector.lowercased()
        if lowercased == "all"
            || lowercased == "external"
            || lowercased == "externals"
            || lowercased == "cursor"
            || lowercased == "mouse"
            || lowercased == "pointer"
            || UInt32(selector) != nil
        {
            return selector
        }

        let displays = try controller.displays()
        if displays.contains(where: { $0.uuid.localizedCaseInsensitiveContains(selector) }) {
            return selector
        }

        let normalized = selector.normalizedTargetName
        let matches = displays.filter { display in
            publicDisplayName(display).normalizedTargetName.contains(normalized)
                || display.name.normalizedTargetName.contains(normalized)
        }

        guard !matches.isEmpty else {
            return selector
        }

        guard matches.count == 1, let display = matches.first else {
            let names = matches.map(publicDisplayName).joined(separator: ", ")
            throw CLIError.invalidUsage("Display name '\(rawSelector)' matches multiple displays: \(names). Use `glowkey displays` and target an id.")
        }

        return String(display.id)
    }

    private static func installUserArtifacts() throws -> URL {
        try buildReleaseBinariesIfPossible()

        let fileManager = FileManager.default
        let applicationDirectory = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true)
        let bundledAppURL = currentAppBundleURL()
        let appURL = bundledAppURL ?? applicationDirectory.appendingPathComponent("GlowKey.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let binURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("bin", isDirectory: true)

        try removeLegacyAppBundles(fileManager: fileManager, applicationDirectory: applicationDirectory, currentAppURL: bundledAppURL)

        if bundledAppURL == nil {
            try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        }
        try fileManager.createDirectory(at: binURL, withIntermediateDirectories: true)

        let binaries = [
            "glowkey",
            "glowkey-shade",
            "glowkey-hotkeys",
            "glowkey-daemon",
            "glowkey-menubar"
        ]

        if bundledAppURL == nil {
            for binary in binaries {
                let source = try builtExecutableURL(named: binary)
                let destination = macOSURL.appendingPathComponent(binary)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
        }

        if bundledAppURL == nil {
            let infoPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>CFBundleExecutable</key>
              <string>glowkey-menubar</string>
              <key>CFBundleIdentifier</key>
              <string>fyi.glowkey.app</string>
              <key>CFBundleName</key>
              <string>GlowKey</string>
              <key>CFBundleIconFile</key>
              <string>AppIcon</string>
              <key>CFBundlePackageType</key>
              <string>APPL</string>
              <key>LSUIElement</key>
              <true/>
            </dict>
            </plist>
            """
            try infoPlist.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
            try installAppIcon(contentsURL: contentsURL)
        }

        let symlinkURL = binURL.appendingPathComponent("glowkey")
        if fileManager.fileExists(atPath: symlinkURL.path) {
            try fileManager.removeItem(at: symlinkURL)
        }
        try fileManager.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: macOSURL.appendingPathComponent("glowkey")
        )

        let legacySymlinkURL = binURL.appendingPathComponent("lumensync")
        if fileManager.fileExists(atPath: legacySymlinkURL.path) {
            try fileManager.removeItem(at: legacySymlinkURL)
        }
        try fileManager.createSymbolicLink(
            at: legacySymlinkURL,
            withDestinationURL: macOSURL.appendingPathComponent("glowkey")
        )

        return appURL
    }

    private static func currentAppBundleURL() -> URL? {
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL

        while url.path != "/" {
            if url.pathExtension == "app", url.lastPathComponent == "GlowKey.app" {
                return url
            }
            url.deleteLastPathComponent()
        }

        return nil
    }

    private static func removeLegacyAppBundles(
        fileManager: FileManager,
        applicationDirectory: URL,
        currentAppURL: URL?
    ) throws {
        var candidates = [
            applicationDirectory.appendingPathComponent("LumenSync.app", isDirectory: true)
        ]

        if let currentAppURL {
            candidates.append(
                currentAppURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("LumenSync.app", isDirectory: true)
            )
        }

        for candidate in Set(candidates) where fileManager.fileExists(atPath: candidate.path) {
            try fileManager.removeItem(at: candidate)
        }
    }

    private static func stopLegacyProcesses() {
        let names = [
            "lumensync-hotkeys",
            "lumensync-menubar",
            "lumensync-shade",
            "lumensync-daemon"
        ]

        for name in names {
            for pid in processIDs(matching: name) {
                kill(pid, SIGTERM)
            }
        }

        Thread.sleep(forTimeInterval: 0.2)

        for name in names {
            for pid in processIDs(matching: name) {
                kill(pid, SIGKILL)
            }
        }
    }

    private static func processIDs(matching name: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", name]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else {
            return []
        }

        let currentPID = getpid()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 != currentPID }
    }

    private static func buildReleaseBinariesIfPossible() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("Package.swift").path) else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["build", "-c", "release", "--package-path", packageRoot.path]
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError.invalidUsage("Release build failed during install.")
        }
    }

    private static func installAppIcon(contentsURL: URL) throws {
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let pngURL = resourcesURL.appendingPathComponent("AppIcon.png")
        let image = appIconImage(size: 512)
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return
        }
        try pngData.write(to: pngURL, options: [.atomic])
    }

    private static func appIconImage(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let background = NSGradient(colors: [
            NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.10, alpha: 1),
            NSColor(calibratedRed: 0.18, green: 0.14, blue: 0.10, alpha: 1)
        ])
        background?.draw(in: NSBezierPath(roundedRect: rect.insetBy(dx: 32, dy: 32), xRadius: 110, yRadius: 110), angle: 270)

        let center = NSPoint(x: size / 2, y: size / 2)
        let color = NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.32, alpha: 1)
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 62, y: center.y - 62, width: 124, height: 124)).fill()

        color.setStroke()
        for index in 0..<12 {
            let angle = CGFloat(index) * .pi / 6
            let inner = size * 0.19
            let outer = size * 0.34
            let start = NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner)
            let end = NSPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer)
            let path = NSBezierPath()
            path.lineWidth = 22
            path.lineCapStyle = .round
            path.move(to: start)
            path.line(to: end)
            path.stroke()
        }

        image.unlockFocus()
        return image
    }

    private static func builtExecutableURL(named name: String) throws -> URL {
        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
        let currentDirectory = currentExecutable.deletingLastPathComponent()
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            workingDirectory.appendingPathComponent(".build/release").appendingPathComponent(name),
            currentDirectory.appendingPathComponent(name),
            workingDirectory.appendingPathComponent(".build/debug").appendingPathComponent(name)
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        throw CLIError.invalidUsage("Missing \(name). Run `swift build`, then try again.")
    }

    private static func applyBrightness(
        _ brightness: Brightness,
        selectorArgument: String,
        controller: GlowKeyController,
        stateStore: RuntimeStateStore,
        shadeProcessManager: ShadeProcessManager
    ) throws {
        let selector = DisplaySelector(selectorArgument)
        let previousState = (try? stateStore.load()) ?? .defaultValue
        let displayBrightness = try displayBrightnessAfterApplying(
            existing: previousState.displayBrightness,
            selectorArgument: selectorArgument,
            brightness: brightness.percentage,
            controller: controller
        )
        let application = try controller.applyBrightness(brightness, selector: selector)

        switch application.method {
        case .realBrightness:
            try stateStore.save(RuntimeState(
                brightness: brightness.percentage,
                selector: selectorArgument,
                displayBrightness: displayBrightness,
                overlayEnabled: application.overlayBrightness != nil,
                overlayBrightness: application.overlayBrightness,
                method: .realBrightness,
                syncExternalDisplays: previousState.syncExternalDisplays
            ))
            if application.overlayBrightness != nil {
                try shadeProcessManager.ensureRunning()
            }

        case .softwareDimming:
            let overlayEnabled = brightness.percentage < 100
            let state = RuntimeState(
                brightness: brightness.percentage,
                selector: selectorArgument,
                displayBrightness: displayBrightness,
                overlayEnabled: overlayEnabled,
                overlayBrightness: overlayEnabled ? brightness.percentage : nil,
                method: overlayEnabled ? .softwareDimming : .normalBrightness,
                syncExternalDisplays: previousState.syncExternalDisplays
            )
            if overlayEnabled {
                try stateStore.save(state)
                try shadeProcessManager.ensureRunning()
            } else {
                try stateStore.save(state)
            }

        case .normalBrightness:
            shadeProcessManager.stopIfRunning()
            try stateStore.save(RuntimeState(
                brightness: brightness.percentage,
                selector: selectorArgument,
                displayBrightness: displayBrightness,
                overlayEnabled: false,
                overlayBrightness: nil,
                method: .normalBrightness,
                syncExternalDisplays: previousState.syncExternalDisplays
            ))
        }
    }

    private static func currentBrightness(in state: RuntimeState, selectorArgument: String) -> Int {
        state.displayBrightness[selectorArgument]
            ?? state.displayBrightness[selectorArgument.lowercased()]
            ?? state.brightness
    }

    private static func displayBrightnessAfterApplying(
        existing: [String: Int],
        selectorArgument: String,
        brightness: Int,
        controller: GlowKeyController
    ) throws -> [String: Int] {
        var values = existing
        let clamped = Brightness(brightness).percentage
        let normalizedSelector = selectorArgument.lowercased()
        values[selectorArgument] = clamped

        let displays = try controller.displays()
        switch DisplaySelector(selectorArgument) {
        case .external:
            values["external"] = clamped
            for display in displays where !display.isBuiltin {
                storeBrightness(clamped, for: display, in: &values)
            }
        case .all:
            values["all"] = clamped
            values["external"] = clamped
            for display in displays {
                storeBrightness(clamped, for: display, in: &values)
            }
        case let .id(id):
            values[String(id)] = clamped
            if let display = displays.first(where: { $0.id == id }) {
                storeBrightness(clamped, for: display, in: &values)
            }
        case let .uuid(uuid):
            values[normalizedSelector] = clamped
            if let display = displays.first(where: { $0.uuid.localizedCaseInsensitiveContains(uuid) }) {
                storeBrightness(clamped, for: display, in: &values)
            }
        }

        return values
    }

    private static func storeBrightness(_ brightness: Int, for display: Display, in values: inout [String: Int]) {
        values[String(display.id)] = brightness
        values[display.uuid] = brightness
    }

    private static func handleHotkeysCommand(
        _ arguments: [String],
        manager: HotkeyProcessManager,
        controller: GlowKeyController
    ) throws {
        guard let command = arguments.first else {
            throw CLIError.invalidUsage("Usage: glowkey hotkeys <start|stop|status>")
        }

        switch command {
        case "start", "debug":
            let request = parseHotkeyStartRequest(Array(arguments.dropFirst()))
            let selector = try resolveSelectorArgument(request.selector, controller: controller)
            if command == "debug" {
                manager.stop()
            }
            try manager.start(
                step: request.step,
                selector: selector,
                downShortcut: request.downShortcut,
                upShortcut: request.upShortcut,
                debug: command == "debug"
            )
            print("External-display shortcuts started.")
            print("Down: \(request.downShortcut)")
            print("Up: \(request.upShortcut)")
            print("Target: \(selector == "cursor" ? "external display under cursor" : selector)")
            print("Fallback shortcuts also work: cmd+opt+- and cmd+opt+=")
            print("Mac brightness keys remain native and continue controlling the built-in display.")

        case "stop":
            manager.stop()
            print("External-display shortcuts stopped.")

        case "status":
            let status = manager.status()
            if status.isRunning {
                let pidText = status.pid.map(String.init) ?? "unknown"
                let orphanText = status.isOrphaned ? " orphaned" : ""
                print("Hotkeys: running\(orphanText) (pid \(pidText))")
            } else {
                print("Hotkeys: stopped")
            }

        default:
            throw CLIError.invalidUsage("Usage: glowkey hotkeys <start|stop|status>")
        }
    }

    private static func handleDaemonCommand(_ arguments: [String], manager: DaemonProcessManager) throws {
        guard let command = arguments.first else {
            throw CLIError.invalidUsage("Usage: glowkey daemon <start|stop|status>")
        }

        switch command {
        case "start":
            try manager.start()
            print("Background mode started.")
        case "stop":
            manager.stop()
            print("Background mode stopped.")
        case "status":
            let status = manager.status()
            if status.isRunning {
                let pidText = status.pid.map(String.init) ?? "unknown"
                let orphanText = status.isOrphaned ? " orphaned" : ""
                print("Background mode: on\(orphanText) (pid \(pidText))")
            } else {
                print("Background mode: off")
            }
        default:
            throw CLIError.invalidUsage("Usage: glowkey daemon <start|stop|status>")
        }
    }

    private static func handleMenuBarCommand(_ arguments: [String], manager: MenuBarProcessManager) throws {
        guard let command = arguments.first else {
            throw CLIError.invalidUsage("Usage: glowkey menubar <start|stop|status>")
        }

        switch command {
        case "start":
            try manager.start()
            print("Menu bar started.")
        case "stop":
            manager.stop()
            print("Menu bar stopped.")
        case "status":
            let status = manager.status()
            if status.isRunning {
                let pidText = status.pid.map(String.init) ?? "unknown"
                let orphanText = status.isOrphaned ? " orphaned" : ""
                print("Menu bar: on\(orphanText) (pid \(pidText))")
            } else {
                print("Menu bar: off")
            }
        default:
            throw CLIError.invalidUsage("Usage: glowkey menubar <start|stop|status>")
        }
    }

    private static func handleSyncCommand(_ arguments: [String], stateStore: RuntimeStateStore) throws {
        guard let command = arguments.first else {
            throw CLIError.invalidUsage("Usage: glowkey sync <on|off|toggle>")
        }

        let state = try stateStore.load()
        let enabled: Bool
        switch command {
        case "on":
            enabled = true
        case "off":
            enabled = false
        case "toggle":
            enabled = !state.syncExternalDisplays
        default:
            throw CLIError.invalidUsage("Usage: glowkey sync <on|off|toggle>")
        }

        try stateStore.save(RuntimeState(
            brightness: state.brightness,
            selector: state.selector,
            displayBrightness: state.displayBrightness,
            overlayEnabled: state.overlayEnabled,
            overlayBrightness: state.overlayBrightness,
            method: state.method,
            syncExternalDisplays: enabled
        ))
        print("Sync displays: \(enabled ? "on" : "off")")
    }

    private static func handleDebugCommand(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw CLIError.invalidUsage("Usage: glowkey debug <hardware-probe|ddc-probe|profiles> [--json]")
        }

        let json = arguments.contains("--json")
        switch command {
        case "hardware-probe":
            let hardwareProbe = HardwareProbe()
            let probes = try hardwareProbe.probeDisplays()
            let rawFramebuffers = hardwareProbe.probeRawFramebuffers()
            json ? printHardwareProbeJSON(probes, rawFramebuffers: rawFramebuffers) : printHardwareProbe(probes, rawFramebuffers: rawFramebuffers)

        case "ddc-probe":
            let probes = AppleSiliconDDCBackend.probeServices()
            json ? printDDCProbeJSON(probes) : printDDCProbe(probes)

        case "profiles":
            let cache = BackendProfileCacheStore().load()
            json ? printProfilesJSON(cache) : printProfiles(cache)

        default:
            throw CLIError.invalidUsage("Usage: glowkey debug <hardware-probe|ddc-probe|profiles> [--json]")
        }
    }

    private static func printProfiles(_ cache: BackendProfileCache) {
        if cache.displays.isEmpty {
            print("No backend profiles cached.")
            return
        }

        for profile in cache.displays.values.sorted(by: { $0.displayKey < $1.displayKey }) {
            print(profile.displayKey)
            print("  method: \(profile.method.rawValue)")
            print("  service: \(profile.serviceFingerprint)")
            print("  updated: \(profile.updatedAt)")
        }
    }

    private static func printProfilesJSON(_ cache: BackendProfileCache) {
        let rows = cache.displays.values
            .sorted(by: { $0.displayKey < $1.displayKey })
            .map { profile in
                [
                    "displayKey": profile.displayKey,
                    "method": profile.method.rawValue,
                    "serviceFingerprint": profile.serviceFingerprint,
                    "updatedAt": ISO8601DateFormatter().string(from: profile.updatedAt)
                ]
            }
        printJSON(rows)
    }

    private static func printDDCProbe(_ probes: [AppleSiliconDDCServiceProbe]) {
        if probes.isEmpty {
            print("No Apple Silicon DDC services found.")
            return
        }

        for probe in probes {
            let name = [probe.manufacturerID, probe.productName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            print(name.isEmpty ? "External display \(probe.index)" : name)
            print("  location: \(probe.location)")
            if !probe.ioDisplayLocation.isEmpty {
                print("  display path: \(probe.ioDisplayLocation)")
            }
            if !probe.edidUUID.isEmpty {
                print("  edid: \(probe.edidUUID)")
            }
            print("  serial: \(probe.serialNumber.isEmpty ? "unavailable" : probe.serialNumber)")
            print("  transport: \(probe.upstreamTransport.isEmpty ? "unknown" : probe.upstreamTransport) -> \(probe.downstreamTransport.isEmpty ? "unknown" : probe.downstreamTransport)")
            if let brightness = probe.brightness, let maxBrightness = probe.maxBrightness {
                print("  brightness: \(brightness)/\(maxBrightness)")
            } else {
                print("  brightness: unavailable")
            }
        }
    }

    private static func printDDCProbeJSON(_ probes: [AppleSiliconDDCServiceProbe]) {
        let rows = probes.map { probe in
            [
                "index": String(probe.index),
                "location": probe.location,
                "ioDisplayLocation": probe.ioDisplayLocation,
                "edidUUID": probe.edidUUID,
                "manufacturerID": probe.manufacturerID,
                "productName": probe.productName,
                "serialNumber": probe.serialNumber,
                "upstreamTransport": probe.upstreamTransport,
                "downstreamTransport": probe.downstreamTransport,
                "brightness": probe.brightness.map(String.init) ?? "",
                "maxBrightness": probe.maxBrightness.map(String.init) ?? "",
                "canReadBrightness": String(probe.canReadBrightness)
            ]
        }
        printJSON(rows)
    }

    private static func printHardwareProbe(_ probes: [DisplayHardwareProbe], rawFramebuffers: [RawFramebufferProbe]) {
        if probes.isEmpty {
            print("No displays found.")
        } else {
            for probe in probes {
                print("\(probe.display.name)")
                print("  type: \(probe.display.kindDescription)")
                print("  framebuffer service: \(probe.framebufferService)")
                print("  display-connect service: \(probe.displayConnectService)")
                print("  display service: \(probe.displayService)")
                if let i2cBusCount = probe.i2cBusCount {
                    print("  I2C/DDC buses: \(i2cBusCount)")
                } else {
                    print("  I2C/DDC buses: unavailable")
                }

                for parameter in probe.parameters {
                    let floatText = parameter.floatValue.map { String(format: "%.3f", $0) } ?? "unavailable"
                    if let value = parameter.integerValue, let min = parameter.integerMin, let max = parameter.integerMax {
                        print("  \(parameter.name): float \(floatText), integer \(value) range \(min)-\(max)")
                    } else {
                        print("  \(parameter.name): float \(floatText), integer unavailable")
                    }
                }
            }
        }

        print("Raw framebuffers")
        if rawFramebuffers.isEmpty {
            print("  none")
        } else {
            for framebuffer in rawFramebuffers {
                if let i2cBusCount = framebuffer.i2cBusCount {
                    print("  \(framebuffer.service): \(framebuffer.name), I2C/DDC buses \(i2cBusCount)")
                } else {
                    print("  \(framebuffer.service): \(framebuffer.name), I2C/DDC unavailable result \(framebuffer.i2cResult)")
                }
            }
        }
    }

    private static func printHardwareProbeJSON(_ probes: [DisplayHardwareProbe], rawFramebuffers: [RawFramebufferProbe]) {
        var rows: [[String: String]] = []
        for probe in probes {
            for parameter in probe.parameters {
                var row: [String: String] = [:]
                row["kind"] = "display"
                row["displayID"] = String(probe.display.id)
                row["displayName"] = probe.display.name
                row["displayType"] = probe.display.kindDescription
                row["framebufferService"] = String(probe.framebufferService)
                row["displayConnectService"] = String(probe.displayConnectService)
                row["displayService"] = String(probe.displayService)
                row["i2cBusCount"] = probe.i2cBusCount.map { String($0) } ?? ""
                row["parameter"] = parameter.name
                row["floatValue"] = parameter.floatValue.map { String($0) } ?? ""
                row["integerValue"] = parameter.integerValue.map { String($0) } ?? ""
                row["integerMin"] = parameter.integerMin.map { String($0) } ?? ""
                row["integerMax"] = parameter.integerMax.map { String($0) } ?? ""
                row["floatResult"] = String(parameter.floatResult)
                row["integerResult"] = String(parameter.integerResult)
                rows.append(row)
            }
        }

        for framebuffer in rawFramebuffers {
            var row: [String: String] = [:]
            row["kind"] = "rawFramebuffer"
            row["service"] = String(framebuffer.service)
            row["name"] = framebuffer.name
            row["i2cBusCount"] = framebuffer.i2cBusCount.map { String($0) } ?? ""
            row["i2cResult"] = String(framebuffer.i2cResult)
            rows.append(row)
        }

        printJSON(rows)
    }

    private static func parseHotkeyStartRequest(_ arguments: [String]) -> HotkeyStartRequest {
        let downShortcut = value(after: "--down", in: arguments) ?? "fn+f1"
        let upShortcut = value(after: "--up", in: arguments) ?? "fn+f2"
        let explicitTarget = value(after: "--target", in: arguments)
        let positional = stripFlagValues(["--down", "--up", "--target"], from: arguments)
        let step = Int(positional.first ?? "5") ?? 5
        let selector = explicitTarget ?? positional.dropFirst().first ?? "cursor"
        return HotkeyStartRequest(
            step: step,
            selector: selector,
            downShortcut: downShortcut,
            upShortcut: upShortcut
        )
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

    private static func stripFlagValues(_ flags: Set<String>, from arguments: [String]) -> [String] {
        var result: [String] = []
        var skipNext = false

        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }

            if flags.contains(argument) {
                skipNext = true
                continue
            }

            result.append(argument)
        }

        return result
    }

    private static func parseSetRequest(_ arguments: [String]) throws -> SetRequest {
        switch arguments.count {
        case 1:
            guard let percentage = Int(arguments[0]) else {
                throw CLIError.invalidUsage("Usage: glowkey set <0-100>")
            }
            return SetRequest(selectorArgument: "external", percentage: percentage)
        case 2:
            guard let percentage = Int(arguments[1]) else {
                throw CLIError.invalidUsage("Usage: glowkey set <all|external|display-id|uuid> <0-100>")
            }
            return SetRequest(selectorArgument: arguments[0], percentage: percentage)
        default:
            throw CLIError.invalidUsage("Usage: glowkey set <0-100>")
        }
    }

    private static func parseRelativeRequest(_ arguments: [String]) throws -> RelativeRequest {
        switch arguments.count {
        case 0:
            return RelativeRequest(selectorArgument: "external", step: 10)
        case 1:
            if let step = Int(arguments[0]) {
                return RelativeRequest(selectorArgument: "external", step: step)
            }
            return RelativeRequest(selectorArgument: arguments[0], step: 10)
        case 2:
            guard let step = Int(arguments[1]) else {
                throw CLIError.invalidUsage("Usage: glowkey up <all|external|display-id|uuid> [step]")
            }
            return RelativeRequest(selectorArgument: arguments[0], step: step)
        default:
            throw CLIError.invalidUsage("Usage: glowkey down [step]")
        }
    }
}

private struct SetRequest {
    let selectorArgument: String
    let percentage: Int
}

private struct RelativeRequest {
    let selectorArgument: String
    let step: Int
}

private struct HotkeyStartRequest {
    let step: Int
    let selector: String
    let downShortcut: String
    let upShortcut: String
}

private extension String {
    var normalizedTargetName: String {
        lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}

enum CLIError: Error, LocalizedError {
    case invalidUsage(String)

    var errorDescription: String? {
        switch self {
        case let .invalidUsage(message):
            message
        }
    }
}

private extension FileHandle {
    func writeLine(_ line: String) {
        write(Data((line + "\n").utf8))
    }
}

do {
    try GlowKeyCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.writeLine("Error: \(error.localizedDescription)")
    Foundation.exit(1)
}
