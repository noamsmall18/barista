import Cocoa

// MARK: - Holdings Form

/// The shares + average cost accessory shown by the holdings dialog.
///
/// Pulled out of the dialog so the layout can be built and rendered without
/// running a modal, which is the only way to check it without clicking through.
final class HoldingsForm {
    let view: NSView
    let shareField: NSTextField
    let costField: NSTextField

    /// The container is a plain (unflipped) NSView, so these are measured from
    /// the bottom up: cost input, cost label, share input, share label.
    private static let fieldWidth: CGFloat = 240
    private static let fieldHeight: CGFloat = 22
    private static let labelHeight: CGFloat = 14
    private static let labelGap: CGFloat = 3     // between a label and its field
    private static let groupGap: CGFloat = 12    // between the two field groups

    static var formHeight: CGFloat {
        fieldHeight + labelGap + labelHeight + groupGap + fieldHeight + labelGap + labelHeight
    }

    init(shares: Double, cost: Double?) {
        let w = Self.fieldWidth
        let fh = Self.fieldHeight
        let lh = Self.labelHeight

        let costFieldY: CGFloat = 0
        let costLabelY = costFieldY + fh + Self.labelGap
        let shareFieldY = costLabelY + lh + Self.groupGap
        let shareLabelY = shareFieldY + fh + Self.labelGap

        view = NSView(frame: NSRect(x: 0, y: 0, width: w, height: Self.formHeight))

        let mono = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)

        func label(_ text: String, y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = labelFont
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingTail
            l.frame = NSRect(x: 0, y: y, width: w, height: lh)
            return l
        }

        let shareLabel = label("Shares held (0 to remove)", y: shareLabelY)
        view.addSubview(shareLabel)

        shareField = NSTextField(frame: NSRect(x: 0, y: shareFieldY, width: w, height: fh))
        shareField.font = mono
        shareField.stringValue = shares > 0 ? Self.trimmed(shares) : ""
        shareField.placeholderString = "0"
        view.addSubview(shareField)

        let costLabel = label("Average cost per share (optional)", y: costLabelY)
        view.addSubview(costLabel)

        costField = NSTextField(frame: NSRect(x: 0, y: costFieldY, width: w, height: fh))
        costField.font = mono
        if let cost, cost > 0 {
            costField.stringValue = String(format: "%.2f", cost)
        }
        costField.placeholderString = "leave blank to skip"
        view.addSubview(costField)

        shareField.nextKeyView = costField
        costField.nextKeyView = shareField
    }

    // MARK: - Reading values

    var enteredShares: Double {
        Double(Self.digits(shareField.stringValue)) ?? 0
    }

    /// Nil means "leave any existing cost alone"; a typed 0 clears it.
    var enteredCost: Double? {
        let typed = Self.digits(costField.stringValue)
        guard !typed.isEmpty else { return nil }
        return Double(typed) ?? 0
    }

    private static func digits(_ raw: String) -> String {
        raw.filter { $0.isNumber || $0 == "." }
    }

    /// 6.3 rather than 6.30, but 6.25 keeps both places.
    private static func trimmed(_ value: Double) -> String {
        if value == value.rounded() { return String(format: "%.0f", value) }
        return String(format: "%g", value)
    }
}
