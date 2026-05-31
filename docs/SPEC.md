# VideoScribe — macOS App Spec

A native macOS app that takes a local video file and produces a single,
self-contained document: the timestamped transcript with screenshots inserted
inline at the moments they occurred. The document is meant to be stored as a
reusable resource and later handed to any multimodal LLM for on-demand
extraction (e.g. pulling a trading strategy spec out of a tutorial video).

This is a capture tool, not an interpretation tool. It does NOT analyze, caption,
or interpret the frames — it assembles faithful raw material (audio → text,
video → frames) and defers all interpretation to a downstream LLM. Keep that
separation; do not add any vision/LLM analysis to the capture pipeline.

---

## 1. Platform & stack

- **Target:** macOS 14+ (Sonoma), Apple Silicon. Universal if trivial; AS-first.
- **Language/UI:** Swift, SwiftUI.
- **Transcription:** WhisperKit (https://github.com/argmaxinc/WhisperKit) — pure
  Swift/CoreML, runs on the Neural Engine, no Python or external server. Default
  model `large-v3` with a Settings option to drop to `base`/`small` for speed.
  Download the model on first run if not present; show progress.
- **Frame extraction:** AVFoundation `AVAssetImageGenerator`. No ffmpeg, no
  bundled binaries.
- **No network** except the one-time WhisperKit model download. State this in
  the UI on first run.

---

## 2. Core user flow

1. Launch → single window.
2. User picks a video file (button + drag-and-drop onto the window). Use
   `NSOpenPanel` / SwiftUI `.fileImporter`. Accept common containers:
   mov, mp4, m4v, and whatever `AVAsset` opens.
3. User sets the screenshot interval (default 5s; field accepts 1–60s).
4. User clicks **Generate**.
5. Progress UI runs (see §4).
6. On completion: play a system alert sound (`NSSound.beep()` or a named system
   sound) AND show a save dialog (`NSSavePanel`) asking where to save the
   document. Default filename = source video name + `.html`.
7. After save, show a small "Done — Reveal in Finder" confirmation.

Keep the UI to one window. No tabs, no sidebar. Pick file → set interval →
Generate → progress → save. That is the whole app.

---

## 3. Processing pipeline (on a background queue, never block the UI)

Given a video file and an interval N seconds:

1. **Load asset.** `AVAsset` from the file URL. Read duration. Validate it has
   an audio track (warn if not — transcript will be empty) and a video track
   (warn if not — no frames).

2. **Transcribe.** Extract/decode audio and run WhisperKit. Request
   **word- or segment-level timestamps**. Result: an ordered list of segments,
   each `{ start: TimeInterval, end: TimeInterval, text: String }`.

3. **Extract frames — slide-aware scene detection with a fixed-interval floor.**

   Trading videos are overwhelmingly slide-based presentations, not continuous
   live screencasts. A naive fixed interval (e.g. every 2s) produces ~1000
   near-identical frames for ~20 slides — bloating the document and burying the
   meaningful frames among duplicates. So the default capture mode is scene
   detection, with a fixed-interval floor as backstop.

   Why this is NOT the usual finicky scene-detection problem: a slide change is a
   near-total frame replacement, so the frame-to-frame difference at a transition
   is huge and unambiguous. Almost any threshold separates "same slide" from
   "next slide." The tuning difficulty that plagues scene detection on continuous
   video (drifting charts, forming candles) does not apply to discrete slides.

   No ffmpeg or scene-detection library needed — implement it directly with
   AVFoundation plus a cheap perceptual diff:

   - **Scan step:** walk the video at a coarse step (default 1s) with
     `AVAssetImageGenerator`. For each scanned frame, downscale to a tiny
     thumbnail (e.g. 32×32 grayscale) and compute a simple perceptual signature
     (mean absolute pixel difference vs. the previous thumbnail, or a basic dHash
     and Hamming distance).
   - **Keep on change:** when the difference vs. the last KEPT frame exceeds the
     scene-change threshold (generous default — slide deltas are stark), keep the
     current frame at full resolution. This captures one frame per slide.
   - **Fixed-interval floor:** regardless of change, force-keep a frame every N
     seconds (default 30s). This re-samples a slide that sits on screen a long
     time while the presenter talks/annotates, and guarantees the worst case is
     no worse than plain interval sampling.
   - **De-dupe:** never keep two frames whose signatures are within the threshold
     of each other, so a forced floor frame that's identical to the current slide
     is skipped.
   - For each KEPT frame: seek precisely (`requestedTimeToleranceBefore`/`After`
     = `.zero`), render at `maximumSize` width (default 1280 — readable enough for
     small UI numbers; exposed in Settings as 720 / 1280 / 1920 / native), encode
     JPEG (~0.8 quality).

   **Live-screencast fallback (honest caveat):** if a segment is a continuously
   moving chart, the detector will trip often and collapse toward dense sampling.
   That's acceptable — the floor and de-dupe keep it bounded, and the common case
   (slides) gets the big win. Do not try to special-case this in v1.

   Expose **Capture mode** in Settings: `Scene detection + floor` (default) and
   `Fixed interval` (the simple every-N-seconds mode, for users who want it).

4. **Merge by timestamp.** Build a single timeline ordered by time. Walk the
   transcript segments and frame timestamps together; emit them in chronological
   order so each screenshot lands between the transcript lines that bracket its
   timestamp. Every item carries its `MM:SS` (and ideally `HH:MM:SS` for long
   videos) label.

5. **Render output** (see §5).

---

## 4. Progress UI

Two-phase, both with visible progress — transcription has no easy linear
percentage from WhisperKit, so show an indeterminate spinner with a status label
("Transcribing…"). For frame extraction, the total number of KEPT frames isn't
known up front (scene detection decides as it scans), so show progress against
the *scan* position instead: a determinate bar over video duration
("Scanning for slides: 04:12 / 18:30 — 17 frames kept"). Show elapsed time.
Provide a Cancel button that actually cancels the work (cooperative cancellation
on the background task).

---

## 5. Output document

**Primary format: a single self-contained HTML file.**
- Images embedded as base64 data URIs so the file is fully portable — one file,
  no asset folder, opens in any browser, renders screenshots inline.
- Structure: a header block (source filename, duration, date generated,
  screenshot interval, whisper model used), then the merged chronological
  timeline.
- Each transcript segment: its timestamp label + text.
- Each screenshot: its timestamp label + the image, inline at its chronological
  position.
- Clean, readable, minimal CSS. Monospace timestamps. The frames should display
  at a readable size (max-width 100%, but large enough to read on-screen text).
- Critically, make the HTML easy for a downstream LLM to parse: wrap each entry
  in a semantic tag with its timestamp as a data attribute, e.g.
  `<div class="seg" data-t="125.0">` / `<div class="frame" data-t="125.0">`.

**Secondary format (Settings toggle): Markdown + image folder.**
- A `.md` file with `![t=02:05](frames/frame_00125.jpg)` references and an
  adjacent `frames/` folder. For users who'd rather have editable text + loose
  images. HTML remains the default.

---

## 6. The gap problem — handle it, don't hide it

Scene detection captures one frame per slide, so for slide-based videos the gap
problem is largely moot — a slide that shows a settings panel is captured when it
appears. The residual risk is a value shown *within* one slide's lifetime but not
on the kept frame (e.g. presenter briefly mouses over a tooltip, or annotates a
slide after the initial capture). The fixed-interval floor (every 30s) partly
covers this. The app's job is not to fully solve it but to make any gap visible
to the downstream LLM:

- Because the transcript is independently timestamped, the merged document lets a
  later LLM notice "the narration references a setting at 07:42 but the nearest
  kept frame is the slide captured at 07:10." Don't suppress or smooth this — the
  raw alignment is the feature, and it tells you exactly where to scrub back.
- A smaller floor interval or a lower scene-change threshold reduces the chance
  of missing a briefly-shown panel, at the cost of a larger file. Document this
  in the UI as a small help note.

---

## 7. Settings (a simple sheet or panel)

- **Capture mode** (`Scene detection + floor` [default] / `Fixed interval`).
- **Scene-change threshold** (sensitivity; default tuned generous for slides).
  Label it plainly, e.g. a slider from "Only big changes" → "Subtle changes."
- **Fixed-interval floor** (seconds, default 30) — used in scene-detection mode
  to force periodic re-sampling.
- **Scan step** (seconds, default 1) — how often the detector samples to compare.
- **Interval** (seconds, 1–60, default 5) — used only in `Fixed interval` mode.
- Frame width (720 / 1280 / 1920 / native, default 1280).
- Whisper model (base / small / large-v3, default large-v3).
- Output format (single HTML [default] / Markdown + folder).
- JPEG quality (default 0.8).

Keep advanced knobs (threshold, scan step, floor) in a collapsible "Advanced"
area so the default UI stays simple — most users should only ever touch capture
mode and never need the rest.

---

## 8. Error handling

- No audio track → proceed with frames only, note it in the document header.
- No video track → proceed with transcript only, note it.
- Unsupported/corrupt file → clear dialog, don't crash.
- WhisperKit model download failure → clear dialog with retry.
- Cancellation mid-run → clean up temp files, return to idle.
- Long videos: stream/append rather than holding every frame in memory at once;
  write frames to a temp dir during processing, base64-inline them at render.

---

## 9. Explicit non-goals for v1

- No video playback/preview in-app.
- No editing of the transcript.
- No frame interpretation, OCR, captioning, or LLM calls of any kind.
- No batch/multiple-file processing (one video at a time).
- No cloud anything.
- No *content-aware* frame selection beyond the perceptual-diff scene detection
  described in §3 — i.e. no ML/vision models deciding which frames "matter." The
  detector is a cheap pixel-difference check only.

Keep v1 ruthlessly simple: pick video → (defaults are fine) → generate → save HTML.

---

## 10. Suggested project structure

```
VideoScribe/
├── VideoScribeApp.swift          # @main, single WindowGroup
├── ContentView.swift             # the one window: picker, interval, Generate, progress
├── SettingsView.swift            # settings sheet
├── Models/
│   ├── TimelineItem.swift        # enum: .segment(start,end,text) | .frame(t, imageData)
│   └── ProcessingState.swift     # idle / transcribing / scanning(scannedTime,duration,kept) / done / error
├── Services/
│   ├── Transcriber.swift         # WhisperKit wrapper, async, cancellable
│   ├── FrameExtractor.swift      # AVAssetImageGenerator + perceptual-diff scene detection
│   │                             #   + fixed-interval floor + de-dupe; async, cancellable
│   └── DocumentBuilder.swift     # merge + render HTML / Markdown
└── Resources/
```

Use Swift concurrency (async/await, Task, cooperative cancellation). Keep all
heavy work off the main actor; update progress via the main actor.

---

## 11. Acceptance criteria

- [ ] Pick a local mp4/mov via button and drag-and-drop.
- [ ] Generate runs without blocking the UI; Cancel works.
- [ ] On a slide-based video, scene detection yields roughly one frame per slide
      (not hundreds of near-duplicates); de-dupe prevents repeated identical slides.
- [ ] Fixed-interval floor still re-samples a long-lived slide periodically.
- [ ] `Fixed interval` capture mode also available and works as plain every-N-sec.
- [ ] Produces a single HTML file where screenshots appear inline at the right
      chronological spot between transcript lines, every entry timestamp-labeled.
- [ ] On finish: audible alert + save dialog defaulting to `<videoname>.html`.
- [ ] HTML opens in a browser, renders all frames, and each entry carries a
      `data-t` timestamp attribute for downstream parsing.
- [ ] Runs fully offline after the one-time model download.
