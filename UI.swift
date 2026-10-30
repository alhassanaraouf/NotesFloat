import Cocoa
import Carbon
import ServiceManagement

enum HotKey {
    static var ref: EventHotKeyRef?

    @discardableResult
    static func register() -> Bool {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        let d = UserDefaults.standard
        return RegisterEventHotKey(UInt32(d.integer(forKey: "hkCode")), UInt32(d.integer(forKey: "hkMods")),
                                   EventHotKeyID(signature: 0x4E464C54, id: 1), GetApplicationEventTarget(), 0, &ref) == noErr
    }
}

struct Item {
    var title = ""
    var subtitle = ""
    var icon = ""
    var shortcut = ""
    var destructive = false
    var enabled = true
    var divider = false
    var header = false
    var body = ""  // searched, not shown; a matching excerpt replaces the subtitle
    var run: () -> Void = {}
}

final class ClosureButton: NSButton {
    var run: () -> Void = {}
    @objc func fire() { run() }
}

// Quiet icon button: no chrome until hovered, like Raycast's toolbar.
func button(_ symbol: String, _ tip: String, _ run: @escaping () -> Void) -> NSButton {
    let b = ClosureButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: nil, action: nil)
    b.target = b
    b.action = #selector(ClosureButton.fire)
    b.run = run
    b.toolTip = tip
    b.bezelStyle = .accessoryBarAction
    b.showsBorderOnlyWhileMouseInside = true
    b.contentTintColor = .secondaryLabelColor
    b.symbolConfiguration = .init(pointSize: 13, weight: .medium)
    b.widthAnchor.constraint(equalToConstant: 28).isActive = true
    b.heightAnchor.constraint(equalToConstant: 26).isActive = true
    return b
}

final class ClickCatcher: NSView {
    var onClick: () -> Void = {}
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with e: NSEvent) { onClick() }
}

final class HoverView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with e: NSEvent) { onHover(true) }
    override func mouseExited(with e: NSEvent) { onHover(false) }
}

func keycaps(_ s: String) -> NSView {
    let stack = NSStackView()
    stack.spacing = 3
    stack.setHuggingPriority(.required, for: .horizontal)
    for ch in s {
        let l = NSTextField(labelWithString: String(ch))
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = .secondaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        box.addSubview(l)
        let snug = box.widthAnchor.constraint(equalToConstant: 20)  // keys stay square instead of stretching
        snug.priority = .defaultHigh
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 20),
            box.widthAnchor.constraint(greaterThanOrEqualTo: l.widthAnchor, constant: 10),
            snug,
            l.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            l.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        stack.addArrangedSubview(box)
    }
    return stack
}

func label(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    return l
}

// Raycast-style HUD: compact dark card with a colored icon badge; confirms an action, then fades. Click-through.
final class Toast: NSView {
    let icon = NSImageView()
    let badge = NSView()
    let text = label("", 12.5, .medium)
    var pending: DispatchWorkItem?
    var lift: NSLayoutConstraint?  // bottom offset; animated for a small slide-up

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)  // HUDs stay dark in light mode too
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        let card = NSVisualEffectView()
        card.material = .hudWindow
        card.state = .active
        card.blendingMode = .withinWindow
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        badge.wantsLayer = true
        badge.layer?.cornerRadius = 9
        icon.symbolConfiguration = .init(pointSize: 9.5, weight: .bold)
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)
        text.textColor = NSColor.white.withAlphaComponent(0.92)
        let row = NSStackView(views: [badge, text])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 9, bottom: 8, right: 13)
        for v in [row, card] { v.translatesAutoresizingMaskIntoConstraints = false }
        card.addSubview(row)
        addSubview(card)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 18), badge.heightAnchor.constraint(equalToConstant: 18),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor), icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            row.topAnchor.constraint(equalTo: card.topAnchor), row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor), row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    func show(_ message: String, _ symbol: String, _ tint: NSColor = .controlAccentColor) {
        text.stringValue = message
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        badge.layer?.backgroundColor = tint.cgColor
        if alphaValue == 0 { lift?.constant = -10 }
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.22
            $0.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            lift?.animator().constant = -18
        }
        pending?.cancel()
        let fade = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.3
                self?.animator().alphaValue = 0
                self?.lift?.animator().constant = -14
            }
        }
        pending = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: fade)
    }
}

// Rounded highlight that follows the mouse, Raycast-style.
final class RowView: NSTableRowView {
    var onHover: () -> Void = {}
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with e: NSEvent) { onHover() }
    override func drawSelection(in r: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

// Searchable command list (⌘K, notes, sub-menus). Lives in its own child window so it never resizes the note.
final class Switcher: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let field = NSTextField()
    let table = NSTableView()
    let empty = label("No results", 13, .regular, .secondaryLabelColor)
    let context = label("", 11, .medium, .tertiaryLabelColor)
    var all: [Item] = [], shown: [Item] = []
    var rowHeight: CGFloat = 34
    var onEmpty: ((String) -> Void)?
    var onClose: () -> Void = {}
    var onResize: (CGFloat) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.font = .systemFont(ofSize: 15)
        field.delegate = self
        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        glass.contentTintColor = .tertiaryLabelColor
        glass.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        let top = NSStackView(views: [glass, field])
        top.spacing = 10
        let lines = [NSBox(), NSBox()]
        lines.forEach { $0.boxType = .separator }
        table.addTableColumn(NSTableColumn(identifier: .init("n")))
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        let sv = NSScrollView()
        sv.documentView = table
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        let hints = label("↑↓ Navigate    ↵ Open    esc Close", 11, .medium, .tertiaryLabelColor)
        let bottom = NSStackView(views: [context, NSView(), hints])
        context.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [top, lines[0], sv, empty, lines[1], bottom] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor),
            top.heightAnchor.constraint(equalToConstant: 50),
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            lines[0].topAnchor.constraint(equalTo: top.bottomAnchor),
            lines[0].leadingAnchor.constraint(equalTo: leadingAnchor),
            lines[0].trailingAnchor.constraint(equalTo: trailingAnchor),
            sv.topAnchor.constraint(equalTo: lines[0].bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: lines[1].topAnchor),
            empty.centerXAnchor.constraint(equalTo: sv.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: sv.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: sv.widthAnchor, constant: -40),
            lines[1].leadingAnchor.constraint(equalTo: leadingAnchor),
            lines[1].trailingAnchor.constraint(equalTo: trailingAnchor),
            lines[1].bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 32),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func open(_ items: [Item], placeholder: String, context: String, rowHeight: CGFloat = 34, onEmpty: ((String) -> Void)? = nil) {
        all = items
        self.rowHeight = rowHeight
        self.onEmpty = onEmpty
        self.context.stringValue = context
        field.placeholderString = placeholder
        field.stringValue = ""
        filter()
    }

    func update(_ items: [Item]) {  // refresh in place, keeping the query
        all = items
        filter()
    }

    func ok(_ r: Int) -> Bool { shown.indices.contains(r) && !shown[r].divider && !shown[r].header && shown[r].enabled }

    func select(_ r: Int) {
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    func filter() {
        let q = field.stringValue
        if q.isEmpty {
            shown = all
        } else {  // title prefix, then title, then content matches
            let words = q.split(separator: " ").map(String.init)
            let hits: [Item] = all.compactMap { n in
                let head = n.title + " " + n.subtitle
                guard !n.divider, !n.header,
                      words.allSatisfy({ head.localizedStandardContains($0) || n.body.localizedStandardContains($0) }) else { return nil }
                var m = n
                if !words.allSatisfy({ head.localizedStandardContains($0) }),
                   let w = words.first(where: { !head.localizedStandardContains($0) }), let s = excerpt(n.body, w) { m.subtitle = s }
                return m
            }
            let ql = q.lowercased()
            shown = hits.filter { $0.title.lowercased().hasPrefix(ql) }
                + hits.filter { !$0.title.lowercased().hasPrefix(ql) && $0.title.localizedStandardContains(q) }
                + hits.filter { !$0.title.localizedStandardContains(q) }
        }
        table.reloadData()
        if let first = shown.indices.first(where: ok) { select(first) }
        empty.isHidden = !shown.isEmpty
        empty.stringValue = onEmpty == nil ? "No results" : q.isEmpty ? "No notes yet — ↵ creates one" : "No results — ↵ creates “\(q)”"
        let rows = shown.reduce(CGFloat(0)) { $0 + height($1) }
        onResize(51 + 12 + (shown.isEmpty ? 80 : rows) + 33)
    }

    func excerpt(_ body: String, _ word: String) -> String? {
        guard let r = body.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = body.index(r.lowerBound, offsetBy: -24, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(r.upperBound, offsetBy: 60, limitedBy: body.endIndex) ?? body.endIndex
        let mid = body[start..<end].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return (start > body.startIndex ? "…" : "") + mid + (end < body.endIndex ? "…" : "")
    }

    func height(_ i: Item) -> CGFloat { i.divider ? 9 : i.header ? 28 : rowHeight }

    func controlTextDidChange(_ n: Notification) { filter() }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(moveUp(_:)), #selector(moveDown(_:)):
            var r = table.selectedRow
            repeat { r += sel == #selector(moveUp(_:)) ? -1 : 1 } while shown.indices.contains(r) && !ok(r)
            if ok(r) { select(r) }
            return true
        case #selector(insertNewline(_:)):
            choose(table.selectedRow)
            return true
        default:
            return false
        }
    }

    @objc func clicked() { choose(table.clickedRow) }

    func choose(_ r: Int) {
        if ok(r) {
            let item = shown[r]
            onClose()
            item.run()
        } else if !shown.contains(where: { !$0.divider && !$0.header }), let onEmpty {
            onEmpty(field.stringValue)
        }
    }

    func numberOfRows(in t: NSTableView) -> Int { shown.count }
    func tableView(_ t: NSTableView, heightOfRow r: Int) -> CGFloat { height(shown[r]) }
    func tableView(_ t: NSTableView, shouldSelectRow r: Int) -> Bool { ok(r) }

    func tableView(_ t: NSTableView, rowViewForRow r: Int) -> NSTableRowView? {
        let v = RowView()
        v.onHover = { [unowned self] in if ok(r) && table.selectedRow != r { table.selectRowIndexes([r], byExtendingSelection: false) } }
        return v
    }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let n = shown[row]
        let cell = NSView()
        let content: NSView
        if n.divider {
            let box = NSBox()
            box.boxType = .separator
            content = box
        } else if n.header {
            content = label(n.title, 11, .semibold, .tertiaryLabelColor)
        } else {
            let tint: NSColor = n.destructive ? .systemRed : .labelColor
            let title = label(n.title.isEmpty ? "Untitled" : n.title, 13, .regular, tint)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let sub = label(n.subtitle, 11, .regular, .secondaryLabelColor)
            sub.isHidden = n.subtitle.isEmpty
            let text = NSStackView(views: [title, sub])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            text.setHuggingPriority(.defaultLow, for: .horizontal)
            let icon = NSImageView(image: NSImage(systemSymbolName: n.icon, accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            icon.contentTintColor = n.destructive ? .systemRed : .secondaryLabelColor
            icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
            let row = NSStackView(views: [icon, text, keycaps(n.shortcut)])
            row.spacing = 10
            row.alphaValue = n.enabled ? 1 : 0.35
            content = row
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            n.header ? content.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -5)
                     : content.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: n.divider ? 0 : 16),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: n.divider ? 0 : -16),
        ])
        return cell
    }
}

final class Settings: NSObject {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
    let rec = NSButton()
    let login = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    let access = NSTextField(wrappingLabelWithString: "")
    lazy var grant = NSButton(title: "Grant Full Disk Access…", target: self, action: #selector(openPrivacy))
    var monitor: Any?

    override init() {
        super.init()
        window.title = "Notes Float Settings"
        window.isReleasedWhenClosed = false
        window.level = .floating
        rec.bezelStyle = .rounded
        rec.target = self
        rec.action = #selector(record)
        login.target = self
        login.action = #selector(toggleLogin)
        access.font = .systemFont(ofSize: 11)
        access.textColor = .secondaryLabelColor
        access.preferredMaxLayoutWidth = 260
        let accessCol = NSStackView(views: [access, grant])
        accessCol.orientation = .vertical
        accessCol.alignment = .leading
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Shortcut:"), rec], [NSGridCell.emptyContentView, login],
                                      [NSTextField(labelWithString: "Checklists:"), accessCol]])
        grid.rowSpacing = 14
        let stack = NSStackView(views: [grid])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        window.contentView = stack
        window.center()
    }

    func show() {
        rec.title = UserDefaults.standard.string(forKey: "hkLabel") ?? ""
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let ok = Notes.canReadDB
        access.stringValue = ok ? "✓ Detected exactly. Only notes with checklists ask for ⌘E."
                                : "Without Full Disk Access every note with a list asks for ⌘E, since any list might be a checklist."
        grant.isHidden = ok
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func record() {
        guard monitor == nil else { return }
        rec.title = "Type shortcut… (Esc cancels)"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] e in
            let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if e.keyCode != 53 {
                guard !f.isDisjoint(with: [.command, .option, .control]) else { NSSound.beep(); return nil }
                let d = UserDefaults.standard
                let old = (d.integer(forKey: "hkCode"), d.integer(forKey: "hkMods"), d.string(forKey: "hkLabel"))
                var mods = 0
                if f.contains(.command) { mods |= cmdKey }
                if f.contains(.option) { mods |= optionKey }
                if f.contains(.control) { mods |= controlKey }
                if f.contains(.shift) { mods |= shiftKey }
                let key = e.characters(byApplyingModifiers: [])?.uppercased() ?? ""
                let label = (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "")
                    + (f.contains(.command) ? "⌘" : "") + (key == " " ? "Space" : key.isEmpty ? "#\(e.keyCode)" : key)
                d.set(Int(e.keyCode), forKey: "hkCode"); d.set(mods, forKey: "hkMods"); d.set(label, forKey: "hkLabel")
                if !HotKey.register() {  // taken by the system or another app: restore
                    d.set(old.0, forKey: "hkCode"); d.set(old.1, forKey: "hkMods"); d.set(old.2, forKey: "hkLabel")
                    HotKey.register()
                    NSSound.beep()
                }
            }
            NSEvent.removeMonitor(monitor!)
            monitor = nil
            rec.title = UserDefaults.standard.string(forKey: "hkLabel") ?? ""
            return nil
        }
    }

    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    @objc func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            NSAlert(error: error).runModal()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
