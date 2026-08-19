import Foundation

struct FundamentalSeriesPoint {
    let label: String
    let fiscalYear: Int
    let fiscalPeriod: String
    let endDate: String
    let filedDate: String
    let form: String
    let value: Double
}

struct FundamentalMetricSeries {
    let id: String
    let label: String
    let statement: String
    let unit: String
    let sourceConcept: String
    let points: [FundamentalSeriesPoint]

    var latest: FundamentalSeriesPoint? { points.last }
}

struct FundamentalRatio {
    let id: String
    let label: String
    let value: Double
    let display: String
    let detail: String
}

struct StockFundamentals {
    let symbol: String
    let companyName: String
    let cik: String
    let fetchedAt: Date
    let annualMetrics: [String: FundamentalMetricSeries]
    let quarterlyMetrics: [String: FundamentalMetricSeries]
    let ratios: [FundamentalRatio]

    func metric(_ id: String) -> FundamentalMetricSeries? {
        annualMetrics[id]
    }

    func quarterlyMetric(_ id: String) -> FundamentalMetricSeries? {
        quarterlyMetrics[id]
    }

    var latestFiscalYear: Int? {
        annualMetrics.values.compactMap { $0.latest?.fiscalYear }.max()
    }

    var latestQuarterLabel: String? {
        quarterlyMetrics.values.compactMap { $0.latest?.label }.max()
    }
}

final class StockFundamentalsService {
    static let shared = StockFundamentalsService()

    private struct SECCompany {
        let cik: Int
        let ticker: String
        let title: String

        var paddedCIK: String { String(format: "%010d", cik) }
    }

    private let secHeaders = [
        "User-Agent": "Barista stock research terminal contact@example.com",
        "Accept": "application/json"
    ]
    private let cacheQueue = DispatchQueue(label: "barista.stockfundamentals.cache")
    private var tickerMap: [String: SECCompany]?
    private var fundamentalsCache: [String: StockFundamentals] = [:]
    private var pendingTickerMapCallbacks: [([String: SECCompany]?) -> Void] = []
    private var isLoadingTickerMap = false

    private init() {}

    func fetch(symbol: String, completion: @escaping (Result<StockFundamentals, Error>) -> Void) {
        let upper = symbol.uppercased()
        let cached: StockFundamentals? = cacheQueue.sync {
            if let cached = fundamentalsCache[upper],
               Date().timeIntervalSince(cached.fetchedAt) < 12 * 60 * 60 {
                return cached
            }
            return nil
        }
        if let cached {
            DispatchQueue.main.async { completion(.success(cached)) }
            return
        }

        fetchTickerMap { [weak self] map in
            guard let self else { return }
            guard let company = map?[upper] else {
                DispatchQueue.main.async { completion(.failure(URLError(.cannotFindHost))) }
                return
            }
            self.fetchCompanyFacts(symbol: upper, company: company, completion: completion)
        }
    }

    private func fetchTickerMap(completion: @escaping ([String: SECCompany]?) -> Void) {
        var cachedMap: [String: SECCompany]?
        var shouldStart = false
        cacheQueue.sync {
            if let tickerMap {
                cachedMap = tickerMap
                return
            }
            pendingTickerMapCallbacks.append(completion)
            if isLoadingTickerMap { return }
            isLoadingTickerMap = true
            shouldStart = true
        }
        if let cachedMap {
            DispatchQueue.main.async { completion(cachedMap) }
            return
        }
        guard shouldStart else {
            return
        }

        guard let url = URL(string: "https://www.sec.gov/files/company_tickers.json") else {
            completeTickerMap(nil)
            return
        }
        let request = DataFetcher.FetchRequest(url: url, headers: secHeaders, maxAge: 24 * 60 * 60)
        DataFetcher.shared.fetch(request) { [weak self] result in
            guard let self else { return }
            guard case .success(let data) = result,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.completeTickerMap(nil)
                return
            }

            var parsed: [String: SECCompany] = [:]
            for value in json.values {
                guard let entry = value as? [String: Any],
                      let cik = entry["cik_str"] as? Int,
                      let ticker = entry["ticker"] as? String,
                      let title = entry["title"] as? String else { continue }
                parsed[ticker.uppercased()] = SECCompany(cik: cik, ticker: ticker.uppercased(), title: title)
            }
            self.completeTickerMap(parsed)
        }
    }

    private func completeTickerMap(_ map: [String: SECCompany]?) {
        let callbacks: [([String: SECCompany]?) -> Void] = cacheQueue.sync {
            if let map { tickerMap = map }
            isLoadingTickerMap = false
            let callbacks = pendingTickerMapCallbacks
            pendingTickerMapCallbacks.removeAll()
            return callbacks
        }
        DispatchQueue.main.async {
            callbacks.forEach { $0(map) }
        }
    }

    private func fetchCompanyFacts(symbol: String, company: SECCompany, completion: @escaping (Result<StockFundamentals, Error>) -> Void) {
        guard let url = URL(string: "https://data.sec.gov/api/xbrl/companyfacts/CIK\(company.paddedCIK).json") else {
            DispatchQueue.main.async { completion(.failure(URLError(.badURL))) }
            return
        }
        let request = DataFetcher.FetchRequest(url: url, headers: secHeaders, maxAge: 12 * 60 * 60)
        DataFetcher.shared.fetch(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                do {
                    let fundamentals = try self.parseCompanyFacts(data: data, symbol: symbol, company: company)
                    self.cacheQueue.sync { self.fundamentalsCache[symbol] = fundamentals }
                    DispatchQueue.main.async { completion(.success(fundamentals)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            case .failure(let error):
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func parseCompanyFacts(data: Data, symbol: String, company: SECCompany) throws -> StockFundamentals {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let facts = json["facts"] as? [String: Any],
              let usgaap = facts["us-gaap"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        var metrics: [String: FundamentalMetricSeries] = [:]
        var quarterlyMetrics: [String: FundamentalMetricSeries] = [:]
        func addBoth(id: String, label: String, statement: String, unit: String, candidates: [String]) {
            addMetric(&metrics, id: id, label: label, statement: statement, unit: unit, usgaap: usgaap, candidates: candidates)
            addQuarterlyMetric(&quarterlyMetrics, id: id, label: label, statement: statement, unit: unit, usgaap: usgaap, candidates: candidates)
        }

        addBoth(id: "revenue", label: "Revenue", statement: "Income", unit: "USD", candidates: [
            "RevenueFromContractWithCustomerExcludingAssessedTax", "Revenues", "SalesRevenueNet"
        ])
        addBoth(id: "cost_of_revenue", label: "Cost of Revenue", statement: "Income", unit: "USD", candidates: [
            "CostOfRevenue", "CostOfGoodsAndServicesSold", "CostOfGoodsSold"
        ])
        addBoth(id: "gross_profit", label: "Gross Profit", statement: "Income", unit: "USD", candidates: ["GrossProfit"])
        addBoth(id: "r_and_d", label: "Research & Development", statement: "Income", unit: "USD", candidates: [
            "ResearchAndDevelopmentExpense", "ResearchAndDevelopmentExpenseExcludingAcquiredInProcessCost"
        ])
        addBoth(id: "sga", label: "SG&A", statement: "Income", unit: "USD", candidates: [
            "SellingGeneralAndAdministrativeExpense", "SellingAndMarketingExpense"
        ])
        addBoth(id: "operating_income", label: "Operating Income", statement: "Income", unit: "USD", candidates: ["OperatingIncomeLoss"])
        addBoth(id: "interest_expense", label: "Interest Expense", statement: "Income", unit: "USD", candidates: [
            "InterestExpenseNonOperating", "InterestExpense", "InterestAndDebtExpense"
        ])
        addBoth(id: "pretax_income", label: "Pretax Income", statement: "Income", unit: "USD", candidates: [
            "IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest",
            "IncomeLossFromContinuingOperationsBeforeIncomeTaxesMinorityInterestAndIncomeLossFromEquityMethodInvestments",
            "IncomeLossFromContinuingOperationsBeforeIncomeTaxes"
        ])
        addBoth(id: "income_tax", label: "Income Tax", statement: "Income", unit: "USD", candidates: [
            "IncomeTaxExpenseBenefit"
        ])
        addBoth(id: "net_income", label: "Net Income", statement: "Income", unit: "USD", candidates: ["NetIncomeLoss", "ProfitLoss"])
        addBoth(id: "operating_cash_flow", label: "Operating Cash Flow", statement: "Cash Flow", unit: "USD", candidates: ["NetCashProvidedByUsedInOperatingActivities"])
        addBoth(id: "capex", label: "Capital Expenditures", statement: "Cash Flow", unit: "USD", candidates: ["PaymentsToAcquirePropertyPlantAndEquipment"])
        addBoth(id: "current_assets", label: "Current Assets", statement: "Balance Sheet", unit: "USD", candidates: ["AssetsCurrent"])
        addBoth(id: "assets", label: "Assets", statement: "Balance Sheet", unit: "USD", candidates: ["Assets"])
        addBoth(id: "current_liabilities", label: "Current Liabilities", statement: "Balance Sheet", unit: "USD", candidates: ["LiabilitiesCurrent"])
        addBoth(id: "liabilities", label: "Liabilities", statement: "Balance Sheet", unit: "USD", candidates: ["Liabilities"])
        addBoth(id: "equity", label: "Shareholders' Equity", statement: "Balance Sheet", unit: "USD", candidates: [
            "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest", "StockholdersEquity"
        ])
        addBoth(id: "cash", label: "Cash & Equivalents", statement: "Balance Sheet", unit: "USD", candidates: [
            "CashAndCashEquivalentsAtCarryingValue", "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents", "CashAndCashEquivalentsAndShortTermInvestments"
        ])
        addBoth(id: "receivables", label: "Receivables", statement: "Balance Sheet", unit: "USD", candidates: [
            "AccountsReceivableNetCurrent", "ReceivablesNetCurrent"
        ])
        addBoth(id: "inventory", label: "Inventory", statement: "Balance Sheet", unit: "USD", candidates: ["InventoryNet"])
        addBoth(id: "goodwill", label: "Goodwill", statement: "Balance Sheet", unit: "USD", candidates: ["Goodwill"])
        addBoth(id: "shares_diluted", label: "Diluted Shares", statement: "Per Share", unit: "shares", candidates: ["WeightedAverageNumberOfDilutedSharesOutstanding"])
        addBoth(id: "eps_diluted", label: "Diluted EPS", statement: "Per Share", unit: "USD/shares", candidates: [
            "EarningsPerShareDiluted", "DilutedEarningsPerShare", "EarningsPerShareBasicAndDiluted"
        ])
        addBoth(id: "dividends_paid", label: "Dividends Paid", statement: "Cash Flow", unit: "USD", candidates: [
            "PaymentsOfDividends", "PaymentsOfDividendsCommonStock"
        ])

        if let debt = combinedDebtSeries(usgaap: usgaap) {
            metrics["debt"] = debt
        } else {
            addMetric(&metrics, id: "debt", label: "Debt", statement: "Balance Sheet", unit: "USD", usgaap: usgaap, candidates: [
                "LongTermDebtAndFinanceLeaseObligations", "LongTermDebt", "LongTermDebtAndFinanceLeaseObligationsNoncurrent"
            ])
        }
        if let debt = combinedDebtSeries(usgaap: usgaap, quarterly: true) {
            quarterlyMetrics["debt"] = debt
        }

        if let fcf = freeCashFlowSeries(cfo: metrics["operating_cash_flow"], capex: metrics["capex"]) {
            metrics["free_cash_flow"] = fcf
        }
        if let fcf = freeCashFlowSeries(cfo: quarterlyMetrics["operating_cash_flow"], capex: quarterlyMetrics["capex"]) {
            quarterlyMetrics["free_cash_flow"] = fcf
        }

        let fundamentals = StockFundamentals(
            symbol: symbol,
            companyName: (json["entityName"] as? String) ?? company.title,
            cik: company.paddedCIK,
            fetchedAt: Date(),
            annualMetrics: metrics,
            quarterlyMetrics: quarterlyMetrics,
            ratios: buildRatios(metrics: metrics)
        )
        return fundamentals
    }

    private func addMetric(_ metrics: inout [String: FundamentalMetricSeries],
                           id: String,
                           label: String,
                           statement: String,
                           unit: String,
                           usgaap: [String: Any],
                           candidates: [String]) {
        guard let series = metricSeries(id: id, label: label, statement: statement, unit: unit, usgaap: usgaap, candidates: candidates) else { return }
        metrics[id] = series
    }

    private func addQuarterlyMetric(_ metrics: inout [String: FundamentalMetricSeries],
                                    id: String,
                                    label: String,
                                    statement: String,
                                    unit: String,
                                    usgaap: [String: Any],
                                    candidates: [String]) {
        guard let series = quarterlyMetricSeries(id: id, label: label, statement: statement, unit: unit, usgaap: usgaap, candidates: candidates) else { return }
        metrics[id] = series
    }

    private func metricSeries(id: String,
                              label: String,
                              statement: String,
                              unit: String,
                              usgaap: [String: Any],
                              candidates: [String]) -> FundamentalMetricSeries? {
        for concept in candidates {
            guard let conceptObject = usgaap[concept] as? [String: Any],
                  let units = conceptObject["units"] as? [String: Any],
                  let facts = factsArray(from: units, preferredUnit: unit) else { continue }
            let points = annualPoints(from: facts)
            if points.count >= 1 {
                return FundamentalMetricSeries(id: id,
                                               label: label,
                                               statement: statement,
                                               unit: unit,
                                               sourceConcept: concept,
                                               points: Array(points.suffix(6)))
            }
        }
        return nil
    }

    private func quarterlyMetricSeries(id: String,
                                       label: String,
                                       statement: String,
                                       unit: String,
                                       usgaap: [String: Any],
                                       candidates: [String]) -> FundamentalMetricSeries? {
        for concept in candidates {
            guard let conceptObject = usgaap[concept] as? [String: Any],
                  let units = conceptObject["units"] as? [String: Any],
                  let facts = factsArray(from: units, preferredUnit: unit) else { continue }
            let points = quarterlyPoints(from: facts)
            if points.count >= 1 {
                return FundamentalMetricSeries(id: id,
                                               label: label,
                                               statement: statement,
                                               unit: unit,
                                               sourceConcept: concept,
                                               points: Array(points.suffix(12)))
            }
        }
        return nil
    }

    private func factsArray(from units: [String: Any], preferredUnit: String) -> [[String: Any]]? {
        let preferences: [String]
        if preferredUnit == "USD" {
            preferences = ["USD", "USD/shares", "pure", "shares"]
        } else if preferredUnit == "shares" {
            preferences = ["shares", "pure"]
        } else {
            preferences = [preferredUnit, "USD/shares", "pure", "USD"]
        }
        for key in preferences {
            if let arr = units[key] as? [[String: Any]], !arr.isEmpty { return arr }
        }
        return units.values.compactMap { $0 as? [[String: Any]] }.first(where: { !$0.isEmpty })
    }

    private func annualPoints(from facts: [[String: Any]]) -> [FundamentalSeriesPoint] {
        var byYear: [Int: [String: Any]] = [:]
        for fact in facts {
            let form = (fact["form"] as? String) ?? ""
            let fp = (fact["fp"] as? String) ?? ""
            let frame = (fact["frame"] as? String) ?? ""
            let isAnnual = fp == "FY" || form == "10-K" || form == "20-F" || form == "40-F" || frame.range(of: #"^CY\d{4}$"#, options: .regularExpression) != nil
            guard isAnnual, let value = factNumber(fact["val"]), value.isFinite else { continue }
            guard let year = factInt(fact["fy"]) ?? yearFromEnd(fact["end"] as? String) else { continue }
            if let existing = byYear[year] {
                let existingFiled = existing["filed"] as? String ?? ""
                let newFiled = fact["filed"] as? String ?? ""
                let existingForm = existing["form"] as? String ?? ""
                let newForm = fact["form"] as? String ?? ""
                let existingScore = annualPreferenceScore(form: existingForm, fp: existing["fp"] as? String ?? "")
                let newScore = annualPreferenceScore(form: newForm, fp: fp)
                if newScore > existingScore || (newScore == existingScore && newFiled > existingFiled) {
                    byYear[year] = fact
                }
            } else {
                byYear[year] = fact
            }
        }

        return byYear.keys.sorted().compactMap { year in
            guard let fact = byYear[year], let value = factNumber(fact["val"]) else { return nil }
            return FundamentalSeriesPoint(
                label: "\(year)",
                fiscalYear: year,
                fiscalPeriod: (fact["fp"] as? String) ?? "FY",
                endDate: (fact["end"] as? String) ?? "",
                filedDate: (fact["filed"] as? String) ?? "",
                form: (fact["form"] as? String) ?? "",
                value: value
            )
        }
    }

    private func quarterlyPoints(from facts: [[String: Any]]) -> [FundamentalSeriesPoint] {
        var byQuarter: [String: [String: Any]] = [:]
        for fact in facts {
            guard let value = factNumber(fact["val"]), value.isFinite else { continue }
            let form = (fact["form"] as? String) ?? ""
            let fp = (fact["fp"] as? String) ?? ""
            let frame = (fact["frame"] as? String) ?? ""
            guard let parsed = quarterIdentity(frame: frame, fp: fp, fy: factInt(fact["fy"])) else { continue }
            let looksQuarterly = frame.contains("Q") || fp.hasPrefix("Q") || form == "10-Q"
            guard looksQuarterly else { continue }
            let key = "\(parsed.year)-\(parsed.period)"
            if let existing = byQuarter[key] {
                let existingFiled = existing["filed"] as? String ?? ""
                let newFiled = fact["filed"] as? String ?? ""
                let existingScore = quarterlyPreferenceScore(form: existing["form"] as? String ?? "", frame: existing["frame"] as? String ?? "")
                let newScore = quarterlyPreferenceScore(form: form, frame: frame)
                if newScore > existingScore || (newScore == existingScore && newFiled > existingFiled) {
                    byQuarter[key] = fact
                }
            } else {
                byQuarter[key] = fact
            }
        }

        return byQuarter.keys.sorted().compactMap { key in
            guard let fact = byQuarter[key],
                  let value = factNumber(fact["val"]),
                  let parsed = quarterIdentity(frame: fact["frame"] as? String ?? "",
                                               fp: fact["fp"] as? String ?? "",
                                               fy: factInt(fact["fy"])) else { return nil }
            return FundamentalSeriesPoint(
                label: "\(parsed.year) \(parsed.period)",
                fiscalYear: parsed.year,
                fiscalPeriod: parsed.period,
                endDate: (fact["end"] as? String) ?? "",
                filedDate: (fact["filed"] as? String) ?? "",
                form: (fact["form"] as? String) ?? "",
                value: value
            )
        }
    }

    private func quarterIdentity(frame: String, fp: String, fy: Int?) -> (year: Int, period: String)? {
        if frame.hasPrefix("CY"), let qRange = frame.range(of: "Q") {
            let yearText = frame.dropFirst(2).prefix(4)
            let quarterText = frame[qRange.upperBound...].prefix(1)
            if let year = Int(yearText), let quarter = Int(quarterText), (1...4).contains(quarter) {
                return (year, "Q\(quarter)")
            }
        }
        if fp.count == 2, fp.hasPrefix("Q"), let quarter = Int(fp.dropFirst()), (1...4).contains(quarter) {
            guard let fy, fy > 0 else { return nil }
            return (fy, "Q\(quarter)")
        }
        return nil
    }

    private func quarterlyPreferenceScore(form: String, frame: String) -> Int {
        var score = 0
        if form == "10-Q" { score += 3 }
        if frame.hasPrefix("CY") && frame.contains("Q") { score += 2 }
        if !frame.hasSuffix("I") { score += 1 }
        return score
    }

    private func annualPreferenceScore(form: String, fp: String) -> Int {
        var score = 0
        if fp == "FY" { score += 3 }
        if form == "10-K" || form == "20-F" || form == "40-F" { score += 2 }
        return score
    }

    private func yearFromEnd(_ end: String?) -> Int? {
        guard let end, end.count >= 4 else { return nil }
        return Int(end.prefix(4))
    }

    private func factNumber(_ raw: Any?) -> Double? {
        if let double = raw as? Double { return double }
        if let int = raw as? Int { return Double(int) }
        if let number = raw as? NSNumber { return number.doubleValue }
        return nil
    }

    private func factInt(_ raw: Any?) -> Int? {
        if let int = raw as? Int { return int }
        if let number = raw as? NSNumber { return number.intValue }
        if let string = raw as? String { return Int(string) }
        return nil
    }

    private func combinedDebtSeries(usgaap: [String: Any], quarterly: Bool = false) -> FundamentalMetricSeries? {
        let currentCandidates = ["LongTermDebtAndFinanceLeaseObligationsCurrent", "LongTermDebtCurrent", "ShortTermBorrowings"]
        let noncurrentCandidates = ["LongTermDebtAndFinanceLeaseObligationsNoncurrent", "LongTermDebtNoncurrent"]
        let current = quarterly
            ? quarterlyMetricSeries(id: "debt_current", label: "Current Debt", statement: "Balance Sheet", unit: "USD", usgaap: usgaap, candidates: currentCandidates)
            : metricSeries(id: "debt_current", label: "Current Debt", statement: "Balance Sheet", unit: "USD", usgaap: usgaap, candidates: currentCandidates)
        let noncurrent = quarterly
            ? quarterlyMetricSeries(id: "debt_noncurrent", label: "Noncurrent Debt", statement: "Balance Sheet", unit: "USD", usgaap: usgaap, candidates: noncurrentCandidates)
            : metricSeries(id: "debt_noncurrent", label: "Noncurrent Debt", statement: "Balance Sheet", unit: "USD", usgaap: usgaap, candidates: noncurrentCandidates)
        guard current != nil || noncurrent != nil else { return nil }
        let keys = Set((current?.points ?? []).map { quarterly ? $0.label : "\($0.fiscalYear)" } +
                       (noncurrent?.points ?? []).map { quarterly ? $0.label : "\($0.fiscalYear)" }).sorted()
        let points = keys.compactMap { key -> FundamentalSeriesPoint? in
            let c = current?.points.first(where: { (quarterly ? $0.label : "\($0.fiscalYear)") == key })
            let n = noncurrent?.points.first(where: { (quarterly ? $0.label : "\($0.fiscalYear)") == key })
            let value = (c?.value ?? 0) + (n?.value ?? 0)
            guard value != 0 else { return nil }
            let source = n ?? c
            return FundamentalSeriesPoint(label: source?.label ?? key,
                                          fiscalYear: source?.fiscalYear ?? Int(key) ?? 0,
                                          fiscalPeriod: source?.fiscalPeriod ?? (quarterly ? "Q" : "FY"),
                                          endDate: source?.endDate ?? "",
                                          filedDate: source?.filedDate ?? "",
                                          form: source?.form ?? "",
                                          value: value)
        }
        guard !points.isEmpty else { return nil }
        return FundamentalMetricSeries(id: "debt",
                                       label: "Debt",
                                       statement: "Balance Sheet",
                                       unit: "USD",
                                       sourceConcept: "Debt current + noncurrent",
                                       points: Array(points.suffix(quarterly ? 12 : 6)))
    }

    private func freeCashFlowSeries(cfo: FundamentalMetricSeries?, capex: FundamentalMetricSeries?) -> FundamentalMetricSeries? {
        guard let cfo, let capex else { return nil }
        let labels = Set(cfo.points.map(\.label) + capex.points.map(\.label)).sorted()
        let points = labels.compactMap { label -> FundamentalSeriesPoint? in
            guard let cfoPoint = cfo.points.first(where: { $0.label == label }),
                  let capexPoint = capex.points.first(where: { $0.label == label }) else { return nil }
            let capexOutflow = abs(capexPoint.value)
            return FundamentalSeriesPoint(label: cfoPoint.label,
                                          fiscalYear: cfoPoint.fiscalYear,
                                          fiscalPeriod: cfoPoint.fiscalPeriod,
                                          endDate: cfoPoint.endDate,
                                          filedDate: cfoPoint.filedDate,
                                          form: cfoPoint.form,
                                          value: cfoPoint.value - capexOutflow)
        }
        guard !points.isEmpty else { return nil }
        let suffixCount = points.contains(where: { $0.fiscalPeriod != "FY" }) ? 12 : 6
        return FundamentalMetricSeries(id: "free_cash_flow",
                                       label: "Free Cash Flow",
                                       statement: "Cash Flow",
                                       unit: "USD",
                                       sourceConcept: "Operating cash flow - capex",
                                       points: Array(points.suffix(suffixCount)))
    }

    private func buildRatios(metrics: [String: FundamentalMetricSeries]) -> [FundamentalRatio] {
        func latest(_ id: String) -> Double? { metrics[id]?.latest?.value }
        var ratios: [FundamentalRatio] = []
        if let revenue = latest("revenue"), let gross = latest("gross_profit"), revenue != 0 {
            ratios.append(percentRatio("gross_margin", "Gross Margin", gross / revenue, "gross profit / revenue"))
        }
        if let revenue = latest("revenue"), let op = latest("operating_income"), revenue != 0 {
            ratios.append(percentRatio("operating_margin", "Operating Margin", op / revenue, "operating income / revenue"))
        }
        if let revenue = latest("revenue"), let net = latest("net_income"), revenue != 0 {
            ratios.append(percentRatio("net_margin", "Net Margin", net / revenue, "net income / revenue"))
        }
        if let revenue = latest("revenue"), let fcf = latest("free_cash_flow"), revenue != 0 {
            ratios.append(percentRatio("fcf_margin", "FCF Margin", fcf / revenue, "free cash flow / revenue"))
        }
        if let equity = latest("equity"), let net = latest("net_income"), equity != 0 {
            ratios.append(percentRatio("roe", "ROE", net / equity, "net income / equity"))
        }
        if let assets = latest("assets"), let net = latest("net_income"), assets != 0 {
            ratios.append(percentRatio("roa", "ROA", net / assets, "net income / assets"))
        }
        if let debt = latest("debt"), let equity = latest("equity"), equity != 0 {
            ratios.append(multipleRatio("debt_equity", "Debt / Equity", debt / equity, "debt / equity"))
        }
        if let cash = latest("cash"), let debt = latest("debt"), debt != 0 {
            ratios.append(multipleRatio("cash_debt", "Cash / Debt", cash / debt, "cash / debt"))
        }
        if let currentAssets = latest("current_assets"), let currentLiabilities = latest("current_liabilities"), currentLiabilities != 0 {
            ratios.append(multipleRatio("current_ratio", "Current Ratio", currentAssets / currentLiabilities, "current assets / current liabilities"))
        }
        if let cash = latest("cash"), let receivables = latest("receivables"), let currentLiabilities = latest("current_liabilities"), currentLiabilities != 0 {
            ratios.append(multipleRatio("quick_ratio", "Quick Ratio", (cash + receivables) / currentLiabilities, "cash + receivables / current liabilities"))
        }
        if let revenue = latest("revenue"), let assets = latest("assets"), assets != 0 {
            ratios.append(multipleRatio("asset_turnover", "Asset Turnover", revenue / assets, "revenue / assets"))
        }
        if let revenue = latest("revenue"), let capex = latest("capex"), revenue != 0 {
            ratios.append(percentRatio("capex_sales", "Capex / Sales", abs(capex) / revenue, "capital expenditures / revenue"))
        }
        if let operatingIncome = latest("operating_income"), let interest = latest("interest_expense"), interest != 0 {
            ratios.append(multipleRatio("interest_cover", "Interest Cover", operatingIncome / abs(interest), "operating income / interest expense"))
        }
        if let pretax = latest("pretax_income"), let tax = latest("income_tax"), pretax != 0 {
            ratios.append(percentRatio("tax_rate", "Tax Rate", tax / pretax, "income tax / pretax income"))
        }
        if let netIncome = latest("net_income"), let operatingCashFlow = latest("operating_cash_flow"), netIncome != 0 {
            ratios.append(multipleRatio("ocf_conversion", "OCF / NI", operatingCashFlow / netIncome, "operating cash flow / net income"))
        }
        if let netIncome = latest("net_income"), let fcf = latest("free_cash_flow"), netIncome != 0 {
            ratios.append(multipleRatio("fcf_conversion", "FCF / NI", fcf / netIncome, "free cash flow / net income"))
        }
        if let revenue = latest("revenue"), let rAndD = latest("r_and_d"), revenue != 0 {
            ratios.append(percentRatio("rd_sales", "R&D / Sales", abs(rAndD) / revenue, "R&D expense / revenue"))
        }
        if let revenue = latest("revenue"), let sga = latest("sga"), revenue != 0 {
            ratios.append(percentRatio("sga_sales", "SG&A / Sales", abs(sga) / revenue, "SG&A expense / revenue"))
        }
        if let revenue = metrics["revenue"]?.points, revenue.count >= 4,
           let first = revenue.dropLast(3).last?.value, let last = revenue.last?.value, first > 0 {
            let cagr = pow(last / first, 1.0 / 3.0) - 1
            ratios.append(percentRatio("revenue_cagr_3y", "Revenue 3Y CAGR", cagr, "three-year revenue compound growth"))
        }
        if let shares = metrics["shares_diluted"]?.points, shares.count >= 2,
           let first = shares.first?.value, let last = shares.last?.value, first > 0 {
            ratios.append(percentRatio("share_change", "Share Count Change", (last - first) / first, "first visible diluted shares to latest"))
        }
        return ratios
    }

    private func percentRatio(_ id: String, _ label: String, _ value: Double, _ detail: String) -> FundamentalRatio {
        FundamentalRatio(id: id,
                         label: label,
                         value: value,
                         display: String(format: "%.1f%%", value * 100),
                         detail: detail)
    }

    private func multipleRatio(_ id: String, _ label: String, _ value: Double, _ detail: String) -> FundamentalRatio {
        FundamentalRatio(id: id,
                         label: label,
                         value: value,
                         display: String(format: "%.2fx", value),
                         detail: detail)
    }
}
