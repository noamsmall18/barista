import Foundation

/// Scheduled US equity sessions in exchange time, independent of the Mac's time
/// zone. Overnight availability still requires an observed, fresh provider bar.
/// Calendar: https://www.nyse.com/markets/hours-calendars
/// Overnight: https://robinhood.com/us/en/support/articles/24-hour-market/
enum PortfolioTradingCalendar {
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    private static let holidayLock = NSLock()
    private static var holidayCache: [Int: Set<Date>] = [:]

    static func isTradingDay(_ date: Date) -> Bool {
        let cal = calendar
        let day = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: day)
        guard weekday != 1, weekday != 7 else { return false }
        return !holidays(in: cal.component(.year, from: day)).contains(day)
    }

    private static func holidays(in year: Int) -> Set<Date> {
        holidayLock.lock()
        defer { holidayLock.unlock() }
        if let cached = holidayCache[year] { return cached }
        let cal = calendar
        func fixed(_ month: Int, _ number: Int) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: number))!
        }
        func observed(_ date: Date) -> Date {
            switch cal.component(.weekday, from: date) {
            case 7: return cal.date(byAdding: .day, value: -1, to: date)!
            case 1: return cal.date(byAdding: .day, value: 1, to: date)!
            default: return date
            }
        }
        func nth(_ month: Int, _ weekday: Int, _ ordinal: Int) -> Date {
            cal.date(from: DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: ordinal))!
        }
        // New Year's Saturday is the exchange's exception: the preceding Friday
        // stays open (for example December 31, 2021 and 2027).
        let newYear = fixed(1, 1)
        var holidays = [cal.component(.weekday, from: newYear) == 1 ? observed(newYear) : newYear,
                        nth(1, 2, 3), nth(2, 2, 3), nth(5, 2, -1),
                        observed(fixed(7, 4)), nth(9, 2, 1), nth(11, 5, 4), observed(fixed(12, 25))]
        if year >= 2022 { holidays.append(observed(fixed(6, 19))) }
        // Gregorian Easter (Meeus), then Good Friday.
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30, i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7, m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let number = (h + l - 7 * m + 114) % 31 + 1
        holidays.append(cal.date(byAdding: .day, value: -2, to: fixed(month, number))!)
        // Exceptional full-day closures in the period supported by existing data.
        let special = ["2012-10-29", "2012-10-30", "2018-12-05", "2025-01-09"]
        let exceptional = special.compactMap { stamp -> Date? in
            let parts = stamp.split(separator: "-").compactMap { Int($0) }
            return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        let result = Set(holidays + exceptional)
        holidayCache[year] = result
        return result
    }

    static func isEarlyClose(_ date: Date) -> Bool {
        guard isTradingDay(date) else { return false }
        let cal = calendar
        let month = cal.component(.month, from: date), day = cal.component(.day, from: date)
        return (month == 7 && day == 3) || (month == 12 && day == 24)
            || (month == 11 && cal.component(.weekday, from: date) == 6 && (23...29).contains(day))
    }

    static func isExtendedSession(_ date: Date) -> Bool {
        guard isTradingDay(date) else { return false }
        let cal = calendar
        let minute = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        return minute >= 240 && minute <= (isEarlyClose(date) ? 1020 : 1200)
    }

    static func isOvernightSession(_ date: Date) -> Bool {
        let cal = calendar
        let hour = cal.component(.hour, from: date)
        if hour < 4 { return isTradingDay(date) }
        guard hour >= 20, !isEarlyClose(date),
              let next = cal.date(byAdding: .day, value: 1, to: date) else { return false }
        return isTradingDay(next)
    }
}
