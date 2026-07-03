import SwiftUI
import AppKit

struct SettingsPane: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Clip") {
                    HStack {
                        Text("Length")
                        Slider(value: $app.settings.clipLength, in: 5...120, step: 5)
                        Text("\(Int(app.settings.clipLength)) s")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                    LabeledContent("Hotkey") {
                        HotkeyRecorder(hotkey: $app.settings.hotkey)
                    }
                    Picker("Save format", selection: $app.settings.saveFormat) {
                        ForEach(SaveFormat.allCases) { format in
                            Text(format.rawValue.uppercased()).tag(format)
                        }
                    }
                    LabeledContent("Save folder") {
                        Button {
                            chooseFolder()
                        } label: {
                            Text(app.settings.saveFolderPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 200)
                        }
                    }
                    Toggle("Auto-save clips when captured", isOn: $app.settings.autoSaveClips)
                    Text("Off by default: clips stay in RAM until you press Save or Save All.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                section("Capture") {
                    Picker("Quality", selection: $app.settings.quality) {
                        ForEach(QualityPreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    Picker("Frame rate", selection: $app.settings.frameRate) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    Toggle("System audio", isOn: $app.settings.captureSystemAudio)
                    if #available(macOS 15.0, *) {
                        Toggle("Microphone", isOn: $app.settings.captureMicrophone)
                    }
                    Toggle("Start buffering at launch", isOn: $app.settings.startOnLaunch)
                    Text("Quality, frame rate, and audio changes briefly restart the recorder.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                section("Memory") {
                    Picker("Cap", selection: $app.settings.memoryCapMB) {
                        Text("512 MB").tag(512)
                        Text("1 GB").tag(1024)
                        Text("2 GB").tag(2048)
                    }
                    Text("Rolling buffer ≈ \(Format.bytes(app.estimatedBufferBytes)) at current settings. The oldest clips are dropped when the cap is reached.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = app.settings.saveFolderURL
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            app.settings.saveFolderPath = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
