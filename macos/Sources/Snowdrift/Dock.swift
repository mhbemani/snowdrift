import AppKit

/// The Dock's visible platter (the rounded glass bar), without Accessibility permission.
///
/// No API exposes it (the Dock's own window is full-screen), so it's computed the way the Dock lays
/// itself out, from its preferences (icon size, items) and the running apps. Measured from
/// screenshots on two displays (icon size 55):
///
///     |<-37->( icon )<----59---->( icon ) ... ( icon )<-59+27->( Trash )<-37->|   75 pt tall
///
/// natural width = (2·37 + (items − 1)·59 + separators·27) · iconSize/55. When that doesn't fit the
/// screen minus 40 pt on each side, the Dock shrinks *everything* to fit. Checked against four
/// measured Docks (21–25 items, 1470 and 1920 pt screens, shrunk and not): all within 1 pt.
/// Items are counted the way the Dock lays them out: Finder, pinned apps, running apps that aren't
/// pinned (in a separate "recents" section only when recent apps are shown), then a separator,
/// folders/stacks, Trash.
// ponytail: no magnification or spacer tiles; measured at icon size 55 only (assumed linear in it).
@MainActor
final class DockInfo {
    private static let referenceTile: CGFloat = 55
    private static let edge: CGFloat = 37, pitch: CGFloat = 59, separator: CGFloat = 27
    private static let height: CGFloat = 75, bottomGap: CGFloat = 5, screenMargin: CGFloat = 40
    private static let radiusPerHeight: CGFloat = 20.0 / 70           // measured: radius 20 at height 70

    private var items = 0
    private var separators = 0
    private var tile: CGFloat = 55

    init() { _ = refresh() }

    /// Re-read the Dock's icon size and items. Returns true if anything changed.
    func refresh() -> Bool {
        let dock = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(dock)
        func pref<T>(_ key: String) -> T? { CFPreferencesCopyAppValue(key as CFString, dock) as? T }

        let newTile = CGFloat((pref("tilesize") as NSNumber?)?.doubleValue ?? 48).clamped(16, 128)
        let apps: [[String: Any]] = pref("persistent-apps") ?? []
        let pinned = Set(apps.compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String })
        let others = (pref("persistent-others") as [Any]?)?.count ?? 0
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  id != "com.apple.finder", !pinned.contains(id) else { return nil }
            return id
        })
        let showRecents = (pref("show-recents") as NSNumber?)?.boolValue ?? true
        var extras = running.count
        if showRecents {
            let recent: [[String: Any]] = pref("recent-apps") ?? []
            let recentIDs = recent.compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String }
            extras += min(3, recentIDs.filter { !pinned.contains($0) && !running.contains($0) }.count)
        }

        let newItems = 1 + apps.count + extras + others + 1                 // Finder … Trash
        let newSeparators = 1 + (showRecents && extras > 0 ? 1 : 0)
        defer { items = newItems; separators = newSeparators; tile = newTile }
        return newItems != items || newSeparators != separators || newTile != tile
    }

    /// The platter in global top-left coordinates, or nil when the Dock is hidden or on a side.
    func platter(on screens: [ScreenInfo]) -> CGRect? {
        guard let s = screens.first(where: { $0.dockThickness > 0 }) else { return nil }
        let k = tile / Self.referenceTile
        let natural = (2 * Self.edge + CGFloat(max(1, items) - 1) * Self.pitch + CGFloat(separators) * Self.separator) * k
        let fit = min(1, max(0, s.frame.width - 2 * Self.screenMargin) / natural)   // shrinks to fit the screen
        let width = natural * fit, height = Self.height * k * fit
        let bottom = s.frame.maxY - Self.bottomGap
        return CGRect(x: s.frame.midX - width / 2, y: bottom - height, width: width, height: height)
    }

    func cornerRadius(on screens: [ScreenInfo]) -> Float {
        Float((platter(on: screens)?.height ?? Self.height) * Self.radiusPerHeight)
    }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(hi, Swift.max(lo, self)) }
}
