import AppKit

/// Estimates the Dock's visible platter. No API exposes it without Accessibility permission
/// (the Dock's own window is full-screen), so it's computed from the Dock's preferences
/// (read-only) and the running apps.
// ponytail: estimate, off by a few points with odd setups (magnification, many folders).
// Calibrate `spacing`/`padding` by eye with --debug; switch to AXUIElement if exact matters.
@MainActor
final class DockInfo {
    private var items = 0
    private var separators = 0
    private var tile: CGFloat = 48
    private let spacing: CGFloat = 1.0      // item width as a multiple of the tile size
    private let separatorWidth: CGFloat = 0.4
    private let padding: CGFloat = 0.25     // per side, in tiles

    init() { refresh() }

    /// Call at start and when apps launch or quit (running apps get their own Dock icons).
    func refresh() {
        let dock = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(dock)
        func pref<T>(_ key: String) -> T? { CFPreferencesCopyAppValue(key as CFString, dock) as? T }

        tile = pref("tilesize") ?? 48
        let apps: [[String: Any]] = pref("persistent-apps") ?? []
        let others = (pref("persistent-others") as [Any]?)?.count ?? 0
        let recents = (pref("show-recents") ?? true) ? min(3, (pref("recent-apps") as [Any]?)?.count ?? 0) : 0
        let pinned = Set(apps.compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String })
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != "com.apple.finder"
                && !pinned.contains($0.bundleIdentifier ?? "")
        }.count
        items = 1 + apps.count + running + recents + others + 1          // Finder … Trash
        separators = 1 + (running + recents > 0 ? 1 : 0)
    }

    /// The platter in global top-left coordinates, or nil when the Dock is hidden or on the side.
    func platter(on screens: [ScreenInfo]) -> CGRect? {
        guard let s = screens.first(where: { $0.dockThickness > 0 }) else { return nil }
        let width = tile * (CGFloat(items) * spacing + CGFloat(separators) * separatorWidth + 2 * padding)
        let top = s.frame.maxY - s.dockThickness + 4
        return CGRect(x: s.frame.midX - width / 2, y: top, width: width, height: s.frame.maxY - top)
    }
}
