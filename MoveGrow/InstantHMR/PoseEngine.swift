// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Which pose engine analyses new videos. InstantHMR (3D, MHR body model) is the default whenever its
// models are in the app; YOLO26l-pose (2D) is the alternative and the fallback. Foundation only.

import Foundation

/// The InstantHMR Core ML models compiled into this build.
enum HMRModels {
    /// The one network MoveGrow ships: Medium. The other sizes (Small, Tiny, Nano) are not bundled or
    /// offered; their checkpoints are not licensed for distribution in the app (see INSTANTHMR.md).
    static let netName = "InstantHMRMediumNet"
    static let bodyName = "MHRBodyKeypoints"
    static func fitName(_ crops: Int) -> String { "InstantHMRFit\(crops)" }

    static func has(_ name: String) -> Bool {
        Bundle.main.url(forResource: name, withExtension: "mlmodelc") != nil
    }

    /// Kinematic-fit choices in this build: 2 crops, 1 crop, and 0 (network alone, always possible).
    /// Fixed for the app's lifetime (the bundle does not change).
    static let availableFits: [Int] = [2, 1].filter { has(fitName($0)) } + [0]
    static let isAvailable: Bool = has(netName) && has(bodyName)

    /// "Medium" (English; used in estimator IDs and files).
    static func shortName(_ net: String) -> String {
        net.replacingOccurrences(of: "InstantHMR", with: "").replacingOccurrences(of: "Net", with: "")
    }

    /// The model size as shown in the app (translated; `shortName` stays English for IDs and files).
    /// Tracks from development builds made with another size show its English name.
    static func displayName(_ net: String) -> String {
        net == netName ? tr("Medium") : shortName(net)
    }

    /// The kinematic fit as shown in the app. (Named apart from `fitName(_:)`: with the same name, a call
    /// without `long:` resolved to the model file name, so the 3D panel showed "fit: InstantHMRFit2".)
    static func fitLabel(_ crops: Int, long: Bool = false) -> String {
        switch crops {
        case 2: return long ? tr("2 crops (most accurate)") : tr("2 crops")
        case 1: return tr("1 crop")
        default: return long ? tr("Off (fastest)") : tr("Off")
        }
    }
}

enum PoseEngine: String, CaseIterable, Identifiable {
    case instantHMR = "instanthmr"
    case yolo

    var id: String { rawValue }
    static let storageKey = "poseEngine"

    var title: String {
        switch self {
        case .instantHMR: return tr("InstantHMR (3D)")
        case .yolo: return tr("YOLO (2D)")
        }
    }

    /// The engine chosen in Settings (InstantHMR unless the parent picked YOLO), if it can run here.
    static var current: PoseEngine {
        let chosen = UserDefaults.standard.string(forKey: storageKey).flatMap(PoseEngine.init(rawValue:)) ?? .instantHMR
        return chosen == .instantHMR && !HMRModels.isAvailable ? .yolo : chosen
    }

    /// Estimator ID new analyses ask for: the InstantHMR configuration, or nil for the YOLO chain.
    static var preferredEstimatorID: String? {
        current == .instantHMR ? HMRConfig.current.estimatorID : nil
    }

    static func isInstantHMR(_ estimatorID: String?) -> Bool { estimatorID?.hasPrefix(HMRConfig.prefix) == true }
}

/// One InstantHMR configuration. It is written into the memory's estimator ID, so a video's later
/// passes (and its 3D file) always use the settings its first pass used.
struct HMRConfig: Equatable {
    static let prefix = "instanthmr-"
    static let fitKey = "hmrFitCrops", fpsKey = "hmrMaxFPS"
    /// Frame-rate choices for InstantHMR analyses (the first pass runs at 15 and the second fills in).
    static let fpsChoices = [15, 30, 60]
    static let defaultFPS = 30

    var network: String          // e.g. "InstantHMRMediumNet"
    var fitCrops: Int            // 0, 1 or 2
    var maxFPS: Int              // analysed frames per second, at most

    /// "instanthmr-medium-fit2-r30"
    var estimatorID: String {
        "\(Self.prefix)\(HMRModels.shortName(network).lowercased())-fit\(fitCrops)-r\(maxFPS)"
    }

    init(network: String, fitCrops: Int, maxFPS: Int) {
        self.network = network
        self.fitCrops = fitCrops
        self.maxFPS = maxFPS
    }

    init?(estimatorID: String) {
        guard estimatorID.hasPrefix(Self.prefix) else { return nil }
        let parts = estimatorID.dropFirst(Self.prefix.count).split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[1].hasPrefix("fit"), parts[2].hasPrefix("r"),
              let fit = Int(parts[1].dropFirst(3)), let fps = Int(parts[2].dropFirst(1)), !parts[0].isEmpty else { return nil }
        network = "InstantHMR\(parts[0].prefix(1).uppercased())\(parts[0].dropFirst())Net"
        fitCrops = fit
        maxFPS = fps
    }

    /// Settings, with the defaults (Medium, 2-crop kinematic fit, 30 frames per second) and whatever this
    /// build actually contains. The network is always Medium.
    static var current: HMRConfig {
        let d = UserDefaults.standard
        let fits = HMRModels.availableFits
        let storedFit = d.object(forKey: fitKey) as? Int
        let fit = storedFit.flatMap { fits.contains($0) ? $0 : nil } ?? (fits.first ?? 0)
        let storedFPS = d.object(forKey: fpsKey) as? Int
        let fps = storedFPS.flatMap { fpsChoices.contains($0) ? $0 : nil } ?? defaultFPS
        return HMRConfig(network: HMRModels.netName, fitCrops: fit, maxFPS: fps)
    }

    /// Whether this build can run the configuration (its network and kinematic fit are bundled). False for
    /// analyses made in development builds with a model size the app no longer ships.
    var isRunnable: Bool {
        network == HMRModels.netName && HMRModels.isAvailable && (fitCrops == 0 || HMRModels.has(HMRModels.fitName(fitCrops)))
    }

    /// Frame-rate cap for AnalysisPlan.
    var planMaxFPS: Double { Double(maxFPS) }
}
