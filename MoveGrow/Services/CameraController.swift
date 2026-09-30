// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import AVFoundation
import Vision
import Combine
import CoreImage
import UIKit

final class CameraController: NSObject, ObservableObject, @unchecked Sendable {
    @Published var checks = EnvironmentChecks.empty
    @Published var pose: PoseFrame?
    @Published var running = false
    @Published var recording = false
    @Published var preparing = false
    @Published var denied = false
    @Published var error: String?
    @Published var seconds = 0.0
    @Published var multiplePeople = false
    @Published var completedURL: URL?
    let session = AVCaptureSession()
    private let movie = AVCaptureMovieFileOutput()
    private let video = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label:"movegrow.camera")
    private let visionQueue = DispatchQueue(label:"movegrow.vision")
    private let context = CIContext()
    private var configured = false
    private var lastAnalysis = 0.0
    private var history: [EnvironmentChecks] = []
    private var timer: Timer?
    private var began: Date?
    private var observer: NSObjectProtocol?
    private var sessionGeneration = UUID()
    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(forName:AVCaptureSession.wasInterruptedNotification,object:session,queue:.main) { [weak self] _ in
            self?.stopRecording()
            self?.error = "Recording was interrupted. Any completed video will be saved."
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; timer?.invalidate() }
    func start() {
        let generation = UUID(); sessionGeneration = generation
        AVCaptureDevice.requestAccess(for:.video) { [weak self] granted in
            guard let self else { return }
            DispatchQueue.main.async {
            guard self.sessionGeneration == generation else { return }
            guard granted else { self.denied = true; return }
            self.denied = false
            self.queue.async {
                do {
                    if !self.configured {
                        self.session.beginConfiguration()
                        defer { self.session.commitConfiguration() }
                        self.session.sessionPreset = .hd1280x720
                        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back) else {
                            throw NSError(domain:"Camera",code:1,userInfo:[NSLocalizedDescriptionKey:"Use an iPhone with a rear camera to record."])
                        }
                        let input = try AVCaptureDeviceInput(device:device)
                        guard self.session.canAddInput(input),self.session.canAddOutput(self.movie),self.session.canAddOutput(self.video) else { throw CocoaError(.featureUnsupported) }
                        self.session.addInput(input)
                        self.video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]
                        self.video.alwaysDiscardsLateVideoFrames = true
                        self.video.setSampleBufferDelegate(self,queue:self.visionQueue)
                        self.session.addOutput(self.video); self.session.addOutput(self.movie)
                        self.configured = true
                    }
                    if !self.session.isRunning { self.session.startRunning() }
                    DispatchQueue.main.async { self.running = true }
                } catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
            }
            }
        }
    }
    func beginRecording() {
        guard running,!recording,!preparing else { return }
        do {
            try LocalFiles.prepare()
            let capacity = try LocalFiles.root.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard capacity > 150_000_000 else {
                error = "Free up some storage before recording."; return
            }
            let url = LocalFiles.url("recording-\(UUID()).mov")
            if let c = movie.connection(with:.video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            movie.maxRecordedDuration = CMTime(seconds:180,preferredTimescale:600)
            preparing = true; seconds = 0; completedURL = nil
            movie.startRecording(to:url,recordingDelegate:self)
        } catch { self.error = error.localizedDescription }
    }
    func stopRecording() { if movie.isRecording { movie.stopRecording() } }
    func stopSession() {
        sessionGeneration = UUID()
        stopRecording(); timer?.invalidate(); timer = nil
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
        running = false
    }
    var ready: Bool { checks.allClear && checks.missingCriticalJoints.isEmpty && !multiplePeople }


    var guidance: String {
        if multiplePeople { return "Keep just your baby in view." }
        if !checks.bodyOK { return "Bring your baby’s whole body into view." }
        if checks.missingCriticalJoints.contains(.nose) { return "Keep your baby’s head in view." }
        if !checks.lightingOK { return "Try a brighter, evenly lit spot." }
        if !checks.limbsOK { return "Keep both hands and feet in view." }
        if !checks.framingOK { return "Leave more room around the head, hands and feet." }
        return "You’re all set."
    }
}
extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,didStartRecordingTo fileURL: URL,from connections:[AVCaptureConnection]) {
        DispatchQueue.main.async {
            self.preparing = false; self.recording = true; self.began = Date()
            try? LocalFiles.protect(fileURL)
            if UIApplication.shared.applicationState != .active { self.stopRecording() }
            self.timer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in
                guard let self,let start = self.began else { return }; self.seconds = Date().timeIntervalSince(start)
            }
        }
    }
    func fileOutput(_ output:AVCaptureFileOutput,didFinishRecordingTo outputFileURL:URL,from connections:[AVCaptureConnection],error:Error?) {
        let success = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
        DispatchQueue.main.async {
            self.timer?.invalidate();self.timer = nil;self.recording = false;self.preparing = false
            if success { self.completedURL = outputFileURL }
            else { self.error = error?.localizedDescription ?? "We couldn’t finish this recording. Please try again." }
        }
    }
}
extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard time-lastAnalysis > 0.12, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = time
        let request = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(cvPixelBuffer:pixels,orientation:.right,options:[:]).perform([request])
        let all = request.results ?? []
        // Keep one visible body for the live overlay even if a caregiver briefly
        // enters frame. Pick the observation with the largest recognized-joint
        // footprint, matching MoveGrow' single-subject visual behavior.
        let selected = PoseDetection.largestObservation(all)
        let points = selected.map(PoseDetection.points) ?? [:]
        let frame = PoseFrame(timestamp:time,joints:points.mapValues { JointPoint(x:$0.x,y:$0.y,confidence:$0.confidence) })
        let light = PoseDetection.luminance(pixels,orientation:.right,context:context,points:points)
        let raw = EnvironmentValidator.evaluate(sceneLuma:light,bodyLuma:light,pose:points.isEmpty ? nil : frame)
        history.append(raw); if history.count > 5 { history.removeFirst() }
        // Three consecutive valid observations before the ready state; a missing
        // frame is reflected immediately in QC rather than inventing visibility.
        let stable = history.count >= 3 && history.suffix(3).allSatisfy { $0.allClear && $0.missingCriticalJoints.isEmpty }
        DispatchQueue.main.async {
            self.pose = points.isEmpty ? nil : frame;self.multiplePeople = all.count > 1
            self.checks = raw
            if raw.allClear && !stable { self.checks.framing = 0.8 }
        }
    }
}
