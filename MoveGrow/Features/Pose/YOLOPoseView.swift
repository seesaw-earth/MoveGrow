// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// ⋯ → YOLO pose: the 2D skeleton of YOLO26l-pose over the video, on request only. With the InstantHMR
// engine these are the keypoints of YOLO26l-pose, which finds the baby for InstantHMR in every frame
// (recorded with the 3D track; not used in the analysis). For a video analysed with the YOLO engine,
// they are its analysis keypoints.

import SwiftUI

struct YOLOPoseView: View {
    @EnvironmentObject private var store: LocalStore
    @Environment(\.dismiss) private var dismiss

    let memoryID: UUID
    let aspect: Double

    @StateObject private var player: ReviewPlayerModel
    @State private var track: PoseTrack?
    @State private var loaded = false

    init(memory: Memory) {
        memoryID = memory.id
        let a = memory.aspectRatio ?? 9.0 / 16.0
        aspect = a > 0.1 ? a : 9.0 / 16.0
        _player = StateObject(wrappedValue: ReviewPlayerModel(url: LocalFiles.url(memory.filename), duration: memory.duration))
    }

    private var memory: Memory? { store.memory(memoryID) }
    private var busy: Bool { store.analyzing.contains(memoryID) }
    private var instantHMR: Bool { PoseEngine.isInstantHMR(memory?.poseEstimator) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    PlayerLayerView(player: player.player)
                    SkeletonOverlay(player: player, ticker: player.clock, track: track)
                    PausedGlyph(player: player)
                }
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 420)
                .background(Color.black)
                .contentShape(Rectangle())
                .onTapGesture { player.toggle() }
                .accessibilityHint(tr("Tap to play or pause"))
                PoseScrubber(player: player, ticker: player.clock)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black)
                ScrollView {
                    note
                        .padding(16)
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                }
            }
            .background(Color.mgPaper)
            .navigationTitle(tr("YOLO pose"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Done")) { dismiss() }
                }
            }
        }
        .task(id: memory?.poseStorage) { await load() }
        .onDisappear { player.pause() }
    }

    @ViewBuilder private var note: some View {
        VStack(alignment: .leading, spacing: 10) {
            if track != nil {
                Text(instantHMR
                     ? tr("YOLO26l-pose finds the baby for InstantHMR in every frame. These are its own 2D keypoints, for comparison; the analysis uses InstantHMR.")
                     : tr("This video was analysed in 2D with YOLO; these are its keypoints."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if busy {
                AnalysisProgressLine(memoryID: memoryID, monitor: store.monitor)
                Text(tr("This video is being analysed. YOLO’s keypoints appear when it is done."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if loaded {
                Text(tr("YOLO’s keypoints are recorded from this version on. Analyse this video again to see them."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if memory?.poseStorage != nil {
                    Button {
                        player.pause()
                        store.reanalyze(memoryID)
                    } label: {
                        Text(tr("Analyse again"))
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.mgSage)
                    .disabled(!store.canReanalyze(memoryID))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mgCard(padding: 12)
    }

    @MainActor private func load() async {
        guard let m = memory, m.poseStorage != nil else {
            track = nil
            loaded = true
            return
        }
        if PoseEngine.isInstantHMR(m.poseEstimator) {
            let id = memoryID
            track = await Task.detached(priority: .userInitiated) { HMRTrack.load(memoryID: id)?.yoloTrack() }.value
        } else {
            track = await store.poseTrack(for: memoryID)
        }
        loaded = true
    }
}

// MARK: - Progress

/// This video's analysis phase, percentage and time left.
private struct AnalysisProgressLine: View {
    let memoryID: UUID
    @ObservedObject var monitor: AnalysisMonitor

    var body: some View {
        let p = monitor.progress[memoryID]
        let f = max(0, min(1, p?.fraction ?? 0))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(p?.title ?? tr("Analysing")).font(.subheadline.weight(.semibold))
                Spacer()
                Text([L10n.percent((f * 100).rounded(.down) / 100), p?.etaText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: f).tint(Color.mgSage)
        }
    }
}

// MARK: - Scrubber

private struct PoseScrubber: View {
    @ObservedObject var player: ReviewPlayerModel
    @ObservedObject var ticker: PlayerClock

    var body: some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel(player.isPlaying ? tr("Pause") : tr("Play"))
            Slider(value: Binding(get: { min(ticker.time, player.duration) },
                                  set: { player.seek($0, precise: false) }),
                   in: 0...max(0.1, player.duration))
                .tint(Color.mgSkeleton)
            Text(verbatim: Self.clock(ticker.time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    static func clock(_ t: Double) -> String {
        let s = Int(max(0, t).rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
