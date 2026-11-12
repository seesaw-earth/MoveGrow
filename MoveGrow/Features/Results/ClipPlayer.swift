// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import AVKit

// Simple clip player used by the milestone editor.

/// Playback time, observed only by the skeleton overlay, so the rest of the screen does not
/// re-render ten times a second while a video plays.
@MainActor final class PlaybackClock: ObservableObject {
    @Published var time = 0.0
}

@MainActor final class ClipPlayer: ObservableObject {
    let player: AVPlayer
    let clock = PlaybackClock()
    private var boundary: Any?
    private var observer: Any?
    private var seekID = UUID()
    private(set) var position = 0.0
    @Published var playingClip = false
    init(url:URL) {
        player = AVPlayer(url:url)
        observer = player.addPeriodicTimeObserver(forInterval:CMTime(seconds:1.0/15,preferredTimescale:600),queue:.main) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.position = seconds
                self.clock.time = seconds
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
