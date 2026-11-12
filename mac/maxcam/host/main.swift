// MaxCamHost — host app (v0): ONLY activates/deactivates the embedded
// extension; it is NOT the frame pump (mailbox design). Drop into the
// Xcode app target; wire the button in Main.storyboard or programmatic UI.
import AppKit
import SystemExtensions

final class ActivationDelegate: NSObject, OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        print("replacing \(existing.bundleIdentifier) v\(existing.bundleShortVersion) with v\(ext.bundleShortVersion)")
        return .replace
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("awaiting approval: System Settings > General > Login Items & Extensions > Camera Extensions")
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        print("activation result: \(result.rawValue)")  // completed | willCompleteUponReboot
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        print("activation FAILED: \(error.localizedDescription)")
        NSLog("maxcamhost activation error: %@", String(reflecting: error))
    }
}

let delegate = ActivationDelegate()
let app = NSApplication.shared
let window = NSWindow(contentRect: NSMakeRect(0, 0, 420, 120),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "MAX Camera host"
let button = NSButton(title: "Activate MAX Camera extension", target: nil, action: nil)
button.frame = NSMakeRect(20, 50, 380, 32)
button.target = ActivationActions.shared
button.action = #selector(ActivationActions.activate(_:))
window.contentView?.addSubview(button)
window.makeKeyAndOrderFront(nil)
app.setActivationPolicy(.regular)

// headless mode: MaxCamHost --activate  (submit request immediately; results
// printed to stdout — owner runs this from a terminal, then approves in
// System Settings > General > Login Items & Extensions)
if CommandLine.arguments.contains("--activate") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        ActivationActions.shared.activate(nil)
    }
}

app.run()

final class ActivationActions: NSObject {
    static let shared = ActivationActions()
    @objc func activate(_ sender: Any?) {
        let req = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: "io.onlyascii.maxcam.extension",
            queue: .main)
        req.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(req)
    }
}
