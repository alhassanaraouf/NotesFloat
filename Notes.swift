// Apple Notes bridge (AppleScript) + HTML <-> NSAttributedString in the subset Notes speaks.
import Cocoa
import SQLite3

struct NoteRef {
    let id, name, folder: String
    let date: Date
    var text = ""  // full plain text, for search
    var pinned = false  // pinned in Apple Notes
    var deleted = false  // in Recently Deleted
}
struct ListPara { let style: Int; let done: Bool }  // Notes paragraph style: 100 bullet, 101 dash, 102 number, 103 checklist
struct Block { let tag: String; let lists: [String]; let runs: [(String, [NSAttributedString.Key: Any])] }
struct NoteBody { let name: String; let date: Date; let attachments: Int; let locked: Bool; let html: String }

enum Notes {
    static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // ponytail: runs on the main thread; move off-main if libraries with thousands of notes feel laggy.
    static func run(_ src: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err { NSLog("Notes error: \(err)"); return nil }
        return r
    }

    @discardableResult
    static func tell(_ s: String) -> NSAppleEventDescriptor? { run("tell application \"Notes\"\n\(s)\nend tell") }

    // Database when readable (fast, has full text + pins); AppleScript otherwise.
    // ponytail: the database can lag Notes (unflushed deletes may still list as live until Notes writes them);
    // the database only has iCloud/On My Mac notes; legacy IMAP/Gmail notes only appear via the AppleScript path.
    static func list() -> [NoteRef] { dbList() ?? scriptList() }

    static func scriptList() -> [NoteRef] {
        guard let d = run("""
            on walk(f, out)
                tell application "Notes"
                    set end of out to {name of f, id of notes of f, name of notes of f, modification date of notes of f, plaintext of notes of f}
                    repeat with s in folders of f
                        my walk(s, out)
                    end repeat
                end tell
            end walk
            set out to {}
            tell application "Notes"
                repeat with a in accounts
                    repeat with f in folders of a
                        my walk(f, out)
                    end repeat
                end repeat
            end tell
            return out
            """) else { return [] }
        var seen = Set<String>(), out: [NoteRef] = []
        for i in stride(from: 1, through: d.numberOfItems, by: 1) {
            guard let f = d.atIndex(i), let folder = f.atIndex(1)?.stringValue,
                  let ids = f.atIndex(2), let names = f.atIndex(3), let dates = f.atIndex(4) else { continue }
            let texts = f.atIndex(5)
            for j in stride(from: 1, through: ids.numberOfItems, by: 1) {
                guard let id = ids.atIndex(j)?.stringValue, seen.insert(id).inserted else { continue }
                // ponytail: English folder name; the database path detects Recently Deleted by folder type instead.
                out.append(NoteRef(id: id, name: names.atIndex(j)?.stringValue ?? "", folder: folder,
                                   date: dates.atIndex(j)?.dateValue ?? .distantPast, text: texts?.atIndex(j)?.stringValue ?? "",
                                   deleted: folder == "Recently Deleted"))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    // One Apple Event (`properties`, ~12 ms) instead of one per property (~50 ms); record fields are read locally.
    static func load(_ id: String) -> NoteBody? {
        guard let d = tell("""
            set p to properties of note id \(q(id))
            if password protected of p then return {name of p, modification date of p, true, ""}
            return {name of p, modification date of p, false, body of p}
            """) ?? tell("""
            set n to note id \(q(id))
            if password protected of n then return {name of n, modification date of n, true, ""}
            return {name of n, modification date of n, false, body of n}
            """), d.numberOfItems == 4 else { return nil }
        let date = d.atIndex(2)?.dateValue ?? .distantPast
        let locked = d.atIndex(3)?.booleanValue ?? false
        // Attachments vanish if we rewrite the body, so an unknown count counts as "has attachments" (read-only).
        let attachments = locked ? 0 : attachmentCount(id, modified: date)
            ?? tell("count attachments of note id \(q(id))").map { Int($0.int32Value) } ?? 1
        return NoteBody(name: d.atIndex(1)?.stringValue ?? "", date: date, attachments: attachments, locked: locked,
                        html: d.atIndex(4)?.stringValue ?? "")
    }

    static func modDate(_ id: String) -> Date? { tell("get modification date of note id \(q(id))")?.dateValue }
    static func save(_ id: String, _ html: String) -> Bool { tell("set body of note id \(q(id)) to \(q(html))") != nil }
    static func create(_ html: String) -> String? { tell("get id of (make new note with properties {body:\(q(html))})")?.stringValue }
    static func delete(_ id: String) { tell("delete note id \(q(id))") }
    static func move(_ id: String, to folder: String) -> Bool { tell("move note id \(q(id)) to folder id \(q(folder))") != nil }

    static func folders() -> [(id: String, name: String)] {
        guard let ids = tell("get id of every folder"), let names = tell("get name of every folder") else { return [] }
        return stride(from: 1, through: ids.numberOfItems, by: 1).compactMap { i in
            guard let id = ids.atIndex(i)?.stringValue, let n = names.atIndex(i)?.stringValue, n != "Recently Deleted" else { return nil }
            return (id, n)
        }
    }

    // MARK: Apple Notes database (read-only; needs Full Disk Access)
    // AppleScript reports checklists as plain bullets, so whether a note has one, and Apple's own pins,
    // only exist in Notes' database. Every caller treats nil as "unknown" and stays on the safe path.

    static let dbPath = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"

    // "x-coredata://…/ICNote/p239" → 239 (the row's Z_PK)
    static func pk(_ id: String) -> Int? { id.split(separator: "/").last.flatMap { $0.hasPrefix("p") ? Int($0.dropFirst()) : nil } }

    static func query(_ sql: String, _ row: (OpaquePointer) -> Void) -> Bool {
        var db: OpaquePointer?, st: OpaquePointer?
        defer { sqlite3_finalize(st); sqlite3_close(db) }
        guard sqlite3_open_v2("file:\(dbPath)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return false }
        while sqlite3_step(st) == SQLITE_ROW { row(st) }
        return true
    }

    // Notes writes to its database lazily (an AppleScript delete was still unwritten minutes later), so a row older
    // than the modification date AppleScript reports may predate a newly added checklist: report "unknown" then.
    static func fresh(_ dbDate: Double, _ modified: Date) -> Bool { dbDate >= modified.timeIntervalSinceReferenceDate - 1 }

    static func hasChecklist(_ id: String, modified: Date) -> Bool? {
        guard let pk = pk(id) else { return nil }
        var found: Bool?
        _ = query("SELECT ZHASCHECKLIST, ZMODIFICATIONDATE1 FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = \(pk)") {
            if fresh(sqlite3_column_double($0, 1), modified) { found = sqlite3_column_int($0, 0) != 0 }
        }
        return found
    }

    // Matches AppleScript note ids: x-coredata://<store uuid>/ICNote/p<Z_PK>
    static let storeUUID: String? = {
        var u: String?
        _ = query("SELECT Z_UUID FROM Z_METADATA") { u = sqlite3_column_text($0, 0).map { String(cString: $0) } }
        return u
    }()

    static var textCache: [Int64: (modified: Double, text: String)] = [:]

    static func dbList() -> [NoteRef]? {
        guard let uuid = storeUUID else { return nil }
        var out: [NoteRef] = []
        let ok = query("""
            SELECT n.Z_PK, n.ZTITLE1, n.ZMODIFICATIONDATE1, f.ZTITLE2, f.ZFOLDERTYPE, n.ZISPINNED, n.ZISPASSWORDPROTECTED, d.ZDATA
            FROM ZICCLOUDSYNCINGOBJECT n
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER
            LEFT JOIN ZICNOTEDATA d ON d.Z_PK = n.ZNOTEDATA
            WHERE n.Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICNote') AND IFNULL(n.ZMARKEDFORDELETION, 0) = 0
              AND n.ZFOLDER IS NOT NULL AND IFNULL(n.ZNEEDSINITIALFETCHFROMCLOUD, 0) = 0  -- skip iCloud placeholders
            """) { st in
            let locked = sqlite3_column_int(st, 6) != 0
            let pk = sqlite3_column_int64(st, 0), modified = sqlite3_column_double(st, 2)
            var text = ""
            if let hit = textCache[pk], hit.modified == modified {  // decode only notes that changed
                text = hit.text
            } else if !locked, let blob = sqlite3_column_blob(st, 7) {  // locked notes are encrypted
                text = decode(Data(bytes: blob, count: Int(sqlite3_column_bytes(st, 7))))?.text ?? ""
                textCache[pk] = (modified, text)
            }
            out.append(NoteRef(id: "x-coredata://\(uuid)/ICNote/p\(sqlite3_column_int64(st, 0))",
                               name: sqlite3_column_text(st, 1).map { String(cString: $0) } ?? "",
                               folder: sqlite3_column_text(st, 3).map { String(cString: $0) } ?? "",
                               date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, 2)),
                               text: text.replacingOccurrences(of: "\u{FFFC}", with: ""),
                               pinned: sqlite3_column_int(st, 5) != 0,
                               deleted: sqlite3_column_int(st, 4) == 1))  // folder type 1 = Recently Deleted
        }
        return ok ? out.sorted { $0.date > $1.date } : nil
    }

    // List paragraphs (bullet/dash/number/checklist) in document order, with checklist ticks.
    // ~1 ms vs ~15 ms over AppleScript; nil when the row is stale or unreadable.
    static func attachmentCount(_ id: String, modified: Date) -> Int? {
        guard let pk = pk(id), let date = dbModDate(id), fresh(date, modified) else { return nil }
        var count: Int?
        _ = query("""
            SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZNOTE = \(pk) AND IFNULL(ZMARKEDFORDELETION, 0) = 0
              AND Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICAttachment')
            """) { count = Int(sqlite3_column_int($0, 0)) }
        return count
    }

    static func dbModDate(_ id: String) -> Double? {
        guard let pk = pk(id) else { return nil }
        var date: Double?
        _ = query("SELECT ZMODIFICATIONDATE1 FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = \(pk)") { date = sqlite3_column_double($0, 0) }
        return date
    }

    static func listParas(_ id: String, modified: Date) -> [ListPara]? {
        guard let pk = pk(id) else { return nil }
        var data: Data?
        _ = query("SELECT d.ZDATA, n.ZMODIFICATIONDATE1 FROM ZICCLOUDSYNCINGOBJECT n JOIN ZICNOTEDATA d ON d.Z_PK = n.ZNOTEDATA WHERE n.Z_PK = \(pk)") {
            if fresh(sqlite3_column_double($0, 1), modified), let b = sqlite3_column_blob($0, 0) {
                data = Data(bytes: b, count: Int(sqlite3_column_bytes($0, 0)))
            }
        }
        return data.flatMap(decode)?.paras.filter { (100...103).contains($0.style) }
    }

    // MARK: note body format: gzip → protobuf { 2: document { 3: note { 2: text, 5: runs { 1: length, 2: paragraph style {
    //   1: style type, 5: checklist { 2: done } } } } } }. Lengths are UTF-16 units.

    static func gunzip(_ d: Data) -> Data? {
        let b = [UInt8](d)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { i += 2 + Int(b[i]) + Int(b[i + 1]) << 8 }
        if flags & 8 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        return try? (Data(b[i..<(b.count - 8)]) as NSData).decompressed(using: .zlib) as Data  // .zlib = raw deflate
    }

    static func fields(_ b: [UInt8]) -> [(num: Int, int: UInt64, bytes: [UInt8])] {
        var out: [(Int, UInt64, [UInt8])] = [], i = 0
        func varint() -> UInt64? {
            var r: UInt64 = 0, shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let c = b[i]
                i += 1
                r |= UInt64(c & 0x7f) << shift
                if c < 0x80 { return r }
                shift += 7
            }
            return nil
        }
        while i < b.count, let key = varint() {
            switch key & 7 {
            case 0: guard let v = varint() else { return out }; out.append((Int(key >> 3), v, []))
            case 2:
                guard let n = varint(), n <= UInt64(b.count - i) else { return out }  // malformed length: stop, don't trap
                out.append((Int(key >> 3), 0, Array(b[i..<i + Int(n)])))
                i += Int(n)
            case 5: i += 4
            case 1: i += 8
            default: return out
            }
        }
        return out
    }

    static func decode(_ z: Data) -> (text: String, paras: [ListPara])? {
        guard let raw = gunzip(z),
              let doc = fields([UInt8](raw)).first(where: { $0.num == 2 }),
              let note = fields(doc.bytes).first(where: { $0.num == 3 }) else { return nil }
        let nf = fields(note.bytes)
        guard let t = nf.first(where: { $0.num == 2 }), let text = String(bytes: t.bytes, encoding: .utf8) else { return nil }
        var runs: [(end: Int, para: ListPara)] = [], pos = 0
        for r in nf where r.num == 5 {
            let rf = fields(r.bytes)
            var style = -1, done = false
            if let ps = rf.first(where: { $0.num == 2 }) {
                let pf = fields(ps.bytes)
                style = pf.first(where: { $0.num == 1 }).map { Int(truncatingIfNeeded: $0.int) } ?? -1
                if let cl = pf.first(where: { $0.num == 5 }) { done = (fields(cl.bytes).first(where: { $0.num == 2 })?.int ?? 0) != 0 }
            }
            pos += Int(clamping: rf.first(where: { $0.num == 1 })?.int ?? 0)
            runs.append((pos, ListPara(style: style, done: done)))
        }
        let ns = text as NSString
        var paras: [ListPara] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            paras.append(runs.first(where: { $0.end > r.location })?.para ?? ListPara(style: -1, done: false))
        }
        return (text, paras)
    }

    static var canReadDB: Bool { query("SELECT 1 FROM ZICCLOUDSYNCINGOBJECT LIMIT 1") { _ in } }

    // MARK: raw Apple Events, safe off the main thread (NSAppleScript isn't), used for background saves

    static func four(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

    // Object specifier for `<property code> of note id "<id>"`.
    static func noteProperty(_ id: String, _ code: String) -> NSAppleEventDescriptor {
        func spec(_ want: FourCharCode, _ from: NSAppleEventDescriptor, _ form: DescType, _ data: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
            let d = NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier))!
            d.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
            d.setDescriptor(from, forKeyword: AEKeyword(keyAEContainer))
            d.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
            d.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
            return d
        }
        let note = spec(four("note"), .null(), DescType(formUniqueID), NSAppleEventDescriptor(string: id))
        return spec(FourCharCode(cProperty), note, DescType(formPropertyID), NSAppleEventDescriptor(typeCode: four(code)))
    }

    // Sends get/set to Notes and returns the reply's result; nil on any send or Notes error.
    static func send(_ eventID: UInt32, _ direct: NSAppleEventDescriptor, data: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor? {
        let e = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(eventID),
                                       targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.Notes"),
                                       returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        e.setParam(direct, forKeyword: AEKeyword(keyDirectObject))
        if let data { e.setParam(data, forKeyword: AEKeyword(keyAEData)) }
        guard let reply = try? e.sendEvent(options: [.waitForReply], timeout: 15),
              (reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0) == 0 else { return nil }
        return reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? .null()
    }

    static func eventModDate(_ id: String) -> Date? { send(kAEGetData, noteProperty(id, "asmo"))?.dateValue }
    static func eventSave(_ id: String, _ html: String) -> Bool { send(kAESetData, noteProperty(id, "body"), data: NSAppleEventDescriptor(string: html)) != nil }

    // AppleScript's `container of note` fails (-1728): use the database when readable, else search the folders.
    static func folderID(of id: String) -> String? {
        if let pk = pk(id), let uuid = storeUUID {
            var folder: Int64?
            _ = query("SELECT ZFOLDER FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = \(pk)") {
                if sqlite3_column_type($0, 0) != SQLITE_NULL { folder = sqlite3_column_int64($0, 0) }
            }
            if let folder { return "x-coredata://\(uuid)/ICFolder/p\(folder)" }
        }
        return tell("""
            repeat with f in folders
                if (id of notes of f) contains \(q(id)) then return id of f
            end repeat
            """)?.stringValue
    }

    static func reveal(_ id: String) { tell("show note id \(q(id))\nactivate") }

    static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.15
        p.paragraphSpacing = 3
        return p
    }()

    // Sizes must match the thresholds in html(_:) below.
    static let css = "<meta charset=utf-8><style>body{font:14px -apple-system}h1{font-size:24px}h2{font-size:20px}h3{font-size:16px}h1,h2,h3{margin:0}tt{font:13px Menlo}</style>"

    static func attributed(_ html: String) -> NSAttributedString {
        let s = (try? NSMutableAttributedString(data: Data((css + html).utf8), options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)) ?? NSMutableAttributedString()
        if s.string.hasSuffix("\n") { s.deleteCharacters(in: NSRange(location: s.length - 1, length: 1)) }
        let all = NSRange(location: 0, length: s.length)
        s.removeAttribute(.backgroundColor, range: all)
        s.addAttribute(.foregroundColor, value: Theme.current.text, range: all)  // theme color (dynamic for light/dark)
        var numberedLists: [ObjectIdentifier: NSTextList] = [:]  // one replacement per imported list keeps items grouped
        s.enumerateAttribute(.paragraphStyle, in: all) { v, r, _ in  // display-only spacing; not serialized
            let ps = (v as? NSParagraphStyle ?? paragraph).mutableCopy() as! NSMutableParagraphStyle
            ps.lineHeightMultiple = paragraph.lineHeightMultiple
            ps.paragraphSpacing = paragraph.paragraphSpacing
            ps.textLists = ps.textLists.map { l in  // AppKit numbers "1"; Apple Notes shows "1."
                guard l.markerFormat == .decimal else { return l }
                if let n = numberedLists[ObjectIdentifier(l)] { return n }
                let n = NSTextList(markerFormat: numbered, options: 0)
                numberedLists[ObjectIdentifier(l)] = n
                return n
            }
            s.addAttribute(.paragraphStyle, value: ps, range: r)
        }
        for f in numberFixes(s).reversed() {
            s.replaceCharacters(in: f.range, with: NSAttributedString(string: f.marker, attributes: s.attributes(at: f.range.location, effectiveRange: nil)))
        }
        return s
    }

    static let numbered = NSTextList.MarkerFormat("{decimal}.")
    static func isNumbered(_ l: NSTextList) -> Bool { l.markerFormat == numbered || l.markerFormat == .decimal }

    // Numbered items whose "\t<n>.\t" marker is out of order, counting per list object (all items of one list share it).
    static func numberFixes(_ s: NSAttributedString) -> [(range: NSRange, marker: String)] {
        let ns = s.string as NSString
        var counters: [ObjectIdentifier: Int] = [:], fixes: [(range: NSRange, marker: String)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, p, _, _ in
            guard p.location < s.length, let l = (s.attribute(.paragraphStyle, at: p.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.last,
                  isNumbered(l) else { return }
            let n = (counters[ObjectIdentifier(l)] ?? 0) + 1
            counters[ObjectIdentifier(l)] = n
            let m = markerLength(ns, p), want = "\t\(l.marker(forItemNumber: n))\t"
            if m > 0, ns.substring(with: NSRange(location: p.location, length: m)) != want { fixes.append((NSRange(location: p.location, length: m), want)) }
        }
        return fixes
    }

    // One entry per paragraph: block tag, enclosing list types (outer→inner), styled runs without list markers.
    static func blocks(_ s: NSAttributedString) -> [Block] {
        let str = s.string as NSString
        var out: [Block] = []
        str.enumerateSubstrings(in: NSRange(location: 0, length: str.length), options: [.byParagraphs, .substringNotRequired]) { _, para, _, _ in
            var r = para
            let attrs = r.location < s.length ? s.attributes(at: r.location, effectiveRange: nil) : [:]
            let lists = ((attrs[.paragraphStyle] as? NSParagraphStyle)?.textLists ?? []).map { isNumbered($0) ? "ol" : "ul" }
            if !lists.isEmpty {  // strip the "\t•\t" marker
                let m = markerLength(str, r)
                r = NSRange(location: r.location + m, length: r.length - m)
            }
            let size = (attrs[.font] as? NSFont)?.pointSize ?? 14
            let tag = !lists.isEmpty ? "li" : size >= 22 ? "h1" : size >= 18 ? "h2" : size >= 15.5 ? "h3" : "div"
            var runs: [(String, [NSAttributedString.Key: Any])] = []
            s.enumerateAttributes(in: r) { a, run, _ in runs.append((str.substring(with: run), a)) }
            out.append(Block(tag: tag, lists: lists, runs: runs))
        }
        return out
    }

    // Length of a list paragraph's leading "\t•\t" / "\t12.\t" marker (0 if it has none).
    static func markerLength(_ ns: NSString, _ p: NSRange) -> Int {
        guard p.length > 1, ns.character(at: p.location) == 9 else { return 0 }
        let tab = ns.range(of: "\t", range: NSRange(location: p.location + 1, length: p.length - 1))
        return tab.location == NSNotFound ? 0 : tab.location + 1 - p.location
    }

    static func inline(_ text: String, _ a: [NSAttributedString.Key: Any], tag: String, md: Bool) -> String {
        var t = md ? text : esc(text)
        let f = a[.font] as? NSFont
        let traits = f.map { NSFontManager.shared.traits(of: $0) } ?? []
        let wrap = { (h: String, m: String) in t = md ? m + t + m : "<\(h)>\(t)</\(h)>" }
        if f?.isFixedPitch == true { wrap("tt", "`") }
        if traits.contains(.boldFontMask), tag == "div" || tag == "li" { wrap("b", "**") }
        if traits.contains(.italicFontMask) { wrap("i", "_") }
        if (a[.underlineStyle] as? Int ?? 0) != 0, a[.link] == nil, !md { wrap("u", "") }
        if (a[.strikethroughStyle] as? Int ?? 0) != 0 { wrap("strike", "~~") }
        if let l = a[.link] {
            let url = (l as? URL)?.absoluteString ?? "\(l)"
            t = md ? "[\(t)](\(url))" : "<a href=\"\(esc(url))\">\(t)</a>"
        }
        return t
    }

    static func html(_ s: NSAttributedString) -> String {
        var out = "", stack: [String] = []
        for b in blocks(s) {
            while !stack.isEmpty && (stack.count > b.lists.count || stack != Array(b.lists.prefix(stack.count))) { out += "</\(stack.removeLast())>" }
            while stack.count < b.lists.count { stack.append(b.lists[stack.count]); out += "<\(stack.last!)>" }
            let inner = b.runs.map { inline($0.0, $0.1, tag: b.tag, md: false) }.joined()
            out += "<\(b.tag)>\(inner.isEmpty ? "<br>" : inner)</\(b.tag)>"
        }
        out += stack.reversed().map { "</\($0)>" }.joined()
        return out.isEmpty ? "<div><br></div>" : out
    }

    static func markdown(_ s: NSAttributedString) -> String {
        blocks(s).map { b in
            let prefix = switch b.tag {
            case "h1": "# "
            case "h2": "## "
            case "h3": "### "
            case "li": String(repeating: "    ", count: b.lists.count - 1) + (b.lists.last == "ol" ? "1. " : "- ")
            default: ""
            }
            return prefix + b.runs.map { inline($0.0, $0.1, tag: b.tag, md: true) }.joined()
        }.joined(separator: "\n")
    }

    static func plain(_ s: NSAttributedString) -> String {
        blocks(s).map { b in
            (b.tag == "li" ? String(repeating: "    ", count: b.lists.count - 1) + "• " : "")
                + b.runs.map(\.0).joined()
        }.joined(separator: "\n")
    }
}

// Saves on a background queue so typing never waits on Apple Notes (~40 ms per save). Each save first checks the
// note wasn't changed elsewhere since our last load/save, then writes and records the new date. That state lives
// only on the queue, so back-to-back saves never mistake each other for outside changes.
final class Saver {
    enum Result { case saved(Date), conflict, failed }
    private let queue = DispatchQueue(label: "me.raoufs.alhassan.NotesFloat.save")
    private var known: [String: Date] = [:]  // touched only on `queue`

    func expect(_ id: String, _ date: Date) { queue.async { self.known[id] = date } }

    func save(_ id: String, _ html: String, wait: Bool = false, done: @escaping (Result) -> Void) {
        let job = {
            let result: Result
            if let expected = self.known[id], let now = Notes.eventModDate(id), now != expected {
                result = .conflict
            } else if Notes.eventSave(id, html), let date = Notes.eventModDate(id) {
                self.known[id] = date
                result = .saved(date)
            } else {
                result = .failed  // e.g. Notes isn't running: raw events can't launch it
            }
            DispatchQueue.main.async { done(result) }
        }
        wait ? queue.sync(execute: job) : queue.async(execute: job)
    }

    func flush() { queue.sync {} }
}
