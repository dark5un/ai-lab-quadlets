// maxagg — create the CoreAudio aggregate devices the MaxPresence P1/P3 tests
// need. Public API only (AudioHardwareCreateAggregateDevice, macOS 10.9+).
//
//   maxagg status                 — show MAX devices, built-ins, aggregates
//   maxagg create-mix-in          — "MAX Mix In": MAX Mic + built-in mic,
//                                   STACKED (inputs summed to 2ch) -> select it
//                                   as the app mic so BOTH you and Max speak.
//   maxagg create-multi-out       — "MAX Multi Out": built-in output + MAX Out
//                                   -> meeting audio reaches you AND plexpipe.
//   maxagg destroy NAME           — remove an aggregate by name.
//
// Why: macOS gives every app exactly ONE input device; "MAX Mic disallows the
// real mic" is that rule, not a Meet/MaxHole bug. An aggregate device merges
// them. Stacked mode sums channel-wise (2ch+2ch -> 2ch) so Meet/Chrome sees a
// normal mic sized stream. Clock comes from the built-in device; MaxHole gets
// drift compensation (it is a software clock).
import CoreAudio
import Foundation

func adr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func u32(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var a = adr(sel, scope); var v: UInt32 = 0; var sz = UInt32(4)
    return AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &v) == noErr ? v : nil
}
func cfString(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = adr(sel); var n: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    return AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &n) == noErr ? (n?.takeRetainedValue() as String?) : nil
}
func devices() -> [AudioObjectID] {
    var a = adr(kAudioHardwarePropertyDevices); var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / 4)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids) == noErr else { return [] }
    return ids
}
struct Dev { let id: AudioObjectID; let name: String
    var uid: String? { cfString(id, kAudioDevicePropertyDeviceUID) }
    // channel counts via the stream configuration per scope (AudioBufferList)
    func chanCount(_ scope: AudioObjectPropertyScope) -> UInt32 {
        var a = adr(kAudioDevicePropertyStreamConfiguration, scope); var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr, sz >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, raw) == noErr else { return 0 }
        let ablPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        var total: UInt32 = 0
        withUnsafeMutablePointer(to: &ablPtr.pointee.mBuffers) { p in
            p.withMemoryRebound(to: AudioBuffer.self, capacity: Int(ablPtr.pointee.mNumberBuffers)) { bufs in
                for i in 0..<Int(ablPtr.pointee.mNumberBuffers) { total += bufs[i].mNumberChannels }
            }
        }
        return total
    }
    var ins: UInt32 { chanCount(kAudioObjectPropertyScopeInput) }
    var outs: UInt32 { chanCount(kAudioObjectPropertyScopeOutput) }
    func chanMap(_ scope: AudioObjectPropertyScope) -> String {
        var a = adr(kAudioDevicePropertyStreamConfiguration, scope); var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr, sz >= UInt32(MemoryLayout<AudioBufferList>.size) else { return "[]" }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, raw) == noErr else { return "[]" }
        let ablPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        var chs: [UInt32] = []
        withUnsafeMutablePointer(to: &ablPtr.pointee.mBuffers) { q in
            q.withMemoryRebound(to: AudioBuffer.self, capacity: Int(ablPtr.pointee.mNumberBuffers)) { bufs in
                for i in 0..<Int(ablPtr.pointee.mNumberBuffers) { chs.append(bufs[i].mNumberChannels) }
            }
        }
        return chs.map(String.init).joined(separator: "+")
    }
    var transport: UInt32? { u32(id, kAudioDevicePropertyTransportType) }
    var isAggregate: Bool { transport == UInt32(kAudioDeviceTransportTypeAggregate) }
    var isBuiltIn: Bool { transport == UInt32(kAudioDeviceTransportTypeBuiltIn) }
}
func devs() -> [Dev] {
    devices().compactMap { id in cfString(id, kAudioObjectPropertyName).map { Dev(id: id, name: $0) } }
}

func createAggregate(_ name: String, aggUID: String, subUIDs: [(uid: String, drift: Bool)], clockUID: String, stacked: Int?) -> (OSStatus, AudioObjectID) {
    // PITFALL (2026-11-12): top-level "uid" (the aggregate's OWN persistent id)
    // is REQUIRED — without it AudioHardwareCreateAggregateDevice returns 'inva'.
    let subs: [[String: Any]] = subUIDs.map { ["uid": $0.uid, "drift": $0.drift ? 1 : 0] }
    var desc: [String: Any] = ["name": name, "uid": aggUID, "subdevices": subs, "clock": clockUID]
    // stacked semantics (resolved via web investigation 2026-11-12):
    //   nil/absent = plain aggregate: channels CONCATENATED (mic1 + max2 = in=3)
    //   1          = MULTI-OUTPUT style fan-out: same stream fed to every subdevice
    // For MAX Mix In we deliberately use CONCATENATION with the physical mic
    // FIRST: Chrome/Meet uses the first two channels of an input; mic(ch1)+
    // MAX-L(ch2) both fall inside that pair, while the MAX-first ordering is
    // exactly the known Meet failure mode (Google community thread).
    var newID = AudioObjectID(0)
    let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newID)
    return (st, newID)
}
func destroy(_ d: Dev) { AudioHardwareDestroyAggregateDevice(d.id) }

func find(_ n: String) -> Dev? { devs().first { $0.name == n } }

func fourcc(_ v: UInt32?) -> String {
    guard let v else { return "?" }
    return String(decoding: withUnsafeBytes(of: v.bigEndian) { Array($0) }.filter { $0 >= 32 && $0 < 127 }, as: UTF8.self)
}
func status() {
    for d in devs().sorted(by: { $0.name < $1.name }) {
        guard d.ins > 0 || d.outs > 0 else { continue }
        print("  \(d.name)  in=[\(d.chanMap(kAudioObjectPropertyScopeInput))] out=[\(d.chanMap(kAudioObjectPropertyScopeOutput))] transport=\(fourcc(d.transport)) uid=\(d.uid ?? "?")")
    }
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "status" {
case "status": status()
case "create-mix-in":
    let all = devs()
    guard let maxmic = all.first(where: { $0.name == "MAX Mic" }), let mmu = maxmic.uid else { print("MAX Mic not found"); exit(1) }
    guard let bi = all.first(where: { $0.isBuiltIn && $0.ins > 0 }) ?? all.first(where: { !$0.isAggregate && $0.name != "MAX Mic" && $0.ins > 0 }), let biu = bi.uid else { print("secondary input device not found"); exit(1) }
    if let old = find("MAX Mix In") { destroy(old); Thread.sleep(forTimeInterval: 1) }
    let (st, id) = createAggregate("MAX Mix In", aggUID: "io.onlyascii.maxmixin", subUIDs: [(biu, false), (mmu, true)], clockUID: biu, stacked: nil)
    print(st == noErr ? "created MAX Mix In (id \(id)) — select it as the mic in Meet" : "create failed: \(st)")
case "create-multi-out":
    let all = devs()
    guard let maxout = all.first(where: { $0.name == "MAX Out" }), let mou = maxout.uid else { print("MAX Out not found"); exit(1) }
    guard let bi = all.first(where: { $0.isBuiltIn && $0.outs > 0 }) ?? all.first(where: { !$0.isAggregate && $0.name != "MAX Out" && $0.outs > 0 }), let biu = bi.uid else { print("secondary output device not found"); exit(1) }
    if let old = find("MAX Multi Out") { destroy(old); Thread.sleep(forTimeInterval: 1) }
    let (st, id) = createAggregate("MAX Multi Out", aggUID: "io.onlyascii.maxmultiout", subUIDs: [(biu, false), (mou, true)], clockUID: biu, stacked: 1)
    print(st == noErr ? "created MAX Multi Out (id \(id)) — select it as the speaker in Meet" : "create failed: \(st)")
case "destroy":
    guard args.count > 2, let d = find(args[2]) else { print("usage: maxagg destroy NAME"); exit(1) }
    destroy(d); print("destroyed \(args[2])")
default: print("unknown subcommand"); exit(2)
}
