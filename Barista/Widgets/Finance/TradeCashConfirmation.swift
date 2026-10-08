import Cocoa

/// Shared by every position dialog so a cash override is always explicit.
enum TradeCashConfirmation {
    enum Result: Equatable {
        case recorded
        case cancelled
        case invalid(String)
    }

    static func recordTrade(widget: StockTickerWidget, symbol: String, kind: MarketQuote.Kind,
                            side: Transaction.Kind, quantity: Double, price: Double,
                            confirmOverride: ((String) -> Bool)? = nil) -> Result {
        if let problem = widget.tradeValidationProblem(symbol: symbol, kind: kind, side: side,
                                                       quantity: quantity, price: price,
                                                       allowCashOverdraft: true) {
            return .invalid(problem)
        }
        let needsOverride = side == .buy && widget.buyRequiresCashOverride(quantity: quantity, price: price)
        if needsOverride {
            let amount = quantity * price
            let remaining = widget.config.cash - amount
            let message = "You don't have enough cash for this purchase.\n\nCurrent cash: \(widget.formatCurrency(widget.config.cash))\nPurchase cost: \(widget.formatCurrency(amount))\nCash after purchase: \(widget.formatCurrency(remaining))\n\nRecord the buy anyway? Its full cost will be deducted from current cash. The shortfall will remain as negative cash; no deposit will be added."
            let confirmed: Bool
            if let confirmOverride {
                confirmed = confirmOverride(message)
            } else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Not enough cash"
                alert.informativeText = message
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Record buy anyway")
                confirmed = alert.runModal() == .alertSecondButtonReturn
            }
            guard confirmed else { return .cancelled }
        }
        guard widget.recordTrade(symbol: symbol, kind: kind, side: side,
                                 quantity: quantity, price: price,
                                 allowCashOverdraft: needsOverride) else {
            return .invalid(widget.tradeValidationProblem(symbol: symbol, kind: kind, side: side,
                                                          quantity: quantity, price: price,
                                                          allowCashOverdraft: needsOverride)
                ?? "Could not record this trade. Your portfolio has not changed.")
        }
        return .recorded
    }
}
