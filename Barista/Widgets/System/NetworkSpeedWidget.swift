import Cocoa

struct NetworkSpeedConfig: Codable, Equatable {
    var showUpload: Bool
    var showDownload: Bool
    var compactFormat: Bool
    var refreshRate: TimeInterval

    static let `default` = NetworkSpeedConfig(
        showUpload: true,
        showDownload: true,
        compactFormat: true,
        refreshRate: 2
    )
}

class NetworkSpeedWidget: BaristaWidget {
    static let widgetID = "network-speed"
    static let displayName = "Network Speed"
    static let subtitle = "Live upload and download speeds"
    static let iconName = "network"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = NetworkSpeedConfig.default

    var config: NetworkSpeedConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private var lastBytesIn: UInt64 = 0
    private var lastBytesOut: UInt64 = 0
    private var lastTime: Date = Date()
    private(set) var downloadSpeed: Double = 0 // bytes/sec
    private(set) var uploadSpeed: Double = 0
    private(set) var sessionDownTotal: UInt64 = 0
    private(set) var sessionUpTotal: UInt64 = 0

    required init(config: NetworkSpeedConfig) {
        self.config = config
    }

    func start() {
        let (bytesIn, bytesOut) = getNetworkBytes()
        lastBytesIn = bytesIn
        lastBytesOut = bytesOut
        lastTime = Date()

        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.updateSpeeds()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func updateSpeeds() {
        let (bytesIn, bytesOut) = getNetworkBytes()
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime)
        guard elapsed > 0 else { return }

        if bytesIn >= lastBytesIn {
            let deltaIn = bytesIn - lastBytesIn
            downloadSpeed = Double(deltaIn) / elapsed
            sessionDownTotal += deltaIn
        }
        if bytesOut >= lastBytesOut {
            let deltaOut = bytesOut - lastBytesOut
            uploadSpeed = Double(deltaOut) / elapsed
            sessionUpTotal += deltaOut
        }

        lastBytesIn = bytesIn
        lastBytesOut = bytesOut
        lastTime = now
        onDisplayUpdate?()
    }

    private func getNetworkBytes() -> (UInt64, UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = ptr {
            let name = String(cString: addr.pointee.ifa_name)
            // Only count active network interfaces
            if name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("pdp_ip") {
                if let data = addr.pointee.ifa_data {
                    let networkData = data.assumingMemoryBound(to: if_data.self)
                    totalIn += UInt64(networkData.pointee.ifi_ibytes)
                    totalOut += UInt64(networkData.pointee.ifi_obytes)
                }
            }
            ptr = addr.pointee.ifa_next
        }

        return (totalIn, totalOut)
    }

    private func formatBytes(_ bytes: Double) -> String {
        if config.compactFormat {
            if bytes < 1024 { return "0K" }
            if bytes < 1_048_576 { return String(format: "%.0fK", bytes / 1024) }
            if bytes < 1_073_741_824 { return String(format: "%.1fM", bytes / 1_048_576) }
            return String(format: "%.1fG", bytes / 1_073_741_824)
        } else {
            if bytes < 1024 { return "0 KB/s" }
            if bytes < 1_048_576 { return String(format: "%.0f KB/s", bytes / 1024) }
            if bytes < 1_073_741_824 { return String(format: "%.1f MB/s", bytes / 1_048_576) }
            return String(format: "%.1f GB/s", bytes / 1_073_741_824)
        }
    }

    private func formatTotal(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b < 1_048_576 { return String(format: "%.0f KB", b / 1024) }
        if b < 1_073_741_824 { return String(format: "%.1f MB", b / 1_048_576) }
        return String(format: "%.2f GB", b / 1_073_741_824)
    }

    func render() -> WidgetDisplayMode {
        var parts: [String] = []
        if config.showDownload {
            parts.append("\u{2193}\(formatBytes(downloadSpeed))")
        }
        if config.showUpload {
            parts.append("\u{2191}\(formatBytes(uploadSpeed))")
        }
        return .text(parts.joined(separator: " "))
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "NETWORK", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let dlItem = NSMenuItem(title: "\u{2193} Download: \(formatBytes(downloadSpeed))/s", action: nil, keyEquivalent: "")
        dlItem.isEnabled = false
        menu.addItem(dlItem)

        let ulItem = NSMenuItem(title: "\u{2191} Upload: \(formatBytes(uploadSpeed))/s", action: nil, keyEquivalent: "")
        ulItem.isEnabled = false
        menu.addItem(ulItem)

        menu.addItem(NSMenuItem.separator())

        let totalDl = NSMenuItem(title: "Session Down: \(formatTotal(sessionDownTotal))", action: nil, keyEquivalent: "")
        totalDl.isEnabled = false
        menu.addItem(totalDl)

        let totalUl = NSMenuItem(title: "Session Up: \(formatTotal(sessionUpTotal))", action: nil, keyEquivalent: "")
        totalUl.isEnabled = false
        menu.addItem(totalUl)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func formatSpeedForCard(_ bytes: Double) -> String {
        if bytes < 1024 { return "0 KB/s" }
        if bytes < 1_048_576 { return String(format: "%.0f KB/s", bytes / 1024) }
        if bytes < 1_073_741_824 { return String(format: "%.1f MB/s", bytes / 1_048_576) }
        return String(format: "%.1f GB/s", bytes / 1_073_741_824)
    }

    func formatTotalForCard(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b < 1_048_576 { return String(format: "%.0f KB", b / 1024) }
        if b < 1_073_741_824 { return String(format: "%.1f MB", b / 1_048_576) }
        return String(format: "%.2f GB", b / 1_073_741_824)
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
