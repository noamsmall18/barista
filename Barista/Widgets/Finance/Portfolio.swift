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

    /// Average cost per share, keyed by symbol. Sparse on purpose: a symbol is
    /// absent until you record what you paid, and total-return figures stay
    /// hidden for those rather than being invented from a zero cost.
    var costBasis: [String: Double]
    var cash: Double

    init(id: String = UUID().uuidString,
         name: String,
         holdings: [String: Double] = [:],
         costBasis: [String: Double] = [:],
         cash: Double = 0) {
        self.id = id
        self.name = name
        self.holdings = holdings
        self.costBasis = costBasis
        self.cash = cash
    }

    enum CodingKeys: String, CodingKey {
        case id, name, holdings, costBasis, cash
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? Portfolio.fallbackName
        holdings = try c.decodeIfPresent([String: Double].self, forKey: .holdings) ?? [:]
        costBasis = try c.decodeIfPresent([String: Double].self, forKey: .costBasis) ?? [:]
        cash = try c.decodeIfPresent(Double.self, forKey: .cash) ?? 0
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
