import AppKit
import os

/// A normal app window, in global coordinates with a top-left origin (points, y down).
struct TrackedWindow {
    var id: CGWindowID
    var frame: CGRect         // position when sampled
    var velocity: CGVector    // points per second, smoothed
}

/// Reads every on-screen window's position. Needs no permission: window bounds are public,
/// only titles/pixels need Screen Recording (which we never ask for).
///
/// Asking WindowServer for the list costs ~1 ms of CPU but can *wait* ~10 ms, so it runs on its
/// own thread (never stalls drawing) at an adaptive rate: ~60 Hz while a mouse button is down
/// (windows are dragged with the mouse) or right after something moved, otherwise 4 Hz.
final class WindowTracker: @unchecked Sendable {
    private struct Snapshot { var windows: [TrackedWindow] = []; var time: CFTimeInterval = 0 }
    private let shared = OSAllocatedUnfairLock(initialState: Snapshot())

    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "snowdrift.windows", qos: .userInteractive)
    private let timer: DispatchSourceTimer
    private var last: [CGWindowID: (frame: CGRect, velocity: CGVector)] = [:]
    private var lastPoll: CFTimeInterval = 0
    private var lastMotion: CFTimeInterval = 0
    private var fast = false
    private var running = true
    private let ownPID = Int(getpid())
    private var polls = 0
    private var pollTime: Double = 0
    private let debug: Bool

    init(debug: Bool = false) {
        self.debug = debug
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [unowned self] in poll() }
        timer.schedule(deadline: .now(), repeating: 0.25, leeway: .milliseconds(20))
        timer.resume()
    }

    /// Latest windows (front to back) and when they were sampled. Cheap: copy-on-write array.
    func snapshot() -> (windows: [TrackedWindow], time: CFTimeInterval) {
        shared.withLock { ($0.windows, $0.time) }
    }

    /// Called by the renderer when a mouse button goes down: switch to fast polling right away.
    func mouseWentDown() {
        queue.async { [self] in if running && !fast { setFast(true); poll() } }
    }

    /// Stop polling entirely while the snow is off or the displays sleep.
    func setRunning(_ on: Bool) {
        queue.async { [self] in
            running = on
            if on { setFast(false); poll() } else { timer.schedule(deadline: .distantFuture, repeating: .never) }
        }
    }

    func stats() -> String {
        queue.sync { String(format: "window polls: %d, avg %.3f ms wall each, %d windows tracked",
                            polls, polls > 0 ? pollTime / Double(polls) * 1000 : 0, last.count) }
    }

    private func setFast(_ on: Bool) {
        fast = on
        let interval = on ? 1.0 / 60 : 0.25
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(on ? 2 : 20))
    }

    private func poll() {
        guard running else { return }
        let now = CACurrentMediaTime()
        let dt = now - lastPoll
        lastPoll = now

        // NSArray/NSDictionary access avoids bridging every dictionary into a Swift Dictionary.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as NSArray?
        else { return }
        var next: [TrackedWindow] = []
        next.reserveCapacity(last.count + 4)
        var nextLast: [CGWindowID: (frame: CGRect, velocity: CGVector)] = [:]
        nextLast.reserveCapacity(last.count + 4)

        // Stage Manager: its strip thumbnails are app windows reported at the (tilted) thumbnail's
        // bounding box, each with a WindowManager overlay at exactly the same bounds. But it also lays
        // an overlay over a full-size window while you drag it (measured: Finder 920x464, Telegram
        // 850x696). What tells them apart: a window going into the strip suddenly *shrinks*.
        var stageThumbs: [CGRect] = []
        for case let w as NSDictionary in list where (w[kCGWindowOwnerName] as? String) == "WindowManager" {
            if let b = w[kCGWindowBounds] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) { stageThumbs.append(r) }
        }

        for case let w as NSDictionary in list {
            guard (w[kCGWindowLayer] as? Int) == 0,                       // normal windows only
                  (w[kCGWindowOwnerPID] as? Int) != ownPID,
                  (w[kCGWindowOwnerName] as? String) != "WindowManager",
                  (w[kCGWindowAlpha] as? Double ?? 1) > 0,
                  let id = w[kCGWindowNumber] as? CGWindowID,
                  let b = w[kCGWindowBounds] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b),
                  r.width >= 40, r.height >= 40                               // skip tiny helper windows
            else { continue }
            if stageThumbs.contains(where: { $0.equalTo(r) }) {
                // Thumbnail if we've never seen it full size, or it just shrank to under half.
                guard let prev = last[id]?.frame,
                      r.width >= prev.width * 0.5 && r.height >= prev.height * 0.5 else { continue }
            }

            var v = CGVector.zero
            if let prev = last[id], dt < 0.1 {
                let raw = CGVector(dx: (r.minX - prev.frame.minX) / dt, dy: (r.minY - prev.frame.minY) / dt)
                // Smooth: WindowServer doesn't update every poll, so raw speed flickers between 0 and 2x.
                v = CGVector(dx: prev.velocity.dx * 0.5 + raw.dx * 0.5, dy: prev.velocity.dy * 0.5 + raw.dy * 0.5)
            }
            if abs(v.dx) + abs(v.dy) > 1 || (last[id] == nil && !last.isEmpty) { lastMotion = now }
            nextLast[id] = (r, v)
            next.append(TrackedWindow(id: id, frame: r, velocity: v))
        }
        if debug {
            // Why did a tracked window stop being tracked? (Its snow falls when that happens.)
            for id in last.keys where nextLast[id] == nil {
                var why = "not in the window list (closed/minimized/other Space)"
                for case let w as NSDictionary in list where (w[kCGWindowNumber] as? CGWindowID) == id {
                    let r = (w[kCGWindowBounds] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
                    why = String(format: "still listed: layer=%d alpha=%.2f owner=%@ bounds=%@ stageOverlayMatch=%d",
                                 w[kCGWindowLayer] as? Int ?? -1, w[kCGWindowAlpha] as? Double ?? -1,
                                 (w[kCGWindowOwnerName] as? String) ?? "?", NSStringFromRect(r),
                                 stageThumbs.contains { $0.equalTo(r) } ? 1 : 0)
                }
                print(String(format: "[%.2f] tracker: window %d dropped: %@", now, id, why))
            }
        }
        last = nextLast
        let snap = Snapshot(windows: next, time: now)
        shared.withLock { $0 = snap }

        let active = CGEventSource.buttonState(.combinedSessionState, button: .left) || now - lastMotion < 0.3
        if active != fast { setFast(active) }
        polls += 1
        pollTime += CACurrentMediaTime() - now
    }
}
