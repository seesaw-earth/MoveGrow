// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Growth charts as one PNG, for a check-up or for family: a header (who, how old, which dates,
// how many videos), the chosen chart or all six with their legends and first-to-last changes,
// and optionally the patterns seen across recordings and the saved milestones. The preview is the
// image itself; Share sends it, Save to Photos adds it to the library.

import SwiftUI
import Charts
import Photos

/// The image's content, drawn at a fixed width (390 pt, 1170 px).
struct GrowthReport: View {
    struct Milestone: Identifiable {
        var id: UUID
        var title: String
        var date: String
        var age: String?
    }
    struct Pattern: Identifiable {
        var id: String
        var name: String
        var count: String
        var note: String?
        var important: Bool
    }

    let babyLine: String?
    let data: TrendData
    let metrics: [TrendMetric]
    let milestones: [Milestone]
    let patterns: [Pattern]
    let generated: String

    static let width: CGFloat = 390

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ForEach(metrics) { m in chartCard(m) }
            if !patterns.isEmpty { patternsCard }
            if !milestones.isEmpty { milestonesCard }
            Text(tr("Made with MoveGrow on %@. Describes movement seen in home videos; not a diagnosis.", generated))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: Self.width, alignment: .leading)
        .background(Color.mgPaper)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "MoveGrow").font(.caption.weight(.semibold)).foregroundStyle(Color.mgSage)
            Text(tr("Movement over time")).font(.mgTitle).foregroundStyle(Color.mgInk)
            if let babyLine { Text(babyLine).font(.subheadline.weight(.semibold)).foregroundStyle(Color.mgInk) }
            let count = data.entries.reduce(0) { $0 + $1.memoryIDs.count }
            let videos = count == 1 ? tr("1 video") : tr("%lld videos", count)
            Text(data.periodText.map { tr("%1$@ · %2$@", $0, videos) } ?? videos)
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func chartCard(_ m: TrendMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(m.title).font(.headline).foregroundStyle(Color.mgInk)
            Text(m.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if data.entries.count >= 2 {
                TrendChart(metric: m, data: data, height: metrics.count > 1 ? 160 : 240)
                TrendLegend(metric: m, approximate: data.hasApproximate)
                let changes = data.changes(m)
                if !changes.isEmpty {
                    Text(tr("From the first to the last point")).font(.caption2).foregroundStyle(.secondary)
                    TrendChips(chips: changes.map { line, d in
                        TrendChips.Chip(id: line.key, title: line.title, color: line.color, text: m.formatChange(d))
                    })
                }
            } else {
                Text(tr("Not enough videos in this period for a trend.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .mgCard(padding: 12)
    }

    private var patternsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Across recordings")).font(.headline).foregroundStyle(Color.mgInk)
            ForEach(patterns) { p in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(p.name).font(.caption.weight(.semibold)).foregroundStyle(p.important ? Color.orange : Color.mgInk)
                        Spacer()
                        Text(p.count).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let note = p.note { Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
        .mgCard(padding: 12)
    }

    private var milestonesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Milestones")).font(.headline).foregroundStyle(Color.mgInk)
            ForEach(milestones) { m in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Color.mgGold).frame(width: 6, height: 6)
                    Text(m.title).font(.caption.weight(.semibold)).foregroundStyle(Color.mgInk)
                    Spacer(minLength: 8)
                    Text([m.date, m.age].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
        }
        .mgCard(padding: 12)
    }
}

struct GrowthExportSheet: View {
    @EnvironmentObject private var store: LocalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    enum Period: String, CaseIterable, Identifiable {
        case all, threeMonths, month
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return tr("All")
            case .threeMonths: return tr("3 months")
            case .month: return tr("1 month")
            }
        }
        var since: Date? {
            switch self {
            case .all: return nil
            case .threeMonths: return Calendar.current.date(byAdding: .month, value: -3, to: Date())
            case .month: return Calendar.current.date(byAdding: .month, value: -1, to: Date())
            }
        }
    }

    enum SaveState { case none, saving, saved, denied, failed }

    @State private var metric: TrendMetric
    @State private var byDay: Bool
    @State private var byAge: Bool
    @AppStorage("growthExport.allCharts") private var allCharts = true
    @AppStorage("growthExport.milestones") private var includeMilestones = true
    @AppStorage("growthExport.patterns") private var includePatterns = true
    @State private var period = Period.all
    @State private var image: UIImage?
    @State private var file: URL?
    @State private var saveState = SaveState.none

    init(metric: TrendMetric, byDay: Bool, byAge: Bool) {
        _metric = State(initialValue: metric)
        _byDay = State(initialValue: byDay)
        _byAge = State(initialValue: byAge)
    }

    private struct Key: Hashable {
        var metric: TrendMetric, byDay: Bool, byAge: Bool, all: Bool, milestones: Bool, patterns: Bool
        var period: Period, language: String, analysed: Int, moments: Int
    }

    private var key: Key {
        Key(metric: metric, byDay: byDay, byAge: byAge, all: allCharts, milestones: includeMilestones, patterns: includePatterns,
            period: period, language: L10n.language.rawValue,
            analysed: store.album.memories.filter { $0.kinematics != nil }.count, moments: store.album.moments.count)
    }

    private var hasPatterns: Bool { store.motorTrends().contains { $0.detectedSessions > 0 } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    preview
                    options
                }
                .padding(16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Color.mgPaper)
            .navigationTitle(tr("Export charts"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Close")) { dismiss() } } }
            .safeAreaInset(edge: .bottom) { actions }
        }
        .task(id: key) { await render() }
        .onDisappear { try? FileManager.default.removeItem(at: Self.folder) }
    }

    private var preview: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Rectangle().fill(Color.mgCard).frame(height: 300).overlay(ProgressView())
            }
        }
        .frame(maxHeight: 460)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .accessibilityLabel(tr("Preview of the image"))
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(tr("Charts"), selection: $allCharts) {
                Text(tr("All charts")).tag(true)
                Text(tr("This chart")).tag(false)
            }
            .pickerStyle(.segmented)
            if !allCharts {
                Picker(tr("Chart"), selection: $metric) {
                    ForEach(TrendMetric.allCases) { m in Text(m.title).tag(m) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Period")).font(.subheadline.weight(.semibold))
                Picker(tr("Period"), selection: $period) {
                    ForEach(Period.allCases) { p in Text(p.title).tag(p) }
                }
                .pickerStyle(.segmented)
            }
            HStack {
                Picker(tr("Points"), selection: $byDay) {
                    Text(tr("Each video")).tag(false)
                    Text(tr("Each day")).tag(true)
                }
                .pickerStyle(.segmented)
                if store.album.baby != nil {
                    Picker(tr("Axis"), selection: $byAge) {
                        Text(tr("Date")).tag(false)
                        Text(tr("Age")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 150)
                }
            }
            Toggle(tr("Milestones"), isOn: $includeMilestones).disabled(store.album.moments.isEmpty)
            if hasPatterns {
                Toggle(tr("Patterns across recordings"), isOn: $includePatterns)
            }
        }
        .tint(Color.mgSage)
        .mgCard(padding: 14)
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if let file, let image {
                    ShareLink(item: file, preview: SharePreview(tr("Movement over time"), image: Image(uiImage: image))) {
                        Text(tr("Share")).font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {} label: { Text(tr("Share")).font(.headline).frame(maxWidth: .infinity, minHeight: 50) }
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                }
                Button { Task { await saveToPhotos() } } label: {
                    Group {
                        switch saveState {
                        case .none, .denied: Text(tr("Save to Photos"))
                        case .saving: ProgressView()
                        case .saved: Text(tr("Saved to Photos"))
                        case .failed: Text(tr("Try again"))
                        }
                    }
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .disabled(file == nil || saveState == .saving || saveState == .saved)
            }
            .tint(Color.mgSage)
            if saveState == .denied {
                Button(tr("Allow adding to Photos in Settings")) {
                    if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
                }
                .font(.footnote)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: rendering

    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("GrowthExport", isDirectory: true) }

    @MainActor private func report() -> GrowthReport {
        let baby = store.album.baby
        let since = period.since
        let data = TrendData(memories: store.album.memories, baby: baby, byDay: byDay, byAge: byAge, since: since)
        var milestones: [GrowthReport.Milestone] = []
        if includeMilestones {
            // The most recent ones, oldest first (an image that keeps growing helps nobody).
            let chosen = store.album.moments.filter { m in since.map { m.date >= $0 } ?? true }.sorted { $0.date < $1.date }.suffix(Self.maxMilestones)
            milestones = chosen.map { m in
                GrowthReport.Milestone(id: m.id, title: m.title, date: L10n.date(m.date), age: baby?.age(on: m.date))
            }
        }
        var patterns: [GrowthReport.Pattern] = []
        if includePatterns {
            let detected = store.motorTrends().filter { $0.detectedSessions > 0 }
            let ranked = detected.sorted { a, b in
                let ka = (a.persistent ? 1 : 0, a.severity, a.detectedSessions)
                let kb = (b.persistent ? 1 : 0, b.severity, b.detectedSessions)
                return ka > kb
            }
            patterns = ranked.map { t in
                GrowthReport.Pattern(id: t.ruleID, name: t.name.text,
                                     count: tr("%1$lld of %2$lld", t.detectedSessions, t.evaluatedSessions),
                                     note: t.message?.text, important: t.persistent && t.severity >= .discuss)
            }
        }
        return GrowthReport(babyLine: baby.map { tr("%1$@ · %2$@", $0.name, $0.age(on: Date())) },
                            data: data, metrics: allCharts ? TrendMetric.allCases : [metric],
                            milestones: milestones, patterns: patterns, generated: L10n.date(Date()))
    }

    static let maxMilestones = 24

    @MainActor private func render() async {
        // Let quick taps settle first.
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        let content = report()
            .environment(\.locale, L10n.locale)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(width: GrowthReport.width, height: nil)
        guard let ui = renderer.uiImage else { return }
        image = ui
        file = nil
        saveState = .none
        // Encoding and writing happen off the main thread; each render gets its own folder, so a
        // cancelled render can never overwrite the file being shared.
        let url = Self.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(Self.filename(baby: store.album.baby?.name))
        let written: Bool = await Task.detached(priority: .userInitiated) {
            guard let png = ui.pngData() else { return false }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? png.write(to: url, options: .atomic)) != nil
        }.value
        guard !Task.isCancelled, written else {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            return
        }
        if let old = file { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
        file = url
    }

    /// "MoveGrow growth Mia 2026-11-03.png"
    static func filename(baby: String?) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -"))
        let raw = [tr("MoveGrow growth"), baby, day].compactMap { $0 }.joined(separator: " ")
        var name = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        return name.trimmingCharacters(in: .whitespaces) + ".png"
    }

    private func saveToPhotos() async {
        guard let file else { return }
        saveState = .saving
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { saveState = .denied; return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
            }
            saveState = .saved
        } catch {
            saveState = .failed
        }
    }
}
