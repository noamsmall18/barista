import Cocoa

struct DailyQuoteConfig: Codable, Equatable {
    var showInBar: Bool
    var scrollInBar: Bool
    var tickerWidth: Double

    static let `default` = DailyQuoteConfig(
        showInBar: true,
        scrollInBar: true,
        tickerWidth: 200
    )
}

class DailyQuoteWidget: BaristaWidget {
    static let widgetID = "daily-quote"
    static let displayName = "Daily Quote"
    static let subtitle = "Inspiring quotes refreshed daily"
    static let iconName = "text.quote"
    static let category = WidgetCategory.funLifestyle
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = DailyQuoteConfig.default

    var config: DailyQuoteConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 3600 }

    private(set) var currentQuote: String = ""
    private(set) var currentAuthor: String = ""
    private var timer: Timer?

    private static let quotes: [(String, String)] = [
        ("The only way to do great work is to love what you do.", "Steve Jobs"),
        ("Innovation distinguishes between a leader and a follower.", "Steve Jobs"),
        ("Stay hungry, stay foolish.", "Steve Jobs"),
        ("Life is what happens when you're busy making other plans.", "John Lennon"),
        ("The future belongs to those who believe in the beauty of their dreams.", "Eleanor Roosevelt"),
        ("It is during our darkest moments that we must focus to see the light.", "Aristotle"),
        ("The best time to plant a tree was 20 years ago. The second best time is now.", "Chinese Proverb"),
        ("Your time is limited, don't waste it living someone else's life.", "Steve Jobs"),
        ("If you look at what you have in life, you'll always have more.", "Oprah Winfrey"),
        ("The mind is everything. What you think you become.", "Buddha"),
        ("Strive not to be a success, but rather to be of value.", "Albert Einstein"),
        ("The best revenge is massive success.", "Frank Sinatra"),
        ("I have not failed. I've just found 10,000 ways that won't work.", "Thomas Edison"),
        ("A person who never made a mistake never tried anything new.", "Albert Einstein"),
        ("The only impossible journey is the one you never begin.", "Tony Robbins"),
        ("Everything you've ever wanted is on the other side of fear.", "George Addair"),
        ("Success is not final, failure is not fatal. It is the courage to continue that counts.", "Winston Churchill"),
        ("Believe you can and you're halfway there.", "Theodore Roosevelt"),
        ("Act as if what you do makes a difference. It does.", "William James"),
        ("What you get by achieving your goals is not as important as what you become.", "Zig Ziglar"),
        ("The secret of getting ahead is getting started.", "Mark Twain"),
        ("Don't be afraid to give up the good to go for the great.", "John D. Rockefeller"),
        ("I find that the harder I work, the more luck I seem to have.", "Thomas Jefferson"),
        ("Success usually comes to those who are too busy to be looking for it.", "Henry David Thoreau"),
        ("Don't let yesterday take up too much of today.", "Will Rogers"),
        ("You learn more from failure than from success.", "Unknown"),
        ("It's not whether you get knocked down, it's whether you get up.", "Vince Lombardi"),
        ("We may encounter many defeats but we must not be defeated.", "Maya Angelou"),
        ("Whether you think you can or you think you can't, you're right.", "Henry Ford"),
        ("The only limit to our realization of tomorrow is our doubts of today.", "Franklin D. Roosevelt"),
        ("Creativity is intelligence having fun.", "Albert Einstein"),
        ("Do what you can, with what you have, where you are.", "Theodore Roosevelt"),
        ("In the middle of every difficulty lies opportunity.", "Albert Einstein"),
        ("It always seems impossible until it's done.", "Nelson Mandela"),
        ("Be yourself; everyone else is already taken.", "Oscar Wilde"),
        ("Two things are infinite: the universe and human stupidity.", "Albert Einstein"),
        ("You miss 100% of the shots you don't take.", "Wayne Gretzky"),
        ("The purpose of our lives is to be happy.", "Dalai Lama"),
        ("Life is really simple, but we insist on making it complicated.", "Confucius"),
        ("Try not to become a man of success. Rather become a man of value.", "Albert Einstein"),
        ("Not how long, but how well you have lived is the main thing.", "Seneca"),
        ("If you want to live a happy life, tie it to a goal, not to people or things.", "Albert Einstein"),
        ("The unexamined life is not worth living.", "Socrates"),
        ("Turn your wounds into wisdom.", "Oprah Winfrey"),
        ("The way to get started is to quit talking and begin doing.", "Walt Disney"),
        ("If life were predictable it would cease to be life.", "Eleanor Roosevelt"),
        ("Life is a succession of lessons which must be lived to be understood.", "Ralph Waldo Emerson"),
        ("You only live once, but if you do it right, once is enough.", "Mae West"),
        ("The greatest glory in living lies not in never falling, but in rising every time we fall.", "Nelson Mandela"),
        ("Go confidently in the direction of your dreams.", "Henry David Thoreau"),
        ("Nothing is impossible. The word itself says I'm possible.", "Audrey Hepburn"),
        ("Keep your face always toward the sunshine and shadows will fall behind you.", "Walt Whitman"),
        ("The best and most beautiful things cannot be seen or touched. They must be felt.", "Helen Keller"),
        ("Do not go where the path may lead. Go instead where there is no path and leave a trail.", "Ralph Waldo Emerson"),
        ("Spread love everywhere you go.", "Mother Teresa"),
        ("When you reach the end of your rope, tie a knot in it and hang on.", "Franklin D. Roosevelt"),
        ("Always remember that you are absolutely unique. Just like everyone else.", "Margaret Mead"),
        ("The only person you are destined to become is the person you decide to be.", "Ralph Waldo Emerson"),
        ("Happiness is not something readymade. It comes from your own actions.", "Dalai Lama"),
        ("Well done is better than well said.", "Benjamin Franklin"),
        ("If you set your goals ridiculously high and it's a failure, you will fail above everyone else's success.", "James Cameron"),
        ("The real test is not whether you avoid this failure. It's whether you let it harden or shame you into inaction.", "Barack Obama"),
        ("What lies behind us and what lies before us are tiny matters compared to what lies within us.", "Ralph Waldo Emerson"),
        ("Live in the sunshine, swim the sea, drink the wild air.", "Ralph Waldo Emerson"),
        ("Whoever is happy will make others happy too.", "Anne Frank"),
    ]

    required init(config: DailyQuoteConfig) {
        self.config = config
        pickQuote()
    }

    private func pickQuote() {
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        let idx = (dayOfYear - 1) % DailyQuoteWidget.quotes.count
        let (quote, author) = DailyQuoteWidget.quotes[idx]
        currentQuote = quote
        currentAuthor = author
    }

    func start() {
        pickQuote()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.pickQuote()
            self?.onDisplayUpdate?()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func render() -> WidgetDisplayMode {
        if !config.showInBar {
            return .text("\u{201C} Daily Quote")
        }

        let display = "\u{201C}\(currentQuote)\u{201D} - \(currentAuthor)"

        if config.scrollInBar {
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let attr = NSAttributedString(string: display + "    ", attributes: [
                .font: font,
                .foregroundColor: NSColor.headerTextColor
            ])
            return .scrollingText(attr, width: CGFloat(config.tickerWidth))
        }

        // Truncate for static display
        if display.count > 40 {
            return .text(String(display.prefix(37)) + "...")
        }
        return .text(display)
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "DAILY QUOTE", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        // Full quote (may be multi-line)
        let quoteItem = NSMenuItem(title: "\u{201C}\(currentQuote)\u{201D}", action: nil, keyEquivalent: "")
        quoteItem.isEnabled = false
        menu.addItem(quoteItem)

        let authorItem = NSMenuItem(title: "- \(currentAuthor)", action: nil, keyEquivalent: "")
        authorItem.isEnabled = false
        menu.addItem(authorItem)

        menu.addItem(NSMenuItem.separator())

        let copyItem = NSMenuItem(title: "Copy Quote", action: #selector(AppDelegate.copyQuote), keyEquivalent: "c")
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
