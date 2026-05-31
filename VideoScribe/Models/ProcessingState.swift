import Foundation

enum ProcessingState: Equatable {
    case idle
    case loadingModel(progress: Double, message: String)
    case transcribing(elapsed: TimeInterval)
    case scanning(scannedTime: TimeInterval, duration: TimeInterval, kept: Int, elapsed: TimeInterval)
    case rendering(elapsed: TimeInterval)
    case done
    case error(String)
    case cancelled

    var isBusy: Bool {
        switch self {
        case .idle, .done, .error, .cancelled: return false
        default: return true
        }
    }
}

struct AppSettings: Codable, Equatable {
    enum CaptureMode: String, Codable, CaseIterable, Identifiable {
        case sceneDetectionFloor = "scene_floor"
        case fixedInterval = "fixed_interval"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sceneDetectionFloor: return "Scene detection + floor"
            case .fixedInterval: return "Fixed interval"
            }
        }
    }

    enum FrameWidth: Int, Codable, CaseIterable, Identifiable {
        case w720 = 720
        case w1280 = 1280
        case w1920 = 1920
        case native = 0
        var id: Int { rawValue }
        var label: String { self == .native ? "Native" : "\(rawValue)" }
    }

    enum WhisperModel: String, Codable, CaseIterable, Identifiable {
        case base
        case small
        case largeV3 = "large-v3"
        var id: String { rawValue }
        var modelName: String {
            switch self {
            case .base: return "openai_whisper-base"
            case .small: return "openai_whisper-small"
            case .largeV3: return "openai_whisper-large-v3"
            }
        }
        var label: String {
            switch self {
            case .base: return "base"
            case .small: return "small"
            case .largeV3: return "large-v3 (default)"
            }
        }
    }

    enum OutputFormat: String, Codable, CaseIterable, Identifiable {
        case singleHTML = "html"
        case markdownFolder = "md_folder"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .singleHTML: return "Single HTML (default)"
            case .markdownFolder: return "Markdown + folder"
            }
        }
    }

    var captureMode: CaptureMode = .sceneDetectionFloor
    var sceneChangeThreshold: Double = 18.0  // 0..50 MAD on 32x32 grayscale; higher = bigger change required
    var fixedIntervalFloor: Double = 30.0
    var scanStep: Double = 1.0
    var fixedInterval: Double = 5.0
    var frameWidth: FrameWidth = .w1280
    var whisperModel: WhisperModel = .largeV3
    var outputFormat: OutputFormat = .singleHTML
    var jpegQuality: Double = 0.8

    static let storageKey = "VideoScribeSettings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AppSettings.storageKey)
        }
    }
}
