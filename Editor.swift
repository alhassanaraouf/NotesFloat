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
            : [NSTextTab(textAlignment: .left, location: 36 * d - 25), NSTextTab(textAlignment: .left, location: 36 * d)]
    }

    static func listLevel(_ fmt: NSTextList.MarkerFormat, depth: Int) -> NSTextList {
        let bullets: [NSTextList.MarkerFormat] = [.disc, .circle, .square]
        return NSTextList(markerFormat: bullets.contains(fmt) ? bullets[(depth - 1) % 3] : fmt == .decimal ? Notes.numbered : fmt, options: 0)
    }

    // "- " → dashed, "* " → bulleted, "1. " → numbered, typed at the start of a line: the typed prefix and list kind.
    func listTrigger(_ r: NSRange, _ s: String?) -> (prefix: NSRange, format: NSTextList.MarkerFormat)? {
        guard s == " ", r.length == 0 else { return nil }
        let ns = text.string as NSString
        let p = ns.paragraphRange(for: r)
        let typed = ns.substring(with: NSRange(location: p.location, length: r.location - p.location))
        guard let fmt: NSTextList.MarkerFormat = ["-": .hyphen, "*": .disc, "•": .disc, "1.": .decimal, "1)": .decimal][typed],
              listItem(at: r.location) == nil else { return nil }
        return (NSRange(location: p.location, length: (typed as NSString).length), fmt)
    }

    func startList(replacing prefix: NSRange, _ fmt: NSTextList.MarkerFormat) {
        guard text.shouldChangeText(in: prefix, replacementString: "") else { return }
        storage.replaceCharacters(in: prefix, with: "")
        text.didChangeText()
        text.setSelectedRange(NSRange(location: prefix.location, length: 0))
        list(fmt)
    }

    // Toggles a list on the selected paragraphs (off if the first one already has this kind).
    func list(_ kind: NSTextList.MarkerFormat) {
        let fmt = kind == .decimal ? Notes.numbered : kind  // shows "1." like Apple Notes
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
        guard let li = listItem(at: sr.location) else { return headingReturn(sel, sr) }
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
