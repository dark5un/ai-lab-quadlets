// FrameClient.swift — the extension dials the plexpipe door ITSELF
// (owner decision 2026-11-12, P2 option 2: extension-as-network-client;
// sandbox permits CLIENT networking — needs com.apple.security.network.client).
// One 'video' session: hello caps=["video"] -> binary 'V' JPEG frames + stat.
// Door URL comes from config.json in the shared App Group container (written
// by the host app / owner once); dev default baked below.
import Foundation

final class FrameClient: NSObject, URLSessionWebSocketDelegate {
    struct Frame { let jpeg: Data }
    let onFrame: (Data) -> Void
    private var task: URLSessionWebSocketTask?
    private var shouldRun = false

    static func doorURL() -> String {
        // App Group config (preferred): {"door":"wss://<host>:8457"}
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: MaxCamDeviceSource.groupID)?
            .appendingPathComponent("config.json"),
           let data = try? Data(contentsOf: url),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let door = j["door"] as? String {
            return door
        }
        return "wss://ai.tail1720c8.ts.net:8457"   // dev default (tailnet)
    }

    init(onFrame: @escaping (Data) -> Void) { self.onFrame = onFrame }

    func start() {
        shouldRun = true
        connect()
    }
    func stop() { shouldRun = false; task?.cancel(with: .normalClosure, reason: nil) }

    private func connect() {
        guard shouldRun else { return }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let t = session.webSocketTask(with: URL(string: Self.doorURL())!)
        self.task = t
        t.resume()
        t.send(.string(#{"{"t":"hello","v":1,"caps":["video"]}"#)) { [weak self] err in
            if let err { self?.scheduleRetry(); return }
            // until the real renderer lands, ask for the testsrc feed:
            t.send(.string(#{"{"t":"testvideo","on":true}"#)) { _ in }
            self?.receive()
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
                case let .data(.binary(d)):
                    if d.first == UInt8(ascii: "V") { self.onFrame(d.subdata(in: 1..<d.count)) }
                case let .string(s):
                    if let data = s.data(using: .utf8),
                       let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       j["t"] as? String == "bye" { self.scheduleRetry(); break }
                default: break
                }
                self.receive()
            }
        }
    }

    private func scheduleRetry() {
        task?.cancel()
        guard shouldRun else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.connect() }
    }

    // session-level auth on this door: none by design (tailnet-only)
    func urlSession(_ s: URLSession, task: URLSessionTask,
                    didCompleteWithError e: Error?) {}
}
