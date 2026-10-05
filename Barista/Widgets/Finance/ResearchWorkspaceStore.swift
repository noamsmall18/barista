import Foundation
import CoreFoundation

/// Research annotations never mutate the portfolio ledger. The current app's
/// preferences domain keeps these durable across browser sessions and restarts.
enum ResearchWorkspaceStore {
    private static let key = "marketbar.researchWorkspace.v1"

    static func load(defaults: UserDefaults = .standard) -> [String: Any] {
        defaults.synchronize()
        guard let data = defaults.data(forKey: key),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["notes": [String: Any](), "preferences": [String: Any]()]
        }
        return result
    }

    @discardableResult
    static func save(_ data: Data, defaults: UserDefaults = .standard) -> Bool {
        guard data.count <= 245_760,
              let update = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !update.isEmpty, Set(update.keys).isSubset(of: ["symbol", "note", "preferences"]) else { return false }
        var workspace = load(defaults: defaults)
        if let rawNote = update["note"] {
            guard let symbol = update["symbol"] as? String, !symbol.isEmpty, symbol.count <= 100,
                  let note = rawNote as? [String: Any], validNote(note) else { return false }
            var notes = workspace["notes"] as? [String: Any] ?? [:]
            // Bound storage independently of the current watchlist.
            guard notes[symbol] != nil || notes.count < 1_000 else { return false }
            // Merge old three-field clients without removing newer research data.
            var saved = notes[symbol] as? [String: Any] ?? [:]
            for (name, value) in note { saved[name] = value }
            saved["updatedAt"] = Date().timeIntervalSince1970
            notes[symbol] = saved
            workspace["notes"] = notes
        } else if update["symbol"] != nil { return false }
        if let rawPreferences = update["preferences"] {
            guard let preferences = rawPreferences as? [String: Any],
                  Set(preferences.keys).isSubset(of: ["compact", "portfolioRange", "portfolioUnit", "financialPeriod", "securityRange", "securityUnit", "favorites", "selected", "benchmark", "researchSymbols"]) else { return false }
            let allowed: [String: Set<String>] = [
                "portfolioRange": ["1D", "1W", "1M", "ALL"], "portfolioUnit": ["value", "percent"],
                "financialPeriod": ["annual", "quarterly"], "securityRange": ["1D", "5D", "1M", "6M", "1Y", "5Y"],
                "securityUnit": ["value", "percent"]
            ]
            for (name, value) in preferences {
                if let choices = allowed[name] {
                    guard let value = value as? String, choices.contains(value) else { return false }
                } else if name == "compact" || name == "benchmark" {
                    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
                } else if name == "researchSymbols" {
                    guard let symbols = value as? [String], symbols.count <= 100,
                          Set(symbols).count == symbols.count,
                          symbols.allSatisfy(ResearchWorkspaceRequest.validResearchSymbol) else { return false }
                } else if name == "favorites" {
                    guard let symbols = value as? [String], symbols.count <= 200,
                          symbols.allSatisfy({ !$0.isEmpty && $0.count <= 100 }) else { return false }
                } else if name == "selected" {
                    guard let symbol = value as? String, symbol.count <= 100 else { return false }
                }
            }
            var saved = workspace["preferences"] as? [String: Any] ?? [:]
            for (name, value) in preferences { saved[name] = value }
            workspace["preferences"] = saved
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: workspace) else { return false }
        defaults.set(encoded, forKey: key)
        defaults.synchronize()
        return true
    }

    private static func boolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func number(_ value: Any?, range: ClosedRange<Double>) -> Bool {
        guard let number = value as? NSNumber, !boolean(number) else { return false }
        return number.doubleValue.isFinite && range.contains(number.doubleValue)
    }

    private static func text(_ value: Any?, limit: Int, nonempty: Bool = false) -> Bool {
        guard let string = value as? String else { return false }
        return string.count <= limit && (!nonempty || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private static func validNote(_ note: [String: Any]) -> Bool {
        let required: Set<String> = ["thesis", "risks", "catalysts"]
        let optional: Set<String> = ["stage", "conviction", "reviewDate", "evidence", "questions", "valuation"]
        guard required.isSubset(of: Set(note.keys)), Set(note.keys).isSubset(of: required.union(optional)),
              required.allSatisfy({ text(note[$0], limit: 12_000) }) else { return false }
        if let stage = note["stage"] {
            guard let stage = stage as? String, ["inbox", "researching", "ready", "monitoring", "archived"].contains(stage) else { return false }
        }
        if let conviction = note["conviction"] {
            guard let conviction = conviction as? String, ["unrated", "low", "medium", "high"].contains(conviction) else { return false }
        }
        if let date = note["reviewDate"] {
            guard let date = date as? String else { return false }
            if !date.isEmpty {
                let format = DateFormatter()
                format.locale = Locale(identifier: "en_US_POSIX")
                format.timeZone = TimeZone(secondsFromGMT: 0)
                format.dateFormat = "yyyy-MM-dd"
                format.isLenient = false
                guard date.count == 10, let parsed = format.date(from: date), format.string(from: parsed) == date else { return false }
            }
        }
        for name in ["evidence", "questions"] {
            guard let raw = note[name] else { continue }
            guard let records = raw as? [[String: Any]], records.count <= 100 else { return false }
            var ids = Set<String>()
            for record in records {
                guard let id = record["id"] as? String, text(id, limit: 80, nonempty: true), ids.insert(id).inserted,
                      number(record["createdAt"], range: 0...4_102_444_800) else { return false }
                if name == "evidence" {
                    guard Set(record.keys) == ["id", "text", "source", "url", "kind", "createdAt"],
                          text(record["text"], limit: 2_000, nonempty: true), text(record["source"], limit: 200),
                          let url = record["url"] as? String, url.count <= 2_000,
                          let kind = record["kind"] as? String, ["supports", "challenges", "question"].contains(kind) else { return false }
                    if !url.isEmpty {
                        guard let parsed = URLComponents(string: url), parsed.scheme == "https", parsed.host?.isEmpty == false,
                              parsed.user == nil, parsed.password == nil else { return false }
                    }
                } else {
                    guard Set(record.keys) == ["id", "text", "done", "createdAt"],
                          text(record["text"], limit: 500, nonempty: true), boolean(record["done"]) else { return false }
                }
            }
        }
        if let raw = note["valuation"] {
            guard let model = raw as? [String: Any], Set(model.keys) == ["eps", "years", "basis", "bear", "base", "bull"],
                  number(model["eps"], range: 0...1_000_000), text(model["basis"], limit: 200),
                  let years = model["years"] as? NSNumber, !boolean(years), [1.0, 2, 3, 5].contains(years.doubleValue) else { return false }
            for name in ["bear", "base", "bull"] {
                guard let scenario = model[name] as? [String: Any], Set(scenario.keys) == ["growth", "multiple"],
                      number(scenario["growth"], range: -90...200), number(scenario["multiple"], range: 0...200) else { return false }
            }
        }
        return true
    }
}
