import UIKit

@MainActor
final class KeyboardTypingView: UIView {
    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onNextKeyboard: (() -> Void)?
    var hasComposition: Bool { composition.hasComposition }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 250) }

    private enum Mode { case chinese, english, numbers, symbols }
    private var mode: Mode = .chinese
    private var letterMode: Mode = .chinese
    private var shifted = false
    private var composition = PinyinComposition()
    private var candidates: [PinyinCandidate] = []
    private var lexicon: PinyinLexicon?
    private var lexiconError: String?
    private let rows = UIStackView()
    private let spellingLabel = UILabel()
    private let candidateRow = UIStackView()
    private var deleteTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        if let url = Bundle.main.url(forResource: "pinyin", withExtension: "sqlite3") ?? Bundle.main.url(forResource: "pinyin", withExtension: "sqlite3", subdirectory: "Resources") {
            do { lexicon = try PinyinLexicon(url: url) }
            catch { lexiconError = "词库读取失败：\(error.localizedDescription)" }
        } else { lexiconError = "拼音词库资源缺失" }
        makeLayout()
        rebuildKeys()
        refreshCandidates()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Flush all words, including a residual spelling after a prefix candidate, before dictation.
    func commitComposition() {
        while composition.hasComposition {
            onInsertText?(composition.commit(candidates.first))
            refreshCandidates()
        }
    }

    /// Document identity changed: never carry uncommitted text into another input field.
    func discardComposition() {
        _ = composition.takeRaw()
        refreshCandidates()
    }

    private func makeLayout() {
        spellingLabel.font = .systemFont(ofSize: 13)
        spellingLabel.textColor = .secondaryLabel
        spellingLabel.numberOfLines = 1
        spellingLabel.accessibilityIdentifier = "pinyinComposition"
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        candidateRow.axis = .horizontal
        candidateRow.spacing = 8
        candidateRow.alignment = .fill
        candidateRow.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(candidateRow)
        NSLayoutConstraint.activate([
            candidateRow.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            candidateRow.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            candidateRow.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            candidateRow.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            candidateRow.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        rows.axis = .vertical
        rows.distribution = .fillEqually
        rows.spacing = 5
        let layout = UIStackView(arrangedSubviews: [spellingLabel, scroll, rows])
        layout.axis = .vertical
        layout.spacing = 3
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            layout.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            spellingLabel.heightAnchor.constraint(equalToConstant: 17),
            scroll.heightAnchor.constraint(equalToConstant: 33)
        ])
    }

    private func rebuildKeys() {
        stopRepeatingDelete()
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        let lines: [[String]]
        switch mode {
        case .chinese, .english:
            lines = [Array("qwertyuiop").map(String.init), Array("asdfghjkl").map(String.init), ["⇧"] + Array("zxcvbnm").map(String.init) + ["'", "⌫"]]
        case .numbers:
            lines = [Array("1234567890").map(String.init), ["-", "/", ":", ";", "(", ")", "¥", "&", "@", "\""], ["#+=", "。", "，", "？", "！", ".", ",", "⌫"]]
        case .symbols:
            lines = [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], ["_", "\\", "|", "~", "<", ">", "$", "€", "£", "·"], ["123", "…", "、", "：", "；", "？", "！", "⌫"]]
        }
        for line in lines {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 4
            for key in line {
                let title = (mode == .english && shifted && key.count == 1) ? key.uppercased() : key
                let button = keyButton(title, identifier: key) { [weak self] in self?.press(key) }
                if key == "⌫" {
                    button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(repeatDelete(_:))))
                    button.accessibilityLabel = "删除"
                }
                row.addArrangedSubview(button)
            }
            rows.addArrangedSubview(row)
        }
        let bottom = UIStackView()
        bottom.axis = .horizontal
        bottom.spacing = 4
        let languageTitle = letterMode == .chinese ? "中/EN" : "EN/中"
        let pageTitle = (mode == .numbers || mode == .symbols) ? "ABC" : "123"
        for (title, action) in [("🌐", "globe"), (languageTitle, "language"), (pageTitle, "page"), (letterMode == .chinese ? "空格 / 选词" : "space", "space"), ("换行", "return")] {
            let button = keyButton(title, identifier: action) { [weak self] in self?.press(action) }
            bottom.addArrangedSubview(button)
            if action != "space" { button.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: action == "language" ? 0.16 : 0.13).isActive = true }
        }
        rows.addArrangedSubview(bottom)
    }

    private func keyButton(_ title: String, identifier: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: identifier == "space" ? 14 : 19)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.6
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 5
        button.accessibilityIdentifier = "typingKey_\(identifier)"
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func press(_ key: String) {
        switch key {
        case "⌫":
            if hasComposition { composition.deleteBackward(); refreshCandidates() }
            else { onDeleteBackward?() }
        case "globe": commitComposition(); onNextKeyboard?()
        case "language":
            commitComposition()
            letterMode = letterMode == .chinese ? .english : .chinese
            mode = letterMode; shifted = false; rebuildKeys(); refreshCandidates()
        case "page":
            commitComposition()
            mode = (mode == .numbers || mode == .symbols) ? letterMode : .numbers
            rebuildKeys(); refreshCandidates()
        case "#+=": mode = .symbols; rebuildKeys()
        case "123": mode = .numbers; rebuildKeys()
        case "⇧":
            if mode == .chinese { commitComposition(); letterMode = .english; mode = .english; shifted = true }
            else { shifted.toggle() }
            rebuildKeys(); refreshCandidates()
        case "space":
            if hasComposition { onInsertText?(composition.commit(candidates.first)); refreshCandidates() }
            else { onInsertText?(" ") }
        case "return": commitComposition(); onInsertText?("\n")
        default:
            if mode == .chinese && (key == "'" || (key.count == 1 && key.utf8.allSatisfy({ (97...122).contains($0) }))) {
                composition.append(key); refreshCandidates()
            } else {
                commitComposition()
                onInsertText?(mode == .english && shifted ? key.uppercased() : key)
                if mode == .english && shifted { shifted = false; rebuildKeys() }
            }
        }
    }

    private func refreshCandidates() {
        candidates = []
        if let lexicon {
            do { candidates = try lexicon.candidates(for: composition.spelling); lexiconError = nil }
            catch { lexiconError = "词库查询失败：\(error.localizedDescription)" }
        }
        spellingLabel.text = hasComposition ? composition.spelling : (lexiconError ?? (letterMode == .chinese ? "拼音 · 本地输入" : "English"))
        candidateRow.arrangedSubviews.forEach { candidateRow.removeArrangedSubview($0); $0.removeFromSuperview() }
        for candidate in candidates {
            let button = keyButton(candidate.text, identifier: "candidate_\(candidate.text)") { [weak self] in
                guard let self else { return }
                self.onInsertText?(self.composition.select(candidate))
                self.refreshCandidates()
            }
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: button.intrinsicContentSize.width + 20).isActive = true
            candidateRow.addArrangedSubview(button)
        }
        // An explicit spelling candidate supports names, URLs and uncommon pinyin.
        if hasComposition {
            let button = keyButton(composition.spelling, identifier: "rawSpelling") { [weak self] in
                guard let self else { return }
                self.onInsertText?(self.composition.takeRaw()); self.refreshCandidates()
            }
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: button.intrinsicContentSize.width + 20).isActive = true
            candidateRow.addArrangedSubview(button)
        }
        spellingLabel.accessibilityValue = composition.spelling
    }

    @objc private func repeatDelete(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            press("⌫")
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.press("⌫") }
            }
        case .ended, .cancelled, .failed: stopRepeatingDelete()
        default: break
        }
    }

    private func stopRepeatingDelete() { deleteTimer?.invalidate(); deleteTimer = nil }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { stopRepeatingDelete() } }
}
