import SwiftUI
import AppKit

/// Flat neutral palette. Every color resolves against the effective appearance,
/// so the dark charcoal default and the optional light/system modes share one definition.
enum Theme {
    static let window = dynamic(dark: 0x1B1B1C, light: 0xECECEC)
    static let grid = dynamic(dark: 0x161617, light: 0xE4E4E5)
    static let panel = dynamic(dark: 0x222223, light: 0xF4F4F4)
    static let chrome = dynamic(dark: 0x262627, light: 0xF7F7F7)
    static let raised = dynamic(dark: 0x2C2C2E, light: 0xFFFFFF)
    static let tile = dynamic(dark: 0x242425, light: 0xFAFAFA)
    static let tileHover = dynamic(dark: 0x2E2E30, light: 0xFFFFFF)
    static let thumbWell = dynamic(dark: 0x1D1D1E, light: 0xDCDCDE)
    static let separator = dynamic(dark: 0x343436, light: 0xD2D2D4)
    static let primaryText = dynamic(dark: 0xE8E8E9, light: 0x1D1D1F)
    static let secondaryText = dynamic(dark: 0x9C9C9F, light: 0x6A6A6E)
    static let tertiaryText = dynamic(dark: 0x6E6E72, light: 0x98989C)
    static let rowSelection = dynamic(dark: 0x34343A, light: 0xDCDCE2)

    // Semantic state colors are always paired with a symbol and text, never used alone.
    static let positive = dynamic(dark: 0x5DBB7A, light: 0x2E8B4F)
    static let caution = dynamic(dark: 0xE0A64A, light: 0xB5741A)
    static let critical = dynamic(dark: 0xE5675F, light: 0xC2382F)
    static let neutralState = dynamic(dark: 0x8E8E93, light: 0x6E6E73)
    // Variants for coloring small text (connection labels only): at least 4.5:1 on the panel,
    // chrome and settings surfaces (dark #222223/#2C2C2E/#333333, light #F4F4F4/#FFFFFF/#EBEBEB).
    // `positive`, `caution` and `critical` stay as they are for item states and notices.
    static let positiveText = dynamic(dark: 0x5DBB7A, light: 0x24753D)
    static let cautionText = dynamic(dark: 0xE3B341, light: 0x8A5B00)
    static let criticalText = dynamic(dark: 0xEC8179, light: 0xB62F29)

    static var accent: NSColor { .controlAccentColor }

    // Small shared radii so controls, tiles and photo overlays read as one family.
    static let controlRadius: CGFloat = 4
    static let tileRadius: CGFloat = 4
    static let badgeRadius: CGFloat = 3

    static func dynamic(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) != .aqua
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    static let ykWindow = Color(nsColor: Theme.window)
    static let ykGrid = Color(nsColor: Theme.grid)
    static let ykPanel = Color(nsColor: Theme.panel)
    static let ykChrome = Color(nsColor: Theme.chrome)
    static let ykRaised = Color(nsColor: Theme.raised)
    static let ykSeparator = Color(nsColor: Theme.separator)
    static let ykPrimary = Color(nsColor: Theme.primaryText)
    static let ykSecondary = Color(nsColor: Theme.secondaryText)
    static let ykTertiary = Color(nsColor: Theme.tertiaryText)
    static let ykRowSelection = Color(nsColor: Theme.rowSelection)
    static let ykPositive = Color(nsColor: Theme.positive)
    static let ykCaution = Color(nsColor: Theme.caution)
    static let ykCritical = Color(nsColor: Theme.critical)
    static let ykNeutral = Color(nsColor: Theme.neutralState)
    static let ykPositiveText = Color(nsColor: Theme.positiveText)
    static let ykCautionText = Color(nsColor: Theme.cautionText)
    static let ykCriticalText = Color(nsColor: Theme.criticalText)
}

/// Visual vocabulary for each machine state. Shared by the AppKit grid and SwiftUI panels
/// so that a state always reads the same: symbol + Japanese label. Routine states stay neutral;
/// only states that need the user (date missing, failure) tint their symbol.
struct StatusStyle {
    var symbol: String
    var label: String
    /// Symbol color. Text never carries the color.
    var tint: NSColor
    /// Needs the user's action: full-contrast text and a tinted symbol.
    var isAlert: Bool
    var dimsThumbnail: Bool
    var showsActivity: Bool

    var textColor: NSColor { isAlert ? Theme.primaryText : Theme.secondaryText }

    init(_ item: MediaItem) {
        switch item.status {
        case .checking:
            self.init(symbol: "hourglass", label: item.status.title)
        case .new:
            self.init(symbol: item.isSelected ? "arrow.down.circle" : "circle.dashed", label: item.isSelected ? "未取り込み" : "未取り込み・除外中")
        case .imported:
            self.init(symbol: "checkmark.circle", label: item.status.title, dimsThumbnail: true)
        case .cardDuplicate:
            self.init(symbol: "square.on.square", label: "同一内容", dimsThumbnail: true)
        case .needsDate:
            self.init(symbol: "calendar.badge.exclamationmark", label: "要確認・日時", tint: Theme.caution, isAlert: true)
        case .failed:
            self.init(symbol: "exclamationmark.triangle.fill", label: item.status.title, tint: Theme.critical, isAlert: true)
        case .copying:
            self.init(symbol: "arrow.down.doc", label: item.status.title, showsActivity: true)
        case .verifying:
            self.init(symbol: "checkmark.shield", label: item.status.title, showsActivity: true)
        }
    }

    private init(symbol: String, label: String, tint: NSColor = Theme.neutralState, isAlert: Bool = false, dimsThumbnail: Bool = false, showsActivity: Bool = false) {
        self.symbol = symbol
        self.label = label
        self.tint = tint
        self.isAlert = isAlert
        self.dimsThumbnail = dimsThumbnail
        self.showsActivity = showsActivity
    }
}
