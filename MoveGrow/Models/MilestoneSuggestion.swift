// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum MilestoneSuggestionKind: String, Codable, Hashable, CaseIterable {
    case handsToMouth
    case movesArmsAndLegs

    var title: String {
        switch self {
        case .handsToMouth: return "Brings hands to mouth"
        case .movesArmsAndLegs: return "Moves both arms and legs"
        }
    }

    var symbol: String {
        switch self {
        case .handsToMouth: return "hand.raised"
        case .movesArmsAndLegs: return "figure.child"
        }
    }
}

enum MilestoneSuggestionStatus: String, Codable, Hashable {
    case suggested
    case confirmed
    case dismissed
}

/// A candidate movement located from the pose time series. `score` is a model
/// match score (0...1), not a calibrated probability or developmental score.
struct MilestoneSuggestion: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: MilestoneSuggestionKind
    var start: Double
    var end: Double
    var score: Double
    var status: MilestoneSuggestionStatus = .suggested
    var classifierVersion: String = "pose-events-v1"
    var momentID: UUID?
    var title: String { kind.title }
}
