import Foundation

/// Runs shell scripts with timeout and captures stdout/stderr.
class ScriptRunner {
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let timedOut: Bool
    }

    /// Run a script file or inline command.
    static func run(
        command: String,
        shell: String = "/bin/zsh",
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30
    ) -> Result {
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
        // Make sure it's executable
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return run(command: path, shell: shell, timeout: timeout)
    }
}
