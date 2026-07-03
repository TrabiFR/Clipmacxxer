import Foundation
import AVFoundation

enum ExportError: LocalizedError {
    case noVideo
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo:
            return "This clip has no video data."
        case .writerFailed(let reason):
            return "Could not write the movie file (\(reason))."
        }
    }
}

/// The only place in the app that writes footage to disk, and it only runs
/// from Save / Save All (or auto-save, when that setting is enabled).
/// Video is passed through without re-encoding; PCM audio is encoded to
/// AAC on the way out.
enum ClipExporter {
    static func export(_ clip: Clip, to url: URL, completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try exportSync(clip, to: url)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    private static func exportSync(_ clip: Clip, to url: URL) throws {
        guard let format = clip.videoFormat, let firstVideo = clip.videoSamples.first else {
            throw ExportError.noVideo
        }
        try? FileManager.default.removeItem(at: url)
        let fileType: AVFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ExportError.writerFailed("video input rejected")
        }
        writer.add(videoInput)

        var feeds: [(AVAssetWriterInput, [CMSampleBuffer])] = [(videoInput, clip.videoSamples)]
        if clip.audioSamples.isEmpty {
            NSLog("Clipmacxxer: export has no system audio samples — clip was captured without audio")
        }
        for samples in [clip.audioSamples, clip.micSamples] where !samples.isEmpty {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings(for: samples[0]))
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                feeds.append((input, samples))
            } else {
                NSLog("Clipmacxxer: writer rejected an audio input — exporting without that track")
            }
        }

        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(firstVideo))

        let group = DispatchGroup()
        for (input, samples) in feeds {
            group.enter()
            let queue = DispatchQueue(label: "clipmacxxer.export.feed")
            var index = 0
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard index < samples.count else {
                        finished = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    if !input.append(samples[index]) {
                        NSLog("Clipmacxxer: append failed at sample %d of %d (%@) — %@",
                              index, samples.count, input.mediaType.rawValue,
                              writer.error?.localizedDescription ?? "no writer error")
                        finished = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    index += 1
                }
            }
        }
        group.wait()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        if writer.status != .completed {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }
    }

    private static func aacSettings(for sample: CMSampleBuffer) -> [String: Any] {
        var sampleRate: Double = 48_000
        var channels = 2
        if let desc = CMSampleBufferGetFormatDescription(sample),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            sampleRate = asbd.mSampleRate
            channels = Int(asbd.mChannelsPerFrame)
        }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 192_000
        ]
    }
}
