import AppKit
import CoreMedia

/// A captured clip held entirely in RAM: compressed H.264 video samples plus
/// raw PCM audio samples. Only ClipExporter ever turns one into a file.
struct Clip: Identifiable {
    let id = UUID()
    let createdAt = Date()
    let duration: Double
    let startTime: CMTime
    let videoSamples: [CMSampleBuffer]
    let audioSamples: [CMSampleBuffer]
    let micSamples: [CMSampleBuffer]
    let videoFormat: CMFormatDescription?
    let byteSize: Int
    let thumbnail: NSImage?
    let width: Int
    let height: Int
    var savedURL: URL?

    var endTime: CMTime {
        CMTimeAdd(startTime, CMTime(seconds: duration, preferredTimescale: 600))
    }
}
