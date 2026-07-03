import SwiftUI
import AppKit
import AVFoundation

/// Plays a clip directly from its in-RAM sample buffers: video through
/// AVSampleBufferDisplayLayer's renderer, audio through
/// AVSampleBufferAudioRenderer, both driven by one render synchronizer.
/// No temp file is ever written for playback.
final class ClipPlayerModel: ObservableObject {
    enum PlaybackState {
        case playing, paused, ended
    }

    @Published var state: PlaybackState = .paused
    @Published var elapsed: Double = 0

    let clip: Clip
    let displayLayer = AVSampleBufferDisplayLayer()

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var audioRenderers: [AVSampleBufferAudioRenderer] = []
    private var audioSampleSets: [[CMSampleBuffer]] = []
    private let feedQueue = DispatchQueue(label: "clipmacxxer.player.feed")
    private var periodicObserver: Any?
    private var boundaryObserver: Any?
    private var started = false

    init(clip: Clip) {
        self.clip = clip
        displayLayer.videoGravity = .resizeAspect
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        for samples in [clip.audioSamples, clip.micSamples] where !samples.isEmpty {
            let renderer = AVSampleBufferAudioRenderer()
            synchronizer.addRenderer(renderer)
            audioRenderers.append(renderer)
            audioSampleSets.append(samples)
        }
        periodicObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.elapsed = max(0, time.seconds - self.clip.startTime.seconds)
        }
        boundaryObserver = synchronizer.addBoundaryTimeObserver(
            forTimes: [NSValue(time: clip.endTime)],
            queue: .main
        ) { [weak self] in
            self?.synchronizer.rate = 0
            self?.state = .ended
        }
    }

    func play() {
        switch state {
        case .playing:
            return
        case .ended:
            restart()
        case .paused:
            if started {
                synchronizer.rate = 1
            } else {
                started = true
                startFeeding()
                synchronizer.setRate(1, time: clip.startTime)
            }
            state = .playing
        }
    }

    func pause() {
        synchronizer.rate = 0
        state = .paused
    }

    func restart() {
        stopFeedingAndFlush()
        startFeeding()
        synchronizer.setRate(1, time: clip.startTime)
        started = true
        state = .playing
    }

    func teardown() {
        synchronizer.rate = 0
        stopFeedingAndFlush()
        if let periodicObserver {
            synchronizer.removeTimeObserver(periodicObserver)
        }
        if let boundaryObserver {
            synchronizer.removeTimeObserver(boundaryObserver)
        }
        periodicObserver = nil
        boundaryObserver = nil
    }

    private func startFeeding() {
        feed(displayLayer.sampleBufferRenderer, samples: clip.videoSamples)
        for (index, renderer) in audioRenderers.enumerated() {
            feed(renderer, samples: audioSampleSets[index])
        }
    }

    private func feed(_ renderer: any AVQueuedSampleBufferRendering, samples: [CMSampleBuffer]) {
        var index = 0
        renderer.requestMediaDataWhenReady(on: feedQueue) {
            while renderer.isReadyForMoreMediaData {
                guard index < samples.count else {
                    renderer.stopRequestingMediaData()
                    if let audio = renderer as? AVSampleBufferAudioRenderer, audio.status == .failed {
                        NSLog("Clipmacxxer: preview audio renderer failed — %@",
                              audio.error?.localizedDescription ?? "unknown error")
                    }
                    return
                }
                renderer.enqueue(samples[index])
                index += 1
            }
        }
    }

    private func stopFeedingAndFlush() {
        displayLayer.sampleBufferRenderer.stopRequestingMediaData()
        displayLayer.sampleBufferRenderer.flush()
        for renderer in audioRenderers {
            renderer.stopRequestingMediaData()
            renderer.flush()
        }
    }
}

struct ClipPlayerView: View {
    @ObservedObject var model: ClipPlayerModel

    var body: some View {
        VStack(spacing: 0) {
            LayerHostingView(hostedLayer: model.displayLayer)
                .background(Color.black)
                .aspectRatio(CGFloat(model.clip.width) / CGFloat(max(1, model.clip.height)), contentMode: .fit)
            HStack(spacing: 12) {
                Button {
                    model.state == .playing ? model.pause() : model.play()
                } label: {
                    Image(systemName: model.state == .playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                Button {
                    model.restart()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Restart")
                Text("\(Format.mmss(model.elapsed)) / \(Format.mmss(model.clip.duration))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.clip.width)×\(model.clip.height)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
        }
        .frame(minWidth: 420, minHeight: 260)
    }
}

/// Layer-hosting NSView so the AVSampleBufferDisplayLayer can live in SwiftUI.
struct LayerHostingView: NSViewRepresentable {
    let hostedLayer: CALayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.layer = hostedLayer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// One player window per clip; closing a window tears down its renderers.
final class PlayerWindowManager: NSObject, NSWindowDelegate {
    private var entries: [UUID: (window: NSWindow, model: ClipPlayerModel)] = [:]

    func open(_ clip: Clip) {
        if let entry = entries[clip.id] {
            NSApp.activate(ignoringOtherApps: true)
            entry.window.makeKeyAndOrderFront(nil)
            return
        }
        let model = ClipPlayerModel(clip: clip)
        let hosting = NSHostingController(rootView: ClipPlayerView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Clip \(Format.clock(clip.createdAt))"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        let maxWidth: CGFloat = 900
        let scale = min(1, maxWidth / CGFloat(max(1, clip.width)))
        window.setContentSize(NSSize(
            width: CGFloat(clip.width) * scale,
            height: CGFloat(clip.height) * scale + 40
        ))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        entries[clip.id] = (window, model)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.play()
    }

    func closeIfOpen(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.model.teardown()
        entry.window.delegate = nil
        entry.window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = entries.first(where: { $0.value.window == window })?.key,
              let entry = entries.removeValue(forKey: id) else { return }
        entry.model.teardown()
    }
}
