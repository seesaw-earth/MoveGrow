// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import AVFoundation

/// Camera preview geometry intentionally mirrors the NMA recorder: the portrait
/// preview is aspect-fill and the pose overlay is drawn in the same normalized,
/// top-left coordinate system as the Vision result used by CameraController.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> Preview {
        let view = Preview()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: Preview, context: Context) {
        view.updateVideoOrientation()
    }

    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateVideoOrientation()
        }

        func updateVideoOrientation() {
            if let connection = preview.connection,
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }
}

struct RecordView: View {
    @EnvironmentObject private var store: LocalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraController()
    @State private var saving = false
    @State private var savedID: UUID?
    @State private var allowImperfect = false
    /// The first time, the recording tips fill the sheet before the camera starts, so the camera prompt
    /// comes with its reason; later they open from the toolbar.
    @AppStorage(Onboarding.recordTipsSeenKey) private var tipsSeen = false
    @State private var introducing = !UserDefaults.standard.bool(forKey: Onboarding.recordTipsSeenKey)
    @State private var showTips = false
    @AppStorage("recordingContext") private var contextRaw = RecordingContext.supine.rawValue
    private var context: RecordingContext { RecordingContext(rawValue:contextRaw) ?? .supine }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing:16) {
                    ZStack {
                        CameraPreview(session:camera.session)

                        RoundedRectangle(cornerRadius:24)
                            .strokeBorder(
                                camera.ready ? Color.green : Color.white.opacity(0.7),
                                style:StrokeStyle(lineWidth:2,dash:[8,7])
                            )
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
                    // CameraController records a 1280x720 sensor stream rotated
                    // 90 degrees to portrait. The live pose only drives the framing
                    // guidance below; no skeleton is drawn.
                    .aspectRatio(9/16,contentMode:.fit)
                    .frame(maxWidth:310)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius:24))
                    .accessibilityLabel(tr("Camera preview"))

                    Text(camera.guidance)
                        .font(.subheadline.weight(camera.ready ? .semibold : .regular))
                        .foregroundStyle(camera.ready ? Color.mgSage : Color.primary)
                        .multilineTextAlignment(.center)

                    if camera.denied {
                        Button(tr("Open Camera Settings")) {
                            if let url = URL(string:UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }

                    if camera.recording {
                        Text(clock(camera.seconds)).monospacedDigit().font(.title2)
                        Button(role:.destructive) { camera.stopRecording() } label: {
                            Text(tr("Finish recording")).frame(maxWidth:.infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Text(tr("Video keeps recording if a hand or foot leaves the frame."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            if camera.ready { camera.beginRecording() }
                            else { allowImperfect = true }
                        } label: {
                            Text(camera.preparing ? tr("Starting…") : tr("Record"))
                                .frame(maxWidth:.infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!camera.running || camera.preparing || saving || savedID != nil)
                    }

                    ContextPicker(selection:Binding(get:{context},set:{contextRaw = $0.rawValue}))
                        .disabled(camera.recording || camera.preparing)

                    Text(tr("Up to 3 minutes · No audio · Saved on this device"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if saving { ProgressView(tr("Saving your memory…")) }
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
            .onAppear { if !introducing { camera.start() }; store.setCaptureActive(true) }
            .onDisappear { camera.stopSession(); store.setCaptureActive(false) }
            .onChange(of:scenePhase) { _,phase in
                // The camera stops in the background, so analysis may use that time; it pauses again on return.
                store.setCaptureActive(phase == .active && savedID == nil)
                if phase != .active { camera.stopRecording() }
                else if !camera.running && savedID == nil && !introducing { camera.start() }
            }
            .onChange(of:camera.completedURL) { _,url in
                guard let url else { return }
                saving = true
                Task {
                    do { savedID = try await store.saveRecording(url:url, context:context) }
                    catch {
                        store.error = tr("The recording file was kept, but couldn’t be added to the album. Reopen the app to retry. %@", error.localizedDescription)
                    }
                    saving = false
                }
            }
            .navigationDestination(isPresented:Binding(get:{savedID != nil},set:{if !$0 {dismiss()}})) {
                if let id = savedID { MemoryDetailView(memoryID:id) }
            }
            .alert(tr("Recording tips"),isPresented:$allowImperfect) {
                Button(tr("Adjust framing"),role:.cancel) {}
                Button(tr("Record anyway")) { camera.beginRecording() }
            } message: {
                Text(tr("%@ You can still keep this memory, but its movement summary may be limited.", camera.guidance))
            }
            .alert(
                tr("Camera"),
                isPresented:Binding(get:{camera.error != nil},set:{if !$0 {camera.error = nil}})
            ) {
                Button(tr("OK"),role:.cancel) {camera.error = nil}
            } message: {
                Text(camera.error ?? "")
            }
        }
        .interactiveDismissDisabled(camera.recording || camera.preparing || saving)
    }
}

/// How the baby is positioned. Chosen before recording (and editable later) so each check only runs
/// where it is meaningful — posture checks, for example, need the baby on their back, filmed from above.
struct ContextPicker: View {
    @Binding var selection: RecordingContext
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:8) {
                    ForEach(RecordingContext.allCases) { c in
                        Button { selection = c } label: {
                            Text(c.title).font(.subheadline)
                                .padding(.horizontal,12).padding(.vertical,8)
                                .background(selection == c ? Color.mgSage.opacity(0.18) : Color(.secondarySystemBackground))
                                .foregroundStyle(selection == c ? Color.mgSage : Color.primary)
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(selection == c ? Color.mgSage : .clear,lineWidth:1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == c ? .isSelected : [])
                    }
                }
            }
            .sensoryFeedback(.selection,trigger:selection)
            if selection != .supine {
                Text(tr("Posture checks need “On back”"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth:.infinity,alignment:.leading)
    }
}
