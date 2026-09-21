import Foundation
import Testing

@testable import BWMonitorCore

@Suite("Terminal buffer")
struct TerminalBufferTests {
    @Test("Lines, prompts and colors")
    func colors() {
        let buffer = TerminalBuffer()
        buffer.feed("\u{1B}[01;32mroot@vps\u{1B}[00m:\u{1B}[01;34m~\u{1B}[00m# ls\r\n")
        #expect(buffer.plainText == "root@vps:~# ls\n")
        let runs = buffer.runs(forLine: 0)
        #expect(runs.map(\.text) == ["root@vps", ":", "~", "# ls"])
        #expect(runs[0].style.foreground == .palette(2))
        #expect(runs[0].style.bold)
        #expect(runs[1].style == TerminalStyle())
        #expect(runs[2].style.foreground == .palette(4))
    }

    @Test("256 and true color")
    func extendedColors() {
        let buffer = TerminalBuffer()
        buffer.feed("\u{1B}[38;5;208ma\u{1B}[48;2;1;2;3mb\u{1B}[0m")
        let runs = buffer.runs(forLine: 0)
        #expect(runs[0].style.foreground == .palette(208))
        #expect(runs[1].style.background == .rgb(1, 2, 3))
    }

    @Test("Readline editing with backspace and erase")
    func lineEditing() {
        let buffer = TerminalBuffer()
        buffer.feed("# lss")
        buffer.feed("\u{08}\u{1B}[K")
        #expect(buffer.plainText == "# ls")
        // History recall redraws the line from the start.
        buffer.feed("\r# uptime\u{1B}[K")
        #expect(buffer.plainText == "# uptime")
        // Cursor moves left, then text is inserted.
        buffer.feed("\u{1B}[3D\u{1B}[1@X")
        #expect(buffer.plainText == "# uptXime")
    }

    @Test("Progress lines overwrite themselves")
    func carriageReturn() {
        let buffer = TerminalBuffer()
        buffer.feed("Progress: 10%\rProgress: 100%\r\ndone\r\n")
        #expect(buffer.plainText == "Progress: 100%\ndone\n")
    }

    @Test("clear empties the screen")
    func clearScreen() {
        let buffer = TerminalBuffer()
        buffer.feed("a\r\nb\r\n")
        let update = buffer.feed("\u{1B}[H\u{1B}[2J\u{1B}[3J# ")
        #expect(buffer.plainText == "# ")
        #expect(update.firstChangedLine == 0)
    }

    @Test("Full-screen programs do not garble the scrollback")
    func alternateScreen() {
        let buffer = TerminalBuffer()
        buffer.feed("# vim\r\n")
        buffer.feed("\u{1B}[?1049h\u{1B}[1;1H~\r\n~\r\n\u{1B}[24;1H\"file\" 3L")
        #expect(buffer.alternateScreen)
        buffer.feed("\u{1B}[?1049l# ")
        #expect(!buffer.alternateScreen)
        #expect(buffer.plainText == "# vim\n# ")
    }

    @Test("Window title, modes, and ignored sequences")
    func modes() {
        let buffer = TerminalBuffer()
        buffer.feed("\u{1B}]0;root@vps: ~\u{07}\u{1B}[?2004h\u{1B}[?1h\u{1B}=\u{1B}(Bok\u{1B}P+q\u{1B}\\!")
        #expect(buffer.title == "root@vps: ~")
        #expect(buffer.bracketedPaste)
        #expect(buffer.applicationCursorKeys)
        #expect(buffer.plainText == "ok!")
    }

    @Test("UTF-8 split across reads, and wide characters")
    func unicode() {
        let buffer = TerminalBuffer()
        let bytes = Data("中文".utf8)
        buffer.feed(bytes.prefix(4))
        #expect(buffer.plainText == "中")
        buffer.feed(bytes.dropFirst(4))
        #expect(buffer.plainText == "中文")
        #expect(buffer.cursor == 4)
        // Readline erases a wide character with two backspaces.
        buffer.feed("\u{08}\u{08}\u{1B}[K")
        #expect(buffer.plainText == "中")
    }

    @Test("Long command lines wrap, and readline can redraw them")
    func wrapping() {
        let buffer = TerminalBuffer()
        buffer.resize(columns: 10, rows: 5)
        buffer.feed("# 12345678ABCDEF")
        #expect(buffer.plainText == "# 12345678\nABCDEF")
        #expect(buffer.row == 1)
        // Readline redraws a wrapped line from its first row.
        buffer.feed("\u{1B}[A\r# 12345678XBCDEF")
        #expect(buffer.plainText == "# 12345678\nXBCDEF")
        // Backspace right after the last column stays on that line.
        let exact = TerminalBuffer()
        exact.resize(columns: 10, rows: 5)
        exact.feed("0123456789\u{08}\u{1B}[K")
        #expect(exact.plainText == "01234567")
        // Erasing to the end of the screen removes the lines below.
        buffer.feed("\u{1B}[A\r\u{1B}[J")
        #expect(buffer.plainText == "")
    }

    @Test("Readline output for a wrapped command, as captured from bash")
    func capturedReadlineWrap() {
        let buffer = TerminalBuffer()
        buffer.resize(columns: 60, rows: 24)
        let a = { (count: Int) in String(repeating: "a", count: count) }
        // bash writes a space and a return at the margin to force the wrap.
        buffer.feed("root@fake-ubuntu:~# echo \(a(35)) \r\(a(60)) \raaaaa-END")
        buffer.feed("\u{08} \u{08}\u{08} \u{08}\u{08} \u{08}XYZ\r\n\(a(100))-XYZ\r\nroot@fake-ubuntu:~# ")
        #expect(buffer.plainText == [
            "root@fake-ubuntu:~# echo \(a(35))",
            a(60),
            "aaaaa-XYZ",
            a(60),
            a(40) + "-XYZ",
            "root@fake-ubuntu:~# "
        ].joined(separator: "\n"))
    }

    @Test("Scrollback is limited")
    func scrollback() {
        let buffer = TerminalBuffer(maxLines: 10)
        buffer.feed(String(repeating: "line\r\n", count: 9))
        let update = buffer.feed("a\r\nb\r\nc\r\n")
        #expect(buffer.lines.count == 10)
        #expect(update.removedLines == 3)
        #expect(update.firstChangedLine == 6)
    }
}
