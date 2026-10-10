import Foundation
let started = Date()
let lexicon = try PinyinLexicon(url: URL(fileURLWithPath: CommandLine.arguments[1]))
var tests = 0
func check(_ condition: Bool, _ name: String) {
    precondition(condition, name)
    tests += 1
    print("PASS \(name)")
}
func top(_ input: String) throws -> PinyinCandidate { try lexicon.candidates(for: input).first! }
check(try top("nihao").text == "你好", "nihao -> 你好")
check(try top("zhongguo").text == "中国", "zhongguo -> 中国")
var composition = PinyinComposition()
for character in "nihaozhongguo" { composition.append(String(character)) }
let prefix = try top(composition.spelling)
check(prefix.text == "你好" && prefix.consumedLetters == 5, "continuous words -> longest 你好 prefix")
check(composition.select(prefix) == "你好" && composition.spelling == "zhongguo", "prefix selection preserves zhongguo")
check(composition.commit(try top(composition.spelling)) == "中国" && !composition.hasComposition, "residual -> 中国; composition empty")
for character in "xi'an" { composition.append(String(character)) }
check(try lexicon.candidates(for: composition.spelling).contains { $0.text == "西安" }, "apostrophe xi'an -> 西安")
check(try !lexicon.candidates(for: composition.spelling).contains { $0.text == "先" }, "apostrophe excludes xian single syllable")
composition.deleteBackward()
check(composition.spelling == "xi'a", "delete affects composition only")
check(composition.takeRaw() == "xi'a" && !composition.hasComposition, "raw spelling commit resets composition")
composition.append("'")
check(!composition.hasComposition, "leading separator ignored")
for character in "ni'hao'zhong'guo" { composition.append(String(character)) }
check(composition.select(try top(composition.spelling)) == "你好" && composition.spelling == "zhong'guo", "apostrophe prefix consumes boundary")
_ = composition.takeRaw()
for character in "vvvv" { composition.append(String(character)) }
check(composition.commit(nil) == "vvvv" && !composition.hasComposition, "unknown spelling commits raw")
check(try !lexicon.candidates(for: "n").isEmpty, "partial n has dictionary candidates")
check(try lexicon.candidates(for: String(repeating: "a", count: 65)).isEmpty, "input boundary caps 65-letter query")
for _ in 0..<100 { _ = try lexicon.candidates(for: "nihaozhongguo") }
print(String(format: "TESTS=%d PASS=%d elapsed_seconds=%.3f", tests, tests, Date().timeIntervalSince(started)))
