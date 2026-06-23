import Darwin
import Foundation
import GlowKeyCore

struct DaemonProcessManager {
    private let paths = RuntimePaths()
    private let launchAgentLabel = "fyi.glowkey.daemon"
    private let legacyLaunchAgentLabel = "fyi.lumensync.daemon"

    func start() throws {
        if status().isRunning {
            return
        }

        let process = Process()
        process.executableURL = try daemonExecutableURL()
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")

        try process.run()
        try paths.ensureDirectory()
        try "\(process.processIdentifier)\n".write(to: paths.daemonPIDURL, atomically: true, encoding: .utf8)
    }

    func installLaunchAgent() throws {
        let daemonURL = try daemonExecutableURL()
        uninstallLegacyLaunchAgent()
        let launchAgentURL = try launchAgentURL(label: launchAgentLabel)
        try FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(launchAgentLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(daemonURL.path)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardOutPath</key>
          <string>/tmp/glowkey-daemon.out.log</string>
          <key>StandardErrorPath</key>
          <string>/tmp/glowkey-daemon.err.log</string>
        </dict>
        </plist>
        """

        try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
        _ = runLaunchctl(arguments: ["bootout", "gui/\(getuid())", launchAgentURL.path])
        try runLaunchctlOrThrow(arguments: ["bootstrap", "gui/\(getuid())", launchAgentURL.path])
        try runLaunchctlOrThrow(arguments: ["enable", "gui/\(getuid())/\(launchAgentLabel)"])
    }

    func uninstallLaunchAgent() {
        if let launchAgentURL = try? launchAgentURL(label: launchAgentLabel) {
            _ = runLaunchctl(arguments: ["bootout", "gui/\(getuid())", launchAgentURL.path])
            try? FileManager.default.removeItem(at: launchAgentURL)
        }
        uninstallLegacyLaunchAgent()
        stop()
    }

    func stop() {
        var pidsToStop = Set<pid_t>()

        if let pid = knownPID(), processIsRunning(pid) {
            pidsToStop.insert(pid)
        } else {
            try? FileManager.default.removeItem(at: paths.daemonPIDURL)
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

        try? FileManager.default.removeItem(at: paths.daemonPIDURL)
    }

    func status() -> DaemonProcessStatus {
        let pidFromFile = knownPID()
        var stalePIDRemoved = false

        if let pidFromFile {
            if processIsRunning(pidFromFile) {
                return DaemonProcessStatus(isRunning: true, pid: pidFromFile, isOrphaned: false, stalePIDRemoved: false)
            }

            stalePIDRemoved = true
            try? FileManager.default.removeItem(at: paths.daemonPIDURL)
        }

        if let orphanPID = helperPIDsByName().first {
            return DaemonProcessStatus(isRunning: true, pid: orphanPID, isOrphaned: true, stalePIDRemoved: stalePIDRemoved)
        }

        return DaemonProcessStatus(isRunning: false, pid: nil, isOrphaned: false, stalePIDRemoved: stalePIDRemoved)
    }

    private func daemonExecutableURL() throws -> URL {
        try ExecutableResolver.firstExecutable(
            named: "glowkey-daemon",
            missingMessage: "Daemon helper is missing. Run `swift build`, then try again."
        )
    }

    private func launchAgentURL(label: String) throws -> URL {
        guard let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            throw CLIError.invalidUsage("Unable to locate the user Library folder.")
        }

        return libraryURL
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private func uninstallLegacyLaunchAgent() {
        guard let launchAgentURL = try? launchAgentURL(label: legacyLaunchAgentLabel) else {
            return
        }
        _ = runLaunchctl(arguments: ["bootout", "gui/\(getuid())", launchAgentURL.path])
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    private func runLaunchctl(arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 1
        }
    }

    private func runLaunchctlOrThrow(arguments: [String]) throws {
        let status = runLaunchctl(arguments: arguments)
        guard status == 0 else {
            throw CLIError.invalidUsage("launchctl failed while configuring background mode.")
        }
    }

    private func knownPID() -> pid_t? {
        guard
            let data = try? Data(contentsOf: paths.daemonPIDURL),
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
        process.arguments = ["-f", "glowkey-daemon"]

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

struct DaemonProcessStatus {
    let isRunning: Bool
    let pid: pid_t?
    let isOrphaned: Bool
    let stalePIDRemoved: Bool
}
