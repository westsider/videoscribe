import Foundation
import AVFoundation
import WhisperKit

struct TranscriptSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

final class Transcriber {
    typealias StatusCallback = @Sendable (String, Double) -> Void

    private let pipe: WhisperKit

    init(model: AppSettings.WhisperModel, progress: StatusCallback) async throws {
        progress("Preparing model \(model.label) — first run downloads from Hugging Face…", 0)
        let config = WhisperKitConfig(
            model: model.modelName,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        self.pipe = try await WhisperKit(config)
        progress("Model ready.", 1.0)
    }

    func transcribe(url videoURL: URL) async throws -> [TranscriptSegment] {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoscribe-audio-\(UUID().uuidString).m4a")
        try await Self.extractAudio(from: videoURL, to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        try Task.checkCancellation()

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            withoutTimestamps: false,
            wordTimestamps: false
        )

        let results: [TranscriptionResult] = try await pipe.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options
        )

        var segments: [TranscriptSegment] = []
        for r in results {
            for s in r.segments {
                let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(
                    start: TimeInterval(s.start),
                    end: TimeInterval(s.end),
                    text: text
                ))
            }
        }
        return segments.sorted { $0.start < $1.start }
    }

    private static func extractAudio(from videoURL: URL, to outURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(
                domain: "VideoScribe.Transcriber",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Could not create audio exporter for this file."]
            )
        }
        export.outputURL = outURL
        export.outputFileType = .m4a
        try? FileManager.default.removeItem(at: outURL)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                if let err = export.error {
                    cont.resume(throwing: err)
                } else if export.status == .completed {
                    cont.resume(returning: ())
                } else {
                    cont.resume(throwing: NSError(
                        domain: "VideoScribe.Transcriber",
                        code: 11,
                        userInfo: [NSLocalizedDescriptionKey: "Audio extraction failed (status \(export.status.rawValue))."]
                    ))
                }
            }
        }
    }
}
