import AppKit
import SwiftUI

enum UsagePalette {
    static let accent = Color(nsColor: .systemBlue)
    static let normalUsage = Color(nsColor: .systemTeal)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let critical = Color(nsColor: .systemRed)
}

/// One warning scale for panel and menu bar. Always use consumed quota.
enum UsageSeverity: Equatable, Sendable {
    case normal, warning, critical
    init(usedPercent: Double) {
        switch usedPercent {
        case 85...: self = .critical
        case 60..<85: self = .warning
        default: self = .normal
        }
    }
    var nsColor: NSColor {
        switch self {
        case .normal: .labelColor
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }
    var color: Color { Color(nsColor: nsColor) }
}
