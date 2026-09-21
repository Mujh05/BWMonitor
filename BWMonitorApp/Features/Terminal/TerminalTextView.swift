import AppKit
import SwiftUI

/// Shows a terminal session and sends keystrokes to it.
struct TerminalOutput: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> TerminalScrollView {
        let scrollView = TerminalScrollView()
        scrollView.terminal.attach(session)
        return scrollView
    }

    func updateNSView(_ scrollView: TerminalScrollView, context: Context) {
        if scrollView.terminal.session !== session {
            scrollView.terminal.attach(session)
        }
    }

    /// Takes whatever space is offered. Otherwise SwiftUI sizes the view to
    /// the full text height and pushes the window's content out of place.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 480, height: 320))
    }
}

final class TerminalScrollView: NSScrollView {
    let terminal = TerminalTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        borderType = .noBorder
        terminal.autoresizingMask = [.width]
        documentView = terminal
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func tile() {
        let wasAtBottom = terminal.isScrolledToBottom
        super.tile()
        terminal.reportSize(in: contentSize)
        if wasAtBottom { terminal.scrollToBottom() }
    }
}

/// A read-only text view that renders a ``TerminalBuffer`` and forwards
/// typing, including input methods, to the SSH session.
final class TerminalTextView: NSTextView {
    private(set) weak var session: TerminalSession?

    private let terminalFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private lazy var boldFont = NSFontManager.shared.convert(terminalFont, toHaveTrait: .boldFontMask)
    private lazy var cellSize: NSSize = {
        let width = ("W" as NSString).size(withAttributes: [.font: terminalFont]).width
        return NSSize(width: width, height: ceil(terminalFont.ascender - terminalFont.descender + terminalFont.leading))
    }()
    private var lineLengths: [Int] = []
    private var attributeCache: [TerminalStyle: [NSAttributedString.Key: Any]] = [:]
    private var markedDisplayRange: NSRange?
    private lazy var inputContextForTerminal = NSTextInputContext(client: self)

    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = false
        allowsUndo = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textContainerInset = NSSize(width: 8, height: 6)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        setAccessibilityLabel(NSLocalizedString("Terminal", comment: "Accessibility label"))
    }

    func attach(_ session: TerminalSession) {
        self.session?.onUpdate = nil
        self.session = session
        session.onUpdate = { [weak self] update in self?.apply(update) }
        attributeCache = [:]
        markedDisplayRange = nil
        textStorage?.setAttributedString(NSAttributedString())
        lineLengths = []
        apply(TerminalUpdate(removedLines: 0, firstChangedLine: 0))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            if let scrollView = self.enclosingScrollView as? TerminalScrollView {
                self.reportSize(in: scrollView.contentSize)
            }
        }
    }

    func reportSize(in contentSize: NSSize) {
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        let columns = Int((contentSize.width - textContainerInset.width * 2) / cellSize.width)
        let rows = Int((contentSize.height - textContainerInset.height * 2) / cellSize.height)
        session?.resize(columns: columns, rows: rows)
    }

    // MARK: Drawing

    private func apply(_ update: TerminalUpdate) {
        guard let storage = textStorage, let session else { return }
        let buffer = session.buffer
        let wasAtBottom = isScrolledToBottom
        let marked = removeMarkedDisplay()

        storage.beginEditing()
        if update.removedLines > 0 {
            let count = min(update.removedLines, lineLengths.count)
            let length = lineLengths.prefix(count).reduce(0, +) + count
            storage.deleteCharacters(in: NSRange(location: 0, length: min(length, storage.length)))
            lineLengths.removeFirst(count)
        }
        if let changed = update.firstChangedLine {
            let first = min(changed, lineLengths.count)
            let offset = lineLengths.prefix(first).reduce(0, +) + first
            let replacement = NSMutableAttributedString()
            var lengths: [Int] = []
            for index in first..<buffer.lines.count {
                if index > first || first > 0 {
                    replacement.append(NSAttributedString(string: "\n", attributes: attributes(for: TerminalStyle())))
                }
                let line = render(line: index, of: buffer)
                lengths.append(line.length)
                replacement.append(line)
            }
            let start = min(first == 0 ? 0 : offset - 1, storage.length)
            storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: replacement)
            lineLengths = Array(lineLengths.prefix(first)) + lengths
        }
        storage.endEditing()

        if let marked { showMarkedText(marked) }
        if wasAtBottom { scrollToBottom() }
    }

    /// Scrolls this terminal only. `scrollToEndOfDocument` would also
    /// scroll every enclosing scroll view and shift the window's content.
    func scrollToBottom() {
        guard let scrollView = enclosingScrollView, let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let clipView = scrollView.contentView
        clipView.scroll(to: NSPoint(x: 0, y: max(frame.height - clipView.bounds.height, 0)))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func render(line index: Int, of buffer: TerminalBuffer) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in buffer.runs(forLine: index) {
            result.append(NSAttributedString(string: run.text, attributes: attributes(for: run.style)))
        }
        // Show the cursor.
        if index == buffer.row, session?.isConnected == true, !buffer.alternateScreen {
            let column = min(buffer.cursor, buffer.columns - 1)
            let cells = buffer.lines[index]
            let visibleColumns = cells.count
            if column >= visibleColumns {
                result.append(NSAttributedString(
                    string: String(repeating: " ", count: column - visibleColumns + 1),
                    attributes: attributes(for: TerminalStyle())
                ))
            }
            let prefix = cells.prefix(min(column, visibleColumns)).filter { !$0.isContinuation }.map(\.text).joined()
            let location = (prefix as NSString).length + max(column - visibleColumns, 0)
            if location < result.length {
                let range = (result.string as NSString).rangeOfComposedCharacterSequence(at: location)
                result.addAttributes(
                    [.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.55)],
                    range: range
                )
            }
        }
        return result
    }

    private func attributes(for style: TerminalStyle) -> [NSAttributedString.Key: Any] {
        if let cached = attributeCache[style] { return cached }
        var foreground = style.foreground.map(TerminalPalette.color) ?? NSColor.textColor
        var background = style.background.map(TerminalPalette.color)
        if style.inverse {
            let swapped = background ?? NSColor.textBackgroundColor
            background = foreground
            foreground = swapped
        }
        if style.dim { foreground = foreground.withAlphaComponent(0.6) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.bold ? boldFont : terminalFont,
            .foregroundColor: foreground,
            .paragraphStyle: paragraph
        ]
        if let background { attributes[.backgroundColor] = background }
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.italic { attributes[.obliqueness] = 0.15 }
        attributeCache[style] = attributes
        return attributes
    }

    var isScrolledToBottom: Bool {
        guard let scrollView = enclosingScrollView else { return true }
        return scrollView.documentVisibleRect.maxY >= bounds.height - cellSize.height * 2
    }

    /// Character index of the cursor in the text storage.
    private var cursorIndex: Int {
        guard let buffer = session?.buffer, let storage = textStorage else { return textStorage?.length ?? 0 }
        let row = min(buffer.row, lineLengths.count - 1)
        guard row >= 0 else { return 0 }
        let lineStart = lineLengths.prefix(row).reduce(0, +) + row
        let prefix = buffer.lines[row].prefix(buffer.cursor).filter { !$0.isContinuation }.map(\.text).joined()
        return min(lineStart + (prefix as NSString).length, storage.length)
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    override var inputContext: NSTextInputContext? { inputContextForTerminal }

    override func keyDown(with event: NSEvent) {
        guard let session, session.isConnected else {
            super.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if !hasMarkedText(), let sequence = Self.sequence(for: event, applicationCursor: session.buffer.applicationCursorKeys) {
            session.send(sequence)
            return
        }
        if modifiers.contains(.control), !hasMarkedText(), let characters = event.characters, !characters.isEmpty {
            session.send(characters == " " ? "\u{0}" : characters)
            return
        }
        // Plain typing and input methods (such as Pinyin) arrive through
        // insertText(_:replacementRange:).
        if inputContext?.handleEvent(event) != true, let characters = event.characters {
            session.send(characters)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "k", window?.firstResponder === self {
            session?.clearScrollback()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func sequence(for event: NSEvent, applicationCursor: Bool) -> String? {
        let option = event.modifierFlags.contains(.option)
        let shift = event.modifierFlags.contains(.shift)
        let cursorPrefix = applicationCursor ? "\u{1B}O" : "\u{1B}["
        switch event.keyCode {
        case 36, 76: return "\r"
        case 48: return shift ? "\u{1B}[Z" : "\t"
        case 51: return option ? "\u{1B}\u{7F}" : "\u{7F}"
        case 117: return "\u{1B}[3~"
        case 53: return "\u{1B}"
        case 123: return option ? "\u{1B}b" : cursorPrefix + "D"
        case 124: return option ? "\u{1B}f" : cursorPrefix + "C"
        case 125: return cursorPrefix + "B"
        case 126: return cursorPrefix + "A"
        case 115: return cursorPrefix + "H"
        case 119: return cursorPrefix + "F"
        case 116: return "\u{1B}[5~"
        case 121: return "\u{1B}[6~"
        case 122: return "\u{1B}OP"
        case 120: return "\u{1B}OQ"
        case 99: return "\u{1B}OR"
        case 118: return "\u{1B}OS"
        case 96: return "\u{1B}[15~"
        case 97: return "\u{1B}[17~"
        case 98: return "\u{1B}[18~"
        case 100: return "\u{1B}[19~"
        case 101: return "\u{1B}[20~"
        case 109: return "\u{1B}[21~"
        case 103: return "\u{1B}[23~"
        case 111: return "\u{1B}[24~"
        default: return nil
        }
    }

    // MARK: Text input (typing and input methods)

    override func insertText(_ string: Any, replacementRange: NSRange) {
        _ = removeMarkedDisplay()
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard !text.isEmpty else { return }
        session?.send(text)
    }

    override func doCommand(by selector: Selector) {
        // Special keys are handled in keyDown; ignore editing commands.
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        _ = removeMarkedDisplay()
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard !text.isEmpty else { return }
        showMarkedText(text)
    }

    override func unmarkText() {
        _ = removeMarkedDisplay()
    }

    override func hasMarkedText() -> Bool {
        markedDisplayRange != nil
    }

    override func markedRange() -> NSRange {
        markedDisplayRange ?? NSRange(location: NSNotFound, length: 0)
    }

    override func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let layoutManager, let textContainer, let window else { return .zero }
        let index = min(markedDisplayRange?.location ?? cursorIndex, max((textStorage?.length ?? 1) - 1, 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 0), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        rect.size.height = max(rect.height, cellSize.height)
        return window.convertToScreen(convert(rect, to: nil))
    }

    private func showMarkedText(_ text: String) {
        guard let storage = textStorage else { return }
        var attributes = attributes(for: TerminalStyle())
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        let location = cursorIndex
        storage.insert(NSAttributedString(string: text, attributes: attributes), at: location)
        markedDisplayRange = NSRange(location: location, length: (text as NSString).length)
    }

    /// Removes the input-method composition from the display and returns it.
    private func removeMarkedDisplay() -> String? {
        guard let range = markedDisplayRange, let storage = textStorage else { return nil }
        markedDisplayRange = nil
        guard NSMaxRange(range) <= storage.length else { return nil }
        let text = storage.attributedSubstring(from: range).string
        storage.deleteCharacters(in: range)
        return text
    }

    // MARK: Pasting and menus

    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        session?.paste(text)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            return session?.isConnected == true && NSPasteboard.general.string(forType: .string) != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let items: [(String, Selector, String)] = [
            (NSLocalizedString("Copy", comment: "Terminal menu"), #selector(copy(_:)), "c"),
            (NSLocalizedString("Paste", comment: "Terminal menu"), #selector(paste(_:)), "v"),
            (NSLocalizedString("Select All", comment: "Terminal menu"), #selector(selectAll(_:)), "a"),
            (NSLocalizedString("Clear Scrollback", comment: "Terminal menu"), #selector(clearScrollback(_:)), "k")
        ]
        for (index, item) in items.enumerated() {
            if index == 3 { menu.addItem(.separator()) }
            menu.addItem(withTitle: item.0, action: item.1, keyEquivalent: item.2).target = self
        }
        return menu
    }

    @objc private func clearScrollback(_ sender: Any?) {
        session?.clearScrollback()
    }
}

/// Terminal colors that stay readable in light and dark appearance.
enum TerminalPalette {
    static func color(_ color: TerminalColor) -> NSColor {
        switch color {
        case let .palette(index):
            if index < 16 { return ansi[Int(index)] }
            if index < 232 {
                let value = Int(index) - 16
                let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
                return NSColor(
                    srgbRed: levels[value / 36] / 255,
                    green: levels[(value / 6) % 6] / 255,
                    blue: levels[value % 6] / 255,
                    alpha: 1
                )
            }
            let gray = CGFloat(8 + (Int(index) - 232) * 10) / 255
            return NSColor(white: gray, alpha: 1)
        case let .rgb(red, green, blue):
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    private static let ansi: [NSColor] = [
        adaptive(light: 0x000000, dark: 0x6E6E6E), // black
        adaptive(light: 0xC23621, dark: 0xFF6B5B), // red
        adaptive(light: 0x25A01C, dark: 0x5FD35A), // green
        adaptive(light: 0x9E8A00, dark: 0xE5CF3B), // yellow
        adaptive(light: 0x2A4FD6, dark: 0x6C9EFF), // blue
        adaptive(light: 0xA93CB8, dark: 0xE07AF0), // magenta
        adaptive(light: 0x14929E, dark: 0x4FD6E0), // cyan
        adaptive(light: 0x8E8E8E, dark: 0xD0D0D0), // white
        adaptive(light: 0x5C5C5C, dark: 0x9A9A9A), // bright black
        adaptive(light: 0xE0442F, dark: 0xFF8A7D), // bright red
        adaptive(light: 0x2FBF23, dark: 0x8AF285), // bright green
        adaptive(light: 0xB8A100, dark: 0xFFEB6B), // bright yellow
        adaptive(light: 0x3E6BF0, dark: 0x94B8FF), // bright blue
        adaptive(light: 0xC756D6, dark: 0xF09CFF), // bright magenta
        adaptive(light: 0x1CAFBD, dark: 0x85ECF2), // bright cyan
        adaptive(light: 0xB0B0B0, dark: 0xFFFFFF) // bright white
    ]

    private static func adaptive(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}
