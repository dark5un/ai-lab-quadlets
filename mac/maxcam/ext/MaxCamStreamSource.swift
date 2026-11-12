// MaxCamStreamSource.swift — CMIOExtensionStreamSource delegate + mailbox pump (v0)
// Watches App Group container mailbox/frame.jpg (atomic tmp+rename writes by
// maxaudiod --mailbox) and pushes decoded 640x480 BGRA sample buffers at 30 fps.
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
    static var mailboxURL: URL {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)
        return base?.appendingPathComponent("mailbox/frame.jpg") ?? URL(fileURLWithPath: "/nonexistent")
    }

    var stream: CMIOExtensionStream?
    var timer: DispatchSourceFileSystemObject?
    var fd: Int32 = -1
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
    private func start() {
        guard !running else { return }
        running = true
        mlog.info("mailbox pump starting, watching \(Self.mailboxURL.path)")
        watchMailbox()
    }

    private func stop() { running = false; timer?.cancel(); timer = nil }

    private func watchMailbox() {
        let url = Self.mailboxURL
        fd = open(url.path, O_EVTONLY)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if fd < 0 { // mailbox absent yet; poll dir creation + file
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.watchMailbox() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .userInteractive))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let fflags = src.data
            if fflags.contains(.delete) || fflags.contains(.rename) {
                close(self.fd); self.fd = -1
                self.timer?.cancel(); self.timer = nil
                if self.running { self.watchMailbox() }
                return
            }
            self.emitFrame(url: url)
        }
        src.setCancelHandler { [weak self] in close(self?.fd ?? -1) }
        src.resume()
        timer = src
        emitFrame(url: url) // first frame
    }

    private func emitFrame(url: URL) {
        guard running, let stream else { return }
        guard let data = try? Data(contentsOf: url),
              let img = NSImage(data: data),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
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
