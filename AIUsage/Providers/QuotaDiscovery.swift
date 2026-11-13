import CoreFoundation
import Foundation

/// Accept only explicit quota measurements; names/availability alone are not percentages.
enum QuotaDiscovery {
    static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
        guard let number = ProviderParsing.double(value), number.isFinite else { return nil }
        return number
    }
    static func title(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(90))
    }
    static func name(_ key: String) -> String {
        ProviderParsing.titleCaseIdentifier(key.replacingOccurrences(of: "-", with: "_"))
    }
    static func notice(_ key: String) -> ProviderUsageDetail {
        ProviderUsageDetail(id: "compatibility." + key, title: "Quota data changed",
            value: String(("Unsupported quota: " + key).prefix(95)))
    }
    static func window(id: String, title: String, used: Double?, reset: Date?) -> QuotaWindow? {
        guard let used, used.isFinite, (0...100).contains(used) else { return nil }
        return QuotaWindow(kind: .additional(id: id, title: Self.title(title)), usedPercent: used, resetsAt: reset)
    }
    static func fraction(_ value: Any?) -> Double? {
        guard let fraction = number(value), (0...1).contains(fraction) else { return nil }
        return (1 - fraction) * 100
    }
}

extension ProviderSnapshot {
    var quotaCompatibilityNotes: [ProviderUsageDetail] {
        usageDetails.filter { $0.id.hasPrefix("compatibility.") }
    }
}
