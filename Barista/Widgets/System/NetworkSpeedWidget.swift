import Cocoa
import CoreWLAN

// MARK: - Config

struct NetworkSpeedConfig: Codable, Equatable {
    var displayMode: NetDisplayMode
    var showUpload: Bool
    var showDownload: Bool
    var compactFormat: Bool
    var unitMode: UnitMode
    var accentColor: NetAccentPreset
    var colorMode: NetColorMode
    var alertThreshold: Double     // MB/s - highlight when exceeded
    var showActiveInterface: Bool
    var showInterfacesInDropdown: Bool
    var showWiFiInfo: Bool
    var showLatency: Bool
    var refreshRate: TimeInterval
    var historyLength: Int

    static let `default` = NetworkSpeedConfig(
        displayMode: .text,
        showUpload: true,
        showDownload: true,
        compactFormat: true,
        unitMode: .auto,
        accentColor: .cyan,
        colorMode: .dynamic,
        alertThreshold: 10,
        showActiveInterface: false,
        showInterfacesInDropdown: true,
        showWiFiInfo: true,
        showLatency: true,
        refreshRate: 1,
        historyLength: 60
    )

    enum NetDisplayMode: String, Codable, Equatable {
        case text
        case sparkline
        case dualSparkline
        case compact
        case barGraph
    }

    enum UnitMode: String, Codable, Equatable {
        case auto
        case kbs
        case mbs
    }

    enum NetAccentPreset: String, Codable, Equatable, CaseIterable {
        case cyan, blue, green, amber, purple, red, white

        var color: NSColor {
            switch self {
            case .cyan:   return NSColor(red: 0.30, green: 0.85, blue: 0.90, alpha: 1)
            case .blue:   return NSColor(red: 0.30, green: 0.65, blue: 0.95, alpha: 1)
            case .green:  return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)
            case .amber:  return NSColor(red: 0.96, green: 0.66, blue: 0.23, alpha: 1)
            case .purple: return NSColor(red: 0.65, green: 0.45, blue: 0.90, alpha: 1)
            case .red:    return NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)
            case .white:  return NSColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
            }
        }
    }

    enum NetColorMode: String, Codable, Equatable {
        case dynamic // color intensity shifts with speed
        case fixed   // always uses accentColor
    }
}

// MARK: - Widget

class NetworkSpeedWidget: BaristaWidget {
    static let widgetID = "network-speed"
    static let displayName = "Network Speed"
    static let subtitle = "Live upload/download, Wi-Fi, latency & interfaces"
    static let iconName = "network"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = NetworkSpeedConfig.default

    var config: NetworkSpeedConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    // Speeds
    private var timer: Timer?
    private var lastBytesIn: UInt64 = 0
    private var lastBytesOut: UInt64 = 0
    private var lastTime: Date = Date()
    private(set) var downloadSpeed: Double = 0 // bytes/sec
    private(set) var uploadSpeed: Double = 0
    private(set) var sessionDownTotal: UInt64 = 0
    private(set) var sessionUpTotal: UInt64 = 0
    private(set) var peakDown: Double = 0
    private(set) var peakUp: Double = 0

    // History
    private(set) var downHistory: [Double] = []
    private(set) var upHistory: [Double] = []

    // Per-interface tracking
    private var prevInterfaceBytes: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var prevInterfaceTime: Date = Date()
    private(set) var interfaceSpeeds: [(name: String, downSpeed: Double, upSpeed: Double, totalIn: UInt64, totalOut: UInt64)] = []

    // Connection info
    private(set) var activeInterface: String = "---"
    private(set) var connectionType: String = "---"
    private(set) var externalIP: String = "---"
    private(set) var gatewayIP: String = "---"
    private(set) var gatewayLatency: Double = -1 // ms, -1 = unknown

    // Wi-Fi info (CoreWLAN)
    private(set) var wifiSSID: String?
    private(set) var wifiRSSI: Int = 0       // dBm
    private(set) var wifiNoise: Int = 0      // dBm
    private(set) var wifiTXRate: Double = 0  // Mbps
    private(set) var wifiChannel: Int = 0
    private(set) var wifiBand: String = ""

    // Counters for less-frequent tasks
    private var slowTickCounter = 0
    private var pingCounter = 0

    // Timer self-correction
    private var currentTimerInterval: TimeInterval = 0

    required init(config: NetworkSpeedConfig) {
        self.config = config
    }

    func start() {
        let rate = config.refreshRate
        currentTimerInterval = rate

        // Prime: take initial byte snapshots using AF_LINK-filtered data
        let (bytesIn, bytesOut) = getNetworkBytes()
        lastBytesIn = bytesIn
        lastBytesOut = bytesOut
        lastTime = Date()
        snapshotInterfaces()
        prevInterfaceTime = Date()

        // Async: detect interface, gateway, external IP, Wi-Fi
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.detectActiveInterfaceSync()
            self?.detectGatewaySync()
            self?.fetchExternalIPSync()
            self?.updateWiFiInfo()
            self?.measureLatencySync()
            DispatchQueue.main.async { self?.onDisplayUpdate?() }
        }

        timer = Timer.scheduledTimer(withTimeInterval: rate, repeats: true) { [weak self] _ in
            self?.updateAll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Update

    private func updateAll() {
        // Self-correct timer if refresh rate changed via config slider
        if currentTimerInterval != config.refreshRate {
            timer?.invalidate()
            timer = nil
            currentTimerInterval = config.refreshRate
            timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
                self?.updateAll()
            }
        }

        updateSpeeds()
        updateInterfaceSpeeds()
        updateWiFiInfo() // CoreWLAN is fast, ~0.1ms

        // Slow tasks on background thread every ~30s
        slowTickCounter += 1
        let ticksPer30s = max(Int(30.0 / config.refreshRate), 1)
        if slowTickCounter >= ticksPer30s {
            slowTickCounter = 0
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.detectActiveInterfaceSync()
                self?.detectGatewaySync()
                self?.fetchExternalIPSync()
                self?.measureLatencySync()
                DispatchQueue.main.async { self?.onDisplayUpdate?() }
            }
        }

        onDisplayUpdate?()
    }

    private func updateSpeeds() {
        let (bytesIn, bytesOut) = getNetworkBytes()
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime)
        guard elapsed > 0.1 else { return } // Skip if interval too small

        if bytesIn >= lastBytesIn {
            let deltaIn = bytesIn - lastBytesIn
            downloadSpeed = Double(deltaIn) / elapsed
            sessionDownTotal += deltaIn
        } else {
            // Counter wrapped or interface reset
            downloadSpeed = 0
        }

        if bytesOut >= lastBytesOut {
            let deltaOut = bytesOut - lastBytesOut
            uploadSpeed = Double(deltaOut) / elapsed
            sessionUpTotal += deltaOut
        } else {
            uploadSpeed = 0
        }

        if downloadSpeed > peakDown { peakDown = downloadSpeed }
        if uploadSpeed > peakUp { peakUp = uploadSpeed }

        lastBytesIn = bytesIn
        lastBytesOut = bytesOut
        lastTime = now

        // History
        downHistory.append(downloadSpeed)
        upHistory.append(uploadSpeed)
        while downHistory.count > config.historyLength { downHistory.removeFirst() }
        while upHistory.count > config.historyLength { upHistory.removeFirst() }
    }

    // MARK: - Network Bytes (AF_LINK only for accuracy)

    /// Reads total bytes in/out across all active network interfaces.
    /// Filters to AF_LINK (family 18) entries only, which contain accurate byte counters.
    private func getNetworkBytes() -> (UInt64, UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = ptr {
            defer { ptr = addr.pointee.ifa_next }

            // Only AF_LINK (18) entries have valid ifi_ibytes/ifi_obytes
            guard let sa = addr.pointee.ifa_addr, sa.pointee.sa_family == 18 else { continue }

            let name = String(cString: addr.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("pdp_ip") || name.hasPrefix("bridge") else { continue }

            if let data = addr.pointee.ifa_data {
                let nd = data.assumingMemoryBound(to: if_data.self)
                totalIn += UInt64(nd.pointee.ifi_ibytes)
                totalOut += UInt64(nd.pointee.ifi_obytes)
            }
        }
        return (totalIn, totalOut)
    }

    /// Reads per-interface byte counters (AF_LINK only).
    private func getInterfaceBytes() -> [String: (bytesIn: UInt64, bytesOut: UInt64)] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [:] }
        defer { freeifaddrs(ifaddr) }

        var byName: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = ptr {
            defer { ptr = addr.pointee.ifa_next }

            guard let sa = addr.pointee.ifa_addr, sa.pointee.sa_family == 18 else { continue }

            let name = String(cString: addr.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("pdp_ip") || name.hasPrefix("bridge") else { continue }

            if let data = addr.pointee.ifa_data {
                let nd = data.assumingMemoryBound(to: if_data.self)
                byName[name] = (UInt64(nd.pointee.ifi_ibytes), UInt64(nd.pointee.ifi_obytes))
            }
        }
        return byName
    }

    // MARK: - Per-Interface Speeds

    private func snapshotInterfaces() {
        prevInterfaceBytes = getInterfaceBytes()
        prevInterfaceTime = Date()
    }

    private func updateInterfaceSpeeds() {
        let current = getInterfaceBytes()
        let now = Date()
        let elapsed = now.timeIntervalSince(prevInterfaceTime)
        guard elapsed > 0.1 else { return }

        var speeds: [(String, Double, Double, UInt64, UInt64)] = []
        for (name, cur) in current {
            let prev = prevInterfaceBytes[name]
            let prevIn = prev?.bytesIn ?? cur.bytesIn
            let prevOut = prev?.bytesOut ?? cur.bytesOut

            let dIn = cur.bytesIn >= prevIn ? Double(cur.bytesIn - prevIn) / elapsed : 0
            let dOut = cur.bytesOut >= prevOut ? Double(cur.bytesOut - prevOut) / elapsed : 0

            if dIn > 100 || dOut > 100 || name == activeInterface {
                speeds.append((name, dIn, dOut, cur.bytesIn, cur.bytesOut))
            }
        }
        prevInterfaceBytes = current
        prevInterfaceTime = now
        interfaceSpeeds = speeds.sorted { ($0.1 + $0.2) > ($1.1 + $1.2) }
    }

    // MARK: - Connection Detection (background thread)

    private func detectActiveInterfaceSync() {
        guard let output = runCommand("/sbin/route", args: ["-n", "get", "default"]) else { return }
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                let iface = trimmed.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
                if !iface.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.activeInterface = iface
                        self?.connectionType = Self.classifyInterface(iface)
                    }
                }
                return
            }
        }
    }

    private func detectGatewaySync() {
        guard let output = runCommand("/sbin/route", args: ["-n", "get", "default"]) else { return }
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                let gw = trimmed.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
                if !gw.isEmpty {
                    DispatchQueue.main.async { [weak self] in self?.gatewayIP = gw }
                }
                return
            }
        }
    }

    private func fetchExternalIPSync() {
        guard let url = URL(string: "https://api.ipify.org") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data, let ip = String(data: data, encoding: .utf8) {
                result = ip.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            sem.signal()
        }.resume()
        sem.wait()
        if let ip = result, !ip.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.externalIP = ip }
        }
    }

    private func measureLatencySync() {
        let gw = DispatchQueue.main.sync { self.gatewayIP }
        guard gw != "---" && !gw.isEmpty else { return }
        guard let output = runCommand("/sbin/ping", args: ["-c", "1", "-t", "2", gw]) else {
            DispatchQueue.main.async { [weak self] in self?.gatewayLatency = -1 }
            return
        }
        // Parse "time=4.286 ms"
        if let range = output.range(of: "time=") {
            let after = output[range.upperBound...]
            if let spaceIdx = after.firstIndex(of: " ") {
                let msStr = String(after[..<spaceIdx])
                if let ms = Double(msStr) {
                    DispatchQueue.main.async { [weak self] in self?.gatewayLatency = ms }
                    return
                }
            }
        }
        DispatchQueue.main.async { [weak self] in self?.gatewayLatency = -1 }
    }

    // MARK: - Wi-Fi Info (CoreWLAN)

    private func updateWiFiInfo() {
        guard let iface = CWWiFiClient.shared().interface() else {
            wifiSSID = nil
            return
        }
        wifiSSID = iface.ssid() // nil without location permission, that's fine
        wifiRSSI = iface.rssiValue()
        wifiNoise = iface.noiseMeasurement()
        wifiTXRate = iface.transmitRate()
        wifiChannel = iface.wlanChannel()?.channelNumber ?? 0
        let band = iface.wlanChannel()?.channelBand
        if band == .band2GHz { wifiBand = "2.4 GHz" }
        else if band == .band5GHz { wifiBand = "5 GHz" }
        else if band == .band6GHz { wifiBand = "6 GHz" }
        else { wifiBand = "" }
    }

    // MARK: - Helpers

    static func classifyInterface(_ name: String) -> String {
        if name.hasPrefix("en0") || name.hasPrefix("en1") {
            // Check if Wi-Fi by seeing if CWWiFiClient recognizes it
            if let iface = CWWiFiClient.shared().interface(), iface.interfaceName == name {
                return "Wi-Fi"
            }
            return "Ethernet"
        }
        if name.hasPrefix("en") { return "Ethernet" }
        if name.hasPrefix("utun") { return "VPN" }
        if name.hasPrefix("pdp_ip") { return "Cellular" }
        if name.hasPrefix("bridge") { return "Bridge" }
        return "Other"
    }

    private func runCommand(_ path: String, args: [String]) -> String? {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Wi-Fi signal quality as 0-100% from RSSI
    var wifiSignalQuality: Int {
        // RSSI typically ranges from -90 (terrible) to -30 (excellent)
        let clamped = min(max(wifiRSSI, -90), -30)
        return Int(Double(clamped + 90) / 60.0 * 100.0)
    }

    /// Signal-to-noise ratio in dB
    var wifiSNR: Int {
        return wifiRSSI - wifiNoise
    }

    // MARK: - Formatting

    private func formatSpeed(_ bytes: Double) -> String {
        switch config.unitMode {
        case .kbs:
            return config.compactFormat
                ? String(format: "%.0fK", bytes / 1024)
                : String(format: "%.0f KB/s", bytes / 1024)
        case .mbs:
            return config.compactFormat
                ? String(format: "%.2fM", bytes / 1_048_576)
                : String(format: "%.2f MB/s", bytes / 1_048_576)
        case .auto:
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
    }

    private func formatTotal(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b < 1_048_576 { return String(format: "%.0f KB", b / 1024) }
        if b < 1_073_741_824 { return String(format: "%.1f MB", b / 1_048_576) }
        return String(format: "%.2f GB", b / 1_073_741_824)
    }

    private func formatSpeedLong(_ bytes: Double) -> String {
        if bytes < 1024 { return "0 KB/s" }
        if bytes < 1_048_576 { return String(format: "%.0f KB/s", bytes / 1024) }
        if bytes < 1_073_741_824 { return String(format: "%.1f MB/s", bytes / 1_048_576) }
        return String(format: "%.1f GB/s", bytes / 1_073_741_824)
    }

    private func formatLatency() -> String {
        if gatewayLatency < 0 { return "---" }
        if gatewayLatency < 1 { return String(format: "%.1fms", gatewayLatency) }
        return String(format: "%.0fms", gatewayLatency)
    }

    // MARK: - Colors

    func colorForSpeed(_ bytesPerSec: Double) -> NSColor {
        switch config.colorMode {
        case .fixed:
            return config.accentColor.color
        case .dynamic:
            let mbps = bytesPerSec / 1_048_576
            if mbps < 0.1 { return Theme.textMuted }
            if mbps < 1.0 { return config.accentColor.color.withAlphaComponent(0.6) }
            if mbps < 10.0 { return config.accentColor.color }
            return config.accentColor.color.blended(withFraction: 0.3, of: .white) ?? config.accentColor.color
        }
    }

    static let downColor = NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)
    static let upColor = NSColor(red: 0.55, green: 0.55, blue: 0.95, alpha: 1)

    static func colorForLatency(_ ms: Double) -> NSColor {
        if ms < 0 { return Theme.textMuted }
        if ms < 10 { return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) }
        if ms < 50 { return NSColor(red: 0.65, green: 0.85, blue: 0.40, alpha: 1) }
        if ms < 100 { return NSColor(red: 0.95, green: 0.80, blue: 0.30, alpha: 1) }
        return NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)
    }

    static func colorForSignal(_ quality: Int) -> NSColor {
        if quality >= 70 { return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) }
        if quality >= 40 { return NSColor(red: 0.95, green: 0.80, blue: 0.30, alpha: 1) }
        return NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        switch config.displayMode {
        case .text:
            var parts: [String] = []
            if config.showDownload { parts.append("\u{2193}\(formatSpeed(downloadSpeed))") }
            if config.showUpload { parts.append("\u{2191}\(formatSpeed(uploadSpeed))") }
            if config.showActiveInterface { parts.append(activeInterface) }
            return .text(parts.joined(separator: " "))

        case .compact:
            var label = ""
            if config.showDownload { label += "\u{25BC}\(formatSpeed(downloadSpeed))" }
            if config.showUpload {
                if !label.isEmpty { label += " " }
                label += "\u{25B2}\(formatSpeed(uploadSpeed))"
            }
            return .text(label)

        case .sparkline:
            let data = Array(downHistory.suffix(30))
            guard data.count >= 2 else { return .text("\u{2193}\(formatSpeed(downloadSpeed)) \u{2191}\(formatSpeed(uploadSpeed))") }
            let color = colorForSpeed(downloadSpeed)
            let img = SparklineRenderer.render(data: data, width: 50, style: SparklineRenderer.Style(
                lineColor: color,
                fillColor: color.withAlphaComponent(0.15),
                lineWidth: 1.5, height: 16, pointRadius: 1.5
            ))
            let label = "\u{2193}\(formatSpeed(downloadSpeed))"
            return .iconAndText(img, label)

        case .dualSparkline:
            let down = Array(downHistory.suffix(30))
            let up = Array(upHistory.suffix(30))
            guard down.count >= 2 else { return .text("\u{2193}\(formatSpeed(downloadSpeed)) \u{2191}\(formatSpeed(uploadSpeed))") }

            // Render both lines into one image
            let w: CGFloat = 50
            let h: CGFloat = 16
            let img = NSImage(size: NSSize(width: w, height: h))
            img.lockFocus()

            // Upload (bottom half, purple)
            if up.count >= 2 {
                let upImg = SparklineRenderer.render(data: up, width: w, style: SparklineRenderer.Style(
                    lineColor: Self.upColor.withAlphaComponent(0.5),
                    fillColor: Self.upColor.withAlphaComponent(0.08),
                    lineWidth: 1, height: h, pointRadius: 0
                ))
                upImg.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            }

            // Download (top, green)
            let downImg = SparklineRenderer.render(data: down, width: w, style: SparklineRenderer.Style(
                lineColor: Self.downColor,
                fillColor: Self.downColor.withAlphaComponent(0.10),
                lineWidth: 1.5, height: h, pointRadius: 1.5
            ))
            downImg.draw(in: NSRect(x: 0, y: 0, width: w, height: h))

            img.unlockFocus()
            let label = "\u{2193}\(formatSpeed(downloadSpeed))"
            return .iconAndText(img, label)

        case .barGraph:
            let downData = Array(downHistory.suffix(20))
            guard !downData.isEmpty else { return .text("\u{2193}\(formatSpeed(downloadSpeed))") }
            let img = SparklineRenderer.renderBars(data: downData, width: 44, style: SparklineRenderer.Style(
                lineColor: Self.downColor, height: 16
            ))
            return .iconAndText(img, formatSpeed(downloadSpeed))
        }
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "NETWORK", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}

// MARK: - Interactive Dropdown

extension NetworkSpeedWidget: InteractiveDropdown {
    var dropdownSize: NSSize {
        var h: CGFloat = 210 // header + speed card + info chips
        if config.showWiFiInfo && connectionType == "Wi-Fi" {
            h += 56 // Wi-Fi card
        }
        h += 72 // history chart + legend
        if config.showInterfacesInDropdown && !interfaceSpeeds.isEmpty {
            h += CGFloat(min(interfaceSpeeds.count, 6)) * 22 + 30
        }
        h += SuperWidgetKit.panelHeight + 8
        h += 40 // footer
        return NSSize(width: 340, height: min(max(h, 300), 760))
    }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 340
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        y = buildHeader(in: container, y: y, pad: pad, cw: cw)
        y = buildSpeedCard(in: container, y: y, pad: pad, cw: cw)

        if config.showWiFiInfo && connectionType == "Wi-Fi" {
            y = buildWiFiCard(in: container, y: y, pad: pad, cw: cw)
        }

        y = buildHistoryChart(in: container, y: y, pad: pad, cw: cw)

        if config.showInterfacesInDropdown {
            y = buildInterfaces(in: container, y: y, pad: pad, cw: cw)
        }

        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
        buildFooter(in: container, y: y, pad: pad, cw: cw)
        return container
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let avgDown = downHistory.isEmpty ? 0 : downHistory.reduce(0, +) / Double(downHistory.count)
        let avgUp = upHistory.isEmpty ? 0 : upHistory.reduce(0, +) / Double(upHistory.count)
        let endpoint = externalIP == "---" ? "External IP pending" : "WAN \(externalIP)"
        let latency = gatewayLatency >= 0 ? formatLatency() : "No ping"
        let wifiText = connectionType == "Wi-Fi" ? "\(wifiSignalQuality)%" : connectionType
        let channelText = wifiChannel > 0 ? "Ch \(wifiChannel) \(wifiBand)" : "Interface \(activeInterface)"

        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            metrics: [
                SuperWidgetMetric(label: "Down", value: formatSpeedLong(downloadSpeed), color: Self.downColor),
                SuperWidgetMetric(label: "Up", value: formatSpeedLong(uploadSpeed), color: Self.upColor),
                SuperWidgetMetric(label: "Latency", value: latency, color: Self.colorForLatency(gatewayLatency)),
                SuperWidgetMetric(label: "Link", value: wifiText, color: connectionType == "Wi-Fi" ? Self.colorForSignal(wifiSignalQuality) : Theme.textSecondary)
            ],
            insights: [
                endpoint,
                "Avg \(formatSpeedLong(avgDown)) down / \(formatSpeedLong(avgUp)) up",
                channelText
            ],
            actions: [
                "Refresh \(Int(config.refreshRate))s",
                "Interfaces \(interfaceSpeeds.count)",
                "Session \(formatTotal(sessionDownTotal + sessionUpTotal))"
            ],
            accent: Self.downColor
        )
    }

    // MARK: - Header

    private func buildHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let title = NSTextField(labelWithString: "Network Speed")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 200, height: 20)
        container.addSubview(title)

        // Subtitle: connection type + interface + IP
        var subParts: [String] = [connectionType, activeInterface]
        if externalIP != "---" { subParts.append(externalIP) }
        let sub = NSTextField(labelWithString: subParts.joined(separator: "  \u{00B7}  "))
        sub.font = .systemFont(ofSize: 10, weight: .medium)
        sub.textColor = Theme.textMuted
        sub.lineBreakMode = .byTruncatingTail
        sub.frame = NSRect(x: pad, y: y - 36, width: cw, height: 14)
        container.addSubview(sub)

        y -= 44
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Speed Card

    private func buildSpeedCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let cardH: CGFloat = 90
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        let halfW = (cw - 8) / 2

        buildSpeedHalf(in: card, x: 8, w: halfW - 8, h: cardH,
                       arrow: "\u{2193}", label: "DOWNLOAD",
                       speed: downloadSpeed, peak: peakDown, total: sessionDownTotal,
                       color: Self.downColor)

        let divider = NSView(frame: NSRect(x: halfW + 2, y: 8, width: 1, height: cardH - 16))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        card.addSubview(divider)

        buildSpeedHalf(in: card, x: halfW + 8, w: halfW - 8, h: cardH,
                       arrow: "\u{2191}", label: "UPLOAD",
                       speed: uploadSpeed, peak: peakUp, total: sessionUpTotal,
                       color: Self.upColor)

        y -= cardH + 8

        // Info chips
        var chips: [(String, String, NSColor)] = [
            (formatSpeedLong(peakDown), "Peak \u{2193}", Self.downColor),
            (formatSpeedLong(peakUp), "Peak \u{2191}", Self.upColor),
        ]
        if config.showLatency {
            chips.append((formatLatency(), "Latency", Self.colorForLatency(gatewayLatency)))
        }
        chips.append((formatTotal(sessionDownTotal + sessionUpTotal), "Session", Theme.textSecondary))

        let chipW = (cw - CGFloat(chips.count - 1) * 6) / CGFloat(chips.count)
        for (i, (val, label, color)) in chips.enumerated() {
            let cx = pad + CGFloat(i) * (chipW + 6)
            let chip = makeCard(x: cx, y: y - 40, w: chipW, h: 40)
            container.addSubview(chip)

            let vl = NSTextField(labelWithString: val)
            vl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            vl.textColor = color; vl.alignment = .center
            vl.lineBreakMode = .byTruncatingTail
            vl.frame = NSRect(x: 2, y: 16, width: chipW - 4, height: 16)
            chip.addSubview(vl)

            let ll = NSTextField(labelWithString: label)
            ll.font = .systemFont(ofSize: 8, weight: .semibold)
            ll.textColor = Theme.textFaint; ll.alignment = .center
            ll.frame = NSRect(x: 2, y: 4, width: chipW - 4, height: 12)
            chip.addSubview(ll)
        }
        y -= 48

        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    private func buildSpeedHalf(in parent: NSView, x: CGFloat, w: CGFloat, h: CGFloat,
                                arrow: String, label: String, speed: Double, peak: Double,
                                total: UInt64, color: NSColor) {
        let headerLbl = NSTextField(labelWithString: "\(arrow) \(label)")
        headerLbl.font = .systemFont(ofSize: 9, weight: .semibold)
        headerLbl.textColor = Theme.textFaint
        headerLbl.frame = NSRect(x: x, y: h - 20, width: w, height: 12)
        parent.addSubview(headerLbl)

        let speedStr = formatSpeedLong(speed)
        let speedLbl = NSTextField(labelWithString: speedStr)
        speedLbl.font = .monospacedDigitSystemFont(ofSize: 18, weight: .heavy)
        speedLbl.textColor = color
        speedLbl.lineBreakMode = .byTruncatingTail
        speedLbl.frame = NSRect(x: x, y: h - 46, width: w, height: 22)
        parent.addSubview(speedLbl)

        // Progress bar relative to peak
        let barW = w - 4
        let barH: CGFloat = 4
        let barBg = NSView(frame: NSRect(x: x, y: h - 56, width: barW, height: barH))
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        barBg.layer?.cornerRadius = 2
        parent.addSubview(barBg)

        if peak > 0 {
            let pct = min(speed / peak, 1.0)
            let fillW = max(barW * CGFloat(pct), 1)
            let fill = NSView(frame: NSRect(x: x, y: h - 56, width: fillW, height: barH))
            fill.wantsLayer = true
            fill.layer?.backgroundColor = color.withAlphaComponent(0.6).cgColor
            fill.layer?.cornerRadius = 2
            parent.addSubview(fill)
        }

        let totalLbl = NSTextField(labelWithString: "Total: \(formatTotal(total))")
        totalLbl.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        totalLbl.textColor = Theme.textFaint
        totalLbl.frame = NSRect(x: x, y: 6, width: w, height: 12)
        parent.addSubview(totalLbl)
    }

    // MARK: - Wi-Fi Card

    private func buildWiFiCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("WI-FI")
        header.frame = NSRect(x: pad, y: y - 12, width: 80, height: 12)
        container.addSubview(header)
        y -= 18

        let cardH: CGFloat = 32
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        // Signal quality bar
        let quality = wifiSignalQuality
        let sigColor = Self.colorForSignal(quality)

        let barW: CGFloat = 50
        let barH: CGFloat = 6
        let barBg = NSView(frame: NSRect(x: 10, y: (cardH - barH) / 2, width: barW, height: barH))
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        barBg.layer?.cornerRadius = 3
        card.addSubview(barBg)

        let fillW = barW * CGFloat(quality) / 100.0
        let fill = NSView(frame: NSRect(x: 10, y: (cardH - barH) / 2, width: fillW, height: barH))
        fill.wantsLayer = true
        fill.layer?.backgroundColor = sigColor.withAlphaComponent(0.7).cgColor
        fill.layer?.cornerRadius = 3
        card.addSubview(fill)

        // RSSI
        let rssiLbl = NSTextField(labelWithString: "\(wifiRSSI) dBm")
        rssiLbl.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        rssiLbl.textColor = sigColor
        rssiLbl.frame = NSRect(x: 66, y: (cardH - 14) / 2, width: 60, height: 14)
        card.addSubview(rssiLbl)

        // TX Rate
        let txLbl = NSTextField(labelWithString: String(format: "%.0f Mbps", wifiTXRate))
        txLbl.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        txLbl.textColor = Theme.textSecondary
        txLbl.frame = NSRect(x: 128, y: (cardH - 14) / 2, width: 70, height: 14)
        card.addSubview(txLbl)

        // Channel + Band
        var chStr = "Ch \(wifiChannel)"
        if !wifiBand.isEmpty { chStr += " \(wifiBand)" }
        let chLbl = NSTextField(labelWithString: chStr)
        chLbl.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        chLbl.textColor = Theme.textFaint
        chLbl.alignment = .right
        chLbl.frame = NSRect(x: cw - 120, y: (cardH - 14) / 2, width: 110, height: 14)
        card.addSubview(chLbl)

        y -= cardH + 4
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - History Chart

    private func buildHistoryChart(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("HISTORY")
        header.frame = NSRect(x: pad, y: y - 12, width: 80, height: 12)
        container.addSubview(header)

        if !downHistory.isEmpty {
            let avgDown = downHistory.reduce(0, +) / Double(downHistory.count)
            let avgUp = upHistory.isEmpty ? 0 : upHistory.reduce(0, +) / Double(upHistory.count)
            let info = "avg \u{2193}\(formatSpeedLong(avgDown)) \u{2191}\(formatSpeedLong(avgUp))"
            let il = NSTextField(labelWithString: info)
            il.font = .monospacedDigitSystemFont(ofSize: 8, weight: .regular)
            il.textColor = Theme.textFaint; il.alignment = .right
            il.frame = NSRect(x: pad + 80, y: y - 12, width: cw - 80, height: 12)
            container.addSubview(il)
        }
        y -= 18

        let chartH: CGFloat = 44
        let chartBg = makeCard(x: pad, y: y - chartH, w: cw, h: chartH)
        container.addSubview(chartBg)

        // Alert threshold line
        if config.alertThreshold > 0 {
            let maxVal = max(downHistory.max() ?? 0, upHistory.max() ?? 0, 1)
            let threshBytes = config.alertThreshold * 1_048_576
            if threshBytes < maxVal {
                let threshY = CGFloat(threshBytes / maxVal) * (chartH - 4) + 2
                let threshLine = NSView(frame: NSRect(x: 0, y: threshY, width: cw, height: 1))
                threshLine.wantsLayer = true
                threshLine.layer?.backgroundColor = NSColor(red: 1, green: 0.22, blue: 0.22, alpha: 0.25).cgColor
                chartBg.addSubview(threshLine)
            }
        }

        let downData = Array(downHistory.suffix(50))
        let upData = Array(upHistory.suffix(50))

        // Upload layer (purple-blue, behind)
        if upData.count >= 2 {
            let img = SparklineRenderer.render(data: upData, width: cw, style: SparklineRenderer.Style(
                lineColor: Self.upColor.withAlphaComponent(0.5),
                fillColor: Self.upColor.withAlphaComponent(0.08),
                lineWidth: 1, height: chartH, pointRadius: 0
            ))
            let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: cw, height: chartH))
            iv.image = img; iv.imageScaling = .scaleNone
            chartBg.addSubview(iv)
        }

        // Download layer (green, front)
        if downData.count >= 2 {
            let img = SparklineRenderer.render(data: downData, width: cw, style: SparklineRenderer.Style(
                lineColor: Self.downColor,
                fillColor: Self.downColor.withAlphaComponent(0.10),
                lineWidth: 1.5, height: chartH, pointRadius: 1.5
            ))
            let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: cw, height: chartH))
            iv.image = img; iv.imageScaling = .scaleNone
            chartBg.addSubview(iv)
        }

        // Legend
        y -= chartH + 4
        let legendY = y - 10
        let dot1 = makeLegendDot(color: Self.downColor, x: pad, y: legendY)
        container.addSubview(dot1)
        let l1 = NSTextField(labelWithString: "Download")
        l1.font = .systemFont(ofSize: 8, weight: .medium); l1.textColor = Theme.textFaint
        l1.frame = NSRect(x: pad + 10, y: legendY - 1, width: 55, height: 10)
        container.addSubview(l1)

        let dot2 = makeLegendDot(color: Self.upColor, x: pad + 70, y: legendY)
        container.addSubview(dot2)
        let l2 = NSTextField(labelWithString: "Upload")
        l2.font = .systemFont(ofSize: 8, weight: .medium); l2.textColor = Theme.textFaint
        l2.frame = NSRect(x: pad + 80, y: legendY - 1, width: 40, height: 10)
        container.addSubview(l2)

        y -= 16
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    private func makeLegendDot(color: NSColor, x: CGFloat, y: CGFloat) -> NSView {
        let dot = NSView(frame: NSRect(x: x, y: y, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 3
        return dot
    }

    // MARK: - Interfaces

    private func buildInterfaces(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        guard !interfaceSpeeds.isEmpty else { return y }
        var y = y

        let header = Theme.sectionHeader("INTERFACES")
        header.frame = NSRect(x: pad, y: y - 12, width: 150, height: 12)
        container.addSubview(header)
        y -= 18

        let ifaces = Array(interfaceSpeeds.prefix(6))
        for (i, iface) in ifaces.enumerated() {
            let rowH: CGFloat = 20
            let rowBg = NSView(frame: NSRect(x: pad, y: y - rowH, width: cw, height: rowH))
            rowBg.wantsLayer = true
            rowBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(i % 2 == 0 ? 0.02 : 0.0).cgColor
            rowBg.layer?.cornerRadius = 4
            container.addSubview(rowBg)

            let isActive = iface.name == activeInterface
            if isActive {
                let dot = NSView(frame: NSRect(x: pad + 4, y: y - rowH + 7, width: 6, height: 6))
                dot.wantsLayer = true
                dot.layer?.backgroundColor = Self.downColor.cgColor
                dot.layer?.cornerRadius = 3
                container.addSubview(dot)
            }

            // Name + type
            let ifType = Self.classifyInterface(iface.name)
            let nameStr = "\(iface.name) (\(ifType))"
            let nameLabel = NSTextField(labelWithString: nameStr)
            nameLabel.font = .systemFont(ofSize: 10, weight: isActive ? .bold : .medium)
            nameLabel.textColor = isActive ? Theme.textPrimary : Theme.textSecondary
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.frame = NSRect(x: pad + 14, y: y - rowH + 3, width: 100, height: 14)
            container.addSubview(nameLabel)

            let downLabel = NSTextField(labelWithString: "\u{2193}\(formatSpeedLong(iface.downSpeed))")
            downLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            downLabel.textColor = Self.downColor.withAlphaComponent(0.8)
            downLabel.alignment = .right
            downLabel.frame = NSRect(x: pad + 114, y: y - rowH + 3, width: 80, height: 14)
            container.addSubview(downLabel)

            let upLabel = NSTextField(labelWithString: "\u{2191}\(formatSpeedLong(iface.upSpeed))")
            upLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            upLabel.textColor = Self.upColor.withAlphaComponent(0.8)
            upLabel.alignment = .right
            upLabel.frame = NSRect(x: pad + cw - 90, y: y - rowH + 3, width: 80, height: 14)
            container.addSubview(upLabel)

            y -= rowH + 2
        }
        return y
    }

    // MARK: - Footer

    @discardableResult
    private func buildFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let y = y - 4

        var footerParts: [String] = []
        footerParts.append(connectionType)
        if gatewayIP != "---" { footerParts.append("gw \(gatewayIP)") }
        if gatewayLatency >= 0 { footerParts.append(formatLatency()) }

        let footer = NSTextField(labelWithString: footerParts.joined(separator: "  \u{00B7}  "))
        footer.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        footer.textColor = Theme.textGhost; footer.alignment = .center
        footer.lineBreakMode = .byTruncatingTail
        footer.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
        container.addSubview(footer)
        return y - 18
    }

    // MARK: - UI Helpers

    private func makeCard(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: x, y: y, width: w, height: h))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        v.layer?.cornerRadius = 8
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        return v
    }

    private func addDivider(in container: NSView, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        let d = NSView(frame: NSRect(x: pad, y: y, width: cw, height: 1))
        d.wantsLayer = true
        d.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        container.addSubview(d)
        y -= 8
    }
}

// MARK: - Declarative Config

extension NetworkSpeedWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .picker(label: "Display Mode", key: "displayMode", options: [
                (title: "Text (arrows + speed)", value: "text"),
                (title: "Sparkline (download)", value: "sparkline"),
                (title: "Dual Sparkline (up + down)", value: "dualSparkline"),
                (title: "Bar Graph", value: "barGraph"),
                (title: "Compact", value: "compact"),
            ], get: { [weak self] in self?.config.displayMode.rawValue ?? "text" },
               set: { [weak self] in self?.config.displayMode = NetworkSpeedConfig.NetDisplayMode(rawValue: $0) ?? .text }),

            .picker(label: "Color Mode", key: "colorMode", options: [
                (title: "Dynamic (shifts with speed)", value: "dynamic"),
                (title: "Fixed Accent Color", value: "fixed"),
            ], get: { [weak self] in self?.config.colorMode.rawValue ?? "dynamic" },
               set: { [weak self] in self?.config.colorMode = NetworkSpeedConfig.NetColorMode(rawValue: $0) ?? .dynamic }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Cyan", value: "cyan"),
                (title: "Blue", value: "blue"),
                (title: "Green", value: "green"),
                (title: "Amber", value: "amber"),
                (title: "Purple", value: "purple"),
                (title: "Red", value: "red"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "cyan" },
               set: { [weak self] in self?.config.accentColor = NetworkSpeedConfig.NetAccentPreset(rawValue: $0) ?? .cyan }),

            .section(title: "Menu Bar"),
            .toggle(label: "Show Download Speed", key: "showDownload",
                    get: { [weak self] in self?.config.showDownload ?? true },
                    set: { [weak self] in self?.config.showDownload = $0 }),
            .toggle(label: "Show Upload Speed", key: "showUpload",
                    get: { [weak self] in self?.config.showUpload ?? true },
                    set: { [weak self] in self?.config.showUpload = $0 }),
            .toggle(label: "Compact Format", key: "compactFormat",
                    get: { [weak self] in self?.config.compactFormat ?? true },
                    set: { [weak self] in self?.config.compactFormat = $0 }),
            .toggle(label: "Show Active Interface", key: "showActiveInterface",
                    get: { [weak self] in self?.config.showActiveInterface ?? false },
                    set: { [weak self] in self?.config.showActiveInterface = $0 }),
            .picker(label: "Unit", key: "unitMode", options: [
                (title: "Auto (KB/MB/GB)", value: "auto"),
                (title: "Always KB/s", value: "kbs"),
                (title: "Always MB/s", value: "mbs"),
            ], get: { [weak self] in self?.config.unitMode.rawValue ?? "auto" },
               set: { [weak self] in self?.config.unitMode = NetworkSpeedConfig.UnitMode(rawValue: $0) ?? .auto }),

            .section(title: "Dropdown"),
            .toggle(label: "Show Interfaces", key: "showInterfacesInDropdown",
                    get: { [weak self] in self?.config.showInterfacesInDropdown ?? true },
                    set: { [weak self] in self?.config.showInterfacesInDropdown = $0 }),
            .toggle(label: "Show Wi-Fi Details", key: "showWiFiInfo",
                    get: { [weak self] in self?.config.showWiFiInfo ?? true },
                    set: { [weak self] in self?.config.showWiFiInfo = $0 }),
            .toggle(label: "Show Latency", key: "showLatency",
                    get: { [weak self] in self?.config.showLatency ?? true },
                    set: { [weak self] in self?.config.showLatency = $0 }),
            .slider(label: "Alert Threshold", key: "alertThreshold", min: 1, max: 100, step: 1,
                    get: { [weak self] in self?.config.alertThreshold ?? 10 },
                    set: { [weak self] in self?.config.alertThreshold = $0 },
                    format: "%.0f MB/s"),

            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshRate", min: 1, max: 10, step: 1,
                    get: { [weak self] in self?.config.refreshRate ?? 2 },
                    set: { [weak self] in self?.config.refreshRate = $0 },
                    format: "%.0f s"),
            .slider(label: "History Length", key: "historyLength", min: 20, max: 120, step: 10,
                    get: { [weak self] in Double(self?.config.historyLength ?? 60) },
                    set: { [weak self] in self?.config.historyLength = Int($0) },
                    format: "%.0f pts"),
        ]
    }
}
