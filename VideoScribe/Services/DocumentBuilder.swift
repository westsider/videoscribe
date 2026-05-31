import Foundation

final class DocumentBuilder {
    private let sourceURL: URL
    private let duration: TimeInterval
    private let settings: AppSettings
    private let warnings: [String]

    init(sourceURL: URL, duration: TimeInterval, settings: AppSettings, warnings: [String]) {
        self.sourceURL = sourceURL
        self.duration = duration
        self.settings = settings
        self.warnings = warnings
    }

    func build(segments: [TranscriptSegment], frames: [ExtractedFrame]) async throws -> URL {
        switch settings.outputFormat {
        case .singleHTML:
            return try await buildHTML(segments: segments, frames: frames)
        case .markdownFolder:
            return try await buildMarkdown(segments: segments, frames: frames)
        }
    }

    // MARK: - Merge

    private enum Item {
        case segment(TranscriptSegment)
        case frame(ExtractedFrame)

        var time: TimeInterval {
            switch self {
            case .segment(let s): return s.start
            case .frame(let f): return f.t
            }
        }

        // Frames sort just before segments at the same timestamp so the slide
        // shows before the narration for that moment.
        var tiebreak: Int {
            switch self {
            case .frame: return 0
            case .segment: return 1
            }
        }
    }

    private func merged(segments: [TranscriptSegment], frames: [ExtractedFrame]) -> [Item] {
        var items: [Item] = []
        items.reserveCapacity(segments.count + frames.count)
        items.append(contentsOf: segments.map(Item.segment))
        items.append(contentsOf: frames.map(Item.frame))
        items.sort {
            if $0.time == $1.time { return $0.tiebreak < $1.tiebreak }
            return $0.time < $1.time
        }
        return items
    }

    // MARK: - HTML

    private func buildHTML(segments: [TranscriptSegment], frames: [ExtractedFrame]) async throws -> URL {
        let tempDir = try makeTempDir()
        let outURL = tempDir.appendingPathComponent("\(sourceURL.deletingPathExtension().lastPathComponent).html")

        var html = ""
        html.reserveCapacity(1_000_000)
        html += htmlHeader()
        html += htmlMeta(framesCount: frames.count, segmentsCount: segments.count)
        html += "<main>\n"
        for item in merged(segments: segments, frames: frames) {
            try Task.checkCancellation()
            switch item {
            case .segment(let s):
                html += renderSegmentHTML(s)
            case .frame(let f):
                html += renderFrameHTML(f)
            }
        }
        html += "</main>\n"
        html += htmlFooter()

        try html.data(using: .utf8)?.write(to: outURL, options: .atomic)
        return outURL
    }

    private func htmlHeader() -> String {
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>\(esc(sourceURL.lastPathComponent)) — VideoScribe</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 15px/1.55 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; max-width: 820px; margin: 2rem auto; padding: 0 1rem; }
        header { border-bottom: 1px solid #8884; padding-bottom: 1rem; margin-bottom: 1.5rem; }
        h1 { font-size: 1.4rem; margin: 0 0 .25rem; }
        .meta { font-size: 0.85rem; color: #888; }
        .meta dl { display: grid; grid-template-columns: max-content 1fr; gap: .15rem 1rem; margin: .5rem 0 0; }
        .meta dt { color: #999; }
        .warn { background: #fff4cc; color: #6a4a00; padding: .4rem .6rem; border-radius: 6px; margin: .5rem 0; font-size: .85rem; }
        @media (prefers-color-scheme: dark) {
          .warn { background: #4a3a00; color: #ffe89a; }
        }
        .ts { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: #888; font-size: .85rem; margin-right: .5rem; }
        .seg { margin: .35rem 0; }
        .seg .text { display: inline; }
        .frame { margin: 1rem 0; }
        .frame img { max-width: 100%; height: auto; border-radius: 6px; box-shadow: 0 1px 4px #0002; display: block; }
        .frame figcaption { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: #888; font-size: .8rem; margin-top: .25rem; }
        </style>
        </head>
        <body>

        """
    }

    private func htmlMeta(framesCount: Int, segmentsCount: Int) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let captureLabel = settings.captureMode == .sceneDetectionFloor
            ? "Scene detection + floor (\(Int(settings.fixedIntervalFloor))s)"
            : "Fixed interval (\(Int(settings.fixedInterval))s)"
        var warnHTML = ""
        for w in warnings {
            warnHTML += "<div class=\"warn\">⚠ \(esc(w))</div>\n"
        }
        return """
        <header>
          <h1>\(esc(sourceURL.lastPathComponent))</h1>
          <div class="meta">
            <dl>
              <dt>Duration</dt><dd>\(formatDuration(duration))</dd>
              <dt>Generated</dt><dd>\(df.string(from: Date()))</dd>
              <dt>Capture</dt><dd>\(captureLabel)</dd>
              <dt>Whisper model</dt><dd>\(esc(settings.whisperModel.rawValue))</dd>
              <dt>Frames</dt><dd>\(framesCount)</dd>
              <dt>Segments</dt><dd>\(segmentsCount)</dd>
            </dl>
            \(warnHTML)
          </div>
        </header>

        """
    }

    private func htmlFooter() -> String {
        return """

        </body>
        </html>
        """
    }

    private func renderSegmentHTML(_ s: TranscriptSegment) -> String {
        let label = TimestampFormatter.label(s.start, totalDuration: duration)
        let text = esc(s.text)
        return "<div class=\"seg\" data-t=\"\(String(format: "%.2f", s.start))\" data-end=\"\(String(format: "%.2f", s.end))\"><span class=\"ts\">[\(label)]</span><span class=\"text\">\(text)</span></div>\n"
    }

    private func renderFrameHTML(_ f: ExtractedFrame) -> String {
        let label = TimestampFormatter.label(f.t, totalDuration: duration)
        let b64 = f.imageData.base64EncodedString()
        return """
        <figure class="frame" data-t="\(String(format: "%.2f", f.t))">
          <img src="data:image/jpeg;base64,\(b64)" alt="frame at \(label)">
          <figcaption>[\(label)]</figcaption>
        </figure>

        """
    }

    private func esc(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "&", with: "&amp;")
        r = r.replacingOccurrences(of: "<", with: "&lt;")
        r = r.replacingOccurrences(of: ">", with: "&gt;")
        r = r.replacingOccurrences(of: "\"", with: "&quot;")
        return r
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let total = max(Int(t.rounded()), 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        return String(format: "%dm %02ds", m, s)
    }

    // MARK: - Markdown + folder

    private func buildMarkdown(segments: [TranscriptSegment], frames: [ExtractedFrame]) async throws -> URL {
        let tempDir = try makeTempDir()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let mdURL = tempDir.appendingPathComponent("\(baseName).md")
        let framesDir = tempDir.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

        // Write frames first
        var nameByT: [TimeInterval: String] = [:]
        for f in frames {
            try Task.checkCancellation()
            let secs = Int(f.t.rounded())
            let name = String(format: "frame_%06d.jpg", secs)
            nameByT[f.t] = name
            try f.imageData.write(to: framesDir.appendingPathComponent(name), options: .atomic)
        }

        var md = ""
        md += "# \(sourceURL.lastPathComponent)\n\n"
        md += "- **Duration:** \(formatDuration(duration))\n"
        md += "- **Generated:** \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))\n"
        md += "- **Capture:** " + (settings.captureMode == .sceneDetectionFloor
            ? "Scene detection + floor (\(Int(settings.fixedIntervalFloor))s)\n"
            : "Fixed interval (\(Int(settings.fixedInterval))s)\n")
        md += "- **Whisper model:** \(settings.whisperModel.rawValue)\n"
        md += "- **Frames:** \(frames.count)  •  **Segments:** \(segments.count)\n"
        if !warnings.isEmpty {
            md += "\n"
            for w in warnings { md += "> ⚠ \(w)\n" }
        }
        md += "\n---\n\n"

        for item in merged(segments: segments, frames: frames) {
            try Task.checkCancellation()
            switch item {
            case .segment(let s):
                let label = TimestampFormatter.label(s.start, totalDuration: duration)
                md += "`[\(label)]` \(s.text)\n\n"
            case .frame(let f):
                let label = TimestampFormatter.label(f.t, totalDuration: duration)
                let name = nameByT[f.t] ?? "frame_unknown.jpg"
                md += "![t=\(label)](frames/\(name))\n\n"
            }
        }

        try md.data(using: .utf8)?.write(to: mdURL, options: .atomic)
        return mdURL
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoscribe-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
