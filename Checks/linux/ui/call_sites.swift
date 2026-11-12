// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
// The lines added to RootView.swift and RecordView.swift, as written there, around stand-ins for the
// rest of those screens (which need Photos, the camera and the store and cannot be type-checked here).
import SwiftUI

final class FakeCamera {
    var running = false, recording = false, preparing = false, denied = false
    var checks = EnvironmentChecks.empty
    func start() {}
}
final class FakeImporter { var isImporting = false }
struct NavigationLink<Destination: View>: View {
    init<S: StringProtocol>(_ title: S, @ViewBuilder destination: () -> Destination) {}
    var body: some View { EmptyView() }
}
struct Section<Content: View>: View {
    init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {}
    var body: some View { EmptyView() }
}

struct RootCallSites: View {
    @State private var recording = false
    @State private var choosingVideo = false
    @AppStorage(Onboarding.welcomeSeenKey) private var welcomeSeen = false
    @AppStorage(Onboarding.importTipsSeenKey) private var importTipsSeen = false
    @State private var importTips = false
    @State private var pickAfterTips = false
    let importer = FakeImporter()
    var hasBaby = false

    var body: some View {
        Group {
            if !hasBaby {
                if welcomeSeen {
                    NavigationStack { Text(verbatim: "profile") }
                } else {
                    // Three short pages first (or Skip); they redraw themselves on a language change too.
                    WelcomeFlow(firstRun:true, finish:{ withAnimation(.easeInOut(duration:0.3)) { welcomeSeen = true } })
                }
            } else {
                MemoriesStandIn(record:{ recording = true }, choose:{ chooseVideos() }, choosing:importer.isImporting)
                Button(tr("Choose from Photos (up to %lld)", BatchImporter.maxVideos)) { chooseVideos() }
                    .disabled(importer.isImporting)
            }
        }
            .sheet(isPresented:$importTips, onDismiss:{
                if pickAfterTips { pickAfterTips = false; choosingVideo = true }
            }) {
                NavigationStack {
                    RecordingTipsView(purpose:.choose, proceed:{ importTipsSeen = true; pickAfterTips = true })
                }
            }
    }

    /// Opens Photos; the first time, the recording tips come first.
    private func chooseVideos() {
        if importTipsSeen { choosingVideo = true } else { importTips = true }
    }
}

struct SettingsCallSites: View {
    var body: some View {
        VStack {
            Section(tr("Getting started")) {
                NavigationLink(tr("How MoveGrow works")) { WelcomeFlow() }
                NavigationLink(tr("Recording tips")) { RecordingTipsView(modal:false) }
            }
        }
    }
}

struct MemoriesStandIn: View {
    /// The empty album's two buttons (RootView presents the recorder and Photos).
    var record: () -> Void = {}
    var choose: () -> Void = {}
    /// An import is running (Photos cannot be opened again yet).
    var choosing = false
    @State private var selecting = false
    var isEmpty = true
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                if isEmpty { FirstVideoCard(record:record, choose:choose, choosing:choosing) }
            }
        }
    }
}

struct RecordCallSites: View {
    @Environment(\.dismiss) private var dismiss
    let camera = FakeCamera()
    @State private var saving = false
    @State private var savedID: UUID?
    @AppStorage(Onboarding.recordTipsSeenKey) private var tipsSeen = false
    @State private var introducing = !UserDefaults.standard.bool(forKey: Onboarding.recordTipsSeenKey)
    @State private var showTips = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing:16) {
                    ZStack {
                        Color.black
                        RoundedRectangle(cornerRadius:24)
                            .strokeBorder(Color.white.opacity(0.7), style:StrokeStyle(lineWidth:2,dash:[8,7]))
                            .padding(.horizontal,30)
                            .padding(.vertical,42)
                    }
                    // What is already right, word by word, in the band under the guide (the line of
                    // guidance below the picture says what to do next).
                    .overlay(alignment:.bottom) {
                        if camera.running && !camera.denied {
                            FramingChecklist(checks:camera.checks)
                                .padding(.horizontal,8)
                                .padding(.bottom,8)
                        }
                    }
                    .frame(maxWidth:310)
                    .clipShape(RoundedRectangle(cornerRadius:24))
                    Text(verbatim: "guidance")

                    if camera.denied {
                        Button(tr("Open Camera Settings")) {}
                    }
                }
                .padding()
            }
            .overlay {
                if introducing {
                    RecordingTips(purpose:.record, proceed:{
                        tipsSeen = true
                        withAnimation(.easeOut(duration:0.25)) { introducing = false }
                        camera.start()
                    })
                    .transition(.opacity)
                }
            }
            .navigationTitle(introducing ? tr("Recording tips") : tr("Record"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) {
                    Button(tr("Close")) { dismiss() }
                        .disabled(camera.recording || camera.preparing || saving)
                }
                ToolbarItem(placement:.primaryAction) {
                    if !introducing {
                        Button(tr("Tips")) { showTips = true }
                            .disabled(camera.recording || camera.preparing || saving)
                    }
                }
            }
            .sheet(isPresented:$showTips) {
                NavigationStack { RecordingTipsView() }
            }
        }
    }
}
