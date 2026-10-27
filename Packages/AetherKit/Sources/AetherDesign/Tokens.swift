import SwiftUI

// Velvet Obsidian: the chrome is grey so the work is the only colour on
// screen. Values are the design canvas's "Velvet Obsidian" board.

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }

    // Grounds
    static let obsidian0 = Color(hex: 0x0B0C0E)
    static let obsidian1 = Color(hex: 0x121316)
    static let raise1 = Color(hex: 0x16171B)
    static let raise2 = Color(hex: 0x1E1F24)
    static let rail = Color(hex: 0x0F1013)
    // Lines
    static let line = Color(hex: 0x1F2128)
    static let line2 = Color(hex: 0x23252D)
    // Ink
    static let inkHi = Color(hex: 0xEDEEF0)
    static let ink = Color(hex: 0xB9BCC4)
    static let ink2 = Color(hex: 0x8B9099)
    static let ink3 = Color(hex: 0x5E636D)
    /// The one bright control: Run and the active tool.
    static let runFill = Color(hex: 0xE8EAEE)
    // Signals, always paired with a second cue
    static let ice = Color(hex: 0x9DB4FF)
    static let lavender = Color(hex: 0xB9A8FF)
    static let live = Color(hex: 0x7DD3B0)
    static let amber = Color(hex: 0xE9C46A)
    static let coral = Color(hex: 0xFF8A7A)
}

public extension Font {
    static let aeTitle = Font.system(size: 13, weight: .semibold)
    static let aeCommand = Font.system(size: 13, weight: .medium)
    static let aeBody = Font.system(size: 12)
    static let aeBodyStrong = Font.system(size: 12, weight: .medium)
    static let aeLabel = Font.system(size: 11, weight: .semibold)
    static let aeSmall = Font.system(size: 11)
    static let aeMono = Font.system(size: 11, design: .monospaced)
    static let aeMonoStrong = Font.system(size: 11.5, weight: .medium, design: .monospaced)
}

public enum Radius {
    public static let handle: CGFloat = 4
    public static let field: CGFloat = 6
    public static let button: CGFloat = 8
    public static let node: CGFloat = 10
    public static let panel: CGFloat = 12
    public static let floating: CGFloat = 14
}

public enum Motion {
    /// Panels, the dock and the viewport move as one.
    public static let panel = Animation.spring(response: 0.32, dampingFraction: 0.8)
    public static let hover = Animation.easeOut(duration: 0.12)
}
