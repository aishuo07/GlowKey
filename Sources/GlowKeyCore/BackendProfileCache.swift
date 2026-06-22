import Foundation

public struct BackendProfileCache: Codable, Equatable, Sendable {
    public var displays: [String: BackendDisplayProfile]

    public init(displays: [String: BackendDisplayProfile] = [:]) {
        self.displays = displays
    }
}

public struct BackendDisplayProfile: Codable, Equatable, Sendable {
    public let displayKey: String
    public let method: RuntimeControlMethod
    public let serviceFingerprint: String
    public let updatedAt: Date

    public init(
        displayKey: String,
        method: RuntimeControlMethod,
        serviceFingerprint: String,
        updatedAt: Date = Date()
    ) {
        self.displayKey = displayKey
        self.method = method
        self.serviceFingerprint = serviceFingerprint
        self.updatedAt = updatedAt
    }
}

public struct BackendProfileCacheStore: Sendable {
    private let paths: RuntimePaths

    public init(paths: RuntimePaths = RuntimePaths()) {
        self.paths = paths
    }

    public func load() -> BackendProfileCache {
        guard let data = try? Data(contentsOf: paths.profileCacheURL),
              let cache = try? JSONDecoder().decode(BackendProfileCache.self, from: data)
        else {
            return BackendProfileCache()
        }

        return cache
    }

    public func profile(for displayKey: String) -> BackendDisplayProfile? {
        load().displays[displayKey]
    }

    public func save(_ profile: BackendDisplayProfile) {
        var cache = load()
        cache.displays[profile.displayKey] = profile
        save(cache)
    }

    public func removeProfile(for displayKey: String) {
        var cache = load()
        cache.displays.removeValue(forKey: displayKey)
        save(cache)
    }

    private func save(_ cache: BackendProfileCache) {
        do {
            try paths.ensureDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cache)
            try data.write(to: paths.profileCacheURL, options: [.atomic])
        } catch {
            // Cache failures must never block brightness control.
        }
    }
}
