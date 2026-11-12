// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// The review screen. The video stays on top (no skeleton over it; YOLO's 2D skeleton is in ⋯ → YOLO
// pose) with a timeline under it to drag through — events are dots on it, and reaching one shows its
// name on the video for a moment — then time and frame stepping, and four tabs: Kinematics (the parameter timeline; "Hold to
// move" to scrub it), 3D (the baby figure following the video), Summary (activity on the baby,
// activity map, left and right, movement, joint range) and Noticed (event navigation, observations,
// possible milestones). While the video is analysed, its progress is shown above. Text only on demand.

import SwiftUI
import AVKit

/// The views under the video: the kinematic panel, the 3D baby, the summary cards and what was noticed.
enum ReviewTab: String {
    case kinematics, pose3D, summary, noticed
}

struct MemoryDetailView: View {
    @EnvironmentObject private var store: LocalStore
    let memoryID: UUID
    var initialStart: Double = 0
    var initialEnd: Double?

    var body: some View {
        Group {
            if let memory = store.memory(memoryID) {
                ReviewScreen(memory: memory, initialStart: initialStart, initialEnd: initialEnd)
            } else {
                ContentUnavailableView(tr("Memory unavailable"), systemImage: "video.slash")
            }
        }
    }
}

private struct ReviewScreen: View {
    @EnvironmentObject private var store: LocalStore
    @Environment(\.dismiss) private var dismiss

    let memoryID: UUID
    let videoURL: URL
    let initialStart: Double
    let initialEnd: Double?

    @StateObject private var player: ReviewPlayerModel
    @State private var track: PoseTrack?
    @State private var digest: ReviewDigest?
    @State private var report: MotorReport?
    @State private var filter: String?
    @State private var momentSeed: ClipSeed?
    @State private var editing = false
    @State private var datePicking = false
    @State private var exporting = false
    @State private var confirmDelete = false
    @State private var detail: MotorFinding?
    @State private var showChecks = false
    /// ⋯ → YOLO pose.
    @State private var showYOLO = false
    @AppStorage("reviewTab") private var tab: ReviewTab = .kinematics
    @State private var confirmReanalyze = false
    @State private var workingSuggestion: UUID?
    /// Display aspect for older memories without a stored one.
    @State private var videoAspect: Double?
    /// The scrubber's caption on the video (a reference, so the screen does not redraw while it changes).
    @State private var scrubCaption = ScrubCaption()

    init(memory: Memory, initialStart: Double, initialEnd: Double?) {
        memoryID = memory.id
        videoURL = LocalFiles.url(memory.filename)
        self.initialStart = initialStart
        self.initialEnd = initialEnd
        _player = StateObject(wrappedValue: ReviewPlayerModel(url: LocalFiles.url(memory.filename), duration: memory.duration))
    }

    private var memory: Memory? { store.memory(memoryID) }
    private var poseReady: Bool { memory?.poseStorage != nil }
    private var refining: Bool { memory?.analysisStage == .quick && store.analyzing.contains(memoryID) }

    private struct LoadKey: Hashable {
        var pose: String?
        var stage: AnalysisStage?
        var motor: Date?
    }

    var body: some View {
        VStack(spacing: 0) {
            videoArea
            VideoScrubber(player: player, ticker: player.clock, events: memory.map { events($0) } ?? [], caption: scrubCaption)
                .background(Color.black)
            ScrollView {
                if let m = memory {
                    content(m)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color.mgPaper)
        .navigationTitle(memory?.displayTitle ?? tr("Memory"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $momentSeed) { seed in
            if let m = memory { MomentEditor(memory: m, seed: seed) }
        }
        .sheet(isPresented: $editing) {
            if let m = memory { MemoryEditor(memory: m) }
        }
        .sheet(isPresented: $datePicking) {
            if let m = memory { VideoDateSheet(memory: m, baby: store.album.baby) }
        }
        .sheet(isPresented: $exporting) {
            if let m = memory {
                ExportVideoSheet(memory: m, videoURL: videoURL, track: track, digest: digest, previewTime: player.time)
            }
        }
        .sheet(item: $detail) { f in
            ObservationDetailSheet(finding: f, rule: store.ruleBook?.rule(f.ruleID), sources: store.ruleBook?.sources ?? [:],
                                   videoURL: videoURL, duration: player.duration) { start, end in player.playSegment(start, end) }
        }
        .sheet(isPresented: $showChecks) {
            if let report { CheckListSheet(report: report, refining: refining) }
        }
        .fullScreenCover(isPresented: $showYOLO) {
            if let m = memory { YOLOPoseView(memory: m).environmentObject(store) }
        }
        .confirmationDialog(tr("Delete this video, its analysis and linked milestones?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(tr("Delete memory"), role: .destructive) { deleteMemory() }
        }
        .confirmationDialog(tr("Analyse this video again with %@? Its current analysis is replaced.", PoseEngine.current.title),
                            isPresented: $confirmReanalyze, titleVisibility: .visible) {
            Button(tr("Analyse again")) {
                player.pause()
                store.reanalyze(memoryID)
            }
        }
        .task(id: LoadKey(pose: memory?.poseStorage, stage: memory?.analysisStage, motor: memory?.motor?.generatedAt)) { await load() }
        .onAppear {
            if let initialEnd { player.playSegment(initialStart, initialEnd) }
        }
        .onDisappear { player.pause() }
        .background { ResultsReadyFeedback(memoryID: memoryID, monitor: store.monitor) }
    }

    // MARK: video

    private var videoArea: some View {
        let aspect = CGFloat(memory?.aspectRatio ?? videoAspect ?? 9.0 / 16.0)
        return ZStack {
            PlayerLayerView(player: player.player)
            PausedGlyph(player: player)
        }
        .overlay(alignment: .top) { ScrubCaptionView(caption: scrubCaption) }
        .aspectRatio(aspect > 0.1 ? aspect : 9.0 / 16.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 360)
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture { player.toggle() }
        .accessibilityElement(children: .contain)
        .accessibilityHint(tr("Tap to play or pause"))
    }

    // MARK: content

    @ViewBuilder private func content(_ m: Memory) -> some View {
        let analysing = store.analyzing.contains(m.id)
        VStack(alignment: .leading, spacing: 14) {
            header(m)
            if analysing {
                // Big ring before any results; a slim bar while results are refined or redone.
                AnalysisRingCard(memoryID: m.id, monitor: store.monitor, compact: digest != nil)
            } else if m.report == nil || !poseReady {
                retryCard(m)
            }
            let timelineEvents = events(m)
            ReviewReadout(player: player, ticker: player.clock, digest: digest)
            ReviewControls(player: player, fps: m.videoFPS ?? digest?.analysisFPS ?? 30) {
                player.pause()
                momentSeed = ClipSeed(start: min(player.time, max(0, m.duration - 1)), end: min(m.duration, player.time + 5), title: "")
            }
            Picker(tr("View"), selection: $tab) {
                Text(tr("Kinematics")).tag(ReviewTab.kinematics)
                Text(tr("3D")).tag(ReviewTab.pose3D)
                Text(tr("Summary")).tag(ReviewTab.summary)
                Text(noticedTitle).tag(ReviewTab.noticed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch tab {
            case .kinematics:
                if digest != nil {
                    ParameterTimeline(player: player, digest: digest, events: timelineEvents)
                        .mgCard(padding: 12)
                } else {
                    placeholder(analysing)
                }
            case .pose3D:
                Pose3DPanel(memory: m, player: player)
            case .summary:
                if let digest {
                    BodyMapCard(digest: digest)
                    ReviewCard(title: tr("Activity map")) {
                        ReviewTimeline(player: player, ticker: player.clock, digest: digest, events: timelineEvents)
                    }
                    BalanceCard(digest: digest)
                    MotionCard(digest: digest, duration: m.duration, player: player)
                    RangeCard(digest: digest)
                } else {
                    placeholder(analysing)
                }
            case .noticed:
                EventNavigator(player: player, ticker: player.clock, events: timelineEvents, groups: groups(m), filter: $filter)
                if let report {
                    ObservationTiles(report: report, refining: refining, onSelect: { f in
                        if let e = f.events.min(by: { $0.t0 < $1.t0 }) { player.seek(e.t0) }
                        player.pause()
                        detail = f
                    }, onShowList: { showChecks = true })
                } else {
                    placeholder(analysing)
                }
                suggestions(m)
            }
            moments(m)
            if !m.note.isEmpty {
                Text(m.note).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// "Noticed" with how many observations are shown.
    private var noticedTitle: String {
        let n = report?.shown.count ?? 0
        return n > 0 ? "\(tr("Noticed")) \(n)" : tr("Noticed")
    }

    private func placeholder(_ analysing: Bool) -> some View {
        Text(analysing ? tr("Appears when the analysis is done.") : tr("No results for this video yet."))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mgCard(padding: 14)
    }

    private func header(_ m: Memory) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button { datePicking = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if m.needsDate {
                        Text(tr("Add filming date"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.mgGold)
                    } else {
                        Text(m.dateText).font(.subheadline.weight(.semibold)).foregroundStyle(Color.mgInk)
                    }
                    if let age = m.ageText(store.album.baby) {
                        Text(age).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(tr("Change when this was filmed"))
            Spacer()
            Menu {
                Picker(tr("Position"), selection: Binding(get: { m.context }, set: { store.setContext($0, for: m.id) })) {
                    ForEach(RecordingContext.allCases) { c in Text(c.title).tag(c) }
                }
            } label: {
                Text(m.context.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 30)
                    .background(Color.mgSageSoft, in: Capsule())
                    .foregroundStyle(Color.mgSage)
            }
            .accessibilityLabel(tr("Baby’s position: %@", m.context.title))
            if let digest {
                StatRing(value: digest.trackedFraction, label: "\(Int((digest.trackedFraction * 100).rounded()))")
                    .accessibilityLabel(tr("Tracked %@ of the time", L10n.percent(digest.trackedFraction)))
            }
        }
    }

    private func retryCard(_ m: Memory) -> some View {
        HStack(spacing: 12) {
            Text(m.analysisError == nil ? tr("Not analysed yet") : tr("Analysis didn’t finish")).font(.subheadline.weight(.semibold))
            Spacer()
            Button(tr("Retry")) { store.analyze(m.id) }
                .buttonStyle(.borderedProminent).tint(Color.mgSage)
        }
        .mgCard(padding: 12)
    }

    // MARK: events

    private func events(_ m: Memory) -> [TimelineEvent] {
        var out: [TimelineEvent] = []
        for f in report?.shown ?? [] {
            for (k, e) in f.events.enumerated() {
                out.append(TimelineEvent(id: "\(f.ruleID)#\(k)", group: f.ruleID, t0: e.t0, t1: e.t1, tint: f.tint, title: f.name.text))
            }
        }
        for s in (m.milestoneSuggestions ?? []) where s.status == .suggested {
            out.append(TimelineEvent(id: "s-\(s.id)", group: "milestones", t0: s.start, t1: s.end, tint: .milestone, title: s.title))
        }
        for moment in store.album.moments where moment.memoryID == m.id {
            out.append(TimelineEvent(id: "m-\(moment.id)", group: "milestones", t0: moment.start, t1: moment.end, tint: .milestone,
                                     title: moment.title.isEmpty ? tr("Milestones") : moment.title))
        }
        return out.sorted { $0.t0 < $1.t0 }
    }

    private func groups(_ m: Memory) -> [EventGroup] {
        var out = (report?.shown ?? []).filter { !$0.events.isEmpty }.map { EventGroup(id: $0.ruleID, title: $0.name.text, tint: $0.tint) }
        let hasMilestones = (m.milestoneSuggestions ?? []).contains { $0.status == .suggested } || store.album.moments.contains { $0.memoryID == m.id }
        if hasMilestones { out.append(EventGroup(id: "milestones", title: tr("Milestones"), tint: .milestone)) }
        return out
    }

    // MARK: milestones

    @ViewBuilder private func suggestions(_ m: Memory) -> some View {
        let pending = (m.milestoneSuggestions ?? []).filter { $0.status == .suggested }
        if !pending.isEmpty {
            ReviewCard(title: tr("Possible milestones")) {
                ForEach(pending) { s in
                    HStack(spacing: 8) {
                        Button { player.playSegment(s.start, s.end) } label: {
                            Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(tr("Plays this part of the video"))
                        Button {
                            player.pause()
                            workingSuggestion = s.id
                            Task {
                                do { try await store.confirmSuggestion(memoryID: m.id, suggestionID: s.id) }
                                catch { store.error = error.localizedDescription }
                                workingSuggestion = nil
                            }
                        } label: {
                            if workingSuggestion == s.id { ProgressView().controlSize(.small) }
                            else { Text(tr("Add")).font(.subheadline.weight(.semibold)) }
                        }
                        .buttonStyle(.borderedProminent).tint(Color.mgSage)
                        .disabled(workingSuggestion != nil)
                        .accessibilityLabel(tr("Add “%@” to Growth", s.title))
                        Button {
                            do { try store.dismissSuggestion(memoryID: m.id, suggestionID: s.id) }
                            catch { store.error = error.localizedDescription }
                        } label: { Text(tr("Not this")).font(.subheadline.weight(.semibold)) }
                        .buttonStyle(.bordered)
                        .disabled(workingSuggestion != nil)
                        .accessibilityLabel(tr("Not this movement"))
                    }
                }
            }
        }
    }

    @ViewBuilder private func moments(_ m: Memory) -> some View {
        let saved = store.album.moments.filter { $0.memoryID == m.id }.sorted { $0.start < $1.start }
        if !saved.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(saved) { moment in
                        Button { player.playSegment(moment.start, moment.end) } label: {
                            Text(moment.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Color.mgGold.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.mgInk)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                player.pause()
                exporting = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel(tr("Export video"))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(tr("Edit title & note")) { editing = true }
                Button(tr("Change date")) { datePicking = true }
                if poseReady {
                    Button(tr("YOLO pose")) {
                        player.pause()
                        showYOLO = true
                    }
                }
                if poseReady {
                    Button(tr("Analyse again")) { confirmReanalyze = true }
                        .disabled(!store.canReanalyze(memoryID))
                }
                if let m = memory {
                    Section(tr("Files")) {
                        ShareLink(item: LocalFiles.url(m.filename)) { Text(tr("Original video")) }
                        if poseReady {
                            ShareLink(item: PoseJSONExport(memoryID: m.id, raw: false), preview: SharePreview(tr("Pose data (JSON)"))) {
                                Text(tr("Pose data (JSON)"))
                            }
                            ShareLink(item: PoseJSONExport(memoryID: m.id, raw: true), preview: SharePreview(tr("Raw pose data (JSON)"))) {
                                Text(tr("Raw pose data (JSON)"))
                            }
                            if PoseEngine.isInstantHMR(m.poseEstimator) {
                                ShareLink(item: HMRJSONExport(memoryID: m.id), preview: SharePreview(tr("3D pose data (JSON)"))) {
                                    Text(tr("3D pose data (JSON)"))
                                }
                            }
                        }
                    }
                }
                Button(tr("Delete memory"), role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(tr("Memory options"))
        }
    }

    // MARK: loading

    @MainActor private func load() async {
        if memory?.aspectRatio == nil, videoAspect == nil, let info = try? await VideoAnalyzer.probe(url: videoURL) {
            videoAspect = info.aspect
        }
        guard poseReady else {
            track = nil; digest = nil; report = nil
            return
        }
        let t = await store.poseTrack(for: memoryID)
        let d = await store.reviewDigest(for: memoryID)
        let r = await store.motorReport(for: memoryID)
        withAnimation(.easeOut(duration: 0.25)) {
            track = t
            digest = d
            report = r
        }
    }

    private func deleteMemory() {
        player.pause()
        do {
            try store.deleteMemory(memoryID)
            dismiss()
        } catch {
            store.error = error.localizedDescription
        }
    }
}

/// Big play glyph while paused (review screen and YOLO pose page).
struct PausedGlyph: View {
    @ObservedObject var player: ReviewPlayerModel
    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .mgGlass(Circle())
            .opacity(player.isPlaying ? 0 : 0.9)
            .scaleEffect(player.isPlaying ? 0.8 : 1)
            .animation(.easeOut(duration: 0.2), value: player.isPlaying)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// This video's analysis progress: a ring before the first results, a slim bar (`compact`) while
/// results are refined or the video is analysed again.
private struct AnalysisRingCard: View {
    let memoryID: UUID
    @ObservedObject var monitor: AnalysisMonitor
    var compact = false

    var body: some View {
        let p = monitor.progress[memoryID]
        let f = p?.fraction ?? 0
        let percent = L10n.percent((f * 100).rounded(.down) / 100)
        let spoken: String = p?.paused == true ? tr("%@, paused", percent)
            : (p?.remainingSeconds.flatMap(AnalysisProgress.eta).map { tr("%1$@, %2$@ left", percent, $0) } ?? percent)
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(p?.title ?? tr("Analysing")).font(.subheadline.weight(.semibold)).foregroundStyle(Color.mgInk)
                    Spacer()
                    Text(p?.paused == true ? tr("Paused") : [percent, p?.etaText].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: max(0, min(1, f)))
                    .tint(Color.mgSage)
                    .animation(.easeOut(duration: 0.3), value: f)
            }
            .mgCard(padding: 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(p?.title ?? tr("Analysing"))
            .accessibilityValue(spoken)
        } else {
            ring(p: p, f: f, spoken: spoken)
        }
    }

    private func ring(p: AnalysisProgress?, f: Double, spoken: String) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.mgSage.opacity(0.15), lineWidth: 8)
                Circle().trim(from: 0, to: max(0.01, min(1, f)))
                    .stroke(Color.mgSage, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: f)
                Text(L10n.percent((f * 100).rounded(.down) / 100))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Color.mgInk)
                    .contentTransition(.numericText())
            }
            .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Analysing")).font(.subheadline.weight(.semibold)).foregroundStyle(Color.mgInk)
                if let p, p.paused {
                    Text(tr("Paused")).font(.subheadline).foregroundStyle(.secondary)
                } else if let eta = p?.remainingSeconds.flatMap(AnalysisProgress.eta) {
                    Text(tr("%@ left", eta)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .mgCard(padding: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Analysing"))
        .accessibilityValue(spoken)
    }
}

/// A gentle haptic when this memory's results arrive while the parent is looking at it.
private struct ResultsReadyFeedback: View {
    let memoryID: UUID
    @ObservedObject var monitor: AnalysisMonitor
    var body: some View {
        Color.clear
            .sensoryFeedback(.success, trigger: monitor.finished) { _, new in new?.id == memoryID }
    }
}

struct MemoryEditor: View {
    @EnvironmentObject private var store:LocalStore
    @Environment(\.dismiss) private var dismiss
    @State var memory:Memory
    @State private var datePicking = false
    var body:some View {
        NavigationStack {
            Form {
                Section(tr("Title")) {TextField(tr("A little moment"),text:$memory.title)}
                Section(tr("Notes")) {TextField(tr("Add a note (optional)"),text:$memory.note,axis:.vertical)}
                Section(tr("Filmed")) {
                    let current = store.memory(memory.id) ?? memory
                    Button {datePicking = true} label: {
                        HStack {
                            Text(current.needsDate ? tr("Add filming date") : current.dateText)
                                .foregroundStyle(current.needsDate ? Color.mgGold : Color.mgInk)
                            Spacer()
                            if let age = current.ageText(store.album.baby) {Text(age).font(.footnote).foregroundStyle(.secondary)}
                        }
                    }
                }
            }
            .sheet(isPresented:$datePicking) {VideoDateSheet(memory:store.memory(memory.id) ?? memory, baby:store.album.baby)}
            // A video without a title of its own shows the placeholder, in the app's language.
            .onAppear {if !memory.hasOwnTitle {memory.title = ""}}
            .navigationTitle(tr("Edit memory")).toolbar {
                ToolbarItem(placement:.cancellationAction) {Button(tr("Cancel")){dismiss()}}
                ToolbarItem(placement:.confirmationAction) {Button(tr("Save")){
                    do {
                        // Merge only edited fields; preserve a report completed meanwhile.
                        if var latest = store.memory(memory.id) {
                            latest.title = memory.title.trimmingCharacters(in:.whitespacesAndNewlines)
                            latest.note = memory.note
                            try store.update(latest)
                        }
                        dismiss()
                    } catch {store.error = error.localizedDescription}
                }}
            }
        }
    }
}
