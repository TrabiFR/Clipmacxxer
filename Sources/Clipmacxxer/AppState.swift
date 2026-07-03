import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isRecording = false
    @Published var clips: [Clip] = []
    @Published var showingSettings = false
    @Published var bufferBytes = 0
    @Published var audioBufferBytes = 0
    @Published var statusMessage: String? {
        didSet { scheduleStatusClear() }
    }
    @Published var settings: AppSettings {
        didSet {
            settings.save()
            handleSettingsChange(from: oldValue)
        }
    }

    let engine = CaptureEngine()
    private let hotKeys = HotKeyManager()
    private let playerWindows = PlayerWindowManager()
    private var restartTask: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?

    var clipsBytes: Int { clips.reduce(0) { $0 + $1.byteSize } }
    var unsavedClips: [Clip] { clips.filter { $0.savedURL == nil } }
    var totalBytes: Int { bufferBytes + clipsBytes }
    var memoryCapBytes: Int { settings.memoryCapMB * 1_048_576 }
    var nearCap: Bool { Double(totalBytes) > 0.85 * Double(memoryCapBytes) }

    var estimatedBufferBytes: Int {
        let video = settings.quality.bitrate / 8 * Int(settings.bufferSeconds)
        let audioPerSecond = 384_000 // 48kHz stereo float32 PCM
        let audio = settings.captureSystemAudio ? audioPerSecond * Int(settings.bufferSeconds) : 0
        return video + audio
    }

    init() {
        settings = AppSettings.load()
        engine.onMemoryUpdate = { [weak self] bytes in
            Task { @MainActor in
                guard let self else { return }
                self.bufferBytes = bytes
                self.audioBufferBytes = self.engine.audioBufferedBytes
            }
        }
        engine.onStoppedUnexpectedly = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                if let error {
                    self.statusMessage = "Recording stopped: \(error.localizedDescription)"
                }
            }
        }
        hotKeys.handler = { [weak self] in self?.captureClip() }
        hotKeys.register(settings.hotkey)
        if settings.startOnLaunch {
            startRecording()
        }
    }

    // MARK: - Recording control

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !engine.isRunning else { return }
        statusMessage = nil
        Task {
            do {
                try await engine.start(settings: settings)
                isRecording = true
            } catch {
                isRecording = false
                statusMessage = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        Task {
            await engine.stop()
            isRecording = false
        }
    }

    // MARK: - Clips

    func captureClip() {
        guard let clip = engine.makeClip(length: settings.clipLength) else {
            statusMessage = "Nothing in the buffer yet."
            NSSound.beep()
            return
        }
        var projected = totalBytes + clip.byteSize
        var dropped = 0
        while projected > memoryCapBytes, let victim = evictionIndex() {
            projected -= clips[victim].byteSize
            playerWindows.closeIfOpen(clips[victim].id)
            clips.remove(at: victim)
            dropped += 1
        }
        if projected > memoryCapBytes {
            statusMessage = "Clip too large for the memory cap — raise the cap or lower quality."
            return
        }
        clips.insert(clip, at: 0)
        // Surface the clip list so the new clip is visible even if the
        // settings pane was open.
        showingSettings = false
        if dropped > 0 {
            statusMessage = "Dropped \(dropped) old clip\(dropped == 1 ? "" : "s") to stay under the memory cap."
        }
        NSSound(named: "Pop")?.play()
        if settings.autoSaveClips {
            save(clip)
        }
    }

    /// Evict clips that already exist on disk before touching unsaved ones;
    /// within each group, oldest first (list is sorted newest-first).
    private func evictionIndex() -> Int? {
        clips.lastIndex(where: { $0.savedURL != nil }) ?? clips.indices.last
    }

    func play(_ clip: Clip) {
        playerWindows.open(clip)
    }

    func discard(_ clip: Clip) {
        playerWindows.closeIfOpen(clip.id)
        clips.removeAll { $0.id == clip.id }
    }

    func save(_ clip: Clip) {
        export(clip) { [weak self] url, error in
            guard let self else { return }
            if let error {
                self.statusMessage = "Save failed: \(error.localizedDescription)"
            } else if let url {
                self.statusMessage = "Saved \(url.lastPathComponent)"
            }
        }
    }

    func saveAll() {
        let unsaved = unsavedClips
        guard !unsaved.isEmpty else {
            statusMessage = "All clips are already saved."
            return
        }
        statusMessage = "Saving \(unsaved.count) clip\(unsaved.count == 1 ? "" : "s")…"
        var remaining = unsaved.count
        var failed = 0
        for clip in unsaved {
            export(clip) { [weak self] _, error in
                guard let self else { return }
                if error != nil { failed += 1 }
                remaining -= 1
                if remaining == 0 {
                    self.statusMessage = failed == 0
                        ? "Saved \(unsaved.count) clip\(unsaved.count == 1 ? "" : "s") to \(self.settings.saveFolderPath)"
                        : "Saved \(unsaved.count - failed) of \(unsaved.count) clips — \(failed) failed."
                }
            }
        }
    }

    /// Writes a clip into the save folder with a collision-free filename and
    /// marks it saved. Completion runs on the main actor.
    private func export(_ clip: Clip, completion: @escaping (URL?, Error?) -> Void) {
        let folder = settings.saveFolderURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            completion(nil, error)
            return
        }
        let url = uniqueSaveURL(in: folder, for: clip)
        activeExportURLs.insert(url)
        ClipExporter.export(clip, to: url) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.activeExportURLs.remove(url)
                if error == nil, let index = self.clips.firstIndex(where: { $0.id == clip.id }) {
                    self.clips[index].savedURL = url
                }
                completion(error == nil ? url : nil, error)
            }
        }
    }

    /// Filenames have second resolution, but overlapping clips or a rapid
    /// Save All can target the same name — also check exports in flight.
    private var activeExportURLs: Set<URL> = []

    private func uniqueSaveURL(in folder: URL, for clip: Clip) -> URL {
        let base = "Clip \(Self.fileStamp.string(from: clip.createdAt))"
        let ext = settings.saveFormat.rawValue
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while activeExportURLs.contains(url) || FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return url
    }

    // MARK: - Private

    private func handleSettingsChange(from old: AppSettings) {
        if old.hotkey != settings.hotkey {
            hotKeys.register(settings.hotkey)
        }
        if old.clipLength != settings.clipLength {
            engine.updateBufferDuration(settings.bufferSeconds)
        }
        if !settings.captureConfigEquals(old), engine.isRunning {
            // Debounced so slider drags don't restart the stream repeatedly.
            restartTask?.cancel()
            restartTask = Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                await engine.stop()
                do {
                    try await engine.start(settings: settings)
                    isRecording = true
                } catch {
                    isRecording = false
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func scheduleStatusClear() {
        statusClearTask?.cancel()
        guard statusMessage != nil else { return }
        statusClearTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()
}
