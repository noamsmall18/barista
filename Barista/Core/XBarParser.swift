import Cocoa

/// Parses xbar/SwiftBar-compatible script output into menu bar display and dropdown items.
///
/// Format:
///   Line 1 before `---` = menu bar title
///   Lines after `---` = dropdown menu items
///   `--` prefix = submenu item
///   Pipe params: `| color=red font=Menlo size=12 href=https://... bash=/path terminal=false image=base64`
struct XBarParser {

    struct ParsedOutput {
        let menuBarLine: ParsedLine
        let menuItems: [ParsedLine]
    }

    struct ParsedLine {
        let text: String
        let params: [String: String]
        let depth: Int  // 0 = top, 1 = submenu, 2 = sub-submenu

        var color: NSColor? {
            guard let colorStr = params["color"] else { return nil }
            return parseColor(colorStr)
        }

        var font: NSFont {
            let name = params["font"] ?? "System"
            let size = CGFloat(Double(params["size"] ?? "13") ?? 13)
            return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
        }

        var href: String? { params["href"] }
        var bash: String? { params["bash"] }
        var terminal: Bool { params["terminal"]?.lowercased() != "false" }
        var refresh: Bool { params["refresh"]?.lowercased() == "true" }

        var sfImage: NSImage? {
            guard let name = params["sfimage"] else { return nil }
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                return img
            }
            return nil
        }

        var image: NSImage? {
            guard let b64 = params["image"],
                  let data = Data(base64Encoded: b64),
                  let img = NSImage(data: data) else { return nil }
            return img
        }

        var attributedString: NSAttributedString {
            var attrs: [NSAttributedString.Key: Any] = [.font: font]
            if let c = color { attrs[.foregroundColor] = c }
            return NSAttributedString(string: text, attributes: attrs)
        }
    }

    /// Parse full script output.
    static func parse(_ output: String) -> ParsedOutput {
        let lines = output.components(separatedBy: "\n")
        var menuBarText = ""
        var menuItems: [ParsedLine] = []
        var foundSeparator = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed == "---" {
                foundSeparator = true
                continue
            }

            if !foundSeparator {
                // Menu bar line (use last non-separator line before ---)
                menuBarText = trimmed
            } else {
                menuItems.append(parseLine(trimmed))
            }
        }

        let menuBarLine = parseLine(menuBarText)
        return ParsedOutput(menuBarLine: menuBarLine, menuItems: menuItems)
    }

    /// Parse a single line with optional pipe params.
    static func parseLine(_ line: String) -> ParsedLine {
        // Count depth (-- prefix for submenus)
        var depth = 0
        var text = line
        while text.hasPrefix("--") {
            depth += 1
            text = String(text.dropFirst(2))
        }
        text = text.trimmingCharacters(in: .whitespaces)

        // Split on first ` | ` to get params
        var params: [String: String] = [:]
        if let pipeRange = text.range(of: " | ", options: .literal) {
            let paramStr = String(text[pipeRange.upperBound...])
            text = String(text[..<pipeRange.lowerBound])

            // Parse key=value pairs
            let parts = splitParams(paramStr)
            for part in parts {
                let kv = part.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    params[String(kv[0]).trimmingCharacters(in: .whitespaces)] =
                        String(kv[1]).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        return ParsedLine(text: text, params: params, depth: depth)
    }

    /// Split params respecting quoted values.
    private static func splitParams(_ str: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var quoteChar: Character = "\""

        for ch in str {
            if !inQuotes && (ch == "\"" || ch == "'") {
                inQuotes = true
                quoteChar = ch
                current.append(ch)
            } else if inQuotes && ch == quoteChar {
                inQuotes = false
                current.append(ch)
            } else if !inQuotes && ch == " " {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: - Color Parsing

    private static func parseColor(_ str: String) -> NSColor? {
        let lower = str.lowercased().trimmingCharacters(in: .whitespaces)

        // Named colors
        let named: [String: NSColor] = [
            "red": .systemRed, "green": .systemGreen, "blue": .systemBlue,
            "yellow": .systemYellow, "orange": .systemOrange, "purple": .systemPurple,
            "pink": .systemPink, "white": .white, "black": .black,
            "gray": .systemGray, "grey": .systemGray, "cyan": .cyan,
            "brown": .systemBrown, "teal": .systemTeal, "indigo": .systemIndigo,
        ]
        if let c = named[lower] { return c }

        // Hex color (#RGB, #RRGGBB, #RRGGBBAA)
        if lower.hasPrefix("#") {
            return parseHex(String(lower.dropFirst()))
        }

        return nil
    }

    private static func parseHex(_ hex: String) -> NSColor? {
        var hexStr = hex
        if hexStr.count == 3 {
            hexStr = hexStr.map { "\($0)\($0)" }.joined()
        }

        guard hexStr.count >= 6 else { return nil }

        let scanner = Scanner(string: hexStr)
        var value: UInt64 = 0
        guard scanner.scanHexInt64(&value) else { return nil }

        if hexStr.count == 8 {
            let r = CGFloat((value >> 24) & 0xFF) / 255.0
            let g = CGFloat((value >> 16) & 0xFF) / 255.0
            let b = CGFloat((value >> 8) & 0xFF) / 255.0
            let a = CGFloat(value & 0xFF) / 255.0
            return NSColor(red: r, green: g, blue: b, alpha: a)
        }

        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1)
    }

    // MARK: - Build NSMenu from parsed output

    static func buildMenu(from items: [ParsedLine], refreshAction: Selector?, target: AnyObject?) -> NSMenu {
        let menu = NSMenu()

        for item in items {
            if item.text == "---" {
                menu.addItem(NSMenuItem.separator())
                continue
            }

            if item.depth == 0 {
                let menuItem = buildMenuItem(from: item, target: target)
                menu.addItem(menuItem)
            } else {
                // Find or create submenu on last top-level item
                if let parent = menu.items.last {
                    if parent.submenu == nil {
                        parent.submenu = NSMenu()
                    }
                    let sub = buildMenuItem(from: item, target: target)
                    parent.submenu?.addItem(sub)
                }
            }
        }

        return menu
    }

    private static func buildMenuItem(from line: ParsedLine, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = line.attributedString

        if let img = line.sfImage {
            item.image = img
        } else if let img = line.image {
            img.size = NSSize(width: 16, height: 16)
            item.image = img
        }

        // Actionable items
        if line.href != nil || line.bash != nil {
            item.isEnabled = true
            item.representedObject = line
            item.target = target
            item.action = Selector(("xbarItemClicked:"))
        } else {
            item.isEnabled = false
        }

        return item
    }
}
