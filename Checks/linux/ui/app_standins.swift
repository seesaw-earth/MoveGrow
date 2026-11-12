// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
// Stand-ins for the app code the onboarding files and BabyFigure reach but that is too heavy to
// type-check on Linux (L10n with Date.FormatStyle, Theme with UIKit, ReviewPlayer, Memory, BatchImport).
// Same names, types and labels as the app's own declarations.
import SwiftUI

func tr(_ key: String, _ args: Any...) -> String { key }
func clock(_ seconds: Double) -> String { "" }

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "", english = "en", chinese = "zh-Hans", spanish = "es"
    var id: String { rawValue }
    static let storageKey = "appLanguage"
    var resolved: AppLanguage { self }
    var nativeName: String { rawValue }
    static func set(_ language: AppLanguage) {}
}

enum Limb: String, CaseIterable, Identifiable {
    case leftArm = "L_arm", rightArm = "R_arm", leftLeg = "L_leg", rightLeg = "R_leg"
    var id: String { rawValue }
    var color: Color { Color.mgSeries1 }
}

enum RecordingContext: String, Codable, CaseIterable, Identifiable {
    case supine, prone, held, sitting, standing, walking, other
    var id: String { rawValue }
}

final class BatchImporter {
    static let maxVideos = 10
    static let maxTotalSeconds = 20.0 * 60
}

extension Color {
    static let mgSage = Color(light: 0x4F6B4C, dark: 0x76936F)
    static let mgSageSoft = Color(light: 0xDCE6D3, dark: 0x2F3B2C)
    static let mgPaper = Color(light: 0xFBF8F4, dark: 0x161513)
    static let mgCard = Color(light: 0xF3ECE2, dark: 0x24221F)
    static let mgInk = Color(light: 0x3B332D, dark: 0xF3EDE6)
    static let mgSeries1 = Color(light: 0x2A78D6, dark: 0x3987E5)
    init(light: UInt32, dark: UInt32) { self.init(UIColor()) }
}
extension Font {
    static let mgDisplay = Font.system(.largeTitle, design: .serif).weight(.semibold)
    static let mgTitle = Font.system(.title2, design: .serif).weight(.semibold)
    static let mgSection = Font.system(.title3, design: .serif).weight(.semibold)
}
extension View {
    func mgCard(padding: CGFloat = 14, radius: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.mgCard))
    }
}

/// MoveGrow's 19 joints (Motor/MotorPose.swift), as MHR70.swift uses them.
enum MJ {
    static let count = 19
    static let nose = 0, leftEye = 1, rightEye = 2, leftEar = 3, rightEar = 4, neck = 5, root = 6
    static let leftShoulder = 7, rightShoulder = 8, leftElbow = 9, rightElbow = 10
    static let leftWrist = 11, rightWrist = 12, leftHip = 13, rightHip = 14
    static let leftKnee = 15, rightKnee = 16, leftAnkle = 17, rightAnkle = 18
}

/// The 3D track (InstantHMR/HMRTrack.swift), reduced to what BabyFigure reads.
struct HMRTrack: Sendable {
    var times: [Double] = []
    var valid: [Bool] = []
    var j3d: [Float] = []
    static let J = 70
    var count: Int { times.count }
    func point3D(_ t: Int, _ j: Int) -> SIMD3<Float> {
        let o = (t * Self.J + j) * 3
        return SIMD3(j3d[o], j3d[o + 1], j3d[o + 2])
    }
}
