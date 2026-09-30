// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import AVKit

struct SkeletonClipSheet: View {
    @Environment(\.dismiss) private var dismiss
    let memory: Memory
    let videoURL: URL
    let poseURL: URL

    @State private var mode = "Random"
    @State private var start = 0.0
    @State private var samples: [MotionSample] = []
    @State private var renderedURL: URL?
    @State private var rendering = false
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var videoAspect: CGFloat = 9.0 / 16.0

    private var clipDuration: Double { min(10, memory.duration) }
    private var maximumStart: Double { max(0, memory.duration - clipDuration) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Skeleton preview").font(.title2.bold())
                        Text("Choose a 10-second section. MoveGrow will draw the keypoint skeleton over a private local copy of the clip.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    Picker("Choose clip", selection: $mode) {
                        Text("Random 10s").tag("Random")
                        Text("Pick 10s").tag("Manual")
                    }.pickerStyle(.segmented)

                    if mode == "Random" {
                        Button {
                            chooseRandomStart()
                        } label: {
                            Label("Choose another random section", systemImage: "shuffle")
                        }.buttonStyle(.bordered)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Start").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(clock(start))–\(clock(start + clipDuration))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Slider(value: $start, in: 0...max(0.001, maximumStart))
                                .disabled(maximumStart <= 0)
                        }
                    }

                    VStack(alignment:.leading, spacing:4) {
                        Label("Selected: \(clock(start))–\(clock(start + clipDuration))", systemImage: "scissors")
                        Text("Skeleton coverage: \(Int(selectedCoverage * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.subheadline)

                    Button {
                        Task { await makePreview() }
                    } label: {
                        if rendering { ProgressView().frame(maxWidth: .infinity) }
                        else { Label("Generate skeleton preview", systemImage: "figure.child").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading || rendering || samples.isEmpty)

                    if let renderedURL {
                        VideoPlayer(player: AVPlayer(url: renderedURL))
                            .aspectRatio(videoAspect, contentMode: .fit)
                            .frame(maxHeight: 370)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        ShareLink(item: renderedURL) {
                            Label("Save or share skeleton clip", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Full-video keypoints").font(.headline)
                        Text("The JSON contains every sampled frame, timestamp, x/y coordinate, confidence, lighting flag, joint names and skeleton connections.")
                            .font(.caption).foregroundStyle(.secondary)
                        ShareLink(item: poseURL) {
                            Label("Export full pose JSON", systemImage: "square.and.arrow.up")
                        }.buttonStyle(.bordered)
                    }

                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                }.padding()
            }
            .navigationTitle("Skeleton")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                await loadVideoAspect()
                await loadPoseData()
            }
            .onChange(of: mode) { _, newValue in
                if newValue == "Random" { chooseRandomStart() }
                renderedURL = nil
            }
            .onChange(of: start) { _, _ in renderedURL = nil }
            .onDisappear {
                if let renderedURL { try? FileManager.default.removeItem(at: renderedURL) }
            }
        }
    }

    private var selectedCoverage: Double { coverage(start: start) }

    private func coverage(start: Double) -> Double {
        let end = start + clipDuration
        let window = samples.filter { $0.time >= start && $0.time <= end }
        guard !window.isEmpty else { return 0 }
        let good = window.filter { sample in
            guard sample.lightOK else { return false }
            return sample.points.values.filter { $0.confidence >= MovementEngine.minimumConfidence }.count >= 8
        }.count
        return Double(good) / Double(window.count)
    }

    private func chooseRandomStart() {
        guard maximumStart > 0, !samples.isEmpty else { start = 0;renderedURL = nil;return }
        let candidateCount = max(2, Int(maximumStart.rounded(.down)) + 1)
        let candidates = (0..<candidateCount).map { min(maximumStart, Double($0)) }
        let usable = candidates.filter { coverage(start:$0) >= 0.30 }
        start = (usable.randomElement() ?? candidates.randomElement()) ?? 0
        renderedURL = nil
    }

    @MainActor private func loadVideoAspect() async {
        let asset = AVURLAsset(url: videoURL)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return }
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let width = abs(bounds.width)
        let height = abs(bounds.height)
        if width > 1, height > 1 {
            videoAspect = width / height
        }
    }

    @MainActor private func loadPoseData() async {
        loading = true
        defer { loading = false }
        do {
            let url = poseURL
            samples = try await Task.detached(priority: .utility) {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let archive = try? decoder.decode(PoseArchive.self, from: data) { return archive.frames }
                return try JSONDecoder().decode([MotionSample].self, from: data) // v4.0.2 compatibility
            }.value
            chooseRandomStart()
        } catch {
            errorMessage = "Keypoints could not be opened. \(error.localizedDescription)"
        }
    }

    @MainActor private func makePreview() async {
        rendering = true
        errorMessage = nil
        if let old = renderedURL { try? FileManager.default.removeItem(at: old); renderedURL = nil }
        do {
            renderedURL = try await SkeletonClipRenderer.render(videoURL: videoURL, samples: samples, start: start, duration: clipDuration)
        } catch {
            errorMessage = error.localizedDescription
        }
        rendering = false
    }
}
