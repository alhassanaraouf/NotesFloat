// Permissions, updates, settings and first-run onboarding.
import Cocoa
import Carbon
import ServiceManagement
import Sparkle

// MARK: permissions

enum Access {
    enum State { case granted, denied, unknown }
    static let notesID = "com.apple.Notes"

    // macOS can only answer for a running Notes; .unknown covers "not asked yet" and "Notes isn't running".
    static func notes(ask: Bool = false) -> State {
        let target = NSAppleEventDescriptor(bundleIdentifier: notesID)
        let s = withExtendedLifetime(target) { AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask) }
        return s == noErr ? .granted : s == OSStatus(errAEEventNotPermitted) ? .denied : .unknown
    }

    // Starts Notes quietly if needed (macOS only asks about running apps), then shows the system prompt.
    // The check blocks until the user answers, so it runs off the main thread.
    static func requestNotes(_ done: @escaping (State) -> Void) {
        let ask = {
            DispatchQueue.global(qos: .userInitiated).async {
                let s = notes(ask: true)
                DispatchQueue.main.async { done(s) }
            }
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: notesID).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: notesID) else { return ask() }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: ask)  // let Notes finish launching
        }
    }

    static var fullDisk: Bool { Notes.canReadDB }

    // Optional: lets quick capture read the selected text in other apps (otherwise it uses the clipboard).
    static var accessibility: Bool { AXIsProcessTrusted() }
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    // The selected text in the frontmost app, via Accessibility; nil without permission or selection.
    static func selectedText() -> String? {
        guard accessibility else { return nil }
        var focused: CFTypeRef?, selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success else { return nil }
        return (selected as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func openPane(_ pane: String) {  // "Privacy_Automation", "Privacy_AllFiles"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

// MARK: updates (Sparkle)

final class Updates: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()
    private(set) lazy var controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    var updater: SPUUpdater { controller.updater }

    // Menu-bar app with no Dock icon: let Sparkle show scheduled update prompts gently, and bring them to front.
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
}

// MARK: shared controls

// Click, then press a key combination; Esc cancels. Re-registers the global hotkey, restoring the old one if taken.
final class ShortcutButton: NSButton {
    var monitor: Any?
    var kind = HotKey.Kind.toggle
    var p: String { kind.prefix }

    convenience init(_ kind: HotKey.Kind = .toggle) {
        self.init(title: "", target: nil, action: nil)
        self.kind = kind
        bezelStyle = .rounded
        target = self
        action = #selector(record)
        refresh()
    }

    func refresh() { title = UserDefaults.standard.string(forKey: p + "Label") ?? "" }

    @objc func record() {
        guard monitor == nil else { return }
        title = "Type shortcut… (Esc cancels)"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] e in
            let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if e.keyCode != 53 {
                guard !f.isDisjoint(with: [.command, .option, .control]) else { NSSound.beep(); return nil }
                let d = UserDefaults.standard
                let old = (d.integer(forKey: p + "Code"), d.integer(forKey: p + "Mods"), d.string(forKey: p + "Label"))
                var mods = 0
                if f.contains(.command) { mods |= cmdKey }
                if f.contains(.option) { mods |= optionKey }
                if f.contains(.control) { mods |= controlKey }
                if f.contains(.shift) { mods |= shiftKey }
                let key = e.characters(byApplyingModifiers: [])?.uppercased() ?? ""
                let label = (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "")
                    + (f.contains(.command) ? "⌘" : "") + (key == " " ? "Space" : key.isEmpty ? "#\(e.keyCode)" : key)
                d.set(Int(e.keyCode), forKey: p + "Code"); d.set(mods, forKey: p + "Mods"); d.set(label, forKey: p + "Label")
                if !HotKey.register(kind) {  // taken by the system or another app: restore
                    d.set(old.0, forKey: p + "Code"); d.set(old.1, forKey: p + "Mods"); d.set(old.2, forKey: p + "Label")
                    HotKey.register(kind)
                    NSSound.beep()
                }
            }
            NSEvent.removeMonitor(monitor!)
            monitor = nil
            refresh()
            return nil
        }
    }
}

enum LoginItem {
    static var on: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

func statusText(_ s: Access.State) -> (String, NSColor) {
    switch s {
    case .granted: ("✓ Allowed", .systemGreen)
    case .denied: ("✗ Not allowed", .systemRed)
    case .unknown: ("Not set up yet", .secondaryLabelColor)
    }
}

func wrapping(_ s: String, _ size: CGFloat = 13, _ color: NSColor = .secondaryLabelColor, width: CGFloat = 400) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: s)
    l.font = .systemFont(ofSize: size)
    l.textColor = color
    l.preferredMaxLayoutWidth = width
    return l
}

func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views)
    s.spacing = spacing
    return s
}

// MARK: settings window

final class Settings: NSObject {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 10), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
    let shortcut = ShortcutButton()
    let capture = ShortcutButton(.capture)
    let login = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    let theme = NSPopUpButton()
    let axStatus = label("", 13)
    lazy var axButton = NSButton(title: "Allow…", target: self, action: #selector(allowAX))
    let notesStatus = label("", 13), diskStatus = label("", 13)
    lazy var notesButton = NSButton(title: "Allow…", target: self, action: #selector(allowNotes))
    lazy var diskButton = NSButton(title: "Open Privacy Settings…", target: self, action: #selector(openDisk))
    let autoCheck = NSButton(checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
    let autoInstall = NSButton(checkboxWithTitle: "Automatically download and install updates", target: nil, action: nil)
    var onTheme: () -> Void = {}
    var onWelcome: () -> Void = {}
    var timer: Timer?

    override init() {
        super.init()
        window.title = "NotesFloat Settings"
        window.isReleasedWhenClosed = false
        window.level = .floating
        login.target = self
        login.action = #selector(toggleLogin)
        theme.addItems(withTitles: Theme.all.map(\.name))
        theme.target = self
        theme.action = #selector(pickTheme)
        for b in [autoCheck, autoInstall] { b.target = self; b.action = #selector(toggleUpdates) }

        let stack = NSStackView(views: [
            section("General", [
                [label("Show / hide:", 13), shortcut],
                [label("Quick capture:", 13), capture],
                [NSGridCell.emptyContentView, wrapping("Adds the selected text (with Accessibility) or the clipboard to your capture note, without opening the window. Choose the note with ⌘K › Capture Into This Note. Also in any app's Services menu as “Add to NotesFloat”.", 11, width: 300)],
                [NSGridCell.emptyContentView, login],
            ]),
            section("Appearance", [[label("Theme:", 13), theme]]),
            section("Permissions", [
                [label("Apple Notes:", 13), row([notesStatus, notesButton])],
                [label("Full Disk Access:", 13), row([diskStatus, diskButton])],
                [NSGridCell.emptyContentView, wrapping("Optional. Lets NotesFloat find checklists exactly, show ☐/☑, search faster, and show your Apple Notes pins. Read-only.", 11, width: 300)],
                [label("Accessibility:", 13), row([axStatus, axButton])],
                [NSGridCell.emptyContentView, wrapping("Optional. Lets quick capture grab the text selected in other apps.", 11, width: 300)],
            ]),
            section("Updates", [
                [NSGridCell.emptyContentView, autoCheck], [NSGridCell.emptyContentView, autoInstall],
                [label("Version:", 13), row([label(Updates.version, 13, .regular, .secondaryLabelColor),
                                              NSButton(title: "Check Now", target: self, action: #selector(checkNow))])],
            ]),
            NSButton(title: "Show Welcome Guide…", target: self, action: #selector(welcome)),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
    }

    func section(_ title: String, _ rows: [[NSView]]) -> NSView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 120
        grid.rowAlignment = .firstBaseline
        let s = NSStackView(views: [label(title, 13, .semibold), grid])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 10
        return s
    }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        timer?.invalidate()  // permissions change in System Settings; keep the status live while open
        timer = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self, window.isVisible else { return t.invalidate() }
            refresh()
        }
    }

    func refresh() {
        shortcut.refresh()
        capture.refresh()
        axStatus.stringValue = Access.accessibility ? "✓ Allowed" : "Not allowed"
        axStatus.textColor = Access.accessibility ? .systemGreen : .secondaryLabelColor
        axButton.isHidden = Access.accessibility
        login.state = LoginItem.on ? .on : .off
        theme.selectItem(withTitle: Theme.current.name)
        let n = statusText(Access.notes())
        notesStatus.stringValue = n.0
        notesStatus.textColor = n.1
        notesButton.isHidden = Access.notes() == .granted
        let disk = Access.fullDisk
        diskStatus.stringValue = disk ? "✓ Allowed" : "Not allowed"
        diskStatus.textColor = disk ? .systemGreen : .secondaryLabelColor
        diskButton.isHidden = disk
        autoCheck.state = Updates.shared.updater.automaticallyChecksForUpdates ? .on : .off
        autoInstall.state = Updates.shared.updater.automaticallyDownloadsUpdates ? .on : .off
        autoInstall.isEnabled = autoCheck.state == .on
    }

    @objc func toggleLogin() { LoginItem.set(login.state == .on); refresh() }
    @objc func pickTheme() {
        UserDefaults.standard.set(Theme.all[theme.indexOfSelectedItem].id, forKey: "theme")
        onTheme()
    }
    @objc func toggleUpdates() {
        Updates.shared.updater.automaticallyChecksForUpdates = autoCheck.state == .on
        Updates.shared.updater.automaticallyDownloadsUpdates = autoCheck.state == .on && autoInstall.state == .on
        refresh()
    }
    @objc func allowNotes() {
        Access.notes() == .denied ? Access.openPane("Privacy_Automation") : Access.requestNotes { [weak self] _ in self?.refresh() }
    }
    @objc func openDisk() { Access.openPane("Privacy_AllFiles") }
    @objc func allowAX() { Access.requestAccessibility() }
    @objc func checkNow() { Updates.shared.checkNow() }
    @objc func welcome() { window.close(); onWelcome() }
}

// MARK: onboarding

final class Onboarding: NSObject {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470), styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    let page = NSStackView()
    let dots = NSStackView()
    lazy var back = NSButton(title: "Back", target: self, action: #selector(goBack))
    lazy var next = NSButton(title: "Continue", target: self, action: #selector(goNext))
    let status = label("", 13, .medium)
    let shortcut = ShortcutButton()
    var step = 0
    var timer: Timer?
    var onFinish: () -> Void = {}
    let steps = 5

    override init() {
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        page.orientation = .vertical
        page.alignment = .centerX
        page.spacing = 14
        next.keyEquivalent = "\r"
        next.bezelStyle = .push
        dots.spacing = 6
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = row([dots, spacer, back, next])
        let root = NSStackView(views: [page, bottom])
        root.orientation = .vertical
        root.distribution = .fill
        root.edgeInsets = NSEdgeInsets(top: 44, left: 36, bottom: 24, right: 28)
        page.setContentHuggingPriority(.init(1), for: .vertical)
        bottom.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -64).isActive = true
        window.contentView = root
    }

    func show() {
        step = 0
        render()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in  // live permission status
            guard let self, window.isVisible else { return t.invalidate() }
            updateStatus()
        }
    }

    func render() {
        page.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let notesIcon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Access.notesID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        func image(_ i: NSImage?, _ size: CGFloat = 88) -> NSImageView {
            let v = NSImageView(image: i ?? NSImage())
            v.widthAnchor.constraint(equalToConstant: size).isActive = true
            v.heightAnchor.constraint(equalToConstant: size).isActive = true
            return v
        }
        func symbol(_ name: String) -> NSImageView {
            let v = image(NSImage(systemSymbolName: name, accessibilityDescription: nil), 64)
            v.symbolConfiguration = .init(pointSize: 52, weight: .regular)
            v.contentTintColor = .controlAccentColor
            return v
        }
        let title = label("", 24, .bold)
        var views: [NSView]
        switch step {
        case 0:
            title.stringValue = "Welcome to NotesFloat"
            views = [image(NSApp.applicationIconImage, 112), title,
                     wrapping("Your Apple Notes in a floating window, above every app and even full-screen ones. It saves straight to Apple Notes, so everything still syncs through iCloud.", 14),
                     wrapping("Let's set up the access it needs. It takes a minute.", 14)]
        case 1:
            title.stringValue = "Allow access to Apple Notes"
            views = [image(notesIcon), title,
                     wrapping("NotesFloat opens and saves your notes through Apple Notes. When you click Allow, macOS asks whether NotesFloat may control Notes — choose Allow.", 14),
                     row([NSButton(title: "Allow Access…", target: self, action: #selector(allowNotes)), status], spacing: 12)]
        case 2:
            title.stringValue = "Full Disk Access (recommended)"
            views = [symbol("lock.shield"), title,
                     wrapping("Apple Notes reports checklists to other apps as plain bullets. With Full Disk Access, NotesFloat reads Apple Notes' own database — read-only — to:", 14),
                     wrapping("•  know exactly which notes have checklists, so it can keep them safe\n•  show checklist items as ☐ / ☑\n•  search inside notes faster, and show your Apple Notes pins", 13, .labelColor),
                     wrapping("In System Settings, turn on NotesFloat in the Full Disk Access list. You can skip this and turn it on later in Settings.", 12),
                     row([NSButton(title: "Open Privacy Settings…", target: self, action: #selector(openDisk)), status], spacing: 12)]
        case 3:
            title.stringValue = "Make it yours"
            let login = NSButton(checkboxWithTitle: "Launch NotesFloat at login", target: self, action: #selector(toggleLogin(_:)))
            login.state = LoginItem.on ? .on : .off
            let updates = NSButton(checkboxWithTitle: "Check for updates automatically", target: self, action: #selector(toggleUpdates(_:)))
            updates.state = Updates.shared.updater.automaticallyChecksForUpdates ? .on : .off
            shortcut.refresh()
            let options = NSStackView(views: [row([label("Show or hide NotesFloat:", 13), shortcut], spacing: 10), login, updates])
            options.orientation = .vertical
            options.alignment = .leading
            options.spacing = 12
            views = [symbol("slider.horizontal.3"), title, wrapping("Pick the shortcut that brings your notes up. Click it, then press new keys.", 14), options]
        default:
            title.stringValue = "You're all set"
            let keys = UserDefaults.standard.string(forKey: "hkLabel") ?? "⌃⌥N"
            views = [image(NSApp.applicationIconImage, 112), title,
                     wrapping("Press \(keys) anytime to show or hide your notes. ⌘K shows every action, ⌘P finds any note, and Esc tucks the window away.", 14)]
        }
        for v in views {
            (v as? NSTextField)?.alignment = .center
            page.addArrangedSubview(v)
        }
        page.setCustomSpacing(20, after: views[0])

        dots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for i in 0..<steps {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = (i == step ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
            dots.addArrangedSubview(dot)
        }
        back.isHidden = step == 0
        updateStatus()
    }

    func updateStatus() {
        switch step {
        case 1:
            let s = statusText(Access.notes())
            status.stringValue = s.0
            status.textColor = s.1
            next.isEnabled = Access.notes() == .granted  // required: everything depends on it
            next.title = "Continue"
        case 2:
            let ok = Access.fullDisk
            status.stringValue = ok ? "✓ Allowed" : ""
            status.textColor = .systemGreen
            next.isEnabled = true
            next.title = ok ? "Continue" : "Skip for Now"
        default:
            next.isEnabled = true
            next.title = step == 0 ? "Get Started" : step == steps - 1 ? "Open NotesFloat" : "Continue"
        }
    }

    @objc func goNext() {
        guard step < steps - 1 else {
            UserDefaults.standard.set(true, forKey: "onboarded")
            window.close()
            onFinish()
            return
        }
        step += 1
        render()
    }

    @objc func goBack() { step = max(0, step - 1); render() }

    @objc func allowNotes() {
        if Access.notes() == .denied { return Access.openPane("Privacy_Automation") }
        status.stringValue = "Waiting for macOS…"
        status.textColor = .secondaryLabelColor
        Access.requestNotes { [weak self] _ in
            self?.updateStatus()
            NSApp.activate(ignoringOtherApps: true)
            self?.window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func openDisk() { Access.openPane("Privacy_AllFiles") }
    @objc func toggleLogin(_ b: NSButton) { LoginItem.set(b.state == .on) }
    @objc func toggleUpdates(_ b: NSButton) { Updates.shared.updater.automaticallyChecksForUpdates = b.state == .on }
}
