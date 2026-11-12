// MaxCamProvider.swift — Xcode-27 Camera Extension template shape
// (verified against the shipped template: CMIOExtensionProviderSource /
// DeviceSource / StreamSource classes; Info.plist carries CMIOExtension.
// CMIOExtensionMachServiceName = $(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)).
// The template's white-stripe generator is replaced by the WSS 'V' frame feed.
import Foundation
import CoreMediaIO
import CoreVideo
import CoreMedia
import ImageIO
import IOKit.audio
import os

let kFrameRate = 30
let kWidth = 640, kHeight = 480
let clog = Logger(subsystem: "io.onlyascii.maxcam", category: "provider")

// MARK: - Stream source
final class MaxCamStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat,
         device: CMIOExtensionDevice) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                          direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [_streamFormat] }
    var activeFormatIndex: Int = 0 { didSet { if activeFormatIndex >= 1 { clog.error("invalid index") } } }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate)) }
        return p
    }
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let i = streamProperties.activeFormatIndex { activeFormatIndex = i }
    }
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    func startStream() throws { (device.source as? MaxCamDeviceSource)?.startStreaming() }
    func stopStream() throws { (device.source as? MaxCamDeviceSource)?.stopStreaming() }
}

// MARK: - Device source (owns the frame pump + FrameClient)
final class MaxCamDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var _streamSource: MaxCamStreamSource!
    private var _streamingCounter: UInt32 = 0
    private var _timer: DispatchSourceTimer?
    private let _timerQueue = DispatchQueue(label: "timerQueue", qos: .userInteractive,
        attributes: [], autoreleaseFrequency: .workItem, target: .global(qos: .userInteractive))
    private var _videoDescription: CMFormatDescription!
    private var _bufferPool: CVPixelBufferPool!
    private var _bufferAuxAttributes: NSDictionary!

    // frame mailbox from FrameClient (network thread -> pump thread)
    private let frameLock = NSLock()
    private var latestJPEG: Data?
    private var client: FrameClient?

    init(localizedName: String) {
        super.init()
        // STABLE device UUID (AVFoundation uniqueIdentifier) — do not randomize:
        // P3 scripts/config pin consumers to it.
        let deviceID = UUID(uuidString: "6A55E5C7-4A5B-4B2E-9F3D-7C2A1B0E9D41")!
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID,
                                     legacyDeviceID: nil, source: self)
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA, width: Int32(kWidth), height: Int32(kHeight),
            extensions: nil, formatDescriptionOut: &_videoDescription)
        let attrs: NSDictionary = [
            kCVPixelBufferWidthKey: kWidth, kCVPixelBufferHeightKey: kHeight,
            kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &_bufferPool)
        _bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]
        let fmt = CMIOExtensionStreamFormat(formatDescription: _videoDescription,
            maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), validFrameDurations: nil)
        let videoID = UUID(uuidString: "B7C2A1E0-9D4F-4A11-8E77-3C5D0E1A2B3C")!
        _streamSource = MaxCamStreamSource(localizedName: "MAX Video", streamID: videoID,
                                           streamFormat: fmt, device: device)
        do { try device.addStream(_streamSource.stream) }
        catch { fatalError("Failed to add stream: \(error)") }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = "MAX Presence Camera" }
        return p
    }
    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: pump lifecycle
    func startStreaming() {
        _streamingCounter += 1
        if client == nil {
            let c = FrameClient { [weak self] jpeg in
                self?.frameLock.lock(); self?.latestJPEG = jpeg; self?.frameLock.unlock()
            }
            c.start()
            client = c
        }
        guard _timer == nil, let _ = _bufferPool else { return }
        _timer = DispatchSource.makeTimerSource(flags: .strict, queue: _timerQueue)
        _timer!.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate), leeway: .seconds(0))
        _timer!.setEventHandler { [weak self] in self?.emitFrame() }
        _timer!.resume()
    }

    func stopStreaming() {
        if _streamingCounter > 1 { _streamingCounter -= 1 } else {
            _streamingCounter = 0
            _timer?.cancel(); _timer = nil
            client?.stop(); client = nil
        }
    }

    private func emitFrame() {
        frameLock.lock(); let jpeg = latestJPEG; frameLock.unlock()
        guard let jpeg, let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        var pixelBuffer: CVPixelBuffer?
        let err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, _bufferPool, _bufferAuxAttributes, &pixelBuffer)
        guard err == 0, let pb = pixelBuffer else { clog.error("out of pixel buffers \(err)"); return }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                            width: kWidth, height: kHeight, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: kWidth, height: kHeight))
        CVPixelBufferUnlockBaseAddress(pb, [])
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(kFrameRate)),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
              dataReady: true, makeDataReadyCallback: nil, refcon: nil,
              formatDescription: _videoDescription, sampleTiming: &timing,
              sampleBufferOut: &sbuf) == noErr, let sbuf else { return }
        _streamSource.stream.send(sbuf, discontinuity: [],
            hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
    }
}

// MARK: - Provider source
final class MaxCamProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: MaxCamDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = MaxCamDeviceSource(localizedName: "MAX Camera")
        do { try provider.addDevice(deviceSource.device) }
        catch { fatalError("Failed to add device: \(error)") }
    }
    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "OnlyASCII" }
        return p
    }
    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
