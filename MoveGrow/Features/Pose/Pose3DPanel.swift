// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// The review screen's 3D tab: the baby figure (BabyFigure.swift) following the video above it, turned
// with a finger, and the 3D data export. It shows the 3D track the analysis wrote (InstantHMR engine).

import SwiftUI

struct Pose3DPanel: View {
    @EnvironmentObject private var store: LocalStore
    let memory: Memory
    @ObservedObject var player: ReviewPlayerModel
    @StateObject private var model = Pose3DModel()
    @State private var yaw = 0.0
    @State private var pitch = 0.0
    @State private var zoom = 1.0

    /// Reload when the analysis writes a new track, or the position (mat or rug) changes.
    private struct LoadKey: Hashable {
        var pose: String?
        var stage: AnalysisStage?
        var context: RecordingContext
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let track = model.shown {
                Pose3DView(player: player, ticker: player.clock, track: track, radius: model.radius, shape: model.shape,
                           floor: model.floor, yaw: $yaw, pitch: $pitch, zoom: $zoom)
                    .frame(height: 240)
                    .overlay(alignment: .bottomTrailing) {
                        if abs(zoom - 1) > 0.05 {
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) { zoom = 1 }
                            } label: {
                                Text(verbatim: String(format: "%.1f×", zoom))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(8)
                            .accessibilityLabel(tr("Reset zoom"))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color.mgCard, in: RoundedRectangle(cornerRadius: 14))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 8) {
                    viewButton(tr("Camera view"), yaw: 0, pitch: 0)
                    viewButton(tr("Side view"), yaw: .pi / 2, pitch: 0)
                    viewButton(tr("Top view"), yaw: 0, pitch: .pi / 2)
                }
                Text(tr("Drag to turn, pinch to zoom; double-tap to return to the camera view."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let raw = model.track { details(raw) }
            } else if model.loaded {
                missing
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: LoadKey(pose: memory.poseStorage, stage: memory.analysisStage, context: memory.context)) {
            await model.load(memoryID: memory.id, context: memory.context)
        }
    }

    private func viewButton(_ title: String, yaw y: Double, pitch p: Double) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) {
                yaw = y
                pitch = p
            }
        } label: {
            Text(title).font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(Color.mgSage)
    }

    private func details(_ t: HMRTrack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                legend(BabyFigure.leftColor, tr("Baby’s left"))
                legend(BabyFigure.rightColor, tr("Baby’s right"))
                Spacer()
                Toggle(tr("Smooth"), isOn: $model.smooth)
                    .fixedSize()
                    .tint(Color.mgSage)
            }
            .font(.caption)
            Text(tr("Mittens and socks show the sides. Joint positions come from the analysis; the body’s shape is drawn for illustration."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(tr("Colours follow the baby’s own sides: when the baby faces the camera, its left is on the right of the screen, as in a mirror."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text(tr("InstantHMR %1$@ · fit: %2$@ · %3$lld fps", HMRModels.displayName(t.header.network),
                    HMRModels.fitLabel(t.header.fitCrops), Int(t.header.requestedFPS.rounded())))
                .font(.footnote.weight(.semibold))
            Text(tr("Person found in %@ of analysed frames", L10n.percent(Double(t.detectedCount) / Double(max(1, t.count)))))
                .font(.footnote)
                .foregroundStyle(.secondary)
            ShareLink(item: HMRJSONExport(memoryID: memory.id), preview: SharePreview(tr("3D pose data (JSON)"))) {
                Label(tr("Export 3D data (JSON)"), systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(Color.mgSage)
        }
        .mgCard(padding: 12)
    }

    /// No 3D track: not analysed yet, being analysed, or analysed in 2D.
    private var missing: some View {
        let waiting = store.analyzing.contains(memory.id) || (memory.poseStorage == nil && memory.analysisError == nil)
        return VStack(alignment: .leading, spacing: 10) {
            if waiting {
                Text(tr("Appears when the analysis is done."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if PoseEngine.current == .instantHMR {
                Text(tr("This video was analysed in 2D. Analyse it again with InstantHMR to see it in 3D."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    player.pause()
                    store.reanalyze(memory.id)
                } label: {
                    Text(tr("Analyse again with InstantHMR"))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.mgSage)
                .disabled(!store.canReanalyze(memory.id))
            } else {
                Text(tr("This video was analysed in 2D. Choose InstantHMR in Settings → Pose engine to analyse videos in 3D."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mgCard(padding: 14)
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title).foregroundStyle(.secondary)
        }
    }
}

/// The baby figure for the frame being shown, turned by `yaw` (about the camera's vertical axis) and
/// `pitch`; redrawn every display frame while playing.
struct Pose3DView: View {
    @ObservedObject var player: ReviewPlayerModel
    @ObservedObject var ticker: PlayerClock
    let track: HMRTrack
    let radius: Float
    let shape: BodyShape
    let floor: BabyFloor?
    @Binding var yaw: Double
    @Binding var pitch: Double
    @Binding var zoom: Double
    @State private var dragStart: CGPoint?
    @State private var startAngles = (yaw: 0.0, pitch: 0.0)
    @State private var startZoom: Double?

    static let zoomRange = 0.6...3.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isPlaying)) { _ in
            let t = player.isPlaying ? player.displayTime : ticker.time
            Canvas { ctx, size in
                guard let i = track.frame(near: t, tolerance: 1.5 / max(1, track.header.requestedFPS)) else {
                    BabyFigure.drawBackground(&ctx, size: size)
                    ctx.draw(Text(tr("No person at this moment")).font(.caption).foregroundStyle(Color.secondary),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                    return
                }
                BabyFigure.draw(&ctx, size: size, track: track, frame: i, radius: radius, shape: shape, floor: floor,
                                yaw: yaw, pitch: pitch, zoom: zoom)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    guard startZoom == nil else { return }               // pinching, not turning
                    if dragStart == nil {
                        dragStart = v.startLocation
                        startAngles = (yaw, pitch)
                    }
                    // The side nearer the viewer follows the finger.
                    yaw = startAngles.yaw - Double(v.translation.width) / 120
                    pitch = min(.pi / 2, max(-.pi / 2, startAngles.pitch + Double(v.translation.height) / 120))
                }
                .onEnded { _ in dragStart = nil }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { v in
                    if startZoom == nil { startZoom = zoom }
                    let z = (startZoom ?? 1) * Double(v.magnification)
                    zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, z))
                }
                .onEnded { _ in
                    startZoom = nil
                    dragStart = nil
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.35)) {
                yaw = 0
                pitch = 0
                zoom = 1
            }
        }
        .accessibilityElement()
        .accessibilityLabel(tr("3D baby figure"))
    }
}
