import Cocoa

struct GitBranchConfig: Codable, Equatable {
    var repoPath: String
    var showDirtyIndicator: Bool
    var showAheadBehind: Bool
    var truncateLength: Int

    static let `default` = GitBranchConfig(
        repoPath: "~",
        showDirtyIndicator: true,
        showAheadBehind: true,
        truncateLength: 20
    )
}

class GitBranchWidget: BaristaWidget {
    static let widgetID = "git-branch"
    static let displayName = "Git Branch"
    static let subtitle = "Current branch and status for a repo"
    static let iconName = "arrow.triangle.branch"
    static let category = WidgetCategory.developer
    static let allowsMultiple = true
    static let isPremium = false
    static let defaultConfig = GitBranchConfig.default

    var config: GitBranchConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 5 }

    private var timer: Timer?
    private(set) var branch: String = ""
    private(set) var isDirty: Bool = false
    private(set) var changedCount: Int = 0
    private(set) var ahead: Int = 0
    private(set) var behind: Int = 0
    private(set) var lastCommit: String = ""
    private(set) var isRepo: Bool = false

    required init(config: GitBranchConfig) {
        self.config = config
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.onDisplayUpdate?()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var resolvedPath: String {
        let p = config.repoPath
        if p.hasPrefix("~") {
            return (p as NSString).expandingTildeInPath
        }
        return p
    }

    private func runGit(_ args: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", resolvedPath] + args.components(separatedBy: " ")
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func refresh() {
        guard let b = runGit("branch --show-current"), !b.isEmpty else {
            // Maybe detached HEAD
            if let hash = runGit("rev-parse --short HEAD") {
                branch = hash
                isRepo = true
            } else {
                isRepo = false
                branch = ""
            }
            return
        }

        isRepo = true
        branch = b

        // Dirty status
        if let status = runGit("status --porcelain") {
            let lines = status.components(separatedBy: "\n").filter { !$0.isEmpty }
            changedCount = lines.count
            isDirty = changedCount > 0
        }

        // Ahead/behind
        if let revList = runGit("rev-list --count --left-right HEAD...@{upstream}") {
            let parts = revList.components(separatedBy: "\t")
            if parts.count == 2 {
                ahead = Int(parts[0]) ?? 0
                behind = Int(parts[1]) ?? 0
            }
        } else {
            ahead = 0
            behind = 0
        }

        // Last commit
        lastCommit = runGit("log --oneline -1") ?? ""
    }

    func render() -> WidgetDisplayMode {
        guard isRepo else { return .text("No repo") }

        var display = branch
        if display.count > config.truncateLength {
            display = String(display.prefix(config.truncateLength)) + "\u{2026}"
        }

        if config.showDirtyIndicator && isDirty {
            display += " \u{2022}\(changedCount)"
        }

        if config.showAheadBehind {
            if ahead > 0 { display += " \u{2191}\(ahead)" }
            if behind > 0 { display += " \u{2193}\(behind)" }
        }

        if !isDirty && !config.showAheadBehind {
            display += " \u{2713}"
        }

        return .text(display)
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "GIT BRANCH", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        guard isRepo else {
            let noRepo = NSMenuItem(title: "Not a git repository", action: nil, keyEquivalent: "")
            noRepo.isEnabled = false
            menu.addItem(noRepo)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
            return menu
        }

        let branchItem = NSMenuItem(title: "Branch: \(branch)", action: nil, keyEquivalent: "")
        branchItem.isEnabled = false
        menu.addItem(branchItem)

        let statusItem = NSMenuItem(title: isDirty ? "\(changedCount) changed files" : "Clean", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        if ahead > 0 || behind > 0 {
            let syncItem = NSMenuItem(title: "\u{2191}\(ahead) ahead  \u{2193}\(behind) behind", action: nil, keyEquivalent: "")
            syncItem.isEnabled = false
            menu.addItem(syncItem)
        }

        if !lastCommit.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let commitItem = NSMenuItem(title: "Last: \(lastCommit)", action: nil, keyEquivalent: "")
            commitItem.isEnabled = false
            menu.addItem(commitItem)
        }

        let pathItem = NSMenuItem(title: "Repo: \(resolvedPath)", action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        menu.addItem(pathItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
