// MaxCamProvider.swift — Camera Extension entry (v0 skeleton, macOS 12.3+ CMIO API)
// Replace the Xcode template's provider file with this. Names match the
// template's pattern (CMIOExtensionMain / provider creation).
import Foundation
import CoreMediaIO
import os

let log = Logger(subsystem: "io.onlyascii.maxcam", category: "provider")

// The template-generated main entry typically is:
//   CMIOExtensionMain()  — with Info.plist NSExtension keys present.
// startService is the documented provider bootstrap.
class MaxCamProvider: NSObject, CMIOExtensionProviderSourceDelegate {
    let provider: CMIOExtensionProvider = CMIOExtensionProvider()
    let source = MaxCamDeviceSource()
    var device: CMIOExtensionDevice!

    func start() {
        provider.source.delegate = self
        device = CMIOExtensionDevice(localizedName: "MAX Camera",
                                     deviceID: "io.onlyascii.maxcam.v1",
                                     modelUID: "io.onlyascii.maxcam.model",
                                     manufacturer: "OnlyASCII",
                                     provider: provider,
                                         transport: .virtual)
        let stream = CMIOExtensionStream(localizedName: "MAX Video",
                                         streamID: 1,
                                         direction: .source,
                                         clockType: .hostTime,
                                         minFrameDuration: CMTime(value: 1, timescale: 30),
                                         maxFrameDuration: CMTime(value: 1, timescale: 10),
                                         dimensions: CMVideoDimensions(width: 640, height: 480),
                                         source: source)
        device.streams = [stream]
        provider.devices = [device]
        log.info("provider registered: MAX Camera 640x480@30")
        // mailbox pump starts when the stream is authorized (see source)
    }
}

func CMIOExtensionMainStart() {
    let p = MaxCamProvider()
    CMIOExtensionProvider.startService(provider: p.provider)
    p.start()
    dispatchMain()
}
CMIOExtensionMainStart()
