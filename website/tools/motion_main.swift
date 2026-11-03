// MoveGrow website — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Makes website/data/<fixture>.json, the motion the home page's hero replays: 15 fps COCO-17
// keypoints (normalised, -1 = not detected) and the smoothed per-limb speed and "moving" flags
// that MotorKit computes, 4 values a second. Built against the MotorKit sources (PoseBinary,
// MotorDigestBuilder, SeriesMath) on a Swift toolchain, then run from the repository root:
//
//   motion rhythmic_kicking_bilateral 10 10 .     (fixture, start s, length s, repository root)
//
// The fixtures in Tests/MotorKitTests/Fixtures are simulated babies, not recordings of real ones.
import Foundation
@main struct Motion {
    static func main() throws {
        let root = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "."
        let name = CommandLine.arguments[1]
        let start = Double(CommandLine.arguments[2])!
        let span = Double(CommandLine.arguments[3])!
        let t = try PoseBinary.decode(Data(contentsOf: URL(fileURLWithPath: root + "/Tests/MotorKitTests/Fixtures/\(name).mgpose")))
        let g = MotorDigestBuilder.make(track: t, aspect: 9.0 / 16)!
        let fps = 15.0
        var frames: [[Any]] = []
        var k = 0.0
        while k < span {
            let time = start + k
            if let i = t.frame(near: time) {
                var j: [Double] = []
                for n in 0..<17 {   // COCO joints only (MJ order minus neck/root)
                    let idx = [0,1,2,3,4,7,8,9,10,11,12,13,14,15,16,17,18][n]
                    let x = Double(t.x(i, idx)), y = Double(t.y(i, idx)), c = Double(t.conf(i, idx))
                    j.append(c >= 0.3 && x.isFinite ? (x * 1000).rounded() / 1000 : -1)
                    j.append(c >= 0.3 && y.isFinite ? (y * 1000).rounded() / 1000 : -1)
                }
                frames.append(j)
            } else { frames.append([]) }
            k += 1 / fps
        }
        func series(_ key: String) -> [Double] {
            let v = SeriesMath.smooth(g.speed[key]?.values ?? [], max(1, Int((1.0 / g.bin).rounded())))
            return (0..<Int(span * 4)).map { q in
                let tt = start + Double(q) / 4
                guard let b = g.bin(at: tt) else { return -1 }
                let x = Double(v[b]); return x.isFinite ? (x * 1000).rounded() / 1000 : -1
            }
        }
        func active(_ key: String) -> [Int] {
            (0..<Int(span * 4)).map { q in
                let tt = start + Double(q) / 4
                guard let b = g.bin(at: tt), let s = g.active[key], b < s.count, s.values[b].isFinite else { return 0 }
                return s.values[b] >= 0.5 ? 1 : 0
            }
        }
        let out: [String: Any] = ["fps": fps, "frames": frames, "scale": g.speedScale,
            "speed": ["L_arm": series("L_arm"), "R_arm": series("R_arm"), "L_leg": series("L_leg"), "R_leg": series("R_leg")],
            "active": ["L_arm": active("L_arm"), "R_arm": active("R_arm"), "L_leg": active("L_leg"), "R_leg": active("R_leg")],
            "duration": t.header.durationSeconds]
        try JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: "website/data/\(name).json"))
        print(name, frames.count, "frames, duration", t.header.durationSeconds, "scale", g.speedScale)
    }
}
