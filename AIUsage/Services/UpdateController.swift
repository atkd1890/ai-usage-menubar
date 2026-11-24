import Observation
import Sparkle

@MainActor
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate {
    /// Highest upstream release already reviewed/ported into this fork; footer notices hide <= this version.
    nonisolated static let syncedUpstreamVersion = "0.5.0"

    private(set) var availableVersion: String?
    private(set) var isChecking = false

    @ObservationIgnored
    private var updaterController: SPUStandardUpdaterController!

    init(startingUpdater: Bool = true) {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        if startingUpdater {
            isChecking = true
            updaterController.updater.checkForUpdateInformation()
        }
    }

    var isUpdateAvailable: Bool {
        availableVersion != nil
    }

    func checkForUpdates() {
        isChecking = true
        updaterController.checkForUpdates(nil)
    }

    func updater(
        _ updater: SPUUpdater,
        didFindValidUpdate item: SUAppcastItem
    ) {
        availableVersion = Self.visibleUpstreamVersion(item.displayVersionString)
        isChecking = false
    }

    nonisolated static func visibleUpstreamVersion(
        _ candidate: String?,
        syncedVersion: String = syncedUpstreamVersion
    ) -> String? {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              isVersion(trimmed, newerThan: syncedVersion) else {
            return nil
        }
        return trimmed
    }

    nonisolated static func isVersion(_ candidate: String, newerThan baseline: String) -> Bool {
        guard let lhs = parseVersion(candidate), let rhs = parseVersion(baseline) else {
            return false
        }
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right {
                return left > right
            }
        }
        if lhs.isPrerelease != rhs.isPrerelease {
            return !lhs.isPrerelease
        }
        return false
    }

    private nonisolated static func parseVersion(_ raw: String) -> (parts: [Int], isPrerelease: Bool)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        if let buildIndex = text.firstIndex(of: "+") {
            text = String(text[..<buildIndex])
        }
        let isPrerelease: Bool
        let coreText: String
        if let dashIndex = text.firstIndex(of: "-") {
            coreText = String(text[..<dashIndex])
            isPrerelease = true
        } else {
            coreText = text
            isPrerelease = false
        }
        let rawParts = coreText.split(separator: ".", omittingEmptySubsequences: false)
        guard !rawParts.isEmpty else { return nil }
        var parts: [Int] = []
        parts.reserveCapacity(rawParts.count)
        for segment in rawParts {
            guard !segment.isEmpty,
                  segment.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(segment) else {
                return nil
            }
            parts.append(number)
        }
        return (parts, isPrerelease)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
        isChecking = false
    }

    func updater(
        _ updater: SPUUpdater,
        didAbortWithError error: any Error
    ) {
        isChecking = false
    }
}
