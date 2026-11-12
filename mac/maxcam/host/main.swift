// MaxCamHost — host app: activates/deactivates the embedded extension; it is
// NOT the frame pump (mailbox design). Two modes:
//   GUI:      window with Activate button.
//   HEADLESS: MaxCamHost --activate — submits the request, prints the
//     delegate result to stdout, EXITS with: 0 completed · 1 failed ·
//     2 needs user approval (extension stays staged in sysextd; approval is
//     independent of this process) · 3 watchdog timeout.
//     Headless mode + exit codes are the contract MAXBar's camera-force
//     path depends on (the widget cannot hold system-extension.install).
import AppKit
import SystemExtensions

let headless = CommandLine.arguments.contains("--activate") || CommandLine.arguments.contains("--deactivate")
let deactivating = CommandLine.arguments.contains("--deactivate")

final class ActivationDelegate: NSObject, OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        print("replacing \(existing.bundleIdentifier) v\(existing.bundleShortVersion) with v\(ext.bundleShortVersion)")
        fflush(stdout)
        return .replace
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("awaiting approval: System Settings > General > Login Items & Extensions > Camera Extensions")
        fflush(stdout)
        if headless { exit(2) }   // sysextd has staged it already; this process no longer needed
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        print("activation result: \(result.rawValue)")  // completed | willCompleteUponReboot
        fflush(stdout)
        if headless { exit(0) }
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        print("activation FAILED: \(error.localizedDescription)")
        NSLog("maxcamhost activation error: %@", String(reflecting: error))
        fflush(stdout)
        if headless { exit(1) }
    }
}

let delegate = ActivationDelegate()
let app = NSApplication.shared

if headless {
    app.setActivationPolicy(.prohibited)
    // watchdog: never leak a process if the delegate never fires
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fflush(stdout); exit(3) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        ActivationActions.shared.activate(nil)
    }
} else {
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
}

app.run()

final class ActivationActions: NSObject {
    static let shared = ActivationActions()
    @objc func activate(_ sender: Any?) {
        let req = deactivating
            ? OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: "io.onlyascii.maxcam.extension", queue: .main)
            : OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: "io.onlyascii.maxcam.extension", queue: .main)
        req.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(req)
    }
}
