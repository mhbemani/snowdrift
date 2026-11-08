import AppKit

/// The Dock's visible platter (the rounded glass bar), without Accessibility permission.
///
/// macOS reports only the Dock's reserved height T (screen frame minus visible frame); that value
/// is live, and already reflects the Dock shrinking itself when it gets too full. Everything else
/// is a fixed proportion of T, measured from a screenshot of the macOS 26 Dock at T = 79 pt:
///
///     |<-35->( icon )<----54---->( icon ) ... ( icon )<-54+24->( Trash )<-35->|   width = 1390 pt
///     platter: top 4 pt below the reserved area's top, 70 pt tall, corner radius 20 pt
///
/// So width = (2·35 + (items − 1)·54 + separators·24) · T/79, with the items counted the way the
/// Dock lays them out: Finder, pinned apps, running apps that aren't pinned (in a separate
/// "recents" section only when recent apps are shown), then a separator, folders/stacks, Trash.
// ponytail: proportions come from one calibration (T = 79, no magnification, no spacer tiles).
// If snow overhangs the Dock at another Dock size, re-measure and update the constants.
@MainActor
final class DockInfo {
    private static let t0: CGFloat = 79
    private static let edge: CGFloat = 35, pitch: CGFloat = 54, separator: CGFloat = 24
    private static let topInset: CGFloat = 4, platterHeight: CGFloat = 70, cornerRadius: CGFloat = 20

    private var items = 0
    private var separators = 0

    init() { _ = refresh() }

    /// Re-count the Dock's items. Returns true if the count changed.
    func refresh() -> Bool {
        let dock = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(dock)
        func pref<T>(_ key: String) -> T? { CFPreferencesCopyAppValue(key as CFString, dock) as? T }

        let apps: [[String: Any]] = pref("persistent-apps") ?? []
        let pinned = Set(apps.compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String })
        let others = (pref("persistent-others") as [Any]?)?.count ?? 0
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  id != "com.apple.finder", !pinned.contains(id) else { return nil }
            return id
        })
        let showRecents = pref("show-recents") ?? true
        var extras = running.count
        if showRecents {
            let recent: [[String: Any]] = pref("recent-apps") ?? []
            let recentIDs = recent.compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String }
            extras += min(3, recentIDs.filter { !pinned.contains($0) && !running.contains($0) }.count)
        }

        let newItems = 1 + apps.count + extras + others + 1                 // Finder … Trash
        let newSeparators = 1 + (showRecents && extras > 0 ? 1 : 0)
        defer { items = newItems; separators = newSeparators }
        return newItems != items || newSeparators != separators
    }

    /// The platter in global top-left coordinates, or nil when the Dock is hidden or on a side.
    func platter(on screens: [ScreenInfo]) -> CGRect? {
        guard let s = screens.first(where: { $0.dockThickness > 0 }) else { return nil }
        let k = s.dockThickness / Self.t0
        let width = (2 * Self.edge + CGFloat(items - 1) * Self.pitch + CGFloat(separators) * Self.separator) * k
        let top = s.frame.maxY - s.dockThickness + Self.topInset * k
        return CGRect(x: s.frame.midX - width / 2, y: top, width: width, height: Self.platterHeight * k)
    }

    func cornerRadius(on screens: [ScreenInfo]) -> Float {
        Float(Self.cornerRadius * (screens.first(where: { $0.dockThickness > 0 })?.dockThickness ?? Self.t0) / Self.t0)
    }
}
