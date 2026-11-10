import XCTest
@testable import Barista

/// End-to-end pass over the shipped request gate and research store: the
/// checks that used to live in a standalone `swiftc` smoke program, which could
/// no longer compile on its own once the store gained recovery protection.
final class ResearchWorkspaceGateTests: XCTestCase {
    private final class MemoryDefaults: UserDefaults {
        var values: [String: Any] = [:]
        override func data(forKey key: String) -> Data? { values[key] as? Data }
        override func set(_ value: Any?, forKey key: String) { values[key] = value }
    }

    func testRequestGateAndStoreRoundTrip() throws {
        let origin = "http://127.0.0.1:54321"
        let body = Data("{\"symbol\":\"AAPL\",\"note\":{\"thesis\":\"☕ Evidence\",\"risks\":\"\",\"catalysts\":\"\"}}".utf8)
        func post(path: String = "/secret/workspace", source: String? = origin, contentType: String = "application/json") -> Data {
            let headers = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:54321\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n" + (source.map { "Origin: \($0)\r\n" } ?? "") + "\r\n"
            return Data(headers.utf8) + body
        }
        func allowed(_ data: Data) -> Bool { ResearchWorkspaceRequest.authorizedPath(request: data, origin: origin, token: "secret") != nil }
        XCTAssertTrue(allowed(post()), "valid same-origin notes POST must pass")
        XCTAssertTrue(!allowed(post(source: nil)), "missing POST Origin must fail")
        XCTAssertTrue(!allowed(post(source: "https://evil.example")), "foreign Origin must fail")
        XCTAssertTrue(!allowed(post(path: "/secret/snapshot")), "portfolio writes must fail")
        XCTAssertTrue(!allowed(post(contentType: "text/plain")), "form-like request must fail")
        let headerOnly = Data(post().dropLast(body.count))
        XCTAssertTrue(ResearchWorkspaceRequest.requestLength(headerOnly) == post().count, "framing must use UTF-8 byte length")
        XCTAssertTrue(!allowed(headerOnly), "incomplete bodies must wait")
        XCTAssertTrue(!allowed(post() + Data("tail".utf8)), "extra body bytes must fail")
        XCTAssertTrue(ResearchWorkspaceRequest.requestLength(Data("GET / HTTP/1.1\r\nContent-Length: 9999999999\r\n\r\n".utf8)) == nil, "oversized requests must fail")
        XCTAssertTrue(ResearchWorkspaceRequest.requestLength(Data("GET / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n".utf8)) == nil, "duplicate lengths must fail")
        XCTAssertTrue(allowed(Data("GET /secret/snapshot HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n".utf8)), "existing snapshot reads must pass")
        XCTAssertTrue(!allowed(Data("GET /secret/snapshot HTTP/1.1\r\nHost: evil.example\r\n\r\n".utf8)), "DNS rebinding Host must fail")
        let defaults = MemoryDefaults()
        XCTAssertTrue(ResearchWorkspaceStore.save(body, defaults: defaults))
        XCTAssertTrue(ResearchWorkspaceStore.save(Data("{\"preferences\":{\"compact\":true,\"portfolioRange\":\"1M\"}}".utf8), defaults: defaults))
        let notes = ResearchWorkspaceStore.load(defaults: defaults)["notes"] as! [String: [String: Any]]
        XCTAssertTrue(notes["AAPL"]?["thesis"] as? String == "☕ Evidence", "notes must round-trip without losing Unicode")
        let before = defaults.values
        let invalid = Data("{\"symbol\":\"MSFT\",\"note\":{\"thesis\":\"bad\",\"risks\":\"\",\"catalysts\":\"\"},\"preferences\":{\"compact\":1}}".utf8)
        XCTAssertTrue(!ResearchWorkspaceStore.save(invalid, defaults: defaults))
        XCTAssertTrue((before as NSDictionary).isEqual(to: defaults.values), "invalid updates must be atomic")
        XCTAssertTrue(defaults.values.keys.count == 1 && defaults.values["barista.activeWidgets"] == nil, "portfolio settings must remain isolated")
        let evidence: [String: Any] = ["id": "e1", "text": "Revenue grew", "source": "10-K", "url": "https://www.sec.gov/edgar/", "kind": "supports", "createdAt": 1_790_000_000]
        let question: [String: Any] = ["id": "q1", "text": "Are margins sustainable?", "done": false, "createdAt": 1_790_000_000]
        let scenario: [String: Any] = ["growth": 10, "multiple": 20]
        var note: [String: Any] = ["thesis": "Original", "risks": "Risk", "catalysts": "Question", "stage": "monitoring", "conviction": "high", "reviewDate": "2026-10-01", "evidence": [evidence], "questions": [question], "valuation": ["eps": 5, "years": 3, "basis": "Manual", "bear": scenario, "base": scenario, "bull": scenario]]
        func saveNote(_ note: [String: Any]) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: ["symbol": "AAPL", "note": note]) else { fatalError("Invalid fixture") }
            return ResearchWorkspaceStore.save(data, defaults: defaults)
        }
        XCTAssertTrue(saveNote(note), "structured research must persist")
        let structured = (ResearchWorkspaceStore.load(defaults: defaults)["notes"] as! [String: [String: Any]])["AAPL"]!
        XCTAssertTrue((structured["evidence"] as! [[String: Any]])[0]["kind"] as? String == "supports", "evidence must round-trip")
        XCTAssertTrue((structured["questions"] as! [[String: Any]])[0]["done"] as? Bool == false, "questions must retain completion")
        XCTAssertTrue((structured["valuation"] as! [String: Any])["eps"] as? Int == 5, "valuation must round-trip")
        XCTAssertTrue(ResearchWorkspaceStore.save(body, defaults: defaults), "old clients must remain compatible")
        let migrated = (ResearchWorkspaceStore.load(defaults: defaults)["notes"] as! [String: [String: Any]])["AAPL"]!
        XCTAssertTrue(migrated["stage"] as? String == "monitoring" && migrated["evidence"] != nil, "old clients must not erase newer research")
        let stable = defaults.values
        for (field, value) in [("stage", "invalid"), ("conviction", "certain"), ("reviewDate", "2026-02-30")] {
            var bad = note; bad[field] = value
            XCTAssertTrue(!saveNote(bad), "invalid research metadata must fail")
        }
        var badEvidence = evidence; badEvidence["url"] = "javascript:alert(1)"; note["evidence"] = [badEvidence]
        XCTAssertTrue(!saveNote(note), "unsafe source links must fail")
        note["evidence"] = [evidence, evidence]
        XCTAssertTrue(!saveNote(note), "duplicate evidence identifiers must fail")
        note["evidence"] = [evidence]; var badQuestion = question; badQuestion["done"] = 1; note["questions"] = [badQuestion]
        XCTAssertTrue(!saveNote(note), "numeric question booleans must fail")
        note["questions"] = [question]; var badValuation = structured["valuation"] as! [String: Any]; badValuation["eps"] = true; note["valuation"] = badValuation
        XCTAssertTrue(!saveNote(note), "boolean EPS must fail")
        XCTAssertTrue((stable as NSDictionary).isEqual(to: defaults.values), "invalid structured updates must leave saved research intact")
        XCTAssertTrue(ResearchWorkspaceRequest.validResearchSymbol("BRK-B") && ResearchWorkspaceRequest.validResearchSymbol("^GSPC"), "market ticker punctuation must pass")
        XCTAssertTrue(!ResearchWorkspaceRequest.validResearchSymbol("AAPL/../../") && !ResearchWorkspaceRequest.validResearchSymbol("https://evil.example"), "non-ticker paths must fail")
        XCTAssertTrue(ResearchWorkspaceStore.save(Data("{\"preferences\":{\"researchSymbols\":[\"COST\",\"BRK-B\"]}}".utf8), defaults: defaults), "independent universe must persist")
        XCTAssertTrue(!ResearchWorkspaceStore.save(Data("{\"preferences\":{\"researchSymbols\":[\"COST\",\"COST\"]}}".utf8), defaults: defaults), "duplicate universe symbols must fail")
    }
}
