// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Anatomical body frame and per-frame posture descriptors (reference: bodyframe.py, posture.py).

import Foundation

/// Body coordinates: u points to the baby's anatomical LEFT, v is cranial, unit = torso length.
struct MotorBodyFrame {
    var px: [[Double]], py: [[Double]]   // isotropic image coords (height units), [joint][t]
    var bu: [[Double]], bv: [[Double]]   // body coords, centroid origin
    var cx: [Double], cy: [Double]       // unsmoothed torso centroid (image)
    var L: [Double]                      // smoothed torso length
    var LRaw: [Double]
    var LSession: Double
    var valid: [Bool]
    var shoulderWidth: Double
    var hipWidth: Double

    init(_ s: MotorSeries, smoothS: Double = 0.5) {
        let T = s.count, J = MJ.count
        px = (0..<J).map { j in s.x[j].map { $0 * s.aspect } }
        py = s.y
        let lsx = px[MJ.leftShoulder], lsy = py[MJ.leftShoulder], rsx = px[MJ.rightShoulder], rsy = py[MJ.rightShoulder]
        let lhx = px[MJ.leftHip], lhy = py[MJ.leftHip], rhx = px[MJ.rightHip], rhy = py[MJ.rightHip]
        var cx = [Double](repeating: .nan, count: T), cy = cx
        var ax = cx, ay = cx, lraw = cx
        var valid = [Bool](repeating: false, count: T)
        for t in 0..<T {
            let mshx = 0.5 * (lsx[t] + rsx[t]), mshy = 0.5 * (lsy[t] + rsy[t])
            let mhpx = 0.5 * (lhx[t] + rhx[t]), mhpy = 0.5 * (lhy[t] + rhy[t])
            cx[t] = 0.25 * (((lsx[t] + rsx[t]) + lhx[t]) + rhx[t])
            cy[t] = 0.25 * (((lsy[t] + rsy[t]) + lhy[t]) + rhy[t])
            ax[t] = mshx - mhpx; ay[t] = mshy - mhpy
            lraw[t] = (ax[t] * ax[t] + ay[t] * ay[t]).squareRoot()
            valid[t] = lraw[t].isFinite && lraw[t] > 1e-4
        }
        let win = max(1, MM.pyRound(smoothS * s.fs) | 1)
        var ang = (0..<T).map { atan2(ay[$0], ax[$0]) }
        let validIdx = (0..<T).filter { valid[$0] }
        if !validIdx.isEmpty {
            let unwrapped = MM.unwrap(validIdx.map { ang[$0] })
            for (k, i) in validIdx.enumerated() { ang[i] = unwrapped[k] }
        }
        let angS = MM.rollingNanMedian((0..<T).map { valid[$0] ? ang[$0] : .nan }, win)
        let LS = MM.rollingNanMedian((0..<T).map { valid[$0] ? lraw[$0] : .nan }, win)
        let vx = angS.map(cos), vy = angS.map(sin)
        var sgn = [Double](repeating: .nan, count: T)
        for t in 0..<T {
            let perpX = -vy[t], perpY = vx[t]
            let d = (lsx[t] - rsx[t]) * perpX + (lsy[t] - rsy[t]) * perpY
            sgn[t] = valid[t] ? (d.isNaN ? .nan : (d > 0 ? 1 : (d < 0 ? -1 : 0))) : .nan
        }
        let sgnWin = max(win, Int(s.fs) | 1)
        sgn = MM.rollingNanMedian(sgn, sgnWin).map { ($0.isFinite && $0 != 0) ? ($0 > 0 ? 1 : -1) : 1 }
        var ux = [Double](repeating: .nan, count: T), uy = ux
        for t in 0..<T { ux[t] = -vy[t] * sgn[t]; uy[t] = vx[t] * sgn[t] }
        let Ls = LS.contains { $0.isFinite } ? MM.nanMedian(LS) : .nan
        var bu = [[Double]](), bv = [[Double]]()
        for j in 0..<J {
            var u = [Double](repeating: .nan, count: T), v = u
            for t in 0..<T where valid[t] {
                let rx = px[j][t] - cx[t], ry = py[j][t] - cy[t]
                u[t] = (rx * ux[t] + ry * uy[t]) / Ls
                v[t] = (rx * vx[t] + ry * vy[t]) / Ls
            }
            bu.append(u); bv.append(v)
        }
        self.bu = bu; self.bv = bv; self.cx = cx; self.cy = cy
        self.L = LS; self.LRaw = lraw; self.LSession = Ls; self.valid = valid
        self.shoulderWidth = MM.nanMedian((0..<T).map { abs(bu[MJ.leftShoulder][$0] - bu[MJ.rightShoulder][$0]) })
        self.hipWidth = MM.nanMedian((0..<T).map { abs(bu[MJ.leftHip][$0] - bu[MJ.rightHip][$0]) })
    }
}

/// Interior angle at b (degrees) for per-frame points; 180 = straight.
func motorJointAngle(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ cx: Double, _ cy: Double) -> Double {
    let v1x = ax - bx, v1y = ay - by, v2x = cx - bx, v2y = cy - by
    let n = (v1x * v1x + v1y * v1y).squareRoot() * (v2x * v2x + v2y * v2y).squareRoot()
    let c = (v1x * v2x + v1y * v2y) / (n > 1e-9 ? n : .nan)
    return MM.degrees(acos(MM.clip(c, -1, 1)))
}

/// Per-frame posture features (feature catalog `frame` level).
enum MotorPosture {
    static func features(_ bf: MotorBodyFrame, headRPrior: Double = 0.30) -> [String: [Double]] {
        let T = bf.valid.count
        let u = bf.bu, v = bf.bv
        var f: [String: [Double]] = [:]
        let nose = MJ.nose, le = MJ.leftEye, re = MJ.rightEye, lear = MJ.leftEar, rear = MJ.rightEar
        let ls = MJ.leftShoulder, rs = MJ.rightShoulder
        var bothEars = [Bool](repeating: false, count: T)
        var centerU = [Double](repeating: .nan, count: T), spread = centerU
        for t in 0..<T {
            bothEars[t] = u[lear][t].isFinite && u[rear][t].isFinite
            let earMid = 0.5 * (u[lear][t] + u[rear][t])
            let msh = 0.5 * (u[ls][t] + u[rs][t])
            centerU[t] = bothEars[t] ? earMid : msh
            spread[t] = 0.5 * abs(u[lear][t] - u[rear][t])
        }
        var headR = headRPrior
        if bothEars.filter({ $0 }).count >= 30 {
            let r = MM.nanPercentile((0..<T).filter { bothEars[$0] }.map { spread[$0] }, 90)
            headR = (r > 0.12 && r < 0.6) ? r : headRPrior
        }
        let yaw = (0..<T).map { MM.clip((u[nose][$0] - centerU[$0]) / headR, -1.2, 1.2) }
        f["head_yaw_sin"] = yaw
        f["head_center_from_ears"] = bothEars.map { $0 ? 1 : 0 }
        f["head_tilt_deg"] = (0..<T).map { t in
            let aEye = MM.degrees(atan2(v[le][t] - v[re][t], u[le][t] - u[re][t]))
            let aSh = MM.degrees(atan2(v[ls][t] - v[rs][t], u[ls][t] - u[rs][t]))
            let tilt = MM.pyMod(aEye - aSh + 180.0, 360.0) - 180.0
            return abs(yaw[t]) > 0.5 ? .nan : tilt
        }
        for (side, s) in [("left", "L"), ("right", "R")] {
            let sh = MJ.index["\(side)Shoulder"]!, el = MJ.index["\(side)Elbow"]!, wr = MJ.index["\(side)Wrist"]!
            let hp = MJ.index["\(side)Hip"]!, kn = MJ.index["\(side)Knee"]!, an = MJ.index["\(side)Ankle"]!
            f["elbow_angle_\(s)"] = (0..<T).map { motorJointAngle(u[sh][$0], v[sh][$0], u[el][$0], v[el][$0], u[wr][$0], v[wr][$0]) }
            f["knee_angle_\(s)"] = (0..<T).map { motorJointAngle(u[hp][$0], v[hp][$0], u[kn][$0], v[kn][$0], u[an][$0], v[an][$0]) }
            let thx = (0..<T).map { u[kn][$0] - u[hp][$0] }, thy = (0..<T).map { v[kn][$0] - v[hp][$0] }
            f["thigh_abd_\(s)"] = (0..<T).map { t in
                let lat = s == "L" ? thx[t] : -thx[t]
                return MM.degrees(atan2(lat, -thy[t]))
            }
            let tl = (0..<T).map { (thx[$0] * thx[$0] + thy[$0] * thy[$0]).squareRoot() }
            let ref = tl.filter { $0.isFinite }.count > 10 ? MM.nanPercentile(tl, 90) : .nan
            f["thigh_flat_\(s)"] = tl.map { $0 / ref }
        }
        let lh = MJ.leftHip, rh = MJ.rightHip
        f["knee_spread"] = (0..<T).map { t in
            var hipw = u[lh][t] - u[rh][t]
            hipw = abs(hipw) > 0.05 ? hipw : .nan
            return (u[MJ.leftKnee][t] - u[MJ.rightKnee][t]) / hipw
        }
        f["ankle_cross"] = (0..<T).map { u[MJ.leftAnkle][$0] - u[MJ.rightAnkle][$0] }
        let lw = MJ.leftWrist, rw = MJ.rightWrist
        f["hands_dist"] = (0..<T).map { t in
            let dx = u[lw][t] - u[rw][t], dy = v[lw][t] - v[rw][t]
            return (dx * dx + dy * dy).squareRoot()
        }
        f["hands_mid_u"] = (0..<T).map { MM.nanPropMax(abs(u[lw][$0]), abs(u[rw][$0])) }
        let eL = f["elbow_angle_L"]!, eR = f["elbow_angle_R"]!
        f["face_side_elbow"] = (0..<T).map { yaw[$0] > 0 ? eL[$0] : eR[$0] }
        f["occiput_side_elbow"] = (0..<T).map { yaw[$0] > 0 ? eR[$0] : eL[$0] }
        f["abs_head_yaw_sin"] = yaw.map { abs($0) }
        let pairs: [(String, String, String, Bool)] = [
            ("min_thigh_abd", "thigh_abd_L", "thigh_abd_R", true), ("min_thigh_flat", "thigh_flat_L", "thigh_flat_R", true),
            ("min_knee_angle", "knee_angle_L", "knee_angle_R", true), ("max_knee_angle", "knee_angle_L", "knee_angle_R", false),
        ]
        for (name, a, b, isMin) in pairs {
            let A = f[a]!, B = f[b]!
            f[name] = (0..<T).map { isMin ? MM.nanPropMin(A[$0], B[$0]) : MM.nanPropMax(A[$0], B[$0]) }
        }
        f["_head_r"] = [Double](repeating: headR, count: T)
        return f
    }
}
