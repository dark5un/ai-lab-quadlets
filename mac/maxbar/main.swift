#!/usr/bin/env swiftc
// MAXBar — macOS menu-bar (toolbar) widget for the MaxPresence virtual
// interfaces. Read-only observer; opens NO audio/capture streams, so it never
// trips the owner's mic-consent policy (TCC). It reports:
//
//   1. Link      — maxaudiod <-> plexpipe WSS door state, read from the
//                  heartbeat file maxaudiod writes at
//                  ~/Library/Application Support/MaxPresence/*.json
//                  (generic: any daemon dropping a same-schema file shows up,
//                  e.g. MaxCamHost when P2 lands).
//   2. Audio     — MaxHole devices "MAX Mic"/"MAX Out": installed + per-scope
//                  kAudioDevicePropertyDeviceIsRunning (who is feeding/reading
//                  each side right now).
//   3. Video     — CMIO enumeration for "MAX Camera" +
//                  kCMIODevicePropertyDeviceIsRunningSomewhere (P2 device).
//
// Build: ./build.sh   Run:   open MAXBar.app  (or ./maxbar --selftest)
import AppKit
import CoreAudio
import CoreMediaIO
import AVFoundation

let kSys = AudioObjectID(kAudioObjectSystemObject)
let kMaxMic = "MAX Mic", kMaxOut = "MAX Out", kMaxCam = "MAX Camera"
let kStatusDir = (NSString(string: "~/Library/Application Support/MaxPresence")).expandingTildeInPath
let kHeartbeatFresh: TimeInterval = 6   // daemon writes every 2 s

// ---------------------------------------------------------------- CoreAudio
func caAddress(_ sel: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
               _ elem: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: elem)
}
func caUInt32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var a = caAddress(sel, scope); var v: UInt32 = 0; var sz = UInt32(4)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v) == noErr ? v : nil
}
func caDevices() -> [AudioObjectID] {
    var a = caAddress(kAudioHardwarePropertyDevices); var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(kSys, &a, 0, nil, &sz) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.stride)
    guard AudioObjectGetPropertyData(kSys, &a, 0, nil, &sz, &ids) == noErr else { return [] }
    return ids
}
func caName(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = caAddress(sel)
    var name: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &name) == noErr
        ? (name?.takeRetainedValue() as String?) : nil
}
struct AudioDev { let id: AudioObjectID; let name: String
    // MEASURED on MaxHole (2026-11-12): kAudioStreamPropertyIsActive ('sact')
    // is statically 1 -> useless. kAudioDevicePropertyDeviceIsRunningSomewhere
    // ('gone', global scope) flips 0->1 exactly while a client streams and
    // back to 0 after. Scope-qualified 'gone' mirrors global on these
    // full-duplex virtual pipes, so one flag per device is all we report.
    var inUse: Bool { caUInt32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1 }
}
func findMaxAudio() -> (mic: AudioDev?, out: AudioDev?) {
    var mic: AudioDev?, out: AudioDev?
    for id in caDevices() {
        guard let n = caName(id, kAudioObjectPropertyName) else { continue }
        if n == kMaxMic { mic = AudioDev(id: id, name: n) }
        if n == kMaxOut { out = AudioDev(id: id, name: n) }
    }
    return (mic, out)
}

// ---------------------------------------------------------------- CoreMediaIO (virtual cameras)
func cmioAddress(_ sel: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(sel),
                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}
func findMaxCamera() -> (present: Bool, inUse: Bool) {
    let sys = CMIOObjectID(kCMIOObjectSystemObject)
    var a = cmioAddress(kCMIOHardwarePropertyDevices); var sz: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(sys, &a, 0, nil, &sz) == noErr else { return (false, false) }
    var ids = [CMIOObjectID](repeating: 0, count: Int(sz) / MemoryLayout<CMIOObjectID>.stride)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(sys, &a, 0, nil, sz, &used, &ids) == noErr else { return (false, false) }
    for id in ids {
        var na = cmioAddress(kCMIOObjectPropertyName)
        var name: Unmanaged<CFString>?
        var sz2 = UInt32(MemoryLayout<Unmanaged<CFString>?>.size); var u2: UInt32 = 0
        CMIOObjectGetPropertyData(id, &na, 0, nil, sz2, &u2, &name)
        if (name?.takeRetainedValue() as String?) == kMaxCam {
            var ga = cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
            var gone: UInt32 = 0; var u3: UInt32 = 0
            CMIOObjectGetPropertyData(id, &ga, 0, nil, 4, &u3, &gone)
            return (true, gone == 1)
        }
    }
    return (false, false)
}

// ---------------------------------------------------------------- heartbeat daemons
struct Daemon {
    let name: String; var connected = false, door = "", mode = ""
    var tx = 0, rx = 0, errors = 0
    var age: TimeInterval = .greatestFiniteMagnitude   // seconds since last write
    var lastStatAge: TimeInterval = .greatestFiniteMagnitude  // server stat heartbeat
    var plexUp: Bool?, bridgeUp: Bool?
    var fresh: Bool { age < kHeartbeatFresh }
    var statFresh: Bool { lastStatAge < 6 }            // server sends every ~2 s
    var healthy: Bool { fresh && connected && statFresh && plexUp == true && bridgeUp == true }
    var brain: String {
        if !statFresh { return "server: no stat heartbeats" }
        return "server: plex \(plexUp == true ? "✓" : "✗") bridge \(bridgeUp == true ? "✓" : "✗")"
    }
    var state: String {
        if !fresh && age == .greatestFiniteMagnitude { return "no status file" }
        if !fresh { return "down — last seen \(Int(age)) s ago" }
        return connected ? "LINK UP (\(door)) — \(brain)" : "up, link down"
    }
}
func readDaemons() -> [Daemon] {
    let fm = FileManager.default
    let now = Date().timeIntervalSince1970
    var out: [Daemon] = []
    guard let files = try? fm.contentsOfDirectory(atPath: kStatusDir) else { return out }
    for f in files.sorted() where f.hasSuffix(".json") {
        var d = Daemon(name: String(f.dropLast(5)))
        guard let data = fm.contents(atPath: kStatusDir + "/" + f),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { out.append(d); continue }
        d.connected = (j["connected"] as? Bool) ?? false
        d.door = (j["door"] as? String) ?? ""
        d.mode = (j["mode"] as? String) ?? ""
        d.tx = (j["tx_frames"] as? Int) ?? 0
        d.rx = (j["rx_frames"] as? Int) ?? 0
        d.errors = (j["errors"] as? Int) ?? 0
        if let v = j["plex_up"] as? Bool { d.plexUp = v }
        if let v = j["bridge_up"] as? Bool { d.bridgeUp = v }
        if let ts = j["ts"] as? Double { d.age = now - ts }
        if let ls = j["last_stat"] as? Double { d.lastStatAge = now - ls }
        out.append(d)
    }
    return out
}

// ---------------------------------------------------------------- self-check (rights)
// MAXBar is a pure property-reader: measured on macOS 27.2 it needs NO TCC
// right (mic, camera, Accessibility...) — queries succeed while authorization
// status is notDetermined, and no prompt ever appears. But that is an
// assumption about THIS OS build, so the widget verifies its own capabilities
// every poll and surfaces failures (plus the rights that would gate them)
// instead of silently showing wrong state. Note: ad-hoc signing means a
// rebuild can drop any future grant — TCC keys on cdhash.
struct Capability { let name: String; let ok: Bool; let hint: String }

func caNameStatus(_ obj: AudioObjectID) -> OSStatus {
    var a = caAddress(kAudioObjectPropertyName); var n: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &n)
}
func caps() -> [Capability] {
    var out: [Capability] = []
    let devs = caDevices()
    let nameOK = devs.contains { caNameStatus($0) == noErr }
    let goneOK = devs.contains { caUInt32($0, kAudioDevicePropertyDeviceIsRunningSomewhere) != nil }
    out.append(Capability(name: "CoreAudio enumerate+state", ok: nameOK && goneOK,
        hint: nameOK && goneOK ? "no rights required"
              : "coreaudiod/MaxHole unhealthy? (killall -9 coreaudiod) — TCC never gates these reads"))
    let sys = CMIOObjectID(kCMIOObjectSystemObject)
    var a = cmioAddress(kCMIOHardwarePropertyDevices); var sz: UInt32 = 0
    let enumSt = CMIOObjectGetPropertyDataSize(sys, &a, 0, nil, &sz)
    var cmOK = enumSt == noErr && sz > 0
    if cmOK {
        var ids = [CMIOObjectID](repeating: 0, count: Int(sz) / MemoryLayout<CMIOObjectID>.stride)
        var used: UInt32 = 0
        if CMIOObjectGetPropertyData(sys, &a, 0, nil, sz, &used, &ids) == noErr {
            cmOK = ids.contains { id in
                var ga = cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
                var g: UInt32 = 0; var u: UInt32 = 0
                return CMIOObjectGetPropertyData(id, &ga, 0, nil, 4, &u, &g) == noErr
            }
        }
    }
    let camAuth = AVCaptureDevice.authorizationStatus(for: .video)
    out.append(Capability(name: "CMIO enumerate+state", ok: cmOK,
        hint: cmOK ? "no rights required (verified notDetermined=\(camAuth == .notDetermined))"
              : "camera state queries blocked — System Settings › Privacy & Security › Camera"
                + (camAuth == .denied ? " (DENIED for MAXBar; re-grant after every rebuild: ad-hoc cdhash changes)" : "")))
    let dirExists = FileManager.default.fileExists(atPath: kStatusDir)
    var listErr: String?
    if dirExists {  // real read attempt — isReadableFile() lies on dirs (verified)
        do { _ = try FileManager.default.contentsOfDirectory(atPath: kStatusDir) }
        catch { listErr = "\(error)" }
    }
    let dirOK = !dirExists || listErr == nil
    out.append(Capability(name: "heartbeat dir readable", ok: dirOK,
        hint: dirOK ? (dirExists ? "readable" : "absent (no daemon has run yet — fine)")
              : "BLOCKED — fix perms on \(kStatusDir): \(listErr!)"))
    let needsInput = false   // MAXBar never opens streams; if that ever changes: mic right
    out.append(Capability(name: "audio input capture", ok: !needsInput, hint: "not used — by design (owner consent policy)"))
    return out
}

// ---------------------------------------------------------------- snapshot + UI
struct Snapshot {
    let mic: AudioDev?, out: AudioDev?, cam: (present: Bool, inUse: Bool), daemons: [Daemon], caps: [Capability]
    var audioActive: Bool { (mic?.inUse ?? false) || (out?.inUse ?? false) }
    var linkUp: Bool { daemons.contains { $0.fresh && $0.connected } }
    var healthy: Bool { daemons.contains { $0.healthy } }
    var daemonUp: Bool { daemons.contains { $0.fresh } }
}
func poll() -> Snapshot {
    let (mic, out) = findMaxAudio()
    return Snapshot(mic: mic, out: out, cam: findMaxCamera(), daemons: readDaemons(), caps: caps())
}

final class Bar: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var snap = poll()

    // The mark: an IRIS (lens ring + pupil = the Max persona you see through)
    // broadcasting VOICE ARCS out both sides (the audio link), with a state
    // dot bottom-right (green link-up / orange daemon-up-link-down / gray
    // down). Glyph colour follows the menu-bar appearance; not a template
    // image because the dot carries colour.
    static func icon(dark: Bool, state: NSColor) -> NSImage {
        let sz = NSSize(width: 22, height: 18)
        let k = 2  // render at Retina resolution; also guarantees a bitmap
                   // backing so the destinationOut knockout actually works
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(sz.width) * k, pixelsHigh: Int(sz.height) * k,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: CGFloat(k), y: CGFloat(k))
        drawIcon(dark: dark, state: state, sz: sz)
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: sz)
        img.addRepresentation(rep)
        img.isTemplate = false
        return img
    }
    static func drawIcon(dark: Bool, state: NSColor, sz: NSSize) {
        let g = dark ? NSColor.white : NSColor(calibratedWhite: 0.13, alpha: 1)
        let cx = CGFloat(11), cy = CGFloat(9.2)
        func stroke(_ p: NSBezierPath, _ w: CGFloat) { p.lineWidth = w; g.setStroke(); p.stroke() }
        // iris: ring + pupil with generous negative space between them
        stroke(NSBezierPath(ovalIn: NSRect(x: cx - 4.3, y: cy - 4.3, width: 8.6, height: 8.6)), 1.5)
        g.setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - 1.3, y: cy - 1.3, width: 2.6, height: 2.6)).fill()
        // broadcast/voice arcs, mirrored, fully inside the canvas. Drawn as
        // sampled polylines on purpose: NSBezierPath.appendArc direction
        // semantics burned us (5-arg = long way -> 292-degree rings; the
        // clockwise: false variant still skipped the pi side on 2026-11-12).
        for r in [7.0, 9.4] as [CGFloat] {
            for base in [CGFloat(0), .pi] {
                let p = NSBezierPath()
                for d in stride(from: -34.0, through: 34.0, by: 2.0) {
                    let a = base + CGFloat(d) * .pi / 180.0
                    let pt = NSPoint(x: cx + r * cos(a), y: cy + r * sin(a))
                    if d == -34.0 { p.move(to: pt) } else { p.line(to: pt) }
                }
                p.lineCapStyle = .round
                stroke(p, 1.4)
            }
        }
        // status badge: smaller, and knockout halo (destinationOut) so it can
        // never fuse with the arcs no matter the state
        let bx = CGFloat(19.4), by = CGFloat(3.0), br = CGFloat(2.2)
        NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: bx - br - 1.4, y: by - br - 1.4, width: (br + 1.4) * 2, height: (br + 1.4) * 2)).fill()
        NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
        state.setFill()
        NSBezierPath(ovalIn: NSRect(x: bx - br, y: by - br, width: br * 2, height: br * 2)).fill()
    }
    static func tooltip(_ s: Snapshot) -> String {
        func yn(_ b: Bool) -> String { b ? "streaming" : "idle" }
        var t = "link: \(s.healthy ? "UP + server healthy" : s.linkUp ? "UP (server not healthy)" : s.daemonUp ? "daemon up, link down" : "down")"
        t += " | MAX Mic " + (s.mic.map { yn($0.inUse) } ?? "missing")
        t += " | MAX Out " + (s.out.map { yn($0.inUse) } ?? "missing")
        t += " | MAX Camera " + (s.cam.present ? (s.cam.inUse ? "streaming" : "idle") : "absent")
        if s.caps.contains(where: { !$0.ok }) { t += " | ⚠ self-check failing" }
        return t
    }
    func start() {
        item.menu = { let m = NSMenu(); m.delegate = self; return m }()
        render()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.snap = poll(); self.render()
        }
    }
    func render() {
        let s = snap
        let state: NSColor = s.healthy ? .systemGreen
            : (s.linkUp ? .systemYellow          // door connected, server brain down/stale
            : (s.daemonUp ? .systemOrange : .systemGray))
        let dark = item.button?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        item.button?.image = Bar.icon(dark: dark, state: state)
        item.button?.imagePosition = .imageOnly
        item.button?.title = s.caps.contains(where: { !$0.ok }) ? "⚠" : ""
        item.button?.toolTip = Bar.tooltip(s)
    }
    // rebuild the menu only when it opens — polling stays cheap
    func menuNeedsUpdate(_ menu: NSMenu) {
        snap = poll(); menu.removeAllItems()
        let s = snap
        func row(_ t: String) { menu.addItem(disabled(t)) }
        row("Link — door bridge (maxaudiod)")
        if s.daemons.isEmpty { row("   no daemons; start: maxaudiod.py run --door URL") }
        for d in s.daemons {
            row("   \(d.name): \(d.state)")
            if d.fresh && d.connected { row("     up \(d.tx) frames · down \(d.rx) · errors \(d.errors)") }
        }
        menu.addItem(.separator())
        row("Audio — MaxHole virtual devices")
        row(audioLine("MAX Mic", s.mic))
        row(audioLine("MAX Out", s.out))
        menu.addItem(.separator())
        row("Video — virtual camera (P2)")
        row(s.cam.present ? "   MAX Camera: \(s.cam.inUse ? "INSTALLED · streaming" : "installed · idle")"
                          : "   MAX Camera: not installed (pending P2)")
        menu.addItem(.separator())
        row(s.caps.allSatisfy { $0.ok } ? "Self-check — no special rights needed" : "Self-check — FAILURES:")
        for c in s.caps { row("   \(c.ok ? "✓" : "✗") \(c.name) — \(c.hint)") }
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit MAXBar", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"); menu.addItem(q)
    }
    func audioLine(_ label: String, _ d: AudioDev?) -> String {
        guard let d else { return "   \(label): NOT INSTALLED" }
        return "   \(label): installed · \(d.inUse ? "STREAMING (in use)" : "idle")"
    }
    func disabled(_ t: String) -> NSMenuItem { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
}

// ---------------------------------------------------------------- entry
if let i = CommandLine.arguments.firstIndex(of: "--icon-dump"), i + 1 < CommandLine.arguments.count {
    let k = CommandLine.arguments.indices.contains(i + 2) ? Int(CommandLine.arguments[i + 2]) ?? 6 : 6
    let combos: [(String, Bool, NSColor)] = [
        ("dark_idle", true, .systemGray), ("dark_up", true, .systemGreen),
        ("light_down", false, .systemOrange)]
    for (name, dark, state) in combos {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 22 * k, pixelsHigh: 18 * k,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: CGFloat(k), y: CGFloat(k))
        Bar.drawIcon(dark: dark, state: state, sz: NSSize(width: 22, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(CommandLine.arguments[i+1])-\(name).png"))
    }
    exit(0)
}
if CommandLine.arguments.contains("--selftest") {
    let s = poll()
    print("link: \(s.healthy ? "UP + server healthy" : s.linkUp ? "UP but server NOT healthy" : (s.daemonUp ? "daemon up / link down" : "down"))")
    for d in s.daemons { print("daemon \(d.name): \(d.state) [age \(Int(d.age))s tx \(d.tx) rx \(d.rx) err \(d.errors)]") }
    print("MAX Mic: \(s.mic.map { "installed, in-use \($0.inUse)" } ?? "NOT INSTALLED")")
    print("MAX Out: \(s.out.map { "installed, in-use \($0.inUse)" } ?? "NOT INSTALLED")")
    print("MAX Camera: \(s.cam.present ? (s.cam.inUse ? "installed, streaming" : "installed, idle") : "not installed")")
    for c in s.caps { print("cap \(c.ok ? "✓" : "✗"): \(c.name) — \(c.hint)") }
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let bar = Bar(); bar.start()
app.run()
