import Foundation

/// Runs shell scripts with timeout and captures stdout/stderr.
class ScriptRunner {
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let timedOut: Bool
    }

    /// Allowed shells to prevent arbitrary executable invocation.
    private static let allowedShells: Set<String> = [
        "/bin/zsh", "/bin/bash", "/bin/sh",
        "/usr/bin/zsh", "/usr/bin/bash",
        "/usr/local/bin/bash", "/usr/local/bin/zsh",
        "/opt/homebrew/bin/bash", "/opt/homebrew/bin/zsh",
    ]

    /// Run a script file or inline command.
    static func run(
        command: String,
        shell: String = "/bin/zsh",
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30
    ) -> Result {
        // Validate shell is an allowed interpreter
        guard allowedShells.contains(shell) else {
            return Result(stdout: "", stderr: "Blocked: '\(shell)' is not an allowed shell", exitCode: -1, timedOut: false)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command] + arguments

        if let env = environment {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            process.environment = merged
        }

        if let dir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return Result(stdout: "", stderr: error.localizedDescription, exitCode: -1, timedOut: false)
        }

        // Timeout handling
        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()

        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }

        let waitResult = group.wait(timeout: deadline)
        if waitResult == .timedOut {
            process.terminate()
            return Result(stdout: "", stderr: "Script timed out after \(Int(timeout))s", exitCode: -1, timedOut: true)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return Result(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus, timedOut: false)
    }

    /// Run a script file directly.
    static func runFile(
        path: String,
        shell: String = "/bin/zsh",
        timeout: TimeInterval = 30
    ) -> Result {
        let fm = FileManager.default

        // Resolve to absolute path and check it exists
        let resolved = (path as NSString).standardizingPath
        guard fm.fileExists(atPath: resolved) else {
            return Result(stdout: "", stderr: "Script not found: \(resolved)", exitCode: -1, timedOut: false)
        }

        // Block paths outside user-accessible directories
        let blocked = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private/var", "/etc"]
        if blocked.contains(where: { resolved.hasPrefix($0) }) {
            return Result(stdout: "", stderr: "Blocked: cannot run scripts from \(resolved)", exitCode: -1, timedOut: false)
        }

        // Check file is executable; do NOT auto-chmod
        guard fm.isExecutableFile(atPath: resolved) else {
            return Result(stdout: "", stderr: "Script is not executable: \(resolved). Run chmod +x on it first.", exitCode: -1, timedOut: false)
        }

        return run(command: resolved, shell: shell, timeout: timeout)
    }
}
