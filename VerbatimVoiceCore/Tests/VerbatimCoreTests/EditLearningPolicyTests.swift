import XCTest
@testable import VerbatimCore

final class EditLearningPolicyTests: XCTestCase {
    func testWordCorrectionWithAddedProse() {
        XCTAssertEqual(EditLearningPolicy.classify(
            original: "我希望 Opentype 可以在听写之后观察修改，让词库适应我的表达。",
            edited: "前缀我希望 opentypeless 可以在听写之后观察修改，让词库适应我的表达。更加个性化"
        ), .correction(original: "Opentype", corrected: "opentypeless"))
    }

    func testPureAdditionsEverywhere() {
        for edited in ["前缀原文", "原文后缀", "原新增文", "前原中间文后", "😀原✨文👨‍👩‍👧‍👦"] {
            XCTAssertEqual(EditLearningPolicy.classify(original: "原文", edited: edited), .ignore)
        }
        XCTAssertEqual(EditLearningPolicy.classify(original: "Opentype", edited: "Opentypeless"), .ignore)
    }

    func testUnicodeAndUndo() {
        XCTAssertEqual(EditLearningPolicy.classify(original: "😀Opentype👨‍👩‍👧‍👦", edited: "前😀opentypeless👨‍👩‍👧‍👦后"), .correction(original: "Opentype", corrected: "opentypeless"))
        XCTAssertEqual(EditLearningPolicy.classify(original: "😀原文", edited: "😀原文"), .ignore)
    }

    func testRepeatedWordRequiresConfirmation() {
        XCTAssertEqual(EditLearningPolicy.classify(original: "Opentype Opentype", edited: "opentypeless Opentype"), .needsConfirmation(original: "Opentype", corrected: "opentypeless"))
    }

    func testDeletionAndSemanticReplacementRequireConfirmation() {
        XCTAssertEqual(EditLearningPolicy.classify(original: "允许", edited: ""), .needsConfirmation(original: "允许", corrected: ""))
        XCTAssertEqual(EditLearningPolicy.classify(original: "enable", edited: "disable"), .needsConfirmation(original: "enable", corrected: "disable"))
        XCTAssertEqual(EditLearningPolicy.classify(original: "不要发送", edited: "要发送"), .needsConfirmation(original: "不", corrected: ""))
        XCTAssertEqual(EditLearningPolicy.classify(original: "费用100元", edited: "费用200元"), .needsConfirmation(original: "100", corrected: "200"))
    }

    func testAmbiguousAnchorsAndRepeatedChineseTerm() {
        if case .correction = EditLearningPolicy.classify(original: "a b a", edited: "b a b") {
            XCTFail("competing anchors must not be learned")
        }
        XCTAssertEqual(EditLearningPolicy.classify(original: "库伯和库伯", edited: "Kubernetes和库伯", knownTerms: ["Kubernetes"]), .needsConfirmation(original: "库伯", corrected: "Kubernetes"))
    }

    func testUnknownPrefixSimilarityRequiresConfirmation() {
        XCTAssertEqual(EditLearningPolicy.classify(original: "security", edited: "securities"), .needsConfirmation(original: "security", corrected: "securities"))
    }

    func testCaseAndFormatIdentity() {
        XCTAssertEqual(EditLearningPolicy.classify(original: "security", edited: "Security"), .correction(original: "security", corrected: "Security"))
        XCTAssertEqual(EditLearningPolicy.classify(original: "hello-world", edited: "helloworld"), .correction(original: "hello-world", corrected: "helloworld"))
    }

    func testDifferentKnownTermsRequireConfirmation() {
        XCTAssertEqual(EditLearningPolicy.classify(original: "Claude", edited: "Codex"), .needsConfirmation(original: "Claude", corrected: "Codex"))
        XCTAssertEqual(EditLearningPolicy.classify(original: "security", edited: "securities", knownTerms: ["security", "securities"]), .needsConfirmation(original: "security", corrected: "securities"))
        XCTAssertEqual(EditLearningPolicy.classify(original: "Opentype", edited: "opentypeless", knownTerms: ["Opentype"]), .needsConfirmation(original: "Opentype", corrected: "opentypeless"))
    }

    func testKnownTargetDoesNotOverrideSemanticGuards() {
        XCTAssertEqual(EditLearningPolicy.classify(original: "allow", edited: "deny", knownTerms: ["deny"]), .needsConfirmation(original: "allow", corrected: "deny"))
        XCTAssertEqual(EditLearningPolicy.classify(original: "version1", edited: "version2", knownTerms: ["version2"]), .needsConfirmation(original: "version1", corrected: "version2"))
        XCTAssertEqual(EditLearningPolicy.classify(original: "发送", edited: "不发送", knownTerms: ["不发送"]), .ignore)
        XCTAssertEqual(EditLearningPolicy.classify(original: "没有", edited: "不行", knownTerms: ["不行"]), .needsConfirmation(original: "没有", corrected: "不行"))
    }

    func testKnownTermAndBoundedCost() {
        XCTAssertEqual(EditLearningPolicy.classify(original: "库伯", edited: "Kubernetes", knownTerms: ["Kubernetes"]), .correction(original: "库伯", corrected: "Kubernetes"))
        XCTAssertEqual(EditLearningPolicy.classify(original: String(repeating: "甲", count: 10_000), edited: String(repeating: "乙", count: 10_000)), .ignore)
        XCTAssertEqual(EditLearningPolicy.observationDuration, 10)
    }
    func testObservationStabilityUndoAndDeadline() {
        var state = EditLearningObservationState(original: "Opentype")
        XCTAssertEqual(state.observe(edited: "opent", elapsed: 0.2), .ignore)
        XCTAssertEqual(state.observe(edited: "opentypeless", elapsed: 0.7), .ignore)
        XCTAssertEqual(state.observe(edited: "opentypeless", elapsed: 1.79), .ignore)
        XCTAssertEqual(state.observe(edited: "opentypeless", elapsed: 1.81), .correction(original: "Opentype", corrected: "opentypeless"))
        XCTAssertEqual(state.observe(edited: "opentypeless", elapsed: 3), .ignore)
        XCTAssertEqual(state.observe(edited: "Opentype", elapsed: 4), .ignore)
        XCTAssertEqual(state.observe(edited: "opentypeless", elapsed: 5), .ignore)
        XCTAssertEqual(state.observe(edited: "opentypeless", elapsed: 6.2), .ignore)
        var late = EditLearningObservationState(original: "Opentype", duration: 45)
        XCTAssertEqual(late.observe(edited: "opentypeless", elapsed: 9), .ignore)
        XCTAssertEqual(late.observe(edited: "opentypeless", elapsed: 10.2), .ignore)
        var short = EditLearningObservationState(original: "Opentype", duration: 1)
        XCTAssertEqual(short.observe(edited: "opentypeless", elapsed: 0), .ignore)
        XCTAssertEqual(short.observe(edited: "opentypeless", elapsed: 1.2), .ignore)
    }

    func testPerformanceSample() {
        let started = ContinuousClock.now
        for _ in 0..<100 {
            _ = EditLearningPolicy.classify(original: "我希望 Opentype 观察这次听写后的修改。", edited: "前缀我希望 opentypeless 观察这次听写后的修改。更加个性化")
        }
        print("EditLearningPolicy 100 local samples: \(started.duration(to: .now))")
    }

}
