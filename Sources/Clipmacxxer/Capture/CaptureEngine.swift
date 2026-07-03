import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreImage
import AppKit

enum CaptureError: LocalizedError {
    case noPermission
    case noDisplay
    case encoderInit(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "Screen Recording permission is required. Grant it to Clipmacxxer in System Settings → Privacy & Security → Screen & System Audio Recording, then press Start again."
        case .noDisplay:
            return "No display found to capture."
        case .encoderInit(let status):
            return "Could not start the video encoder (error \(status))."
        }
    }
}

/// Owns the ScreenCaptureKit stream and feeds the rolling buffer:
/// screen frames → hardware H.264 → RAM ring; audio stays as PCM in the ring.
final class CaptureEngine: NSObject, SCStreamDelegate, SCStreamOutput {
    private let buffer = RollingBuffer()
    private var stream: SCStream?
    private var encoder: VideoEncoder?
    private let videoQueue = DispatchQueue(label: "clipmacxxer.capture.video")
    private let audioQueue = DispatchQueue(label: "clipmacxxer.capture.audio")

    // Accessed on videoQueue only.
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastFrameAt: CFAbsoluteTime = 0
    private var lastThumbnailAt: CFAbsoluteTime = 0
    private var heartbeat: DispatchSourceTimer?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private let thumbnailLock = NSLock()
    private var _latestThumbnailJPEG: Data?
    var latestThumbnailJPEG: Data? {
        thumbnailLock.withLock { _latestThumbnailJPEG }
    }

    private var lastMemoryPush: CFAbsoluteTime = 0

    private(set) var outputSize = CGSize(width: 1920, height: 1080)

    /// Both callbacks are invoked on the main queue.
    var onMemoryUpdate: ((Int) -> Void)?
    var onStoppedUnexpectedly: ((Error?) -> Void)?

    var isRunning: Bool { stream != nil }
    var bufferedBytes: Int { buffer.totalBytes }
    var audioBufferedBytes: Int { buffer.bufferedAudioBytes }

    // Accessed on audioQueue only.
    private var loggedFirstAudioSample = false

    func updateBufferDuration(_ seconds: Double) {
        buffer.maxDuration = seconds
    }

    func start(settings: AppSettings) async throws {
        guard stream == nil else { return }

        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            throw CaptureError.noPermission
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        // Keep our own popover/windows out of the recording.
        let ownApps = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier && !$0.bundleIdentifier.isEmpty
        }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = CGFloat(filter.pointPixelScale)
        var pixelSize = CGSize(
            width: filter.contentRect.width * scale,
            height: filter.contentRect.height * scale
        )
        if let maxHeight = settings.quality.maxHeight, pixelSize.height > CGFloat(maxHeight) {
            let factor = CGFloat(maxHeight) / pixelSize.height
            pixelSize = CGSize(width: pixelSize.width * factor, height: CGFloat(maxHeight))
        }
        let width = max(2, Int(pixelSize.width.rounded()) & ~1)
        let height = max(2, Int(pixelSize.height.rounded()) & ~1)
        outputSize = CGSize(width: width, height: height)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 8
        if settings.captureSystemAudio {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }
        var micEnabled = false
        if settings.captureMicrophone, #available(macOS 15.0, *) {
            if await AVCaptureDevice.requestAccess(for: .audio) {
                config.captureMicrophone = true
                micEnabled = true
            }
        }

        let encoder = try VideoEncoder(
            width: width,
            height: height,
            bitrate: settings.quality.bitrate,
            frameRate: settings.frameRate
        )
        encoder.onEncodedFrame = { [weak self] sample, isKeyframe in
            guard let self else { return }
            self.buffer.appendVideo(sample, isKeyframe: isKeyframe)
            self.pushMemoryUpdateThrottled()
        }
        buffer.clear()
        buffer.maxDuration = settings.bufferSeconds
        self.encoder = encoder

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if settings.captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if micEnabled, #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        }
        audioQueue.sync { loggedFirstAudioSample = false }
        try await stream.startCapture()
        self.stream = stream
        NSLog("Clipmacxxer: capture started — systemAudio=%@ mic=%@ %dx%d@%dfps",
              settings.captureSystemAudio ? "on" : "off",
              micEnabled ? "on" : "off", width, height, settings.frameRate)
        startHeartbeat()
    }

    func stop() async {
        heartbeat?.cancel()
        heartbeat = nil
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        encoder?.invalidate()
        encoder = nil
        videoQueue.sync { self.lastPixelBuffer = nil }
    }

    /// Non-destructive: the rolling buffer keeps going, so pressing the
    /// hotkey twice in a minute yields two (overlapping) clips.
    func makeClip(length: Double) -> Clip? {
        guard let snap = buffer.snapshot(last: length) else { return nil }
        let thumbnail = latestThumbnailJPEG.flatMap { NSImage(data: $0) }
        return Clip(
            duration: snap.duration,
            startTime: snap.start,
            videoSamples: snap.video,
            audioSamples: snap.audio,
            micSamples: snap.mic,
            videoFormat: snap.format,
            byteSize: snap.bytes,
            thumbnail: thumbnail,
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            handleScreenSample(sampleBuffer)
        case .audio:
            if !loggedFirstAudioSample {
                loggedFirstAudioSample = true
                let format = CMSampleBufferGetFormatDescription(sampleBuffer)
                    .map { String(describing: $0) } ?? "no format description"
                NSLog("Clipmacxxer: first system audio sample arrived — %@", format)
            }
            guard let copy = Self.retainableCopy(of: sampleBuffer) else { return }
            buffer.appendAudio(copy, isMic: false)
            pushMemoryUpdateThrottled()
        default:
            if #available(macOS 15.0, *), type == .microphone {
                guard let copy = Self.retainableCopy(of: sampleBuffer) else { return }
                buffer.appendAudio(copy, isMic: true)
                pushMemoryUpdateThrottled()
            }
        }
    }

    /// ScreenCaptureKit recycles the sample buffers it delivers from a small
    /// internal pool (queueDepth). Retaining them in the ring starves that
    /// pool and audio delivery silently stops after the first few buffers —
    /// video survives only because frames are re-encoded into app-owned
    /// buffers immediately. Copy the PCM into our own memory instead.
    ///
    /// SCK also delivers *planar* (non-interleaved) float PCM, which
    /// AVSampleBufferAudioRenderer won't render (the file exporter only copes
    /// because its AAC converter accepts planar input) — so the copy also
    /// interleaves into standard packed float that every consumer accepts.
    private static func retainableCopy(of sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let srcASBD = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            return nil
        }
        let frames = CMSampleBufferGetNumSamples(sample)
        let channels = max(1, Int(srcASBD.mChannelsPerFrame))
        let isFloat32 = srcASBD.mFormatID == kAudioFormatLinearPCM
            && srcASBD.mBitsPerChannel == 32
            && (srcASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard isFloat32, frames > 0 else { return genericCopy(of: sample) }

        let ablPointer = AudioBufferList.allocate(maximumBuffers: channels)
        defer { free(ablPointer.unsafeMutablePointer) }
        var retainedBlock: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPointer.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channels),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &retainedBlock
        ) == noErr else { return genericCopy(of: sample) }

        let abl = UnsafeMutableAudioBufferListPointer(ablPointer.unsafeMutablePointer)
        var interleaved = [Float](repeating: 0, count: frames * channels)
        if abl.count == 1, let data = abl[0].mData {
            // Single buffer means the data is already interleaved (or mono).
            memcpy(&interleaved, data,
                   min(Int(abl[0].mDataByteSize), interleaved.count * MemoryLayout<Float>.size))
        } else {
            for (channel, buffer) in abl.enumerated() {
                guard let data = buffer.mData else { continue }
                let plane = data.assumingMemoryBound(to: Float.self)
                let planeFrames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                for frame in 0..<planeFrames {
                    interleaved[frame * channels + channel] = plane[frame]
                }
            }
        }
        withExtendedLifetime(retainedBlock) {}

        var asbd = AudioStreamBasicDescription(
            mSampleRate: srcASBD.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var interleavedFormatOut: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &interleavedFormatOut
        ) == noErr, let interleavedFormat = interleavedFormatOut else { return nil }

        let dataLength = frames * channels * MemoryLayout<Float>.size
        var blockOut: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockOut
        ) == kCMBlockBufferNoErr, let block = blockOut,
        interleaved.withUnsafeBytes({ bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: dataLength
            ) == kCMBlockBufferNoErr
        }) else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            decodeTimeStamp: .invalid
        )
        var sampleSize = channels * MemoryLayout<Float>.size
        var copyOut: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: interleavedFormat,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &copyOut
        )
        return status == noErr ? copyOut : nil
    }

    /// Fallback for non-float formats: byte-for-byte deep copy without
    /// changing the layout.
    private static func genericCopy(of sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let srcBlock = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(srcBlock)

        var dstBlockOut: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &dstBlockOut
        ) == kCMBlockBufferNoErr, let dstBlock = dstBlockOut else { return nil }

        var lengthAtOffset = 0
        var totalLength = 0
        var dstPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            dstBlock, atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dstPointer
        ) == kCMBlockBufferNoErr, let dst = dstPointer,
        CMBlockBufferCopyDataBytes(srcBlock, atOffset: 0, dataLength: length, destination: dst) == kCMBlockBufferNoErr
        else { return nil }

        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return nil }

        var copyOut: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: dstBlock,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: CMSampleBufferGetFormatDescription(sample),
            sampleCount: CMSampleBufferGetNumSamples(sample),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &copyOut
        )
        return status == noErr ? copyOut : nil
    }

    private func handleScreenSample(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lastPixelBuffer = pixelBuffer
        lastFrameAt = CFAbsoluteTimeGetCurrent()
        encoder?.encode(pixelBuffer, presentationTime: pts)
        makeThumbnailIfDue(pixelBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heartbeat?.cancel()
            self.heartbeat = nil
            self.stream = nil
            self.encoder?.invalidate()
            self.encoder = nil
            self.onStoppedUnexpectedly?(error)
        }
    }

    // MARK: - Private

    /// ScreenCaptureKit only delivers frames when the screen changes. Re-encode
    /// the last frame at 1 fps during static periods so the buffer timeline
    /// never has holes and a clip is always available.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let pixelBuffer = self.lastPixelBuffer else { return }
            if CFAbsoluteTimeGetCurrent() - self.lastFrameAt > 1.1 {
                let pts = CMClockGetTime(CMClockGetHostTimeClock())
                self.encoder?.encode(pixelBuffer, presentationTime: pts)
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private func makeThumbnailIfDue(_ pixelBuffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastThumbnailAt >= 1.0 else { return }
        lastThumbnailAt = now
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let targetWidth: CGFloat = 320
        guard image.extent.width > 0 else { return }
        let s = targetWidth / image.extent.width
        image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        if let data = ciContext.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB()) {
            thumbnailLock.withLock { _latestThumbnailJPEG = data }
        }
    }

    private func pushMemoryUpdateThrottled() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastMemoryPush >= 0.5 else { return }
        lastMemoryPush = now
        let bytes = buffer.totalBytes
        DispatchQueue.main.async { [weak self] in
            self?.onMemoryUpdate?(bytes)
        }
    }
}
