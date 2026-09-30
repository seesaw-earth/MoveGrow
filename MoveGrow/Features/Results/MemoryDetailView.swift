// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import AVKit

@MainActor final class ClipPlayer: ObservableObject {
    let player: AVPlayer
    private var boundary: Any?
    private var observer: Any?
    private var seekID = UUID()
    @Published var position = 0.0
    @Published var playingClip = false
    init(url:URL) {
        player = AVPlayer(url:url)
        observer = player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.1,preferredTimescale:600),queue:.main) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            Task { @MainActor [weak self] in
                self?.position = seconds
            }
        }
    }
    func play(start:Double,end:Double?) {
        player.pause()
        let request = UUID(); seekID = request
        player.currentItem?.cancelPendingSeeks()
        player.currentItem?.forwardPlaybackEndTime = end.map { CMTime(seconds:$0,preferredTimescale:600) } ?? .invalid
        if let boundary { player.removeTimeObserver(boundary);self.boundary = nil }
        playingClip = end != nil
        if let end {
            boundary = player.addBoundaryTimeObserver(forTimes:[NSValue(time:CMTime(seconds:end,preferredTimescale:600))],queue:.main) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.player.pause()
                }
            }
        }
        player.seek(to:CMTime(seconds:max(0,start),preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                guard let self, self.seekID == request else { return }
                self.player.play()
            }
        }
    }
    func stop() { seekID = UUID(); player.currentItem?.cancelPendingSeeks(); player.pause() }
    deinit {
        if let observer { player.removeTimeObserver(observer) }
        if let boundary { player.removeTimeObserver(boundary) }
    }
}

private struct PlaybackSkeletonOverlay: View {
    let sample: MotionSample?

    var body: some View {
        GeometryReader { geo in
            if let sample, sample.lightOK {
                ZStack {
                    Path { path in
                        for (a, b) in BodyJoint.connections {
                            guard let p = visiblePoint(sample, joint: a),
                                  let q = visiblePoint(sample, joint: b) else { continue }
                            path.move(to: scaled(p, geo.size))
                            path.addLine(to: scaled(q, geo.size))
                        }
                    }
                    .stroke(
                        Color.mint.opacity(0.96),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )

                    ForEach(BodyJoint.allCases, id: \.self) { joint in
                        if let point = visiblePoint(sample, joint: joint) {
                            Circle()
                                .fill(.white)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(Color.mint, lineWidth: 2))
                                .shadow(radius: 1)
                                .position(scaled(point, geo.size))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func visiblePoint(_ sample: MotionSample, joint: BodyJoint) -> MotionPoint? {
        guard let point = sample.points[joint.rawValue],
              point.confidence >= MovementEngine.minimumConfidence,
              point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { return nil }
        return point
    }

    private func scaled(_ p: MotionPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: p.y * size.height)
    }
}

struct MemoryDetailView: View {
    @EnvironmentObject private var store: LocalStore
    @Environment(\.dismiss) private var dismiss
    let memoryID: UUID
    var initialStart: Double = 0
    var initialEnd: Double?
    var autoOpenSkeleton: Bool = false
    var body: some View {
        Group {
            if let memory = store.memory(memoryID) {
                MemoryContent(memoryID:memoryID,url:LocalFiles.url(memory.filename),initialStart:initialStart,initialEnd:initialEnd,autoOpenSkeleton:autoOpenSkeleton)
            } else { ContentUnavailableView("Memory unavailable",systemImage:"video.slash") }
        }
    }
}
private struct MemoryContent: View {
    @EnvironmentObject private var store: LocalStore
    @Environment(\.dismiss) private var dismiss

    let memoryID: UUID
    let videoURL: URL
    var initialStart: Double
    var initialEnd: Double?
    var autoOpenSkeleton: Bool

    @StateObject private var playback: ClipPlayer
    @State private var momentSeed: ClipSeed?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var skeletonSheet = false
    @State private var autoSkeletonPresented = false
    @State private var workingSuggestion: UUID?
    @State private var playbackSamples: [MotionSample] = []
    @State private var showPlaybackSkeleton = true
    @State private var videoAspect: CGFloat = 9.0 / 16.0

    init(memoryID:UUID,url:URL,initialStart:Double,initialEnd:Double?,autoOpenSkeleton:Bool) {
        self.memoryID = memoryID
        self.videoURL = url
        self.initialStart = initialStart
        self.initialEnd = initialEnd
        self.autoOpenSkeleton = autoOpenSkeleton
        _playback = StateObject(wrappedValue:ClipPlayer(url:url))
    }

    private var memory: Memory? { store.memory(memoryID) }

    var body: some View {
        screen
    }

    private var navigationScreen: some View {
        content
            .navigationTitle(memory?.title ?? "Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { memoryToolbar }
    }

    private var modalScreen: some View {
        navigationScreen
            .sheet(item:$momentSeed) { seed in
                if let m = memory { MomentEditor(memory:m,seed:seed) }
            }
            .sheet(isPresented:$editing) {
                if let m = memory { MemoryEditor(memory:m) }
            }
            .sheet(isPresented:$skeletonSheet) {
                skeletonSheetContent
            }
    }

    private var screen: some View {
        modalScreen
            .confirmationDialog(
                "Delete this video, summary and linked milestone clips?",
                isPresented:$confirmDelete,
                titleVisibility:.visible
            ) {
                Button("Delete memory",role:.destructive) { deleteMemory() }
            }
            .onAppear(perform:handleAppear)
            .onChange(of:poseReady) { _,ready in handlePoseReady(ready) }
            .task(id: poseReady) { await loadPlaybackResources() }
            .onDisappear { playback.stop() }
    }

    private var poseReady: Bool { store.poseURL(for:memoryID) != nil }

    @ViewBuilder private var content: some View {
        ScrollView {
            if let m = memory {
                memorySections(m)
                    .padding()
            }
        }
    }

    @ViewBuilder private func memorySections(_ m: Memory) -> some View {
        VStack(alignment:.leading,spacing:20) {
            videoSection(m)
            metadataSection(m)
            saveMilestoneButton(m)

            if !m.note.isEmpty {
                Text(m.note).font(.subheadline)
            }

            analysisSection(m)
            momentsSection(m)
        }
    }

    @ViewBuilder private func videoSection(_ m: Memory) -> some View {
        ZStack {
            VideoPlayer(player:playback.player)
            if showPlaybackSkeleton, !playbackSamples.isEmpty {
                PlaybackSkeletonOverlay(sample: currentPlaybackSample)
            }
        }
        // Match the video's displayed orientation rather than forcing a 3:4 box.
        // Because the player and overlay share this exact aspect rectangle, the
        // normalized pose coordinates land on the same pixels as the source video.
        .aspectRatio(videoAspect,contentMode:.fit)
        .frame(maxWidth:.infinity)
        .frame(maxHeight:370)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius:18))

        HStack {
            Text(m.date.formatted(date:.abbreviated,time:.shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !playbackSamples.isEmpty {
                Button {
                    showPlaybackSkeleton.toggle()
                } label: {
                    Label(
                        showPlaybackSkeleton ? "Hide skeleton" : "Show skeleton",
                        systemImage: showPlaybackSkeleton ? "figure.child" : "figure.child.circle"
                    )
                }
                .font(.caption)
            }
            if playback.playingClip {
                Button("Full video") { playback.play(start:0,end:nil) }
                    .font(.caption)
            }
        }
    }

    @ViewBuilder private func metadataSection(_ m: Memory) -> some View {
        if let baby = store.album.baby {
            Text(baby.age(on:m.date))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        if let estimator = m.poseEstimator {
            let isYOLO = estimator.contains("yolo26")
            HStack(spacing:6) {
                Image(systemName:isYOLO ? "cpu" : "exclamationmark.triangle")
                Text(isYOLO ? "YOLO26l Pose · on-device Core ML" : "Apple Vision fallback")
                if let processing = m.poseProcessing, processing != "none" {
                    Text("· \(processing)")
                }
            }
            .font(.caption2)
            .foregroundStyle(isYOLO ? Color.secondary : Color.orange)
        }
    }

    private func saveMilestoneButton(_ m: Memory) -> some View {
        Button {
            playback.stop()
            momentSeed = ClipSeed(
                start:min(playback.position,max(0,m.duration-1)),
                end:min(m.duration,playback.position+5),
                title:""
            )
        } label: {
            Label("Save a milestone clip",systemImage:"sparkle")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder private func analysisSection(_ m: Memory) -> some View {
        if let report = m.report {
            reportView(report,memory:m)
            suggestionSection(m)
            skeletonButton(m)
        } else if store.analyzing.contains(m.id) {
            ProgressView("Preparing movement summary on this device…")
            Text("Your video is already saved. You can return to the album.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(m.analysisError ?? "Your video is saved.")
                .font(.subheadline)
            Button("Retry summary") { store.analyze(m.id) }
        }
    }

    @ViewBuilder private func suggestionSection(_ m: Memory) -> some View {
        let pending = (m.milestoneSuggestions ?? []).filter { $0.status == .suggested }
        if !pending.isEmpty {
            milestoneSuggestionsView(pending,memory:m)
        }
    }

    @ViewBuilder private func skeletonButton(_ m: Memory) -> some View {
        if store.poseURL(for:m.id) != nil {
            Button {
                playback.stop()
                skeletonSheet = true
            } label: {
                Label("Make a 10s skeleton clip",systemImage:"figure.child")
                    .frame(maxWidth:.infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private func momentsSection(_ m: Memory) -> some View {
        let moments = store.album.moments
            .filter { $0.memoryID == m.id }
            .sorted { $0.start < $1.start }

        if !moments.isEmpty {
            Text("Milestones in this memory").font(.headline)
            ForEach(moments) { moment in
                Button { playback.play(start:moment.start,end:moment.end) } label: {
                    Label(
                        "\(moment.title) · \(clock(moment.start))–\(clock(moment.end))",
                        systemImage:"play.circle"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ToolbarContentBuilder private var memoryToolbar: some ToolbarContent {
        ToolbarItem(placement:.topBarTrailing) {
            Menu {
                Button("Edit title & note",systemImage:"pencil") { editing = true }
                if let m = memory { exportMenu(m) }
                Button("Delete memory",systemImage:"trash",role:.destructive) { confirmDelete = true }
            } label: {
                Image(systemName:"ellipsis.circle")
            }
            .accessibilityLabel("Memory options")
        }
    }

    @ViewBuilder private func exportMenu(_ m: Memory) -> some View {
        ShareLink(item:LocalFiles.url(m.filename)) {
            Label("Export video",systemImage:"square.and.arrow.up")
        }

        if let poseURL = store.poseURL(for:m.id) {
            ShareLink(item:poseURL) {
                Label("Export processed pose JSON",systemImage:"square.and.arrow.up")
            }
            if let rawPoseURL = store.rawPoseURL(for:m.id) {
                ShareLink(item:rawPoseURL) {
                    Label("Export raw YOLO pose JSON",systemImage:"square.and.arrow.up")
                }
            }
            Button("Create skeleton clip",systemImage:"figure.child") {
                playback.stop()
                skeletonSheet = true
            }
        }

        if let report = m.report {
            ShareLink(item:reportText(report,memory:m)) {
                Label("Share summary",systemImage:"doc.text")
            }
        }
    }

    @ViewBuilder private var skeletonSheetContent: some View {
        if let m = memory, let poseURL = store.poseURL(for:m.id) {
            SkeletonClipSheet(
                memory:m,
                videoURL:LocalFiles.url(m.filename),
                poseURL:poseURL
            )
        }
    }


    private var currentPlaybackSample: MotionSample? {
        nearestSample(to: playback.position)
    }

    private func nearestSample(to time: Double) -> MotionSample? {
        guard !playbackSamples.isEmpty, time.isFinite else { return nil }
        var low = 0
        var high = playbackSamples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if playbackSamples[mid].time < time { low = mid + 1 }
            else { high = mid }
        }

        let right = low
        let left = max(0, right - 1)
        let candidate: MotionSample
        if abs(playbackSamples[left].time - time) <= abs(playbackSamples[right].time - time) {
            candidate = playbackSamples[left]
        } else {
            candidate = playbackSamples[right]
        }
        // Do not freeze an old pose over a long detector gap.
        return abs(candidate.time - time) <= 0.20 ? candidate : nil
    }

    @MainActor private func loadPlaybackResources() async {
        let sourceURL = videoURL
        if let tracks = try? await AVURLAsset(url: sourceURL).loadTracks(withMediaType: .video),
           let track = tracks.first,
           let naturalSize = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform)
            let width = abs(bounds.width)
            let height = abs(bounds.height)
            if width > 1, height > 1 {
                videoAspect = width / height
            }
        }

        guard let poseURL = store.poseURL(for: memoryID) else {
            playbackSamples = []
            return
        }

        do {
            playbackSamples = try await Task.detached(priority: .utility) {
                let data = try Data(contentsOf: poseURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let archive = try? decoder.decode(PoseArchive.self, from: data) {
                    return archive.frames.sorted { $0.time < $1.time }
                }
                return try JSONDecoder().decode([MotionSample].self, from: data).sorted { $0.time < $1.time }
            }.value
        } catch {
            playbackSamples = []
        }
    }

    private func deleteMemory() {
        playback.stop()
        do {
            try store.deleteMemory(memoryID)
            dismiss()
        } catch {
            store.error = error.localizedDescription
        }
    }

    private func handleAppear() {
        if initialEnd != nil {
            playback.play(start:initialStart,end:initialEnd)
        }
        if autoOpenSkeleton, !autoSkeletonPresented, poseReady {
            autoSkeletonPresented = true
            skeletonSheet = true
        }
    }

    private func handlePoseReady(_ ready: Bool) {
        if ready && autoOpenSkeleton && !autoSkeletonPresented {
            playback.stop()
            autoSkeletonPresented = true
            skeletonSheet = true
        }
    }

    @ViewBuilder private func milestoneSuggestionsView(_ suggestions:[MilestoneSuggestion],memory:Memory) -> some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label("Possible milestones",systemImage:"sparkles").font(.headline)
                Spacer()
                Text("Review first").font(.caption).foregroundStyle(.secondary)
            }
            Text("These are movement-pattern suggestions from on-device pose analysis, not developmental conclusions.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(suggestions) { suggestion in
                VStack(alignment:.leading,spacing:9) {
                    Button {
                        playback.play(start:suggestion.start,end:suggestion.end)
                    } label: {
                        HStack {
                            Image(systemName:suggestion.kind.symbol).frame(width:28)
                            VStack(alignment:.leading,spacing:2) {
                                Text(suggestion.title).font(.subheadline.weight(.semibold))
                                Text("Preview \(clock(suggestion.start))–\(clock(suggestion.end)) · \(matchLabel(suggestion.score))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName:"play.circle")
                        }
                    }.buttonStyle(.plain)

                    HStack {
                        Button {
                            playback.stop()
                            workingSuggestion = suggestion.id
                            Task {
                                do { try await store.confirmSuggestion(memoryID:memory.id,suggestionID:suggestion.id) }
                                catch { store.error = error.localizedDescription }
                                workingSuggestion = nil
                            }
                        } label: {
                            if workingSuggestion == suggestion.id { ProgressView().controlSize(.small) }
                            else { Label("Add to Growth",systemImage:"bookmark.fill") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(workingSuggestion != nil)

                        Button("Not this movement") {
                            do { try store.dismissSuggestion(memoryID:memory.id,suggestionID:suggestion.id) }
                            catch { store.error = error.localizedDescription }
                        }
                        .buttonStyle(.bordered)
                        .disabled(workingSuggestion != nil)
                    }
                    .font(.caption)
                }
                .padding(12)
                .background(.teal.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius:14))
            }
        }
    }

    private func matchLabel(_ score: Double) -> String {
        score >= 0.84 ? "strong pattern match" : "possible pattern match"
    }

    @ViewBuilder private func reportView(_ r:MovementReport,memory:Memory) -> some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Movement summary").font(.headline)
            Text(r.summary).font(.subheadline)
            Label(r.qualityNote,systemImage:"viewfinder").font(.caption).foregroundStyle(.secondary)
        }
        if !r.events.isEmpty {
            DisclosureGroup("Movement clips · \(r.events.count)") {
                ForEach(r.events) { event in
                    HStack {
                        Button {playback.play(start:event.start,end:event.end)} label: {
                            VStack(alignment:.leading,spacing:4) {
                                Label(event.title,systemImage:"play.circle")
                                Text("\(clock(event.start))–\(clock(event.end))").font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                        Spacer()
                        Button {
                            playback.stop()
                            momentSeed = ClipSeed(start:event.start,end:event.end,title:"")
                        } label: {
                            Image(systemName:"bookmark")
                        }
                        .accessibilityLabel("Save \(event.title) as milestone")
                        .frame(minWidth:44,minHeight:44)
                    }
                    .padding(.vertical,6)
                }
            }
        }
        DisclosureGroup("Recording details") {
            VStack(alignment:.leading,spacing:12) {
                Text("Whole-body landmarks visible: \(clock(r.fullBodySeconds)) of \(clock(r.duration))").font(.caption)
                ForEach(r.limbs) { limb in
                    VStack(alignment:.leading,spacing:4) {
                        HStack {
                            Text(limb.name)
                            Spacer()
                            Text("\(clock(limb.observedSeconds)) observed").foregroundStyle(.secondary)
                        }
                        if let fraction = limb.activeFraction {
                            ProgressView(value:min(1,max(0,fraction)))
                            Text("Movement detected in \(Int(fraction*100))% of observed time").font(.caption)
                        } else {
                            Text("Not enough clear data").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
                Text("Estimates from 2D landmarks. Visibility, lighting and camera motion affect results. These are observations, not developmental scores.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top,10)
        }
    }

    private func reportText(_ r:MovementReport,memory:Memory) -> String {
        "MoveGrow — \(memory.title)\n\(memory.date.formatted(date:.abbreviated,time:.shortened))\n\n\(r.summary)\n\n\(r.qualityNote)\n\n" + r.limbs.map {"\($0.name): \(clock($0.observedSeconds)) observed; \(clock($0.activeSeconds)) movement detected."}.joined(separator:"\n") + "\n\nDescriptive observations only; not a developmental screening or diagnosis."
    }
}

struct MemoryEditor: View {
    @EnvironmentObject private var store:LocalStore
    @Environment(\.dismiss) private var dismiss
    @State var memory:Memory
    var body:some View {
        NavigationStack {
            Form {TextField("Title",text:$memory.title);TextField("Notes",text:$memory.note,axis:.vertical)}
                .navigationTitle("Edit memory").toolbar {
                    ToolbarItem(placement:.cancellationAction) {Button("Cancel"){dismiss()}}
                    ToolbarItem(placement:.confirmationAction) {Button("Save"){
                        do {
                            // Merge only edited fields; preserve a report completed meanwhile.
                            if var latest = store.memory(memory.id) {latest.title = memory.title;latest.note = memory.note;try store.update(latest)}
                            dismiss()
                        } catch {store.error = error.localizedDescription}
                    }.disabled(memory.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
                }
        }
    }
}
