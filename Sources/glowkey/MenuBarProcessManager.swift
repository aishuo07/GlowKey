import Darwin
import Foundation
import GlowKeyCore

struct MenuBarProcessManager {
    private let paths = RuntimePaths()

    func start(open: Bool = false) throws {
        if status().isRunning {
            return
        }

        let process = Process()
        process.executableURL = try menuBarExecutableURL()
        if open {
            process.arguments = ["--open"]
        }
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")

        try process.run()
        try paths.ensureDirectory()
        try "\(process.processIdentifier)\n".write(to: paths.menubarPIDURL, atomically: true, encoding: .utf8)
    }

    func stop() {
        var pidsToStop = Set<pid_t>()

        if let pid = knownPID(), processIsRunning(pid) {
            pidsToStop.insert(pid)
        } else {
            try? FileManager.default.removeItem(at: paths.menubarPIDURL)
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

        try? FileManager.default.removeItem(at: paths.menubarPIDURL)
    }

    func status() -> MenuBarProcessStatus {
        let pidFromFile = knownPID()
        var stalePIDRemoved = false

        if let pidFromFile {
            if processIsRunning(pidFromFile) {
                return MenuBarProcessStatus(isRunning: true, pid: pidFromFile, isOrphaned: false, stalePIDRemoved: false)
            }

            stalePIDRemoved = true
            try? FileManager.default.removeItem(at: paths.menubarPIDURL)
        }

        if let orphanPID = helperPIDsByName().first {
            return MenuBarProcessStatus(isRunning: true, pid: orphanPID, isOrphaned: true, stalePIDRemoved: stalePIDRemoved)
        }

        return MenuBarProcessStatus(isRunning: false, pid: nil, isOrphaned: false, stalePIDRemoved: stalePIDRemoved)
    }

    private func menuBarExecutableURL() throws -> URL {
        try ExecutableResolver.firstExecutable(
            named: "glowkey-menubar",
            missingMessage: "Menu-bar helper is missing. Run `swift build`, then try again."
        )
    }

    private func knownPID() -> pid_t? {
        guard
            let data = try? Data(contentsOf: paths.menubarPIDURL),
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
        process.arguments = ["-f", "glowkey-menubar"]

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

struct MenuBarProcessStatus {
    let isRunning: Bool
    let pid: pid_t?
    let isOrphaned: Bool
    let stalePIDRemoved: Bool
}
