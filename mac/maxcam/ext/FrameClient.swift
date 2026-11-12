// FrameClient.swift — the extension dials the plexpipe door ITSELF
// (owner decision 2026-11-12, P2 option 2: extension-as-network-client;
// sandbox CLIENT networking via com.apple.security.network.client).
// One 'video' session: hello caps=["video"] -> binary 'V' JPEG frames + stat.
// Door URL comes from config.json in the shared App Group container
// (written once by the host app / owner); dev default baked below.
import Foundation

final class FrameClient: NSObject, URLSessionWebSocketDelegate {
    static let groupID = "R2XM78R4TE.io.onlyascii.maxcam"

    let onFrame: (Data) -> Void
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var shouldRun = false

    static func doorURL() -> String {
        // App Group config (preferred): {"door":"wss://<host>:8457"}
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("config.json"),
           let data = try? Data(contentsOf: url),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let door = j["door"] as? String {
            return door
        }
        return "wss://ai.tail1720c8.ts.net:8457"   // dev default (tailnet)
    }

    init(onFrame: @escaping (Data) -> Void) { self.onFrame = onFrame }

    func start() { shouldRun = true; connect() }

    func stop() {
        shouldRun = false
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil; session = nil
    }

    private func connect() {
        guard shouldRun else { return }
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        let t = s.webSocketTask(with: URL(string: Self.doorURL())!)
        task = t
        t.resume()
        t.send(.string(#"{"t":"hello","v":1,"caps":["video"]}"#)) { [weak self] err in
            guard let self else { return }
            if err != nil { NSLog("maxcam door hello failed: %@", String(describing: err)); self.scheduleRetry(); return }
            // until the real renderer lands, ask for the testsrc feed:
            t.send(.string(#"{"t":"testvideo","on":true}"#)) { _ in }
            self.receive()
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.scheduleRetry()
            case let .success(msg):
                switch msg {
                case let .data(d):
                    if d.first == UInt8(ascii: "V"), d.count > 1 {
                        self.onFrame(d.subdata(in: 1..<d.count))
                    }
                case let .string(s):
                    if let data = s.data(using: .utf8),
                       let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       j["t"] as? String == "bye" { self.scheduleRetry() }
                @unknown default:
                    break
                }
                self.receive()
            }
        }
    }

    private func scheduleRetry() {
        task?.cancel()
        session?.finishTasksAndInvalidate()
        task = nil; session = nil
        guard shouldRun else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.connect() }
    }
}
