import SwiftUI

// Stratus-inspired pitch-black T3 tokens: zero borders, zero pane dividers,
// pure typographic hierarchy and subtle tonal elevation.

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }

    // Grounds (pure pitch-black ladder)
    static let obsidian0 = Color(hex: 0x000000)
    static let rail = Color(hex: 0x030304)
    static let obsidian1 = Color(hex: 0x060608)
    static let floatingSurface = Color(hex: 0x0B0B0F)
    static let raise1 = Color(hex: 0x0B0B0E)
    static let surfaceHover = Color(hex: 0x111114)
    static let surfacePill = Color(hex: 0x151519)
    static let raise2 = Color(hex: 0x16161B)
    // Ultra-subtle lines (fallback only; prefer borderless tonal elevation)
    static let line = Color(hex: 0x0E0E12)
    static let line2 = Color(hex: 0x15151B)
    // Ink
    static let inkHi = Color(hex: 0xF4F4F6)
    static let ink = Color(hex: 0xC2C2CC)
    static let ink2 = Color(hex: 0x8E8E99)
    static let ink3 = Color(hex: 0x585862)
    /// The one bright control: Run and the active tool.
    static let runFill = Color(hex: 0xF4F4F6)
    // Stratus T3 accent palette
    static let ice = Color(hex: 0x7A89FF)
    static let lavender = Color(hex: 0xA78BFA)
    static let live = Color(hex: 0x34D399)
    static let amber = Color(hex: 0xFBBF24)
    static let coral = Color(hex: 0xE88255)
    static let sky = Color(hex: 0x4BC3F7)
    static let rose = Color(hex: 0xF87171)
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
    public static let panel = Animation.easeOut(duration: 0.16)
    public static let hover = Animation.easeOut(duration: 0.12)
}
