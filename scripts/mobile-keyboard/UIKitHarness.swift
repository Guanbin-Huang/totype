import UIKit

@main
@MainActor
final class HarnessDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var lines: [String] = []
    var count = 0
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        let keyboard = KeyboardTypingView(frame: CGRect(x: 0, y: 0, width: 320, height: 250))
        controller.view.addSubview(keyboard)
        keyboard.layoutIfNeeded()
        var output = ""
        var deletes = 0
        var globes = 0
        keyboard.onInsertText = { output += $0 }
        keyboard.onDeleteBackward = { deletes += 1 }
        keyboard.onNextKeyboard = { globes += 1 }
        func find(_ view: UIView, _ id: String) -> UIButton? {
            if let button = view as? UIButton, button.accessibilityIdentifier == "typingKey_" + id { return button }
            for subview in view.subviews { if let button = find(subview, id) { return button } }
            return nil
        }
        func press(_ id: String) {
            guard let button = find(keyboard, id) else { fatalError("Missing key \(id)") }
            button.sendActions(for: .touchUpInside)
        }
        func type(_ text: String) { for character in text { press(String(character)) } }
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError(label + " output=" + output) }
            count += 1; lines.append("PASS " + label)
        }
        type("nihao"); check(keyboard.hasComposition && output.isEmpty, "pinyin remains local before selection")
        press("candidate_你好"); check(output == "你好" && !keyboard.hasComposition, "candidate button inserts 你好")
        type("nihaozhongguo"); press("candidate_你好"); check(keyboard.hasComposition && output == "你好你好", "prefix candidate leaves composition")
        keyboard.commitComposition(); check(output == "你好你好中国" && !keyboard.hasComposition, "dictation flush commits residual 中国")
        type("ni"); press("⌫"); press("⌫"); check(!keyboard.hasComposition && deletes == 0, "delete composition does not delete document")
        press("⌫"); check(deletes == 1, "empty composition forwards document delete")
        press("language"); type("hello"); check(output.hasSuffix("hello"), "English letters insert immediately")
        press("⇧"); press("a"); press("b"); check(output.hasSuffix("helloAb"), "shift uppercases one English letter")
        press("page"); type("123"); press("。"); check(output.hasSuffix("Ab123。"), "number and punctuation page inserts exact keys")
        press("#+="); press("["); press("="); check(output.hasSuffix("。[="), "symbol page inserts brackets and equals")
        press("page"); press("space"); press("return"); check(output.hasSuffix("[= \n"), "space and return forward exact text")
        press("globe"); check(globes == 1, "globe forwards next-keyboard callback")
        press("language"); type("nihao"); press("return"); check(output.hasSuffix("你好\n") && !keyboard.hasComposition, "return flushes Chinese composition then newline")
        let beforeDiscard = output
        type("nihao"); keyboard.discardComposition()
        check(!keyboard.hasComposition && output == beforeDiscard && find(keyboard, "candidate_你好") == nil, "document change discards composition and candidates without insertion")
        check(keyboard.intrinsicContentSize.height <= 260, "keyboard height <= 260")
        lines.append("UI_TESTS=\(count) PASS=\(count)")
        let document = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try! lines.joined(separator: "\n").write(to: document.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
        return true
    }
}
