import Darwin
import Foundation
import GlowKeyCore

struct HotkeyProcessManager {
    private let paths = RuntimePaths()

    func start(step: Int, selector: String, downShortcut: String, upShortcut: String, debug: Bool = false) throws {
        if status().isRunning {
            stop()
        }

        let helperURL = try helperExecutableURL()
        let glowkeyURL = try glowkeyExecutableURL()

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            "--glowkey", glowkeyURL.path,
            "--step", String(max(1, step)),
            "--selector", selector,
            "--down", downShortcut,
            "--up", upShortcut
        ]
        if debug {
            process.arguments?.append("--debug")
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        } else {
            process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        }
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        try process.run()
        try paths.ensureDirectory()
        try "\(process.processIdentifier)\n".write(to: paths.hotkeysPIDURL, atomically: true, encoding: .utf8)

        if debug {
            process.waitUntilExit()
        }
    }

    func stop() {
        var pidsToStop = Set<pid_t>()

        if let pid = knownPID(), processIsRunning(pid) {
            pidsToStop.insert(pid)
        } else {
            try? FileManager.default.removeItem(at: paths.hotkeysPIDURL)
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

        try? FileManager.default.removeItem(at: paths.hotkeysPIDURL)
    }

    func status() -> HotkeyProcessStatus {
        let pidFromFile = knownPID()
        var stalePIDRemoved = false

        if let pidFromFile {
            if processIsRunning(pidFromFile) {
                return HotkeyProcessStatus(
                    isRunning: true,
                    pid: pidFromFile,
                    isOrphaned: false,
                    stalePIDRemoved: false
                )
            }

            stalePIDRemoved = true
            try? FileManager.default.removeItem(at: paths.hotkeysPIDURL)
        }

        if let orphanPID = helperPIDsByName().first {
            return HotkeyProcessStatus(
                isRunning: true,
                pid: orphanPID,
                isOrphaned: true,
                stalePIDRemoved: stalePIDRemoved
            )
        }

        return HotkeyProcessStatus(
            isRunning: false,
            pid: nil,
            isOrphaned: false,
            stalePIDRemoved: stalePIDRemoved
        )
    }

    private func helperExecutableURL() throws -> URL {
        try ExecutableResolver.firstExecutable(
            named: "glowkey-hotkeys",
            missingMessage: "Hotkey helper is missing. Run `swift build`, then try again."
        )
    }

    private func glowkeyExecutableURL() throws -> URL {
        try ExecutableResolver.firstExecutable(
            named: "glowkey",
            includeCurrentExecutableIfNamed: true,
            missingMessage: "GlowKey executable is missing. Run `swift build`, then try again."
        )
    }

    private func knownPID() -> pid_t? {
        guard
            let data = try? Data(contentsOf: paths.hotkeysPIDURL),
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
        process.arguments = ["-f", "glowkey-hotkeys"]

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

        let currentPID = getpid()
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 != currentPID }
            .filter(processIsRunning)
    }
}

struct HotkeyProcessStatus {
    let isRunning: Bool
    let pid: pid_t?
    let isOrphaned: Bool
    let stalePIDRemoved: Bool
}
