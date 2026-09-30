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

/// NMA-style live skeleton: bones plus visible joints, rendered over exactly the
/// same portrait preview area. PoseFrame coordinates are normalized with a
/// top-left origin after CameraController rotates the Vision input to portrait.
private struct LivePoseOverlay: View {
    let pose: PoseFrame

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Path { path in
                    for (a, b) in BodyJoint.connections {
                        guard let p = pose.point(a), let q = pose.point(b),
                              p.confidence > 0.12, q.confidence > 0.12 else { continue }
                        path.move(to: scaled(p, geo.size))
                        path.addLine(to: scaled(q, geo.size))
                    }
                }
                .stroke(
                    Color.mint.opacity(0.96),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )

                ForEach(BodyJoint.allCases, id: \.self) { joint in
                    if let point = pose.point(joint), point.confidence > 0.08 {
                        Circle()
                            .fill(.white)
                            .frame(width: markerSize(for: joint), height: markerSize(for: joint))
                            .overlay(Circle().stroke(Color.mint, lineWidth: 2))
                            .shadow(radius: 1)
                            .position(scaled(point, geo.size))
                    }
                }
            }
            .animation(.linear(duration: 0.10), value: pose.timestamp)
        }
        .allowsHitTesting(false)
    }

    private func scaled(_ p: JointPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    private func markerSize(for joint: BodyJoint) -> CGFloat {
        switch joint {
        case .leftWrist, .rightWrist, .leftAnkle, .rightAnkle:
            return 10
        default:
            return 7
        }
    }
}

struct RecordView: View {
    @EnvironmentObject private var store: LocalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraController()
    @State private var skeleton = true
    @State private var saving = false
    @State private var savedID: UUID?
    @State private var allowImperfect = false

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

                        if skeleton, let pose = camera.pose {
                            LivePoseOverlay(pose: pose)
                        }
                    }
                    // CameraController records a 1280x720 sensor stream rotated
                    // 90 degrees to portrait, so this is the same displayed 9:16
                    // geometry that the normalized live pose was estimated on.
                    .aspectRatio(9/16,contentMode:.fit)
                    .frame(maxWidth:310)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius:24))
                    .accessibilityLabel("Camera preview with live movement skeleton")

                    Label(camera.guidance,systemImage:camera.ready ? "checkmark.circle.fill" : "viewfinder")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)

                    if camera.denied {
                        Button("Open Camera Settings") {
                            if let url = URL(string:UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }

                    if camera.recording {
                        Text(clock(camera.seconds)).monospacedDigit().font(.title2)
                        Button(role:.destructive) { camera.stopRecording() } label: {
                            Label("Finish recording",systemImage:"stop.circle.fill").frame(maxWidth:.infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Text("Video keeps recording if a hand or foot leaves the frame.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            if camera.ready { camera.beginRecording() }
                            else { allowImperfect = true }
                        } label: {
                            Label(camera.preparing ? "Starting…" : "Record",systemImage:"record.circle")
                                .frame(maxWidth:.infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!camera.running || camera.preparing || saving || savedID != nil)
                    }

                    Toggle("Show live skeleton",isOn:$skeleton).font(.subheadline)
                    Text("Up to 3 minutes · No audio · Saved on this device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if saving { ProgressView("Saving your memory…") }
                }
                .padding()
            }
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(camera.recording || camera.preparing || saving)
                }
            }
            .onAppear { camera.start() }
            .onDisappear { camera.stopSession() }
            .onChange(of:scenePhase) { _,phase in
                if phase != .active { camera.stopRecording() }
                else if !camera.running && savedID == nil { camera.start() }
            }
            .onChange(of:camera.completedURL) { _,url in
                guard let url else { return }
                saving = true
                Task {
                    do { savedID = try await store.saveRecording(url:url) }
                    catch {
                        store.error = "The recording file was kept, but couldn’t be added to the album. Reopen the app to retry. \(error.localizedDescription)"
                    }
                    saving = false
                }
            }
            .navigationDestination(isPresented:Binding(get:{savedID != nil},set:{if !$0 {dismiss()}})) {
                if let id = savedID { MemoryDetailView(memoryID:id) }
            }
            .alert("Recording tips",isPresented:$allowImperfect) {
                Button("Adjust framing",role:.cancel) {}
                Button("Record anyway") { camera.beginRecording() }
            } message: {
                Text("\(camera.guidance) You can still keep this memory, but its movement summary may be limited.")
            }
            .alert(
                "Camera",
                isPresented:Binding(get:{camera.error != nil},set:{if !$0 {camera.error = nil}})
            ) {
                Button("OK",role:.cancel) {camera.error = nil}
            } message: {
                Text(camera.error ?? "")
            }
        }
        .interactiveDismissDisabled(camera.recording || camera.preparing || saving)
    }
}
