// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import UIKit
import PhotosUI

struct RootView: View {
    @EnvironmentObject private var store: LocalStore
    @StateObject private var importer = BatchImporter()
    /// Changing the language rebuilds the screens below (open sheets stay open).
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @State private var recording = false
    @State private var settings = false
    @State private var choosingVideo = false
    @State private var selectedVideos: [PhotosPickerItem] = []
    @State private var showProcessing = false
    /// Getting started (OnboardingView.swift): the welcome pages come before the baby profile, and the
    /// recording tips before the first import.
    @AppStorage(Onboarding.welcomeSeenKey) private var welcomeSeen = false
    @AppStorage(Onboarding.importTipsSeenKey) private var importTipsSeen = false
    @State private var importTips = false
    @State private var pickAfterTips = false
    var body: some View {
        Group {
            if store.recoveryRequired {
                ContentUnavailableView(tr("Your files are safe"),systemImage:"externaldrive.badge.exclamationmark",description:Text(tr("The album couldn’t be opened. Existing recordings have been kept. Keep the app installed while this is resolved.")))
            } else if store.album.baby == nil {
                if welcomeSeen {
                    // Not rebuilt on a language change (that would clear what was typed); it redraws itself.
                    NavigationStack { ProfileView(firstRun:true) }
                } else {
                    // Three short pages first (or Skip); they redraw themselves on a language change too.
                    WelcomeFlow(firstRun:true, finish:{ withAnimation(.easeInOut(duration:0.3)) { welcomeSeen = true } })
                }
            } else {
                // Rebuilt on a language change so every screen redraws in the new language.
                TabView {
                    NavigationStack {
                        MemoriesView(record:{ recording = true }, choose:{ chooseVideos() }, choosing:importer.isImporting)
                            .safeAreaInset(edge: .bottom) {
                                ProcessingPill(monitor: store.monitor, importer: importer) { showProcessing = true }
                            }
                            .toolbar {
                                ToolbarItem(placement:.topBarLeading) { Button { settings = true } label: { Image(systemName:"gearshape") }.accessibilityLabel(tr("Settings")) }
                                ToolbarItem(placement:.topBarTrailing) {
                                    Menu {
                                        Button(tr("Record")) { recording = true }
                                        Button(tr("Choose from Photos (up to %lld)", BatchImporter.maxVideos)) { chooseVideos() }
                                            .disabled(importer.isImporting)
                                    } label: {
                                        Image(systemName:"plus")
                                    }
                                    .accessibilityLabel(tr("Add video"))
                                }
                            }
                    }.tabItem { Label(tr("Memories"),systemImage:"square.grid.2x2") }
                    NavigationStack { GrowthView() }.tabItem { Label(tr("Growth"),systemImage:"chart.line.uptrend.xyaxis") }
                }
                .id(language)
            }
        }
        .sheet(isPresented:$recording) { RecordView() }
            .sheet(isPresented:$settings) { NavigationStack { SettingsView() } }
            .sheet(isPresented:$showProcessing) {
                ProcessingSheet(monitor: store.monitor, importer: importer)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            // Before the first import: which videos work. "Choose videos" opens Photos once the sheet has closed.
            .sheet(isPresented:$importTips, onDismiss:{
                if pickAfterTips { pickAfterTips = false; choosingVideo = true }
            }) {
                NavigationStack {
                    RecordingTipsView(purpose:.choose, proceed:{ importTipsSeen = true; pickAfterTips = true })
                }
            }
            // Up to 10 videos, 20 minutes in total (checked while copying; longer ones are skipped).
            .photosPicker(isPresented:$choosingVideo, selection:$selectedVideos, maxSelectionCount:BatchImporter.maxVideos,
                          selectionBehavior:.ordered, matching:.videos, preferredItemEncoding:.current)
            .onChange(of:selectedVideos) { _,items in
                guard !items.isEmpty else { return }
                selectedVideos = []
                importer.start(items, store: store)
                // Let the Photos picker finish dismissing before presenting another sheet.
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    showProcessing = true
                }
            }
            .task { await store.recoverRecordings();store.resumePending() }
            // Outermost, so sheets get the app's language for dates and numbers too.
            .environment(\.locale, L10n.locale)
    }

    /// Opens Photos; the first time, the recording tips come first.
    private func chooseVideos() {
        if importTipsSeen { choosingVideo = true } else { importTips = true }
    }
}

struct ProfileView: View {
    @EnvironmentObject private var store: LocalStore
    @Environment(\.dismiss) private var dismiss
    /// Redraws in place when the language changes (keeping what was typed).
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    var firstRun = false
    @State private var name = ""
    @State private var birthday = Date()
    @State private var bornEarly = false
    @State private var dueDate = Date()
    var body: some View {
        Form {
            if firstRun {
                Section {
                    Text(verbatim: "MoveGrow").font(.mgDisplay).foregroundStyle(Color.mgInk)
                    Text(tr("A private place for little moments and new moves."))
                    LanguageRow()
                }
            }
            Section(tr("Your baby")) {
                TextField(tr("Nickname"),text:$name).textContentType(.givenName)
                DatePicker(tr("Birthday"),selection:$birthday,in:...Date(),displayedComponents:.date)
            }
            Section {
                Toggle(tr("Born before the due date"), isOn:$bornEarly.animation())
                if bornEarly {
                    DatePicker(tr("Due date"),selection:$dueDate,in:birthday...,displayedComponents:.date)
                }
            } footer: {
                Text(bornEarly
                     ? tr("Movement checks use corrected age (counted from the due date) until 24 months, as paediatric guidance does for babies born early.")
                     : tr("If your baby was born two or more weeks early, add the due date so checks use corrected age."))
            }
            Section {
                Button(firstRun ? tr("Create my album") : tr("Save")) {
                    let baby = Baby(name:name.trimmingCharacters(in:.whitespacesAndNewlines), birthday:birthday,
                                    dueDate: bornEarly && dueDate > birthday ? dueDate : nil)
                    do { try store.setBaby(baby); if !firstRun { dismiss() } }
                    catch { store.error = error.localizedDescription }
                }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            } footer: {
                Text(tr("No account. No automatic uploads. Videos stay in this app on this device. Deleting the app or losing your phone can remove your memories; export the ones you want to keep."))
            }
        }
        .id(language)
        .navigationTitle(firstRun ? tr("Welcome") : tr("Baby profile"))
            .onAppear {
                if let baby = store.album.baby {
                    name = baby.name; birthday = baby.birthday
                    bornEarly = baby.dueDate != nil; dueDate = baby.dueDate ?? baby.birthday
                }
            }
    }
}

/// The in-app language: English, 简体中文, Español, or the same as the iPhone. Takes effect at once.
struct LanguageRow: View {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    var body: some View {
        Picker(tr("Language"), selection: Binding(get: { AppLanguage(rawValue: language) ?? .system }, set: { AppLanguage.set($0) })) {
            ForEach(AppLanguage.allCases) { l in Text(l.nativeName).tag(l) }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: LocalStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    // Read so the Analysis section refreshes after the pose engine settings change.
    @AppStorage(PoseEngine.storageKey) private var engineRaw = PoseEngine.instantHMR.rawValue
    @AppStorage(HMRConfig.fpsKey) private var hmrFPS = HMRConfig.defaultFPS
    @State private var storage: Int64?
    var body: some View {
        List {
            Section { LanguageRow() }
            Section { NavigationLink(tr("Baby profile")) { ProfileView() } }
            Section(tr("Getting started")) {
                NavigationLink(tr("How MoveGrow works")) { WelcomeFlow() }
                NavigationLink(tr("Recording tips")) { RecordingTipsView(modal:false) }
            }
            Section(tr("On this device")) {
                Text(tr("No account and no cloud processing. Videos, movement data and summaries are stored on this iPhone and excluded from automatic backup. Export the videos you want to keep before switching phones or deleting the app."))
                    .font(.subheadline).foregroundStyle(.secondary)
                LabeledContent(tr("Memories"), value: "\(store.album.memories.count)")
                LabeledContent(tr("Milestones"), value: "\(store.album.moments.count)")
                LabeledContent(tr("Storage used")) {
                    if let storage { Text(ByteCountFormatter.string(fromByteCount:storage, countStyle:.file)) } else { ProgressView() }
                }
            }
            Section {
                NavigationLink {
                    PoseEngineSettingsView()
                } label: {
                    LabeledContent(tr("Pose engine"), value: PoseEngine.current.title)
                }
                if PoseEngine.current == .instantHMR {
                    Text(tr("Videos are analysed at up to %lld frames per second.", HMRConfig.current.maxFPS))
                } else {
                    Text(tr("Every video is analysed at its own frame rate."))
                }
                Text(tr("Up to %1$lld videos and %2$lld minutes per import.", BatchImporter.maxVideos, Int(BatchImporter.maxTotalSeconds / 60)))
            } header: { Text(tr("Analysis")) } footer: {
                Text(tr("Analysis pauses while the camera is open and keeps going in the background on iOS 26 (shown as a Live Activity you can stop)."))
            }
            Section(tr("About movement summaries")) {
                Text(tr("Summaries describe visible movement in a recording. They are not developmental scores, screening tests or diagnoses.")).font(.subheadline)
                Text(tr("Movement boundaries use experimental, adjustable thresholds. Small movements, occlusion and camera motion can affect results.")).font(.caption).foregroundStyle(.secondary)
                Link(tr("CDC developmental milestones"),destination:URL(string:"https://www.cdc.gov/act-early/milestones/")!)
            }
            Section(tr("Privacy")) {
                NavigationLink(tr("Privacy overview")) { MoveGrowPrivacyView() }
                Link(tr("Privacy policy"), destination: URL(string:"https://seesaw-earth.github.io/MoveGrow/privacy.html")!)
                Link(tr("Support"), destination: URL(string:"https://seesaw-earth.github.io/MoveGrow/support.html")!)
            }
            Section(tr("About MoveGrow")) {
                LabeledContent(tr("Version"), value: Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.2")
                LabeledContent(tr("Developer"), value: "Ziqing Shi")
                Text(verbatim: "© 2026 Ziqing Shi").font(.caption).foregroundStyle(.secondary)
                NavigationLink(tr("Open source & licences")) { MoveGrowOpenSourceView() }
                Link(tr("MoveGrow source code"), destination: URL(string:"https://github.com/seesaw-earth/MoveGrow")!)
            }
        }
        .id(language)
        .navigationTitle(tr("Settings")).toolbar { Button(tr("Done")) { dismiss() } }
            .task { storage = await store.storageUsed() }
    }
}

struct MoveGrowPrivacyView: View {
    var body: some View {
        List {
            Section(tr("On-device by design")) {
                Text(tr("MoveGrow does not require an account and does not upload your baby’s videos, profile, pose data, movement summaries or milestones to a MoveGrow server."))
                Text(tr("Video analysis runs on your device. App data is stored locally in protected app storage and excluded from automatic backup."))
            }
            Section(tr("Your control")) {
                Text(tr("Importing a video creates a private local copy. Exporting or sharing only happens when you choose it."))
                Text(tr("Deleting the app can remove locally stored memories, so export anything you want to keep before deleting the app or changing devices."))
            }
            Section(tr("Important")) {
                Text(tr("MoveGrow provides descriptive movement visualization and organization. It is not a developmental screening test, diagnosis or medical device."))
            }
        }.navigationTitle(tr("Privacy"))
    }
}

struct MoveGrowOpenSourceView: View {
    var body: some View {
        List {
            Section {
                Text(tr("MoveGrow is distributed as open-source software under the GNU Affero General Public License v3.0 (AGPL-3.0)."))
                Text(verbatim: "Copyright © 2026 Ziqing Shi.")
            } header: { Text(verbatim: "MoveGrow") }
            Section {
                Text(tr("Pose analysis uses UltralyticsYOLO 8.9.15 and the official YOLO26l-pose Core ML model. These components are used under AGPL-3.0."))
                Link(tr("Ultralytics licence"), destination: URL(string:"https://www.ultralytics.com/license")!)
                Link(tr("Ultralytics iOS source"), destination: URL(string:"https://github.com/ultralytics/yolo-ios-app")!)
            } header: { Text(verbatim: "Ultralytics YOLO") }
            Section {
                Text(tr("3D pose analysis uses the InstantHMR Medium model, converted to Core ML. Its model weights are distributed under Meta’s SAM License; the InstantHMR code it is based on is under the Apache License 2.0. The MHR body model is © Meta Platforms, Inc. and affiliates, under the Apache License 2.0."))
                NavigationLink { LicenseTextView(title: "SAM License", resource: "SAM-License") } label: { Text(verbatim: "SAM License") }
                NavigationLink { LicenseTextView(title: "Apache License 2.0", resource: "Apache-2.0") } label: { Text(verbatim: "Apache License 2.0") }
                Link(tr("InstantHMR source"), destination: URL(string: "https://github.com/Naturalpad-studio/InstantHMR")!)
                Link(tr("MHR source"), destination: URL(string: "https://github.com/facebookresearch/MHR")!)
            } header: { Text(verbatim: "InstantHMR · MHR") }
            Section {
                Text(tr("The complete corresponding source, AGPL-3.0 licence, build scripts and model provenance for MoveGrow are published in the public MoveGrow repository."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(tr("Open source"))
    }
}

/// A licence text bundled with the app (MoveGrow/Licenses), shown in full. The SAM License asks that a
/// copy travel with the model weights; the Apache License 2.0 covers InstantHMR's code and MHR.
struct LicenseTextView: View {
    let title: String
    let resource: String

    var body: some View {
        ScrollView {
            Text(verbatim: Self.text(resource))
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
    }

    static func text(_ resource: String) -> String {
        Bundle.main.url(forResource: resource, withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}

/// Album sections computed once per render pass (one sort, one grouping pass).
private struct MemorySection: Identifiable {
    var date: Date
    var memories: [Memory]
    var id: Date { date }
}

struct MemoriesView: View {
    /// The empty album's two buttons (RootView presents the recorder and Photos).
    var record: () -> Void = {}
    var choose: () -> Void = {}
    /// An import is running (Photos cannot be opened again yet).
    var choosing = false
    @EnvironmentObject private var store: LocalStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("compactGrid") private var compact = true
    @AppStorage("memoriesGrouping") private var grouping = "Months"
    /// Choosing videos to analyse again in one go.
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var confirmReanalyse = false
    private func bucket(_ date:Date) -> Date {
        let unit: Calendar.Component = grouping == "Days" ? .day : .month
        return Calendar.current.dateInterval(of:unit,for:date)?.start ?? date
    }
    private var sections: [MemorySection] {
        var out: [MemorySection] = []
        for memory in store.album.memories.sorted(by: { $0.date > $1.date }) {
            let b = bucket(memory.date)
            if out.last?.date == b { out[out.count - 1].memories.append(memory) } else { out.append(MemorySection(date:b, memories:[memory])) }
        }
        return out
    }
    /// Selected videos that can be analysed again now (not the one being analysed this moment).
    private var eligible: [UUID] {
        store.album.memories.map(\.id).filter { selected.contains($0) && store.canReanalyze($0) }
    }
    var body: some View {
        let sections = sections
        let withMoments = Set(store.album.moments.map(\.memoryID))
        let columns = Array(repeating:GridItem(.flexible(),spacing:4),count:typeSize.isAccessibilitySize ? 2 : (compact ? 3 : 2))
        let pixels = compact ? 300 : 460
        ScrollView {
            LazyVStack(alignment:.leading,spacing:16) {
                if let baby = store.album.baby { Text(tr("%1$@ · %2$@", baby.name, baby.age(on:Date()))).font(.subheadline).foregroundStyle(.secondary) }
                HStack {
                    Picker(tr("Group memories"),selection:$grouping) { Text(tr("Days")).tag("Days");Text(tr("Months")).tag("Months") }.pickerStyle(.segmented)
                    Button {compact.toggle()} label:{Image(systemName:compact ? "square.grid.2x2" : "square.grid.3x3").frame(minWidth:44,minHeight:44)}.accessibilityLabel(compact ? tr("Larger thumbnails") : tr("Smaller thumbnails"))
                    if !sections.isEmpty {
                        Button(selecting ? tr("Done") : tr("Select")) {
                            withAnimation(.easeOut(duration:0.2)) { selecting.toggle(); selected = [] }
                        }
                        .fontWeight(selecting ? .semibold : .regular)
                        .frame(minHeight:44)
                    }
                }
                if sections.isEmpty { FirstVideoCard(record:record, choose:choose, choosing:choosing) }
                ForEach(sections) { section in
                    Text(grouping == "Days" ? L10n.date(section.date, .long) : L10n.monthYear(section.date)).font(.headline)
                    LazyVGrid(columns:columns,spacing:4) {
                        ForEach(section.memories) { memory in
                            if selecting {
                                let on = selected.contains(memory.id)
                                Button {
                                    if on { selected.remove(memory.id) } else { selected.insert(memory.id) }
                                } label: {
                                    tile(memory, pixels:pixels, moments:false)
                                        .overlay(alignment:.topLeading) {
                                            Image(systemName:on ? "checkmark.circle.fill" : "circle")
                                                .font(.title3)
                                                .symbolRenderingMode(on ? .palette : .monochrome)
                                                .foregroundStyle(.white, Color.mgSage)
                                                .shadow(color:.black.opacity(0.35), radius:1.5)
                                                .padding(6)
                                        }
                                        .overlay { if on { RoundedRectangle(cornerRadius:10).stroke(Color.mgSage, lineWidth:3) } }
                                        .opacity(store.canReanalyze(memory.id) ? 1 : 0.5)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(accessibilityText(memory))
                                .accessibilityAddTraits(on ? .isSelected : [])
                            } else {
                                NavigationLink {MemoryDetailView(memoryID:memory.id)} label: {
                                    tile(memory, pixels:pixels, moments:withMoments.contains(memory.id))
                                }.buttonStyle(.plain).accessibilityLabel(accessibilityText(memory))
                            }
                        }
                    }
                }
                Text(tr("Saved on this device")).font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(.top)
            }.padding(.horizontal).padding(.bottom,24)
        }
        .navigationTitle(selecting ? tr("%lld selected", selected.count) : tr("Memories"))
        .safeAreaInset(edge:.bottom) {
            if selecting { selectionBar }
        }
        .confirmationDialog(tr("Analyse these videos again with %@? Their current analysis is replaced.", PoseEngine.current.title),
                            isPresented:$confirmReanalyse, titleVisibility:.visible) {
            Button(tr("Analyse again")) {
                store.reanalyze(ids: eligible)
                withAnimation(.easeOut(duration:0.2)) { selecting = false; selected = [] }
            }
            Button(tr("Cancel"), role:.cancel) {}
        }
        .onChange(of:store.album.memories.count) { _, _ in
            selected = selected.filter { id in store.memory(id) != nil }     // a selected video was deleted
        }
    }

    /// Select all / Deselect all, and one tap to analyse the selection again.
    private var selectionBar: some View {
        let all = Set(store.album.memories.map(\.id))
        let everything = !all.isEmpty && selected == all
        let count = eligible.count
        return HStack(spacing:12) {
            Button(everything ? tr("Deselect all") : tr("Select all")) { selected = everything ? [] : all }
                .frame(minHeight:44)
            Spacer()
            Button { confirmReanalyse = true } label: {
                Label(tr("Analyse again (%lld)", count), systemImage:"arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.mgSage)
            .disabled(count == 0)
        }
        .padding(.horizontal)
        .padding(.vertical,8)
        .background(.bar)
    }

    private func accessibilityText(_ memory: Memory) -> String {
        [memory.displayTitle, memory.dateText, memory.ageText(store.album.baby), memory.durationLabel].compactMap { $0 }.joined(separator: ", ")
    }

    /// A video's thumbnail with its duration, age, analysis ring and (optionally) the milestones dot.
    private func tile(_ memory: Memory, pixels: Int, moments: Bool) -> some View {
        Thumbnail(filename:memory.thumbnail, maxPixel:pixels).aspectRatio(1,contentMode:.fit)
            .overlay(alignment:.bottomTrailing) {Text(memory.durationLabel).font(.caption2.monospacedDigit()).foregroundStyle(.white).padding(4).background(.black.opacity(0.6)).clipShape(Capsule()).padding(5)}
            .overlay(alignment:.topLeading) {
                // Has saved milestones.
                if moments {Circle().fill(Color.mgGold).frame(width:8,height:8).overlay(Circle().stroke(.white,lineWidth:1.5)).padding(7)}
            }
            .overlay(alignment:.topTrailing) {
                if store.analyzing.contains(memory.id) { AnalysisBadge(memoryID:memory.id, monitor:store.monitor).padding(5) }
            }
            .overlay(alignment:.bottomLeading) {
                if memory.needsDate {
                    Text(tr("No date")).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal,5).padding(.vertical,3).background(Color.mgGold.opacity(0.9)).clipShape(Capsule()).padding(5)
                } else if let age = memory.shortAge(store.album.baby) {
                    Text(age).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal,5).padding(.vertical,3).background(.black.opacity(0.55)).clipShape(Capsule()).padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius:10))
    }
}

/// Small progress ring on a thumbnail. Only this view observes the 5 Hz progress updates.
struct AnalysisBadge: View {
    let memoryID: UUID
    @ObservedObject var monitor: AnalysisMonitor
    var body: some View {
        let p = monitor.progress[memoryID]
        ZStack {
            Circle().fill(.black.opacity(0.55))
            Circle().trim(from:0, to:max(0.04, p?.fraction ?? 0)).stroke(.white, style:StrokeStyle(lineWidth:2.5, lineCap:.round))
                .rotationEffect(.degrees(-90)).padding(4)
                .animation(.linear(duration:0.25), value:p?.fraction)
        }
        .frame(width:24,height:24)
        .opacity(p?.paused == true ? 0.5 : 1)
        .accessibilityLabel(p?.title ?? tr("Analysing"))
    }
}
