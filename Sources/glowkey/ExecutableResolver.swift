import Foundation

enum ExecutableResolver {
    static func firstExecutable(
        named name: String,
        includeCurrentExecutableIfNamed: Bool = false,
        missingMessage: String
    ) throws -> URL {
        for candidate in candidates(named: name, includeCurrentExecutableIfNamed: includeCurrentExecutableIfNamed)
            where FileManager.default.isExecutableFile(atPath: candidate.path)
        {
            return candidate
        }

        throw CLIError.invalidUsage(missingMessage)
    }

    private static func candidates(named name: String, includeCurrentExecutableIfNamed: Bool) -> [URL] {
        let currentExecutable = resolvedCurrentExecutableURL()
        let currentDirectory = currentExecutable.deletingLastPathComponent()
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        var candidates: [URL] = []
        if includeCurrentExecutableIfNamed, currentExecutable.lastPathComponent == name {
            candidates.append(currentExecutable)
        }

        candidates.append(currentDirectory.appendingPathComponent(name))
        candidates.append(contentsOf: applicationExecutables(named: name))
        candidates.append(workingDirectory.appendingPathComponent(".build/release/\(name)"))
        candidates.append(workingDirectory.appendingPathComponent(".build/debug/\(name)"))

        var seen = Set<String>()
        return candidates.filter { url in
            let key = url.standardizedFileURL.path
            return seen.insert(key).inserted
        }
    }

    private static func resolvedCurrentExecutableURL() -> URL {
        let rawURL = URL(fileURLWithPath: CommandLine.arguments[0])
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: rawURL.path) else {
            return rawURL.resolvingSymlinksInPath()
        }

        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = rawURL.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return destinationURL.resolvingSymlinksInPath()
    }

    private static func applicationExecutables(named name: String) -> [URL] {
        let fileManager = FileManager.default
        let applicationDirectories =
            fileManager.urls(for: .applicationDirectory, in: .userDomainMask)
            + fileManager.urls(for: .applicationDirectory, in: .localDomainMask)

        return applicationDirectories.map {
            $0
                .appendingPathComponent("GlowKey.app", isDirectory: true)
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent(name)
        }
    }
}
