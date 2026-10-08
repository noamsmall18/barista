import Foundation

/// Presentation-only filtering and ordering for Marketbar's watchlist.
/// Quote ownership and refresh cadence stay with StockTickerWidget.
struct MarketbarWatchlistModel {
    struct Row: Equatable {
        let symbol: String
        let kind: MarketQuote.Kind
        let price: Double?
        let changePercent: Double?
        let positionValue: Double?
        let positionCurrency: String
        let totalReturnPercent: Double?
    }

    enum Sort: String, CaseIterable {
        case symbol = "Symbol"
        case change = "Largest move"
        case positionValue = "Position value"
    }

    var query = ""
    var sort: Sort = .symbol

    func visibleRows(from rows: [Row]) -> [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = needle.isEmpty ? rows : rows.filter {
            $0.symbol.localizedCaseInsensitiveContains(needle)
                || ($0.kind == .crypto && "crypto".localizedCaseInsensitiveContains(needle))
                || ($0.kind == .stock && "stock".localizedCaseInsensitiveContains(needle))
        }
        switch sort {
        case .symbol:
            return filtered.sorted { $0.symbol.localizedStandardCompare($1.symbol) == .orderedAscending }
        case .change:
            return filtered.sorted {
                switch ($0.changePercent, $1.changePercent) {
                case let (lhs?, rhs?):
                    if abs(lhs) == abs(rhs) { return $0.symbol < $1.symbol }
                    return abs(lhs) > abs(rhs)
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return $0.symbol < $1.symbol
                }
            }
        case .positionValue:
            return filtered.sorted {
                let lhs = $0.positionValue ?? -Double.infinity
                let rhs = $1.positionValue ?? -Double.infinity
                if lhs == rhs { return $0.symbol < $1.symbol }
                return lhs > rhs
            }
        }
    }
}
