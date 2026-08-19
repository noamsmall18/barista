import Cocoa
import CoreWLAN

// MARK: - Config

struct WiFiSignalConfig: Codable, Equatable {
    var displayMode: WiFiDisplayMode = .signalBars
    var showSSID: Bool = true
    var showdBm: Bool = true
    var showChannel: Bool = false
    var showBand: Bool = false
    var showTxRate: Bool = false
    var showNoise: Bool = false
    var showSNR: Bool = false
    var accentColor: AccentPreset = .cyan
    var colorMode: ColorMode = .dynamic
    var refreshRate: TimeInterval = 2
    var historyLength: Int = 60
    var lowSignalThreshold: Int = -70
    var compactLabels: Bool = false

    static let `default` = WiFiSignalConfig()

    enum WiFiDisplayMode: String, Codable, Equatable {
        case signalBars  // bars icon + SSID
        case dBm         // "WiFi -52dBm"
        case ssidOnly    // just SSID name
        case compact     // just bars icon
        case detailed    // "MyNetwork -52dBm Ch36 5GHz"
    }

    enum AccentPreset: String, Codable, Equatable, CaseIterable {
        case blue, cyan, green, amber, purple, red, white
        var color: NSColor {
            switch self {
            case .blue:   return NSColor(red: 0.30, green: 0.65, blue: 0.95, alpha: 1)
            case .cyan:   return NSColor(red: 0.30, green: 0.85, blue: 0.90, alpha: 1)
            case .green:  return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)
            case .amber:  return NSColor(red: 0.96, green: 0.66, blue: 0.23, alpha: 1)
            case .purple: return NSColor(red: 0.65, green: 0.45, blue: 0.90, alpha: 1)
            case .red:    return NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)
            case .white:  return NSColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
            }
        }
    }

    enum ColorMode: String, Codable, Equatable {
        case dynamic // color shifts green->yellow->orange->red with signal
        case fixed   // always uses accentColor
    }
}

// MARK: - Widget

class WiFiSignalWidget: BaristaWidget {
    static let widgetID = "wifi-signal"
    static let displayName = "Wi-Fi Signal"
    static let subtitle = "SSID, signal strength, channel & band"
    static let iconName = "wifi"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = WiFiSignalConfig.default

    var config: WiFiSignalConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private var currentTimerInterval: TimeInterval = 0

    // Wi-Fi state
    private(set) var ssid: String = "Not Connected"
    private(set) var bssid: String = ""
    private(set) var rssi: Int = 0          // dBm, typically -30 to -90
    private(set) var noise: Int = 0         // dBm
    private(set) var channelNumber: Int = 0
    private(set) var channelBand: String = "" // "2.4GHz", "5GHz", "6GHz"
    private(set) var channelWidth: Int = 0   // MHz
    private(set) var txRate: Double = 0      // Mbps
    private(set) var securityType: String = "Unknown"
    private(set) var countryCode: String = ""
    private(set) var isConnected: Bool = false

    // History
    private(set) var rssiHistory: [Double] = []

    private let wifiClient = CWWiFiClient.shared()

    required init(config: WiFiSignalConfig) {
        self.config = config
    }

    func start() {
        currentTimerInterval = config.refreshRate
        updateWiFi()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.updateWiFi()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Data Collection

    private func updateWiFi() {
        // Self-correcting timer
        if currentTimerInterval != config.refreshRate {
            timer?.invalidate()
            timer = nil
            currentTimerInterval = config.refreshRate
            timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
                self?.updateWiFi()
            }
        }

        guard let iface = wifiClient.interface() else {
            isConnected = false
            ssid = "No Wi-Fi"
            bssid = ""
            rssi = 0
            noise = 0
            channelNumber = 0
            channelBand = ""
            channelWidth = 0
            txRate = 0
            securityType = "None"
            countryCode = ""
            onDisplayUpdate?()
            return
        }

        let currentSSID = iface.ssid()
        isConnected = currentSSID != nil
        ssid = currentSSID ?? "Not Connected"
        bssid = iface.bssid() ?? ""
        rssi = iface.rssiValue()
        noise = iface.noiseMeasurement()
        txRate = iface.transmitRate()
        countryCode = iface.countryCode() ?? ""

        if let channel = iface.wlanChannel() {
            channelNumber = channel.channelNumber
            channelWidth = Self.channelWidthMHz(channel.channelWidth)
            channelBand = Self.bandString(channel.channelBand)
        }

        securityType = Self.securityString(iface.security())

        if isConnected {
            rssiHistory.append(Double(rssi))
            while rssiHistory.count > config.historyLength {
                rssiHistory.removeFirst()
            }
        }

        onDisplayUpdate?()
    }

    // MARK: - Computed Properties

    var snr: Int {
        guard noise != 0 else { return 0 }
        return rssi - noise
    }

    var signalQuality: String {
        if rssi >= -50 { return "Excellent" }
        if rssi >= -60 { return "Good" }
        if rssi >= -70 { return "Fair" }
        if rssi >= -80 { return "Weak" }
        return "Very Weak"
    }

    var signalBarsCount: Int {
        if rssi >= -50 { return 4 }
        if rssi >= -60 { return 3 }
        if rssi >= -70 { return 2 }
        if rssi >= -80 { return 1 }
        return 0
    }

    // MARK: - Color Helpers

    func accentForSignal(_ dBm: Int) -> NSColor {
        switch config.colorMode {
        case .fixed: return config.accentColor.color
        case .dynamic: return Self.dynamicSignalColor(dBm, threshold: config.lowSignalThreshold)
        }
    }

    static func dynamicSignalColor(_ dBm: Int, threshold: Int) -> NSColor {
        if dBm >= -50 {
            return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) // green
        } else if dBm >= -60 {
            let f = CGFloat(Double(dBm + 60) / 10.0)
            return NSColor(red: 0.30 + 0.65 * (1.0 - f), green: 0.85 - 0.05 * (1.0 - f), blue: 0.55 - 0.25 * (1.0 - f), alpha: 1)
        } else if dBm >= -70 {
            return NSColor(red: 0.96, green: 0.66, blue: 0.23, alpha: 1) // amber/yellow
        } else if dBm >= -80 {
            return NSColor(red: 1.0, green: 0.50, blue: 0.15, alpha: 1) // orange
        } else {
            return NSColor(red: 1.0, green: 0.22, blue: 0.22, alpha: 1) // red
        }
    }

    // MARK: - Signal Bars NSImage

    private func renderSignalBars(size: CGFloat = 16) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()

        let bars = 4
        let gap: CGFloat = 1.5
        let barW = (size - gap * CGFloat(bars - 1)) / CGFloat(bars)
        let activeBars = signalBarsCount
        let color = accentForSignal(rssi)

        for i in 0..<bars {
            let x = CGFloat(i) * (barW + gap)
            let fraction = CGFloat(i + 1) / CGFloat(bars)
            let barH = max(size * 0.2 + (size * 0.75) * fraction, 2)
            let y: CGFloat = 1

            let rect = NSRect(x: x, y: y, width: barW, height: barH)
            let path = NSBezierPath(roundedRect: rect, xRadius: barW / 3, yRadius: barW / 3)

            if i < activeBars {
                color.withAlphaComponent(0.85).setFill()
            } else {
                NSColor.white.withAlphaComponent(0.10).setFill()
            }
            path.fill()
        }

        img.unlockFocus()
        return img
    }

    // MARK: - Render (Menu Bar)

    func render() -> WidgetDisplayMode {
        guard isConnected else {
            return .text("No WiFi")
        }

        let color = accentForSignal(rssi)

        switch config.displayMode {
        case .signalBars:
            let icon = renderSignalBars()
            let label = config.showSSID ? ssid : "\(rssi)dBm"
            return .iconAndText(icon, label)

        case .dBm:
            return renderAttributedDBm(color: color)

        case .ssidOnly:
            let str = NSMutableAttributedString()
            str.append(NSAttributedString(string: ssid, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: color
            ]))
            return .attributedText(str)

        case .compact:
            let icon = renderSignalBars()
            return .iconAndText(icon, "")

        case .detailed:
            return renderAttributedDetailed(color: color)
        }
    }

    private func renderAttributedDBm(color: NSColor) -> WidgetDisplayMode {
        let str = NSMutableAttributedString()
        str.append(NSAttributedString(string: "WiFi ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5)
        ]))
        str.append(NSAttributedString(string: "\(rssi)dBm", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: color
        ]))
        return .attributedText(str)
    }

    private func renderAttributedDetailed(color: NSColor) -> WidgetDisplayMode {
        let str = NSMutableAttributedString()

        // SSID
        let displaySSID = ssid.count > 12 ? String(ssid.prefix(10)) + ".." : ssid
        str.append(NSAttributedString(string: displaySSID, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color
        ]))

        // dBm
        str.append(NSAttributedString(string: " \(rssi)dBm", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: color.withAlphaComponent(0.8)
        ]))

        // Channel
        if config.showChannel && channelNumber > 0 {
            str.append(NSAttributedString(string: " Ch\(channelNumber)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: Theme.textFaint
            ]))
        }

        // Band
        if config.showBand && !channelBand.isEmpty {
            str.append(NSAttributedString(string: " \(channelBand)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: Theme.textFaint
            ]))
        }

        return .attributedText(str)
    }

    // MARK: - Dropdown (fallback NSMenu)

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let h = NSMenuItem(title: "WI-FI SIGNAL", action: nil, keyEquivalent: "")
        h.isEnabled = false; menu.addItem(h)
        menu.addItem(NSMenuItem.separator())
        let u = NSMenuItem(title: isConnected ? "\(ssid) \(rssi) dBm" : "Not Connected", action: nil, keyEquivalent: "")
        u.isEnabled = false; menu.addItem(u)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { [] }

    // MARK: - Static Helpers

    static func channelWidthMHz(_ width: CWChannelWidth) -> Int {
        switch width {
        case .width20MHz:  return 20
        case .width40MHz:  return 40
        case .width80MHz:  return 80
        case .width160MHz: return 160
        case .widthUnknown: return 0
        @unknown default:  return 0
        }
    }

    static func bandString(_ band: CWChannelBand) -> String {
        switch band {
        case .band2GHz: return "2.4GHz"
        case .band5GHz: return "5GHz"
        case .band6GHz: return "6GHz"
        case .bandUnknown: return ""
        @unknown default: return ""
        }
    }

    static func securityString(_ security: CWSecurity) -> String {
        switch security {
        case .none:                  return "Open"
        case .WEP:                   return "WEP"
        case .wpaPersonal:           return "WPA Personal"
        case .wpaPersonalMixed:      return "WPA Mixed"
        case .wpa2Personal:          return "WPA2 Personal"
        case .wpa3Personal:          return "WPA3 Personal"
        case .personal:              return "WPA3 Personal"
        case .dynamicWEP:            return "Dynamic WEP"
        case .wpaEnterprise:         return "WPA Enterprise"
        case .wpaEnterpriseMixed:    return "WPA Enterprise Mixed"
        case .wpa2Enterprise:        return "WPA2 Enterprise"
        case .wpa3Enterprise:        return "WPA3 Enterprise"
        case .wpa3Transition:        return "WPA3 Transition"
        case .OWE:                   return "OWE"
        case .oweTransition:         return "OWE Transition"
        case .enterprise:            return "WPA3 Enterprise"
        case .unknown:               return "Unknown"
        @unknown default:            return "Unknown"
        }
    }
}

// MARK: - Interactive Dropdown

extension WiFiSignalWidget: InteractiveDropdown {
    var dropdownSize: NSSize {
        var h: CGFloat = 240 // header + connection card + network details
        h += 60  // signal history chart
        h += 40  // signal quality assessment
        h += SuperWidgetKit.panelHeight + 8
        h += 40  // footer
        return NSSize(width: 340, height: min(max(h, 320), 700))
    }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 340
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        y = buildHeader(in: container, y: y, pad: pad, cw: cw)
        y = buildConnectionCard(in: container, y: y, pad: pad, cw: cw)
        y = buildNetworkDetailsCard(in: container, y: y, pad: pad, cw: cw)
        y = buildSignalHistory(in: container, y: y, pad: pad, cw: cw)
        y = buildSignalQuality(in: container, y: y, pad: pad, cw: cw)
        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
        buildFooter(in: container, y: y, pad: pad, cw: cw)

        return container
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let avgRSSI = rssiHistory.isEmpty ? Double(rssi) : rssiHistory.reduce(0, +) / Double(rssiHistory.count)
        let bssidText = bssid.isEmpty ? "BSSID unavailable" : "BSSID \(bssid)"
        let channelText = channelNumber > 0 ? "Ch \(channelNumber) \(channelBand)" : "No channel"
        let networkText = isConnected ? ssid : "Not connected"

        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            metrics: [
                SuperWidgetMetric(label: "RSSI", value: "\(rssi)dBm", color: accentForSignal(rssi)),
                SuperWidgetMetric(label: "Quality", value: signalQuality, color: accentForSignal(rssi)),
                SuperWidgetMetric(label: "SNR", value: "\(snr)dB", color: snr >= 25 ? Theme.green : Theme.orange),
                SuperWidgetMetric(label: "TX", value: txRate > 0 ? String(format: "%.0fMb", txRate) : "--", color: Theme.textSecondary)
            ],
            insights: [
                networkText,
                String(format: "Avg RSSI %.0f dBm", avgRSSI),
                channelText
            ],
            actions: [
                securityType,
                "Threshold \(config.lowSignalThreshold)dBm",
                bssidText
            ],
            accent: accentForSignal(rssi)
        )
    }

    // MARK: Header

    private func buildHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let title = NSTextField(labelWithString: "Wi-Fi Signal")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 200, height: 20)
        container.addSubview(title)

        // Status badge
        let statusStr = isConnected ? "Connected" : "Disconnected"
        let badge = NSTextField(labelWithString: statusStr)
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = isConnected ? NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) :
            NSColor(red: 1.0, green: 0.22, blue: 0.22, alpha: 1)
        badge.alignment = .right
        badge.frame = NSRect(x: pad + cw - 120, y: y - 18, width: 120, height: 16)
        container.addSubview(badge)

        y -= 28
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: Connection Card

    private func buildConnectionCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("CONNECTION")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)
        y -= 18

        let cardH: CGFloat = 80
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        // Signal bars visualization (large)
        let barsSize: CGFloat = 48
        let barsImg = renderSignalBars(size: barsSize)
        let barsView = NSImageView(frame: NSRect(x: 12, y: (cardH - barsSize) / 2, width: barsSize, height: barsSize))
        barsView.image = barsImg
        card.addSubview(barsView)

        // Right side: SSID, BSSID, RSSI, Noise, SNR
        let sx: CGFloat = barsSize + 24
        let sw = cw - sx - 8
        var sy = cardH - 10

        // SSID
        let ssidLabel = NSTextField(labelWithString: ssid)
        ssidLabel.font = .systemFont(ofSize: 13, weight: .bold)
        ssidLabel.textColor = accentForSignal(rssi)
        ssidLabel.lineBreakMode = .byTruncatingTail
        ssidLabel.frame = NSRect(x: sx, y: sy - 16, width: sw, height: 16)
        card.addSubview(ssidLabel)
        sy -= 18

        // BSSID
        if !bssid.isEmpty {
            let bssidLabel = NSTextField(labelWithString: bssid)
            bssidLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            bssidLabel.textColor = Theme.textFaint
            bssidLabel.frame = NSRect(x: sx, y: sy - 12, width: sw, height: 12)
            card.addSubview(bssidLabel)
            sy -= 14
        }

        // RSSI + Noise + SNR row
        let rows: [(String, String, NSColor)] = [
            ("RSSI", "\(rssi) dBm", accentForSignal(rssi)),
            ("Noise", "\(noise) dBm", Theme.textMuted),
            ("SNR", "\(snr) dB", snr >= 25 ? NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) : Theme.textSecondary),
        ]
        for (label, value, color) in rows {
            addStatPair(in: card, label: label, value: value, color: color, x: sx, y: sy - 12, w: sw)
            sy -= 14
        }

        y -= cardH + 8
        return y
    }

    // MARK: Network Details Card

    private func buildNetworkDetailsCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("NETWORK DETAILS")
        header.frame = NSRect(x: pad, y: y - 12, width: 150, height: 12)
        container.addSubview(header)
        y -= 18

        var chips: [(String, String, NSColor)] = []

        if channelNumber > 0 {
            chips.append(("Ch \(channelNumber)", "Channel", Theme.textSecondary))
        }
        if !channelBand.isEmpty {
            chips.append((channelBand, "Band", NSColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 1)))
        }
        if channelWidth > 0 {
            chips.append(("\(channelWidth)MHz", "Width", Theme.textSecondary))
        }
        if txRate > 0 {
            chips.append((String(format: "%.0f Mbps", txRate), "Tx Rate", NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)))
        }

        if !chips.isEmpty {
            let chipW = (cw - CGFloat(chips.count - 1) * 6) / CGFloat(max(chips.count, 1))
            for (i, (val, label, color)) in chips.enumerated() {
                let cx = pad + CGFloat(i) * (chipW + 6)
                let chip = makeCard(x: cx, y: y - 40, w: chipW, h: 40)
                container.addSubview(chip)

                let vl = NSTextField(labelWithString: val)
                vl.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
                vl.textColor = color; vl.alignment = .center
                vl.lineBreakMode = .byTruncatingTail
                vl.frame = NSRect(x: 2, y: 16, width: chipW - 4, height: 18)
                chip.addSubview(vl)

                let ll = NSTextField(labelWithString: label)
                ll.font = .systemFont(ofSize: 8, weight: .semibold)
                ll.textColor = Theme.textFaint; ll.alignment = .center
                ll.frame = NSRect(x: 2, y: 4, width: chipW - 4, height: 12)
                chip.addSubview(ll)
            }
            y -= 48
        }

        // Security + Country row
        var infoChips: [(String, String, NSColor)] = []
        infoChips.append((securityType, "Security", Theme.textSecondary))
        if !countryCode.isEmpty {
            infoChips.append((countryCode, "Country", Theme.textMuted))
        }

        let infoChipW = (cw - CGFloat(infoChips.count - 1) * 6) / CGFloat(max(infoChips.count, 1))
        for (i, (val, label, color)) in infoChips.enumerated() {
            let cx = pad + CGFloat(i) * (infoChipW + 6)
            let chip = makeCard(x: cx, y: y - 34, w: infoChipW, h: 34)
            container.addSubview(chip)

            let vl = NSTextField(labelWithString: val)
            vl.font = .systemFont(ofSize: 11, weight: .bold)
            vl.textColor = color; vl.alignment = .center
            vl.lineBreakMode = .byTruncatingTail
            vl.frame = NSRect(x: 2, y: 14, width: infoChipW - 4, height: 16)
            chip.addSubview(vl)

            let ll = NSTextField(labelWithString: label)
            ll.font = .systemFont(ofSize: 8, weight: .semibold)
            ll.textColor = Theme.textFaint; ll.alignment = .center
            ll.frame = NSRect(x: 2, y: 2, width: infoChipW - 4, height: 12)
            chip.addSubview(ll)
        }
        y -= 42

        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: Signal History

    private func buildSignalHistory(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("SIGNAL HISTORY")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)

        if rssiHistory.count >= 2 {
            let avg = rssiHistory.reduce(0, +) / Double(rssiHistory.count)
            let peak = rssiHistory.max() ?? 0
            let low = rssiHistory.min() ?? 0
            let info = String(format: "avg %.0f  lo %.0f  hi %.0f dBm", avg, low, peak)
            let il = NSTextField(labelWithString: info)
            il.font = .monospacedDigitSystemFont(ofSize: 8, weight: .regular)
            il.textColor = Theme.textFaint; il.alignment = .right
            il.frame = NSRect(x: pad + 120, y: y - 12, width: cw - 120, height: 12)
            container.addSubview(il)
        }
        y -= 18

        let chartH: CGFloat = 44
        let chartBg = makeCard(x: pad, y: y - chartH, w: cw, h: chartH)
        container.addSubview(chartBg)

        // Threshold line for low signal
        let threshNorm = max(0, min(1, Double(config.lowSignalThreshold + 100) / 70.0))
        let threshY = CGFloat(threshNorm) * (chartH - 4) + 2
        let threshLine = NSView(frame: NSRect(x: 0, y: threshY, width: cw, height: 1))
        threshLine.wantsLayer = true
        threshLine.layer?.backgroundColor = NSColor(red: 1, green: 0.22, blue: 0.22, alpha: 0.25).cgColor
        chartBg.addSubview(threshLine)

        let chartData = Array(rssiHistory.suffix(50))
        if chartData.count >= 2 {
            // Normalize: RSSI is negative, invert so stronger = higher
            let normalizedData = chartData.map { $0 + 100 } // shift from [-100,0] to [0,100]
            let color = accentForSignal(rssi)
            let img = SparklineRenderer.render(data: normalizedData, width: cw, style: SparklineRenderer.Style(
                lineColor: color,
                fillColor: color.withAlphaComponent(0.10),
                lineWidth: 1.5, height: chartH, pointRadius: 1.5
            ))
            let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: cw, height: chartH))
            iv.image = img; iv.imageScaling = .scaleNone
            chartBg.addSubview(iv)
        }

        y -= chartH + 4
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: Signal Quality

    private func buildSignalQuality(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("SIGNAL QUALITY")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)
        y -= 18

        let cardH: CGFloat = 28
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        // Quality label
        let qualLabel = NSTextField(labelWithString: signalQuality)
        qualLabel.font = .systemFont(ofSize: 13, weight: .bold)
        qualLabel.textColor = accentForSignal(rssi)
        qualLabel.frame = NSRect(x: 12, y: 4, width: 100, height: 20)
        card.addSubview(qualLabel)

        // Signal strength bar
        let barX: CGFloat = cw - 122
        let barW: CGFloat = 110
        let barBg = NSView(frame: NSRect(x: barX, y: 10, width: barW, height: 8))
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        barBg.layer?.cornerRadius = 4
        card.addSubview(barBg)

        // Normalized: -100 dBm = 0%, -30 dBm = 100%
        let norm = max(0, min(1, Double(rssi + 100) / 70.0))
        let fillW = barW * CGFloat(norm)
        if fillW > 0 {
            let fill = NSView(frame: NSRect(x: barX, y: 10, width: fillW, height: 8))
            fill.wantsLayer = true
            fill.layer?.backgroundColor = accentForSignal(rssi).withAlphaComponent(0.7).cgColor
            fill.layer?.cornerRadius = 4
            card.addSubview(fill)
        }

        y -= cardH + 4
        return y
    }

    // MARK: Footer

    @discardableResult
    private func buildFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let y = y - 4
        var parts: [String] = []

        if isConnected {
            parts.append(ssid)
            if channelNumber > 0 { parts.append("Ch \(channelNumber)") }
            if !channelBand.isEmpty { parts.append(channelBand) }
        } else {
            parts.append("No Connection")
        }

        let footer = NSTextField(labelWithString: parts.joined(separator: "  \u{00B7}  "))
        footer.font = .systemFont(ofSize: 9, weight: .regular)
        footer.textColor = Theme.textGhost; footer.alignment = .center
        footer.lineBreakMode = .byTruncatingTail
        footer.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
        container.addSubview(footer)
        return y - 18
    }

    // MARK: UI Helpers

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

    private func addStatPair(in parent: NSView, label: String, value: String, color: NSColor, x: CGFloat, y: CGFloat, w: CGFloat) {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 10, weight: .regular)
        lbl.textColor = Theme.textMuted
        lbl.frame = NSRect(x: x, y: y, width: 48, height: 14)
        parent.addSubview(lbl)

        let val = NSTextField(labelWithString: value)
        val.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        val.textColor = color
        val.lineBreakMode = .byTruncatingTail
        val.frame = NSRect(x: x + 48, y: y, width: w - 48, height: 14)
        parent.addSubview(val)
    }
}

// MARK: - Declarative Config

extension WiFiSignalWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .picker(label: "Display Mode", key: "displayMode", options: [
                (title: "Signal Bars + SSID", value: "signalBars"),
                (title: "WiFi dBm", value: "dBm"),
                (title: "SSID Only", value: "ssidOnly"),
                (title: "Compact (bars only)", value: "compact"),
                (title: "Detailed (all info)", value: "detailed"),
            ], get: { [weak self] in self?.config.displayMode.rawValue ?? "signalBars" },
               set: { [weak self] in self?.config.displayMode = WiFiSignalConfig.WiFiDisplayMode(rawValue: $0) ?? .signalBars }),

            .picker(label: "Color Mode", key: "colorMode", options: [
                (title: "Dynamic (shifts with signal)", value: "dynamic"),
                (title: "Fixed Accent Color", value: "fixed"),
            ], get: { [weak self] in self?.config.colorMode.rawValue ?? "dynamic" },
               set: { [weak self] in self?.config.colorMode = WiFiSignalConfig.ColorMode(rawValue: $0) ?? .dynamic }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Blue", value: "blue"),
                (title: "Cyan", value: "cyan"),
                (title: "Green", value: "green"),
                (title: "Amber", value: "amber"),
                (title: "Purple", value: "purple"),
                (title: "Red", value: "red"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "cyan" },
               set: { [weak self] in self?.config.accentColor = WiFiSignalConfig.AccentPreset(rawValue: $0) ?? .cyan }),

            .section(title: "Menu Bar Info"),
            .toggle(label: "Show SSID", key: "showSSID",
                    get: { [weak self] in self?.config.showSSID ?? true },
                    set: { [weak self] in self?.config.showSSID = $0 }),
            .toggle(label: "Show dBm", key: "showdBm",
                    get: { [weak self] in self?.config.showdBm ?? true },
                    set: { [weak self] in self?.config.showdBm = $0 }),
            .toggle(label: "Show Channel", key: "showChannel",
                    get: { [weak self] in self?.config.showChannel ?? false },
                    set: { [weak self] in self?.config.showChannel = $0 }),
            .toggle(label: "Show Band", key: "showBand",
                    get: { [weak self] in self?.config.showBand ?? false },
                    set: { [weak self] in self?.config.showBand = $0 }),
            .toggle(label: "Show Tx Rate", key: "showTxRate",
                    get: { [weak self] in self?.config.showTxRate ?? false },
                    set: { [weak self] in self?.config.showTxRate = $0 }),
            .toggle(label: "Show Noise", key: "showNoise",
                    get: { [weak self] in self?.config.showNoise ?? false },
                    set: { [weak self] in self?.config.showNoise = $0 }),
            .toggle(label: "Show SNR", key: "showSNR",
                    get: { [weak self] in self?.config.showSNR ?? false },
                    set: { [weak self] in self?.config.showSNR = $0 }),
            .toggle(label: "Compact Labels", key: "compactLabels",
                    get: { [weak self] in self?.config.compactLabels ?? false },
                    set: { [weak self] in self?.config.compactLabels = $0 }),

            .section(title: "Alerts"),
            .slider(label: "Low Signal Threshold", key: "lowSignalThreshold", min: -90, max: -40, step: 5,
                    get: { [weak self] in Double(self?.config.lowSignalThreshold ?? -70) },
                    set: { [weak self] in self?.config.lowSignalThreshold = Int($0) },
                    format: "%.0f dBm"),

            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshRate", min: 2, max: 30, step: 1,
                    get: { [weak self] in self?.config.refreshRate ?? 5 },
                    set: { [weak self] in self?.config.refreshRate = $0 },
                    format: "%.0f s"),
            .slider(label: "History Length", key: "historyLength", min: 20, max: 120, step: 10,
                    get: { [weak self] in Double(self?.config.historyLength ?? 60) },
                    set: { [weak self] in self?.config.historyLength = Int($0) },
                    format: "%.0f pts"),
        ]
    }
}
