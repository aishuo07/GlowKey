import Foundation

public struct RuntimeState: Codable, Equatable, Sendable {
    public let brightness: Int
    public let selector: String
    public let displayBrightness: [String: Int]
    public let overlayEnabled: Bool
    public let overlayBrightness: Int?
    public let method: RuntimeControlMethod
    public let syncExternalDisplays: Bool

    public init(
        brightness: Int,
        selector: String,
        displayBrightness: [String: Int] = [:],
        overlayEnabled: Bool,
        overlayBrightness: Int? = nil,
        method: RuntimeControlMethod = .normalBrightness,
        syncExternalDisplays: Bool = false
    ) {
        self.brightness = min(100, max(0, brightness))
        self.selector = selector
        self.displayBrightness = displayBrightness.mapValues { min(100, max(0, $0)) }
        self.overlayEnabled = overlayEnabled
        self.overlayBrightness = overlayBrightness.map { min(100, max(0, $0)) }
        self.method = method
        self.syncExternalDisplays = syncExternalDisplays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        brightness = min(100, max(0, try container.decode(Int.self, forKey: .brightness)))
        selector = try container.decode(String.self, forKey: .selector)
        let rawDisplayBrightness = try container.decodeIfPresent([String: Int].self, forKey: .displayBrightness)
            ?? [selector: brightness]
        displayBrightness = rawDisplayBrightness.mapValues { min(100, max(0, $0)) }
        overlayEnabled = try container.decode(Bool.self, forKey: .overlayEnabled)
        overlayBrightness = try container.decodeIfPresent(Int.self, forKey: .overlayBrightness).map { min(100, max(0, $0)) }
        method = try container.decodeIfPresent(RuntimeControlMethod.self, forKey: .method) ?? (overlayEnabled ? .softwareDimming : .normalBrightness)
        syncExternalDisplays = try container.decodeIfPresent(Bool.self, forKey: .syncExternalDisplays) ?? false
    }

    public static let defaultValue = RuntimeState(
        brightness: 100,
        selector: "external",
        displayBrightness: [:],
        overlayEnabled: false,
        overlayBrightness: nil,
        method: .normalBrightness,
        syncExternalDisplays: false
    )

    private enum CodingKeys: String, CodingKey {
        case brightness
        case selector
        case displayBrightness
        case overlayEnabled
        case overlayBrightness
        case method
        case syncExternalDisplays
    }
}

public enum RuntimeControlMethod: String, Codable, Sendable {
    case normalBrightness = "Normal brightness"
    case realBrightness = "Real brightness"
    case softwareDimming = "Software dimming"
}

public struct RuntimePaths: Sendable {
    public let directoryURL: URL
    public let stateURL: URL
    public let profileCacheURL: URL
    public let shadePIDURL: URL
    public let hotkeysPIDURL: URL
    public let daemonPIDURL: URL
    public let menubarPIDURL: URL

    public init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directoryURL = baseURL.appendingPathComponent("GlowKey", isDirectory: true)
        RuntimePaths.migrateLegacyStateIfNeeded(from: baseURL, to: directoryURL)
        self.directoryURL = directoryURL
        self.stateURL = directoryURL.appendingPathComponent("state.json")
        self.profileCacheURL = directoryURL.appendingPathComponent("profiles.json")
        self.shadePIDURL = directoryURL.appendingPathComponent("shade.pid")
        self.hotkeysPIDURL = directoryURL.appendingPathComponent("hotkeys.pid")
        self.daemonPIDURL = directoryURL.appendingPathComponent("daemon.pid")
        self.menubarPIDURL = directoryURL.appendingPathComponent("menubar.pid")
    }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private static func migrateLegacyStateIfNeeded(from baseURL: URL, to directoryURL: URL) {
        let fileManager = FileManager.default
        let legacyDirectoryURL = baseURL.appendingPathComponent("LumenSync", isDirectory: true)

        guard
            fileManager.fileExists(atPath: legacyDirectoryURL.path),
            !fileManager.fileExists(atPath: directoryURL.path)
        else {
            return
        }

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for filename in ["state.json", "profiles.json"] {
                let source = legacyDirectoryURL.appendingPathComponent(filename)
                let destination = directoryURL.appendingPathComponent(filename)
                guard fileManager.fileExists(atPath: source.path) else {
                    continue
                }
                try fileManager.copyItem(at: source, to: destination)
            }
        } catch {
            // Migration is best-effort; GlowKey can recreate state if old files are unavailable.
        }
    }
}

public struct RuntimeStateStore: Sendable {
    private let paths: RuntimePaths

    public init(paths: RuntimePaths = RuntimePaths()) {
        self.paths = paths
    }

    public func load() throws -> RuntimeState {
        guard let data = try? Data(contentsOf: paths.stateURL) else {
            return .defaultValue
        }

        if let runtimeState = try? JSONDecoder().decode(RuntimeState.self, from: data) {
            return runtimeState
        }

        if let legacyState = try? JSONDecoder().decode(LegacyBrightnessState.self, from: data) {
            return RuntimeState(
                brightness: legacyState.percentage,
                selector: "external",
                displayBrightness: ["external": legacyState.percentage],
                overlayEnabled: legacyState.percentage < 100,
                overlayBrightness: legacyState.percentage < 100 ? legacyState.percentage : nil,
                method: legacyState.percentage < 100 ? .softwareDimming : .normalBrightness
            )
        }

        if let oldRuntimeState = try? JSONDecoder().decode(LegacyRuntimeState.self, from: data) {
            return RuntimeState(
                brightness: oldRuntimeState.brightness,
                selector: oldRuntimeState.selector,
                displayBrightness: [oldRuntimeState.selector: oldRuntimeState.brightness],
                overlayEnabled: oldRuntimeState.overlayEnabled,
                overlayBrightness: oldRuntimeState.overlayEnabled ? oldRuntimeState.brightness : nil,
                method: oldRuntimeState.overlayEnabled ? .softwareDimming : .normalBrightness
            )
        }

        return .defaultValue
    }

    public func save(_ state: RuntimeState) throws {
        try paths.ensureDirectory()
        let data = try JSONEncoder().encode(state)
        try data.write(to: paths.stateURL, options: [.atomic])
    }
}

private struct LegacyBrightnessState: Codable {
    let percentage: Int
}

private struct LegacyRuntimeState: Codable {
    let brightness: Int
    let selector: String
    let overlayEnabled: Bool
}
