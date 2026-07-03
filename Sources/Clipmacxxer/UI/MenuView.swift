import SwiftUI
import AppKit

struct MenuView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(12)
            Divider()
            if app.showingSettings {
                SettingsPane()
                    .frame(height: 470)
            } else {
                clipsPane
            }
            Divider()
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: 440)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(app.isRecording ? Color.red : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text("Clipmacxxer")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                app.captureClip()
            } label: {
                Image(systemName: "scissors")
            }
            .help("Clip the last \(Int(app.settings.clipLength)) s (\(app.settings.hotkey.display))")
            Button {
                app.saveAll()
            } label: {
                Image(systemName: "square.and.arrow.down.on.square")
            }
            .help("Save all unsaved clips to \(app.settings.saveFolderPath)")
            .disabled(app.unsavedClips.isEmpty)
            Button {
                app.showingSettings.toggle()
            } label: {
                Image(systemName: app.showingSettings ? "list.and.film" : "gearshape")
            }
            .help(app.showingSettings ? "Show clips" : "Settings")
            Button(app.isRecording ? "Stop" : "Start") {
                app.toggleRecording()
            }
        }
    }

    /// Shows whether system audio is actually flowing, so a silent capture
    /// is visible while recording instead of only after playback.
    private var statusText: String {
        guard app.isRecording else { return "Not recording" }
        var text = "Buffering the last \(Int(app.settings.clipLength)) s"
        if app.settings.captureSystemAudio {
            text += app.audioBufferBytes > 0 ? " • audio ✓" : " • no audio yet"
        }
        return text
    }

    @ViewBuilder
    private var clipsPane: some View {
        if app.clips.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "film.stack")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("No clips yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(app.settings.autoSaveClips
                     ? "Press \(app.settings.hotkey.display) to save the last \(Int(app.settings.clipLength)) seconds to \(app.settings.saveFolderPath)."
                     : "Press \(app.settings.hotkey.display) to keep the last \(Int(app.settings.clipLength)) seconds in RAM.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 170)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(app.clips) { clip in
                        ClipRow(clip: clip)
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
            .frame(maxHeight: 380)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let message = app.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 3) {
                HStack {
                    Text("Memory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Format.bytes(app.totalBytes)) / \(Format.bytes(app.memoryCapBytes))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(app.nearCap ? Color.orange : Color.secondary)
                }
                ProgressView(value: min(1, Double(app.totalBytes) / Double(app.memoryCapBytes)))
                    .tint(app.nearCap ? Color.orange : Color.accentColor)
            }
            HStack {
                if !app.clips.isEmpty {
                    let unsaved = app.unsavedClips.count
                    Text("\(app.clips.count) clip\(app.clips.count == 1 ? "" : "s")"
                         + (unsaved > 0 ? " • \(unsaved) unsaved" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    (NSApp.delegate as? AppDelegate)?.showMainWindow()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .help("Open as a window")
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }
}

struct ClipRow: View {
    @EnvironmentObject var app: AppState
    let clip: Clip

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(Format.clock(clip.createdAt))
                        .font(.callout.weight(.medium))
                    if clip.savedURL != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .help("Saved to disk")
                    }
                }
                Text("\(Format.seconds(clip.duration)) • \(Format.bytes(clip.byteSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 2) {
                iconButton("play.fill", help: "Play") { app.play(clip) }
                if let url = clip.savedURL {
                    iconButton("folder", help: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } else {
                    iconButton("square.and.arrow.down", help: "Save to \(app.settings.saveFolderPath)") { app.save(clip) }
                }
                iconButton("trash", help: "Discard") { app.discard(clip) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var thumbnail: some View {
        Group {
            if let image = clip.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
