// tiltnav 1.1 — wheel tilt (horizontal scroll) → a keystroke, scoped per application.
//
// SCOPE, deliberately narrow: the one thing Karabiner-Elements cannot do is see a horizontal
// scroll event — its "from" accepts key_code / consumer_key_code / pointing_button only. Every
// real mouse BUTTON belongs in karabiner.json, not here. That guard is the feature.
//
// Why it is not a thin shim: "tilt emits F16, Karabiner maps F16 → ⌥← per app" would keep all
// policy in karabiner.json. Impossible — Karabiner grabs physical HID devices and never observes
// synthesized CGEvents. So this tool emits the final chord and carries a little per-app policy.
//
// EXIT CONDITION: this exists because LinearMouse resolves per-app scoping by hit-testing the
// window under the pointer, which fails for a full-screen app. If that is fixed upstream, delete
// this and use LinearMouse.
//
// Design spec: docs/.research/tiltnav/ux-design-spec.md
// The key-injection recipe (hidSystemState source, keyboard type from the source, device-specific
// modifier masks, modifiers as flagsChanged, posted at the HID tap) is derived from LinearMouse —
// MIT, Copyright (c) 2021-2026 LinearMouse. It is what makes Microsoft's Windows App accept the
// event; generic CGEventFlags alone are silently dropped.

import AppKit
import CoreGraphics
import Foundation

let VERSION = "1.1"
let BUILD_DATE = "2026-09-20"

// MARK: - Paths

let stateDir   = NSString(string: "~/.local/state/tiltnav").expandingTildeInPath
let pidFile    = stateDir + "/tiltnav.pid"
let lockFile   = stateDir + "/tiltnav.lock"
let calibFile  = stateDir + "/calibration.json"
let sockPath   = stateDir + "/control.sock"
let logPath    = NSString(string: "~/Library/Logs/tiltnav.log").expandingTildeInPath
let configPath = NSString(string: "~/.config/tiltnav.json").expandingTildeInPath
let appPath    = NSString(string: "~/Applications/Tiltnav.app").expandingTildeInPath
let agentPlist = NSString(string: "~/Library/LaunchAgents/com.m5air.tiltnav.plist").expandingTildeInPath

// MARK: - Logging

let isCLI = CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }

let ISO: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
}()

func logln(_ m: String) {
    if isCLI { return }                       // a diagnostic must not pollute what it diagnoses
    let line = "\(ISO.string(from: Date())) tiltnav: \(m)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Keys and modifiers

let MODIFIER_KEYCODE: [String: CGKeyCode] = ["command": 55, "shift": 56, "option": 58, "control": 59]

/// Generic mask PLUS the device-specific bit (IOKit/hidsystem/IOLLEvent.h). Windows App needs both:
/// with the generic mask alone it receives the key and drops the modifier.
let MODIFIER_FLAGS: [String: CGEventFlags] = [
    "command": CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue   | 0x0000_0008),
    "shift":   CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue     | 0x0000_0002),
    "option":  CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x0000_0020),
    "control": CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue   | 0x0000_0001),
]

let GLYPH: [String: String] = ["command": "⌘", "shift": "⇧", "option": "⌥", "control": "⌃",
                               "arrowLeft": "←", "arrowRight": "→", "arrowUp": "↑", "arrowDown": "↓"]

let KEYCODE: [String: CGKeyCode] = [
    "arrowLeft": 123, "arrowRight": 124, "arrowDown": 125, "arrowUp": 126,
    "[": 33, "]": 30, "-": 27, "=": 24, ",": 43, ".": 47, "/": 44, ";": 41, "'": 39, "`": 50,
    "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "forwardDelete": 117,
    "home": 115, "end": 119, "pageUp": 116, "pageDown": 121,
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
    "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1,
    "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
    "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
]

// MARK: - Config

struct Chord {
    var modifiers: [String]
    var key: String
    var describe: String { (modifiers + [key]).joined(separator: "+") }
    var glyphs: String { modifiers.map { GLYPH[$0] ?? $0 }.joined() + (GLYPH[key] ?? key) }
}

enum Behaviour {
    case passthrough
    case chords(tiltLeft: Chord?, tiltRight: Chord?)
}

func describe(_ b: Behaviour) -> String {
    switch b {
    case .passthrough: return "passthrough"
    case let .chords(l, r): return "tiltLeft=\(l?.describe ?? "-") tiltRight=\(r?.describe ?? "-")"
    }
}

func glyphDescribe(_ b: Behaviour) -> String {
    switch b {
    case .passthrough: return "passthrough"
    case let .chords(l, r): return "tilt← \(l?.glyphs ?? "—")   tilt→ \(r?.glyphs ?? "—")"
    }
}

struct Config {
    var debounce: Double = 0.30
    /// A trackpad's horizontal swipe is the same CGEvent as a wheel tilt, so the trackpad
    /// otherwise inherits tiltnav's Back/Forward and a stray two-finger drift navigates away.
    /// macOS marks a trackpad's scroll continuous (pixel-precise, phased) and a notched wheel
    /// discrete; measured on this machine, tilt is always isContinuous=0 and the trackpad always
    /// isContinuous=1, with no overlap. Set false only for a high-resolution wheel that reports
    /// itself continuous — then the trackpad fires too.
    var discreteWheelOnly: Bool = true
    var defaultBehaviour: Behaviour = .passthrough
    var apps: [String: Behaviour] = [:]
    var parsedOK = false
    var parseError: String?
    var rejected: [String] = []
    var unresolved: [String] = []
    var mtime: Date?

    static func parseChord(_ parts: [String], _ ctx: String, _ rejected: inout [String]) -> Chord? {
        guard let key = parts.last, !parts.isEmpty else {
            rejected.append("\(ctx): empty chord"); return nil
        }
        guard KEYCODE[key] != nil else {
            rejected.append("\(ctx): unknown key '\(key)'"); return nil
        }
        let mods = Array(parts.dropLast())
        for m in mods where MODIFIER_FLAGS[m] == nil {
            rejected.append("\(ctx): unknown modifier '\(m)'"); return nil
        }
        return Chord(modifiers: mods, key: key)
    }

    /// Accepts tiltLeft/tiltRight (preferred — physical direction, unambiguous) and the older
    /// left/right spellings. The rename exists because "left" was ambiguous between the raw
    /// delta sign, another tool's naming, and the physical tilt; that cost real debugging time.
    static func parseBehaviour(_ raw: Any, _ ctx: String, _ rejected: inout [String]) -> Behaviour? {
        if let s = raw as? String {
            if s == "passthrough" { return .passthrough }
            rejected.append("\(ctx): expected \"passthrough\" or an object, got \"\(s)\""); return nil
        }
        guard let d = raw as? [String: Any] else {
            rejected.append("\(ctx): expected an object or \"passthrough\""); return nil
        }
        var l: Chord?, r: Chord?
        if let a = (d["tiltLeft"] ?? d["left"]) as? [String] {
            l = parseChord(a, "\(ctx).tiltLeft", &rejected)
        }
        if let a = (d["tiltRight"] ?? d["right"]) as? [String] {
            r = parseChord(a, "\(ctx).tiltRight", &rejected)
        }
        if l == nil && r == nil { rejected.append("\(ctx): no usable tiltLeft/tiltRight"); return nil }
        return .chords(tiltLeft: l, tiltRight: r)
    }

    /// Returns nil when the file cannot be parsed at all, so the caller keeps last-good config.
    static func load() -> Config? {
        var c = Config()
        c.mtime = (try? FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate]) as? Date
        guard let data = FileManager.default.contents(atPath: configPath) else {
            c.parseError = "not found"; c.parsedOK = true      // absent is valid: pass everything through
            return c
        }
        let root: [String: Any]
        do {
            guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                c.parseError = "top level is not an object"; return nil
            }
            root = o
        } catch {
            c.parseError = "\(error.localizedDescription)"     // Foundation reports the character offset
            return nil
        }
        if let d = root["debounceSeconds"] as? Double { c.debounce = d }
        if let b = root["discreteWheelOnly"] as? Bool { c.discreteWheelOnly = b }
        if let raw = root["default"] {
            if let b = parseBehaviour(raw, "default", &c.rejected) { c.defaultBehaviour = b }
        }
        if let apps = root["apps"] as? [String: Any] {
            for (bundle, raw) in apps {
                if let b = parseBehaviour(raw, "apps[\(bundle)]", &c.rejected) {
                    c.apps[bundle] = b
                    // A bundle id that resolves to nothing installed is the typo class: it looks
                    // like a working config and silently never matches.
                    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) == nil {
                        // Only flag it when no shorter prefix resolves either; otherwise it is a
                        // legitimate sub-bundle rather than a typo.
                        var parts = bundle.split(separator: ".")
                        var parentResolves = false
                        while parts.count > 2 {
                            parts.removeLast()
                            if NSWorkspace.shared.urlForApplication(
                                withBundleIdentifier: parts.joined(separator: ".")) != nil {
                                parentResolves = true; break
                            }
                        }
                        if !parentResolves { c.unresolved.append(bundle) }
                    }
                }
            }
        }
        c.parsedOK = true
        return c
    }
}

// MARK: - Calibration (the direction trap, held as state rather than as a document)

struct Calibration {
    var positiveIsTiltLeft = true
    var calibrated = false

    static func load() -> Calibration {
        var c = Calibration()
        if let d = FileManager.default.contents(atPath: calibFile),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            c.positiveIsTiltLeft = (o["positiveIsTiltLeft"] as? Bool) ?? true
            c.calibrated = (o["calibrated"] as? Bool) ?? false
        }
        return c
    }

    func save() {
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let o: [String: Any] = ["positiveIsTiltLeft": positiveIsTiltLeft, "calibrated": calibrated]
        if let d = try? JSONSerialization.data(withJSONObject: o, options: .prettyPrinted) {
            try? d.write(to: URL(fileURLWithPath: calibFile))
        }
    }

    var describe: String {
        "deltaAxis2 \(positiveIsTiltLeft ? "+1" : "-1") = tiltLeft"
            + (calibrated ? " (calibrated)" : " (ASSUMED DEFAULT, never calibrated)")
    }
}

// MARK: - Injection

func hardwareLikeEvent(_ vk: CGKeyCode, _ keyDown: Bool) -> CGEvent? {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: keyDown)
    else { return nil }
    e.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
    e.setIntegerValueField(.keyboardEventKeyboardType, value: Int64(source.keyboardType))
    return e
}

func postChord(_ c: Chord) {
    guard let vk = KEYCODE[c.key] else { return }
    var flags = CGEventFlags()
    for m in c.modifiers {
        guard let mvk = MODIFIER_KEYCODE[m], let mask = MODIFIER_FLAGS[m] else { continue }
        flags.insert(mask)
        if let e = hardwareLikeEvent(mvk, true) { e.type = .flagsChanged; e.flags = flags; e.post(tap: .cghidEventTap) }
    }
    for down in [true, false] {
        if let e = hardwareLikeEvent(vk, down) { e.flags = flags; e.post(tap: .cghidEventTap) }
    }
    for m in c.modifiers.reversed() {
        guard let mvk = MODIFIER_KEYCODE[m], let mask = MODIFIER_FLAGS[m] else { continue }
        flags.remove(mask)
        if let e = hardwareLikeEvent(mvk, false) { e.type = .flagsChanged; e.flags = flags; e.post(tap: .cghidEventTap) }
    }
}

// MARK: - Runtime state

final class Runtime {
    var config = Config()
    var calibration = Calibration.load()
    var paused = false
    var tap: CFMachPort?
    var tapArmed = false
    var selfTestPassed = false
    var selfTestAt: Date?
    var selfTestMs = 0
    var eventsSeen = 0
    var chordsSent = 0
    var passthroughCount = 0
    var continuousIgnored = 0
    var tapReEnables = 0
    var lastEventAt: Date?
    var lastChordAt: Date?
    var lastDelta = 0
    var lastResolved = ""
    var startedAt = Date()
    var lastFire: Double = 0
    var watchTilts = false
}

let rt = Runtime()

let SELFTEST_MAGIC: Int64 = 0x7117_4E41_5601
var selfTestAwaiting = false
var selfTestSawMagic = false

// MARK: - Provenance / singleton

func launchedBy() -> String {
    let svc = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? "0"
    if svc != "0" && !svc.isEmpty { return "launchd (\(svc))" }
    if getppid() == 1 { return "launchd (label unknown)" }
    return "unmanaged (Finder/shell) — AGENT NOT RUNNING"
}

var lockFD: Int32 = -1
func acquireSingleton() -> Bool {
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    lockFD = open(lockFile, O_CREAT | O_RDWR, 0o644)
    if lockFD < 0 { return true }                  // cannot lock: do not refuse to run over it
    return flock(lockFD, LOCK_EX | LOCK_NB) == 0
}

func currentCDHash() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    p.arguments = ["-d", "--verbose=4", appPath]
    let pipe = Pipe(); p.standardError = pipe; p.standardOutput = Pipe()
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    for line in out.split(separator: "\n") where line.hasPrefix("CDHash=") {
        return String(line.dropFirst(7))
    }
    return ""
}

let grantedHashFile = stateDir + "/granted-cdhash"

/// The Accessibility grant for an ad-hoc-signed bundle is pinned to the binary's cdhash, so a
/// rebuild silently revokes it while the System Settings row still looks ticked. Recording the
/// hash that last worked lets us tell "you rebuilt it" apart from "macOS revoked it".
func grantDiagnosis() -> String {
    let current = currentCDHash()
    guard let stored = try? String(contentsOfFile: grantedHashFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty else {
        return "never granted on this machine, or never yet proven"
    }
    if stored == current { return "macOS revoked a grant that previously worked for this exact build" }
    return "THE APP WAS REBUILT since the grant (stored \(stored.prefix(8))… ≠ current \(current.prefix(8))…) — remove the old Tiltnav entry in Accessibility and add it again"
}

// MARK: - Start at login

let AGENT_PLIST_BODY = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.m5air.tiltnav</string>
  <key>ProgramArguments</key> <array><string>__EXEC__</string></array>
  <key>RunAtLoad</key>        <true/>
</dict>
</plist>
"""

func startAtLoginEnabled() -> Bool { FileManager.default.fileExists(atPath: agentPlist) }

func setStartAtLogin(_ on: Bool) {
    if on {
        let exec = appPath + "/Contents/MacOS/tiltnav"
        let body = AGENT_PLIST_BODY.replacingOccurrences(of: "__EXEC__", with: exec)
        try? FileManager.default.createDirectory(
            atPath: (agentPlist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? body.write(toFile: agentPlist, atomically: true, encoding: .utf8)
        // Load it only if it is not already loaded, so we never restart ourselves.
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        check.arguments = ["print", "gui/\(getuid())/com.m5air.tiltnav"]
        check.standardOutput = Pipe(); check.standardError = Pipe()
        try? check.run(); check.waitUntilExit()
        if check.terminationStatus != 0 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootstrap", "gui/\(getuid())", agentPlist]
            try? p.run(); p.waitUntilExit()
        }
        logln("start at login ENABLED")
    } else {
        // Deliberately does NOT bootout: turning off "start at login" must not kill the
        // running instance. It simply will not come back at the next login.
        try? FileManager.default.removeItem(atPath: agentPlist)
        logln("start at login DISABLED (this instance keeps running until you quit or log out)")
    }
}

// MARK: - Conflict detection

struct TapInfo { var pid: pid_t; var name: String; var enabled: Bool }

func scrollTapsOtherThanUs() -> [TapInfo] {
    var count: UInt32 = 0
    guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
    var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
    var got: UInt32 = 0
    guard CGGetEventTapList(count, &taps, &got) == .success else { return [] }
    let me = getpid()
    let scrollMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    var out: [TapInfo] = []
    for t in taps.prefix(Int(got)) where t.tappingProcess != me && (t.eventsOfInterest & scrollMask) != 0 {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(t.tappingProcess, &buf, UInt32(buf.count))
        let path = n > 0 ? String(cString: buf) : ""
        let name = path.isEmpty ? "pid \(t.tappingProcess)" : (path as NSString).lastPathComponent
        out.append(TapInfo(pid: t.tappingProcess, name: name, enabled: t.enabled))
    }
    return out
}

/// Logi Options+ does not touch the wheel tilt, but it DOES claim mouse buttons 4/5 at the
/// HID++ level whenever anything is assigned to them, including "do nothing". Saying so here
/// stops a future debugger walking the whole PITFALLS path again.
func knownFamilyNotes() -> [String] {
    var notes: [String] = []
    func running(_ pattern: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", pattern]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }
    if running("logioptionsplus_agent") {
        notes.append("Logi Options+ is running — it claims mouse buttons 4/5 at HID++ so Karabiner cannot see them. Wheel tilt is NOT affected.")
    }
    if running("LinearMouse") { notes.append("LinearMouse is running — it can map the same tilt. Check its config for a scroll mapping.") }
    if running("Hammerspoon") { notes.append("Hammerspoon is running — check for an hs.eventtap on scrollWheel.") }
    return notes
}

// MARK: - The tap

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        rt.tapReEnables += 1
        logln("WARNING: tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input") — re-enabling (count \(rt.tapReEnables))")
        if let t = rt.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return nil
    }
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

    if selfTestAwaiting, event.getIntegerValueField(.eventSourceUserData) == SELFTEST_MAGIC {
        selfTestSawMagic = true
        return nil                                  // swallow the probe, never act on it
    }

    let h = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
    if h == 0 { return Unmanaged.passUnretained(event) }   // vertical scroll is never ours

    // The trackpad reaches us as the same event a wheel tilt does. Drop it before the counters,
    // so a swipe is not "a tilt seen" — an honest activity line is the only way to tell
    // "my mouse is not being heard" from "my swipes are being correctly declined".
    if rt.config.discreteWheelOnly,
       event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
        rt.continuousIgnored += 1
        return Unmanaged.passUnretained(event)
    }

    rt.eventsSeen += 1
    rt.lastEventAt = Date()
    rt.lastDelta = Int(h)

    if rt.paused {
        rt.passthroughCount += 1
        return Unmanaged.passUnretained(event)
    }

    let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    let behaviour = rt.config.apps[bundle] ?? rt.config.defaultBehaviour
    let tiltLeft = rt.calibration.positiveIsTiltLeft ? (h > 0) : (h < 0)
    rt.lastResolved = tiltLeft ? "tiltLeft" : "tiltRight"

    guard case let .chords(l, r) = behaviour, let chord = tiltLeft ? l : r else {
        rt.passthroughCount += 1
        if rt.watchTilts { logln("tilt deltaAxis2=\(h) → \(rt.lastResolved) [\(bundle)] → passthrough") }
        return Unmanaged.passUnretained(event)
    }

    let now = Date().timeIntervalSince1970
    if now - rt.lastFire < rt.config.debounce { return nil }   // swallow a held tilt's repeats
    rt.lastFire = now

    postChord(chord)
    rt.chordsSent += 1
    rt.lastChordAt = Date()
    if rt.watchTilts { logln("tilt deltaAxis2=\(h) → \(rt.lastResolved) [\(bundle)] → \(chord.describe)") }
    return nil
}

func armTap() -> Bool {
    if let t = rt.tap, CGEvent.tapIsEnabled(tap: t) { return true }
    let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                    options: .defaultTap, eventsOfInterest: mask,
                                    callback: tapCallback, userInfo: nil) else { return false }
    rt.tap = t
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    return true
}

/// The ONLY basis for a green light. A non-nil tap and AXIsProcessTrusted() are both presence;
/// this is effect — a synthetic tagged event must come back through our own callback.
func runSelfTest() {
    guard rt.tapArmed else { rt.selfTestPassed = false; return }
    let t0 = Date()
    selfTestAwaiting = true
    selfTestSawMagic = false
    if let src = CGEventSource(stateID: .hidSystemState),
       let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                       wheel1: 0, wheel2: 1, wheel3: 0) {
        e.setIntegerValueField(.eventSourceUserData, value: SELFTEST_MAGIC)
        e.post(tap: .cghidEventTap)
    }
    let deadline = Date().addingTimeInterval(1.0)
    while Date() < deadline && !selfTestSawMagic { CFRunLoopRunInMode(.defaultMode, 0.02, true) }
    selfTestAwaiting = false
    rt.selfTestPassed = selfTestSawMagic
    rt.selfTestAt = Date()
    rt.selfTestMs = Int(Date().timeIntervalSince(t0) * 1000)
    if rt.selfTestPassed {
        try? currentCDHash().write(toFile: grantedHashFile, atomically: true, encoding: .utf8)
        logln("self-test PASSED (round-trip \(rt.selfTestMs)ms)")
    } else {
        logln("self-test FAILED — the tap exists but no event came back; treat as DEAF")
    }
}

// MARK: - Status

enum Health { case healthy, deaf, configProblem, notRunning, paused, degraded
    var exitCode: Int32 {
        switch self {
        case .healthy: return 0; case .deaf: return 1; case .configProblem: return 2
        case .notRunning: return 3; case .paused: return 4; case .degraded: return 5
        }
    }
    var label: String {
        switch self {
        case .healthy: return "healthy"; case .deaf: return "DEAF"; case .configProblem: return "config problem"
        case .notRunning: return "not running"; case .paused: return "paused"; case .degraded: return "degraded"
        }
    }
}

func currentHealth(conflicts: Int, unresolved: Int) -> Health {
    if rt.paused { return .paused }
    if !rt.tapArmed || !rt.selfTestPassed { return .deaf }
    if !rt.config.parsedOK { return .configProblem }
    // Karabiner taps scroll on this machine permanently and contends for nothing; an entry for an
    // app that is not installed is intent, not a fault. Either alone would pin the state amber
    // forever, which is the same defect as an indicator that never fires. Degraded is reserved
    // for a conflict that has actually manifested: another enabled scroll tap AND nothing seen.
    let uptime = Date().timeIntervalSince(rt.startedAt)
    if conflicts > 0 && rt.eventsSeen == 0 && uptime > 60 { return .degraded }
    _ = unresolved
    return .healthy
}

func ago(_ d: Date?) -> String {
    guard let d = d else { return "never" }
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s/60)m ago" }
    return "\(s/3600)h\(s%3600/60)m ago"
}

func statusReport() -> (String, Int32) {
    let conflicts = scrollTapsOtherThanUs().filter { $0.enabled }
    let notes = knownFamilyNotes()
    let health = currentHealth(conflicts: conflicts.count, unresolved: rt.config.unresolved.count)
    let up = Int(Date().timeIntervalSince(rt.startedAt))
    var s = ""
    s += "tiltnav \(VERSION)   cdhash \(currentCDHash().prefix(8))…  built \(BUILD_DATE)\n"
    s += "  state       : \(health.label)\n"
    s += "  process     : running, pid \(getpid()), up \(up/3600)h\((up%3600)/60)m\n"
    s += "  launched by : \(launchedBy())\n"
    s += "  singleton   : lock held by this pid\n"
    s += "  permissions : Accessibility \(AXIsProcessTrusted() ? "GRANTED" : "NOT GRANTED")\n"
    if !rt.selfTestPassed { s += "                \(grantDiagnosis())\n" }
    s += "  tap         : \(rt.tapArmed ? "created at HID point, enabled" : "NOT CREATED")\n"
    s += "  proof       : self-test \(rt.selfTestPassed ? "PASSED" : "FAILED") \(rt.selfTestAt.map { ISO.string(from: $0) } ?? "never") (round-trip \(rt.selfTestMs)ms)\n"
    s += "  activity    : \(rt.eventsSeen) horizontal-scroll events seen, \(rt.chordsSent) chords sent, \(rt.passthroughCount) passthrough\n"
    s += "  trackpad    : \(rt.config.discreteWheelOnly ? "ignored — \(rt.continuousIgnored) continuous-scroll events passed through untouched" : "NOT ignored (discreteWheelOnly=false) — swipes fire chords too")\n"
    s += "                last event \(ago(rt.lastEventAt)) · last chord \(ago(rt.lastChordAt)) · \(rt.tapReEnables) tap re-enables\n"
    s += "  calibration : \(rt.calibration.describe)\n"
    s += "  at login    : \(startAtLoginEnabled() ? "enabled" : "disabled")\n"
    s += "  config      : \(configPath)  \(rt.config.mtime.map { ISO.string(from: $0) } ?? "absent")  \(rt.config.parsedOK ? "parsed OK" : "PARSE FAILED: \(rt.config.parseError ?? "?")")\n"
    s += "                \(rt.config.apps.count) app overrides, \(rt.config.rejected.count) rejected entries, \(rt.config.unresolved.count) unresolved bundle ids\n"
    for r in rt.config.rejected { s += "                rejected: \(r)\n" }
    for u in rt.config.unresolved { s += "                unresolved bundle id: \(u)\n" }
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    let beh = rt.config.apps[front] ?? rt.config.defaultBehaviour
    s += "  frontmost   : \(front) → \(glyphDescribe(beh))\(rt.config.apps[front] != nil ? "  (app override)" : "  (default)")\n"
    s += "  conflicts   : \(conflicts.isEmpty ? "none detected" : conflicts.map { "\($0.name) (pid \($0.pid))" }.joined(separator: ", "))\n"
    for n in notes { s += "                note: \(n)\n" }
    return (s, health.exitCode)
}

// MARK: - Control socket (status must come from the live process, not from a file)

func serveControlSocket() {
    unlink(sockPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { logln("control socket: socket() failed"); return }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { p in
        sockPath.withCString { strncpy(p, $0, 103) }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
    }
    guard bound == 0, listen(fd, 4) == 0 else { logln("control socket: bind/listen failed"); close(fd); return }
    DispatchQueue.global(qos: .utility).async {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            DispatchQueue.main.sync {
                let (text, code) = statusReport()
                let payload = "\(code)\n\(text)"
                _ = payload.withCString { write(c, $0, strlen($0)) }
            }
            close(c)
        }
    }
}

func askRunningProcess() -> (String, Int32)? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { p in
        sockPath.withCString { strncpy(p, $0, 103) }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let ok = withUnsafePointer(to: &addr) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard ok == 0 else { return nil }
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        data.append(contentsOf: buf[0..<n])
    }
    guard let s = String(data: data, encoding: .utf8), let nl = s.firstIndex(of: "\n") else { return nil }
    let code = Int32(s[s.startIndex..<nl]) ?? 1
    return (String(s[s.index(after: nl)...]), code)
}

// MARK: - CLI

func cliStatus() -> Int32 {
    if let (text, code) = askRunningProcess() { print(text, terminator: ""); return code }
    print("tiltnav \(VERSION)")
    print("  state       : not running")
    print("  hint        : launchctl bootstrap gui/$(id -u) \(agentPlist)")
    // The breadcrumb is only a crash trace, never live status — and it must not claim a process
    // is gone without checking. "Alive but not answering" is a different diagnosis (older build).
    if let s = try? String(contentsOfFile: pidFile, encoding: .utf8),
       let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
        let alive = kill(pid, 0) == 0
        print("  breadcrumb  : pid file says \(pid) — " + (alive
            ? "that process IS alive but did not answer the control socket (an older tiltnav? restart the agent)"
            : "that process is gone (stale breadcrumb)"))
    }
    return Health.notRunning.exitCode
}

func cliUninstall() -> Int32 {
    print("This removes tiltnav completely:")
    let items = [agentPlist, appPath, configPath, stateDir, logPath,
                 NSString(string: "~/.local/bin/tiltnav").expandingTildeInPath]
    for i in items { print("  \(i)") }
    print("\nIt cannot remove the Accessibility entry — do that in System Settings › Privacy & Security ›")
    print("Accessibility (select Tiltnav, click −).")
    print("\nProceed? [y/N] ", terminator: "")
    guard let line = readLine(), line.lowercased() == "y" else { print("aborted."); return 1 }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["bootout", "gui/\(getuid())/com.m5air.tiltnav"]
    try? p.run(); p.waitUntilExit()
    for i in items { try? FileManager.default.removeItem(atPath: i) }
    print("removed. The Accessibility entry is still yours to delete.")
    return 0
}

let args = CommandLine.arguments
if args.contains("--help") {
    print("""
    tiltnav \(VERSION) — wheel tilt (horizontal scroll) → a keystroke, per application.

      --status       ask the running process: state, proof, activity counters, conflicts
                     exit 0 healthy · 1 deaf · 2 config · 3 not running · 4 paused · 5 degraded
      --uninstall    remove app, agent, config, state and log (prompts first)
      --help         this text

    Config : \(configPath)   (hand-edited; tiltnav never writes it)
    Log    : \(logPath)
    Setup  : the menu-bar item shows every problem state and links to its fix.

    Buttons are NOT handled here — they belong in karabiner.json. This tool only ever sees
    horizontal scroll, which Karabiner structurally cannot.
    """)
    exit(0)
}
if args.contains("--status")    { exit(cliStatus()) }
if args.contains("--uninstall") { exit(cliUninstall()) }

// MARK: - Menu bar

final class MenuController: NSObject, NSMenuDelegate {
    var statusItem: NSStatusItem!

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu
        refresh()
    }

    /// Four mutually exclusive states, each a distinct silhouette — not just a dimmed variant,
    /// so "deaf" is never mistaken for "paused" at a glance.
    func refresh() {
        guard let b = statusItem?.button else { return }
        let conflicts = scrollTapsOtherThanUs().filter { $0.enabled }.count
        let health = currentHealth(conflicts: conflicts, unresolved: rt.config.unresolved.count)
        let symbol: String
        switch health {
        case .deaf:          symbol = "exclamationmark.triangle"
        case .paused:        symbol = "arrow.left.and.right.slash"
        case .degraded, .configProblem: symbol = "arrow.left.and.right.circle"
        default:             symbol = "arrow.left.and.right"
        }
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "tiltnav")
        b.image?.isTemplate = true
        if b.image == nil { b.title = health == .healthy ? "⇄" : "⇄!" }
        b.appearsDisabled = (health == .paused)
        b.toolTip = "tiltnav — \(health.label)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let conflicts = scrollTapsOtherThanUs().filter { $0.enabled }
        let health = currentHealth(conflicts: conflicts.count, unresolved: rt.config.unresolved.count)

        add(menu, "tiltnav \(VERSION) — \(health.label)", enabled: false)

        if !rt.selfTestPassed {
            add(menu, "   no proof the tap works", enabled: false)
            if !AXIsProcessTrusted() {
                add(menu, "Open Accessibility Settings…", #selector(openAccessibility))
                add(menu, "Why did this stop working?", #selector(explainGrant))
            } else {
                add(menu, "Re-run self-test", #selector(retest))
            }
        } else {
            add(menu, rt.paused ? "Resume" : "Pause", #selector(togglePause))
        }

        menu.addItem(.separator())
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        add(menu, "Frontmost: \(front)", enabled: false)
        let beh = rt.config.apps[front] ?? rt.config.defaultBehaviour
        add(menu, "   \(glyphDescribe(beh))\(rt.config.apps[front] != nil ? "  (override)" : "  (default)")", enabled: false)
        add(menu, "Copy mapping snippet for this app", #selector(copySnippet))

        menu.addItem(.separator())
        add(menu, "\(rt.eventsSeen) tilts seen · \(rt.chordsSent) chords sent · last \(ago(rt.lastEventAt))", enabled: false)
        if rt.config.discreteWheelOnly { add(menu, "trackpad ignored · \(rt.continuousIgnored) swipes passed through", enabled: false) }
        add(menu, "   \(rt.calibration.describe)", enabled: false)
        add(menu, "Swap tilt directions", #selector(swapDirections))
        let w = NSMenuItem(title: "Watch tilts in the log", action: #selector(toggleWatch), keyEquivalent: "")
        w.target = self; w.state = rt.watchTilts ? .on : .off
        menu.addItem(w)

        if !conflicts.isEmpty || !rt.config.rejected.isEmpty || !rt.config.unresolved.isEmpty {
            menu.addItem(.separator())
            for c in conflicts { add(menu, "conflict: \(c.name) also taps scroll", enabled: false) }
            for r in rt.config.rejected { add(menu, "config: \(r)", enabled: false) }
            for u in rt.config.unresolved { add(menu, "config: no app for \(u)", enabled: false) }
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = startAtLoginEnabled() ? .on : .off
        menu.addItem(login)
        add(menu, "Edit Config…", #selector(editConfig))
        add(menu, "Reload Config", #selector(reload))
        add(menu, "Show Log", #selector(showLog))
        add(menu, "Status in Terminal", #selector(showStatus))
        menu.addItem(.separator())
        let q = NSMenuItem(title: launchedBy().hasPrefix("launchd") ? "Quit (agent restarts at login)" : "Quit",
                           action: #selector(quit), keyEquivalent: "q")
        q.target = self; menu.addItem(q)
    }

    private func add(_ m: NSMenu, _ title: String, _ sel: Selector? = nil, enabled: Bool = true) {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        if let sel = sel { i.target = self; _ = sel } else { i.isEnabled = false }
        if !enabled { i.isEnabled = false }
        m.addItem(i)
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func explainGrant() {
        let a = NSAlert()
        a.messageText = "tiltnav has no proof it can see your mouse"
        a.informativeText = grantDiagnosis() + "\n\nThe Accessibility grant for this app is tied to the exact binary, so rebuilding it revokes the grant while the System Settings row still looks ticked. Remove the Tiltnav entry, then add \(appPath) again."
        a.addButton(withTitle: "Open Accessibility Settings")
        a.addButton(withTitle: "Close")
        if a.runModal() == .alertFirstButtonReturn { openAccessibility() }
    }

    @objc func retest() { runSelfTest(); refresh() }

    @objc func togglePause() {
        rt.paused.toggle(); logln(rt.paused ? "paused via menu" : "resumed via menu"); refresh()
    }

    @objc func swapDirections() {
        rt.calibration.positiveIsTiltLeft.toggle()
        rt.calibration.calibrated = true
        rt.calibration.save()
        logln("calibration set: \(rt.calibration.describe)")
        refresh()
    }

    @objc func toggleWatch() {
        rt.watchTilts.toggle()
        logln(rt.watchTilts ? "watching tilts (every event logged)" : "stopped watching tilts")
    }

    @objc func copySnippet() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "com.example.app"
        let snippet = """
            "\(front)": { "tiltLeft": ["option", "arrowLeft"], "tiltRight": ["option", "arrowRight"] }
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        logln("copied mapping snippet for \(front)")
    }

    @objc func editConfig() {
        if !FileManager.default.fileExists(atPath: configPath) {
            // The one bounded exception to "tiltnav never writes the config": create if absent.
            let seed = """
            {
              "debounceSeconds": 0.3,
              "default": { "tiltLeft": ["command", "["], "tiltRight": ["command", "]"] },
              "apps": {
              }
            }
            """
            try? seed.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    @objc func reload() {
        if let c = Config.load() { rt.config = c; logln("config reloaded via menu") }
        else { logln("config reload FAILED — keeping last-good config") }
        refresh()
    }

    @objc func toggleLogin() { setStartAtLogin(!startAtLoginEnabled()) }

    @objc func showLog()    { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }

    @objc func showStatus() {
        let a = NSAlert()
        a.messageText = "tiltnav status"
        a.informativeText = statusReport().0
        a.addButton(withTitle: "Copy"); a.addButton(withTitle: "Close")
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(statusReport().0, forType: .string)
        }
    }

    /// Stops this process only. It must never unload the LaunchAgent: that turned a Quit into a
    /// permanently-disabled service whose replacement was an unmanaged Finder instance.
    @objc func quit() {
        logln("quit requested via menu")
        try? FileManager.default.removeItem(atPath: pidFile)
        unlink(sockPath)
        NSApp.terminate(nil)
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menuController = MenuController()
menuController.install()                       // before anything that can fail

if !acquireSingleton() {
    logln("another tiltnav already holds the lock — exiting so two taps do not fight")
    // Tell the user rather than vanishing.
    let a = NSAlert()
    a.messageText = "tiltnav is already running"
    a.informativeText = "Another instance holds the lock. This one will quit."
    a.runModal()
    exit(0)
}

try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
try? "\(getpid())\n".write(toFile: pidFile, atomically: true, encoding: .utf8)

if let c = Config.load() { rt.config = c } else {
    rt.config.parsedOK = false
    logln("config PARSE FAILED at startup — passing every tilt through until it is fixed")
}
logln("config: default=\(describe(rt.config.defaultBehaviour)), \(rt.config.apps.count) override(s), debounce=\(rt.config.debounce)s")
logln("launched by \(launchedBy())")

rt.tapArmed = armTap()
if rt.tapArmed { runSelfTest() } else {
    logln("no event tap — \(grantDiagnosis()). Menu bar item will say so; retrying every 5s.")
}
menuController.refresh()
serveControlSocket()

var configMTime = rt.config.mtime
let poll = Timer(timeInterval: 2.0, repeats: true) { _ in
    let m = (try? FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate]) as? Date
    if m != configMTime {
        configMTime = m
        if let c = Config.load() { rt.config = c; logln("config changed on disk — reloaded") }
        else { logln("config changed but PARSE FAILED — keeping last-good") }
        menuController.refresh()
    }
    if !rt.tapArmed {
        rt.tapArmed = armTap()
        if rt.tapArmed { logln("Accessibility granted — tap armed"); runSelfTest(); menuController.refresh() }
    } else if let t = rt.tap, !CGEvent.tapIsEnabled(tap: t) {
        rt.tapReEnables += 1
        logln("tap found disabled — re-enabling (count \(rt.tapReEnables))")
        CGEvent.tapEnable(tap: t, enable: true)
    }
}
CFRunLoopAddTimer(CFRunLoopGetCurrent(), poll, .commonModes)

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    logln("woke from sleep — re-validating tap")
    if let t = rt.tap, !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
    runSelfTest()
    menuController.refresh()
}

signal(SIGHUP) { _ in if let c = Config.load() { rt.config = c } }
logln("started \(VERSION) (pid \(getpid())) — menu bar item installed")
app.run()
