import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: SettingsStore
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section("Capture") {
                Picker("Capture mode", selection: $store.settings.captureMode) {
                    ForEach(AppSettings.CaptureMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if store.settings.captureMode == .sceneDetectionFloor {
                    Slider(
                        value: $store.settings.sceneChangeThreshold,
                        in: 4...40,
                        step: 1
                    ) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Text("Subtle").font(.caption)
                    } maximumValueLabel: {
                        Text("Big").font(.caption)
                    }
                    HStack {
                        Text("Fixed-interval floor")
                        Spacer()
                        Stepper(value: $store.settings.fixedIntervalFloor, in: 5...600, step: 5) {
                            Text("\(Int(store.settings.fixedIntervalFloor)) s")
                        }
                    }
                    Text("A smaller floor or higher sensitivity reduces the chance of missing a briefly-shown panel, at the cost of a larger file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Interval")
                        Spacer()
                        Stepper(value: $store.settings.fixedInterval, in: 1...60, step: 1) {
                            Text("\(Int(store.settings.fixedInterval)) s")
                        }
                    }
                }
            }

            Section("Output") {
                Picker("Frame width", selection: $store.settings.frameWidth) {
                    ForEach(AppSettings.FrameWidth.allCases) { w in
                        Text(w.label).tag(w)
                    }
                }
                Picker("Whisper model", selection: $store.settings.whisperModel) {
                    ForEach(AppSettings.WhisperModel.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                Picker("Output format", selection: $store.settings.outputFormat) {
                    ForEach(AppSettings.OutputFormat.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                HStack {
                    Text("JPEG quality")
                    Slider(value: $store.settings.jpegQuality, in: 0.3...1.0)
                    Text(String(format: "%.2f", store.settings.jpegQuality)).monospacedDigit()
                }
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    if store.settings.captureMode == .sceneDetectionFloor {
                        HStack {
                            Text("Scan step")
                            Spacer()
                            Stepper(value: $store.settings.scanStep, in: 0.25...10, step: 0.25) {
                                Text(String(format: "%.2f s", store.settings.scanStep))
                            }
                        }
                        Text("How often the detector samples the video to compare for changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Scene-change threshold")
                        Spacer()
                        Stepper(value: $store.settings.sceneChangeThreshold, in: 1...60, step: 1) {
                            Text(String(format: "%.0f", store.settings.sceneChangeThreshold))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }
}
