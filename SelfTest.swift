// `NotesFloat --test`: headless checks run by build.sh and CI. Uses made-up notes only; never touches Apple Notes.
import Cocoa

func runSelfTests() -> Never {
    var failures: [String] = []
    func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if !ok { failures.append(what + (detail().isEmpty ? "" : "\n    \(detail())")) }
    }

    // HTML ↔ attributed text, Markdown, AppleScript quoting
    let h = "<h1>Title</h1><div>a <b>b</b> <i>c</i> &amp; <u>d</u> <strike>e</strike> <a href=\"https://x.y/\">l</a></div>"
        + "<div><br></div><ul><li>one</li><li>two</li></ul><ol><li>n</li></ol><h2>H</h2><h3>S</h3><div><tt>mono</tt></div>"
    let s = Notes.attributed(h)
    check(Notes.html(s) == h, "HTML round trip", Notes.html(s))
    check(Notes.markdown(s) == "# Title\na **b** _c_ & d ~~e~~ [l](https://x.y/)\n\n- one\n- two\n1. n\n## H\n### S\n`mono`", "Markdown", Notes.markdown(s))
    let nested = "<ul><li>a</li><ul><li>b</li></ul><li>c</li></ul>"
    check(Notes.html(Notes.attributed(nested)) == nested, "nested list round trip", Notes.html(Notes.attributed(nested)))
    check(Notes.q(#"say "hi" \"#) == #""say \"hi\" \\""#, "AppleScript quoting")

    // Editor, driven like the app does (shouldChange/doCommand), on a windowless text view
    func editor(_ html: String = "") -> Editor {
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.isEditable = true
        tv.isRichText = true
        tv.allowsUndo = false
        tv.textStorage!.setAttributedString(Notes.attributed(html))
        tv.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: Notes.paragraph]
        return Editor(tv)
    }
    func type(_ e: Editor, _ str: String) {
        for ch in str {
            let r = e.text.selectedRange()
            if let t = e.blockTrigger(r, String(ch)) { e.startBlock(replacing: t.prefix, t.block); continue }
            e.text.insertText(String(ch), replacementRange: r)
            if Editor.inlineTriggers.contains(String(ch)) { e.inlineShortcut() }
            e.renumber()
        }
    }
    func html(_ e: Editor) -> String { Notes.html(e.text.attributedString()) }
    let newline = #selector(NSResponder.insertNewline(_:)), tab = #selector(NSResponder.insertTab(_:))
    let backtab = #selector(NSResponder.insertBacktab(_:)), backspace = #selector(NSResponder.deleteBackward(_:))

    var e = editor()
    type(e, "- a")
    check(html(e) == "<ul><li>a</li></ul>", "“- ” starts a list", html(e))
    _ = e.command(newline); type(e, "b")
    check(html(e) == "<ul><li>a</li><li>b</li></ul>", "↩ continues a list", html(e))
    _ = e.command(newline); _ = e.command(newline); type(e, "c")
    check(html(e) == "<ul><li>a</li><li>b</li></ul><div>c</div>", "↩ on an empty item ends the list", html(e))

    e = editor("<ul><li>a</li><li>b</li></ul>")
    e.text.setSelectedRange(NSRange(location: (e.text.string as NSString).length, length: 0))
    _ = e.command(tab)
    check(html(e) == "<ul><li>a</li><ul><li>b</li></ul></ul>", "Tab nests a list item", html(e))
    let ps = e.storage.attribute(.paragraphStyle, at: (e.text.string as NSString).length - 1, effectiveRange: nil) as? NSParagraphStyle
    check(ps?.headIndent == 72, "nested item uses import geometry (72pt)", "\(ps?.headIndent ?? -1)")
    _ = e.command(backtab)
    check(html(e) == "<ul><li>a</li><li>b</li></ul>", "⇧Tab outdents", html(e))

    e = editor("<ul><li>a</li></ul>")
    e.text.setSelectedRange(NSRange(location: Notes.markerLength(e.text.string as NSString, NSRange(location: 0, length: 3)), length: 0))
    _ = e.command(backspace)
    check(html(e) == "<div>a</div>", "⌫ right after the bullet ends the list", html(e))

    e = editor()
    type(e, "1. x"); _ = e.command(newline); type(e, "y"); _ = e.command(newline); type(e, "z")
    let markers = { (e.text.string as NSString).components(separatedBy: "\n").map { $0.split(separator: "\t").first.map(String.init) ?? "" } }
    check(markers() == ["1.", "2.", "3."], "numbered list counts up", "\(markers())")
    e.moveLine(up: true)  // z above y
    check(html(e) == "<ol><li>x</li><li>z</li><li>y</li></ol>" && markers() == ["1.", "2.", "3."], "moving an item renumbers",
          "\(html(e)) \(markers())")

    e = editor("<h1>Title</h1>")
    e.text.setSelectedRange(NSRange(location: 5, length: 0))
    _ = e.command(newline); type(e, "body")
    check(html(e) == "<h1>Title</h1><div>body</div>", "↩ after a heading starts Body text", html(e))

    e = editor("<ol><li>x</li><li>y</li></ol>")
    check(markers() == ["1.", "2."], "loaded numbered lists show “1.”", "\(markers())")

    // Right-to-left: direction is display-only (Apple Notes' HTML has none), decided per paragraph by its first letter
    let rtlHTML = "<h1>ملاحظات</h1><div>نص عربي مع English</div><div>English first مع عربي</div><ul><li>بند</li><ul><li>فرعي</li></ul></ul><ol><li>واحد</li></ol>"
    let rtl = Notes.attributed(rtlHTML)
    check(Notes.html(rtl) == rtlHTML, "Arabic note saves back unchanged", Notes.html(rtl))
    let dirs: [String] = (rtl.string as NSString).components(separatedBy: "\n").enumerated().map { i, _ in
        let loc = (rtl.string as NSString).components(separatedBy: "\n").prefix(i).reduce(0) { $0 + ($1 as NSString).length + 1 }
        let ps = rtl.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle
        return ps?.baseWritingDirection == .rightToLeft && ps?.alignment == .right ? "R" : ps?.baseWritingDirection == .leftToRight && ps?.alignment == .left ? "L" : "?"
    }
    check(dirs == ["R", "R", "L", "R", "R", "R"], "paragraph direction follows the first letter", "\(dirs)")
    check(Notes.isRTL("123 - مرحبا") && !Notes.isRTL("Hi مرحبا") && Notes.isRTL("שלום") && !Notes.isRTL("١٢٣"), "first-letter rule ignores digits and punctuation")
    e = editor()
    type(e, "- عنصر"); e.fixDirections()
    let dashPS = e.storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    check(html(e) == "<ul><li>عنصر</li></ul>" && e.text.string.hasPrefix("\t–\t") && dashPS?.baseWritingDirection == .rightToLeft,
          "typed Arabic dashed list: “–”, right-to-left, saves as a list", "\(html(e)) \(String(reflecting: e.text.string))")

    // Markdown shortcuts while typing (and what must stay literal)
    for (typed, want, what) in [
        ("# Big", "<h1>Big</h1>", "“# ” → Title"), ("## Mid", "<h2>Mid</h2>", "“## ” → Heading"), ("### Small", "<h3>Small</h3>", "“### ” → Subheading"),
        ("a **bold** b", "<div>a <b>bold</b> b</div>", "**bold**"), ("an _it_ x", "<div>an <i>it</i> x</div>", "_italic_"),
        ("an *it* x", "<div>an <i>it</i> x</div>", "*italic*"), ("~~gone~~", "<div><strike>gone</strike></div>", "~~strike~~"),
        ("run `ls -la` now", "<div>run <tt>ls -la</tt> now</div>", "`code`"),
        ("see [docs](https://x.y/a)", "<div>see <a href=\"https://x.y/a\">docs</a></div>", "[text](url)"),
        ("snake_case_name", "<div>snake_case_name</div>", "snake_case stays"), ("2*3*4", "<div>2*3*4</div>", "2*3*4 stays"),
        ("#tag here", "<div>#tag here</div>", "#tag stays"), ("`a **b** c`", "<div><tt>a **b** c</tt></div>", "no formatting inside code"),
        ("x **bold** and _it_", "<div>x <b>bold</b> and <i>it</i></div>", "two spans on one line"),
    ] {
        e = editor()
        type(e, typed)
        check(html(e) == want, "typing \(what)", html(e))
    }
    e = editor()
    type(e, "```"); _ = e.command(newline); type(e, "let x = 1")
    check(html(e) == "<div><tt>let x = 1</tt></div>", "``` then ↩ starts a Monostyled paragraph", html(e))

    // Pasting Markdown
    let md = "# Title\nSome **bold**, _italic_, `code`, ~~gone~~ and a [link](https://x.y/).\n\n- one\n- two\n  - nested\n\n1. first\n2. second\n\n- [ ] todo\n- [x] done\n\n```swift\nlet x = 1\n```\n> quoted\n---\nend"
    let mdWant = "<h1>Title</h1><div>Some <b>bold</b>, <i>italic</i>, <tt>code</tt>, <strike>gone</strike> and a <a href=\"https://x.y/\">link</a>.</div>"
        + "<div><br></div><ul><li>one</li><li>two</li><ul><li>nested</li></ul></ul><ol><li>first</li><li>second</li></ol>"
        + "<ul><li>☐ todo</li><li>☑ done</li></ul><div><br></div><div><tt>let x = 1</tt></div><div>quoted</div><div>end</div>"
    check(Notes.markdownHTML(md) == mdWant, "Markdown paste → Apple Notes HTML", Notes.markdownHTML(md))
    check(Notes.html(Notes.attributed(Notes.markdownHTML(md))) == mdWant, "pasted Markdown saves as the same HTML", Notes.html(Notes.attributed(Notes.markdownHTML(md))))
    check(Notes.looksLikeMarkdown(md) && Notes.looksLikeMarkdown("- milk\n- eggs") && !Notes.looksLikeMarkdown("Just a sentence, 2*3*4 = 24.")
          && !Notes.looksLikeMarkdown("email me at a_b_c@x.y"), "detects Markdown, leaves plain text alone")

    // Notes' database format: gzip(protobuf), built by hand: title, a ticked checklist item, a bullet
    func varint(_ v: Int) -> [UInt8] { var v = UInt64(v), o: [UInt8] = []; repeat { o.append(UInt8(v & 0x7f) | (v > 0x7f ? 0x80 : 0)); v >>= 7 } while v > 0; return o }
    func num(_ f: Int, _ v: Int) -> [UInt8] { varint(f << 3) + varint(v) }
    func bytes(_ f: Int, _ b: [UInt8]) -> [UInt8] { varint(f << 3 | 2) + varint(b.count) + b }
    func run(_ len: Int, _ style: [UInt8]?) -> [UInt8] { bytes(5, num(1, len) + (style.map { bytes(2, $0) } ?? [])) }
    let noteText = "Title\nA\nB\n"
    let note = bytes(2, Array(noteText.utf8)) + run(6, nil) + run(2, num(1, 103) + bytes(5, num(2, 1))) + run(2, num(1, 100))
    let proto = Data(bytes(2, bytes(3, note)))
    let gz = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3]) + (try! (proto as NSData).compressed(using: .zlib) as Data) + Data(count: 8)
    let decoded = Notes.decode(gz)
    check(decoded?.text == noteText, "decodes note text", "\(String(describing: decoded?.text))")
    check(decoded?.paras.map(\.style) == [-1, 103, 100] && decoded?.paras.map(\.done) == [false, true, false],
          "decodes checklist styles and ticks", "\(String(describing: decoded?.paras))")
    check(Notes.decode(Data([0x1f, 0x8b] + [UInt8](repeating: 0xff, count: 40))) == nil, "rejects garbage without crashing")

    if failures.isEmpty { print("ok"); exit(0) }
    print("FAILED \(failures.count):\n- " + failures.joined(separator: "\n- "))
    exit(1)
}
