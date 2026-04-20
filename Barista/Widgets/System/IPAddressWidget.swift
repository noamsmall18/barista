import Cocoa

struct IPAddressConfig: Codable, Equatable {
    var showPublic: Bool
    var showLocal: Bool

    static let `default` = IPAddressConfig(showPublic: true, showLocal: false)
}

class IPAddressWidget: BaristaWidget {
    static let widgetID = "ip-address"
    static let displayName = "IP Address"
    static let subtitle = "Your public and local IP address"
    static let iconName = "network"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = IPAddressConfig.default

    var config: IPAddressConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 300 }

    private var timer: Timer?
    private(set) var publicIP: String = "--"
    var publicIPValue: String { publicIP }
    private(set) var localIP: String = "--"
    private(set) var lastFetchFailed = false

    required init(config: IPAddressConfig) {
        self.config = config
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        // Local IP
        localIP = getLocalIP() ?? "--"

        // Public IP
        if config.showPublic {
            guard let url = URL(string: "https://api.ipify.org?format=json") else { return }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
                guard let self = self else { return }
                guard let data = data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ip = json["ip"] as? String else {
                    DispatchQueue.main.async {
                        self.lastFetchFailed = true
                        self.onDisplayUpdate?()
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.lastFetchFailed = false
                    self.publicIP = ip
                    self.onDisplayUpdate?()
                }
            }.resume()
        } else {
            onDisplayUpdate?()
        }
    }

    private func getLocalIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        return address
    }

    func render() -> WidgetDisplayMode {
        if config.showPublic && publicIP == "--" && lastFetchFailed {
            return .text("IP: Offline")
        }
        if config.showPublic && config.showLocal {
            return .text("\(publicIP) | \(localIP)")
        } else if config.showPublic {
            return .text(publicIP)
        } else {
            return .text(localIP)
        }
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "IP ADDRESS", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let pubItem = NSMenuItem(title: "Public: \(publicIP)", action: nil, keyEquivalent: "")
        pubItem.isEnabled = false
        menu.addItem(pubItem)

        let localItem = NSMenuItem(title: "Local: \(localIP)", action: nil, keyEquivalent: "")
        localItem.isEnabled = false
        menu.addItem(localItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Copy Public IP", action: #selector(AppDelegate.copyPublicIP), keyEquivalent: "c"))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
