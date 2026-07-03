import Foundation
import CoreMedia

/// Thread-safe rolling window of encoded video and raw audio sample buffers.
/// Everything lives in RAM as CMSampleBuffers; nothing here ever touches disk.
final class RollingBuffer {
    struct Entry {
        let sample: CMSampleBuffer
        let seconds: Double
        let isKeyframe: Bool
        let bytes: Int
    }

    struct Snapshot {
        let video: [CMSampleBuffer]
        let audio: [CMSampleBuffer]
        let mic: [CMSampleBuffer]
        let start: CMTime
        let duration: Double
        let bytes: Int
        let format: CMFormatDescription?
    }

    private let lock = NSLock()
    private var video: [Entry] = []
    private var audio: [Entry] = []
    private var mic: [Entry] = []
    private var videoBytes = 0
    private var audioBytes = 0
    private var micBytes = 0
    private var _maxDuration: Double = 35

    var maxDuration: Double {
        get { lock.withLock { _maxDuration } }
        set {
            lock.withLock {
                _maxDuration = newValue
                trimLocked()
            }
        }
    }

    var totalBytes: Int {
        lock.withLock { videoBytes + audioBytes + micBytes }
    }

    /// System-audio bytes currently buffered — used by the UI to show whether
    /// audio is actually flowing while recording.
    var bufferedAudioBytes: Int {
        lock.withLock { audioBytes }
    }

    func clear() {
        lock.withLock {
            video = []; audio = []; mic = []
            videoBytes = 0; audioBytes = 0; micBytes = 0
        }
    }

    func appendVideo(_ sample: CMSampleBuffer, isKeyframe: Bool) {
        let entry = Entry(
            sample: sample,
            seconds: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
            isKeyframe: isKeyframe,
            bytes: CMSampleBufferGetTotalSampleSize(sample)
        )
        lock.withLock {
            video.append(entry)
            videoBytes += entry.bytes
            trimLocked()
        }
    }

    func appendAudio(_ sample: CMSampleBuffer, isMic: Bool) {
        // Audio buffers are deep copies without a per-sample size table, so
        // CMSampleBufferGetTotalSampleSize would report 0 — measure the raw
        // PCM block instead.
        let bytes = CMSampleBufferGetDataBuffer(sample).map { CMBlockBufferGetDataLength($0) }
            ?? CMSampleBufferGetTotalSampleSize(sample)
        let entry = Entry(
            sample: sample,
            seconds: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
            isKeyframe: false,
            bytes: bytes
        )
        lock.withLock {
            if isMic {
                mic.append(entry)
                micBytes += entry.bytes
            } else {
                audio.append(entry)
                audioBytes += entry.bytes
            }
        }
    }

    /// Copies out the last `length` seconds. The slice always starts on a
    /// keyframe so it is independently decodable. Non-destructive: the buffer
    /// keeps rolling, so multiple overlapping clips are possible.
    func snapshot(last length: Double) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let newest = video.last else { return nil }
        let cutoff = newest.seconds - length
        guard let startIndex = video.lastIndex(where: { $0.isKeyframe && $0.seconds <= cutoff })
                ?? video.firstIndex(where: { $0.isKeyframe }) else { return nil }

        let videoSlice = video[startIndex...]
        guard let first = videoSlice.first else { return nil }
        let startSeconds = first.seconds
        let audioSlice = audio.drop(while: { $0.seconds < startSeconds - 0.1 })
        let micSlice = mic.drop(while: { $0.seconds < startSeconds - 0.1 })

        let bytes = videoSlice.reduce(0) { $0 + $1.bytes }
            + audioSlice.reduce(0) { $0 + $1.bytes }
            + micSlice.reduce(0) { $0 + $1.bytes }

        return Snapshot(
            video: videoSlice.map(\.sample),
            audio: audioSlice.map(\.sample),
            mic: micSlice.map(\.sample),
            start: CMSampleBufferGetPresentationTimeStamp(first.sample),
            duration: max(0.1, newest.seconds - startSeconds),
            bytes: bytes,
            format: CMSampleBufferGetFormatDescription(first.sample)
        )
    }

    private func trimLocked() {
        guard let newest = video.last else { return }
        let cutoff = newest.seconds - _maxDuration
        // Drop whole GOPs: keep the last keyframe at or before the cutoff so
        // the window always starts on a decodable frame.
        if let keyframeIndex = video.lastIndex(where: { $0.isKeyframe && $0.seconds <= cutoff }),
           keyframeIndex > 0 {
            for entry in video[0..<keyframeIndex] { videoBytes -= entry.bytes }
            video.removeSubrange(0..<keyframeIndex)
        }
        let audioCutoff = (video.first?.seconds ?? cutoff) - 0.2
        trimAudioLocked(&audio, bytes: &audioBytes, before: audioCutoff)
        trimAudioLocked(&mic, bytes: &micBytes, before: audioCutoff)
    }

    private func trimAudioLocked(_ entries: inout [Entry], bytes: inout Int, before cutoff: Double) {
        guard let firstKept = entries.firstIndex(where: { $0.seconds >= cutoff }) else {
            if !entries.isEmpty, entries[entries.count - 1].seconds < cutoff {
                bytes = 0
                entries.removeAll()
            }
            return
        }
        guard firstKept > 0 else { return }
        for entry in entries[0..<firstKept] { bytes -= entry.bytes }
        entries.removeSubrange(0..<firstKept)
    }
}
