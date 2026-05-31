# VideoScribe

A native macOS app that turns a local video into a single self-contained HTML
document: timestamped transcript with screenshots inserted inline at the
moments they occurred.

It's a capture tool, not an interpretation tool — it does *not* analyze,
caption, or interpret frames. It assembles faithful raw material (audio → text,
video → frames at slide-change points) and defers all interpretation to a
downstream multimodal LLM.

The use case it's tuned for: tutorial / slide-based videos (e.g. "explain me a
trading strategy from this 30-minute talk"). The output is a portable HTML
file you keep around and hand to an LLM later, on demand.

## Features

- **Fully offline after a one-time model download.** No API keys. No cloud.
- **WhisperKit** (Argmax Open-Source SDK) runs transcription on the Neural
  Engine via CoreML.
- **Slide-aware scene detection** for frame capture: one frame per slide
  instead of hundreds of near-duplicates. A fixed-interval floor backstops
  long-lived slides; a perceptual-diff de-dupe prevents repeats.
- **Single HTML output** with base64-embedded images — one file, no asset
  folder, opens in any browser. Every entry carries a `data-t="seconds"`
  attribute so a downstream LLM can locate the moment exactly.
- Markdown + folder mode also available.
- Drag-and-drop or file picker. Real Cancel. Progress for both phases.

## Requirements

- macOS 14 (Sonoma) or newer, Apple Silicon.
- Xcode 15+ to build from source.
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
  to regenerate the Xcode project from `project.yml`.

## Build & run

```bash
# 1. Generate the Xcode project from project.yml
xcodegen generate

# 2. Build a Release .app
xcodebuild -project VideoScribe.xcodeproj -scheme VideoScribe \
           -configuration Release -destination 'platform=macOS' \
           -derivedDataPath .build build

# 3. (Optional) Install to /Applications
ditto .build/Build/Products/Release/VideoScribe.app /Applications/VideoScribe.app
```

Or just open `VideoScribe.xcodeproj` in Xcode and hit Run.

On first launch, picking a video kicks off a one-time download of the chosen
Whisper model from Hugging Face (cached at `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`).
Default model is `large-v3` (~1.5 GB). Drop to `small` or `base` in Settings
(`⌘,`) if you want faster turnaround or a smaller download.

## How frame selection works

For slide-based videos a naive every-N-second capture produces hundreds of
near-identical frames, burying the meaningful ones. VideoScribe instead:

1. **Scans** the video at a coarse step (default 1 s) at low resolution.
2. For each scanned frame, computes a small perceptual signature (32×32
   grayscale).
3. **Keeps** a frame at full resolution when its signature differs enough from
   the last kept frame (scene change).
4. Also force-keeps a frame every N seconds (default 30 s) to re-sample a slide
   that sits on screen a long time, with de-dupe to skip exact repeats.

This collapses to roughly one frame per slide for a tutorial, while staying
bounded for live screencast segments. Knobs (sensitivity, floor, scan step)
live in Settings under "Advanced."

## Output format

A single HTML file with:

- Header metadata: source filename, duration, generation date, capture mode,
  Whisper model, frame and segment counts.
- Chronologically merged transcript and frames.
- Each transcript segment: `<div class="seg" data-t="125.0" data-end="128.4">`.
- Each frame: `<figure class="frame" data-t="125.0"><img src="data:image/jpeg;base64,..."></figure>`.

The `data-t` attributes make it trivial for an LLM to locate any moment when
extracting information.

## Project layout

```
VideoScribe/
├── project.yml                 # xcodegen config — source of truth
├── VideoScribe.xcodeproj/      # generated; gitignored
└── VideoScribe/
    ├── VideoScribeApp.swift
    ├── ContentView.swift
    ├── SettingsView.swift
    ├── Models/
    │   ├── TimelineItem.swift
    │   └── ProcessingState.swift  # also defines AppSettings
    └── Services/
        ├── Transcriber.swift      # WhisperKit wrapper, async, cancellable
        ├── FrameExtractor.swift   # scene detection + floor
        └── DocumentBuilder.swift  # merge + render HTML / Markdown
```

The design rationale is in [`docs/SPEC.md`](docs/SPEC.md).

## License

MIT — see [LICENSE](LICENSE).

VideoScribe depends on [argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift)
(formerly WhisperKit), Apache-2.0.
