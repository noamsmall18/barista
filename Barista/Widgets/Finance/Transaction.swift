import Foundation

// MARK: - Transaction ledger

/// One recorded event in a portfolio's history.
///
/// The ledger is the single source of truth: share counts and average cost are
/// derived from it rather than stored independently, so they cannot drift out of
/// step with each other. A manual correction is not an exception to that - it is
/// recorded as an `.adjustment` entry, which keeps one authoritative history and
/// leaves a visible trace of when and why a number was forced.
struct Transaction: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case buy, sell, adjustment

        var label: String {
            switch self {
            case .buy: return "Buy"
            case .sell: return "Sell"
            case .adjustment: return "Set"
            }
        }
    }

    var id: String = UUID().uuidString
    var date: Date
    var symbol: String
    var kind: Kind

    /// Shares traded. For `.adjustment` this is the resulting absolute share
    /// count, not a delta, which is what makes "just set it to 15" expressible.
    var quantity: Double

    /// Price per share. For `.adjustment` it is the average cost to record;
    /// zero means "leave the existing average cost alone".
    var price: Double

    var note: String?

    /// Positions carried over from before the ledger existed. Dated far enough
    /// back that any real trade logged later sorts after it and applies on top.
    static let openingDate = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01

    var isOpeningPosition: Bool {
        kind == .adjustment && date == Transaction.openingDate
    }

    init(id: String = UUID().uuidString,
         date: Date,
         symbol: String,
         kind: Kind,
         quantity: Double,
         price: Double,
         note: String? = nil) {
        self.id = id
        self.date = date
        self.symbol = symbol.uppercased()
        self.kind = kind
        self.quantity = quantity
        self.price = price
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case id, date, symbol, kind, quantity, price, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Transaction.openingDate
        symbol = (try c.decodeIfPresent(String.self, forKey: .symbol) ?? "").uppercased()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .adjustment
        quantity = try c.decodeIfPresent(Double.self, forKey: .quantity) ?? 0
        price = try c.decodeIfPresent(Double.self, forKey: .price) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

// MARK: - Derivation

/// What a ledger works out to: the state every other part of the app reads.
struct LedgerState: Equatable {
    var holdings: [String: Double] = [:]
    var costBasis: [String: Double] = [:]
    /// Profit or loss actually banked by selling, per symbol.
    var realized: [String: Double] = [:]

    var realizedTotal: Double { realized.values.reduce(0, +) }
}

enum Ledger {
    /// Replays the ledger to produce current share counts, average cost and
    /// realised profit.
    ///
    /// Average cost uses the weighted-average method: a sale banks the profit on
    /// the shares sold and leaves the average for the remainder untouched, which
    /// is the convention every broker statement shows.
    static func derive(from transactions: [Transaction]) -> LedgerState {
        var shares: [String: Double] = [:]
        var avgCost: [String: Double] = [:]
        var realized: [String: Double] = [:]

        // Stable ordering: by date, and by original position within the same date
        // so two entries on one day replay in the order they were recorded.
        let ordered = transactions.enumerated()
            .sorted { a, b in
                a.element.date == b.element.date
                    ? a.offset < b.offset
                    : a.element.date < b.element.date
            }
            .map(\.element)

        for t in ordered {
            let sym = t.symbol.uppercased()
            guard !sym.isEmpty else { continue }
            let held = shares[sym] ?? 0

            switch t.kind {
            case .buy:
                guard t.quantity > 0 else { continue }
                let total = held + t.quantity
                let priorCost = (avgCost[sym] ?? t.price) * held
                avgCost[sym] = total > 0 ? (priorCost + t.price * t.quantity) / total : t.price
                shares[sym] = total

            case .sell:
                guard t.quantity > 0, held > 0 else { continue }
                let sold = min(t.quantity, held)
                if let cost = avgCost[sym], cost > 0 {
                    realized[sym, default: 0] += (t.price - cost) * sold
                }
                shares[sym] = held - sold

            case .adjustment:
                shares[sym] = max(0, t.quantity)
                if t.price > 0 { avgCost[sym] = t.price }
            }
        }

        var state = LedgerState()
        state.holdings = shares.filter { $0.value > 0 }
        // Only keep an average for something still held, and never a zero: a zero
        // average would render as a fabricated 100% gain.
        state.costBasis = avgCost.filter { sym, cost in cost > 0 && (shares[sym] ?? 0) > 0 }
        state.realized = realized.filter { $0.value != 0 }
        return state
    }

    /// Turns pre-ledger holdings into opening entries, so migrating an existing
    /// portfolio reproduces exactly the numbers it showed before.
    static func openingEntries(holdings: [String: Double],
                               costBasis: [String: Double]) -> [Transaction] {
        holdings
            .filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
            .map { symbol, quantity in
                Transaction(date: Transaction.openingDate,
                            symbol: symbol,
                            kind: .adjustment,
                            quantity: quantity,
                            price: costBasis[symbol] ?? 0,
                            note: "Opening position")
            }
    }
}
