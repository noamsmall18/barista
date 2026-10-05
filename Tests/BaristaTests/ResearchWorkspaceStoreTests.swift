import XCTest
@testable import Barista

final class ResearchWorkspaceStoreTests: XCTestCase {
    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "barista.tests.research.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testNotesAndPreferencesPersistWithoutReplacingOtherSymbols() throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        for symbol in ["AAPL", "MSFT"] {
            let update: [String: Any] = ["symbol": symbol, "note": ["thesis": "Evidence \(symbol)", "risks": "", "catalysts": ""]]
            XCTAssertTrue(ResearchWorkspaceStore.save(try JSONSerialization.data(withJSONObject: update), defaults: defaults))
        }
        XCTAssertTrue(ResearchWorkspaceStore.save(Data("{\"preferences\":{\"compact\":true,\"portfolioRange\":\"1M\"}}".utf8), defaults: defaults))
        let stored = ResearchWorkspaceStore.load(defaults: defaults)
        let notes = try XCTUnwrap(stored["notes"] as? [String: [String: Any]])
        XCTAssertEqual(notes["AAPL"]?["thesis"] as? String, "Evidence AAPL")
        XCTAssertEqual(notes["MSFT"]?["thesis"] as? String, "Evidence MSFT")
        XCTAssertEqual((stored["preferences"] as? [String: Any])?["portfolioRange"] as? String, "1M")
        XCTAssertNil(defaults.object(forKey: "barista.activeWidgets"), "research saves must not write portfolio settings")
    }

    func testInvalidUpdateIsRejectedAtomically() throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let invalid: [String: Any] = ["symbol": "AAPL", "note": ["thesis": "Do not save", "risks": "", "catalysts": ""], "preferences": ["portfolioRange": "unknown"]]
        XCTAssertFalse(ResearchWorkspaceStore.save(try JSONSerialization.data(withJSONObject: invalid), defaults: defaults))
        XCTAssertTrue((ResearchWorkspaceStore.load(defaults: defaults)["notes"] as? [String: Any])?.isEmpty == true)
        for text in ["{\"portfolios\":[]}", "{\"preferences\":{\"compact\":1}}", "{\"symbol\":\"AAPL\",\"note\":{\"thesis\":\"incomplete\"}}"] {
            XCTAssertFalse(ResearchWorkspaceStore.save(Data(text.utf8), defaults: defaults))
        }
    }

    func testStructuredResearchAndLegacyWritesPreserveEvidence() throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let evidence: [String: Any] = ["id": "receipt", "text": "Reported cash flow", "source": "10-K", "url": "https://www.sec.gov/edgar/", "kind": "supports", "createdAt": 1_790_000_000]
        let question: [String: Any] = ["id": "question", "text": "What changed?", "done": false, "createdAt": 1_790_000_000]
        let note: [String: Any] = ["thesis": "Case", "risks": "Risk", "catalysts": "Date", "stage": "researching", "conviction": "medium", "reviewDate": "2026-10-01", "evidence": [evidence], "questions": [question]]
        XCTAssertTrue(ResearchWorkspaceStore.save(try JSONSerialization.data(withJSONObject: ["symbol": "AAPL", "note": note]), defaults: defaults))
        let legacy = ["symbol": "AAPL", "note": ["thesis": "Revised case", "risks": "Risk", "catalysts": "Date"]] as [String: Any]
        XCTAssertTrue(ResearchWorkspaceStore.save(try JSONSerialization.data(withJSONObject: legacy), defaults: defaults))
        let notes = try XCTUnwrap(ResearchWorkspaceStore.load(defaults: defaults)["notes"] as? [String: [String: Any]])
        XCTAssertEqual(notes["AAPL"]?["stage"] as? String, "researching")
        XCTAssertEqual(notes["AAPL"]?["thesis"] as? String, "Revised case")
        let savedEvidence = try XCTUnwrap(notes["AAPL"]?["evidence"] as? [[String: Any]])
        XCTAssertEqual(savedEvidence.first?["text"] as? String, "Reported cash flow")
    }

    func testStructuredResearchRejectsInvalidDateSourceAndBoolean() throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var note: [String: Any] = ["thesis": "", "risks": "", "catalysts": "", "reviewDate": "2026-02-30"]
        func save() throws -> Bool {
            ResearchWorkspaceStore.save(try JSONSerialization.data(withJSONObject: ["symbol": "AAPL", "note": note]), defaults: defaults)
        }
        XCTAssertFalse(try save())
        note.removeValue(forKey: "reviewDate")
        note["evidence"] = [["id": "receipt", "text": "Bad URL", "source": "", "url": "javascript:alert(1)", "kind": "supports", "createdAt": 1_790_000_000]]
        XCTAssertFalse(try save())
        note.removeValue(forKey: "evidence")
        note["questions"] = [["id": "question", "text": "Bad boolean", "done": 1, "createdAt": 1_790_000_000]]
        XCTAssertFalse(try save())
        XCTAssertTrue((ResearchWorkspaceStore.load(defaults: defaults)["notes"] as? [String: Any])?.isEmpty == true)
    }
}
