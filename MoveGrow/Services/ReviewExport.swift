// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// What an exported MP4 contains and where everything goes (no drawing here, so it is checked on
// Linux too). With nothing but the video (and optionally the skeleton) the export is the plain
// video. With the date or the charts it becomes a small report: a header with the baby's age and
// the date, the video, and under it the parameter charts on the same time axis as the review
// screen, with a cursor that moves with the video and the current values beside each chart.
// Portrait reports fit a phone screen (9 : 19.5) so they play full screen without cropping.

import Foundation

/// A chart in the export (the review timeline's tracks, minus tracking and events).
enum ExportRow: String, CaseIterable, Identifiable, Hashable, Codable {
    case arms, legs, elbows, knees, balance, head, motion

    var id: String { rawValue }
    static let defaults: [ExportRow] = [.arms, .legs, .elbows, .knees, .head]

    var title: String {
        switch self {
        case .arms: return tr("Arms")
        case .legs: return tr("Legs")
        case .elbows: return tr("Elbows")
        case .knees: return tr("Knees")
        case .balance: return tr("L · R")
        case .head: return tr("Head")
        case .motion: return tr("Motion")
        }
    }

    /// Track height in layout points.
    var height: Double {
        switch self {
        case .arms, .legs: return 34
        case .elbows, .knees, .motion: return 28
        case .balance: return 26
        case .head: return 22
        }
    }

    /// Fixed value range per kind, so exports of different videos compare by eye.
    func range(_ g: ReviewDigest) -> (lo: Double, hi: Double) {
        switch self {
        case .arms, .legs, .motion: return (0, max(0.3, g.speedScale * 1.1))
        case .elbows, .knees: return (40, 180)
        case .balance, .head: return (-1, 1)
        }
    }
}

/// The palette used in exports (the app's light-mode colours; a video has no dark mode).
enum ExportColor {
    static let paper: UInt32 = 0xFBF8F4, card: UInt32 = 0xF3ECE2, ink: UInt32 = 0x3B332D
    static let sage: UInt32 = 0x4F6B4C, gold: UInt32 = 0xA8843E, skeleton: UInt32 = 0xBFE0AE
    static let videoBack: UInt32 = 0x1E1B18
    static let leftArm: UInt32 = 0x2A78D6, rightArm: UInt32 = 0xEB6834, leftLeg: UInt32 = 0x1BAF7A, rightLeg: UInt32 = 0xEDA100
    static func limb(_ key: String) -> UInt32 {
        switch key {
        case "L_arm": return leftArm
        case "R_arm": return rightArm
        case "L_leg": return leftLeg
        default: return rightLeg
        }
    }
}

struct ReviewExportOptions: Hashable {
    enum Quality: String, CaseIterable, Hashable {
        /// 720 px wide (portrait) / 1280 (landscape), at most 30 fps.
        case standard
        /// 1080 px wide (portrait) / 1920 (landscape), the video's own frame rate up to 60 fps.
        case high
    }

    var skeleton = true
    var charts = true
    var caption = true
    var sound = true
    var quality = Quality.high
    var rows: [ExportRow] = ExportRow.defaults
    /// Part of the video, in seconds.
    var start = 0.0
    var end = 0.0

    var duration: Double { max(0, end - start) }
    /// A report frame (header and/or charts) rather than the bare video.
    var framed: Bool { caption || (charts && !rows.isEmpty) }
    var showsCharts: Bool { charts && !rows.isEmpty }
}

/// One line of a chart, smoothed like the review timeline (≈1 s).
struct ExportLine: Hashable {
    var values: [Float]
    var color: UInt32
    var dashed: Bool
    var alpha: Double = 1
    subscript(i: Int) -> Float { i >= 0 && i < values.count ? values[i] : .nan }
}

enum ExportData {
    static func lines(_ row: ExportRow, _ g: ReviewDigest) -> [ExportLine] {
        let k = max(1, Int((1.0 / g.bin).rounded()))
        func s(_ key: String, _ dashed: Bool) -> ExportLine? {
            g.speed[key].map { ExportLine(values: SeriesMath.smooth($0.values, k), color: ExportColor.limb(key), dashed: dashed) }
        }
        func a(_ key: String, _ limb: String, _ dashed: Bool) -> ExportLine? {
            g.angle[key].map { ExportLine(values: SeriesMath.smooth($0.values, k), color: ExportColor.limb(limb), dashed: dashed) }
        }
        switch row {
        case .arms: return [s("L_arm", false), s("R_arm", true)].compactMap { $0 }
        case .legs: return [s("L_leg", false), s("R_leg", true)].compactMap { $0 }
        case .elbows: return [a("elbow_L", "L_arm", false), a("elbow_R", "R_arm", true)].compactMap { $0 }
        case .knees: return [a("knee_L", "L_leg", false), a("knee_R", "R_leg", true)].compactMap { $0 }
        // The balance series is already a 1.5 s ratio.
        case .balance: return [ExportLine(values: g.armBalanceSeries.values, color: ExportColor.ink, dashed: false),
                               ExportLine(values: g.legBalanceSeries.values, color: ExportColor.ink, dashed: true, alpha: 0.6)]
        case .head: return [ExportLine(values: SeriesMath.smooth(g.headYaw.values, k), color: ExportColor.ink, dashed: false)]
        case .motion: return [ExportLine(values: SeriesMath.smooth(g.motion.values, k), color: ExportColor.sage, dashed: false)]
        }
    }

    /// The values beside a chart at bin `i`, one per line: ["L 152°", "R 140°"], ["arms +0.21", "legs −0.05"],
    /// ["left 0.4"], ["0.38"] (in the app's language). A missing value reads "–".
    static func values(_ row: ExportRow, _ lines: [ExportLine], bin i: Int?) -> [(text: String, color: UInt32)] {
        func v(_ k: Int) -> Double? {
            guard let i, k < lines.count else { return nil }
            let x = Double(lines[k][i])
            return x.isFinite ? x : nil
        }
        func color(_ k: Int) -> UInt32 { k < lines.count ? lines[k].color : ExportColor.ink }
        func signed(_ x: Double) -> String {
            x >= 0.005 ? "+" + L10n.number(x) : (x <= -0.005 ? "−" + L10n.number(-x) : L10n.number(0))
        }
        func degrees(_ x: Double) -> String { "\(Int(x.rounded()))°" }
        switch row {
        case .arms, .legs:
            return [(tr("L %@", v(0).map { L10n.number($0) } ?? "–"), color(0)),
                    (tr("R %@", v(1).map { L10n.number($0) } ?? "–"), color(1))]
        case .elbows, .knees:
            return [(tr("L %@", v(0).map(degrees) ?? "–"), color(0)),
                    (tr("R %@", v(1).map(degrees) ?? "–"), color(1))]
        case .balance:
            return [(tr("arms %@", v(0).map(signed) ?? "–"), ExportColor.ink), (tr("legs %@", v(1).map(signed) ?? "–"), ExportColor.ink)]
        case .head:
            // Positive = turned to the baby's own left.
            guard let y = v(0) else { return [("–", ExportColor.ink)] }
            if abs(y) < 0.1 { return [(tr("ahead"), ExportColor.ink)] }
            return [(y > 0 ? tr("left %@", L10n.number(y, digits: 1)) : tr("right %@", L10n.number(-y, digits: 1)),
                     y > 0 ? ExportColor.leftArm : ExportColor.rightArm)]
        case .motion:
            return [(v(0).map { L10n.number($0) } ?? "–", ExportColor.sage)]
        }
    }

    static let limbs = ["L_arm", "R_arm", "L_leg", "R_leg"]

    /// Whether each limb moves in bin `i` (share of active frames ≥ ½); limbs without data are absent.
    static func moving(_ g: ReviewDigest, bin i: Int?) -> [String: Bool] {
        var out: [String: Bool] = [:]
        guard let i else { return out }
        for key in limbs {
            guard let s = g.active[key], i < s.count, s.values[i].isFinite else { continue }
            out[key] = s.values[i] >= 0.5
        }
        return out
    }
}

/// Where everything goes, in layout points (`unit` pixels each).
struct ExportLayout: Equatable {
    static let margin = 12.0
    /// Room for chart names and values (Spanish words are longer).
    static var labelWidth: Double { L10n.language == .spanish ? 62 : 48 }
    static var valueWidth: Double { L10n.language == .spanish ? 74 : 60 }
    static let headerHeight = 46.0
    static let readoutHeight = 28.0
    static let rowGap = 6.0
    static let axisHeight = 14.0
    static let footerHeight = 30.0
    /// Tallest portrait report: a phone screen.
    static let maxPortraitRatio = 19.5 / 9

    var unit: Double
    /// Canvas in points; `pixelWidth` × `pixelHeight` in pixels (both even).
    var size: CGSize
    var pixelWidth: Int
    var pixelHeight: Int
    var framed: Bool
    var header: CGRect?
    var video: CGRect
    var panel: CGRect?
    var readout: CGRect?
    var rows: [ExportRow]
    var rowRects: [CGRect]
    var axis: CGRect?
    var footer: CGRect?

    /// The video area in pixels (even), the size frames are decoded at.
    var videoPixelWidth: Int { Self.even(video.width * unit) }
    var videoPixelHeight: Int { Self.even(video.height * unit) }
    /// Left edge of the charts (after the labels) and their width.
    var chartMinX: Double { rowRects.first.map { Double($0.minX) } ?? 0 }
    var chartWidth: Double { rowRects.first.map { Double($0.width) } ?? 0 }

    static func even(_ x: Double) -> Int { max(2, Int((x / 2).rounded()) * 2) }

    static func panelHeight(_ rows: [ExportRow]) -> Double {
        10 + readoutHeight + 8 + rows.reduce(0) { $0 + $1.height } + rowGap * Double(max(0, rows.count - 1)) + 6 + axisHeight + footerHeight + 4
    }

    /// `aspect` = displayed width / height of the video.
    static func make(aspect raw: Double, options o: ReviewExportOptions) -> ExportLayout {
        let aspect = raw.isFinite && raw > 0.2 && raw < 5 ? raw : 9.0 / 16.0
        let design = aspect >= 1.2 ? 640.0 : (aspect >= 0.85 ? 420.0 : 360.0)
        let unit = o.quality == .high ? 3.0 : 2.0
        let rows = o.showsCharts ? o.rows : []
        guard o.framed else {
            let size = CGSize(width: design, height: design / aspect)
            return ExportLayout(unit: unit, size: size, pixelWidth: even(design * unit), pixelHeight: even(design / aspect * unit),
                                framed: false, header: nil, video: CGRect(origin: .zero, size: size), panel: nil, readout: nil,
                                rows: [], rowRects: [], axis: nil, footer: nil)
        }
        let m = margin, cw = design - 2 * m
        var y = 8.0
        var header: CGRect?
        if o.caption {
            header = CGRect(x: m, y: y, width: cw, height: headerHeight)
            y += headerHeight
        } else {
            y += 4
        }
        let panelH = rows.isEmpty ? 0 : panelHeight(rows) + 8
        var vw = cw, vh = cw / aspect
        if aspect < 1 {
            let room = design * maxPortraitRatio - y - panelH - 8
            if vh > room { vh = max(room, cw * 0.75); vw = vh * aspect }
        }
        let video = CGRect(x: m + (cw - vw) / 2, y: y, width: vw, height: vh)
        y += vh
        var panel: CGRect?, readout: CGRect?, axis: CGRect?, footer: CGRect?
        var rects: [CGRect] = []
        if !rows.isEmpty {
            y += 8
            let p = CGRect(x: m, y: y, width: cw, height: panelHeight(rows))
            panel = p
            let inner = p.insetBy(dx: 10, dy: 0)
            var ry = p.minY + 10
            readout = CGRect(x: inner.minX, y: ry, width: inner.width, height: readoutHeight)
            ry += readoutHeight + 8
            let chartX = inner.minX + labelWidth, chartW = inner.width - labelWidth - valueWidth
            for (k, row) in rows.enumerated() {
                rects.append(CGRect(x: chartX, y: ry, width: chartW, height: row.height))
                ry += row.height + (k == rows.count - 1 ? 0 : rowGap)
            }
            ry += 6
            axis = CGRect(x: chartX, y: ry, width: chartW, height: axisHeight)
            ry += axisHeight
            footer = CGRect(x: inner.minX, y: ry, width: inner.width, height: footerHeight)
            y = p.maxY
        }
        y += 8
        let size = CGSize(width: design, height: y)
        return ExportLayout(unit: unit, size: size, pixelWidth: even(design * unit), pixelHeight: even(y * unit),
                            framed: true, header: header, video: video, panel: panel, readout: readout,
                            rows: rows, rowRects: rects, axis: axis, footer: footer)
    }

    /// x of time `t` on the charts, for the exported part [start, end].
    func x(_ t: Double, start: Double, end: Double) -> Double {
        let f = min(max(0, (t - start) / max(end - start, 0.1)), 1)
        return chartMinX + f * chartWidth
    }

    static func y(_ v: Double, in r: CGRect, range: (lo: Double, hi: Double)) -> Double {
        let f = (min(max(v, range.lo), range.hi) - range.lo) / max(1e-9, range.hi - range.lo)
        return Double(r.maxY) - f * Double(r.height)
    }
}

enum ExportTiming {
    /// Output frame rate: the video's own (rounded), at most 30 fps for standard and 60 for high.
    static func fps(source: Double, quality: ReviewExportOptions.Quality) -> Int {
        let s = source.isFinite && source >= 10 ? source : 30
        return Int(min(s, quality == .high ? 60 : 30).rounded())
    }

    static func bitRate(width: Int, height: Int, fps: Int) -> Int {
        let r = Double(width * height * fps) * 0.07
        return Int(min(max(r, 2_500_000), 16_000_000))
    }

    /// Rough file size in bytes (video at its bit rate plus 128 kb/s sound).
    static func estimatedBytes(layout: ExportLayout, fps: Int, seconds: Double, sound: Bool) -> Double {
        let bits = Double(bitRate(width: layout.pixelWidth, height: layout.pixelHeight, fps: fps)) * 0.75 + (sound ? 128_000 : 0)
        return bits * max(0, seconds) / 8
    }
}

enum ExportNaming {
    /// "MoveGrow Mia 45 days old 2026-03-03.mp4" — letters, digits, spaces and dashes only. No date
    /// when the filming date isn't known.
    static func filename(babyName: String?, age: String?, date: Date?, calendar cal: Calendar = .current) -> String {
        let day = date.map { d -> String in
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        let parts = [babyName, age.map { $0.replacingOccurrences(of: "·", with: " ") }, day].compactMap { $0 }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -"))
        var name = parts.joined(separator: " ").unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return (name.isEmpty ? "MoveGrow" : "MoveGrow " + name) + ".mp4"
    }
}

extension PoseTrack {
    /// Nearest analysed frame to `time` (binary search); nil across a detector gap (> 0.15 s) or in poor light.
    func frame(near time: Double) -> Int? {
        let ts = times
        guard !ts.isEmpty, time.isFinite else { return nil }
        var lo = 0, hi = ts.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if ts[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        let i = lo > 0 && abs(ts[lo - 1] - time) <= abs(ts[lo] - time) ? lo - 1 : lo
        return abs(ts[i] - time) <= 0.15 && lightOK[i] ? i : nil
    }
}
