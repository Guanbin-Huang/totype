import XCTest
@testable import VerbatimCore

final class DoubaoHotwordContextTests: XCTestCase {
    func testOfficialJSONAndConservativeByteBudget() throws {
        let selected = DoubaoHotwordContext.select(["Codex", "豆包", "opentypeless", "Kubernetes", "第四个长技术词"])
        let context = try XCTUnwrap(selected.context)
        XCTAssertLessThanOrEqual(context.utf8.count, DoubaoHotwordContext.maximumContextUTF8Bytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: [[String: String]]])
        XCTAssertEqual(object["hotwords"]?.compactMap { $0["word"] }, selected.terms)
        XCTAssertGreaterThan(selected.droppedCount, 0)
        XCTAssertEqual(DoubaoHotwordContext.select(selected.terms), .init(terms: selected.terms, context: selected.context, droppedCount: 0))
    }

    func testEmptyDuplicateOversizedAndEscaping() throws {
        XCTAssertNil(DoubaoHotwordContext.select([]).context)
        let selected = DoubaoHotwordContext.select([String(repeating: "词", count: 100), " ", "Code\"x\\\n😀", " codex ", "CODEX"])
        XCTAssertEqual(selected.terms, ["Code\"x\\\n😀", "codex"])
        XCTAssertEqual(selected.droppedCount, 3)
        let object = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(selected.context).utf8)) as! [String: [[String: String]]]
        XCTAssertEqual(object["hotwords"]?.compactMap { $0["word"] }, selected.terms)
    }
}
