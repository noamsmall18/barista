import Foundation

// MARK: - Portfolio

/// One named set of positions plus uninvested cash.
/// The watchlist (symbols/coins) is shared across all portfolios - a portfolio
/// only records how much of each symbol you hold and how much cash sits beside it.
struct Portfolio: Codable, Equatable {
    /// Stable across renames, so the active selection survives an edit.
    var id: String
    var name: String
    var holdings: [String: Double]
    var cash: Double

    init(id: String = UUID().uuidString,
         name: String,
         holdings: [String: Double] = [:],
         cash: Double = 0) {
        self.id = id
        self.name = name
        self.holdings = holdings
        self.cash = cash
    }

    var isEmpty: Bool {
        cash <= 0 && !holdings.values.contains { $0 > 0 }
    }

    // MARK: - Constraints

    /// The tab strip is 396pt wide; past this the tabs stop being readable.
    static let maxCount = 6
    static let fallbackName = "Main"
    private static let maxNameLength = 20

    /// Trim, collapse inner whitespace, cap length, and never return empty.
    static func sanitize(name raw: String) -> String {
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return fallbackName }
        return String(collapsed.prefix(maxNameLength))
    }
}
