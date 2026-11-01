// Apple Notes-style editing on an NSTextView: lists (auto-start, continue, nest, renumber), headings, inline
// formatting, moving lines. Holds no app state, so the self-test drives it without a window.
// List items carry their marker as text ("\t•\t", "\t3.\t"), the way AppKit's HTML import produces them.
import Cocoa

final class Editor {
    let text: NSTextView
    let body = NSFont.systemFont(ofSize: 14)
    var textColor: () -> NSColor = { .textColor }
    private var renumbering = false

    init(_ text: NSTextView) { self.text = text }

    var storage: NSTextStorage { text.textStorage! }

    // MARK: lists

    // List paragraph at `loc`: its range, its marker length, and its innermost list.
    func listItem(at loc: Int) -> (para: NSRange, marker: Int, list: NSTextList)? {
        let ns = text.string as NSString
        let p = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        guard p.location < storage.length,
              let l = (storage.attribute(.paragraphStyle, at: p.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.last
        else { return nil }
        return (p, Notes.markerLength(ns, p), l)
    }

    // Same geometry and bullets as AppKit's HTML import (36pt per level; • ◦ ▪), so typed and loaded lists match.
    static func indent(_ ps: NSMutableParagraphStyle, _ lists: [NSTextList]) {
        let d = CGFloat(lists.count)
        ps.textLists = lists
        ps.firstLineHeadIndent = 0
        ps.headIndent = 36 * d
        ps.tabStops = d == 0 ? NSParagraphStyle.default.tabStops
            : [NSTextTab(textAlignment: .left, location: 36 * d - 25), NSTextTab(textAlignment: .natural, location: 36 * d)]  // as AppKit's import: keeps the gap in RTL
    }

    static func listLevel(_ fmt: NSTextList.MarkerFormat, depth: Int) -> NSTextList {
        let bullets: [NSTextList.MarkerFormat] = [.disc, .circle, .square]
        return NSTextList(markerFormat: bullets.contains(fmt) ? bullets[(depth - 1) % 3] : fmt == .decimal ? Notes.numbered : fmt, options: 0)
    }

    // MARK: Markdown shortcuts

    enum Block { case list(NSTextList.MarkerFormat), heading(CGFloat) }

    // A Markdown line prefix typed at the start of a line, completed by the space being typed:
    // "- " "* " "1. " start lists; "# " "## " "### " make Title, Heading, Subheading.
    func blockTrigger(_ r: NSRange, _ s: String?) -> (prefix: NSRange, block: Block)? {
        guard s == " ", r.length == 0 else { return nil }
        let ns = text.string as NSString
        let p = ns.paragraphRange(for: r)
        let typed = ns.substring(with: NSRange(location: p.location, length: r.location - p.location))
        let blocks: [String: Block] = ["-": .list(.hyphen), "*": .list(.disc), "•": .list(.disc), "1.": .list(.decimal), "1)": .list(.decimal),
                                       "#": .heading(24), "##": .heading(20), "###": .heading(16)]
        guard let b = blocks[typed], listItem(at: r.location) == nil else { return nil }
        return (NSRange(location: p.location, length: (typed as NSString).length), b)
    }

    func startBlock(replacing prefix: NSRange, _ b: Block) {
        guard text.shouldChangeText(in: prefix, replacementString: "") else { return }
        storage.replaceCharacters(in: prefix, with: "")
        text.didChangeText()
        text.setSelectedRange(NSRange(location: prefix.location, length: 0))
        switch b {
        case .list(let f): list(f)
        case .heading(let size): block(size, bold: true)
        }
    }

    static let inlineTriggers: Set<String> = ["*", "_", "~", "`", ")"]
    private static let lead = #"(?:^|(?<=[\s(\[{"'“‘]))"#  // a marker opens only at a word boundary (keeps snake_case, 2*3*4)
    private static let inlineRules: [(kind: String, re: NSRegularExpression)] = [
        ("link", #"\[([^\]\n]+)\]\(((?:https?://|mailto:)[^\s)]+)\)$"#),
        ("bold", lead + #"\*\*(?=\S)([^*\n]+?)(?<=\S)\*\*$"#),
        ("bold", lead + #"__(?=\S)([^_\n]+?)(?<=\S)__$"#),
        ("strike", lead + #"~~(?=\S)([^~\n]+?)(?<=\S)~~$"#),
        ("code", #"`([^`\n]+)`$"#),
        ("italic", lead + #"\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*$"#),
        ("italic", lead + #"_(?=[^\s_])([^_\n]+?)(?<=[^\s_])_$"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    // Right after a closing marker is typed: **bold**, _italic_, ~~strike~~, `code`, [text](url) become formatting
    // and the markers go. Its own undo step, so ⌘Z brings back the literal Markdown. Literal inside code.
    @discardableResult
    func inlineShortcut() -> Bool {
        let caret = text.selectedRange()
        guard caret.length == 0, caret.location > 0 else { return false }
        let ns = text.string as NSString
        let p = ns.paragraphRange(for: NSRange(location: caret.location - 1, length: 0))
        let start = p.location + Notes.markerLength(ns, p)
        guard caret.location > start, !((storage.attribute(.font, at: caret.location - 1, effectiveRange: nil) as? NSFont)?.isFixedPitch ?? false)
        else { return false }
        let before = ns.substring(with: NSRange(location: start, length: caret.location - start))
        for rule in Editor.inlineRules {
            guard let m = rule.re.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) else { continue }
            let opened = (before as NSString).substring(to: m.range.location).filter { $0 == "`" }.count
            if rule.kind != "code", opened % 2 == 1 { continue }  // inside an unclosed `code span`: stay literal
            let whole = NSRange(location: start + m.range.location, length: m.range.length)
            let content = (before as NSString).substring(with: m.range(at: 1))
            let plain = storage.attributes(at: start + m.range(at: 1).location, effectiveRange: nil)
            var attrs = plain
            let font = attrs[.font] as? NSFont ?? body
            switch rule.kind {
            case "bold": attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            case "italic": attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            case "strike": attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case "code": attrs[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
            default: attrs[.link] = URL(string: (before as NSString).substring(with: m.range(at: 2)))
            }
            guard text.shouldChangeText(in: whole, replacementString: content) else { return false }
            storage.replaceCharacters(in: whole, with: NSAttributedString(string: content, attributes: attrs))
            text.didChangeText()
            text.setSelectedRange(NSRange(location: whole.location + (content as NSString).length, length: 0))
            text.typingAttributes = plain  // keep typing unformatted after the span
            return true
        }
        return false
    }

    // ``` (optionally with a language, like ```swift) then ↩ turns the line into a Monostyled paragraph.
    func codeFence(_ sel: Selector, _ sr: NSRange) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        let ns = text.string as NSString
        let p = ns.paragraphRange(for: sr)
        let line = ns.substring(with: p).trimmingCharacters(in: .newlines)
        guard line.range(of: #"^```[A-Za-z0-9+#-]*$"#, options: .regularExpression) != nil else { return false }
        let lineRange = NSRange(location: p.location, length: (line as NSString).length)
        guard text.shouldChangeText(in: lineRange, replacementString: "") else { return false }
        storage.replaceCharacters(in: lineRange, with: "")
        text.didChangeText()
        text.setSelectedRange(NSRange(location: p.location, length: 0))
        block(13, bold: false, mono: true)
        return true
    }

    // Toggles a list on the selected paragraphs (off if the first one already has this kind).
    func list(_ kind: NSTextList.MarkerFormat) {
        let fmt = kind == .decimal ? Notes.numbered : kind == .hyphen ? Notes.dashed : kind  // "1." and "–" like Apple Notes
        let pr = (text.string as NSString).paragraphRange(for: text.selectedRange())
        let old = storage.attributedSubstring(from: pr)
        let firstStyle = (pr.location < storage.length ? storage.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil)
                                                       : text.typingAttributes[.paragraphStyle]) as? NSParagraphStyle
        let off = firstStyle?.textLists.first?.markerFormat == fmt
        let newList = NSTextList(markerFormat: fmt, options: 0)
        var paras: [NSRange] = []
        (old.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: old.length),
                                                     options: [.byParagraphs, .substringNotRequired]) { _, _, e, _ in paras.append(e) }
        if paras.isEmpty { paras = [NSRange(location: 0, length: 0)] }
        let out = NSMutableAttributedString()
        for (i, e) in paras.enumerated() {
            let attrs = e.length > 0 ? old.attributes(at: e.location, effectiveRange: nil) : text.typingAttributes
            let ps = (attrs[.paragraphStyle] as? NSParagraphStyle ?? Notes.paragraph).mutableCopy() as! NSMutableParagraphStyle
            let c = old.attributedSubstring(from: e).mutableCopy() as! NSMutableAttributedString
            if !ps.textLists.isEmpty {
                c.deleteCharacters(in: NSRange(location: 0, length: Notes.markerLength(c.string as NSString, NSRange(location: 0, length: c.length))))
            }
            if off {
                Editor.indent(ps, [])
            } else {
                Editor.indent(ps, [newList])
                c.insert(NSAttributedString(string: "\t\(newList.marker(forItemNumber: i + 1))\t", attributes: attrs), at: 0)
            }
            c.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: c.length))
            out.append(c)
        }
        guard text.shouldChangeText(in: pr, replacementString: out.string) else { return }
        storage.replaceCharacters(in: pr, with: out)
        text.didChangeText()
        text.setSelectedRange(NSRange(location: pr.location + out.length - (out.string.hasSuffix("\n") ? 1 : 0), length: 0))
    }

    // Tab / ⇧Tab anywhere in a list item changes its nesting, like Apple Notes.
    func nest(_ li: (para: NSRange, marker: Int, list: NSTextList), deeper: Bool) {
        let ps = (storage.attribute(.paragraphStyle, at: li.para.location, effectiveRange: nil) as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        var lists = ps.textLists
        if deeper { guard lists.count < 6 else { return }; lists.append(Editor.listLevel(li.list.markerFormat, depth: lists.count + 1)) }
        else { guard lists.count > 1 else { return }; lists.removeLast() }
        Editor.indent(ps, lists)
        let contentStart = li.para.location + li.marker
        let content = storage.attributedSubstring(from: NSRange(location: contentStart, length: NSMaxRange(li.para) - contentStart))
        let marker = "\t\(lists.last!.marker(forItemNumber: 1))\t"
        let out = NSMutableAttributedString(string: marker, attributes: content.length > 0 ? content.attributes(at: 0, effectiveRange: nil) : text.typingAttributes)
        out.append(content)
        out.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: out.length))
        let caret = text.selectedRange().location - contentStart
        guard text.shouldChangeText(in: li.para, replacementString: out.string) else { return }
        storage.replaceCharacters(in: li.para, with: out)
        text.didChangeText()
        text.setSelectedRange(NSRange(location: li.para.location + (marker as NSString).length + max(0, caret), length: 0))
    }

    // Direction follows each paragraph's first letter (see Notes.setDirections); re-check the edited paragraphs.
    // Attribute-only and display-only, so it skips undo registration.
    func fixDirections() {
        Notes.setDirections(storage, in: text.selectedRange())
    }

    // Numbers are text, so recount every numbered list after an edit: moving, adding or deleting items keeps 1, 2, 3.
    // Each list is one NSTextList object (shared by its items), which is how items are grouped.
    func renumber() {
        guard !renumbering else { return }  // our own edits re-trigger textDidChange
        renumbering = true
        defer { renumbering = false }
        let fixes = Notes.numberFixes(storage)
        guard !fixes.isEmpty else { return }
        var sel = text.selectedRange()
        for f in fixes.reversed() {
            guard text.shouldChangeText(in: f.range, replacementString: f.marker) else { continue }
            storage.replaceCharacters(in: f.range, with: NSAttributedString(string: f.marker, attributes: storage.attributes(at: f.range.location, effectiveRange: nil)))
            text.didChangeText()
            if f.range.location < sel.location { sel.location += (f.marker as NSString).length - f.range.length }
        }
        text.setSelectedRange(sel)
    }

    // ↩ continues a list, ↩ on an empty item or ⌫ right after the bullet ends it, Tab / ⇧Tab nest;
    // ↩ at the end of a heading starts a Body line. Returns whether the command was handled.
    func command(_ sel: Selector) -> Bool {
        let sr = text.selectedRange()
        guard sr.length == 0 else { return false }
        guard let li = listItem(at: sr.location) else { return codeFence(sel, sr) || headingReturn(sel, sr) }
        let ns = text.string as NSString
        let content = ns.substring(with: NSRange(location: li.para.location + li.marker, length: li.para.length - li.marker))
            .trimmingCharacters(in: .newlines)
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if content.isEmpty { list(li.list.markerFormat); return true }
            let current = ns.substring(with: NSRange(location: li.para.location, length: li.marker))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\t.)"))
            var attrs = text.typingAttributes
            attrs[.paragraphStyle] = storage.attribute(.paragraphStyle, at: li.para.location, effectiveRange: nil)
            text.insertText(NSAttributedString(string: "\n\t\(li.list.marker(forItemNumber: (Int(current) ?? 0) + 1))\t", attributes: attrs),
                            replacementRange: sr)
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            nest(li, deeper: sel == #selector(NSResponder.insertTab(_:)))
            return true
        case #selector(NSResponder.deleteBackward(_:)) where li.marker > 0 && sr.location == li.para.location + li.marker:
            list(li.list.markerFormat)
            return true
        default:
            return false
        }
    }

    func headingReturn(_ sel: Selector, _ sr: NSRange) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        let ns = text.string as NSString
        let p = ns.paragraphRange(for: sr)
        let end = NSMaxRange(p) - (ns.substring(with: p).hasSuffix("\n") ? 1 : 0)
        guard sr.location == end, p.length > 0, p.location < ns.length,
              let f = storage.attribute(.font, at: p.location, effectiveRange: nil) as? NSFont,
              f.pointSize >= 15.5, !f.isFixedPitch else { return false }
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: textColor(), .paragraphStyle: Notes.paragraph]
        text.insertText("\n", replacementRange: sr)  // terminates the heading paragraph
        let next = NSRange(location: sr.location + 1, length: 1)  // the old newline now ends the new empty line
        let now = text.string as NSString
        if NSMaxRange(next) <= now.length, now.character(at: next.location) == 10, text.shouldChangeText(in: next, replacementString: nil) {
            storage.setAttributes(bodyAttrs, range: next)
            text.didChangeText()
        }
        text.typingAttributes = bodyAttrs
        return true
    }

    func moveLine(up: Bool) {
        let ns = text.string as NSString
        let cur = ns.paragraphRange(for: text.selectedRange())
        if up ? cur.location == 0 : NSMaxRange(cur) >= ns.length { return }
        let other = ns.paragraphRange(for: NSRange(location: up ? cur.location - 1 : NSMaxRange(cur), length: 0))
        let (first, second) = up ? (other, cur) : (cur, other)
        let a = storage.attributedSubstring(from: first).mutableCopy() as! NSMutableAttributedString
        let b = storage.attributedSubstring(from: second).mutableCopy() as! NSMutableAttributedString
        if !b.string.hasSuffix("\n") {  // last line has no newline: move it over
            b.append(a.attributedSubstring(from: NSRange(location: a.length - 1, length: 1)))
            a.deleteCharacters(in: NSRange(location: a.length - 1, length: 1))
        }
        let whole = NSUnionRange(first, second)
        let offset = text.selectedRange().location - cur.location
        let out = NSMutableAttributedString(attributedString: b)
        out.append(a)
        guard text.shouldChangeText(in: whole, replacementString: out.string) else { return }
        storage.replaceCharacters(in: whole, with: out)
        text.didChangeText()
        text.setSelectedRange(NSRange(location: (up ? first.location : first.location + b.length) + offset, length: 0))
        renumber()
    }

    // MARK: inline and block formatting

    func trait(_ t: NSFontTraitMask) {
        let fm = NSFontManager.shared, r = text.selectedRange()
        let now = (r.length > 0 ? storage.attribute(.font, at: r.location, effectiveRange: nil) : text.typingAttributes[.font]) as? NSFont ?? body
        let add = !fm.traits(of: now).contains(t)
        let conv = { (f: NSFont) in add ? fm.convert(f, toHaveTrait: t) : fm.convert(f, toNotHaveTrait: t) }
        if r.length == 0 { text.typingAttributes[.font] = conv(now); return }
        guard text.shouldChangeText(in: r, replacementString: nil) else { return }
        storage.enumerateAttribute(.font, in: r) { v, sub, _ in self.storage.addAttribute(.font, value: conv(v as? NSFont ?? self.body), range: sub) }
        text.didChangeText()
    }

    func toggle(_ key: NSAttributedString.Key) {
        let r = text.selectedRange()
        let now = (r.length > 0 ? storage.attribute(key, at: r.location, effectiveRange: nil) : text.typingAttributes[key]) as? Int ?? 0
        let v = now == 0 ? NSUnderlineStyle.single.rawValue : 0
        if r.length == 0 { text.typingAttributes[key] = v; return }
        guard text.shouldChangeText(in: r, replacementString: nil) else { return }
        storage.addAttribute(key, value: v, range: r)
        text.didChangeText()
    }

    func block(_ size: CGFloat, bold: Bool, mono: Bool = false) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        text.typingAttributes[.font] = font
        let r = (text.string as NSString).paragraphRange(for: text.selectedRange())
        guard r.length > 0, text.shouldChangeText(in: r, replacementString: nil) else { return }
        storage.addAttribute(.font, value: font, range: r)
        text.didChangeText()
    }
}
