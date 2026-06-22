import AppKit
import Darwin
import Foundation
import GlowKeyCore

enum LumenIcon {
    static func menuBarImage() -> NSImage {
        let image = draw(size: NSSize(width: 18, height: 18), menuBar: true)
        image.isTemplate = false
        return image
    }

    static func panelImage() -> NSImage {
        draw(size: NSSize(width: 30, height: 30), menuBar: false)
    }

    private static func draw(size: NSSize, menuBar: Bool) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let bounds = NSRect(origin: .zero, size: size)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(size.width, size.height) * 0.22
        let rayInner = min(size.width, size.height) * 0.34
        let rayOuter = min(size.width, size.height) * 0.47
        let color = menuBar
            ? NSColor(calibratedRed: 1.0, green: 0.77, blue: 0.40, alpha: 1)
            : NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.32, alpha: 1)

        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()

        color.setStroke()
        for index in 0..<8 {
            let angle = CGFloat(index) * .pi / 4
            let start = NSPoint(x: center.x + cos(angle) * rayInner, y: center.y + sin(angle) * rayInner)
            let end = NSPoint(x: center.x + cos(angle) * rayOuter, y: center.y + sin(angle) * rayOuter)
            let path = NSBezierPath()
            path.lineWidth = max(1.4, size.width * 0.07)
            path.lineCapStyle = .round
            path.move(to: start)
            path.line(to: end)
            path.stroke()
        }

        image.unlockFocus()
        return image
    }
}

@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.image = LumenIcon.menuBarImage()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        bootstrapBackgroundServices()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 400, height: 520)
        popover.contentViewController = LumenPanelController()

        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.togglePopover()
            }
        }
    }

    private func bootstrapBackgroundServices() {
        guard let glowkeyURL = bundledGlowKeyExecutableURL() else {
            return
        }

        DispatchQueue.global(qos: .utility).async {
            runProcess(glowkeyURL, arguments: ["install", "--skip-menubar-start"])
        }
    }

    private func bundledGlowKeyExecutableURL() -> URL? {
        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
        let candidate = currentExecutable
            .deletingLastPathComponent()
            .appendingPathComponent("glowkey")

        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            return nil
        }

        var url = currentExecutable.standardizedFileURL
        while url.path != "/" {
            if url.pathExtension == "app", url.lastPathComponent == "GlowKey.app" {
                return candidate
            }
            url.deleteLastPathComponent()
        }

        return nil
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else {
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.contentViewController = LumenPanelController()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

@MainActor
final class LumenPanelController: NSViewController {
    private let controller = GlowKeyController()
    private let stateStore = RuntimeStateStore()
    private var currentState = RuntimeState.defaultValue
    private var refreshTimer: Timer?
    private var lastStateModifiedAt: Date?
    private var lastDisplaySignature = ""
    private var isDragging = false

    override func loadView() {
        currentState = (try? stateStore.load()) ?? .defaultValue
        let displays = (try? controller.displays()) ?? []
        let shortcutsEnabled = shortcutsAreRunning()
        lastStateModifiedAt = stateModifiedAt()
        lastDisplaySignature = displaySignature(displays)
        view = LumenPanelView(
            state: currentState,
            displays: displays,
            shortcutsEnabled: shortcutsEnabled,
            apply: { [weak self] selector, value in
                self?.apply(selector: selector, brightness: value)
            },
            toggleSync: { [weak self] in
                self?.toggleSync()
            },
            draggingChanged: { [weak self] isDragging in
                self?.isDragging = isDragging
            },
            refresh: { [weak self] in
                self?.reload()
            },
            quit: {
                NSApp.terminate(nil)
            }
        )
        preferredContentSize = view.frame.size
        startAutoRefresh()
    }

    private func apply(selector: String, brightness: Int) {
        guard let candidate = glowkeyExecutableURL() else {
            log("Unable to find glowkey CLI for selector \(selector)")
            return
        }

        let arguments = ["set", selector, String(Brightness(brightness).percentage)]
        DispatchQueue.global(qos: .userInitiated).async {
            runProcess(candidate, arguments: arguments)
        }
    }

    private func toggleSync() {
        guard let candidate = glowkeyExecutableURL() else {
            log("Unable to find glowkey CLI for sync toggle")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            runProcess(candidate, arguments: ["sync", "toggle"])
        }
    }

    private func reload() {
        loadView()
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadIfNeeded()
            }
        }
    }

    private func reloadIfNeeded() {
        guard !isDragging else {
            return
        }

        let displays = (try? controller.displays()) ?? []
        let currentStateModifiedAt = stateModifiedAt()
        let currentDisplaySignature = displaySignature(displays)
        guard currentStateModifiedAt != lastStateModifiedAt || currentDisplaySignature != lastDisplaySignature else {
            return
        }
        reload()
    }

    private func stateModifiedAt() -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: RuntimePaths().stateURL.path)[.modificationDate] as? Date
    }

    private func displaySignature(_ displays: [Display]) -> String {
        displays
            .map { "\($0.id):\($0.uuid):\($0.name):\($0.isOnline):\($0.isActive)" }
            .joined(separator: "|")
    }

    private func shortcutsAreRunning() -> Bool {
        guard
            let data = try? Data(contentsOf: RuntimePaths().hotkeysPIDURL),
            let value = String(data: data, encoding: .utf8),
            let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return false
        }

        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func runCLI(arguments: [String]) {
        guard let candidate = glowkeyExecutableURL() else {
            log("Unable to find glowkey CLI for arguments: \(arguments.joined(separator: " "))")
            return
        }

        let process = Process()
        process.executableURL = candidate
        process.arguments = arguments
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                log("glowkey exited \(process.terminationStatus) for arguments: \(arguments.joined(separator: " "))")
            }
        } catch {
            log("Failed to run glowkey: \(error.localizedDescription)")
        }
    }

    private func glowkeyExecutableURL() -> URL? {
        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
        let currentDirectory = currentExecutable.deletingLastPathComponent()
        let packageRoot = currentDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let candidates = [
            currentDirectory.appendingPathComponent("glowkey"),
            packageRoot.appendingPathComponent("bin/glowkey"),
            packageRoot.appendingPathComponent(".build/debug/glowkey"),
            packageRoot.appendingPathComponent(".build/release/glowkey"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("bin/glowkey")
        ]

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/glowkey-menubar.err.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url)
            {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

private func runProcess(_ executableURL: URL, arguments: [String]) {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
    process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
    process.standardError = FileHandle(forWritingAtPath: "/dev/null")
    try? process.run()
    process.waitUntilExit()
}

@MainActor
final class LumenPanelView: NSView {
    private let apply: (String, Int) -> Void
    private let toggleSync: () -> Void
    private let draggingChanged: (Bool) -> Void
    private let refresh: () -> Void
    private let quit: () -> Void
    private let state: RuntimeState
    private let shortcutsEnabled: Bool
    private var shortcutsPanel: NSView?
    private var transientPanelTitle: String?
    private var liveApplyWorkItems: [String: DispatchWorkItem] = [:]
    private var lastScheduledValues: [String: Int] = [:]

    init(
        state: RuntimeState,
        displays: [Display],
        shortcutsEnabled: Bool,
        apply: @escaping (String, Int) -> Void,
        toggleSync: @escaping () -> Void,
        draggingChanged: @escaping (Bool) -> Void,
        refresh: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.state = state
        self.shortcutsEnabled = shortcutsEnabled
        self.apply = apply
        self.toggleSync = toggleSync
        self.draggingChanged = draggingChanged
        self.refresh = refresh
        self.quit = quit
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height(for: displays, shortcutsEnabled: shortcutsEnabled)))
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.075, green: 0.078, blue: 0.084, alpha: 1).cgColor
        build(displays: displays)
        if CommandLine.arguments.contains("--open-shortcuts") {
            DispatchQueue.main.async { [weak self] in
                self?.shortcutsTapped()
            }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelPendingLiveApplies()
            draggingChanged(false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private static func height(for displays: [Display], shortcutsEnabled: Bool) -> CGFloat {
        132 + CGFloat(max(displays.count, 1)) * 96 + (shortcutsEnabled ? 0 : 48)
    }

    private func build(displays: [Display]) {
        let x: CGFloat = 18
        var y = bounds.height - 56

        let top = topBar()
        top.frame.origin = NSPoint(x: x, y: y)
        addSubview(top)

        y -= 88
        if displays.isEmpty {
            let card = emptyCard()
            card.frame.origin = NSPoint(x: x, y: y)
            addSubview(card)
            y -= 92
        } else {
            for display in displays {
                let card = displayCard(display)
                card.frame.origin = NSPoint(x: x, y: y)
                addSubview(card)
                y -= 96
            }
        }

        if !shortcutsEnabled {
            let permission = permissionPanel()
            permission.frame.origin = NSPoint(x: x, y: 74)
            addSubview(permission)
        }

        let footerPanel = footer()
        footerPanel.frame.origin = NSPoint(x: x, y: 14)
        addSubview(footerPanel)
    }

    private func topBar() -> NSView {
        let row = NSStackView(frame: NSRect(x: 0, y: 0, width: 364, height: 44))
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let icon = NSImageView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        icon.image = LumenIcon.panelImage()

        let titleBlock = NSStackView(frame: NSRect(x: 0, y: 0, width: 170, height: 38))
        titleBlock.orientation = .vertical
        titleBlock.alignment = .leading
        titleBlock.spacing = -1

        let title = NSTextField(labelWithString: "GlowKey")
        title.font = .systemFont(ofSize: 20, weight: .black)
        title.textColor = mainText

        let subtitle = NSTextField(labelWithString: "Display brightness")
        subtitle.font = .systemFont(ofSize: 11, weight: .bold)
        subtitle.textColor = mutedText

        titleBlock.addArrangedSubview(title)
        titleBlock.addArrangedSubview(subtitle)

        let spacer = NSView()
        let refreshButton = symbolButton("arrow.clockwise", action: #selector(refreshTapped))
        let quitButton = symbolButton("xmark", action: #selector(quitTapped))

        row.addArrangedSubview(icon)
        row.addArrangedSubview(titleBlock)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(refreshButton)
        row.addArrangedSubview(quitButton)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func displayCard(_ display: Display) -> NSView {
        let value = brightness(for: display)
        let card = CardView(frame: NSRect(x: 0, y: 0, width: 364, height: 80))
        card.accentColor = display.isBuiltin ? softGray : peach
        card.isActive = selectorMatches(display)
        card.isDimmed = value <= 25

        let icon = NSTextField(labelWithString: display.isBuiltin ? "▣" : "▭")
        icon.font = .systemFont(ofSize: 21, weight: .bold)
        icon.textColor = display.isBuiltin ? softGray : peach
        icon.alignment = .center
        icon.frame = NSRect(x: 16, y: 43, width: 28, height: 24)
        card.addSubview(icon)

        let title = NSTextField(labelWithString: displayTitle(display))
        title.font = .systemFont(ofSize: 17, weight: .black)
        title.textColor = mainText
        title.alignment = .left
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 52, y: 47, width: 214, height: 22)
        card.addSubview(title)

        let percent = NSTextField(labelWithString: "\(value)%")
        percent.font = .systemFont(ofSize: 16, weight: .black)
        percent.textColor = display.isBuiltin ? softGray : peach
        percent.alignment = .right
        percent.frame = NSRect(x: 282, y: 47, width: 58, height: 22)
        card.addSubview(percent)

        let bar = BrightnessBar(
            frame: NSRect(x: 48, y: 12, width: 296, height: 26),
            value: value,
            isEnabled: true,
            fillColor: display.isBuiltin ? softGray : peach,
            onDragStart: { [weak self] in
                self?.draggingChanged(true)
            },
            onChange: { [weak self] value in
                percent.stringValue = "\(value)%"
                self?.scheduleLiveApply(selector: self?.selector(for: display) ?? String(display.id), value: value)
            },
            onCommit: { [weak self] value in
                let selector = self?.selector(for: display) ?? String(display.id)
                self?.liveApplyWorkItems[selector]?.cancel()
                self?.liveApplyWorkItems[selector] = nil
                self?.apply(selector, value)
                self?.draggingChanged(false)
            }
        )
        card.addSubview(bar)

        return card
    }

    private func selector(for display: Display) -> String {
        state.syncExternalDisplays && !display.isBuiltin ? "external" : String(display.id)
    }

    private func displayTitle(_ display: Display) -> String {
        if display.isBuiltin {
            return "MacBook Pro"
        }

        if display.name.lowercased().hasPrefix("external display") {
            return "External \(display.resolutionDescription)"
        }

        return display.name
    }

    private func brightness(for display: Display) -> Int {
        if let value = state.displayBrightness[String(display.id)] ?? state.displayBrightness[display.uuid] {
            return value
        }

        if display.isBuiltin {
            return state.displayBrightness["all"] ?? (selectorMatches(display) ? state.brightness : 100)
        }

        if let groupedValue = state.displayBrightness["external"] ?? state.displayBrightness["all"] {
            return groupedValue
        }

        return selectorMatches(display) ? state.brightness : 100
    }

    private func selectorMatches(_ display: Display) -> Bool {
        let selector = state.selector.lowercased()
        if let id = UInt32(selector) {
            return display.id == id
        }

        return selector == String(display.id)
            || display.uuid.lowercased().contains(selector)
            || (selector == "external" && !display.isBuiltin)
            || selector == "all"
    }

    private func emptyCard() -> NSView {
        let card = CardView(frame: NSRect(x: 0, y: 0, width: 364, height: 80))
        card.accentColor = mutedText
        let title = NSTextField(labelWithString: "No Displays")
        title.font = .systemFont(ofSize: 21, weight: .black)
        title.textColor = mainText
        title.alignment = .center
        title.frame = NSRect(x: 20, y: 42, width: 324, height: 26)
        card.addSubview(title)
        let sub = chip("Connect a monitor", fill: NSColor.black.withAlphaComponent(0.22), text: mutedText)
        sub.font = .systemFont(ofSize: 11, weight: .black)
        sub.frame = NSRect(x: 109, y: 17, width: 146, height: 24)
        card.addSubview(sub)
        return card
    }

    private func permissionPanel() -> NSView {
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 364, height: 42))
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 14
        panel.layer?.backgroundColor = NSColor(calibratedRed: 0.18, green: 0.13, blue: 0.09, alpha: 0.96).cgColor

        let label = NSTextField(labelWithString: "Shortcuts need Accessibility permission")
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = mainText
        label.frame = NSRect(x: 12, y: 13, width: 220, height: 16)
        panel.addSubview(label)

        let button = NSButton(title: "Open", target: self, action: #selector(openAccessibilitySettings))
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11, weight: .bold)
        button.frame = NSRect(x: 282, y: 8, width: 66, height: 26)
        panel.addSubview(button)
        return panel
    }

    private func footer() -> NSView {
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 364, height: 48))
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 15
        panel.layer?.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.10, blue: 0.09, alpha: 0.90).cgColor

        let sync = NSButton(title: state.syncExternalDisplays ? "Sync On" : "Sync Off", target: self, action: #selector(syncTapped))
        sync.bezelStyle = .rounded
        sync.font = .systemFont(ofSize: 12, weight: .bold)
        sync.frame = NSRect(x: 18, y: 10, width: 154, height: 28)
        panel.addSubview(sync)

        let shortcuts = NSButton(title: "Shortcuts", target: self, action: #selector(shortcutsTapped))
        shortcuts.bezelStyle = .rounded
        shortcuts.font = .systemFont(ofSize: 12, weight: .bold)
        shortcuts.frame = NSRect(x: 192, y: 10, width: 154, height: 28)
        panel.addSubview(shortcuts)
        return panel
    }

    private func symbolButton(_ symbol: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 0, y: 0, width: 38, height: 32)
        return button
    }

    private func chip(_ title: String, fill: NSColor, text: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.alignment = .center
        field.textColor = text
        field.wantsLayer = true
        field.layer?.cornerRadius = 12
        field.layer?.backgroundColor = fill.cgColor
        return field
    }

    @objc private func refreshTapped() {
        refresh()
    }

    @objc private func quitTapped() {
        quit()
    }

    @objc private func shortcutsTapped() {
        showTransientPanel(
            title: "Shortcuts",
            lines: [
                "Cursor display: fn + F1 / fn + F2",
                "Fallback: command + option + - / =",
                "Mac F1/F2 stays native"
            ]
        )
    }

    @objc private func syncTapped() {
        toggleSync()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func showTransientPanel(title: String, lines: [String]) {
        if transientPanelTitle == title {
            shortcutsPanel?.removeFromSuperview()
            shortcutsPanel = nil
            transientPanelTitle = nil
            return
        }
        shortcutsPanel?.removeFromSuperview()

        let panel = NSView(frame: NSRect(x: 18, y: 70, width: 364, height: 104))
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 18
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        panel.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.11, alpha: 0.98).cgColor

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 17, weight: .black)
        titleField.textColor = mainText
        titleField.frame = NSRect(x: 18, y: 70, width: 220, height: 24)
        panel.addSubview(titleField)

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeTransientPanel))
        closeButton.bezelStyle = .rounded
        closeButton.font = .systemFont(ofSize: 12, weight: .bold)
        closeButton.frame = NSRect(x: 276, y: 68, width: 70, height: 26)
        panel.addSubview(closeButton)

        var y: CGFloat = 48
        for line in lines {
            let field = NSTextField(labelWithString: line)
            field.font = .systemFont(ofSize: 12, weight: .bold)
            field.textColor = mutedText
            field.frame = NSRect(x: 18, y: y, width: 326, height: 18)
            panel.addSubview(field)
            y -= 20
        }

        addSubview(panel)
        shortcutsPanel = panel
        transientPanelTitle = title
    }

    private func scheduleLiveApply(selector: String, value: Int) {
        guard lastScheduledValues[selector] != value else {
            return
        }
        lastScheduledValues[selector] = value
        liveApplyWorkItems[selector]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.apply(selector, value)
        }
        liveApplyWorkItems[selector] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.075, execute: workItem)
    }

    private func cancelPendingLiveApplies() {
        for workItem in liveApplyWorkItems.values {
            workItem.cancel()
        }
        liveApplyWorkItems.removeAll()
        lastScheduledValues.removeAll()
    }

    @objc private func closeTransientPanel() {
        shortcutsPanel?.removeFromSuperview()
        shortcutsPanel = nil
        transientPanelTitle = nil
    }

    private var mainText: NSColor { NSColor(calibratedRed: 0.93, green: 0.90, blue: 0.91, alpha: 1) }
    private var warmText: NSColor { NSColor(calibratedRed: 0.77, green: 0.68, blue: 0.71, alpha: 1) }
    private var mutedText: NSColor { NSColor(calibratedRed: 0.58, green: 0.53, blue: 0.57, alpha: 1) }
    private var peach: NSColor { NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.46, alpha: 1) }
    private var softGray: NSColor { NSColor(calibratedRed: 0.68, green: 0.66, blue: 0.65, alpha: 1) }
    private var panelFill: NSColor { NSColor.white.withAlphaComponent(0.075) }
}

final class CardView: NSView {
    var accentColor: NSColor = .systemOrange
    var isActive = false
    var isDimmed = false

    override func draw(_ dirtyRect: NSRect) {
        let fillAlpha: CGFloat = isDimmed ? 0.90 : 0.96
        NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: fillAlpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 22, yRadius: 22).fill()

        if isActive {
            accentColor.withAlphaComponent(0.36).setStroke()
        } else {
            NSColor.white.withAlphaComponent(0.06).setStroke()
        }
        let stroke = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 22, yRadius: 22)
        stroke.lineWidth = isActive ? 2 : 1
        stroke.stroke()

        accentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 5, height: bounds.height), xRadius: 2.5, yRadius: 2.5).fill()
    }
}

final class BrightnessBar: NSView {
    private var value: Int
    private var visualValue: CGFloat
    private var lastEmittedValue: Int
    private let controlEnabled: Bool
    private let onDragStart: () -> Void
    private let onChange: (Int) -> Void
    private let onCommit: (Int) -> Void
    private let fill: NSColor
    private let track = NSColor(calibratedRed: 0.24, green: 0.21, blue: 0.19, alpha: 1)
    private let knob = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.55, alpha: 1)
    private var isTracking = false

    init(
        frame: NSRect,
        value: Int,
        isEnabled: Bool,
        fillColor: NSColor,
        onDragStart: @escaping () -> Void,
        onChange: @escaping (Int) -> Void,
        onCommit: @escaping (Int) -> Void
    ) {
        let clampedValue = min(100, max(0, value))
        self.value = clampedValue
        self.visualValue = CGFloat(clampedValue)
        self.lastEmittedValue = clampedValue
        self.controlEnabled = isEnabled
        self.fill = fillColor
        self.onDragStart = onDragStart
        self.onChange = onChange
        self.onCommit = onCommit
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        toolTip = "Drag to change brightness"
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        controlEnabled
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        controlEnabled
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = controlEnabled ? 1 : 0.42
        let bar = trackRect

        track.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()

        let fillWidth = bar.width * visualValue / 100
        let fillRect = NSRect(x: bar.minX, y: bar.minY, width: fillWidth, height: bar.height)
        if fillRect.width > 0 {
            NSGradient(colors: [
                fill.withAlphaComponent(alpha * 0.86),
                knob.withAlphaComponent(alpha)
            ])?.draw(
                in: NSBezierPath(roundedRect: fillRect, xRadius: bar.height / 2, yRadius: bar.height / 2),
                angle: 0
            )
        }

        let knobX = bar.minX + fillWidth
        let knobSize: CGFloat = isTracking ? 29 : 26
        let knobRect = NSRect(x: knobX - knobSize / 2, y: bar.midY - knobSize / 2, width: knobSize, height: knobSize)
        NSColor.black.withAlphaComponent(0.24).setFill()
        NSBezierPath(ovalIn: knobRect.offsetBy(dx: 0, dy: -1.5)).fill()
        knob.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: knobRect).fill()
        NSColor.white.withAlphaComponent(0.20).setStroke()
        NSBezierPath(ovalIn: knobRect.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard controlEnabled else {
            return
        }

        isTracking = true
        needsDisplay = true
        onDragStart()
        updateValue(from: event)
        var keepTracking = true
        while keepTracking, let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch next.type {
            case .leftMouseDragged:
                updateValue(from: next)
            case .leftMouseUp:
                updateValue(from: next)
                keepTracking = false
            default:
                break
            }
        }
        isTracking = false
        needsDisplay = true
        onCommit(value)
    }

    private func updateValue(from event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let bar = trackRect
        let ratio = min(1, max(0, (point.x - bar.minX) / bar.width))
        visualValue = ratio * 100
        value = Int(visualValue.rounded())
        if value != lastEmittedValue {
            lastEmittedValue = value
            onChange(value)
        }
        needsDisplay = true
    }

    private var trackRect: NSRect {
        NSRect(x: 8, y: bounds.midY - 5, width: bounds.width - 16, height: 10)
    }
}

final class PeachSliderCell: NSSliderCell {
    private let fill = NSColor(calibratedRed: 1.0, green: 0.73, blue: 0.46, alpha: 1)
    private let track = NSColor(calibratedRed: 0.22, green: 0.19, blue: 0.17, alpha: 1)
    private let knob = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.55, alpha: 1)

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 5, width: rect.width, height: 10)
        track.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5).fill()

        let range = maxValue - minValue
        let ratio = range == 0 ? 0 : CGFloat((doubleValue - minValue) / range)
        let fillRect = NSRect(x: bar.minX, y: bar.minY, width: bar.width * max(0, min(1, ratio)), height: bar.height)
        fill.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 5, yRadius: 5).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let rect = knobRect.insetBy(dx: -2, dy: -2)
        knob.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

let app = NSApplication.shared
let delegate = MenuBarApp()
app.delegate = delegate
app.run()
