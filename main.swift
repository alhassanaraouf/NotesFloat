// Raycast-Notes-style floating editor backed by Apple Notes.
// macOS has no API to make Notes' own window float, so we float our own panel and sync via AppleScript.
import Cocoa
import Carbon

class Panel: NSPanel { override var canBecomeKey: Bool { true } }

struct Cmd {
    let title: String
    let icon: String
    let key: String  // "⌃⌥⇧⌘" prefix + key, as built in the key monitor
    var destructive = false
    var enabled = true
    let run: () -> Void
    var label: String { key.replacingOccurrences(of: "=", with: "+").uppercased() }
}

final class App: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
                      styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    let text = NSTextView(usingTextLayoutManager: false)  // TextKit 1: list markers live in the text, like HTML import makes them
    let scroll = NSScrollView()
    let switcher = Switcher()
    // Lists/menus are an overlay inside the note window: a separate window would take key focus and flip the
    // note's glass to its grey inactive look on every open/close.
    let scrim = ClickCatcher()
    let popupView = NSView()
    var root: HoverView!
    var popupHeight: CGFloat = 0
    let settings = Settings()
    let onboarding = Onboarding()
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let titleLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let toast = Toast()
    var hiding = false
    var noteCache: [NoteRef] = []
    var browseToken: UUID?
    var dirty = false  // typed since last load/save
    var checklist: Bool?  // nil = couldn't read Notes' database
    lazy var shareButton = button("eye", "") { self.toggleSharing() }
    let toolbar = NSStackView()
    let formatBar = NSStackView()
    let body = NSFont.systemFont(ofSize: 14)
    let d = UserDefaults.standard

    var cur: (id: String, date: Date)?
    var name = ""
    var hard = false  // attachments/tables/images/locked: never write
    var soft = false  // may hold checklists/tags/colors AppleScript can't round-trip: write only after ⌘E
    var lastHTML = ""
    var timer: Timer?
    var back: [String] = [], fwd: [String] = []

    var readOnly: Bool { cur == nil || hard || soft }
    var popupOpen: Bool { !popupView.isHidden }
    var editable: Bool { !popupOpen && !readOnly }
    var pins: [String] { d.stringArray(forKey: "pinned") ?? [] }

    // MARK: commands (drive both the ⌘K panel and keyboard shortcuts)

    var sections: [(String, [Cmd])] {
        let pinned = cur.map { pins.contains($0.id) } ?? false
        let hidden = d.bool(forKey: "hideShare")
        return [
            ("Note", [Cmd(title: "New Note", icon: "plus", key: "⌘n") { self.newNote() },
             Cmd(title: "Duplicate Note", icon: "plus.square.on.square", key: "⌘d", enabled: cur != nil && !hard) { self.duplicate() },
             Cmd(title: pinned ? "Unpin Note" : "Pin Note", icon: pinned ? "pin.slash" : "pin", key: "⇧⌘p", enabled: cur != nil) { self.togglePin() },
             Cmd(title: "Browse Notes", icon: "rectangle.stack", key: "⌘p") { self.browse() },
             Cmd(title: "Reload from Apple Notes", icon: "arrow.clockwise", key: "⌘r", enabled: cur != nil) { self.reload() },
             Cmd(title: "Go Back", icon: "arrow.backward.circle", key: "⌘[", enabled: !back.isEmpty) { self.go(-1) },
             Cmd(title: "Go Forward", icon: "arrow.forward.circle", key: "⌘]", enabled: !fwd.isEmpty) { self.go(1) }]),
            ("Share", [Cmd(title: "Copy Note As…", icon: "doc.on.clipboard", key: "⇧⌘c", enabled: cur != nil) { self.copyAs() },
             Cmd(title: "Copy Deeplink", icon: "link", key: "⇧⌘d", enabled: cur != nil) { self.copyLink() },
             Cmd(title: "Export…", icon: "square.and.arrow.up", key: "⇧⌘e", enabled: cur != nil) { self.export() },
             Cmd(title: "Open in Apple Notes", icon: "arrow.up.forward.app", key: "⌘o", enabled: cur != nil) { self.reveal() }]),
            ("Edit", [Cmd(title: "Find in Note", icon: "text.magnifyingglass", key: "⌘f") { self.find() },
             Cmd(title: "Format…", icon: "textformat", key: "⇧⌘,", enabled: !readOnly) { self.formatMenu() },
             Cmd(title: "Move List Item Up", icon: "arrow.up", key: "⌃⌘↑", enabled: !readOnly) { self.moveLine(up: true) },
             Cmd(title: "Move List Item Down", icon: "arrow.down", key: "⌃⌘↓", enabled: !readOnly) { self.moveLine(up: false) },
             Cmd(title: "Move to Folder…", icon: "folder", key: "", enabled: cur != nil) { self.moveMenu() }]
                + (soft && !hard ? [Cmd(title: checklist == true ? "Edit Anyway (checklists become bullets)" : "Edit Anyway",
                                        icon: "lock.open", key: "⌘e") { self.unlock() }] : [])),
            ("View", [Cmd(title: hidden ? "Show While Screen Sharing" : "Hide While Screen Sharing", icon: "video.slash", key: "⌥⌘h") { self.toggleSharing() },
             Cmd(title: "Toggle Format Bar", icon: "textformat.size", key: "⌥⌘,") { self.toggleFormatBar() },
             Cmd(title: "Change Theme…", icon: "paintpalette", key: "") { self.themeMenu() },
             Cmd(title: "Actual Size", icon: "1.magnifyingglass", key: "⌘0", enabled: scroll.magnification != 1) { self.zoom(0) },
             Cmd(title: "Zoom In", icon: "plus.magnifyingglass", key: "⌘=") { self.zoom(1) },
             Cmd(title: "Zoom Out", icon: "minus.magnifyingglass", key: "⌘-") { self.zoom(-1) }]),
            ("App", [Cmd(title: "Settings", icon: "gearshape", key: "⌘,") { self.settings.show() },
                     Cmd(title: "Check for Updates…", icon: "arrow.down.circle", key: "") { Updates.shared.checkNow() },
                     Cmd(title: "Welcome Guide", icon: "hand.wave", key: "") { self.onboarding.show() },
                     Cmd(title: "Quit NotesFloat", icon: "power", key: "⌘q") { NSApp.terminate(nil) }]),
            ("Trash", [Cmd(title: "Show Recently Deleted Notes", icon: "trash", key: "") { self.deletedMenu() },
                       Cmd(title: "Delete Note", icon: "trash", key: "⌃x", destructive: true, enabled: cur != nil) { self.deleteNote() }]),
        ]
    }

    var formatCmds: [Cmd] {
        [Cmd(title: "Title", icon: "textformat.size.larger", key: "⇧⌘t") { self.block(24, bold: true) },
         Cmd(title: "Heading", icon: "textformat.size", key: "⇧⌘h") { self.block(20, bold: true) },
         Cmd(title: "Subheading", icon: "textformat.size.smaller", key: "⇧⌘j") { self.block(16, bold: true) },
         Cmd(title: "Body", icon: "text.alignleft", key: "⇧⌘b") { self.block(14, bold: false) },
         Cmd(title: "Monostyled", icon: "chevron.left.forwardslash.chevron.right", key: "⇧⌘m") { self.block(13, bold: false, mono: true) },
         Cmd(title: "Bold", icon: "bold", key: "⌘b") { self.trait(.boldFontMask) },
         Cmd(title: "Italic", icon: "italic", key: "⌘i") { self.trait(.italicFontMask) },
         Cmd(title: "Underline", icon: "underline", key: "⌘u") { self.toggle(.underlineStyle) },
         Cmd(title: "Strikethrough", icon: "strikethrough", key: "⇧⌘x") { self.toggle(.strikethroughStyle) },
         Cmd(title: "Bulleted List", icon: "list.bullet", key: "⇧⌘7") { self.list(.disc) },
         Cmd(title: "Dashed List", icon: "list.dash", key: "⇧⌘8") { self.list(.hyphen) },
         Cmd(title: "Numbered List", icon: "list.number", key: "⇧⌘9") { self.list(.decimal) },
         Cmd(title: "Add Link…", icon: "link.badge.plus", key: "⇧⌘k") { self.addLink() }]
    }

    // Shortcut-only: editing keys a menu bar would normally provide, plus aliases.
    var hiddenCmds: [Cmd] {
        [("⌘x", "cut:"), ("⌘c", "copy:"), ("⌘v", "pasteAsPlainText:"), ("⌘a", "selectAll:"), ("⌘z", "undo:"), ("⇧⌘z", "redo:")]
            .map { k, sel in Cmd(title: "", icon: "", key: k) { NSApp.sendAction(Selector(sel), to: nil, from: nil) } }
        + [Cmd(title: "", icon: "", key: "⌘k") { self.actions() },
           Cmd(title: "", icon: "", key: "⌥⌘f") { self.browse() },
           Cmd(title: "", icon: "", key: "⇧⌘=") { self.zoom(1) },
           Cmd(title: "", icon: "", key: "⌘w") { self.hide() },
           Cmd(title: "", icon: "", key: "⌘q") { NSApp.terminate(nil) }]
    }

    func items(_ cmds: [Cmd]) -> [Item] {
        cmds.map { c in Item(title: c.title, icon: c.icon, shortcut: c.label, destructive: c.destructive, enabled: c.enabled, run: c.run) }
    }

    // MARK: setup

    func glass(_ content: NSView, radius: CGFloat) -> NSGlassEffectView {
        let g = NSGlassEffectView()
        g.cornerRadius = radius
        g.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55)  // keeps text legible over bright wallpapers
        g.contentView = content
        return g
    }

    // Glass clipped to a rounded shape, so the borderless window's shadow follows the corners instead of a rectangle.
    func rounded(_ content: NSView, radius: CGFloat) -> NSView {
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = radius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        let g = glass(content, radius: radius)
        g.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(g)
        NSLayoutConstraint.activate([
            g.topAnchor.constraint(equalTo: clip.topAnchor), g.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            g.leadingAnchor.constraint(equalTo: clip.leadingAnchor), g.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])
        return clip
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = d.bool(forKey: "hideShare") ? .none : .readOnly
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 300, height: 220)
        panel.center()
        panel.setFrameAutosaveName("NotesFloatWindow")

        root = HoverView()
        panel.contentView = rounded(root, radius: 18)
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [unowned self] _ in
            panel.invalidateShadow()
            if popupOpen { placePopup(height: popupHeight) }
        }
        switcher.onClose = { [unowned self] in closeSwitcher() }
        switcher.onResize = { [unowned self] h in placePopup(height: h) }

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let left = button("sidebar.left", "Browse Notes  ⌘P") { self.browse() }
        let right = NSStackView(views: [button("square.and.pencil", "New Note  ⌘N") { self.newNote() },
                                        button("ellipsis.circle", "Actions  ⌘K") { self.actions() }])
        right.spacing = 2
        let center = NSStackView(views: [shareButton, titleLabel])  // share state stays visible, not just on hover
        center.spacing = 0
        for v in [left, center, right] { toolbar.addArrangedSubview(v) }
        updateShareButton()
        toolbar.distribution = .equalCentering
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 2, right: 10)
        // Fixed heights: the vertical column otherwise squeezes the bar to its label height and the 26pt buttons
        // overflow past the window's top edge (worse with the screen-sharing eye shown in the nested center stack).
        toolbar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        center.heightAnchor.constraint(equalToConstant: 26).isActive = true
        left.alphaValue = 0
        right.alphaValue = 0
        root.onHover = { inside in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                left.animator().alphaValue = inside ? 1 : 0
                right.animator().alphaValue = inside ? 1 : 0
            }
        }

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.allowsMagnification = true
        scroll.magnification = d.object(forKey: "zoom") as? CGFloat ?? 1
        scroll.documentView = text
        // Zoom = magnify + keep the text view as wide as the visible area, so text re-wraps instead of overflowing.
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: scroll.contentView, queue: .main) { [unowned self] _ in fitWidth() }
        }
        text.isVerticallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.isRichText = true
        text.importsGraphics = false
        text.allowsUndo = true
        text.usesFindBar = true
        text.drawsBackground = false
        text.font = body
        text.textColor = .textColor
        text.textContainerInset = NSSize(width: 22, height: 10)
        text.defaultParagraphStyle = Notes.paragraph
        text.delegate = self

        let fmt: [(String, String, () -> Void)] = [
            ("textformat", "Format…  ⇧⌘,", { self.formatMenu() }), ("bold", "Bold  ⌘B", { self.trait(.boldFontMask) }),
            ("italic", "Italic  ⌘I", { self.trait(.italicFontMask) }), ("underline", "Underline  ⌘U", { self.toggle(.underlineStyle) }),
            ("strikethrough", "Strikethrough  ⇧⌘X", { self.toggle(.strikethroughStyle) }), ("list.bullet", "Bulleted List  ⇧⌘7", { self.list(.disc) }),
            ("list.dash", "Dashed List  ⇧⌘8", { self.list(.hyphen) }), ("list.number", "Numbered List  ⇧⌘9", { self.list(.decimal) }),
            ("link", "Add Link  ⇧⌘K", { self.addLink() }),
        ]
        for (icon, tip, run) in fmt { formatBar.addArrangedSubview(button(icon, tip, run)) }
        formatBar.spacing = 2
        formatBar.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 8, right: 12)
        formatBar.isHidden = !(d.object(forKey: "formatBar") as? Bool ?? true)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail

        let column = NSStackView(views: [toolbar, scroll, statusLabel, formatBar])
        column.orientation = .vertical
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        for v in [toolbar, scroll] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        toast.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            { toast.lift = toast.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -22); return toast.lift! }(),
            toast.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),
        ])
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor), column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor), column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] e in
            guard e.window === panel else { return e }
            if e.keyCode == 53 { popupOpen ? closeSwitcher() : hide(); return nil }  // Esc
            let f = e.modifierFlags
            if readOnly, cur != nil, e.window === panel, panel.firstResponder === text, f.isDisjoint(with: [.command, .control]),
               e.characters?.isEmpty == false, ![123, 124, 125, 126, 115, 119, 116, 121].contains(e.keyCode) {  // typing, not navigating
                hard ? toast.show("Read-only here — ⌘O to edit in Apple Notes", "lock.fill", .systemOrange)
                     : toast.show(checklist == true ? "Has checklists — ⌘E to edit anyway" : "Protected — ⌘E to edit anyway", "lock.fill", .systemOrange)
                return nil
            }
            guard f.contains(.command) || f.contains(.control) else { return e }
            let key = switch e.keyCode {
            case 51: "⌫"
            case 126: "↑"
            case 125: "↓"
            default: e.characters(byApplyingModifiers: [])?.lowercased() ?? ""
            }
            let k = (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "")
                + (f.contains(.command) ? "⌘" : "") + key
            guard let c = (hiddenCmds + formatCmds + sections.flatMap(\.1)).first(where: { $0.key == k }) else { return e }
            if c.enabled {
                let editKey = ["⌘x", "⌘c", "⌘v", "⌘a", "⌘z", "⇧⌘z"].contains(k)
                if popupOpen && !editKey { closeSwitcher() }
                c.run()
            } else {
                toast.show(c.title.isEmpty ? "Not available here" : "\(c.title) isn't available here", "nosign", .systemOrange)
            }
            return nil
        }

        // Overlay: a click-catcher over the note (click outside = close) and the list card above it.
        scrim.frame = root.bounds
        scrim.autoresizingMask = [.width, .height]
        scrim.onClick = { [unowned self] in closeSwitcher() }
        let card = NSVisualEffectView()
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        card.autoresizingMask = [.width, .height]
        switcher.frame = card.bounds
        switcher.autoresizingMask = [.width, .height]
        card.addSubview(switcher)
        popupView.wantsLayer = true
        popupView.layer?.shadowColor = NSColor.black.cgColor
        popupView.layer?.shadowOpacity = 0.3
        popupView.layer?.shadowRadius = 16
        popupView.layer?.shadowOffset = CGSize(width: 0, height: -6)
        popupView.addSubview(card)
        for v in [scrim, popupView] { v.isHidden = true; root.addSubview(v) }

        status.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "NotesFloat")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show NotesFloat", action: #selector(showFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NotesFloat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        status.menu = menu

        HotKey.register()
        // Pick up edits made in Apple Notes: on focus, and every few seconds while visible.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [unowned self] _ in
            syncFromNotes(force: true)
        }
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [unowned self] _ in syncFromNotes() }
        // The first HTML import loads WebKit (~230 ms); pay that now instead of on the first hotkey press.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = Notes.attributed("<div>warm-up</div>") }
        _ = Updates.shared.controller  // starts Sparkle's scheduled checks
        settings.onTheme = { [unowned self] in applyTheme() }
        settings.onWelcome = { [unowned self] in onboarding.show() }
        onboarding.onFinish = { [unowned self] in show() }
        applyTheme()
        if !d.bool(forKey: "onboarded") { onboarding.show() }  // first run: permissions before anything touches Notes
    }

    @objc func showFromMenu() { show() }
    @objc func showSettings() { settings.show() }
    @objc func checkUpdates() { Updates.shared.checkNow() }

    func themeMenu() {
        present(Theme.all.map { t in
            Item(title: t.name, icon: t.id == Theme.current.id ? "checkmark.circle.fill" : "circle") {
                self.d.set(t.id, forKey: "theme")
                self.applyTheme()
                self.toast.show("\(t.name) theme", "paintpalette")
            }
        }, placeholder: "Choose a theme…")
    }

    func applyTheme() {
        let t = Theme.current
        panel.appearance = t.appearance.map { NSAppearance(named: $0)! }
        root.fill = t.background
        text.insertionPointColor = t.accent
        text.selectedTextAttributes = [.backgroundColor: t.accent.withAlphaComponent(0.3)]
        text.linkTextAttributes = [.foregroundColor: t.accent, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        text.typingAttributes[.foregroundColor] = t.text
        if let c = cur, !hard { reopenInPlace(c.id) }  // re-render existing text in the theme's colors
    }

    func application(_ app: NSApplication, open urls: [URL]) {  // notesfloat://open?id=…
        guard let id = urls.first.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })?
            .queryItems?.first(where: { $0.name == "id" })?.value else { return }
        open(id)
        show()
    }

    // MARK: panel

    func togglePanel() { panel.isKeyWindow || popupOpen ? hide() : show() }

    func show() {
        if let c = cur {
            if !panel.isVisible, Notes.modDate(c.id) != c.date { open(c.id, record: false) }  // pick up edits made elsewhere
        } else {
            openLast()
        }
        hiding = false
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(text)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 1 }) { [self] in panel.invalidateShadow() }
    }

    func hide() {
        closeSwitcher()
        save()
        hiding = true
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) { [self] in
            if hiding { panel.orderOut(nil); panel.alphaValue = 1 }
        }
    }

    // Every list (notes, actions, sub-menus) goes through here.
    var popupKind = ""  // "actions" / "notes" / "" for sub-menus, so toolbar buttons can toggle their own popup
    var lastClosed = (kind: "", at: Date.distantPast)

    // ⌘K/⌘P while open: the key monitor closes the popup just before the action runs,
    // so "closed a moment ago by this same command" counts as open → stay closed.
    func toggling(_ kind: String) -> Bool {
        if popupOpen && popupKind == kind { closeSwitcher(); return true }
        return lastClosed.kind == kind && Date().timeIntervalSince(lastClosed.at) < 0.3
    }

    func present(_ items: [Item], placeholder: String, rowHeight: CGFloat = 34, kind: String = "", onEmpty: ((String) -> Void)? = nil) {
        popupKind = kind
        browseToken = nil
        switcher.open(items, placeholder: placeholder, context: cur == nil ? "NotesFloat" : name,
                      rowHeight: rowHeight, onEmpty: onEmpty)  // calls placePopup via onResize
        if !popupOpen {
            scrim.isHidden = false
            popupView.isHidden = false
            popupView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; popupView.animator().alphaValue = 1 }
        }
        panel.makeFirstResponder(switcher.field)
    }

    // Manual frames (no constraints), capped to the window, so the overlay can never resize the window.
    func placePopup(height: CGFloat) {
        popupHeight = height
        let b = root.bounds
        let h = min(height, b.height - 48)
        popupView.frame = NSRect(x: 10, y: b.height - 40 - h, width: b.width - 20, height: h)
    }

    func closeSwitcher() {
        guard popupOpen else { return }
        lastClosed = (popupKind, Date())
        scrim.isHidden = true
        popupView.isHidden = true
        panel.makeFirstResponder(text)
    }

    func fitWidth() {
        let w = scroll.contentView.bounds.width
        if abs(text.frame.width - w) > 0.5 { text.setFrameSize(NSSize(width: w, height: text.frame.height)) }
    }

    func actions() {
        if toggling("actions") { return }
        present(sections.flatMap { [Item(title: $0.0, header: true)] + items($0.1) }, placeholder: "Search for actions…", kind: "actions")
    }

    // Opens instantly from the last fetch, then refreshes in place.
    func browse(deleted: Bool = false) {
        if !deleted, toggling("notes") { return }
        save()
        let local = Set(pins)
        let rel = RelativeDateTimeFormatter(), current = cur?.id
        let make = { (all: [NoteRef]) -> [Item] in
            // ponytail: English folder name only; localized "Recently Deleted" folders show up in Browse.
            let notes = all.filter { $0.deleted == deleted }
            let p = local.union(notes.filter(\.pinned).map(\.id))  // ours + Apple Notes' pins
            return (notes.filter { p.contains($0.id) } + notes.filter { !p.contains($0.id) }).map { n in
                Item(title: n.name,
                     subtitle: (n.id == current ? "Open now  ·  " : "") + "\(n.folder)  ·  \(rel.localizedString(for: n.date, relativeTo: Date()))",
                     icon: p.contains(n.id) ? "pin.fill" : "note.text", body: n.text) { self.open(n.id) }
            }
        }
        if noteCache.isEmpty { noteCache = Notes.list() }
        present(make(noteCache), placeholder: deleted ? "Search recently deleted…" : "Search notes…", rowHeight: 46, kind: deleted ? "" : "notes",
                onEmpty: deleted ? nil : { [unowned self] q in newNote(q) })
        let token = UUID()
        browseToken = token
        DispatchQueue.main.async { [self] in
            noteCache = Notes.list()
            if popupOpen, browseToken == token { switcher.update(make(noteCache)) }
        }
    }

    func deletedMenu() { browse(deleted: true) }

    func formatMenu() { present(items(formatCmds), placeholder: "Format…") }

    func copyAs() {
        let s = text.attributedString()
        let put = { [self] (str: String, kind: String) in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
            toast.show("Copied as \(kind)", "doc.on.clipboard")
        }
        present([Item(title: "Markdown", icon: "text.document") { put(Notes.markdown(s), "Markdown") },
                       Item(title: "Plain Text", icon: "doc.plaintext") { put(Notes.plain(s), "Plain Text") },
                       Item(title: "HTML", icon: "chevron.left.forwardslash.chevron.right") { put(Notes.html(s), "HTML") }],
                      placeholder: "Copy note as…")
    }

    func export() {
        let s = text.attributedString()
        present([Item(title: "Markdown (.md)", icon: "text.document") { self.write(Data(Notes.markdown(s).utf8), "md") },
                       Item(title: "Plain Text (.txt)", icon: "doc.plaintext") { self.write(Data(Notes.plain(s).utf8), "txt") },
                       Item(title: "PDF", icon: "doc.richtext") { self.write(self.pdf(), "pdf") }],
                      placeholder: "Export as…")
    }

    func moveMenu() {
        guard let c = cur else { return }
        present(Notes.folders().map { f in
            Item(title: f.name, icon: "folder") {
                Notes.move(c.id, to: f.id) ? self.toast.show("Moved to \(f.name)", "folder")
                                           : self.toast.show("Couldn't move the note", "exclamationmark.triangle.fill", .systemRed)
            }
        }, placeholder: "Move to folder…")
    }

    // MARK: notes

    @discardableResult
    func open(_ id: String, selectTitle: Bool = false, record: Bool = true) -> Bool {
        save()
        guard let n = Notes.load(id) else { return false }
        if record, let c = cur, c.id != id { back.append(c.id); fwd = [] }
        d.set(id, forKey: "noteID")
        cur = (id, n.date)
        name = n.name
        hard = n.locked || n.attachments > 0
            || n.html.range(of: "<(img|table|object)", options: [.regularExpression, .caseInsensitive]) != nil
        // Checklists come from Notes' database when we can read it; otherwise any list might be one.
        checklist = Notes.hasChecklist(id, modified: n.date)
        let listRisk = checklist ?? (n.html.range(of: "<ul", options: .caseInsensitive) != nil)
        soft = !(d.stringArray(forKey: "unlocked") ?? []).contains(id) && !wroteLast(id, n.date)
            && (listRisk || n.html.range(of: #"class=|color[:=]|(^|[\s>])#\w"#, options: .regularExpression) != nil)
        text.textStorage!.setAttributedString(n.locked
            ? NSAttributedString(string: "🔒 This note is locked. ⌘O opens it in Notes.", attributes: [.font: body, .foregroundColor: Theme.current.text])
            : Notes.attributed(n.html))
        lastHTML = Notes.html(text.attributedString())  // baseline: untouched notes are never rewritten
        dirty = false
        if !n.locked { liveTitle() }
        if checklist == true { showChecklists(id, modified: n.date) }
        text.undoManager?.removeAllActions()
        applyMode()
        let firstLine = (text.string as NSString).range(of: "\n").location
        text.setSelectedRange(NSRange(location: 0, length: selectTitle ? (firstLine == NSNotFound ? (text.string as NSString).length : firstLine) : 0))
        return true
    }

    func openLast() {
        if let id = d.string(forKey: "noteID"), open(id, record: false) { return }
        if let n = Notes.list().first(where: { !$0.deleted }), open(n.id, record: false) { return }
        if newNote(announce: false) { return }
        cur = nil
        text.textStorage!.setAttributedString(NSAttributedString(
            string: "Can't reach Apple Notes.\nAllow NotesFloat in System Settings › Privacy & Security › Automation, then reopen.",
            attributes: [.font: body, .foregroundColor: Theme.current.text]))
        applyMode()
    }

    @discardableResult
    func newNote(_ title: String = "", announce: Bool = true) -> Bool {
        guard let id = Notes.create("<h1>\(Notes.esc(title.isEmpty ? "New Note" : title))</h1>") else {
            if announce { toast.show("Couldn't create a note", "exclamationmark.triangle.fill", .systemRed) }
            return false
        }
        closeSwitcher()
        markWritten(id, Notes.modDate(id))
        let ok = open(id, selectTitle: title.isEmpty)
        if announce { toast.show("Note created", "square.and.pencil") }
        return ok
    }

    func duplicate() {
        save()
        guard let id = Notes.create(Notes.html(text.attributedString())) else {
            return toast.show("Couldn't duplicate the note", "exclamationmark.triangle.fill", .systemRed)
        }
        if !soft { markWritten(id, Notes.modDate(id)) }  // a soft-locked original may hide checklists
        open(id)
        toast.show("Note duplicated", "plus.square.on.square")
    }

    func deleteNote() {  // goes to Notes' Recently Deleted, recoverable for 30 days
        guard let c = cur else { return }
        timer?.invalidate()
        cur = nil
        d.removeObject(forKey: "noteID")
        Notes.delete(c.id)
        back.removeAll { $0 == c.id }
        noteCache.removeAll { $0.id == c.id }
        openLast()
        toast.show("Moved to Recently Deleted", "trash.fill", .systemRed)
    }

    func go(_ dir: Int) {
        guard let c = cur, let id = dir < 0 ? back.popLast() : fwd.popLast() else { return }
        if dir < 0 { fwd.append(c.id) } else { back.append(c.id) }
        open(id, record: false)
    }

    func togglePin() {
        guard let c = cur else { return }
        let pinned = pins.contains(c.id)
        d.set(pinned ? pins.filter { $0 != c.id } : pins + [c.id], forKey: "pinned")
        toast.show(pinned ? "Unpinned" : "Pinned to top of list", pinned ? "pin.slash" : "pin.fill")
    }

    func reveal() {
        guard let c = cur else { return }
        hide()
        Notes.reveal(c.id)
    }

    func unlock() {
        guard let c = cur, soft, !hard else { return }
        d.set((d.stringArray(forKey: "unlocked") ?? []) + [c.id], forKey: "unlocked")
        soft = false
        applyMode()
        toast.show("Editing enabled", "lock.open.fill")
    }

    func copyLink() {
        guard let c = cur, let id = c.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("notesfloat://open?id=\(id)", forType: .string)
        toast.show("Deeplink copied", "link")
    }

    func toggleSharing() {
        d.set(!d.bool(forKey: "hideShare"), forKey: "hideShare")
        panel.sharingType = d.bool(forKey: "hideShare") ? .none : .readOnly
        updateShareButton()
        d.bool(forKey: "hideShare") ? toast.show("Hidden from screen sharing", "eye.slash.fill", .controlAccentColor)
                                    : toast.show("Visible in screen sharing", "eye")
    }

    func updateShareButton() {
        let hidden = d.bool(forKey: "hideShare")
        shareButton.image = NSImage(systemSymbolName: hidden ? "eye.slash.fill" : "eye", accessibilityDescription: nil)
        shareButton.contentTintColor = hidden ? .controlAccentColor : .tertiaryLabelColor
        shareButton.toolTip = "Hidden from screen sharing — click to show  ⌥⌘H"
        shareButton.isHidden = !hidden  // visible-to-sharing is the default; only flag the exception
    }

    func toggleFormatBar() {
        formatBar.isHidden.toggle()
        d.set(!formatBar.isHidden, forKey: "formatBar")
    }

    func zoom(_ step: Int) {
        scroll.magnification = step == 0 ? 1 : max(0.6, min(2.5, scroll.magnification + CGFloat(step) * 0.1))
        d.set(scroll.magnification, forKey: "zoom")
        fitWidth()
        toast.show("Zoom \(Int((scroll.magnification * 100).rounded()))%", "magnifyingglass")
    }

    func write(_ data: Data, _ ext: String) {
        let p = NSSavePanel()
        p.nameFieldStringValue = (name.isEmpty ? "Note" : name) + "." + ext
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            try data.write(to: url)
            toast.show("Exported \(url.lastPathComponent)", "square.and.arrow.up")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // ponytail: one tall PDF page; paginate via NSPrintOperation if people print these.
    func pdf() -> Data {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 10))
        tv.appearance = NSAppearance(named: .aqua)  // dark text on white regardless of system theme
        tv.textContainerInset = NSSize(width: 36, height: 36)
        tv.textStorage!.setAttributedString(text.attributedString())
        tv.isVerticallyResizable = true
        tv.sizeToFit()
        return tv.dataWithPDF(inside: tv.bounds)
    }

    func applyMode() {
        text.isEditable = !readOnly
        panel.title = cur == nil ? "NotesFloat" : name
        titleLabel.stringValue = panel.title
        updateFooter()
    }

    func updateFooter() {
        statusLabel.stringValue = hard ? "Read-only  ·  ⌘O Open in Apple Notes"
            : !soft ? ""
            : checklist == true ? "Has checklists — editing turns them into bullets  ·  ⌘E Edit anyway"
            : checklist == nil ? "May contain checklists  ·  ⌘E Edit anyway"
            : "Has tags or colors this editor can't keep  ·  ⌘E Edit anyway"
    }

    // Checklists can only come from Apple Notes itself, which would bump the date; if we wrote last, it has none.
    func markWritten(_ id: String, _ date: Date?) {
        guard let date else { return }
        var own = d.dictionary(forKey: "written") as? [String: Double] ?? [:]
        own[id] = date.timeIntervalSince1970
        d.set(own, forKey: "written")
    }

    func wroteLast(_ id: String, _ date: Date) -> Bool {
        (d.dictionary(forKey: "written") as? [String: Double])?[id] == date.timeIntervalSince1970
    }

    // Apple Notes names a note after its first line; mirror that while typing.
    func liveTitle() {
        let first = (text.string.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        name = first.isEmpty ? "New Note" : first
        panel.title = name
        titleLabel.stringValue = name
    }

    // Draw checklist items as ☐/☑ using Notes' database (AppleScript reports them as bullets). Display only:
    // the marker is stripped on save like any list marker, and checklist notes stay locked until ⌘E.
    func showChecklists(_ id: String, modified: Date) {
        guard let paras = Notes.listParas(id, modified: modified) else { return }
        let st = text.textStorage!, ns = st.string as NSString
        var markers: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, p, _, _ in
            guard p.location < st.length,
                  (st.attribute(.paragraphStyle, at: p.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.isEmpty == false else { return }
            var m = NSRange(location: p.location, length: 0)
            if p.length > 1, ns.character(at: p.location) == 9 {
                let tab = ns.range(of: "\t", range: NSRange(location: p.location + 1, length: p.length - 1))
                if tab.location != NSNotFound { m.length = tab.location + 1 - p.location }
            }
            markers.append(m)
        }
        guard markers.count == paras.count else { return }  // layouts disagree: keep plain bullets rather than guess
        for (m, p) in zip(markers, paras).reversed() where p.style == 103 && m.length > 0 {
            var a = st.attributes(at: m.location, effectiveRange: nil)
            a[.foregroundColor] = p.done ? Theme.current.accent : NSColor.secondaryLabelColor
            st.replaceCharacters(in: m, with: NSAttributedString(string: "\t\(p.done ? "☑" : "☐")\t", attributes: a))
        }
    }

    // Re-read the note, keeping the caret and scroll position.
    func reopenInPlace(_ id: String) {
        let sel = text.selectedRange(), origin = scroll.contentView.bounds.origin
        guard open(id, record: false) else { return }
        let len = (text.string as NSString).length
        text.setSelectedRange(NSRange(location: min(sel.location, len), length: min(sel.length, len - min(sel.location, len))))
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func reload() {
        guard let c = cur else { return }
        save()  // if Notes changed meanwhile, save() already took Notes' version
        reopenInPlace(c.id)
        toast.show("Reloaded from Apple Notes", "arrow.clockwise")
    }

    // Polls cheaply: with database access, only ask Apple Notes (~12 ms, wakes Notes) when the note's row changed (~1 ms).
    // ponytail: edits Notes hasn't written to disk yet wait for the next write; focusing the window (force) asks anyway.
    var lastPolledDB: Double?
    func syncFromNotes(force: Bool = false) {
        guard panel.isVisible, !popupOpen, !dirty, let c = cur else { return }
        if !force, let db = Notes.dbModDate(c.id) {
            if db == lastPolledDB { return }
            lastPolledDB = db
        }
        guard
              !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty,  // don't relaunch Notes
              let date = Notes.modDate(c.id), date != c.date else { return }
        reopenInPlace(c.id)
        toast.show("Updated from Apple Notes", "arrow.triangle.2.circlepath")
    }

    func save() {
        timer?.invalidate()
        guard let c = cur, !readOnly else { return }
        let html = Notes.html(text.attributedString())
        guard html != lastHTML else { return }
        if let d = Notes.modDate(c.id), d != c.date {
            // ponytail: edited elsewhere since we loaded; Notes wins and unsaved local typing (<1s) is dropped.
            cur = nil
            open(c.id, record: false)
            toast.show("Updated from Apple Notes", "arrow.triangle.2.circlepath")
            return
        }
        guard Notes.save(c.id, html), let d = Notes.modDate(c.id) else {
            return toast.show("Couldn't save — is Apple Notes running?", "exclamationmark.triangle.fill", .systemRed)
        }
        cur = (c.id, d)
        lastHTML = html
        dirty = false
        if let i = noteCache.firstIndex(where: { $0.id == c.id }) {
            noteCache[i] = NoteRef(id: c.id, name: name, folder: noteCache[i].folder, date: d)
        }
        markWritten(c.id, d)
    }

    func textDidChange(_ n: Notification) {
        dirty = true
        liveTitle()
        timer?.invalidate()
        timer = .scheduledTimer(withTimeInterval: 0.8, repeats: false) { [unowned self] _ in save() }
    }

    func applicationWillTerminate(_ n: Notification) { save() }

    // MARK: Apple Notes-style list typing

    // List paragraph at `loc`: its range, the length of its "\t•\t" marker, and its list.
    func listItem(at loc: Int) -> (para: NSRange, marker: Int, list: NSTextList)? {
        let ns = text.string as NSString, st = text.textStorage!
        let p = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        guard p.location < st.length, let l = (st.attribute(.paragraphStyle, at: p.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.last
        else { return nil }
        var marker = 0
        if p.length > 1, ns.character(at: p.location) == 9 {
            let tab = ns.range(of: "\t", range: NSRange(location: p.location + 1, length: p.length - 1))
            if tab.location != NSNotFound { marker = tab.location + 1 - p.location }
        }
        return (p, marker, l)
    }

    // "- " → dashed, "* " → bulleted, "1. " → numbered, at the start of a line.
    func textView(_ tv: NSTextView, shouldChangeTextIn r: NSRange, replacementString s: String?) -> Bool {
        guard s == " ", r.length == 0, editable else { return true }
        let ns = tv.string as NSString
        let p = ns.paragraphRange(for: r)
        let typed = ns.substring(with: NSRange(location: p.location, length: r.location - p.location))
        guard let fmt: NSTextList.MarkerFormat = ["-": .hyphen, "*": .disc, "•": .disc, "1.": .decimal, "1)": .decimal][typed],
              listItem(at: r.location) == nil else { return true }
        DispatchQueue.main.async { [self] in
            let trigger = NSRange(location: p.location, length: (typed as NSString).length)
            guard text.shouldChangeText(in: trigger, replacementString: "") else { return }
            text.textStorage!.replaceCharacters(in: trigger, with: "")
            text.didChangeText()
            text.setSelectedRange(NSRange(location: p.location, length: 0))
            list(fmt)
        }
        return false
    }

    // Same geometry and bullets AppKit's HTML import produces (36pt per level; • ◦ ▪), so typed and loaded lists match.
    func indent(_ ps: NSMutableParagraphStyle, _ lists: [NSTextList]) {
        let d = CGFloat(lists.count)
        ps.textLists = lists
        ps.firstLineHeadIndent = 0
        ps.headIndent = 36 * d
        ps.tabStops = d == 0 ? NSParagraphStyle.default.tabStops
            : [NSTextTab(textAlignment: .left, location: 36 * d - 25), NSTextTab(textAlignment: .left, location: 36 * d)]
    }

    func listLevel(_ fmt: NSTextList.MarkerFormat, depth: Int) -> NSTextList {
        let bullets: [NSTextList.MarkerFormat] = [.disc, .circle, .square]
        return NSTextList(markerFormat: bullets.contains(fmt) ? bullets[(depth - 1) % 3] : fmt, options: 0)
    }

    // Tab / ⇧Tab anywhere in a list item changes its nesting, like Apple Notes.
    func nest(_ li: (para: NSRange, marker: Int, list: NSTextList), deeper: Bool) {
        let st = text.textStorage!
        let ps = (st.attribute(.paragraphStyle, at: li.para.location, effectiveRange: nil) as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        var lists = ps.textLists
        if deeper { guard lists.count < 6 else { return }; lists.append(listLevel(li.list.markerFormat, depth: lists.count + 1)) }
        else { guard lists.count > 1 else { return }; lists.removeLast() }
        indent(ps, lists)
        let contentStart = li.para.location + li.marker
        let content = st.attributedSubstring(from: NSRange(location: contentStart, length: NSMaxRange(li.para) - contentStart))
        let marker = "\t\(lists.last!.marker(forItemNumber: 1))\t"
        let out = NSMutableAttributedString(string: marker, attributes: content.length > 0 ? content.attributes(at: 0, effectiveRange: nil) : text.typingAttributes)
        out.append(content)
        out.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: out.length))
        let caret = text.selectedRange().location - contentStart
        guard text.shouldChangeText(in: li.para, replacementString: out.string) else { return }
        st.replaceCharacters(in: li.para, with: out)
        text.didChangeText()
        text.setSelectedRange(NSRange(location: li.para.location + (marker as NSString).length + max(0, caret), length: 0))
    }

    // ↩ at the end of a Title/Heading/Subheading starts a Body line, like Apple Notes.
    func headingReturn(_ tv: NSTextView, _ sel: Selector, _ sr: NSRange) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        let ns = tv.string as NSString
        let p = ns.paragraphRange(for: sr)
        let end = NSMaxRange(p) - (ns.substring(with: p).hasSuffix("\n") ? 1 : 0)
        guard sr.location == end, p.length > 0, p.location < ns.length,
              let f = tv.textStorage!.attribute(.font, at: p.location, effectiveRange: nil) as? NSFont,
              f.pointSize >= 15.5, !f.isFixedPitch else { return false }
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: Theme.current.text, .paragraphStyle: Notes.paragraph]
        tv.insertText("\n", replacementRange: sr)  // terminates the heading paragraph
        let next = NSRange(location: sr.location + 1, length: 1)  // old newline now ends the new empty line
        let now = tv.string as NSString  // `ns` is a pre-insert snapshot
        if NSMaxRange(next) <= now.length, now.character(at: next.location) == 10, tv.shouldChangeText(in: next, replacementString: nil) {
            tv.textStorage!.setAttributes(bodyAttrs, range: next)
            tv.didChangeText()
        }
        tv.typingAttributes = bodyAttrs
        return true
    }

    // ↩ continues the list, ↩ on an empty item or ⌫ right after the bullet ends it.
    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        let sr = tv.selectedRange()
        guard editable, sr.length == 0 else { return false }
        guard let li = listItem(at: sr.location) else { return headingReturn(tv, sel, sr) }
        let ns = tv.string as NSString
        let body = ns.substring(with: NSRange(location: li.para.location + li.marker, length: li.para.length - li.marker))
            .trimmingCharacters(in: .newlines)
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if body.isEmpty { list(li.list.markerFormat); return true }
            let current = ns.substring(with: NSRange(location: li.para.location, length: li.marker))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\t.)"))
            let next = li.list.marker(forItemNumber: (Int(current) ?? 0) + 1)
            var attrs = tv.typingAttributes
            attrs[.paragraphStyle] = tv.textStorage!.attribute(.paragraphStyle, at: li.para.location, effectiveRange: nil)
            tv.insertText(NSAttributedString(string: "\n\t\(next)\t", attributes: attrs), replacementRange: sr)
            return true
        }
        if sel == #selector(NSResponder.insertTab(_:)) || sel == #selector(NSResponder.insertBacktab(_:)) {
            nest(li, deeper: sel == #selector(NSResponder.insertTab(_:)))
            return true
        }
        if sel == #selector(NSResponder.deleteBackward(_:)), li.marker > 0, sr.location == li.para.location + li.marker {
            list(li.list.markerFormat)
            return true
        }
        return false
    }

    // MARK: formatting

    func find() {
        let m = NSMenuItem()
        m.tag = NSTextFinder.Action.showFindInterface.rawValue
        text.performTextFinderAction(m)
    }

    func trait(_ t: NSFontTraitMask) {
        guard editable else { return }
        let fm = NSFontManager.shared, r = text.selectedRange(), st = text.textStorage!
        let now = (r.length > 0 ? st.attribute(.font, at: r.location, effectiveRange: nil) : text.typingAttributes[.font]) as? NSFont ?? body
        let add = !fm.traits(of: now).contains(t)
        let conv = { (f: NSFont) in add ? fm.convert(f, toHaveTrait: t) : fm.convert(f, toNotHaveTrait: t) }
        if r.length == 0 { text.typingAttributes[.font] = conv(now); return }
        guard text.shouldChangeText(in: r, replacementString: nil) else { return }
        st.enumerateAttribute(.font, in: r) { v, sub, _ in st.addAttribute(.font, value: conv(v as? NSFont ?? self.body), range: sub) }
        text.didChangeText()
    }

    func toggle(_ key: NSAttributedString.Key) {
        guard editable else { return }
        let r = text.selectedRange(), st = text.textStorage!
        let now = (r.length > 0 ? st.attribute(key, at: r.location, effectiveRange: nil) : text.typingAttributes[key]) as? Int ?? 0
        let v = now == 0 ? NSUnderlineStyle.single.rawValue : 0
        if r.length == 0 { text.typingAttributes[key] = v; return }
        guard text.shouldChangeText(in: r, replacementString: nil) else { return }
        st.addAttribute(key, value: v, range: r)
        text.didChangeText()
    }

    func block(_ size: CGFloat, bold: Bool, mono: Bool = false) {
        guard editable else { return }
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        text.typingAttributes[.font] = font
        let r = (text.string as NSString).paragraphRange(for: text.selectedRange())
        guard r.length > 0, text.shouldChangeText(in: r, replacementString: nil) else { return }
        text.textStorage!.addAttribute(.font, value: font, range: r)
        text.didChangeText()
    }

    func addLink() {
        guard editable else { return }
        let a = NSAlert()
        a.messageText = "Add Link"
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        f.placeholderString = "https://"
        if let s = NSPasteboard.general.string(forType: .string), s.hasPrefix("http") { f.stringValue = s }
        a.accessoryView = f
        a.window.initialFirstResponder = f
        a.beginSheetModal(for: panel) { [unowned self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            guard let url = URL(string: f.stringValue), url.scheme != nil else { return toast.show("That doesn't look like a link", "link") }
            var r = text.selectedRange()
            if r.length == 0 {
                text.insertText(f.stringValue, replacementRange: r)
                r.length = (f.stringValue as NSString).length
            }
            guard text.shouldChangeText(in: r, replacementString: nil) else { return }
            text.textStorage!.addAttribute(.link, value: url, range: r)
            text.didChangeText()
        }
    }

    // ponytail: numbered-list markers aren't renumbered after moves; Notes renumbers on save/reload.
    func moveLine(up: Bool) {
        guard editable else { return }
        let ns = text.string as NSString, st = text.textStorage!
        let cur = ns.paragraphRange(for: text.selectedRange())
        if up ? cur.location == 0 : NSMaxRange(cur) >= ns.length { return }
        let other = ns.paragraphRange(for: NSRange(location: up ? cur.location - 1 : NSMaxRange(cur), length: 0))
        let (first, second) = up ? (other, cur) : (cur, other)
        let a = st.attributedSubstring(from: first).mutableCopy() as! NSMutableAttributedString
        let b = st.attributedSubstring(from: second).mutableCopy() as! NSMutableAttributedString
        if !b.string.hasSuffix("\n") {  // last line has no newline: move it over
            b.append(a.attributedSubstring(from: NSRange(location: a.length - 1, length: 1)))
            a.deleteCharacters(in: NSRange(location: a.length - 1, length: 1))
        }
        let whole = NSUnionRange(first, second)
        let offset = text.selectedRange().location - cur.location
        let out = NSMutableAttributedString(attributedString: b)
        out.append(a)
        guard text.shouldChangeText(in: whole, replacementString: out.string) else { return }
        st.replaceCharacters(in: whole, with: out)
        text.didChangeText()
        text.setSelectedRange(NSRange(location: (up ? first.location : first.location + b.length) + offset, length: 0))
    }

    func list(_ fmt: NSTextList.MarkerFormat) {
        guard editable else { return }
        let st = text.textStorage!
        let pr = (text.string as NSString).paragraphRange(for: text.selectedRange())
        let old = st.attributedSubstring(from: pr)
        let firstStyle = (pr.location < st.length ? st.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil)
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
            let ps = (attrs[.paragraphStyle] as? NSParagraphStyle ?? .default).mutableCopy() as! NSMutableParagraphStyle
            let c = old.attributedSubstring(from: e).mutableCopy() as! NSMutableAttributedString
            if !ps.textLists.isEmpty, c.string.hasPrefix("\t") {
                let tab = (c.string as NSString).range(of: "\t", range: NSRange(location: 1, length: c.length - 1))
                if tab.location != NSNotFound { c.deleteCharacters(in: NSRange(location: 0, length: tab.location + 1)) }
            }
            if off {
                indent(ps, [])
            } else {
                indent(ps, [newList])
                c.insert(NSAttributedString(string: "\t\(newList.marker(forItemNumber: i + 1))\t", attributes: attrs), at: 0)
            }
            c.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: c.length))
            out.append(c)
        }
        guard text.shouldChangeText(in: pr, replacementString: out.string) else { return }
        st.replaceCharacters(in: pr, with: out)
        text.didChangeText()
        text.setSelectedRange(NSRange(location: pr.location + out.length - (out.string.hasSuffix("\n") ? 1 : 0), length: 0))
    }
}

if CommandLine.arguments.contains("--test") {
    let h = "<h1>Title</h1><div>a <b>b</b> <i>c</i> &amp; <u>d</u> <strike>e</strike> <a href=\"https://x.y/\">l</a></div>"
        + "<div><br></div><ul><li>one</li><li>two</li></ul><ol><li>n</li></ol><h2>H</h2><h3>S</h3><div><tt>mono</tt></div>"
    let s = Notes.attributed(h)
    let out = Notes.html(s)
    precondition(out == h, "\n got: \(out)\nwant: \(h)")
    let md = Notes.markdown(s)
    precondition(md == "# Title\na **b** _c_ & d ~~e~~ [l](https://x.y/)\n\n- one\n- two\n1. n\n## H\n### S\n`mono`", md)
    let nested = "<ul><li>a</li><ul><li>b</li></ul><li>c</li></ul>"
    precondition(Notes.html(Notes.attributed(nested)) == nested, Notes.html(Notes.attributed(nested)))
    precondition(Notes.q(#"say "hi" \"#) == #""say \"hi\" \\""#)
    print("ok")
    exit(0)
}

// One-time carry-over of settings (shortcut, pins, last note…) from earlier identifiers, newest first.
if !UserDefaults.standard.bool(forKey: "migratedSettings") {
    for oldID in ["app.notesfloat.NotesFloat", "local.notesfloat"] {
        for (k, v) in UserDefaults.standard.persistentDomain(forName: oldID) ?? [:] where UserDefaults.standard.object(forKey: k) == nil {
            UserDefaults.standard.set(v, forKey: k)
        }
    }
    UserDefaults.standard.set(true, forKey: "migratedSettings")
}
UserDefaults.standard.register(defaults: ["hkCode": kVK_ANSI_N, "hkMods": controlKey | optionKey, "hkLabel": "⌃⌥N"])
let app = App()
var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in app.togglePanel(); return noErr }, 1, &spec, nil, nil)
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.delegate = app
NSApplication.shared.run()
