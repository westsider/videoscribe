import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ExtractedFrame: Sendable {
    let t: TimeInterval
    let imageData: Data  // JPEG
}

final class FrameExtractor {
    typealias ProgressCallback = @Sendable (TimeInterval, TimeInterval, Int) -> Void

    private let asset: AVAsset
    private let duration: TimeInterval
    private let settings: AppSettings
    private let progress: ProgressCallback

    init(asset: AVAsset, duration: TimeInterval, settings: AppSettings, progress: @escaping ProgressCallback) {
        self.asset = asset
        self.duration = duration
        self.settings = settings
        self.progress = progress
    }

    func extract() async throws -> [ExtractedFrame] {
        switch settings.captureMode {
        case .fixedInterval:    return try await extractFixedInterval()
        case .sceneDetectionFloor: return try await extractSceneDetection()
        }
    }

    // MARK: - Fixed interval

    private func extractFixedInterval() async throws -> [ExtractedFrame] {
        let interval = max(1.0, settings.fixedInterval)
        var out: [ExtractedFrame] = []
        var t: TimeInterval = 0
        while t < duration {
            try Task.checkCancellation()
            let time = CMTime(seconds: t, preferredTimescale: 600)
            do {
                let frame = try await renderOne(at: time)
                out.append(frame)
            } catch is CancellationError { throw CancellationError() }
              catch { /* skip unreadable frame */ }
            progress(t, duration, out.count)
            t += interval
        }
        return out
    }

    // MARK: - Scene detection + floor

    private func extractSceneDetection() async throws -> [ExtractedFrame] {
        let step = max(0.25, settings.scanStep)
        let floor = max(1.0, settings.fixedIntervalFloor)
        let threshold = settings.sceneChangeThreshold
        let dedupeThreshold = max(2.0, threshold * 0.2)  // floor-keep dedupe is more permissive

        let scanGen = AVAssetImageGenerator(asset: asset)
        scanGen.appliesPreferredTrackTransform = true
        scanGen.requestedTimeToleranceBefore = .zero
        scanGen.requestedTimeToleranceAfter = .zero
        scanGen.maximumSize = CGSize(width: 96, height: 96)

        var kept: [ExtractedFrame] = []
        var lastKeptSignature: [UInt8]? = nil
        var lastKeptTime: TimeInterval = -.infinity

        var t: TimeInterval = 0
        var firstFrameRendered = false

        while t < duration {
            try Task.checkCancellation()
            let time = CMTime(seconds: t, preferredTimescale: 600)

            let scanImage: CGImage
            do {
                scanImage = try await getCGImage(generator: scanGen, time: time)
            } catch is CancellationError { throw CancellationError() }
              catch {
                progress(t, duration, kept.count)
                t += step
                continue
            }
            let signature = computeSignature(from: scanImage)

            var shouldKeep = false
            if !firstFrameRendered {
                shouldKeep = true
            } else if let last = lastKeptSignature {
                let diff = mad(last, signature)
                if diff >= threshold {
                    shouldKeep = true
                } else if (t - lastKeptTime) >= floor, diff >= dedupeThreshold {
                    // floor-keep, but de-dupe if essentially identical
                    shouldKeep = true
                }
            }

            if shouldKeep {
                do {
                    let frame = try await renderOne(at: time)
                    kept.append(frame)
                    lastKeptSignature = signature
                    lastKeptTime = t
                    firstFrameRendered = true
                } catch is CancellationError { throw CancellationError() }
                  catch { /* couldn't render full-res — keep scanning */ }
            }

            progress(t, duration, kept.count)
            t += step
        }

        return kept
    }

    // MARK: - Helpers

    private func renderOne(at time: CMTime) async throws -> ExtractedFrame {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        if settings.frameWidth != .native {
            let w = CGFloat(settings.frameWidth.rawValue)
            gen.maximumSize = CGSize(width: w, height: w * 4)  // height generous; aspect preserved
        }
        let cg = try await getCGImage(generator: gen, time: time)
        let data = try jpeg(from: cg, quality: settings.jpegQuality)
        return ExtractedFrame(t: CMTimeGetSeconds(time), imageData: data)
    }

    private func getCGImage(generator: AVAssetImageGenerator, time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let image else {
                    cont.resume(throwing: NSError(
                        domain: "VideoScribe.FrameExtractor",
                        code: 20,
                        userInfo: [NSLocalizedDescriptionKey: "Couldn't decode frame at \(CMTimeGetSeconds(time))s."]
                    ))
                    return
                }
                cont.resume(returning: image)
            }
        }
    }

    private func computeSignature(from cgImage: CGImage) -> [UInt8] {
        let w = 32, h = 32
        var data = [UInt8](repeating: 0, count: w * h)
        data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            let colorSpace = CGColorSpaceCreateDeviceGray()
            guard let ctx = CGContext(
                data: base,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }

    private func mad(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var sum: Int = 0
        for i in 0..<n {
            sum += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(sum) / Double(n)
    }

    private func jpeg(from cgImage: CGImage, quality: Double) throws -> Data {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "VideoScribe.FrameExtractor", code: 21, userInfo: [NSLocalizedDescriptionKey: "Could not create JPEG destination."])
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "VideoScribe.FrameExtractor", code: 22, userInfo: [NSLocalizedDescriptionKey: "JPEG encoding failed."])
        }
        return mutableData as Data
    }
}
