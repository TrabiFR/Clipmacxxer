import Foundation
import Carbon.HIToolbox

struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String
}

enum QualityPreset: String, Codable, CaseIterable, Identifiable {
    case low, medium, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "Low (720p)"
        case .medium: return "Medium (1080p)"
        case .high: return "High (native)"
        }
    }

    /// Output is downscaled so its height does not exceed this. nil = native.
    var maxHeight: Int? {
        switch self {
        case .low: return 720
        case .medium: return 1080
        case .high: return nil
        }
    }

    var bitrate: Int {
        switch self {
        case .low: return 2_500_000
        case .medium: return 5_000_000
        case .high: return 10_000_000
        }
    }
}

enum SaveFormat: String, Codable, CaseIterable, Identifiable {
    case mov, mp4
    var id: String { rawValue }
}

struct AppSettings: Codable, Equatable {
    var clipLength: Double = 30
    var quality: QualityPreset = .medium
    var frameRate: Int = 30
    var captureSystemAudio: Bool = true
    var captureMicrophone: Bool = false
    var startOnLaunch: Bool = true
    var memoryCapMB: Int = 1024
    var saveFormat: SaveFormat = .mov
    var autoSaveClips: Bool = false
    var saveFolderPath: String = "~/Downloads"
    var hotkey = Hotkey(
        keyCode: UInt32(kVK_ANSI_9),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        display: "⇧⌘9"
    )

    init() {}

    enum CodingKeys: String, CodingKey {
        case clipLength, quality, frameRate, captureSystemAudio, captureMicrophone,
             startOnLaunch, memoryCapMB, saveFormat, autoSaveClips, saveFolderPath, hotkey
    }

    // decodeIfPresent everywhere so settings saved by older builds keep
    // working when new fields are added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        clipLength = try container.decodeIfPresent(Double.self, forKey: .clipLength) ?? defaults.clipLength
        quality = try container.decodeIfPresent(QualityPreset.self, forKey: .quality) ?? defaults.quality
        frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate) ?? defaults.frameRate
        captureSystemAudio = try container.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? defaults.captureSystemAudio
        captureMicrophone = try container.decodeIfPresent(Bool.self, forKey: .captureMicrophone) ?? defaults.captureMicrophone
        startOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .startOnLaunch) ?? defaults.startOnLaunch
        memoryCapMB = try container.decodeIfPresent(Int.self, forKey: .memoryCapMB) ?? defaults.memoryCapMB
        saveFormat = try container.decodeIfPresent(SaveFormat.self, forKey: .saveFormat) ?? defaults.saveFormat
        autoSaveClips = try container.decodeIfPresent(Bool.self, forKey: .autoSaveClips) ?? defaults.autoSaveClips
        saveFolderPath = try container.decodeIfPresent(String.self, forKey: .saveFolderPath) ?? defaults.saveFolderPath
        hotkey = try container.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? defaults.hotkey
    }

    var saveFolderURL: URL {
        URL(fileURLWithPath: (saveFolderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The rolling buffer keeps a little more than one clip length so a
    /// clip can always start on a keyframe at or before the requested window.
    var bufferSeconds: Double { clipLength + 5 }

    /// True when a change requires tearing down and restarting the SCStream/encoder.
    func captureConfigEquals(_ other: AppSettings) -> Bool {
        quality == other.quality
            && frameRate == other.frameRate
            && captureSystemAudio == other.captureSystemAudio
            && captureMicrophone == other.captureMicrophone
    }

    static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "settings"),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            defaults.set(true, forKey: "didResetAutoSaveDefault")
            return AppSettings()
        }
        // Old builds defaulted auto-save to on, so existing stored settings
        // have it enabled without the user ever choosing it. Reset it once
        // so auto-save is opt-in from here on.
        if !defaults.bool(forKey: "didResetAutoSaveDefault") {
            settings.autoSaveClips = false
            defaults.set(true, forKey: "didResetAutoSaveDefault")
            settings.save()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "settings")
        }
    }
}
