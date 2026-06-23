import AppKit
import CoreGraphics
import Darwin
import Foundation
import GlowKeyCore
import SwiftUI

@main
struct GlowKeyMenuBarApp: App {
    @NSApplicationDelegateAdaptor(GlowKeyMenuBarDelegate.self) private var appDelegate
    @StateObject private var model = GlowKeyMenuModel()

    var body: some Scene {
        MenuBarExtra {
            GlowKeyMenuView(model: model)
        } label: {
            Image(systemName: "sun.max.fill")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class GlowKeyMenuBarDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        bootstrapBackgroundServices()
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
}

@MainActor
final class GlowKeyMenuModel: ObservableObject {
    @Published private(set) var state = RuntimeState.defaultValue
    @Published private(set) var displays: [Display] = []
    @Published private(set) var displayBrightness: [CGDirectDisplayID: Int] = [:]
    @Published private(set) var shortcutsEnabled = false
    @Published var shortcutsExpanded = false

    private let controller = GlowKeyController()
    private let stateStore = RuntimeStateStore()
    private let applyCoordinator = MenuApplyCoordinator()
    private var refreshTimer: Timer?
    private var isDragging = false
    private var lastStateModifiedAt: Date?
    private var lastDisplaySignature = ""
    private var lastBrightnessSignature = ""

    init() {
        refresh()
        startAutoRefresh()
    }

    func refresh() {
        let nextState = (try? stateStore.load()) ?? .defaultValue
        let nextDisplays = (try? controller.displays()) ?? []
        let nextBrightness = currentBrightnessValues(for: nextDisplays, state: nextState)

        state = nextState
        displays = nextDisplays
        displayBrightness = nextBrightness
        shortcutsEnabled = shortcutsAreRunning()
        lastStateModifiedAt = stateModifiedAt()
        lastDisplaySignature = displaySignature(nextDisplays)
        lastBrightnessSignature = brightnessSignature(nextBrightness)
    }

    func brightness(for display: Display) -> Int {
        if let value = displayBrightness[display.id] {
            return value
        }

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

    func displayTitle(_ display: Display) -> String {
        if display.isBuiltin {
            return "MacBook Pro"
        }

        if display.name.lowercased().hasPrefix("external display") {
            return "External \(display.resolutionDescription)"
        }

        return display.name
    }

    func beginDragging() {
        isDragging = true
    }

    func liveSet(_ value: Int, for display: Display) {
        setLocalBrightness(value, for: display)
        guard let candidate = glowkeyExecutableURL() else {
            return
        }

        applyCoordinator.submitLive(
            executableURL: candidate,
            selector: selector(for: display),
            brightness: value
        )
    }

    func commit(_ value: Int, for display: Display) {
        setLocalBrightness(value, for: display)
        guard let candidate = glowkeyExecutableURL() else {
            isDragging = false
            return
        }

        applyCoordinator.submitCommit(
            executableURL: candidate,
            selector: selector(for: display),
            brightness: value
        ) { [weak self] in
            self?.isDragging = false
            self?.refresh()
        }
    }

    func toggleSync() {
        let enabled = !state.syncExternalDisplays
        state = RuntimeState(
            brightness: state.brightness,
            selector: state.selector,
            displayBrightness: state.displayBrightness,
            overlayEnabled: state.overlayEnabled,
            overlayBrightness: state.overlayBrightness,
            method: state.method,
            syncExternalDisplays: enabled
        )
        try? stateStore.save(state)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func quit() {
        NSApp.terminate(nil)
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

        let nextState = (try? stateStore.load()) ?? .defaultValue
        let nextDisplays = (try? controller.displays()) ?? []
        let nextBrightness = currentBrightnessValues(for: nextDisplays, state: nextState)
        let nextStateModifiedAt = stateModifiedAt()
        let nextDisplaySignature = displaySignature(nextDisplays)
        let nextBrightnessSignature = brightnessSignature(nextBrightness)

        guard nextStateModifiedAt != lastStateModifiedAt
            || nextDisplaySignature != lastDisplaySignature
            || nextBrightnessSignature != lastBrightnessSignature
        else {
            return
        }

        state = nextState
        displays = nextDisplays
        displayBrightness = nextBrightness
        shortcutsEnabled = shortcutsAreRunning()
        lastStateModifiedAt = nextStateModifiedAt
        lastDisplaySignature = nextDisplaySignature
        lastBrightnessSignature = nextBrightnessSignature
    }

    private func selector(for display: Display) -> String {
        state.syncExternalDisplays && !display.isBuiltin ? "external" : String(display.id)
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

    private func setLocalBrightness(_ value: Int, for display: Display) {
        let percentage = Brightness(value).percentage
        if state.syncExternalDisplays, !display.isBuiltin {
            for external in displays where !external.isBuiltin {
                displayBrightness[external.id] = percentage
            }
        } else {
            displayBrightness[display.id] = percentage
        }
    }

    private func currentBrightnessValues(for displays: [Display], state: RuntimeState) -> [CGDirectDisplayID: Int] {
        var values: [CGDirectDisplayID: Int] = [:]
        for display in displays {
            guard display.isBuiltin || !state.overlayEnabled else {
                continue
            }

            if let brightness = controller.currentBrightness(for: display) {
                values[display.id] = brightness
            }
        }
        return values
    }

    private func displaySignature(_ displays: [Display]) -> String {
        displays
            .map { "\($0.id):\($0.uuid):\($0.name):\($0.isOnline):\($0.isActive)" }
            .joined(separator: "|")
    }

    private func brightnessSignature(_ values: [CGDirectDisplayID: Int]) -> String {
        values
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "|")
    }

    private func stateModifiedAt() -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: RuntimePaths().stateURL.path)[.modificationDate] as? Date
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
}

private struct GlowKeyMenuView: View {
    @ObservedObject var model: GlowKeyMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.displays.isEmpty {
                Text("No displays found")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 58)
            } else {
                VStack(spacing: 10) {
                    ForEach(model.displays, id: \.id) { display in
                        DisplayBrightnessRow(display: display, model: model)
                    }
                }
            }

            if !model.shortcutsEnabled {
                permissionRow
            }

            shortcutsSection
            footer
        }
        .padding(16)
        .frame(width: 348)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 0) {
                Text("GlowKey")
                    .font(.headline.weight(.semibold))
                Text("Display brightness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh displays")

            Button {
                model.quit()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Quit GlowKey")
        }
    }

    private var permissionRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Shortcuts need access")
                    .font(.callout.weight(.semibold))
                Text("Enable Accessibility permission")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open") {
                model.openAccessibilitySettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var shortcutsSection: some View {
        DisclosureGroup(isExpanded: $model.shortcutsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ShortcutLine(title: "Cursor display", keys: "fn + F1 / F2")
                ShortcutLine(title: "Fallback", keys: "cmd + option + - / =")
            }
            .padding(.top, 8)
        } label: {
            Label("Shortcuts", systemImage: "keyboard")
                .font(.callout.weight(.semibold))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(model.state.syncExternalDisplays ? "Sync On" : "Sync Off") {
                model.toggleSync()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Spacer()

            Text(model.shortcutsEnabled ? "Shortcuts on" : "Shortcuts off")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DisplayBrightnessRow: View {
    let display: Display
    @ObservedObject var model: GlowKeyMenuModel

    var body: some View {
        let value = model.brightness(for: display)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                Text(model.displayTitle(display))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                Text("\(value)%")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }

            HStack(spacing: 10) {
                Image(systemName: "sun.min.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)

                WhiteBrightnessSlider(
                    value: value,
                    onEditingBegan: {
                        model.beginDragging()
                    },
                    onChange: { nextValue in
                        model.liveSet(nextValue, for: display)
                    },
                    onCommit: { nextValue in
                        model.commit(nextValue, for: display)
                    }
                )
                .frame(height: 26)

                Image(systemName: "sun.max.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct WhiteBrightnessSlider: View {
    let value: Int
    let onEditingBegan: () -> Void
    let onChange: (Int) -> Void
    let onCommit: (Int) -> Void

    @State private var dragValue: Int?
    @State private var isDragging = false

    private var displayedValue: Int {
        dragValue ?? value
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let ratio = CGFloat(displayedValue) / 100
            let knobSize: CGFloat = isDragging ? 24 : 21
            let trackHeight: CGFloat = 5
            let knobX = min(max(width * ratio, knobSize / 2), width - knobSize / 2)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(.white)
                    .frame(width: max(trackHeight, width * ratio), height: trackHeight)

                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                    .overlay {
                        Circle().stroke(.white.opacity(0.65), lineWidth: 1)
                    }
                    .offset(x: knobX - knobSize / 2)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingBegan()
                        }
                        let nextValue = valueFrom(locationX: gesture.location.x, width: width)
                        if dragValue != nextValue {
                            dragValue = nextValue
                            onChange(nextValue)
                        }
                    }
                    .onEnded { gesture in
                        let finalValue = valueFrom(locationX: gesture.location.x, width: width)
                        dragValue = nil
                        isDragging = false
                        onCommit(finalValue)
                    }
            )
        }
        .accessibilityLabel("Brightness")
        .accessibilityValue("\(displayedValue)%")
    }

    private func valueFrom(locationX: CGFloat, width: CGFloat) -> Int {
        let ratio = min(1, max(0, locationX / max(width, 1)))
        return Brightness(Int((ratio * 100).rounded())).percentage
    }
}

private struct ShortcutLine: View {
    let title: String
    let keys: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(keys)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
        .font(.caption)
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

private final class MenuApplyCoordinator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fyi.glowkey.menubar.apply", qos: .userInitiated)
    private let lock = NSLock()
    private var revisions: [String: Int] = [:]

    func submitLive(executableURL: URL, selector: String, brightness: Int) {
        let revision = nextRevision(for: selector)
        queue.async { [weak self] in
            guard self?.shouldRunLive(selector: selector, revision: revision) == true else {
                return
            }
            runProcess(
                executableURL,
                arguments: ["set", selector, String(Brightness(brightness).percentage)]
            )
        }
    }

    func submitCommit(
        executableURL: URL,
        selector: String,
        brightness: Int,
        completion: @escaping @MainActor () -> Void
    ) {
        _ = nextRevision(for: selector)
        queue.async {
            runProcess(
                executableURL,
                arguments: ["set", selector, String(Brightness(brightness).percentage)]
            )
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    private func nextRevision(for selector: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let revision = (revisions[selector] ?? 0) + 1
        revisions[selector] = revision
        return revision
    }

    private func shouldRunLive(selector: String, revision: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revisions[selector] == revision
    }
}
