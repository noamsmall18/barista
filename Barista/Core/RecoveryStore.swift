import Foundation
import CryptoKit
import Darwin

/// Versioned copies live outside preferences so deleting a widget or resetting
/// settings cannot delete the recovery history. All test stores are injected.
final class RecoveryStore {
    static let shared: RecoveryStore? = {
        guard !AppPreferences.isRunningTests else { return nil }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppFlavor.current.displayName + "/Recovery", isDirectory: true)
        return RecoveryStore(defaults: ResearchWorkspaceDefaults.shared, directory: root,
                             domain: AppFlavor.current.defaultsSuite)
    }()

    struct Archive: Codable {
        var version = 1
        var domain: String
        var createdAt: Date
        var reason: String
        var kept: Bool
        var payload: Data
        var checksum: String
    }

    struct Backup {
        let url: URL
        let archive: Archive
        let summary: String
    }

    enum RecoveryError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    let directory: URL
    let domain: String
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let recentLimit: Int
    private let mutex = NSRecursiveLock()
    private var lockDepth = 0
    private var protectionDepth = 0
    private(set) var lastError: String?

    init(defaults: UserDefaults, directory: URL, domain: String,
         recentLimit: Int = 100, clock: @escaping () -> Date = Date.init) {
        precondition(!AppPreferences.isRunningTests || defaults is InMemoryTestPreferences,
                     "Recovery tests must use in-memory preferences")
        self.defaults = defaults
        self.directory = directory.resolvingSymlinksInPath()
        self.domain = domain
        self.recentLimit = recentLimit
        self.clock = clock
    }

    static func owns(_ key: String) -> Bool {
        key.hasPrefix("barista.") || key.hasPrefix("marketbar.")
    }

    /// These changes trigger snapshots. Quote responses and chart samples do
    /// not fill the timeline; launch/periodic/manual backups still include them.
    private static let importantKeys: Set<String> = [
        "barista.activeWidgets", "barista.widgetMemory", "barista.profiles",
        "barista.activeProfile", "barista.menuBarAppearance", "marketbar.researchWorkspace.v1"
    ]

    /// A failed automatic backup is exposed in Recovery rather than silently
    /// claiming the change is protected. Existing app persistence still works.
    @discardableResult
    func protect<T>(_ reason: String, change: () -> T) -> T {
        var result: T?
        do {
            try locked {
                if protectionDepth > 0 { result = change(); return }
                protectionDepth += 1
                defer { protectionDepth -= 1 }
                do { _ = try captureUnlocked(reason: "Before " + reason, kept: false, force: false) }
                catch { report(error) }
                result = change()
                do { _ = try captureUnlocked(reason: reason, kept: false, force: false) }
                catch { report(error) }
            }
        } catch {
            report(error)
            return change()
        }
        return result!
    }

    @discardableResult
    static func protect<T>(_ reason: String, change: () -> T) -> T {
        guard let store = shared else { return change() }
        return store.protect(reason, change: change)
    }

    @discardableResult
    func capture(reason: String = "Automatic backup", kept: Bool = false, force: Bool = false) throws -> URL {
        do { return try locked { try captureUnlocked(reason: reason, kept: kept, force: force) } }
        catch { report(error); throw error }
    }

    func backups() throws -> [Backup] {
        try locked {
            try archiveFiles().compactMap { url in
                // Keep damaged files on disk, but never offer an unsafe restore.
                guard let archive = try? read(url),
                      let values = try? validatedValues(archive) else { return nil }
                return Backup(url: url, archive: archive, summary: summary(values))
            }.sorted { $0.archive.createdAt > $1.archive.createdAt }
        }
    }

    func matchesCurrent(_ backup: Backup) -> Bool {
        defaults.synchronize()
        let current = defaults.dictionaryRepresentation().filter { Self.importantKeys.contains($0.key) }
        guard let restored = try? validatedValues(backup.archive) else { return false }
        return NSDictionary(dictionary: current).isEqual(to: restored.filter { Self.importantKeys.contains($0.key) })
    }

    func preview(_ url: URL) throws -> Backup {
        let archive = try read(url)
        let values = try validatedValues(archive)
        return Backup(url: url, archive: archive, summary: summary(values))
    }

    /// One preferences-domain commit prevents a partial restore. A kept backup
    /// of the current state must succeed before any saved setting is replaced.
    @discardableResult
    func restore(_ url: URL) throws -> URL {
        try locked {
            let values = try validatedValues(read(url))
            let safety = try captureUnlocked(reason: "Before restore — undo this restore", kept: true, force: true)
            try withHistoryLock {
                defaults.synchronize()
                var merged = defaults.persistentDomain(forName: domain) ?? defaults.dictionaryRepresentation()
                merged = merged.filter { !Self.owns($0.key) }
                merged.merge(values) { _, restored in restored }
                defaults.setPersistentDomain(merged, forName: domain)
                guard defaults.synchronize(),
                      NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:]).isEqual(to: merged) else {
                    throw RecoveryError.invalid("The restored settings could not be saved. Your pre-restore backup has been kept.")
                }
            }
            do { _ = try captureUnlocked(reason: "Restored backup", kept: false, force: true) }
            catch { report(error) }
            return safety
        }
    }

    func currentDataProblem() -> String? {
        defaults.synchronize()
        let values = (defaults.persistentDomain(forName: domain) ?? defaults.dictionaryRepresentation())
            .filter { Self.owns($0.key) }
        if values["barista.activeWidgets"] == nil,
           let files = try? archiveFiles(), files.contains(where: { url in
               guard let archive = try? read(url), let saved = try? validatedValues(archive) else { return false }
               return saved["barista.activeWidgets"] != nil
           }) {
            return "Your saved layout is missing, but recovery backups are available."
        }
        do {
            let payload = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            _ = try validatedValues(Archive(domain: domain, createdAt: clock(), reason: "Check", kept: false,
                                             payload: payload, checksum: digest(payload)))
            return nil
        } catch { return error.localizedDescription }
    }

    func export(to url: URL) throws {
        let source = try capture(reason: "Manual backup", kept: true, force: true)
        _ = try preview(source)
        try Data(contentsOf: source).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func captureUnlocked(reason: String, kept: Bool, force: Bool) throws -> URL {
        defaults.synchronize()
        let values = (defaults.persistentDomain(forName: domain) ?? defaults.dictionaryRepresentation())
            .filter { Self.owns($0.key) }
        let existing = try archiveFiles().compactMap { url -> (URL, Archive)? in
            guard let archive = try? read(url), archive.domain == domain else { return nil }
            return (url, archive)
        }.sorted { $0.1.createdAt > $1.1.createdAt }
        if !force, !kept, let latest = existing.first,
           let previous = try? PropertyListSerialization.propertyList(from: latest.1.payload, format: nil) as? [String: Any] {
            let important = values.filter { Self.importantKeys.contains($0.key) }
            let oldImportant = previous.filter { Self.importantKeys.contains($0.key) }
            if NSDictionary(dictionary: important).isEqual(to: oldImportant),
               clock().timeIntervalSince(latest.1.createdAt) < 900 { return latest.0 }
        }
        let payload = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        guard payload.count <= 64 * 1_024 * 1_024 else {
            throw RecoveryError.invalid("Your backup is too large to save. Export your data before making more changes.")
        }
        let archive = Archive(domain: domain, createdAt: clock(), reason: reason, kept: kept,
                              payload: payload, checksum: digest(payload))
        let data = try PropertyListEncoder().encode(archive)
        let url = directory.appendingPathComponent(UUID().uuidString + ".marketbarbackup")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // Always retain 100 recent snapshots and one per day for the last 30
        // days. Manual and pre-restore backups are never automatically pruned.
        let automatic = ([(url, archive)] + existing).filter { !$0.1.kept }
        let calendar = Calendar(identifier: .gregorian)
        var daily: [Date: URL] = [:]
        for item in automatic where clock().timeIntervalSince(item.1.createdAt) < 30 * 86_400 {
            daily[calendar.startOfDay(for: item.1.createdAt)] = item.0
        }
        let keepDaily = Set(daily.values)
        let lastGood = existing.first { (try? validatedValues($0.1)) != nil }?.0
        for (index, item) in automatic.enumerated()
        where index >= recentLimit && !keepDaily.contains(item.0) && item.0 != lastGood {
            try? FileManager.default.removeItem(at: item.0)
        }
        lastError = nil
        return url
    }

    private func read(_ url: URL) throws -> Archive {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 70 * 1_024 * 1_024 else { throw RecoveryError.invalid("This backup is too large to open.") }
        let archive = try PropertyListDecoder().decode(Archive.self, from: Data(contentsOf: url))
        guard archive.version == 1 else { throw RecoveryError.invalid("This backup needs a different version of the app.") }
        guard archive.domain == domain else { throw RecoveryError.invalid("This backup belongs to a different app. Marketbar and Barista backups are separate.") }
        guard digest(archive.payload) == archive.checksum else { throw RecoveryError.invalid("This backup is damaged. Choose another backup; your current data has not changed.") }
        return archive
    }

    private func validatedValues(_ archive: Archive) throws -> [String: Any] {
        guard let values = try PropertyListSerialization.propertyList(from: archive.payload, format: nil) as? [String: Any],
              values.keys.allSatisfy(Self.owns) else { throw RecoveryError.invalid("This file is not a valid app backup.") }
        if let raw = values["barista.activeWidgets"] {
            guard let data = raw as? Data else { throw RecoveryError.invalid("The saved widget layout is damaged.") }
            let widgets = try JSONDecoder().decode([SavedWidget].self, from: data)
            guard Set(widgets.map(\.instanceID)).count == widgets.count else { throw RecoveryError.invalid("This backup has duplicate widgets.") }
            for widget in widgets where widget.widgetID == "stock-ticker" {
                if let data = widget.configData { try validatePortfolio(data) }
            }
        }
        if let raw = values["barista.widgetMemory"] {
            guard let data = raw as? Data else { throw RecoveryError.invalid("The saved widget settings are damaged.") }
            let memory = try JSONDecoder().decode([String: Data].self, from: data)
            if let config = memory["stock-ticker"] { try validatePortfolio(config) }
        }
        if let raw = values["barista.profiles"] {
            guard let data = raw as? Data else { throw RecoveryError.invalid("The saved profiles are damaged.") }
            let profiles = try JSONDecoder().decode([WidgetProfile].self, from: data)
            for widget in profiles.flatMap(\.widgets) where widget.widgetID == "stock-ticker" {
                if let config = widget.configData { try validatePortfolio(config) }
            }
        }
        if let raw = values["barista.portfolioHistory"] {
            guard let data = raw as? Data else { throw RecoveryError.invalid("The saved chart history is damaged.") }
            _ = try JSONDecoder().decode([String: [PortfolioHistoryService.Point]].self, from: data)
        }
        if let raw = values["marketbar.researchWorkspace.v1"] {
            guard let data = raw as? Data,
                  let workspace = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  workspace["notes"] is [String: Any], workspace["preferences"] is [String: Any] else {
                throw RecoveryError.invalid("The saved research workspace is damaged.")
            }
        }
        return values
    }

    private func validatePortfolio(_ data: Data) throws {
        // Require recognizable data before using backward-compatible decoders
        // that intentionally default missing fields for older app versions.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["symbols"] is [String], object["portfolios"] is [[String: Any]] || object["holdings"] is [String: Any] else {
            throw RecoveryError.invalid("The saved portfolio is incomplete. Choose another backup.")
        }
        if let portfolios = object["portfolios"] as? [[String: Any]], portfolios.isEmpty || portfolios.count > Portfolio.maxCount {
            throw RecoveryError.invalid("This backup has an invalid number of portfolios.")
        }
        for portfolio in object["portfolios"] as? [[String: Any]] ?? [object] {
            for key in ["holdings", "costBasis"] {
                if let raw = portfolio[key] {
                    guard let numbers = raw as? [String: Double], numbers.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                        throw RecoveryError.invalid("This backup contains invalid position amounts.")
                    }
                }
            }
            if object["portfolios"] != nil {
                guard portfolio["id"] is String, portfolio["name"] is String, portfolio["cash"] is Double,
                      portfolio["holdings"] != nil else {
                    throw RecoveryError.invalid("This backup contains incomplete portfolio records.")
                }
            }
        }
        let config = try JSONDecoder().decode(StockTickerConfig.self, from: data)
        guard Set(config.portfolios.map(\.id)).count == config.portfolios.count,
              config.portfolios.allSatisfy({ p in
                  !p.id.isEmpty && p.cash.isFinite && p.holdings.values.allSatisfy { $0.isFinite && $0 >= 0 }
                    && p.costBasis.values.allSatisfy { $0.isFinite && $0 >= 0 }
                    && Set(p.transactions.map(\.id)).count == p.transactions.count
                    && p.transactions.allSatisfy { !$0.symbol.isEmpty && $0.quantity.isFinite && $0.quantity >= 0 && $0.price.isFinite && $0.price >= 0 && ($0.cashDelta?.isFinite ?? true) }
              }) else { throw RecoveryError.invalid("This backup contains invalid portfolio records.") }
    }

    private func summary(_ values: [String: Any]) -> String {
        var parts: [String] = []
        if let raw = values["barista.activeWidgets"] as? Data,
           let widgets = try? JSONDecoder().decode([SavedWidget].self, from: raw) {
            parts.append("\(widgets.count) widgets")
            let config = widgets.first { $0.widgetID == "stock-ticker" }?.configData
                ?? (values["barista.widgetMemory"] as? Data).flatMap { try? JSONDecoder().decode([String: Data].self, from: $0)["stock-ticker"] }
            if let data = config, let config = try? JSONDecoder().decode(StockTickerConfig.self, from: data) {
                parts += config.portfolios.map { "\($0.name): \($0.holdings.count) positions, cash \(String(format: "%.2f", $0.cash))" }
                parts.append("\(config.symbols.count + config.coins.count) watchlist entries")
            }
        }
        if values["barista.portfolioHistory"] != nil { parts.append("Chart history") }
        if values["marketbar.researchWorkspace.v1"] != nil { parts.append("Research notes and preferences") }
        parts.append("App settings and layouts")
        return parts.joined(separator: "\n")
    }

    private func archiveFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "marketbarbackup" }
            .map { directory.appendingPathComponent($0.lastPathComponent) }
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        NSLog("Recovery backup failed: %@", error.localizedDescription)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        if lockDepth > 0 { return try body() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent("recovery.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        lockDepth += 1
        defer { lockDepth -= 1 }
        return try body()
    }

    private func withHistoryLock<T>(_ body: () throws -> T) throws -> T {
        let file = directory.deletingLastPathComponent().appendingPathComponent("portfolio-history.lock")
        let fd = Darwin.open(file.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
