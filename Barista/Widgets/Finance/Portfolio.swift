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

    /// The authoritative record. `holdings` and `costBasis` above are a cache of
    /// what replaying this produces, kept as stored properties so the rest of the
    /// app can read them cheaply without knowing the ledger exists.
    var transactions: [Transaction] = []

    /// Profit banked by selling, as opposed to gains still on paper.
    var realized: [String: Double] = [:]

    /// Set when the ledger was seeded from pre-ledger holdings during decode.
    /// Not persisted; it exists so the app knows to write the migrated form back
    /// once, instead of re-deriving it on every launch.
    var didSeedLedger: Bool = false

    init(id: String = UUID().uuidString,
         name: String,
         holdings: [String: Double] = [:],
         costBasis: [String: Double] = [:],
         cash: Double = 0,
         transactions: [Transaction] = []) {
        self.id = id
        self.name = name
        self.holdings = holdings
        self.costBasis = costBasis
        self.cash = cash
        self.transactions = transactions
        if transactions.isEmpty {
            self.transactions = Ledger.openingEntries(holdings: holdings, costBasis: costBasis)
        }
        applyLedger()
    }

    enum CodingKeys: String, CodingKey {
        case id, name, holdings, costBasis, cash, transactions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? Portfolio.fallbackName
        holdings = try c.decodeIfPresent([String: Double].self, forKey: .holdings) ?? [:]
        costBasis = try c.decodeIfPresent([String: Double].self, forKey: .costBasis) ?? [:]
        cash = try c.decodeIfPresent(Double.self, forKey: .cash) ?? 0
        transactions = try c.decodeIfPresent([Transaction].self, forKey: .transactions) ?? []

        // Portfolios saved before the ledger existed carry holdings but no
        // history. Seed opening entries from what they already had so the
        // migration is invisible: the derived numbers come out identical.
        if transactions.isEmpty, holdings.contains(where: { $0.value > 0 }) {
            transactions = Ledger.openingEntries(holdings: holdings, costBasis: costBasis)
            didSeedLedger = true
        }
        applyLedger()
    }

    // MARK: - Ledger

    /// Recomputes the cached holdings, cost basis and realised profit.
    /// Call after any change to `transactions`.
    mutating func applyLedger() {
        guard !transactions.isEmpty else { realized = [:]; return }
        let state = Ledger.derive(from: transactions)
        holdings = state.holdings
        costBasis = state.costBasis
        realized = state.realized
    }

    mutating func record(_ transaction: Transaction) {
        transactions.append(transaction)
        applyLedger()
    }

    mutating func removeTransaction(id: String) {
        transactions.removeAll { $0.id == id }
        applyLedger()
    }

    /// Records a manual correction rather than writing the number directly, so
    /// the ledger stays the only place state comes from.
    mutating func setQuantity(_ quantity: Double, for symbol: String,
                              averageCost: Double? = nil, note: String? = nil) {
        // Typing a number in means "this is the truth now", so the correction is
        // dated after everything already recorded. Without this, a trade dated in
        // the future would replay on top of it and the correction would look like
        // it silently did nothing.
        let latest = transactions.map(\.date).max() ?? .distantPast
        let stamp = max(Date(), latest.addingTimeInterval(1))
        record(Transaction(date: stamp, symbol: symbol, kind: .adjustment,
                           quantity: max(0, quantity),
                           price: averageCost ?? 0,
                           note: note ?? "Manual adjustment"))
    }

    var realizedTotal: Double { realized.values.reduce(0, +) }

    /// Trades only, newest first. Opening entries are history, not decisions.
    var tradeHistory: [Transaction] {
        transactions
            .filter { !$0.isOpeningPosition }
            .sorted { $0.date > $1.date }
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
