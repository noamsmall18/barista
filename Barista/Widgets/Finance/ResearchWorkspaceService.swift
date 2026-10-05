import Cocoa
import Darwin

/// The browser's backend runs in its own process, with the parent flavor's
/// preferences domain and public-data services, and no menu-bar application.
enum ResearchWorkspaceService {
    struct Session: Codable {
        let url: URL
        var token: String { url.lastPathComponent }
        var port: UInt16? { url.port.flatMap(UInt16.init(exactly:)) }
    }

    static func configurationData(defaults: UserDefaults = ResearchWorkspaceDefaults.shared) -> Data? {
        defaults.synchronize()
        if let raw = defaults.data(forKey: "barista.activeWidgets"),
           let widgets = try? JSONDecoder().decode([SavedWidget].self, from: raw),
           let data = widgets.first(where: { $0.widgetID == StockTickerWidget.widgetID })?.configData { return data }
        if let raw = defaults.data(forKey: "barista.widgetMemory"),
           let memory = try? JSONDecoder().decode([String: Data].self, from: raw) { return memory[StockTickerWidget.widgetID] }
        return nil
    }

    static func configuration(defaults: UserDefaults = ResearchWorkspaceDefaults.shared) -> StockTickerConfig {
        configurationData(defaults: defaults).flatMap { try? JSONDecoder().decode(StockTickerConfig.self, from: $0) } ?? .default
    }

    static func run() {
        do {
            let args = CommandLine.arguments
            let directory: URL
            // An isolated session directory also allows integration checks to
            // use a temporary helper bundle and preferences domain.
            if let index = args.firstIndex(of: "--session-directory"), args.indices.contains(index + 1) {
                directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            } else {
                directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent(AppFlavor.current.displayName + "/Research", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let sessionFile = directory.appendingPathComponent("session.json")
            if args.contains("--stop") {
                reopen(sessionFile, shouldOpen: false, shouldStop: true, attempt: 0)
                RunLoop.main.run()
                return
            }
            let lock = Darwin.open(directory.appendingPathComponent("service.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lock >= 0 else { throw POSIXError(.EACCES) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(lock)
                reopen(sessionFile, shouldOpen: !args.contains("--no-open"), attempt: 0)
                RunLoop.main.run()
                return
            }
            // Hold the file descriptor for the process lifetime. Kernel releases
            // this lock on termination, including crashes and force quit.
            let previous = (try? Data(contentsOf: sessionFile)).flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
            let widget = StockTickerWidget(config: configuration(), notificationsEnabled: false)
            let server = PortfolioWebServer(widget: widget, token: previous?.token ?? UUID().uuidString + UUID().uuidString,
                preferredPort: previous?.port)
            server.start(onReady: { url in
                do {
                    try JSONEncoder().encode(Session(url: url)).write(to: sessionFile, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionFile.path)
                    print(url.absoluteString)
                    fflush(stdout)
                    if !args.contains("--no-open") { NSWorkspace.shared.open(url) }
                } catch { fail(error) }
            }, onFailure: { fail($0) })
            widget.start()
            var lastConfig = configurationData()
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                let data = configurationData()
                guard data != lastConfig else { return }
                lastConfig = data
                widget.applyResearchConfiguration(configuration())
            }
            // Keep all owners alive while the Foundation run loop serves HTTP,
            // provider callbacks, earnings/calendar refresh, and portfolio history.
            withExtendedLifetime((widget, server, timer, lock)) { RunLoop.main.run() }
        } catch { fail(error) }
    }

    private static func reopen(_ file: URL, shouldOpen: Bool, shouldStop: Bool = false, attempt: Int) {
        guard attempt < 25 else { fail(POSIXError(.ETIMEDOUT)) }
        guard let data = try? Data(contentsOf: file),
              let session = try? JSONDecoder().decode(Session.self, from: data) else {
            if shouldStop { exit(0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { reopen(file, shouldOpen: shouldOpen, attempt: attempt + 1) }
            return
        }
        var request = URLRequest(url: session.url.appendingPathComponent("health"))
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { data, response, _ in
            DispatchQueue.main.async {
                if (response as? HTTPURLResponse)?.statusCode == 200,
                   let data, let health = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   health["service"] as? String == "research-workspace" {
                    if shouldStop {
                        guard let pid = health["pid"] as? Int32, pid > 1 else { fail(POSIXError(.EINVAL)) }
                        guard Darwin.kill(pid, SIGTERM) == 0 || errno == ESRCH else { fail(POSIXError(.EPERM)) }
                        exit(0)
                    }
                    print(session.url.absoluteString)
                    fflush(stdout)
                    if shouldOpen { NSWorkspace.shared.open(session.url) }
                    exit(0)
                }
                if shouldStop { exit(0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { reopen(file, shouldOpen: shouldOpen, attempt: attempt + 1) }
            }
        }.resume()
    }

    private static func fail(_ error: Error) -> Never {
        fputs("Research workspace: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

/// Every dropdown launches the independent helper, even while the app is open.
/// Quitting the parent doesn't terminate Process children or the browser session.
enum ResearchWorkspaceLauncher {
    static func open() {
        guard let resources = Bundle.main.resourceURL else { return }
        let name = AppFlavor.current.displayName
        let installed = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(name + "/Research/Service.bundle/Contents/MacOS/" + name + "Research")
        let embedded = resources.appendingPathComponent("Research.bundle/Contents/MacOS/" + name + "Research")
        let executable = installed.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil } ?? embedded
        let process = Process()
        process.executableURL = executable
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't open research workspace"
            alert.informativeText = "Rebuild the app with build-app.sh to include the independent research helper. \(error.localizedDescription)"
            alert.runModal()
        }
    }
}
