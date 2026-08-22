// BetterSongifyNotifier is a resident, LSUIElement menu-bar companion.
// Spotify remains authoritative: distributed notifications only invalidate the
// cached PlaybackSnapshot; one coalesced AppleEvents read supplies UI and POST
// notification delivery. The legacy Node socket helper remains in tools/ only
// as a rollback source and is deliberately not packaged in this app.

import AppKit
import Foundation
import Network
import ServiceManagement
import UserNotifications

private let notifierBundleID = "io.bettersongify.notifier"
private let notifierPort: UInt16 = 17_352
// Mirrors the panel's menuBarSong setting so the item's visibility survives a
// login before Spotify (and the injected script) has started.
private let menuBarVisibleDefaultsKey = "menuBarSongVisible"
// ControlCenter can permanently refuse to place any status item belonging to a
// bundle identifier; running that bundle's binary directly instead of launching
// the app is what provokes it. The block is keyed to the exact identifier, so a
// nested helper bundle with its own identifier still draws, while
// io.bettersongify.notifier keeps owning notifications and Automation. Off by
// default: a clean install hosts the item itself and never launches the helper.
private let menuBarHelperBundleID = "io.bettersongify.notifier.menubar"
private let menuBarHelperDefaultsKey = "menuBarUseHelper"
private let menuBarHelperArgument = "--menubar-helper"
private let snapshotNotificationName = Notification.Name("io.bettersongify.notifier.snapshot")
private let actionNotificationName = Notification.Name("io.bettersongify.notifier.action")
private let fieldSeparator = " |;| "
// src/index.js aborts its desktop POST at 5000 ms. Pre-submission work must
// cancel before that so its toast fallback cannot race a late native delivery.
private let productionProcessingTimeout: TimeInterval = 4.0

enum PlaybackStatus: Equatable {
    case playing, paused, stopped, spotifyNotRunning, automationUnavailable, unknown

    // Wire form for the helper bridge. Spelled out rather than derived so a
    // rename of a case cannot silently change the protocol.
    var rawName: String {
        switch self {
        case .playing: return "playing"
        case .paused: return "paused"
        case .stopped: return "stopped"
        case .spotifyNotRunning: return "spotifyNotRunning"
        case .automationUnavailable: return "automationUnavailable"
        case .unknown: return "unknown"
        }
    }

    init(rawName: String) {
        switch rawName {
        case "playing": self = .playing
        case "paused": self = .paused
        case "stopped": self = .stopped
        case "spotifyNotRunning": self = .spotifyNotRunning
        case "automationUnavailable": self = .automationUnavailable
        default: self = .unknown
        }
    }

    var text: String {
        switch self {
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .stopped: return "Spotify stopped"
        case .spotifyNotRunning: return "Spotify not running"
        case .automationUnavailable: return "Spotify access unavailable"
        case .unknown: return "Spotify unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .playing: return "play.fill"
        case .paused: return "pause.fill"
        case .stopped: return "stop.fill"
        case .spotifyNotRunning, .automationUnavailable, .unknown: return "minus"
        }
    }
}

struct PlaybackSnapshot: Equatable {
    let title: String?
    let artist: String?
    let album: String?
    let artworkURL: String?
    let status: PlaybackStatus
    // Playback position and track length in seconds, plus the moment the
    // position was read. Progress is interpolated from capturedAt between
    // reads: an AppleEvents round trip costs ~150 ms, far too much to spend
    // once a second just to advance a progress bar.
    let position: Double
    let duration: Double
    let capturedAt: Date

    init(title: String?, artist: String?, album: String?, artworkURL: String?, status: PlaybackStatus,
         position: Double = 0, duration: Double = 0, capturedAt: Date = Date()) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.status = status
        self.position = position
        self.duration = duration
        self.capturedAt = capturedAt
    }

    // capturedAt is deliberately excluded: it differs on every read, so
    // including it would report an unchanged track as a change on each recovery
    // tick. position is included so a seek — including one made while paused —
    // still re-renders.
    static func == (lhs: PlaybackSnapshot, rhs: PlaybackSnapshot) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album
            && lhs.artworkURL == rhs.artworkURL && lhs.status == rhs.status
            && lhs.position == rhs.position && lhs.duration == rhs.duration
    }

    static let unavailable = PlaybackSnapshot(title: nil, artist: nil, album: nil, artworkURL: nil, status: .spotifyNotRunning)

    var displayTitle: String? {
        guard let title, !title.isEmpty else { return nil }
        return title
    }

    var marqueeText: String {
        guard let title = displayTitle else { return status.text }
        guard let artist, !artist.isEmpty else { return title }
        return "\(title) — \(artist)"
    }

    // Only a loaded track has a position to show; a stopped or unreachable
    // Spotify reports zeroes, which must not render as a bar parked at 0:00.
    var hasTiming: Bool { duration > 0 && (status == .playing || status == .paused) }

    func elapsed(at now: Date = Date()) -> Double {
        guard hasTiming else { return 0 }
        let advance = status == .playing ? max(0, now.timeIntervalSince(capturedAt)) : 0
        return min(max(position + advance, 0), duration)
    }

    func fraction(at now: Date = Date()) -> Double {
        guard hasTiming else { return 0 }
        return elapsed(at: now) / duration
    }

    // Distributed notifications carry only property-list types, and every value
    // here is a String so no numeric bridging can change a value in flight.
    var userInfo: [String: String] {
        var info: [String: String] = [
            "status": status.rawName,
            "position": String(position),
            "duration": String(duration),
            "capturedAt": String(capturedAt.timeIntervalSince1970),
        ]
        if let title { info["title"] = title }
        if let artist { info["artist"] = artist }
        if let album { info["album"] = album }
        if let artworkURL { info["artworkURL"] = artworkURL }
        return info
    }

    init(userInfo: [String: String]) {
        self.init(title: userInfo["title"], artist: userInfo["artist"], album: userInfo["album"],
                  artworkURL: userInfo["artworkURL"],
                  status: PlaybackStatus(rawName: userInfo["status"] ?? "unknown"),
                  position: Double(userInfo["position"] ?? "") ?? 0,
                  duration: Double(userInfo["duration"] ?? "") ?? 0,
                  capturedAt: Date(timeIntervalSince1970: Double(userInfo["capturedAt"] ?? "")
                                   ?? Date().timeIntervalSince1970))
    }

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write("BetterSongifyNotifier: \(message)\n".data(using: .utf8)!)
}

private func cleanMetadata(_ input: String?) -> String? {
    guard let input else { return nil }
    let withoutControls = String(input.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    let value = withoutControls.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

private func sanitizedFallback(_ input: String?) -> String? { cleanMetadata(input).map { String($0.prefix(200)) } }

private func validArtwork(_ input: String?) -> String? {
    guard let value = cleanMetadata(input), let url = URL(string: value),
          url.scheme == "https", url.host == "i.scdn.co", url.port == nil,
          url.user == nil, url.password == nil, url.path.hasPrefix("/image/") else { return nil }
    return value
}

// MARK: - Spotify authority

final class SpotifyPlaybackMonitor {
    private let workQueue = DispatchQueue(label: "io.bettersongify.notifier.spotify", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []
    // Scheduling state is workQueue-only. Generations ensure a POST received
    // during a read waits for a subsequent authoritative AppleEvents read.
    private var refreshInFlight = false
    private var refreshScheduled = false
    private var needsFollowup = false
    private var requestGeneration = 0
    private var completions: [(Int, (PlaybackSnapshot) -> Void)] = []
    private(set) var snapshot = PlaybackSnapshot.unavailable
    var onSnapshot: ((PlaybackSnapshot) -> Void)?
    // Both fire only on observed transitions, never for the state Spotify
    // happens to be in at launch — this app is resident and starts in whichever
    // state it finds, so AppDelegate seeds itself from isSpotifyRunning instead.
    // Delivered on the main thread because they drive the status item.
    var onSpotifyLaunched: (() -> Void)?
    var onSpotifyTerminated: (() -> Void)?

    static var isSpotifyRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: nil) { [weak self] _ in
            self?.refresh()
        })
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] notification in
            if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.spotify.client" {
                DispatchQueue.main.async { self?.onSpotifyLaunched?() }
                self?.refresh()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] notification in
            if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.spotify.client" {
                DispatchQueue.main.async { self?.deliver(.unavailable); self?.onSpotifyTerminated?() }
            }
        })
        refresh()
    }

    func stop() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.forEach { distributed.removeObserver($0); workspace.removeObserver($0) }
        observers.removeAll()
    }

    // Coalesces invalidations and serializes all AppleEvents work. The settle
    // delay lets Spotify finish its title/artist/state mutation burst.
    func refresh(completion: ((PlaybackSnapshot) -> Void)? = nil) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.requestGeneration += 1
            let generation = self.requestGeneration
            if let completion { self.completions.append((generation, completion)) }
            if self.refreshInFlight { self.needsFollowup = true; return }
            self.scheduleRead()
        }
    }

    private func scheduleRead() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        workQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            guard !self.refreshInFlight else { self.needsFollowup = true; return }
            self.refreshInFlight = true
            let readGeneration = self.requestGeneration
            self.finishRead(self.readSpotifySnapshot(), generation: readGeneration)
        }
    }

    private func finishRead(_ fresh: PlaybackSnapshot, generation: Int) {
        // Still on workQueue: never mutate this state from the main queue.
        refreshInFlight = false
        let ready = completions.filter { $0.0 <= generation }.map { $0.1 }
        completions.removeAll { $0.0 <= generation }
        let followup = needsFollowup || !completions.isEmpty
        needsFollowup = false
        if followup { scheduleRead() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deliver(fresh)
            ready.forEach { $0(fresh) }
        }
    }

    private func deliver(_ fresh: PlaybackSnapshot) {
        precondition(Thread.isMainThread)
        let changed = fresh != snapshot
        snapshot = fresh
        if changed { onSnapshot?(fresh) }
    }

    private func readSpotifySnapshot() -> PlaybackSnapshot {
        // Load-bearing for the resident lifecycle, not just an optimisation: an
        // AppleEvent to a stopped Spotify would launch it, so an app that is now
        // alive at login must never send one before it sees Spotify running.
        guard SpotifyPlaybackMonitor.isSpotifyRunning else {
            return .unavailable
        }
        // "player position" is a real in seconds; "div 1" truncates it to an
        // integer without Standard Additions' round, whose terminology would
        // have to resolve inside this application tell block, and without a
        // locale-dependent decimal separator in the string form. Track duration
        // is an integer in MILLISECONDS (Spotify's dictionary, verified against
        // the client August 2026) and is converted below.
        let source = """
        tell application id "com.spotify.client"
          try
            set playerState to (player state as string)
            if playerState is "stopped" then return playerState & "\(fieldSeparator)" & "" & "\(fieldSeparator)" & "" & "\(fieldSeparator)" & "" & "\(fieldSeparator)" & "" & "\(fieldSeparator)" & "0" & "\(fieldSeparator)" & "0"
            set currentTrack to current track
            set elapsedSeconds to ((player position) div 1) as string
            set trackDuration to (duration of currentTrack) as string
            return playerState & "\(fieldSeparator)" & name of currentTrack & "\(fieldSeparator)" & artist of currentTrack & "\(fieldSeparator)" & album of currentTrack & "\(fieldSeparator)" & artwork url of currentTrack & "\(fieldSeparator)" & elapsedSeconds & "\(fieldSeparator)" & trackDuration
          on error
            return "unknown\(fieldSeparator)\(fieldSeparator)\(fieldSeparator)\(fieldSeparator)\(fieldSeparator)\(fieldSeparator)"
          end try
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return PlaybackSnapshot(title: nil, artist: nil, album: nil, artworkURL: nil, status: .automationUnavailable) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let value = result.stringValue else {
            log("Spotify refresh failed: \(error?[NSAppleScript.errorMessage] ?? "unknown error")")
            return PlaybackSnapshot(title: nil, artist: nil, album: nil, artworkURL: nil, status: .automationUnavailable)
        }
        let parts = value.components(separatedBy: fieldSeparator)
        guard parts.count == 7 else { return PlaybackSnapshot(title: nil, artist: nil, album: nil, artworkURL: nil, status: .unknown) }
        let status: PlaybackStatus
        switch parts[0].lowercased() {
        case "playing": status = .playing
        case "paused": status = .paused
        case "stopped": status = .stopped
        case "unknown": status = .automationUnavailable
        default: status = .unknown
        }
        return PlaybackSnapshot(title: cleanMetadata(parts[1]), artist: cleanMetadata(parts[2]), album: cleanMetadata(parts[3]),
                                artworkURL: validArtwork(parts[4]), status: status,
                                position: max(0, Double(parts[5]) ?? 0), duration: max(0, (Double(parts[6]) ?? 0) / 1000))
    }
}

// MARK: - Status item

// Shared by the menu's now-playing row and the status item, where the same bar
// is drawn as a hairline under the title. Rounded on both ends, so a fill
// narrower than its own height is widened to the cap: a sliver of a rounded
// rect reads as a stray dot rather than as progress.
final class ProgressBarView: NSView {
    var fraction: CGFloat = 0 { didSet { if fraction != oldValue { needsDisplay = true } } }
    var trackColor: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }
    var fillColor: NSColor = .labelColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let radius = bounds.height / 2
        trackColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return }
        fillColor.setFill()
        let width = min(bounds.width, max(bounds.height, bounds.width * clamped))
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: radius, yRadius: radius).fill()
    }

    // Clicks belong to whatever hosts the bar: the status button that owns the
    // menu, or the non-interactive now-playing menu item.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// Song/artist/status plus cover art live in one view-based item because a
// stock NSMenuItem can only place its image leading of the title. The progress
// row below them is part of the same view for the same reason.
final class NowPlayingMenuView: NSView {
    private static let artworkSide: CGFloat = 52
    private static let inset: CGFloat = 14
    // The song/artist/status block and its cover art; the progress row sits
    // under it and is hidden (leaving the reserved strip blank) when Spotify
    // reports no playing or paused track.
    private static let headerHeight: CGFloat = 76
    private static let timeWidth: CGFloat = 60
    private let songField = NowPlayingMenuView.makeLabel(secondary: false)
    private let artistField = NowPlayingMenuView.makeLabel(secondary: true)
    private let statusField = NowPlayingMenuView.makeLabel(secondary: true)
    private let elapsedField = NowPlayingMenuView.makeTimeLabel(alignment: .left)
    private let durationField = NowPlayingMenuView.makeTimeLabel(alignment: .right)
    private let progressView = ProgressBarView()
    private let artworkView = NSImageView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 104))
        let side = NowPlayingMenuView.artworkSide, inset = NowPlayingMenuView.inset
        artworkView.frame = NSRect(x: bounds.width - inset - side, y: (NowPlayingMenuView.headerHeight - side) / 2, width: side, height: side)
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 6
        artworkView.layer?.masksToBounds = true
        addSubview(artworkView)
        let textWidth = artworkView.frame.minX - 12 - inset
        for (index, field) in [songField, artistField, statusField].enumerated() {
            field.frame = NSRect(x: inset, y: 13 + CGFloat(index) * 17, width: textWidth, height: 17)
            addSubview(field)
        }
        progressView.frame = NSRect(x: inset, y: 74, width: bounds.width - inset * 2, height: 4)
        progressView.trackColor = .quaternaryLabelColor
        progressView.fillColor = .labelColor
        addSubview(progressView)
        elapsedField.frame = NSRect(x: inset, y: 82, width: NowPlayingMenuView.timeWidth, height: 14)
        durationField.frame = NSRect(x: bounds.width - inset - NowPlayingMenuView.timeWidth, y: 82, width: NowPlayingMenuView.timeWidth, height: 14)
        addSubview(elapsedField)
        addSubview(durationField)
        renderArtwork(nil)
    }

    required init?(coder: NSCoder) { nil }

    private static func makeLabel(secondary: Bool) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .menuFont(ofSize: 0)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    private static func makeTimeLabel(alignment: NSTextAlignment) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        // Monospaced digits: the elapsed time changes every second and a
        // proportional font would jitter the whole label as digits swap.
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.alignment = alignment
        return field
    }

    func update(_ snapshot: PlaybackSnapshot, artwork: NSImage?) {
        songField.stringValue = "Song: \(snapshot.title ?? "Unavailable")"
        artistField.stringValue = "Artist: \(snapshot.artist ?? "Unavailable")"
        statusField.stringValue = "Status: \(snapshot.status.text)"
        updateProgress(snapshot)
        renderArtwork(artwork)
    }

    // Called on its own every progress tick: re-running update() would reset
    // the artwork and text fields once a second for nothing.
    func updateProgress(_ snapshot: PlaybackSnapshot) {
        let timed = snapshot.hasTiming
        progressView.isHidden = !timed
        elapsedField.isHidden = !timed
        durationField.isHidden = !timed
        guard timed else { return }
        progressView.fraction = CGFloat(snapshot.fraction())
        elapsedField.stringValue = PlaybackSnapshot.timeText(snapshot.elapsed())
        durationField.stringValue = PlaybackSnapshot.timeText(snapshot.duration)
    }

    private func renderArtwork(_ artwork: NSImage?) {
        if let artwork {
            artworkView.image = artwork
            artworkView.contentTintColor = nil
            artworkView.layer?.backgroundColor = nil
            return
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "No cover art")?
            .withSymbolConfiguration(configuration)
        artworkView.contentTintColor = .tertiaryLabelColor
        artworkView.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
    }
}

// Left-aligned, pixel-scrolled text under a gradient fade. NSStatusBarButton
// is deliberately not used for the label: it centres its title, so a marquee
// built from per-character slices pulses about the centre instead of
// translating, and slices of a proportional font change width every step.
final class MarqueeTextView: NSView {
    private let fadeLayer = CAGradientLayer()
    var attributed: NSAttributedString? { didSet { needsDisplay = true } }
    var offset: CGFloat = 0 { didSet { needsDisplay = true } }
    // Distance to the second copy of the text. Drawing the string twice is what
    // makes the wrap seamless: the start re-enters on the right as the end
    // leaves on the left, so offset can reset to 0 with nothing visibly jumping.
    var repeatAt: CGFloat? { didSet { needsDisplay = true } }
    // Fade width at each edge, in points, and never a flag: an edge that
    // switches from no mask to a full 12 pt gradient dims characters that were
    // crisp one tick earlier. The owner ramps these in with the pixels that
    // are actually hidden, so the first character darkens as it leaves rather
    // than the instant the title starts moving. Clamped here to a quarter of
    // the width so a narrow item cannot fade its whole title away.
    var fadeLeading: CGFloat = 0 { didSet { if fadeLeading != oldValue { applyFade() } } }
    var fadeTrailing: CGFloat = 0 { didSet { if fadeTrailing != oldValue { applyFade() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fadeLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fadeLayer.endPoint = CGPoint(x: 1, y: 0.5)
        fadeLayer.colors = [NSColor.clear, .black, .black, NSColor.clear].map(\.cgColor)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        applyFade()
    }

    private func applyFade() {
        guard bounds.width > 0 else { layer?.mask = nil; return }
        let limit = bounds.width / 4
        let lead = min(max(0, fadeLeading), limit)
        let trail = min(max(0, fadeTrailing), limit)
        guard lead > 0 || trail > 0 else { layer?.mask = nil; return }
        // Disabled actions: without this the mask animates on every change,
        // which at 30 Hz means the gradient chasing the offset a frame behind.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeLayer.locations = [0, NSNumber(value: Double(lead / bounds.width)),
                               NSNumber(value: Double(1 - trail / bounds.width)), 1]
        fadeLayer.frame = bounds
        layer?.mask = fadeLayer
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let attributed else { return }
        let y = (bounds.height - attributed.size().height) / 2
        attributed.draw(at: NSPoint(x: -offset, y: y))
        if let repeatAt { attributed.draw(at: NSPoint(x: repeatAt - offset, y: y)) }
    }

    // Clicks belong to the enclosing NSStatusBarButton, which owns the menu.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class MarqueeStatusView: NSView {
    static let leadingInset: CGFloat = 6
    static let iconGap: CGFloat = 6
    static let trailingInset: CGFloat = 8
    static let iconWidth: CGFloat = 14
    private static let pointsPerSecond: CGFloat = 26
    // Dwell happens only at the start of the title, never at the end.
    private static let startDwell: TimeInterval = 5
    // Blank run between the end of the title and its repeat, so the wrap reads
    // as "the title came round again" rather than as a stutter.
    private static let loopGap: CGFloat = 44
    // Widest either edge fades. Narrower than loopGap on purpose: the blank
    // run is what lets the trailing fade hand over from the end of one copy to
    // the start of the next without the switch landing on visible pixels.
    private static let fadeWidth: CGFloat = 12
    // Progress hairline under the icon and title. The strip is reserved
    // whether or not the line is drawn, so the title never shifts vertically
    // when a track stops or starts.
    private static let progressHeight: CGFloat = 2
    private static let progressBottomInset: CGFloat = 2

    private let iconView = NSImageView()
    private let textView = MarqueeTextView(frame: .zero)
    private let progressView = ProgressBarView()
    private var textWidth: CGFloat = 0
    private var offset: CGFloat = 0
    private var dwellUntil = Date.distantPast
    private var lastTick = Date()
    private var timer: Timer?
    private var text = ""
    private var isPlaying = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        addSubview(textView)
        progressView.isHidden = true
        addSubview(progressView)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let side = MarqueeStatusView.iconWidth
        let reserved = MarqueeStatusView.progressHeight + MarqueeStatusView.progressBottomInset
        let contentHeight = max(0, bounds.height - reserved)
        iconView.frame = NSRect(x: MarqueeStatusView.leadingInset, y: (contentHeight - side) / 2, width: side, height: side)
        textView.frame = NSRect(x: iconView.frame.maxX + MarqueeStatusView.iconGap, y: 0,
                                width: max(0, bounds.width - iconView.frame.maxX - MarqueeStatusView.iconGap - MarqueeStatusView.trailingInset),
                                height: contentHeight)
        // Spans icon and title together — it is the whole item's progress, not
        // the label's.
        progressView.frame = NSRect(x: MarqueeStatusView.leadingInset, y: contentHeight,
                                    width: max(0, bounds.width - MarqueeStatusView.leadingInset - MarqueeStatusView.trailingInset),
                                    height: MarqueeStatusView.progressHeight)
        syncScrollState()
    }

    static func measure(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.menuBarFont(ofSize: 0)]).width)
    }

    func update(text: String, symbol: String, accessibility: String, playing: Bool) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        iconView.image?.isTemplate = true
        // Play/pause is handled before the unchanged-title early-return: the
        // same track pausing is exactly the case that has to start or stop the
        // scroll. Resuming re-dwells at the title's start, where the pause
        // parked it.
        if playing != isPlaying {
            isPlaying = playing
            if playing { offset = 0; dwellUntil = Date().addingTimeInterval(MarqueeStatusView.startDwell) }
            syncScrollState()
        }
        guard text != self.text else { applyColors(); return }
        self.text = text
        textWidth = MarqueeStatusView.measure(text)
        offset = 0; dwellUntil = Date().addingTimeInterval(MarqueeStatusView.startDwell)
        applyColors()
        syncScrollState()
    }

    // Progress is set on its own rather than through update(text:…), which
    // early-returns on an unchanged title — the fraction changes every tick
    // while the title stands still. nil hides the line entirely.
    func setProgress(_ fraction: CGFloat?) {
        progressView.isHidden = fraction == nil
        progressView.fraction = fraction ?? 0
    }

    // The status item inverts its content while the menu is open.
    func applyColors() {
        let highlighted = (superview as? NSStatusBarButton)?.isHighlighted ?? false
        let color: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        iconView.contentTintColor = color
        textView.attributed = NSAttributedString(string: text, attributes: [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: color])
        progressView.fillColor = color
        progressView.trackColor = color.withAlphaComponent(0.25)
        applyOffset()
    }

    // Every title scrolls while it plays, including one that fits: the motion
    // is what marks the item as the now-playing title, and a track whose name
    // happens to be short should not read as a different kind of item. Nothing
    // scrolls while playback is stopped or paused — motion there reads as
    // playback that has not actually stopped.
    private var scrolls: Bool { isPlaying && textWidth > 0 && textView.bounds.width > 0 }
    // One full cycle: the whole title plus the blank gap before it repeats.
    private var loopWidth: CGFloat { textWidth + MarqueeStatusView.loopGap }

    // The timer exists only while there is something to scroll: a resident
    // menu-bar app must not wake 30x a second to early-return.
    private func syncScrollState() {
        guard scrolls else {
            stopScrolling()
            offset = 0
            textView.repeatAt = nil
            applyOffset()
            return
        }
        textView.repeatAt = loopWidth
        if offset >= loopWidth { offset = 0 }
        applyOffset()
        guard timer == nil else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopScrolling() { timer?.invalidate(); timer = nil }

    private func applyOffset() {
        textView.offset = offset
        // Fade the left edge only while the title itself is clipped there.
        // Past textWidth the first copy has fully exited and the left edge
        // holds the blank gap, so fading it would pop the leading character
        // back to crisp at the wrap.
        // The leading fade is exactly as wide as the text already hidden off
        // the left edge, up to fadeWidth, so it grows in with the scroll.
        // Past textWidth the first copy has fully exited and the left edge
        // holds the blank gap, so there is nothing left to fade.
        textView.fadeLeading = offset < textWidth ? min(MarqueeStatusView.fadeWidth, offset) : 0
        // Trailing likewise tracks the overhang past the right edge, which
        // covers the static case too: a title too long for the item stays
        // faded while paused, rather than ending in a hard cut. Once the
        // second copy is on screen there is always more title arriving, and
        // that handover happens while the blank gap covers the right edge.
        let visible = textView.bounds.width
        textView.fadeTrailing = scrolls && loopWidth - offset < visible
            ? MarqueeStatusView.fadeWidth
            : min(MarqueeStatusView.fadeWidth, max(0, textWidth - offset - visible))
    }

    @objc private func tick() {
        let now = Date()
        let elapsed = CGFloat(now.timeIntervalSince(lastTick))
        lastTick = now
        guard now >= dwellUntil, scrolls else { return }
        offset += MarqueeStatusView.pointsPerSecond * elapsed
        // Forward only. The second copy has reached the left edge, so resetting
        // to 0 is the same picture — then hold at the title's start.
        if offset >= loopWidth {
            offset = 0
            dwellUntil = now.addingTimeInterval(MarqueeStatusView.startDwell)
        }
        applyOffset()
    }

    func stop() { stopScrolling() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class StatusItemController: NSObject, NSMenuDelegate {
    // Long titles cap here and scroll; short ones make the item hug its text.
    private static let maxTextWidth: CGFloat = 170
    private static let minTextWidth: CGFloat = 44
    private let item = NSStatusBar.system.statusItem(withLength: 0)
    private let menu = NSMenu()
    private let nowPlayingItem = NSMenuItem()
    private let nowPlayingView = NowPlayingMenuView()
    private let marqueeView = MarqueeStatusView(frame: .zero)
    private let artworkLoader = MenuArtworkLoader()
    private var snapshot = PlaybackSnapshot.unavailable
    private var progressTimer: Timer?
    var onOpenSpotify: (() -> Void)?
    // Opening the menu re-reads Spotify, so a track the user scrubbed since the
    // last refresh shows its real position rather than the interpolated one.
    var onMenuOpen: (() -> Void)?

    override init() {
        super.init()
        guard let button = item.button else { return }
        button.title = ""
        button.image = nil
        marqueeView.autoresizingMask = [.width, .height]
        marqueeView.frame = button.bounds
        button.addSubview(marqueeView)
        nowPlayingItem.view = nowPlayingView
        menu.addItem(nowPlayingItem); menu.addItem(.separator())
        menu.addItem(withTitle: "Open Spotify", action: #selector(openSpotify), keyEquivalent: "")
        menu.items.forEach { $0.target = $0.target ?? self }
        menu.delegate = self
        item.menu = menu
        artworkLoader.onImage = { [weak self] in self?.renderNowPlaying() }
        render()
    }

    func update(_ snapshot: PlaybackSnapshot) {
        precondition(Thread.isMainThread)
        self.snapshot = snapshot
        artworkLoader.load(snapshot.artworkURL)
        renderNowPlaying()
        render()
        syncProgressTimer()
        renderProgress()
    }

    private func renderNowPlaying() { nowPlayingView.update(snapshot, artwork: artworkLoader.image) }

    private func renderProgress() {
        marqueeView.setProgress(snapshot.hasTiming ? CGFloat(snapshot.fraction()) : nil)
        nowPlayingView.updateProgress(snapshot)
    }

    // Ticks only while a timed track is actually playing: a paused position
    // does not move, and a resident menu-bar app must not wake to
    // early-return. One second matches the menu's mm:ss labels; the pill's
    // hairline advances well under a point per tick at any track length.
    private func syncProgressTimer() {
        guard snapshot.status == .playing, snapshot.hasTiming else {
            progressTimer?.invalidate()
            progressTimer = nil
            return
        }
        guard progressTimer == nil else { return }
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(progressTick), userInfo: nil, repeats: true)
        // .common so it keeps ticking while the menu is open, which is exactly
        // when the elapsed label is on screen.
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    @objc private func progressTick() { renderProgress() }

    // Width is recomputed only here, never per scroll tick, so the item and
    // its menu-bar neighbours stay put while the text moves inside it.
    private func render() {
        let text = snapshot.marqueeText
        let chrome = MarqueeStatusView.leadingInset + MarqueeStatusView.iconWidth + MarqueeStatusView.iconGap + MarqueeStatusView.trailingInset
        let textWidth = min(max(StatusItemController.minTextWidth, MarqueeStatusView.measure(text)), StatusItemController.maxTextWidth)
        item.length = chrome + textWidth
        marqueeView.update(text: text, symbol: snapshot.status.symbol, accessibility: snapshot.status.text, playing: snapshot.status == .playing)
        item.button?.toolTip = text
    }

    func menuWillOpen(_ menu: NSMenu) {
        onMenuOpen?()
        DispatchQueue.main.async { self.marqueeView.applyColors() }
    }
    func menuDidClose(_ menu: NSMenu) { DispatchQueue.main.async { self.marqueeView.applyColors() } }

    @objc private func openSpotify() { onOpenSpotify?() }
    func stop() {
        progressTimer?.invalidate(); progressTimer = nil
        marqueeView.stop(); artworkLoader.cancel(); NSStatusBar.system.removeStatusItem(item)
    }
}

// Menu cover art reuses ArtworkDownload so the CDN host pinning, redirect
// checks, and 2 MB ceiling that guard notification attachments also guard
// anything drawn in the menu.
final class MenuArtworkLoader {
    private var currentURL: String?
    private var delivery: NotificationDelivery?
    private(set) var image: NSImage?
    var onImage: (() -> Void)?

    func load(_ url: String?) {
        precondition(Thread.isMainThread)
        let validated = url.flatMap(validArtwork)
        guard validated != currentURL else { return }
        cancel()
        currentURL = validated
        image = nil
        onImage?()
        guard let validated, let target = URL(string: validated) else { return }
        let delivery = NotificationDelivery()
        self.delivery = delivery
        ArtworkDownload(url: target, delivery: delivery) { [weak self] file in
            guard let file else { return }
            let loaded = NSImage(contentsOf: file)
            discardArtworkFile(file)
            DispatchQueue.main.async {
                // A newer track may have superseded this download in flight.
                guard let self, self.currentURL == validated else { return }
                self.image = loaded
                self.onImage?()
            }
        }.start()
    }

    func cancel() {
        _ = delivery?.cancelIfPending()
        delivery = nil
    }
}

// MARK: - Notifications

struct NotificationFallback { let title: String?; let artist: String?; let artwork: String? }

// A request owns this token. Cancellation wins before submission; once
// submission is atomically claimed, HTTP waits for center.add's completion so
// it never emits a toast-causing timeout after a native notification started.
final class NotificationDelivery {
    private let lock = NSLock()
    private var cancelled = false
    private var submitted = false
    private var cleanup: (() -> Void)?
    // Registering after cancellation runs cleanup immediately. Cancellation
    // extracts its hook under lock then calls it after unlocking.
    func registerCleanup(_ hook: @escaping () -> Void) -> Bool {
        lock.lock()
        if cancelled { lock.unlock(); hook(); return false }
        if submitted { lock.unlock(); return false }
        cleanup = hook; lock.unlock(); return true
    }
    func cancelIfPending() -> Bool {
        lock.lock(); guard !submitted, !cancelled else { lock.unlock(); return false }
        cancelled = true; let hook = cleanup; cleanup = nil; lock.unlock(); hook?(); return true
    }
    func beginSubmission() -> Bool { lock.lock(); defer { lock.unlock() }; guard !cancelled, !submitted else { return false }; submitted = true; cleanup = nil; return true }
    func clearCleanup() { lock.lock(); cleanup = nil; lock.unlock() }
    // The passed system-call initiation must be asynchronous by API contract.
    // Holding this tiny lock through initiation makes cancellation and "start"
    // one atomic decision, but never spans a callback or arbitrary async work.
    @discardableResult func startIfPending(_ start: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !submitted else { return false }
        start()
        return true
    }
    @discardableResult func startSubmission(_ start: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !submitted else { return false }
        submitted = true; cleanup = nil
        start()
        return true
    }
    var canContinue: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled && !submitted }
    var isSubmitted: Bool { lock.lock(); defer { lock.unlock() }; return submitted }
}

private func discardArtworkFile(_ file: URL?) { if let file { try? FileManager.default.removeItem(at: file) } }

// Streams rather than buffers arbitrary artwork responses. Redirects and the
// final response must remain Spotify CDN HTTPS image endpoints; data over 2 MB
// is cancelled before it can be retained in memory.
private final class ArtworkDownload: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let url: URL; private let delivery: NotificationDelivery; private let completion: (URL?) -> Void
    private var session: URLSession?; private var task: URLSessionDataTask?; private var data = Data(); private var accepted = false; private var completed = false
    init(url: URL, delivery: NotificationDelivery, completion: @escaping (URL?) -> Void) { self.url = url; self.delivery = delivery; self.completion = completion }
    func start() {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        task = session?.dataTask(with: url)
        guard delivery.registerCleanup({ [weak self] in self?.cancelImmediately() }) else { return }
        task?.resume()
    }
    private func cancelImmediately() { task?.cancel(); session?.invalidateAndCancel() }
    private func finish(_ file: URL?) { guard !completed else { return }; completed = true; task = nil; delivery.clearCleanup(); session?.finishTasksAndInvalidate(); completion(file) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard delivery.canContinue, let target = request.url, validArtwork(target.absoluteString) != nil else { completionHandler(nil); finish(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard delivery.canContinue, validArtwork(response.url?.absoluteString) != nil,
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              response.mimeType?.lowercased().hasPrefix("image/") == true else { completionHandler(.cancel); finish(nil); return }
        accepted = true; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard delivery.canContinue, accepted, data.count + chunk.count <= 2_000_000 else { dataTask.cancel(); finish(nil); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error == nil, accepted, !data.isEmpty, delivery.canContinue else { finish(nil); return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("better-songify-art-\(UUID().uuidString).jpg")
        do { try data.write(to: file, options: .atomic); finish(file) } catch { finish(nil) }
    }
}
protocol NotificationDelivering: AnyObject { @discardableResult func notify(fallback: NotificationFallback, completion: @escaping (Bool, String?) -> Void) -> NotificationDelivery }

final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate, NotificationDelivering {
    private let monitor: SpotifyPlaybackMonitor
    init(monitor: SpotifyPlaybackMonitor) { self.monitor = monitor; super.init(); UNUserNotificationCenter.current().delegate = self }

    @discardableResult func notify(fallback: NotificationFallback, completion: @escaping (Bool, String?) -> Void) -> NotificationDelivery {
        let delivery = NotificationDelivery()
        monitor.refresh { [weak self] live in
            guard let self, delivery.canContinue else { return }
            let title = live.title ?? fallback.title
            guard let title else { completion(false, "No Spotify track is available"); return }
            self.authorizeAndDeliver(delivery: delivery, title: title, artist: live.artist ?? fallback.artist, album: live.album, artwork: live.artworkURL ?? fallback.artwork, completion: completion)
        }
        return delivery
    }

    private func authorizeAndDeliver(delivery: NotificationDelivery, title: String, artist: String?, album: String?, artwork: String?, completion: @escaping (Bool, String?) -> Void) {
        let center = UNUserNotificationCenter.current()
        delivery.startIfPending {
            center.getNotificationSettings { [weak self] settings in
            guard delivery.canContinue else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self?.deliver(delivery: delivery, title: title, artist: artist, album: album, artwork: artwork, completion: completion)
            case .notDetermined:
                delivery.startIfPending {
                    center.requestAuthorization(options: [.alert]) { granted, error in
                    guard delivery.canContinue else { return }
                    guard granted, error == nil else { completion(false, error?.localizedDescription ?? "Notifications are not authorized"); return }
                    self?.deliver(delivery: delivery, title: title, artist: artist, album: album, artwork: artwork, completion: completion)
                }
                }
            default: completion(false, "Notifications are not authorized")
            }
        }
        }
    }

    private func deliver(delivery: NotificationDelivery, title: String, artist: String?, album: String?, artwork: String?, completion: @escaping (Bool, String?) -> Void) {
        let makeRequest: (URL?) -> Void = { artworkFile in
            let content = UNMutableNotificationContent(); content.title = title; content.subtitle = artist ?? ""; content.body = album ?? ""; content.sound = nil
            guard delivery.startSubmission({
                if let artworkFile {
                    if let attachment = try? UNNotificationAttachment(identifier: "artwork", url: artworkFile) {
                        content.attachments = [attachment] // Notification Center now owns/moves it.
                    } else {
                        discardArtworkFile(artworkFile)
                    }
                }
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "better-songify-song-change", content: content, trigger: nil)) { error in
                    completion(error == nil, error?.localizedDescription)
                }
            }) else {
                discardArtworkFile(artworkFile)
                return
            }
        }
        guard let artwork = validArtwork(artwork), let url = URL(string: artwork) else { makeRequest(nil); return }
        ArtworkDownload(url: url, delivery: delivery) { file in makeRequest(file) }.start()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

// MARK: - Fixed-contract loopback server

final class LoopbackServer {
    private var listener: NWListener?
    private let coordinator: NotificationDelivering
    private let port: UInt16
    private let requestQueue = DispatchQueue(label: "io.bettersongify.notifier.requests")
    private var activeRequests: [ObjectIdentifier: HTTPRequest] = [:]
    private(set) var errorText: String?
    var onState: (() -> Void)?
    // POST /menu-bar carries the panel's "Show Song In Menu Bar" setting; the
    // panel owns it and this process only obeys and remembers it.
    var onMenuBarVisibility: ((Bool) -> Void)?
    init(coordinator: NotificationDelivering, port: UInt16 = notifierPort) { self.coordinator = coordinator; self.port = port }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready: self?.errorText = nil
                    case .failed(let error):
                        self?.errorText = "Notifier connection unavailable: \(error.localizedDescription)"
                        log(self?.errorText ?? "Notifier connection unavailable")
                    default: break
                    }
                    self?.onState?()
                }
            }
            self.listener = listener; listener.start(queue: .global(qos: .userInitiated))
        } catch {
            errorText = "Notifier connection unavailable: \(error.localizedDescription)"
            log(errorText ?? "Notifier connection unavailable")
            onState?()
        }
    }
    func stop() {
        listener?.cancel(); listener = nil
        requestQueue.sync {
            activeRequests.values.forEach { $0.cancel() }
            activeRequests.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        let request = HTTPRequest(connection: connection, coordinator: coordinator, menuBarVisibility: onMenuBarVisibility) { [weak self] request in
            self?.requestQueue.async { self?.activeRequests.removeValue(forKey: ObjectIdentifier(request)) }
        }
        requestQueue.sync { activeRequests[ObjectIdentifier(request)] = request }
        connection.start(queue: .global(qos: .userInitiated)); request.receive()
    }
}

private final class HTTPRequest {
    private let connection: NWConnection
    private let coordinator: NotificationDelivering
    private let menuBarVisibility: ((Bool) -> Void)?
    private let finished: (HTTPRequest) -> Void
    // Network, timeout, and notification callbacks may arrive on arbitrary
    // queues. Every mutable request field below is confined to this queue.
    private let queue = DispatchQueue(label: "io.bettersongify.notifier.request.\(UUID().uuidString)")
    private var buffer = Data(); private var headerEnd: Int?; private var bodyLength: Int?; private var done = false
    private var method = ""; private var path = ""; private var origin: String?
    private var readDeadline: DispatchWorkItem?; private var processingDeadline: DispatchWorkItem?
    private var delivery: NotificationDelivery?
    private let readTimeout: TimeInterval
    init(connection: NWConnection, coordinator: NotificationDelivering, menuBarVisibility: ((Bool) -> Void)?, finished: @escaping (HTTPRequest) -> Void) {
        self.connection = connection; self.coordinator = coordinator; self.menuBarVisibility = menuBarVisibility; self.finished = finished
        self.readTimeout = ProcessInfo.processInfo.environment["BS_NOTIFIER_TEST_MODE"] == "1" ? 0.35 : 5
    }
    func cancel() { queue.async { self.respond(503, "Notifier is stopping") } }
    func receive() {
        queue.async {
            self.readDeadline = DispatchWorkItem { [weak self] in
                self?.queue.async { self?.respond(408, "Request timeout") }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + self.readTimeout, execute: self.readDeadline!)
            self.readMore()
        }
    }
    private func readMore() {
        dispatchPrecondition(condition: .onQueue(queue))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4097) { [weak self] data, _, complete, error in
            self?.queue.async {
                guard let self, !self.done else { return }
                if let data { self.buffer.append(data) }
                if self.buffer.count > 12_288 { self.respond(413, "Request too large"); return }
                if self.headerEnd == nil, let range = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self.headerEnd = range.upperBound
                    guard self.parseHeaders() else { return }
                }
                if let headerEnd = self.headerEnd, let bodyLength = self.bodyLength, self.buffer.count >= headerEnd + bodyLength { self.process(); return }
                if complete || error != nil { self.respond(400, "Incomplete request"); return }
                self.readMore()
            }
        }
    }
    private func parseHeaders() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        // headerEnd is after CRLFCRLF; decode only actual header bytes so the
        // structural delimiter is never mistaken for an empty header line.
        guard let end = headerEnd, end >= 4, let text = String(data: buffer[..<(end - 4)], encoding: .utf8) else { respond(400, "Invalid headers"); return false }
        let lines = text.components(separatedBy: "\r\n")
        guard let request = lines.first?.split(separator: " "), request.count == 3 else { respond(400, "Invalid request"); return false }
        method = String(request[0]); path = String(request[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { respond(400, "Invalid header"); return false }
            let key = line[..<colon].lowercased()
            // Duplicate local headers are ambiguous; reject rather than let a
            // dictionary initializer trap or accept a smuggling-shaped input.
            guard headers[key] == nil else { respond(400, "Duplicate header"); return false }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Captured before the route guards so preflights carry it too: the CORS
        // grant in responseHeaders is decided per-origin, and OPTIONS returns
        // early below.
        origin = headers["origin"]
        if ProcessInfo.processInfo.environment["BS_NOTIFIER_TEST_MODE"] == "1", path == "/test-submissions", method == "GET" { bodyLength = 0; return true }
        guard path == "/notify" || path == "/menu-bar" else { respond(404, "Not found"); return false }
        guard method == "OPTIONS" || method == "POST" else { respond(405, "Method not allowed"); return false }
        if method == "OPTIONS" { bodyLength = 0; return true }
        guard let lengthText = headers["content-length"], let length = Int(lengthText), length >= 0 else { respond(411, "Content-Length required"); return false }
        guard length <= 4096 else { respond(413, "Body too large"); return false }
        bodyLength = length; return true
    }
    private func process() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let end = headerEnd, let bodyLength, end >= 4 else { respond(400, "Invalid request"); return }
        readDeadline?.cancel()
        if method == "OPTIONS" { respond(204, nil); return }
        if method == "GET" { respondJSON(ok: true, error: nil, extra: ["submissions": testSubmissionCount.value]); return }
        let body = buffer.subdata(in: end..<(end + bodyLength))
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { respond(400, "Invalid JSON"); return }
        if path == "/menu-bar" {
            // Nothing to time out and nothing to cancel: this only flips a
            // status item, so it answers immediately rather than borrowing the
            // notification path's delivery token.
            guard let visible = json["visible"] as? Bool else { respond(400, "Invalid menu bar request"); return }
            if let apply = menuBarVisibility { DispatchQueue.main.async { apply(visible) } }
            respondJSON(ok: true, error: nil)
            return
        }
        let fallback = NotificationFallback(title: sanitizedFallback(json["title"] as? String), artist: sanitizedFallback(json["artist"] as? String), artwork: validArtwork(sanitizedFallback(json["artwork"] as? String)))
        let processingTimeout: TimeInterval = ProcessInfo.processInfo.environment["BS_NOTIFIER_TEST_MODE"] == "1" ? 0.3 : productionProcessingTimeout
        processingDeadline = DispatchWorkItem { [weak self] in self?.queue.async {
            guard let self, let delivery = self.delivery, delivery.cancelIfPending() else { return }
            self.respond(503, "Notification delivery timed out")
        } }
        DispatchQueue.global().asyncAfter(deadline: .now() + processingTimeout, execute: processingDeadline!)
        delivery = coordinator.notify(fallback: fallback) { [weak self] ok, error in
            self?.queue.async { self?.respondJSON(ok: ok, error: error) }
        }
    }
    // The desktop renderer serves xpui from an https spotify.com origin and the
    // web player from open.spotify.com. Both need the grant: the trigger POST
    // is JSON (so it is preflighted) and its reply is read. Everything else —
    // including any web page the user happens to be visiting — gets no CORS
    // headers, so the browser refuses it both the request and the response.
    // This was `*`, which let any site spoof notifications, hide the menu-bar
    // item, or read back the current track. Origin-less clients such as the
    // installer's curl health check are unaffected: CORS is browser-enforced.
    private static let allowedOriginPattern = try! NSRegularExpression(pattern: "^https://([a-z0-9-]+\\.)*spotify\\.com$")
    private var allowedOrigin: String? {
        guard let origin, !origin.isEmpty else { return nil }
        guard HTTPRequest.allowedOriginPattern.firstMatch(in: origin, range: NSRange(origin.startIndex..., in: origin)) != nil else {
            // Surfaced because a Spotify origin change would otherwise stop
            // notifications with no visible cause.
            log("rejected cross-origin request from \(origin)")
            return nil
        }
        return origin
    }
    private func responseHeaders(length: Int, contentType: String) -> String {
        var cors = ""
        if let allowedOrigin {
            cors = "Access-Control-Allow-Origin: \(allowedOrigin)\r\nVary: Origin\r\nAccess-Control-Allow-Headers: content-type\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Private-Network: true\r\n"
        }
        return cors + "Content-Type: \(contentType)\r\nContent-Length: \(length)\r\nConnection: close\r\n"
    }
    private func respondJSON(ok: Bool, error: String?, extra: [String: Any] = [:]) {
        var object: [String: Any] = ["ok": ok, "backend": "notifier-app"]
        extra.forEach { object[$0.key] = $0.value }
        if let error { object["error"] = error }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"ok\":false}".utf8)
        respond(200, data: data, contentType: "application/json")
    }
    private func respond(_ code: Int, _ message: String?) { respond(code, data: message.map { Data($0.utf8) }, contentType: "text/plain; charset=utf-8") }
    private func respond(_ code: Int, data: Data?, contentType: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !done else { return }; done = true; readDeadline?.cancel(); processingDeadline?.cancel(); _ = delivery?.cancelIfPending()
        let body = data ?? Data(); let reason = code == 204 ? "No Content" : (code == 200 ? "OK" : "Bad Request")
        let header = "HTTP/1.1 \(code) \(reason)\r\n\(responseHeaders(length: body.count, contentType: contentType))\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
            self.connection.cancel()
            self.finished(self)
        })
    }
}

// MARK: - App lifecycle and maintenance

private func maintenanceMode() -> Bool {
    guard CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--maintenance" else { return false }
    // The installer's one-time hook for the whole auto-start behaviour, and the
    // only thing that makes the companion outlive a restart. It sits ahead of
    // the availability guard below and exits non-zero on any failure, so the
    // installer reports it instead of leaving a companion that never returns.
    if CommandLine.arguments[2] == "register-login" {
        guard #available(macOS 13.0, *) else {
            log("Opening at login requires macOS 13 or later.")
            exit(1)
        }
        do { try SMAppService.mainApp.register() } catch {
            log("Could not register BetterSongify to open at login: \(error.localizedDescription)")
            exit(1)
        }
        return true
    }
    guard #available(macOS 13.0, *) else { return true }
    if CommandLine.arguments[2] == "unregister-login" { try? SMAppService.mainApp.unregister() }
    if CommandLine.arguments[2] == "quit" {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: notifierBundleID)
            .filter { $0.processIdentifier != selfPID }
            .forEach { $0.terminate() }
    }
    return true
}

// Test-only server mode deliberately has no NSApplication, AppleEvents,
// ServiceManagement operation, or UNUserNotificationCenter interaction. It is
// used by tools/test-notifier-transport.sh to exercise the public HTTP parser.
private final class TestSubmissionCount {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
private let testSubmissionCount = TestSubmissionCount()

private final class TestNotificationCoordinator: NotificationDelivering {
    @discardableResult func notify(fallback: NotificationFallback, completion: @escaping (Bool, String?) -> Void) -> NotificationDelivery {
        let delivery = NotificationDelivery()
        let delay: TimeInterval = fallback.title == "Delayed" ? 0.6 : 0
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            // The delayed path models work that has not reached center.add;
            // timeout cancellation must make this a no-op.
            guard delivery.beginSubmission() else { return }
            testSubmissionCount.increment()
            completion(true, nil)
        }
        return delivery
    }
}

private func transportSelfTests() {
    precondition(validArtwork("https://i.scdn.co/image/abc") != nil)
    precondition(validArtwork("http://i.scdn.co/image/abc") == nil)
    precondition(validArtwork("https://example.invalid/image/abc") == nil)
    precondition(validArtwork("https://i.scdn.co/not-image/abc") == nil)
    precondition(validArtwork("https://i.scdn.co:444/image/abc") == nil)
    precondition(validArtwork("https://user@i.scdn.co/image/abc") == nil)
    let unicode = String(repeating: "🎵", count: 240)
    precondition(sanitizedFallback(unicode)?.count == 200)
    precondition(cleanMetadata(unicode)?.count == 240)
    var started = false
    let cancelledFirst = NotificationDelivery()
    precondition(cancelledFirst.cancelIfPending())
    precondition(!cancelledFirst.startIfPending { started = true })
    precondition(!started)
    let startedFirst = NotificationDelivery()
    precondition(startedFirst.startIfPending { started = true })
    precondition(startedFirst.cancelIfPending()) // non-submission stages still cancel after initiation
    let submittedFirst = NotificationDelivery()
    precondition(submittedFirst.startSubmission {})
    precondition(!submittedFirst.cancelIfPending())
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("better-songify-cleanup-\(UUID().uuidString)")
    try! Data([0]).write(to: temporary)
    discardArtworkFile(temporary)
    precondition(!FileManager.default.fileExists(atPath: temporary.path))
}

private func transportTestMode() -> Bool {
    guard CommandLine.arguments.contains("--transport-test") else { return false }
    setenv("BS_NOTIFIER_TEST_MODE", "1", 1)
    transportSelfTests()
    let server = LoopbackServer(coordinator: TestNotificationCoordinator(), port: 17_353)
    server.start()
    RunLoop.main.run(until: Date().addingTimeInterval(12))
    server.stop()
    return true
}

// Hosts the status item in a bundle whose identifier ControlCenter has not
// blocked. It never reads Spotify (that would raise a second Automation prompt
// under a second identity) and never posts notifications — it renders what the
// main app pushes and sends menu actions back.
final class MenuBarHelperDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController()
        controller.onOpenSpotify = { postHelperAction("openSpotify") }
        controller.onMenuOpen = { postHelperAction("menuOpen") }
        status = controller
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onSnapshot(_:)), name: snapshotNotificationName, object: nil)
        // The main app pushes on change, so ask for the current state at launch
        // rather than showing "Spotify not running" until the next change.
        postHelperAction("resend")
    }

    @objc private func onSnapshot(_ note: Notification) {
        guard let info = note.userInfo as? [String: String] else { return }
        let snapshot = PlaybackSnapshot(userInfo: info)
        DispatchQueue.main.async { self.status?.update(snapshot) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        status?.stop(); status = nil
    }
}

private func postHelperAction(_ action: String) {
    DistributedNotificationCenter.default().postNotificationName(
        actionNotificationName, object: nil, userInfo: ["action": action], deliverImmediately: true)
}

private func menuBarHelperMode() -> Bool {
    CommandLine.arguments.contains(menuBarHelperArgument)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = SpotifyPlaybackMonitor()
    private var status: StatusItemController?
    private var coordinator: NotificationCoordinator?
    private var server: LoopbackServer?
    private var recoveryTimer: Timer?
    // The BetterSongify panel owns "Show Song In Menu Bar" and pushes it over
    // the loopback contract, but this app starts at login — long before
    // Spotify's renderer can push anything — so the last value it was told is
    // remembered here. An absent key means visible, matching the panel default.
    private var menuBarVisible = UserDefaults.standard.object(forKey: menuBarVisibleDefaultsKey) as? Bool ?? true
    // Opt-in escape hatch for a machine whose bundle identifier ControlCenter
    // has blocked. Default false, so nothing changes for a clean install.
    private let useHelper = UserDefaults.standard.bool(forKey: menuBarHelperDefaultsKey)
    private var helperLaunched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.onSnapshot = { [weak self] _ in self?.render() }
        coordinator = NotificationCoordinator(monitor: monitor)
        // The listener binds for the whole process lifetime, never only while
        // Spotify runs: rebinding on launch would race the injected script's
        // first POST, and an idle NWListener costs nothing.
        if let coordinator {
            let server = LoopbackServer(coordinator: coordinator)
            server.onState = { [weak self] in self?.render() }
            // Set before start(): accept() reads this handler from the
            // listener's queue.
            server.onMenuBarVisibility = { [weak self] visible in self?.setMenuBarVisible(visible) }
            server.start()
            self.server = server
        }
        // The status item shadows Spotify, so it shares Spotify's lifetime — but
        // the process does not. It stays resident as a login item so something
        // is always alive to notice Spotify start; nothing else can, and every
        // push alternative was tried and failed. The menu still offers no Quit
        // item.
        if useHelper {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(onHelperAction(_:)), name: actionNotificationName, object: nil)
        }
        monitor.onSpotifyLaunched = { [weak self] in self?.syncStatusItem() }
        monitor.onSpotifyTerminated = { [weak self] in self?.hideStatusItem() }
        monitor.start()
        syncStatusItem()
        logLoginItemState()
        render()
    }
    func applicationWillTerminate(_ notification: Notification) { hideStatusItem(); monitor.stop(); server?.stop() }

    // The item is shown only when Spotify is running AND the panel setting
    // allows it; either going away takes it down, and either coming back
    // restores it.
    private func syncStatusItem() {
        precondition(Thread.isMainThread)
        if menuBarVisible, SpotifyPlaybackMonitor.isSpotifyRunning { showStatusItem() } else { hideStatusItem() }
    }

    private func setMenuBarVisible(_ visible: Bool) {
        precondition(Thread.isMainThread)
        UserDefaults.standard.set(visible, forKey: menuBarVisibleDefaultsKey)
        guard visible != menuBarVisible else { return }
        menuBarVisible = visible
        syncStatusItem()
    }

    // Idle is genuinely idle: with Spotify closed there is no status item, no
    // marquee and no recovery timer, leaving only the two workspace observers,
    // which are event-driven. A resident app must not wake to early-return.
    private func showStatusItem() {
        precondition(Thread.isMainThread)
        guard status == nil, !helperLaunched else { return }
        if useHelper {
            helperLaunched = true
            launchHelper()
        } else {
            let controller = StatusItemController()
            controller.onOpenSpotify = { [weak self] in self?.openSpotify() }
            controller.onMenuOpen = { [weak self] in self?.monitor.refresh() }
            status = controller
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.monitor.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        recoveryTimer = timer
        render()
    }

    private func hideStatusItem() {
        precondition(Thread.isMainThread)
        recoveryTimer?.invalidate(); recoveryTimer = nil
        status?.stop(); status = nil
        if helperLaunched {
            helperLaunched = false
            NSRunningApplication.runningApplications(withBundleIdentifier: menuBarHelperBundleID)
                .forEach { $0.terminate() }
        }
    }

    // The helper lives inside this bundle, so it is replaced with it and cannot
    // drift out of sync with the format above.
    private func launchHelper() {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/BetterSongifyMenuBar.app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            log("Menu bar helper is missing from the bundle; rebuild and reinstall BetterSongify.")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = [menuBarHelperArgument]
        config.activates = false
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { log("Could not start the menu bar helper: \(error.localizedDescription)") }
        }
    }

    private func pushSnapshotToHelper(_ snapshot: PlaybackSnapshot) {
        DistributedNotificationCenter.default().postNotificationName(
            snapshotNotificationName, object: nil, userInfo: snapshot.userInfo, deliverImmediately: true)
    }

    @objc private func onHelperAction(_ note: Notification) {
        guard let action = (note.userInfo as? [String: String])?["action"] else { return }
        DispatchQueue.main.async {
            switch action {
            case "openSpotify": self.openSpotify()
            case "menuOpen": self.monitor.refresh()
            // The helper starts after the main app and would otherwise sit on a
            // stale label until the next change.
            case "resend": self.pushSnapshotToHelper(self.monitor.snapshot)
            default: break
            }
        }
    }

    // SMAppService lost its user-facing control when the Launch at Login row was
    // removed, so a registration the user switched off in System Settings fails
    // invisibly — the app just never comes back. Surface it on stderr at least.
    // This diagnostic is load-bearing: it is what caught a keep-login dead end
    // that looked like a success.
    private func logLoginItemState() {
        guard #available(macOS 13.0, *) else { return }
        switch SMAppService.mainApp.status {
        case .enabled: break
        case .requiresApproval: log("BetterSongify is switched off in System Settings > General > Login Items; re-enable it or the menu bar item will not return after a restart.")
        case .notRegistered: log("BetterSongify is not registered to open at login; re-run the installer or the menu bar item will not return after a restart.")
        case .notFound: log("BetterSongify's login registration was not found; re-run the installer.")
        @unknown default: break
        }
    }
    // Automation/notification-permission failures no longer have a menu row to
    // land in; they stay observable on stderr and in the POST error the
    // extension already surfaces as its in-app toast.
    private func render() {
        switch monitor.snapshot.status {
        case .automationUnavailable: log("Spotify Automation access failed; allow BetterSongify in Privacy & Security > Automation.")
        case .unknown: log("Spotify returned no readable playback state.")
        default: break
        }
        if useHelper {
            if helperLaunched { pushSnapshotToHelper(monitor.snapshot) }
        } else {
            status?.update(monitor.snapshot)
        }
    }
    private func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else { log("Spotify is not installed."); return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

if menuBarHelperMode() {
    let app = NSApplication.shared
    let delegate = MenuBarHelperDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
} else if !maintenanceMode() && !transportTestMode() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
