import Cocoa

struct TopProcessesConfig: Codable, Equatable {
    var sortBy: SortMode
    var processCount: Int
    var showInMenuBar: ShowMode
    var refreshRate: TimeInterval

    enum SortMode: String, Codable, CaseIterable, Equatable {
        case cpu = "CPU"
        case memory = "Memory"
    }

    enum ShowMode: String, Codable, CaseIterable, Equatable {
        case topProcess = "Top Process"
        case summary = "Summary"
    }

    static let `default` = TopProcessesConfig(
        sortBy: .cpu,
        processCount: 8,
        showInMenuBar: .topProcess,
        refreshRate: 5
    )
}

struct ProcessInfo_Entry {
    let pid: pid_t
    let name: String
    var cpuPercent: Double
    var memoryMB: Double
}

class TopProcessesWidget: BaristaWidget, InteractiveDropdown {
    static let widgetID = "top-processes"
    static let displayName = "Top Processes"
    static let subtitle = "Activity Monitor in your menu bar"
    static let iconName = "list.bullet.rectangle"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = TopProcessesConfig.default

    var config: TopProcessesConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private(set) var processes: [ProcessInfo_Entry] = []
    private(set) var totalCPU: Double = 0
    private(set) var totalMemMB: Double = 0

    required init(config: TopProcessesConfig) {
        self.config = config
    }

    func start() {
        updateProcesses()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.updateProcesses()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Process Data

    private func updateProcesses() {
        // Use `ps` for reliable cross-architecture process info
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid,pcpu,rss,comm", "-r"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return }

        var entries: [ProcessInfo_Entry] = []
        var tCPU: Double = 0
        var tMem: Double = 0

        let lines = output.components(separatedBy: "\n").dropFirst() // skip header
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4 else { continue }

            guard let pid = pid_t(parts[0]),
                  let cpu = Double(parts[1]),
                  let rssKB = Double(parts[2]) else { continue }

            let name = String(parts[3]).components(separatedBy: "/").last ?? String(parts[3])
            let memMB = rssKB / 1024.0

            entries.append(ProcessInfo_Entry(pid: pid, name: name, cpuPercent: cpu, memoryMB: memMB))
            tCPU += cpu
            tMem += memMB
        }

        totalCPU = tCPU
        totalMemMB = tMem

        // Sort
        switch config.sortBy {
        case .cpu:
            entries.sort { $0.cpuPercent > $1.cpuPercent }
        case .memory:
            entries.sort { $0.memoryMB > $1.memoryMB }
        }

        // Keep top N
        processes = Array(entries.prefix(config.processCount))
        onDisplayUpdate?()
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        switch config.showInMenuBar {
        case .topProcess:
            guard let top = processes.first else { return .text("No processes") }
            let name = String(top.name.prefix(12))
            switch config.sortBy {
            case .cpu:
                return .text("\(name) \(Int(top.cpuPercent))%")
            case .memory:
                return .text(String(format: "%@ %.0fMB", name, top.memoryMB))
            }
        case .summary:
            let count = Foundation.ProcessInfo.processInfo.activeProcessorCount
            return .text(String(format: "CPU %.0f%% (%d cores)", totalCPU / Double(count), count))
        }
    }

    // MARK: - Dropdown Menu

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "TOP PROCESSES (by \(config.sortBy.rawValue))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        for (i, proc) in processes.enumerated() {
            let name = String(proc.name.prefix(20))
            let detail: String
            switch config.sortBy {
            case .cpu:
                detail = String(format: "%.1f%%", proc.cpuPercent)
            case .memory:
                detail = proc.memoryMB >= 1024
                    ? String(format: "%.1f GB", proc.memoryMB / 1024)
                    : String(format: "%.0f MB", proc.memoryMB)
            }
            let item = NSMenuItem(title: "\(i + 1). \(name) - \(detail)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if processes.isEmpty {
            let noData = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            noData.isEnabled = false
            menu.addItem(noData)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    // MARK: - Interactive Dropdown

    func buildDropdownPopover() -> NSView {
        let width: CGFloat = 380
        let rowH: CGFloat = 24
        let padding: CGFloat = 16
        let count = CGFloat(max(processes.count, 1))
        let height = padding + 20 + 8 + 20 + count * rowH + 8 + 16 + padding

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true

        var y = height - padding

        // Title
        let title = NSTextField(labelWithString: "Top Processes")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: padding, y: y - 18, width: width - padding * 2, height: 18)
        container.addSubview(title)
        y -= 28

        // Column headers
        let nameHeader = NSTextField(labelWithString: "PROCESS")
        nameHeader.font = .systemFont(ofSize: 9, weight: .medium)
        nameHeader.textColor = Theme.textMuted
        nameHeader.frame = NSRect(x: padding, y: y - 14, width: 160, height: 14)
        container.addSubview(nameHeader)

        let cpuHeader = NSTextField(labelWithString: "CPU")
        cpuHeader.font = .systemFont(ofSize: 9, weight: .medium)
        cpuHeader.textColor = Theme.textMuted
        cpuHeader.alignment = .right
        cpuHeader.frame = NSRect(x: width - padding - 160, y: y - 14, width: 70, height: 14)
        container.addSubview(cpuHeader)

        let memHeader = NSTextField(labelWithString: "MEMORY")
        memHeader.font = .systemFont(ofSize: 9, weight: .medium)
        memHeader.textColor = Theme.textMuted
        memHeader.alignment = .right
        memHeader.frame = NSRect(x: width - padding - 80, y: y - 14, width: 80, height: 14)
        container.addSubview(memHeader)
        y -= 20

        // Process rows
        if processes.isEmpty {
            let noData = NSTextField(labelWithString: "Loading...")
            noData.font = .systemFont(ofSize: 11)
            noData.textColor = Theme.textMuted
            noData.frame = NSRect(x: padding, y: y - 16, width: width - padding * 2, height: 16)
            container.addSubview(noData)
        } else {
            for proc in processes {
                let name = String(proc.name.prefix(24))
                let nameLabel = NSTextField(labelWithString: name)
                nameLabel.font = .systemFont(ofSize: 11)
                nameLabel.textColor = Theme.textSecondary
                nameLabel.frame = NSRect(x: padding, y: y - 18, width: 200, height: 18)
                container.addSubview(nameLabel)

                let cpuLabel = NSTextField(labelWithString: String(format: "%.1f%%", proc.cpuPercent))
                cpuLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                cpuLabel.textColor = proc.cpuPercent > 50 ? Theme.red : Theme.textSecondary
                cpuLabel.alignment = .right
                cpuLabel.frame = NSRect(x: width - padding - 160, y: y - 18, width: 70, height: 18)
                container.addSubview(cpuLabel)

                let memStr = proc.memoryMB >= 1024
                    ? String(format: "%.1f GB", proc.memoryMB / 1024)
                    : String(format: "%.0f MB", proc.memoryMB)
                let memLabel = NSTextField(labelWithString: memStr)
                memLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                memLabel.textColor = Theme.textSecondary
                memLabel.alignment = .right
                memLabel.frame = NSRect(x: width - padding - 80, y: y - 18, width: 80, height: 18)
                container.addSubview(memLabel)

                y -= rowH
            }
        }

        // Totals
        y -= 4
        let divider = NSView(frame: NSRect(x: padding, y: y, width: width - padding * 2, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.divider.cgColor
        container.addSubview(divider)
        y -= 4

        let totalStr = String(format: "Total: CPU %.0f%%  Memory %.1f GB", totalCPU, totalMemMB / 1024)
        let totalLabel = NSTextField(labelWithString: totalStr)
        totalLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        totalLabel.textColor = Theme.textMuted
        totalLabel.frame = NSRect(x: padding, y: y - 14, width: width - padding * 2, height: 14)
        container.addSubview(totalLabel)

        return container
    }

    var dropdownSize: NSSize {
        let rowH: CGFloat = 24
        let padding: CGFloat = 16
        let count = CGFloat(max(processes.count, 1))
        let height = padding + 20 + 8 + 20 + count * rowH + 8 + 16 + padding
        return NSSize(width: 380, height: max(height, 140))
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
