import Foundation

public enum TerminalColor: Equatable, Hashable, Sendable {
    /// 0–15 are the standard and bright ANSI colors, 16–255 the xterm palette.
    case palette(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct TerminalStyle: Equatable, Hashable, Sendable {
    public var foreground: TerminalColor?
    public var background: TerminalColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false

    public init() {}
}

public struct TerminalCell: Equatable, Sendable {
    public var text: String
    public var style: TerminalStyle
    /// The right half of a double-width character; not drawn.
    public var isContinuation = false

    static let blank = TerminalCell(text: " ", style: TerminalStyle())
}

/// A run of equally styled text within one line.
public struct TerminalRun: Equatable, Sendable {
    public var text: String
    public var style: TerminalStyle
}

public struct TerminalUpdate: Equatable, Sendable {
    /// Lines dropped from the top because of the scrollback limit.
    public var removedLines = 0
    /// Index of the first line whose content changed, if any.
    public var firstChangedLine: Int?
}

/// A terminal model for SSH shell sessions: an endless scrollback whose last
/// `rows` lines form the screen.
///
/// It understands what shells and common tools print: colors, carriage
/// returns, backspace, line editing and wrapping (including readline moving
/// the cursor up to redraw a long command), clearing, window titles and
/// bracketed paste. Programs that take over the whole screen (vim, top,
/// less) switch to the alternate screen; their output is not recorded, so
/// the scrollback stays readable, and `alternateScreen` tells the UI to
/// suggest a full terminal.
public final class TerminalBuffer {
    public private(set) var lines: [[TerminalCell]] = [[]]
    /// The line holding the cursor.
    public private(set) var row = 0
    /// The cursor column. Equal to `columns` right after the last column was
    /// written; the next character then wraps, as in xterm.
    public private(set) var cursor = 0
    public private(set) var columns = 80
    public private(set) var rows = 24
    public private(set) var title: String?
    public private(set) var alternateScreen = false
    public private(set) var applicationCursorKeys = false
    public private(set) var bracketedPaste = false
    public let maxLines: Int

    private enum State {
        case ground
        case escape
        case charset
        case csi
        case osc
        case oscEscape
        case ignoredString
        case ignoredStringEscape
    }

    private var state = State.ground
    private var parameters = ""
    private var oscText = ""
    private var style = TerminalStyle()
    private var savedPosition = (row: 0, column: 0)
    private var mainScreenPosition = (row: 0, column: 0)
    private var pendingBytes = Data()
    private var update = TerminalUpdate()

    public init(maxLines: Int = 5_000) {
        self.maxLines = max(maxLines, 10)
    }

    /// The size the remote side was told about; long lines wrap at `columns`.
    public func resize(columns: Int, rows: Int) {
        self.columns = max(columns, 10)
        self.rows = max(rows, 2)
    }

    @discardableResult
    public func feed(_ text: String) -> TerminalUpdate {
        feed(Data(text.utf8))
    }

    /// Processes output from the remote side and reports what changed.
    @discardableResult
    public func feed(_ data: Data) -> TerminalUpdate {
        update = TerminalUpdate()
        let (complete, remainder) = Self.splitIncompleteUTF8(pendingBytes + data)
        pendingBytes = remainder
        for scalar in String(decoding: complete, as: UTF8.self).unicodeScalars {
            process(scalar)
        }
        trimScrollback()
        return update
    }

    public func clear() {
        lines = [[]]
        row = 0
        cursor = 0
        markChanged(0)
    }

    /// Styled runs of one line, for drawing.
    public func runs(forLine index: Int) -> [TerminalRun] {
        var runs: [TerminalRun] = []
        for cell in lines[index] where !cell.isContinuation {
            if var last = runs.last, last.style == cell.style {
                last.text += cell.text
                runs[runs.count - 1] = last
            } else {
                runs.append(TerminalRun(text: cell.text, style: cell.style))
            }
        }
        return runs
    }

    public var plainText: String {
        lines.map { line in line.filter { !$0.isContinuation }.map(\.text).joined() }.joined(separator: "\n")
    }

    /// The first line of the screen; the cursor never moves above it.
    private var screenTop: Int { max(lines.count - rows, 0) }

    // MARK: Parsing

    private func process(_ scalar: Unicode.Scalar) {
        switch state {
        case .ground:
            ground(scalar)
        case .escape:
            escape(scalar)
        case .charset:
            state = .ground
        case .csi:
            if (0x40...0x7E).contains(scalar.value) {
                state = .ground
                controlSequence(final: Character(scalar))
            } else if scalar.value == 0x1B {
                state = .escape
            } else if scalar.value < 0x20 {
                ground(scalar) // controls act immediately, even inside a sequence
            } else if parameters.count < 64 {
                parameters.unicodeScalars.append(scalar)
            }
        case .osc:
            if scalar.value == 0x07 {
                finishOSC()
            } else if scalar.value == 0x1B {
                state = .oscEscape
            } else if oscText.count < 512 {
                oscText.unicodeScalars.append(scalar)
            }
        case .oscEscape:
            finishOSC()
            if scalar != "\\" { process(scalar) }
        case .ignoredString:
            if scalar.value == 0x1B { state = .ignoredStringEscape } else if scalar.value == 0x07 { state = .ground }
        case .ignoredStringEscape:
            state = scalar == "\\" ? .ground : .ignoredString
        }
    }

    private func ground(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x1B:
            state = .escape
        case 0x0A, 0x0B, 0x0C:
            lineFeed()
        case 0x0D:
            moveCursor(to: 0)
        case 0x08:
            moveCursor(to: min(cursor, columns - 1) - 1)
        case 0x09:
            moveCursor(to: min((cursor / 8 + 1) * 8, columns - 1))
        case 0x00..<0x20, 0x7F:
            break // bell and other controls
        default:
            put(scalar)
        }
    }

    private func escape(_ scalar: Unicode.Scalar) {
        state = .ground
        switch scalar {
        case "[":
            parameters = ""
            state = .csi
        case "]":
            oscText = ""
            state = .osc
        case "P", "X", "^", "_":
            state = .ignoredString
        case "(", ")", "*", "+", "-", ".", "/", "#", "%":
            state = .charset
        case "7":
            savedPosition = (row, cursor)
        case "8":
            moveCursor(toRow: savedPosition.row)
            moveCursor(to: savedPosition.column)
        case "E":
            lineFeed()
        case "D":
            let column = cursor
            lineFeed()
            moveCursor(to: column)
        case "M":
            moveCursor(toRow: row - 1)
        case "c":
            style = TerminalStyle()
            alternateScreen = false
            clear()
        default:
            break
        }
    }

    private func controlSequence(final: Character) {
        let isPrivate = parameters.hasPrefix("?")
        let values = parameters
            .trimmingCharacters(in: CharacterSet(charactersIn: "?>=<! "))
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0.split(separator: ":").first ?? "") }
        let first = values.first.flatMap { $0 } ?? 0
        let count = max(first, 1)

        if isPrivate {
            guard final == "h" || final == "l" else { return }
            let enabled = final == "h"
            for mode in values.compactMap({ $0 }) {
                switch mode {
                case 1: applicationCursorKeys = enabled
                case 47, 1047, 1049:
                    guard alternateScreen != enabled else { break }
                    if enabled {
                        mainScreenPosition = (row, cursor)
                    } else {
                        row = min(mainScreenPosition.row, lines.count - 1)
                        cursor = mainScreenPosition.column
                    }
                    alternateScreen = enabled
                case 2004: bracketedPaste = enabled
                default: break
                }
            }
            return
        }
        guard !alternateScreen else { return }

        switch final {
        case "m": selectGraphicRendition(values)
        case "K": eraseInLine(first)
        case "J": eraseInDisplay(first)
        case "A": moveCursor(toRow: row - count)
        case "B": moveCursor(toRow: row + count)
        case "C": moveCursor(to: min(cursor, columns - 1) + count)
        case "D": moveCursor(to: min(cursor, columns - 1) - count)
        case "G", "`": moveCursor(to: count - 1)
        case "d": moveCursor(toRow: screenTop + count - 1)
        case "H", "f":
            moveCursor(toRow: screenTop + count - 1)
            moveCursor(to: (values.count > 1 ? values[1] ?? 1 : 1) - 1)
        case "P": deleteCharacters(count)
        case "@": insertBlanks(count)
        case "X": eraseCharacters(count)
        default: break
        }
    }

    private func finishOSC() {
        state = .ground
        let parts = oscText.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[0] == "0" || parts[0] == "2" {
            title = String(parts[1])
        }
    }

    // MARK: Editing

    private func put(_ scalar: Unicode.Scalar) {
        guard !alternateScreen else { return }
        let width = Self.width(of: scalar)
        if width == 0 {
            // A combining mark joins the character before the cursor.
            if let index = lines[row].indices.last(where: { $0 < cursor && !lines[row][$0].isContinuation }) {
                lines[row][index].text.unicodeScalars.append(scalar)
                markChanged(row)
            }
            return
        }
        if cursor + width > columns {
            // Wrap to the next line, like a terminal with automatic margins.
            lineFeed()
        }
        pad(row, to: cursor + width)
        clearWideCharacter(row, at: cursor)
        if width == 2 { clearWideCharacter(row, at: cursor + 1) }
        lines[row][cursor] = TerminalCell(text: String(scalar), style: style)
        if width == 2 {
            lines[row][cursor + 1] = TerminalCell(text: "", style: style, isContinuation: true)
        }
        cursor += width
        markChanged(row)
    }

    /// Moves to the start of the next line, adding one at the bottom.
    private func lineFeed() {
        guard !alternateScreen else { return }
        markChanged(row)
        row += 1
        if row == lines.count { lines.append([]) }
        cursor = 0
        markChanged(row)
    }

    /// Moves the cursor on its line; the line counts as changed so the
    /// cursor is redrawn.
    private func moveCursor(to column: Int) {
        cursor = min(max(column, 0), columns - 1)
        if !alternateScreen { markChanged(row) }
    }

    private func moveCursor(toRow target: Int) {
        guard !alternateScreen else { return }
        markChanged(row)
        row = min(max(target, screenTop), lines.count - 1)
        markChanged(row)
    }

    private func eraseInLine(_ mode: Int) {
        switch mode {
        case 0:
            if cursor < lines[row].count { lines[row].removeSubrange(cursor...) }
        case 1:
            let end = min(cursor, columns - 1)
            pad(row, to: end + 1)
            for index in 0...end { lines[row][index] = .blank }
        default:
            lines[row] = []
        }
        markChanged(row)
    }

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            if row + 1 < lines.count { lines.removeSubrange((row + 1)...) }
        case 1:
            break
        default:
            clear()
        }
    }

    private func deleteCharacters(_ count: Int) {
        guard cursor < lines[row].count else { return }
        lines[row].removeSubrange(cursor..<min(cursor + count, lines[row].count))
        markChanged(row)
    }

    private func insertBlanks(_ count: Int) {
        guard cursor < lines[row].count else { return }
        lines[row].insert(contentsOf: Array(repeating: TerminalCell.blank, count: count), at: cursor)
        if lines[row].count > columns { lines[row].removeSubrange(columns...) }
        markChanged(row)
    }

    private func eraseCharacters(_ count: Int) {
        guard cursor < lines[row].count else { return }
        for index in cursor..<min(cursor + count, lines[row].count) { lines[row][index] = .blank }
        markChanged(row)
    }

    private func pad(_ line: Int, to length: Int) {
        if lines[line].count < length {
            lines[line].append(contentsOf: Array(repeating: TerminalCell.blank, count: length - lines[line].count))
        }
    }

    /// Overwriting half of a double-width character blanks the other half.
    private func clearWideCharacter(_ line: Int, at column: Int) {
        guard column < lines[line].count else { return }
        if lines[line][column].isContinuation, column > 0 {
            lines[line][column - 1] = .blank
            lines[line][column] = .blank
        } else if column + 1 < lines[line].count, lines[line][column + 1].isContinuation {
            lines[line][column + 1] = .blank
        }
    }

    private func selectGraphicRendition(_ values: [Int?]) {
        var codes = values.map { $0 ?? 0 }
        if codes.isEmpty { codes = [0] }
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: style = TerminalStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 22:
                style.bold = false
                style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37: style.foreground = .palette(UInt8(code - 30))
            case 39: style.foreground = nil
            case 40...47: style.background = .palette(UInt8(code - 40))
            case 49: style.background = nil
            case 90...97: style.foreground = .palette(UInt8(code - 90 + 8))
            case 100...107: style.background = .palette(UInt8(code - 100 + 8))
            case 38, 48:
                var color: TerminalColor?
                if index + 2 < codes.count, codes[index + 1] == 5 {
                    color = .palette(UInt8(clamping: codes[index + 2]))
                    index += 2
                } else if index + 4 < codes.count, codes[index + 1] == 2 {
                    color = .rgb(
                        UInt8(clamping: codes[index + 2]),
                        UInt8(clamping: codes[index + 3]),
                        UInt8(clamping: codes[index + 4])
                    )
                    index += 4
                }
                if code == 38 { style.foreground = color } else { style.background = color }
            default:
                break
            }
            index += 1
        }
    }

    // MARK: Bookkeeping

    private func markChanged(_ line: Int) {
        update.firstChangedLine = min(update.firstChangedLine ?? line, line)
    }

    private func trimScrollback() {
        let excess = lines.count - maxLines
        guard excess > 0 else { return }
        lines.removeFirst(excess)
        row = max(row - excess, 0)
        update.removedLines += excess
        update.firstChangedLine = update.firstChangedLine.map { max($0 - excess, 0) }
    }

    /// Columns a character occupies: 0 for combining marks, 2 for CJK and
    /// emoji, 1 otherwise.
    static func width(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value < 0x300 { return 1 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        if scalar.properties.isEmojiPresentation { return 2 }
        switch value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// Splits off a UTF-8 sequence cut in half at the end of a read.
    static func splitIncompleteUTF8(_ data: Data) -> (complete: Data, remainder: Data) {
        let bytes = [UInt8](data)
        var index = bytes.count - 1
        var continuationCount = 0
        while index >= 0, continuationCount < 3, bytes[index] & 0xC0 == 0x80 {
            continuationCount += 1
            index -= 1
        }
        guard index >= 0 else { return (data, Data()) }
        let lead = bytes[index]
        let expected: Int
        switch lead {
        case 0xC0...0xDF: expected = 2
        case 0xE0...0xEF: expected = 3
        case 0xF0...0xF7: expected = 4
        default: return (data, Data())
        }
        let available = bytes.count - index
        guard available < expected else { return (data, Data()) }
        return (Data(bytes[..<index]), Data(bytes[index...]))
    }
}
