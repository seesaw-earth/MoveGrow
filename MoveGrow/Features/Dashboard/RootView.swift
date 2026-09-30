// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import UIKit
import PhotosUI

struct RootView: View {
    @EnvironmentObject private var store: LocalStore
    @State private var recording = false
    @State private var settings = false
    @State private var choosingVideo = false
    @State private var selectedVideo: PhotosPickerItem?
    @State private var importingVideo = false
    @State private var importedMemoryID: UUID?
    @State private var importError: String?
    var body: some View {
        Group {
            if store.recoveryRequired {
                ContentUnavailableView("Your files are safe",systemImage:"externaldrive.badge.exclamationmark",description:Text("The album couldn’t be opened. Existing recordings have been kept. Keep the app installed while this is resolved."))
            } else if store.album.baby == nil {
                ProfileView(firstRun:true)
            } else {
                TabView {
                    NavigationStack {
                        MemoriesView()
                            .toolbar {
                                ToolbarItem(placement:.topBarLeading) { Button { settings = true } label: { Image(systemName:"gearshape") }.accessibilityLabel("Settings") }
                                ToolbarItem(placement:.topBarTrailing) {
                                    Menu {
                                        Button { recording = true } label: { Label("Record a new video", systemImage:"camera") }
                                        Button { choosingVideo = true } label: { Label("Choose from Photos", systemImage:"photo.on.rectangle") }
                                    } label: {
                                        Label("Add video", systemImage:"plus")
                                    }
                                }
                            }
                    }.tabItem { Label("Memories",systemImage:"square.grid.3x3") }
                    NavigationStack { GrowthView() }.tabItem { Label("Growth",systemImage:"sparkles") }
                }
            }
        }.sheet(isPresented:$recording) { RecordView() }
            .sheet(isPresented:$settings) { NavigationStack { SettingsView() } }
            .sheet(isPresented:Binding(get:{ importedMemoryID != nil },set:{ if !$0 { importedMemoryID = nil } })) {
                NavigationStack {
                    if let id = importedMemoryID {
                        MemoryDetailView(memoryID:id,autoOpenSkeleton:true)
                            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Done") { importedMemoryID = nil } } }
                    }
                }
            }
            .photosPicker(isPresented:$choosingVideo, selection:$selectedVideo, matching:.videos, preferredItemEncoding:.current)
            .onChange(of:selectedVideo) { _,item in
                guard let item else { return }
                importingVideo = true
                Task {
                    defer {
                        selectedVideo = nil
                        importingVideo = false
                    }
                    do {
                        guard let staged = try await item.loadTransferable(type:ImportedPhotoVideo.self) else {
                            throw CocoaError(.fileReadUnknown)
                        }
                        defer { try? FileManager.default.removeItem(at:staged.url) }
                        importedMemoryID = try await store.importStagedVideo(from:staged.url, recordedDate:staged.recordedDate)
                    } catch {
                        importError = "We couldn’t add that video. The original in Photos was not changed. \(error.localizedDescription)"
                    }
                }
            }
            .overlay {
                if importingVideo {
                    ZStack {
                        Color.black.opacity(0.12).ignoresSafeArea()
                        VStack(spacing:12) {
                            ProgressView()
                            Text("Adding video…").font(.headline)
                            Text("Keeping a private local copy for movement analysis.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(22).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius:18)).padding()
                    }.allowsHitTesting(true)
                }
            }
            .alert("Import video",isPresented:Binding(get:{ importError != nil },set:{ if !$0 { importError = nil } })) {
                Button("OK",role:.cancel) { importError = nil }
            } message: { Text(importError ?? "") }
            .task { await store.recoverRecordings();store.resumePending() }
    }
}

struct ProfileView: View {
    @EnvironmentObject private var store: LocalStore
    @Environment(\.dismiss) private var dismiss
    var firstRun = false
    @State private var name = ""
    @State private var birthday = Date()
    var body: some View {
        Form {
            if firstRun {
                Section {
                    Image(systemName:"leaf").font(.largeTitle).foregroundStyle(.teal)
                    Text("MoveGrow").font(.largeTitle.bold())
                    Text("A private place for little moments and new moves.")
                }
            }
            Section("Your baby") {
                TextField("Nickname",text:$name).textContentType(.givenName)
                DatePicker("Birthday",selection:$birthday,in:...Date(),displayedComponents:.date)
            }
            Section {
                Button(firstRun ? "Create my album" : "Save") {
                    do { try store.setBaby(Baby(name:name.trimmingCharacters(in:.whitespacesAndNewlines),birthday:birthday)); if !firstRun { dismiss() } }
                    catch { store.error = error.localizedDescription }
                }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            } footer: {
                Text("No account. No automatic uploads. Videos stay in this app on this device. Deleting the app or losing your phone can remove your memories; export the ones you want to keep.")
            }
        }.navigationTitle(firstRun ? "Welcome" : "Baby profile")
            .onAppear { if let baby = store.album.baby { name = baby.name;birthday = baby.birthday } }
    }
}
struct SettingsView: View {
    @EnvironmentObject private var store: LocalStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section { NavigationLink("Baby profile") { ProfileView() } }
            Section("On this device") {
                Label("No account or cloud processing",systemImage:"iphone")
                Text("Videos, movement data and summaries are stored locally and excluded from automatic backup. Export important videos from each memory before switching phones or deleting the app.").font(.subheadline).foregroundStyle(.secondary)
                Text("\(store.album.memories.count) memories · \(store.album.moments.count) milestones")
            }
            Section("About movement summaries") {
                Text("Summaries describe visible movement in a recording. They are not developmental scores, screening tests or diagnoses.").font(.subheadline)
                Text("Movement boundaries use experimental, adjustable thresholds. Small movements, occlusion and camera motion can affect results.").font(.caption).foregroundStyle(.secondary)
                Link("CDC developmental milestones",destination:URL(string:"https://www.cdc.gov/act-early/milestones/")!)
            }
            Section("Privacy") {
                NavigationLink("Privacy overview") { MoveGrowPrivacyView() }
                Link("Privacy policy", destination: URL(string:"https://seesaw-earth.github.io/MoveGrow/privacy.html")!)
                Link("Support", destination: URL(string:"https://seesaw-earth.github.io/MoveGrow/support.html")!)
            }
            Section("About MoveGrow") {
                LabeledContent("Version", value: "1.0")
                LabeledContent("Developer", value: "Ziqing Shi")
                Text("© 2026 Ziqing Shi").font(.caption).foregroundStyle(.secondary)
                NavigationLink("Open source & licenses") { MoveGrowOpenSourceView() }
                Link("MoveGrow source code", destination: URL(string:"https://github.com/seesaw-earth/MoveGrow")!)
            }
        }.navigationTitle("Settings").toolbar { Button("Done") { dismiss() } }
    }
}

struct MoveGrowPrivacyView: View {
    var body: some View {
        List {
            Section("On-device by design") {
                Text("MoveGrow does not require an account and does not upload your baby's videos, profile, pose data, movement summaries or milestones to a MoveGrow server.")
                Text("Video analysis runs on your device. App data is stored locally in protected app storage and excluded from automatic backup.")
            }
            Section("Your control") {
                Text("Importing a video creates a private local copy. Exporting or sharing only happens when you choose it.")
                Text("Deleting the app can remove locally stored memories, so export anything you want to keep before deleting the app or changing devices.")
            }
            Section("Important") {
                Text("MoveGrow provides descriptive movement visualization and organization. It is not a developmental screening test, diagnosis or medical device.")
            }
        }.navigationTitle("Privacy")
    }
}

struct MoveGrowOpenSourceView: View {
    var body: some View {
        List {
            Section("MoveGrow") {
                Text("MoveGrow is distributed as open-source software under the GNU Affero General Public License v3.0 (AGPL-3.0).")
                Text("Copyright © 2026 Ziqing Shi.")
            }
            Section("Ultralytics YOLO") {
                Text("Pose analysis uses UltralyticsYOLO 8.9.15 and the official YOLO26l-pose Core ML model. These components are used under AGPL-3.0.")
                Link("Ultralytics license", destination: URL(string:"https://www.ultralytics.com/license")!)
                Link("Ultralytics iOS source", destination: URL(string:"https://github.com/ultralytics/yolo-ios-app")!)
            }
            Section {
                Text("The complete corresponding source, AGPL-3.0 license, build scripts and model provenance for MoveGrow are published in the public MoveGrow repository.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Open Source")
    }
}

struct Thumbnail: View {
    let filename: String?
    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let filename,let image = UIImage(contentsOfFile:LocalFiles.url(filename).path) {
                GeometryReader { geo in
                    Image(uiImage:image).resizable().scaledToFill().frame(width:geo.size.width,height:geo.size.height).clipped()
                }
            } else { Image(systemName:"video").foregroundStyle(.secondary).font(.title2) }
        }.clipped()
    }
}
struct MemoriesView: View {
    @EnvironmentObject private var store: LocalStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("compactGrid") private var compact = true
    @State private var grouping = "Months"
    private var memories: [Memory] { store.album.memories.sorted { $0.date > $1.date } }
    private var groups: [Date] { Array(Set(memories.map { bucket($0.date) })).sorted(by:>) }
    private func bucket(_ date:Date) -> Date {
        let unit: Calendar.Component = grouping == "Days" ? .day : .month
        return Calendar.current.dateInterval(of:unit,for:date)?.start ?? date
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                if let baby = store.album.baby { Text("\(baby.name) · \(baby.age(on:Date()))").font(.subheadline).foregroundStyle(.secondary) }
                HStack {
                    Picker("Group memories",selection:$grouping) { Text("Days").tag("Days");Text("Months").tag("Months") }.pickerStyle(.segmented)
                    Button {compact.toggle()} label:{Image(systemName:compact ? "square.grid.2x2" : "square.grid.3x3").frame(minWidth:44,minHeight:44)}.accessibilityLabel(compact ? "Larger thumbnails" : "Compact thumbnails")
                }
                if memories.isEmpty { ContentUnavailableView("Your story starts here",systemImage:"camera",description:Text("Tap + to record a new video or choose one from Photos.")) }
                ForEach(groups,id:\.self) { date in
                    Text(date.formatted(grouping == "Days" ? .dateTime.month(.wide).day().year() : .dateTime.month(.wide).year())).font(.headline)
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:4),count:typeSize.isAccessibilitySize ? 2 : (compact ? 3 : 2)),spacing:4) {
                        ForEach(memories.filter {bucket($0.date) == date}) { memory in
                            NavigationLink {MemoryDetailView(memoryID:memory.id)} label: {
                                Thumbnail(filename:memory.thumbnail).aspectRatio(1,contentMode:.fit)
                                    .overlay(alignment:.bottomTrailing) {Text(memory.durationLabel).font(.caption2.monospacedDigit()).foregroundStyle(.white).padding(4).background(.black.opacity(0.6)).clipShape(Capsule()).padding(5)}
                                    .overlay(alignment:.topLeading) {
                                        if store.album.moments.contains(where:{$0.memoryID == memory.id}) {Image(systemName:"sparkle").font(.caption).foregroundStyle(.white).padding(5).background(.black.opacity(0.55)).clipShape(Circle()).padding(5)}
                                    }.clipShape(RoundedRectangle(cornerRadius:10))
                            }.buttonStyle(.plain).accessibilityLabel("\(memory.title), \(memory.date.formatted(date:.abbreviated,time:.omitted)), \(memory.durationLabel)")
                        }
                    }
                }
                Text("Saved on this device").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(.top)
            }.padding(.horizontal).padding(.bottom,24)
        }.navigationTitle("Memories")
    }
}
