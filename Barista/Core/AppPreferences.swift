import Foundation

/// Tests must never read or overwrite the user's installed app preferences.
/// The explicit flag also covers manual verification with a disposable app.
enum AppPreferences {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["BARISTA_TEST_MODE"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
            || CommandLine.arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent == "xctest" } == true
    }

    static let testSuiteName = "com.noam.barista.tests." + UUID().uuidString

    static let shared: UserDefaults = {
        guard isRunningTests else { return .standard }
        // Fail closed rather than falling back to the user's settings.
        guard let isolated = InMemoryTestPreferences(suiteName: testSuiteName) else {
            preconditionFailure("Unable to create isolated test preferences")
        }
        return isolated
    }()
}

/// Every preference operation used by the app is handled in RAM during tests.
/// Even a test that resets a store cannot write to any on-disk defaults domain.
final class InMemoryTestPreferences: UserDefaults {
    private var values: [String: Any] = [:]
    private let lock = NSRecursiveLock()

    override func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    override func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    override func removeObject(forKey key: String) { set(nil, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: URL?, forKey key: String) { set(value as Any?, forKey: key) }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func url(forKey key: String) -> URL? { object(forKey: key) as? URL }
    override func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    override func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    override func float(forKey key: String) -> Float { (object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
    override func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    override func synchronize() -> Bool { true }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    override func register(defaults registrationDictionary: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        values.merge(registrationDictionary) { current, _ in current }
    }
}
