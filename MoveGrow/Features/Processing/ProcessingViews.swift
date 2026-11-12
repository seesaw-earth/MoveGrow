// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Processing is a ring: progress and time left. Shown as a floating pill above the album
// (Liquid Glass on iOS 26), as a larger ring when the pill is tapped, and on iOS 26 as the
// system Live Activity of the continued background task (BackgroundWork).

import SwiftUI

extension View {
    /// Liquid Glass on iOS 26, a material elsewhere.
    @ViewBuilder func mgGlass<S: Shape>(_ shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
        #else
        self.background(.regularMaterial, in: shape)
        #endif
    }
}

// MARK: - Pill

struct ProcessingPill: View {
    @ObservedObject var monitor: AnalysisMonitor
    @ObservedObject var importer: BatchImporter
    var open: () -> Void
    @State private var hiddenBatch: [UUID]?

    var body: some View {
        let batch = monitor.batch
        let importing = importer.isImporting
        let visible = importing || (batch.map { !($0.isComplete && hiddenBatch == $0.ids) } ?? false)
        Group {
            if visible {
                Button(action: open) {
                    HStack(spacing: 10) {
                        if let batch, batch.isComplete, !importing {
                            Text(batch.total == 1 ? tr("Video ready") : tr("%lld videos ready", batch.total))
                                .font(.subheadline.weight(.semibold))
                        } else {
                            StatRing(value: importing ? importer.fraction : (batch?.fraction ?? 0), size: 26)
                            Text(text(batch)).font(.subheadline.weight(.semibold).monospacedDigit())
                                .contentTransition(.numericText())
                        }
                    }
                    .foregroundStyle(Color.mgInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .mgGlass(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityLabel(accessibility(batch))
            }
        }
        .animation(.spring(duration: 0.35), value: visible)
        .task(id: batch?.isComplete == true && !importing) {
            // A finished batch stays visible for a moment, then gets out of the way.
            guard let batch, batch.isComplete, !importing else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { hiddenBatch = batch.ids }
        }
    }

    private func text(_ batch: BatchProgress?) -> String {
        if let s = importer.state, !s.finished { return "\(min(s.done + 1, s.total))/\(s.total)" }
        return batch?.shortText ?? ""
    }

    private func accessibility(_ batch: BatchProgress?) -> String {
        if importer.isImporting { return tr("Adding videos") }
        guard let batch else { return "" }
        return batch.isComplete ? (batch.total == 1 ? tr("Video ready") : tr("%lld videos ready", batch.total))
            : tr("Analysing video %1$lld of %2$lld", min(batch.finished + 1, batch.total), batch.total)
    }
}

// MARK: - Ring

/// The large ring shown when the pill is tapped: percentage in the middle, time left below.
struct ProcessingSheet: View {
    @ObservedObject var monitor: AnalysisMonitor
    @ObservedObject var importer: BatchImporter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let b = monitor.batch
        let importing = importer.isImporting
        let fraction = importing && (b?.fraction ?? 0) == 0 ? importer.fraction : (b?.fraction ?? 0)
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Color.mgSage.opacity(0.15), lineWidth: 16)
                Circle().trim(from: 0, to: max(0.005, min(1, fraction)))
                    .stroke(Color.mgSage, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: fraction)
                VStack(spacing: 4) {
                    if b?.isComplete == true && !importing {
                        Text(tr("Done")).font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(Color.mgSage)
                    } else {
                        Text(L10n.percent((fraction * 100).rounded(.down) / 100))
                            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.mgInk)
                            .contentTransition(.numericText())
                    }
                    if let b, b.total > 1 {
                        Text(tr("%1$lld of %2$lld videos", b.finished, b.total)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 200, height: 200)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("Processing"))
            .accessibilityValue(L10n.percent((fraction * 100).rounded(.down) / 100))

            if let b, !b.isComplete || importing {
                Text(b.paused ? tr("Paused") : (b.remainingSeconds.flatMap(AnalysisProgress.eta).map { tr("%@ left", $0) } ?? "…"))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            if let s = importer.state, s.finished, s.skippedForLength > 0 || s.failed > 0 || s.undated > 0 {
                VStack(spacing: 4) {
                    if s.undated > 0 {
                        Text(s.undated == 1 ? tr("1 video needs a filming date") : tr("%lld videos need a filming date", s.undated))
                            .foregroundStyle(Color.mgGold)
                    }
                    if s.skippedForLength > 0 {
                        Text(s.skippedForLength == 1 ? tr("1 video not added: over 20 minutes in total")
                                                     : tr("%lld videos not added: over 20 minutes in total", s.skippedForLength))
                            .foregroundStyle(.orange)
                    }
                    if s.failed > 0 {
                        Text(s.failed == 1 ? tr("1 video couldn’t be added") : tr("%lld videos couldn’t be added", s.failed))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mgPaper)
        .overlay(alignment: .topTrailing) {
            Button(tr("Close")) { dismiss() }
                .font(.headline)
                .padding()
        }
        .onDisappear { importer.clearIfFinished() }
    }
}
