import SwiftUI
import AppKit

/// "Blacktop & Traffic Paint": asphalt sidebar, concrete ground, traffic-yellow accent.
enum Palette {
    static let asphalt = Color(hex: 0x17181A)
    static let asphaltRaised = Color(hex: 0x1F2023)
    static let asphaltField = Color(hex: 0x232428)
    static let asphaltActive = Color(hex: 0x2A2B30)
    static let asphaltLine = Color(hex: 0x2F3035)
    static let asphaltRule = Color(hex: 0x3A3B40)

    static let ground = Color(hex: 0xF3F3F1)
    static let surface = Color.white
    static let surfaceSunk = Color(hex: 0xF7F7F5)
    static let chip = Color(hex: 0xF1F1EE)
    static let border = Color(hex: 0xE3E3DF)
    static let control = Color(hex: 0xD5D5D0)
    static let hairline = Color(hex: 0xECECE8)

    static let ink = Color(hex: 0x17181A)
    static let secondary = Color(hex: 0x565961)
    static let tertiary = Color(hex: 0x6B6E75)
    static let sidebarText = Color(hex: 0xC9CACD)
    static let sidebarMuted = Color(hex: 0x8C8F96)
    static let onDarkMuted = Color(hex: 0xA3A6AD)

    static let accent = Color(hex: 0xFFC21A)
    static let accentWash = Color(hex: 0xFFFBEA)
    static let amberInk = Color(hex: 0x7A4F00)
    static let blue = Color(hex: 0x1F5FD1)
    static let infoInk = Color(hex: 0x1A4FAF)
    static let infoBg = Color(hex: 0xE6EEFB)
    static let goInk = Color(hex: 0x146B3E)
    static let goBg = Color(hex: 0xE3F4EA)
    static let noGoInk = Color(hex: 0xA3231A)
    static let noGoBg = Color(hex: 0xFDE7E4)
    static let watchInk = Color(hex: 0x7A4F00)
    static let watchBg = Color(hex: 0xFFF2CC)
    static let mint = Color(hex: 0x5DD39E)
    static let salmon = Color(hex: 0xFF8A7A)

    static let wood = Color(hex: 0xB48A55)
    static let woodShade = Color(hex: 0x9C7646)
    static let flagging = Color(hex: 0xFF6B2C)
    static let vial = Color(hex: 0xCFE7A8)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Font {
    /// Condensed display face (SF Pro Condensed) for titles and big numbers.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }
    static func ui(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static let eyebrow = Font.system(size: 11, weight: .bold)
}
