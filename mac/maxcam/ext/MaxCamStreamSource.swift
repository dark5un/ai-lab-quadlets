// MaxCamStreamSource.swift — CMIOExtensionStreamSource delegate + frame pump (v0)
// Feed (owner decision 2026-11-12, P2 option 2): extension dials the door
// itself via FrameClient ('V' JPEG frames over WSS). App Group mailbox via
// maxaudiod --mailbox is the FALLBACK path only. Decodes latest frame into
// 640x480 BGRA and pushes CMSampleBuffers at feed rate.
import Foundation
import CoreMediaIO
import CoreVideo
import CoreMedia
import AppKit
import os

let mlog = Logger(subsystem: "io.onlyascii.maxcam", category: "mailbox")

final class MaxCamDeviceSource: NSObject, CMIOExtensionStreamSourceDelegate {
    // Fill in TEAMID once the Xcode project sets the app group.
    static let groupID = "<TEAMID>.io.onlyascii.maxpresence"

    var stream: CMIOExtensionStream?
    var running = false

    // MARK: format
    func formats(forStream stream: CMIOExtensionStream) -> [CMFormatDescription] {
        var desc: CMFormatDescription?
        let dims = CMVideoDimensions(width: 640, height: 480)
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: Self.blankPixelBuffer(),
            formatDescriptionOut: &desc) ?? { _ = dims; return () }()
        _ = desc
        // Robust path: build a plain video format description:
        var vd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_32BGRA,
                                       width: 640, height: 480,
                                       extensions: nil,
                                       formatDescriptionOut: &vd)
        return [vd].compactMap { $0 }
    }

    static func blankPixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 640, 480,
                            kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    func setStreamProperties(_ properties: CMIOExtensionStreamProperties,
                             for stream: CMIOExtensionStream) throws {
        self.stream = stream
    }

    func authorizedToStartStream(_ stream: CMIOExtensionStream) async throws {
        start()
    }

    func startStream(_ stream: CMIOExtensionStream) { start() }
    func stopStream(_ stream: CMIOExtensionStream) { stop() }

    // MARK: pump
    private var client: FrameClient?
    private var latest: Data?
    private var pump: DispatchSourceTimer?

    private func start() {
        guard !running else { return }
        running = true
        let c = FrameClient { [weak self] jpeg in self?.latest = jpeg }
        c.start()
        client = c
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        t.setEventHandler { [weak self] in self?.emitFrame() }
        t.resume()
        pump = t
        mlog.info("frame pump starting (WSS video leg)")
    }

    private func stop() {
        running = false
        pump?.cancel(); pump = nil
        client?.stop(); client = nil
    }

    private func emitFrame() {
        guard running, let stream, let data = latest,
              let img = NSImage(data: data),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        latest = nil // consume (no stale re-emit)
        let pb = Self.blankPixelBuffer()
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                  width: 640, height: 480,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 640, height: 480))

        var varDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pb,
                                                     formatDescriptionOut: &varDesc)
        let pts = CMTime(value: CMTimeValue(Date().timeIntervalSince1970 * 1e6), timescale: 1_000_000)
        var sb: CMSampleBuffer?
        let info = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                      presentationTimeStamp: pts,
                                      decodeTimeStamp: .invalid)
        let st = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                    imageBuffer: pb,
                                                    dataReady: true,
                                                    makeDataReadyCallback: nil,
                                                    refcon: nil,
                                                    formatDescription: varDesc!,
                                                    sampleTiming: &info,
                                                    sampleBufferOut: &sb)
        if st == noErr, let sb {
            stream.send(sb, discontinuity: false, hostTimeInNanoseconds: UInt64(Date().timeIntervalSince1970 * 1e9))
        }
    }
}
