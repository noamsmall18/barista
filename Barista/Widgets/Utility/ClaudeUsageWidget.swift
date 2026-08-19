import Cocoa
import Darwin

// MARK: - Config

struct ClaudeUsageConfig: Codable, Equatable {
    var autoRefresh: Bool
    var refreshInterval: TimeInterval  // minutes
    var showInMenuBar: ShowInBar
    var accentColor: CCAccent

    static let `default` = ClaudeUsageConfig(
        autoRefresh: true,
        refreshInterval: 1,
        showInMenuBar: .percentage,
        accentColor: .orange
    )

    enum ShowInBar: String, Codable, Equatable {
        case percentage    // "CC 45%"
        case fraction      // "CC 180/400"
        case statusOnly    // "CC" + color dot
    }

    enum CCAccent: String, Codable, Equatable, CaseIterable {
        case orange, cyan, blue, green, purple, white

        var color: NSColor {
            switch self {
            case .orange: return NSColor(red: 0.92, green: 0.55, blue: 0.20, alpha: 1)
            case .cyan:   return NSColor(red: 0.30, green: 0.85, blue: 0.90, alpha: 1)
            case .blue:   return NSColor(red: 0.30, green: 0.65, blue: 0.95, alpha: 1)
            case .green:  return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)
            case .purple: return NSColor(red: 0.65, green: 0.45, blue: 0.90, alpha: 1)
            case .white:  return NSColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
            }
        }
    }
}

// MARK: - Parsed Usage Data

struct ClaudeUsageData {
    var currentUsed: Double = 0    // e.g. 180.5
    var currentLimit: Double = 0   // e.g. 400
    var currentUnit: String = ""   // e.g. "turns" or "messages"
    var percentage: Double = 0     // 0-100
    var resetTime: String = ""     // e.g. "in 3 hours"
    var plan: String = ""          // e.g. "Max" or "Pro"
    var rawLines: [String] = []    // all non-empty lines for fallback display
    var fetchTime: Date = Date()
    var isValid: Bool = false
}

// MARK: - Widget

class ClaudeUsageWidget: BaristaWidget {
    static let widgetID = "claude-usage"
    static let displayName = "Claude Code Usage"
    static let subtitle = "Live Claude Code session & usage stats"
    static let iconName = "chevron.left.forwardslash.chevron.right"
    static let category = WidgetCategory.utility
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = ClaudeUsageConfig.default

    var config: ClaudeUsageConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { nil } // We handle our own timer

    private var timer: Timer?
    private(set) var usageData = ClaudeUsageData()
    private(set) var isFetching = false
    private(set) var lastError: String?

    // PTY state
    private var childPid: pid_t = 0
    private var masterFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timeoutWork: DispatchWorkItem?
    private var idleWork: DispatchWorkItem?
    private var scanBuffer = ""
    private var captureBuffer = ""
    private var stage: FetchStage = .idle

    private enum FetchStage {
        case idle
        case waitingForBanner
        case waitingForPrompt
        case waitingForResult
        case capturing
    }

    // fork() workaround: Swift marks fork() unavailable, access via dlsym
    private static let _fork: @convention(c) () -> pid_t = {
        let handle = dlopen(nil, RTLD_LAZY)
        let sym = dlsym(handle, "fork")
        return unsafeBitCast(sym, to: (@convention(c) () -> pid_t).self)
    }()

    required init(config: ClaudeUsageConfig) {
        self.config = config
    }

    func start() {
        // Fetch immediately on start
        fetchUsage()

        // Set up auto-refresh timer if enabled
        if config.autoRefresh {
            let interval = config.refreshInterval * 60 // convert minutes to seconds
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.fetchUsage()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        teardownSession()
    }

    func refresh() {
        stop()
        start()
    }

    // MARK: - Fetch Usage via PTY

    func fetchUsage() {
        guard !isFetching else { return }
        isFetching = true
        lastError = nil
        scanBuffer = ""
        captureBuffer = ""
        stage = .waitingForBanner
        onDisplayUpdate?()

        launchClaudeSession()
    }

    private func launchClaudeSession() {
        // Find claude binary
        let claudePath = Self.findClaude()
        guard !claudePath.isEmpty else {
            isFetching = false
            lastError = "Claude CLI not found. Install it and make sure 'claude' is on your PATH."
            onDisplayUpdate?()
            return
        }

        // Open PTY
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0 else {
            isFetching = false
            lastError = "Failed to open PTY"
            onDisplayUpdate?()
            return
        }
        guard let slaveNamePtr = ptsname(master) else {
            close(master)
            isFetching = false
            lastError = "Failed to get PTY slave name"
            onDisplayUpdate?()
            return
        }
        let slaveName = String(cString: slaveNamePtr)
        masterFd = master

        // Set terminal size
        var winSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 640, ws_ypixel: 0)
        _ = ioctl(master, UInt(TIOCSWINSZ), &winSize)

        let pid = Self._fork()
        guard pid >= 0 else {
            close(master)
            masterFd = -1
            isFetching = false
            lastError = "fork() failed"
            onDisplayUpdate?()
            return
        }

        if pid == 0 {
            // Child process
            close(master)
            _ = setsid()
            let slave = slaveName.withCString { open($0, O_RDWR) }
            guard slave >= 0 else { _exit(1) }
            _ = ioctl(slave, UInt(TIOCSCTTY), 0)
            _ = dup2(slave, STDIN_FILENO)
            _ = dup2(slave, STDOUT_FILENO)
            _ = dup2(slave, STDERR_FILENO)
            if slave > STDERR_FILENO { close(slave) }
            _ = setenv("TERM", "xterm-256color", 1)
            _ = setenv("COLORTERM", "truecolor", 1)
            // Start in temp dir so claude has no project context
            var template = "/tmp/barista-cc-XXXXXX".utf8CString.map { $0 }
            if mkdtemp(&template) != nil { _ = chdir(template) }
            // Use login shell so claude is on PATH
            var args: [UnsafeMutablePointer<Int8>?] = [
                strdup("/bin/zsh"), strdup("-l"), strdup("-c"), strdup("claude"), nil
            ]
            execv("/bin/zsh", &args)
            _exit(127)
        }

        // Parent
        childPid = pid

        // Set up read source
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(master, &buf, buf.count)
            guard n > 0 else { return }
            let chunk = String(data: Data(buf[0..<n]), encoding: .utf8)
                ?? String(data: Data(buf[0..<n]), encoding: .isoLatin1) ?? ""
            DispatchQueue.main.async { [weak self] in
                self?.handlePTYOutput(chunk)
            }
        }
        readSource = source
        source.resume()

        // Timeout after 25 seconds
        let timeout = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isFetching else { return }
                self.lastError = "Timed out waiting for Claude usage data"
                self.isFetching = false
                self.teardownSession()
                self.onDisplayUpdate?()
            }
        }
        timeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)

        // Monitor child exit
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            DispatchQueue.main.async {
                guard let self, self.childPid == pid else { return }
                self.childPid = 0
                if self.isFetching {
                    let exitCode = (status >> 8) & 0xff
                    if exitCode != 0 {
                        self.lastError = "claude exited with code \(exitCode)"
                        self.isFetching = false
                        self.teardownSession()
                        self.onDisplayUpdate?()
                    }
                }
            }
        }
    }

    // MARK: - PTY Output Handling

    private func handlePTYOutput(_ text: String) {
        let stripped = stripANSI(text)
        scanBuffer += stripped

        // Prevent unbounded growth
        if scanBuffer.count > 8192 {
            scanBuffer = String(scanBuffer.suffix(4096))
        }

        switch stage {
        case .idle:
            return

        case .waitingForBanner:
            // Check for setup/login prompts
            if scanBuffer.contains("Welcome to Claude Code")
                || scanBuffer.contains("Choose the text style")
                || scanBuffer.contains("can be used with your Claude subscription") {
                lastError = "Claude Code needs setup. Run 'claude' in your terminal first."
                isFetching = false
                teardownSession()
                onDisplayUpdate?()
                return
            }
            // Trust prompt - auto-confirm
            if scanBuffer.contains("Quick safety check") {
                scanBuffer = ""
                writeToPTY("\r")
            }
            // Banner detected - send /usage
            if scanBuffer.range(of: "Claude Code v\\d+", options: .regularExpression) != nil {
                stage = .waitingForPrompt
                scanBuffer = ""
                writeToPTY("/usage")
            }

        case .waitingForPrompt:
            // Wait for echo of /usage before sending enter
            if scanBuffer.contains("/usage") {
                stage = .waitingForResult
                scanBuffer = ""
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.writeToPTY("\r")
                }
            }

        case .waitingForResult:
            if scanBuffer.contains("rate_limit_error") {
                lastError = "Rate limited - try again in a moment"
                isFetching = false
                teardownSession()
                onDisplayUpdate?()
                return
            }
            if scanBuffer.contains("Current session") {
                stage = .capturing
                captureBuffer = ""
                scanBuffer = ""
                // Force full re-render via SIGWINCH
                let fd = masterFd
                if fd >= 0 {
                    DispatchQueue.global(qos: .userInitiated).async {
                        var ws = winsize(ws_row: 24, ws_col: 79, ws_xpixel: 0, ws_ypixel: 0)
                        _ = ioctl(fd, UInt(TIOCSWINSZ), &ws)
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
                            var ws = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 640, ws_ypixel: 0)
                            _ = ioctl(fd, UInt(TIOCSWINSZ), &ws)
                        }
                    }
                }
                rescheduleIdleTimer()
            }

        case .capturing:
            captureBuffer += stripped
            rescheduleIdleTimer()
        }
    }

    private func rescheduleIdleTimer() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.finalizeCapture()
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func finalizeCapture() {
        guard stage == .capturing else { return }
        timeoutWork?.cancel()
        idleWork?.cancel()
        stage = .idle

        // Parse the captured text into structured data
        let parsed = Self.parseUsageText(captureBuffer)
        usageData = parsed
        isFetching = false
        teardownSession()
        onDisplayUpdate?()
    }

    // MARK: - Parse Usage Output

    static func parseUsageText(_ text: String) -> ClaudeUsageData {
        var data = ClaudeUsageData()
        data.fetchTime = Date()

        // Clean up the text
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        data.rawLines = lines

        for line in lines {
            let lower = line.lowercased()

            // Look for percentage patterns like "45%" or "45.2%"
            if let pctRange = line.range(of: "\\d+\\.?\\d*%", options: .regularExpression) {
                let pctStr = String(line[pctRange]).replacingOccurrences(of: "%", with: "")
                if let pct = Double(pctStr) {
                    data.percentage = pct
                }
            }

            // Look for fraction patterns like "180/400" or "180.5/400"
            if let fracRange = line.range(of: "\\d+\\.?\\d*\\s*/\\s*\\d+\\.?\\d*", options: .regularExpression) {
                let fracStr = String(line[fracRange])
                let parts = fracStr.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let used = Double(parts[0]), let limit = Double(parts[1]) {
                    data.currentUsed = used
                    data.currentLimit = limit
                    if data.percentage == 0 && limit > 0 {
                        data.percentage = (used / limit) * 100
                    }
                }
            }

            // Look for unit (turns, messages, etc.)
            if lower.contains("turn") { data.currentUnit = "turns" }
            else if lower.contains("message") { data.currentUnit = "messages" }
            else if lower.contains("request") { data.currentUnit = "requests" }

            // Look for reset time
            if lower.contains("reset") || lower.contains("renew") {
                if let inRange = line.range(of: "in \\d+.*", options: .regularExpression) {
                    data.resetTime = String(line[inRange])
                }
            }

            // Look for plan name
            if lower.contains("max plan") || lower.contains("max") && lower.contains("plan") {
                data.plan = "Max"
            } else if lower.contains("pro plan") || lower.contains("pro") && lower.contains("plan") {
                data.plan = "Pro"
            } else if lower.contains("team plan") || lower.contains("team") && lower.contains("plan") {
                data.plan = "Team"
            } else if lower.contains("free plan") || lower.contains("free") && lower.contains("plan") {
                data.plan = "Free"
            }
        }

        data.isValid = data.currentLimit > 0 || data.percentage > 0 || !data.rawLines.isEmpty
        return data
    }

    // MARK: - PTY Helpers

    private func writeToPTY(_ text: String) {
        let fd = masterFd
        guard fd >= 0 else { return }
        text.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }
    }

    private func stripANSI(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: "\u{1B}(?:\\[[^@-~]*[@-~]|[^\\[])",
            with: " ",
            options: .regularExpression
        )
        return stripped.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    }

    private func teardownSession() {
        timeoutWork?.cancel(); timeoutWork = nil
        idleWork?.cancel(); idleWork = nil
        readSource?.cancel(); readSource = nil
        stage = .idle
        if childPid > 0 { kill(childPid, SIGTERM); childPid = 0 }
        if masterFd >= 0 { close(masterFd); masterFd = -1 }
    }

    static func findClaude() -> String {
        // Check common locations
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.npm/bin/claude",
            "\(NSHomeDirectory())/.nvm/versions/node/current/bin/claude",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Try which
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["claude"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}
        return ""
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        if isFetching {
            return .text("CC ...")
        }

        if let err = lastError {
            let short = err.count > 15 ? String(err.prefix(15)) + ".." : err
            return .text("CC \(short)")
        }

        guard usageData.isValid else {
            return .text("CC --")
        }

        switch config.showInMenuBar {
        case .percentage:
            return .text(String(format: "CC %.0f%%", usageData.percentage))
        case .fraction:
            if usageData.currentLimit > 0 {
                return .text(String(format: "CC %.0f/%.0f", usageData.currentUsed, usageData.currentLimit))
            }
            return .text(String(format: "CC %.0f%%", usageData.percentage))
        case .statusOnly:
            return .text("CC")
        }
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "CLAUDE USAGE", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}

// MARK: - Interactive Dropdown

extension ClaudeUsageWidget: InteractiveDropdown {
    var dropdownSize: NSSize {
        var h: CGFloat = 200 // header + usage card
        if !usageData.rawLines.isEmpty {
            h += CGFloat(min(usageData.rawLines.count, 10)) * 16 + 40
        }
        h += SuperWidgetKit.panelHeight + 8
        h += 50 // footer
        return NSSize(width: 340, height: min(max(h, 260), 660))
    }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 340
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        y = buildDropdownHeader(in: container, y: y, pad: pad, cw: cw)

        if isFetching {
            y = buildLoadingState(in: container, y: y, pad: pad, cw: cw)
        } else if let err = lastError {
            y = buildErrorState(err, in: container, y: y, pad: pad, cw: cw)
        } else if usageData.isValid {
            y = buildUsageCard(in: container, y: y, pad: pad, cw: cw)
            y = buildRawOutput(in: container, y: y, pad: pad, cw: cw)
        } else {
            y = buildEmptyState(in: container, y: y, pad: pad, cw: cw)
        }

        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
        buildDropdownFooter(in: container, y: y, pad: pad, cw: cw)
        return container
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let accent = config.accentColor.color
        let pct = usageData.percentage
        let pctColor = pct < 50 ? Theme.green : pct < 80 ? Theme.orange : Theme.red
        let statusText: String
        if isFetching {
            statusText = "Fetching"
        } else if lastError != nil {
            statusText = "Error"
        } else if usageData.isValid {
            statusText = "Live"
        } else {
            statusText = "Idle"
        }
        let usedText = usageData.currentLimit > 0 ? String(format: "%.0f", usageData.currentUsed) : "--"
        let limitText = usageData.currentLimit > 0 ? String(format: "%.0f", usageData.currentLimit) : "--"
        let resetText = usageData.resetTime.isEmpty ? "Unknown" : usageData.resetTime
        let updatedText: String
        if usageData.isValid {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            updatedText = "Updated \(formatter.string(from: usageData.fetchTime))"
        } else {
            updatedText = "No usage snapshot"
        }
        let detailText = lastError ?? usageData.rawLines.first ?? "Click refresh to fetch Claude usage"

        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            metrics: [
                SuperWidgetMetric(label: "Status", value: statusText, color: lastError == nil ? accent : Theme.red),
                SuperWidgetMetric(label: "Used", value: usedText, color: pctColor),
                SuperWidgetMetric(label: "Limit", value: limitText, color: Theme.textSecondary),
                SuperWidgetMetric(label: "Pct", value: usageData.isValid ? String(format: "%.0f%%", pct) : "--", color: pctColor)
            ],
            insights: [
                detailText,
                usageData.plan.isEmpty ? "Plan unknown" : "\(usageData.plan) plan",
                updatedText
            ],
            actions: [
                "Reset \(resetText)",
                config.autoRefresh ? "Auto \(Int(config.refreshInterval))m" : "Manual",
                "Raw \(usageData.rawLines.count) lines"
            ],
            accent: lastError == nil ? accent : Theme.red
        )
    }

    private func buildDropdownHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let title = NSTextField(labelWithString: "Claude Code Usage")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 220, height: 20)
        container.addSubview(title)

        // Refresh button
        let refreshBtn = NSButton(frame: NSRect(x: pad + cw - 24, y: y - 22, width: 24, height: 24))
        refreshBtn.bezelStyle = .inline
        refreshBtn.isBordered = false
        refreshBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshBtn.contentTintColor = Theme.textMuted
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshTapped)
        container.addSubview(refreshBtn)

        var subParts: [String] = []
        if !usageData.plan.isEmpty { subParts.append("\(usageData.plan) Plan") }
        if usageData.isValid {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            subParts.append("Updated \(formatter.string(from: usageData.fetchTime))")
        }
        let sub = NSTextField(labelWithString: subParts.isEmpty ? "Click refresh to fetch" : subParts.joined(separator: "  \u{00B7}  "))
        sub.font = .systemFont(ofSize: 10, weight: .medium)
        sub.textColor = Theme.textMuted
        sub.frame = NSRect(x: pad, y: y - 36, width: cw - 30, height: 14)
        container.addSubview(sub)

        y -= 44
        addDropdownDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    @objc private func refreshTapped() {
        fetchUsage()
    }

    private func buildUsageCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let cardH: CGFloat = 90
        let card = makeDropdownCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        let accent = config.accentColor.color
        let pct = usageData.percentage
        let pctColor = pct < 50 ? NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)
            : pct < 80 ? NSColor(red: 0.95, green: 0.80, blue: 0.30, alpha: 1)
            : NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)

        // Large percentage
        let pctLabel = NSTextField(labelWithString: String(format: "%.0f%%", pct))
        pctLabel.font = .monospacedDigitSystemFont(ofSize: 32, weight: .heavy)
        pctLabel.textColor = pctColor
        pctLabel.frame = NSRect(x: 16, y: cardH - 52, width: 110, height: 38)
        card.addSubview(pctLabel)

        let usedLabel = NSTextField(labelWithString: "used")
        usedLabel.font = .systemFont(ofSize: 11, weight: .medium)
        usedLabel.textColor = Theme.textFaint
        usedLabel.frame = NSRect(x: 16, y: cardH - 66, width: 40, height: 14)
        card.addSubview(usedLabel)

        // Progress bar
        let barX: CGFloat = 16
        let barW = cw - 48
        let barH: CGFloat = 8
        let barY: CGFloat = 10
        let barBg = NSView(frame: NSRect(x: barX, y: barY, width: barW, height: barH))
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        barBg.layer?.cornerRadius = 4
        card.addSubview(barBg)

        let fillW = barW * CGFloat(min(pct / 100.0, 1.0))
        if fillW > 0 {
            let fill = NSView(frame: NSRect(x: barX, y: barY, width: fillW, height: barH))
            fill.wantsLayer = true
            fill.layer?.backgroundColor = pctColor.withAlphaComponent(0.7).cgColor
            fill.layer?.cornerRadius = 4
            card.addSubview(fill)
        }

        // Right side: fraction + unit + reset
        let rx: CGFloat = 130
        let rw = cw - rx - 24
        var ry = cardH - 22

        if usageData.currentLimit > 0 {
            let fracStr = String(format: "%.0f / %.0f", usageData.currentUsed, usageData.currentLimit)
            let fracLabel = NSTextField(labelWithString: fracStr)
            fracLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .bold)
            fracLabel.textColor = accent
            fracLabel.frame = NSRect(x: rx, y: ry, width: rw, height: 20)
            card.addSubview(fracLabel)
            ry -= 18

            if !usageData.currentUnit.isEmpty {
                let unitLabel = NSTextField(labelWithString: usageData.currentUnit)
                unitLabel.font = .systemFont(ofSize: 10, weight: .medium)
                unitLabel.textColor = Theme.textMuted
                unitLabel.frame = NSRect(x: rx, y: ry, width: rw, height: 14)
                card.addSubview(unitLabel)
                ry -= 16
            }
        }

        if !usageData.resetTime.isEmpty {
            let resetLabel = NSTextField(labelWithString: "Resets \(usageData.resetTime)")
            resetLabel.font = .systemFont(ofSize: 10, weight: .regular)
            resetLabel.textColor = Theme.textFaint
            resetLabel.frame = NSRect(x: rx, y: ry, width: rw, height: 14)
            card.addSubview(resetLabel)
        }

        y -= cardH + 8
        addDropdownDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    private func buildRawOutput(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        guard !usageData.rawLines.isEmpty else { return y }
        var y = y

        let header = Theme.sectionHeader("RAW OUTPUT")
        header.frame = NSRect(x: pad, y: y - 12, width: 100, height: 12)
        container.addSubview(header)
        y -= 18

        let lines = Array(usageData.rawLines.prefix(10))
        for line in lines {
            let display = line.count > 50 ? String(line.prefix(48)) + ".." : line
            let lbl = NSTextField(labelWithString: display)
            lbl.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            lbl.textColor = Theme.textSecondary
            lbl.lineBreakMode = .byTruncatingTail
            lbl.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
            container.addSubview(lbl)
            y -= 16
        }
        return y
    }

    private func buildLoadingState(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let lbl = NSTextField(labelWithString: "Fetching usage from Claude Code...")
        lbl.font = .systemFont(ofSize: 12, weight: .medium)
        lbl.textColor = Theme.textMuted
        lbl.alignment = .center
        lbl.frame = NSRect(x: pad, y: y - 40, width: cw, height: 20)
        container.addSubview(lbl)

        let sub = NSTextField(labelWithString: "Spawning claude session, this takes a few seconds")
        sub.font = .systemFont(ofSize: 10, weight: .regular)
        sub.textColor = Theme.textFaint
        sub.alignment = .center
        sub.frame = NSRect(x: pad, y: y - 58, width: cw, height: 14)
        container.addSubview(sub)
        y -= 70
        return y
    }

    private func buildErrorState(_ error: String, in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let lbl = NSTextField(labelWithString: error)
        lbl.font = .systemFont(ofSize: 11, weight: .medium)
        lbl.textColor = NSColor(red: 1.0, green: 0.40, blue: 0.35, alpha: 1)
        lbl.lineBreakMode = .byWordWrapping
        lbl.maximumNumberOfLines = 4
        lbl.frame = NSRect(x: pad, y: y - 60, width: cw, height: 60)
        container.addSubview(lbl)
        y -= 68
        return y
    }

    private func buildEmptyState(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let lbl = NSTextField(labelWithString: "No usage data yet")
        lbl.font = .systemFont(ofSize: 12, weight: .medium)
        lbl.textColor = Theme.textMuted
        lbl.alignment = .center
        lbl.frame = NSRect(x: pad, y: y - 30, width: cw, height: 20)
        container.addSubview(lbl)

        let sub = NSTextField(labelWithString: "Click the refresh button to fetch from Claude Code")
        sub.font = .systemFont(ofSize: 10, weight: .regular)
        sub.textColor = Theme.textFaint
        sub.alignment = .center
        sub.frame = NSRect(x: pad, y: y - 48, width: cw, height: 14)
        container.addSubview(sub)
        y -= 60
        return y
    }

    @discardableResult
    private func buildDropdownFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let y = y - 4
        var parts: [String] = ["Claude Code"]
        if config.autoRefresh {
            parts.append("auto-refresh \(Int(config.refreshInterval))m")
        } else {
            parts.append("manual refresh")
        }
        let footer = NSTextField(labelWithString: parts.joined(separator: "  \u{00B7}  "))
        footer.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        footer.textColor = Theme.textGhost; footer.alignment = .center
        footer.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
        container.addSubview(footer)
        return y - 18
    }

    // MARK: - UI Helpers

    private func makeDropdownCard(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: x, y: y, width: w, height: h))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        v.layer?.cornerRadius = 8
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        return v
    }

    private func addDropdownDivider(in container: NSView, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        let d = NSView(frame: NSRect(x: pad, y: y, width: cw, height: 1))
        d.wantsLayer = true
        d.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        container.addSubview(d)
        y -= 8
    }
}

// MARK: - Declarative Config

extension ClaudeUsageWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .picker(label: "Menu Bar Display", key: "showInMenuBar", options: [
                (title: "Percentage (CC 45%)", value: "percentage"),
                (title: "Fraction (CC 180/400)", value: "fraction"),
                (title: "Status Only (CC)", value: "statusOnly"),
            ], get: { [weak self] in self?.config.showInMenuBar.rawValue ?? "percentage" },
               set: { [weak self] in self?.config.showInMenuBar = ClaudeUsageConfig.ShowInBar(rawValue: $0) ?? .percentage }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Orange", value: "orange"),
                (title: "Cyan", value: "cyan"),
                (title: "Blue", value: "blue"),
                (title: "Green", value: "green"),
                (title: "Purple", value: "purple"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "orange" },
               set: { [weak self] in self?.config.accentColor = ClaudeUsageConfig.CCAccent(rawValue: $0) ?? .orange }),

            .section(title: "Refresh"),
            .toggle(label: "Auto-Refresh", key: "autoRefresh",
                    get: { [weak self] in self?.config.autoRefresh ?? false },
                    set: { [weak self] in self?.config.autoRefresh = $0 }),
            .slider(label: "Refresh Interval", key: "refreshInterval", min: 1, max: 15, step: 1,
                    get: { [weak self] in self?.config.refreshInterval ?? 1 },
                    set: { [weak self] in self?.config.refreshInterval = $0 },
                    format: "%.0f min"),
        ]
    }
}
