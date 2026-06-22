import Darwin
import Foundation
import GlowKeyCore

struct ShadeProcessManager {
    private let paths = RuntimePaths()

    func ensureRunning() throws {
        if status().isRunning {
            return
        }

        let helperURL = try helperExecutableURL()
        let process = Process()
        process.executableURL = helperURL
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")

        try process.run()
        try paths.ensureDirectory()
        try "\(process.processIdentifier)\n".write(to: paths.shadePIDURL, atomically: true, encoding: .utf8)
    }

    func stopIfRunning() {
        var pidsToStop = Set<pid_t>()

        if let pid = knownPID(), processIsRunning(pid) {
            pidsToStop.insert(pid)
        } else {
            try? FileManager.default.removeItem(at: paths.shadePIDURL)
        }

        for pid in helperPIDsByName() {
            pidsToStop.insert(pid)
        }

        for pid in pidsToStop {
            kill(pid, SIGTERM)
        }

        for pid in pidsToStop where processIsRunning(pid) {
            waitForExit(pid, timeoutSeconds: 0.5)
            if processIsRunning(pid) {
                kill(pid, SIGKILL)
            }
        }

        try? FileManager.default.removeItem(at: paths.shadePIDURL)
    }

    func status() -> ShadeProcessStatus {
        let pidFromFile = knownPID()
        var stalePIDRemoved = false

        if let pidFromFile {
            if processIsRunning(pidFromFile) {
                return ShadeProcessStatus(
                    isRunning: true,
                    pid: pidFromFile,
                    isOrphaned: false,
                    stalePIDRemoved: false
                )
            }

            stalePIDRemoved = true
            try? FileManager.default.removeItem(at: paths.shadePIDURL)
        }

        if let orphanPID = helperPIDsByName().first {
            return ShadeProcessStatus(
                isRunning: true,
                pid: orphanPID,
                isOrphaned: true,
                stalePIDRemoved: stalePIDRemoved
            )
        }

        return ShadeProcessStatus(
            isRunning: false,
            pid: nil,
            isOrphaned: false,
            stalePIDRemoved: stalePIDRemoved
        )
    }

    private func helperExecutableURL() throws -> URL {
        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
        let currentDirectory = currentExecutable.deletingLastPathComponent()
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            userApplicationExecutable("glowkey-shade"),
            currentDirectory.appendingPathComponent("glowkey-shade"),
            workingDirectory.appendingPathComponent(".build/debug/glowkey-shade"),
            workingDirectory.appendingPathComponent(".build/release/glowkey-shade")
        ].compactMap(\.self)

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        throw CLIError.invalidUsage("Shade helper is missing. Run `swift build`, then try again.")
    }

    private func userApplicationExecutable(_ name: String) -> URL? {
        FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GlowKey.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func knownPID() -> pid_t? {
        guard
            let data = try? Data(contentsOf: paths.shadePIDURL),
            let value = String(data: data, encoding: .utf8),
            let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }

        return pid
    }

    private func processIsRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func waitForExit(_ pid: pid_t, timeoutSeconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while processIsRunning(pid), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func helperPIDsByName() -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "glowkey-shade"]

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

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter(processIsRunning)
    }
}

struct ShadeProcessStatus {
    let isRunning: Bool
    let pid: pid_t?
    let isOrphaned: Bool
    let stalePIDRemoved: Bool
}
