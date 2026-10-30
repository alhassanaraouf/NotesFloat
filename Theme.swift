import Cocoa

// Window colors. Only display: nothing here is written to notes.
struct Theme {
    let id, name: String
    let background: NSColor?  // nil: the Liquid Glass shows through
    let text: NSColor
    let accent: NSColor  // caret, selection, links, ticked checklists
    let appearance: NSAppearance.Name?  // nil: follow the system

    static func rgb(_ h: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(h >> 16 & 0xff) / 255, green: CGFloat(h >> 8 & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: 1)
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light) }
    }

    static let all: [Theme] = [
        Theme(id: "notes", name: "Apple Notes", background: dynamic(0xFFFFFF, 0x1E1E1E), text: .textColor,
              accent: dynamic(0xD9A400, 0xFFD60A), appearance: nil),
        Theme(id: "glass", name: "Liquid Glass", background: nil, text: .textColor, accent: .controlAccentColor, appearance: nil),
        Theme(id: "graphite", name: "Graphite", background: rgb(0x1A1A1C), text: rgb(0xECECEE), accent: rgb(0xFF6363), appearance: .darkAqua),
        Theme(id: "paper", name: "Paper", background: rgb(0xFAF5E9), text: rgb(0x3A2F25), accent: rgb(0xB5651D), appearance: .aqua),
    ]

    static var current: Theme { all.first { $0.id == UserDefaults.standard.string(forKey: "theme") } ?? all[0] }
}
