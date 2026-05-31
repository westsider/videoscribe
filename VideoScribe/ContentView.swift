import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit

@MainActor
final class GenerationController: ObservableObject {
    @Published var state: ProcessingState = .idle
    @Published var elapsedDisplay: String = ""
    @Published var lastWarnings: [String] = []

    private var startTime: Date?
    private var elapsedTimer: Timer?
    private var task: Task<Void, Never>?

    func start(videoURL: URL, settings: AppSettings, onFinish: @escaping (Result<URL, Error>) -> Void) {
        cancel()
        lastWarnings = []
        startTime = Date()
        beginElapsedTimer()

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let outURL = try await self.run(videoURL: videoURL, settings: settings)
                await MainActor.run {
                    self.stopElapsedTimer()
                    self.state = .done
                    onFinish(.success(outURL))
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.stopElapsedTimer()
                    self.state = .cancelled
                }
            } catch {
                await MainActor.run {
                    self.stopElapsedTimer()
                    self.state = .error(error.localizedDescription)
                    onFinish(.failure(error))
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        stopElapsedTimer()
        if state.isBusy { state = .cancelled }
    }

    private func beginElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startTime else { return }
                let secs = Int(Date().timeIntervalSince(start))
                self.elapsedDisplay = String(format: "%02d:%02d", secs / 60, secs % 60)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func run(videoURL: URL, settings: AppSettings) async throws -> URL {
        // Validate asset
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durSecs = CMTimeGetSeconds(duration)
        guard durSecs.isFinite, durSecs > 0 else {
            throw NSError(domain: "VideoScribe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read video duration (corrupt or unsupported file?)"])
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        var warnings: [String] = []
        if audioTracks.isEmpty { warnings.append("No audio track found — transcript will be empty.") }
        if videoTracks.isEmpty { warnings.append("No video track found — no screenshots captured.") }
        await MainActor.run { self.lastWarnings = warnings }

        // 1) Transcribe (only if audio present)
        var segments: [TranscriptSegment] = []
        if !audioTracks.isEmpty {
            await MainActor.run {
                self.state = .loadingModel(progress: 0, message: "Preparing transcription model…")
            }
            let transcriber = try await Transcriber(
                model: settings.whisperModel,
                progress: { @Sendable msg, progress in
                    Task { @MainActor in
                        self.state = .loadingModel(progress: progress, message: msg)
                    }
                }
            )
            try Task.checkCancellation()
            await MainActor.run { self.state = .transcribing(elapsed: 0) }
            segments = try await transcriber.transcribe(url: videoURL)
        }

        try Task.checkCancellation()

        // 2) Extract frames (only if video present)
        var frames: [ExtractedFrame] = []
        if !videoTracks.isEmpty {
            let extractor = FrameExtractor(
                asset: asset,
                duration: durSecs,
                settings: settings,
                progress: { @Sendable scanned, total, kept in
                    Task { @MainActor in
                        self.state = .scanning(scannedTime: scanned, duration: total, kept: kept, elapsed: 0)
                    }
                }
            )
            frames = try await extractor.extract()
        }

        try Task.checkCancellation()

        // 3) Build doc
        await MainActor.run { self.state = .rendering(elapsed: 0) }
        let builder = DocumentBuilder(
            sourceURL: videoURL,
            duration: durSecs,
            settings: settings,
            warnings: warnings
        )
        let outURL = try await builder.build(segments: segments, frames: frames)
        return outURL
    }
}

struct ContentView: View {
    @EnvironmentObject var store: SettingsStore
    @StateObject private var controller = GenerationController()
    @State private var videoURL: URL?
    @State private var showImporter = false
    @State private var dropTargeted = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            videoPicker
            intervalRow
            actionRow
            statusArea
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .video, .audiovisualContent],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let u = urls.first { videoURL = u }
            case .failure(let err):
                saveError = err.localizedDescription
            }
        }
        .alert("Error", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("VideoScribe").font(.title).bold()
            Text("Pick a video → set interval → Generate → save HTML.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private var videoPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Video").font(.headline)
            HStack {
                Button {
                    showImporter = true
                } label: {
                    Label("Choose video…", systemImage: "film")
                }
                .disabled(controller.state.isBusy)

                if let videoURL {
                    Text(videoURL.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                } else {
                    Text("…or drag a video file onto this window.")
                        .foregroundStyle(.secondary)
                }
            }
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [6,4]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(height: 80)
                .overlay {
                    Text(dropTargeted ? "Drop to load" : "Drag & drop a .mov / .mp4 / .m4v")
                        .foregroundStyle(.secondary)
                }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    handleDrop(providers: providers)
                }
        }
    }

    @ViewBuilder private var intervalRow: some View {
        if store.settings.captureMode == .fixedInterval {
            HStack {
                Text("Interval:")
                Stepper(value: Binding(
                    get: { store.settings.fixedInterval },
                    set: { store.settings.fixedInterval = max(1, min(60, $0)) }
                ), in: 1...60, step: 1) {
                    Text("\(Int(store.settings.fixedInterval)) s")
                        .frame(width: 50, alignment: .leading)
                }
                .frame(maxWidth: 200)
                Text("(fixed-interval mode)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.secondary)
                Text("Capture mode: Scene detection + floor (\(Int(store.settings.fixedIntervalFloor))s)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                Text("Change in Settings (⌘,)")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
        }
    }

    private var actionRow: some View {
        HStack {
            Button {
                guard let videoURL else { return }
                controller.start(videoURL: videoURL, settings: store.settings) { result in
                    if case .success(let outURL) = result {
                        promptSave(builtFile: outURL, source: videoURL)
                    }
                }
            } label: {
                Label("Generate", systemImage: "play.fill")
                    .frame(minWidth: 100)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(videoURL == nil || controller.state.isBusy)

            if controller.state.isBusy {
                Button("Cancel", role: .destructive) {
                    controller.cancel()
                }
            }
        }
    }

    @ViewBuilder private var statusArea: some View {
        switch controller.state {
        case .idle:
            EmptyView()
        case .loadingModel(let progress, let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.callout)
                if progress > 0 {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
                Text("Elapsed: \(controller.elapsedDisplay)").font(.caption).foregroundStyle(.secondary)
            }
        case .transcribing:
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcribing…").font(.callout)
                ProgressView()
                Text("Elapsed: \(controller.elapsedDisplay)").font(.caption).foregroundStyle(.secondary)
            }
        case .scanning(let scanned, let total, let kept, _):
            VStack(alignment: .leading, spacing: 6) {
                Text("Scanning for slides: \(time(scanned)) / \(time(total)) — \(kept) frames kept")
                    .font(.callout)
                ProgressView(value: total > 0 ? scanned/total : 0)
                Text("Elapsed: \(controller.elapsedDisplay)").font(.caption).foregroundStyle(.secondary)
            }
        case .rendering:
            VStack(alignment: .leading, spacing: 6) {
                Text("Rendering document…").font(.callout)
                ProgressView()
                Text("Elapsed: \(controller.elapsedDisplay)").font(.caption).foregroundStyle(.secondary)
            }
        case .done:
            Label("Done.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cancelled:
            Label("Cancelled.", systemImage: "xmark.circle")
                .foregroundStyle(.orange)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
        }
        if !controller.lastWarnings.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(controller.lastWarnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
    }

    private var footer: some View {
        Text("Runs fully offline after a one-time model download.")
            .foregroundStyle(.tertiary)
            .font(.caption)
    }

    private func time(_ t: TimeInterval) -> String {
        let total = max(t, 0)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                self.videoURL = url
            }
        }
        return true
    }

    private func promptSave(builtFile: URL, source: URL) {
        NSSound.beep()
        let panel = NSSavePanel()
        let baseName = source.deletingPathExtension().lastPathComponent
        let ext = store.settings.outputFormat == .singleHTML ? "html" : "md"
        panel.nameFieldStringValue = "\(baseName).\(ext)"
        panel.allowedContentTypes = store.settings.outputFormat == .singleHTML ? [.html] : [.plainText]
        panel.title = "Save VideoScribe document"
        panel.canCreateDirectories = true

        let response = panel.runModal()
        guard response == .OK, let destURL = panel.url else {
            try? FileManager.default.removeItem(at: builtFile)
            try? FileManager.default.removeItem(at: builtFile.deletingLastPathComponent())
            return
        }

        do {
            if store.settings.outputFormat == .singleHTML {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: builtFile, to: destURL)
            } else {
                // Markdown + folder: builtFile is the .md inside a temp dir alongside frames/
                let tempDir = builtFile.deletingLastPathComponent()
                let framesDir = tempDir.appendingPathComponent("frames", isDirectory: true)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: builtFile, to: destURL)
                let destFrames = destURL.deletingLastPathComponent().appendingPathComponent("frames", isDirectory: true)
                if FileManager.default.fileExists(atPath: destFrames.path) {
                    // Merge: copy contents in
                    let items = (try? FileManager.default.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil)) ?? []
                    for it in items {
                        let dest = destFrames.appendingPathComponent(it.lastPathComponent)
                        if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
                        try FileManager.default.moveItem(at: it, to: dest)
                    }
                    try? FileManager.default.removeItem(at: framesDir)
                } else {
                    try FileManager.default.moveItem(at: framesDir, to: destFrames)
                }
            }
            try? FileManager.default.removeItem(at: builtFile.deletingLastPathComponent())

            let alert = NSAlert()
            alert.messageText = "Saved"
            alert.informativeText = destURL.lastPathComponent
            alert.addButton(withTitle: "Reveal in Finder")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([destURL])
            }
        } catch {
            saveError = "Could not save: \(error.localizedDescription)"
        }
    }
}
