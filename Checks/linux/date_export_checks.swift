// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Video dates (exact / days old / approximate, labels, migration) and the MP4 export's layout,
// values, timing and file names.
import Foundation

enum DateExportChecks {
    static func check(_ ok: Bool, _ what: String) {
        precondition(ok, what)
        print("  ✓", what)
    }

    static func run() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }
        func ymd(_ d: Date) -> [Int] { let c = cal.dateComponents([.year, .month, .day, .hour], from: d); return [c.year!, c.month!, c.day!, c.hour!] }
        let born = day(2026, 1, 10, 7)
        let now = day(2026, 6, 1, 9)

        // Resolution.
        check(ymd(DateSetting.daysOld(days: 45).resolved(birthday: born, now: now, calendar: cal)!) == [2026, 2, 24, 12], "45 days old → Feb 24 (noon)")
        check(ymd(DateSetting.daysOld(days: 0).resolved(birthday: born, now: now, calendar: cal)!) == [2026, 1, 10, 12], "day 0 = birthday")
        check(ymd(DateSetting.aboutWeeks(weeks: 6).resolved(birthday: born, now: now, calendar: cal)!) == [2026, 2, 21, 12], "about 6 weeks → Feb 21")
        check(ymd(DateSetting.aboutMonths(months: 3).resolved(birthday: born, now: now, calendar: cal)!) == [2026, 4, 10, 12], "about 3 months → Apr 10")
        check(ymd(DateSetting.inMonth(year: 2026, month: 3).resolved(birthday: born, now: now, calendar: cal)!) == [2026, 3, 15, 12], "March 2026 → mid-month")
        check(ymd(DateSetting.inMonth(year: 2026, month: 1).resolved(birthday: day(2026, 1, 20), now: now, calendar: cal)!)[0...2] == [2026, 1, 20], "birth month: not before birth")
        check(DateSetting.inMonth(year: 2026, month: 6).resolved(birthday: born, now: now, calendar: cal)! <= now, "current month: not after today")
        check(DateSetting.daysOld(days: 9000).resolved(birthday: born, now: now, calendar: cal)! == now, "never in the future")
        check(DateSetting.daysOld(days: 3).resolved(birthday: nil, now: now, calendar: cal) == nil, "age needs a birthday")
        check(DateSetting.inMonth(year: 2026, month: 2).resolved(birthday: nil, now: now, calendar: cal) != nil, "a month needs no birthday")
        let exact = day(2026, 2, 2, 15)
        check(DateSetting.exact(date: exact).resolved(birthday: born, now: now, calendar: cal) == exact, "exact day kept as chosen")
        check(DateSetting.aboutWeeks(weeks: 2).isApproximate && !DateSetting.daysOld(days: 2).isApproximate
              && DateSetting.daysOld(days: 2).followsBirthday && !DateSetting.inMonth(year: 2026, month: 1).followsBirthday,
              "approximate / follows-birthday flags")

        // Labels.
        let baby = Baby(name: "Mia", birthday: born)
        var m = Memory(id: UUID(), date: day(2026, 2, 24, 16), title: "t", duration: 5, filename: "a.mov")
        m.capturedDate = m.date; m.dateOrigin = .metadata
        check(m.dateText.contains("2026") && m.ageText(baby) == baby.age(on: m.date) && m.filmedDate == m.date && !m.needsDate,
              "filmed date: full date, age, can go back to it")
        m.dateSetting = .daysOld(days: 45); m.date = m.dateSetting!.resolved(birthday: born, now: now, calendar: cal)!
        check(m.ageText(baby) == "45 days old" && m.shortAge(baby) == "45 d" && m.datePrecision == .day, "days old label")
        m.dateSetting = .aboutWeeks(weeks: 6); m.date = m.dateSetting!.resolved(birthday: born, now: now, calendar: cal)!
        check(m.ageText(baby) == "About 6 weeks old" && m.shortAge(baby) == "~6 wk" && m.dateText.hasPrefix("Around ") && m.dateIsApproximate,
              "about 6 weeks: \(m.ageText(baby) ?? "-") · \(m.shortAge(baby) ?? "-") · \(m.dateText)")
        m.dateSetting = .aboutMonths(months: 1); m.date = m.dateSetting!.resolved(birthday: born, now: now, calendar: cal)!
        check(m.ageText(baby) == "About 1 month old", "about 1 month (singular)")
        m.dateSetting = .inMonth(year: 2026, month: 4); m.date = m.dateSetting!.resolved(birthday: born, now: now, calendar: cal)!
        check(m.ageText(baby) == "About 3 months old" && !m.dateText.hasPrefix("Around"), "sometime in April: \(m.ageText(baby)!) · \(m.dateText)")
        let preterm = Baby(name: "P", birthday: born, dueDate: day(2026, 3, 1))
        m.dateSetting = .aboutWeeks(weeks: 10); m.date = m.dateSetting!.resolved(birthday: born, now: now, calendar: cal)!
        check(m.ageText(preterm)?.contains("corrected ~") == true, "preterm: approximate corrected age (\(m.ageText(preterm)!))")
        var unknown = Memory(id: UUID(), date: now, title: "t", duration: 5, filename: "b.mov")
        unknown.capturedDate = now; unknown.dateOrigin = .unknown
        check(unknown.needsDate && unknown.dateText == "Date unknown" && unknown.ageText(baby) == nil && unknown.shortAge(baby) == nil
              && unknown.filmedDate == nil, "no date in the file: asks for one")
        let legacy = Memory(id: UUID(), date: exact, title: "t", duration: 5, filename: "c.mov")
        check(!legacy.needsDate && legacy.filmedDate == exact, "older memories: their date is the filming date")

        // Storage.
        for s in [DateSetting.exact(date: exact), .daysOld(days: 45), .aboutWeeks(weeks: 6), .aboutMonths(months: 3), .inMonth(year: 2026, month: 3)] {
            var x = m; x.dateSetting = s; x.dateOrigin = .unknown
            let back = try JSONDecoder().decode(Memory.self, from: try JSONEncoder().encode(x))
            precondition(back.dateSetting == s && back.dateOrigin == .unknown, "round trip \(s)")
        }
        check(true, "date settings round-trip through album JSON")

        // Capture dates in files.
        let parsed = CaptureDate.parse("2026-03-03T16:12:45+0800")
        check(parsed.map { abs($0.timeIntervalSince1970 - 1_772_525_565) < 1 } == true, "QuickTime creation date with +0800 offset")
        check(CaptureDate.parse("2026-03-03T08:12:45Z") == parsed, "ISO 8601 UTC")
        check(CaptureDate.plausible(Date(timeIntervalSince1970: -2_082_844_800)) == nil && CaptureDate.plausible(Date(timeIntervalSince1970: 0)) == nil
              && CaptureDate.plausible(Date().addingTimeInterval(3 * 86_400)) == nil && CaptureDate.plausible(parsed) == parsed,
              "placeholder dates (1904, 1970, future) are ignored")

        // Export layout.
        var o = ReviewExportOptions(); o.start = 0; o.end = 30
        let portrait = ExportLayout.make(aspect: 1080.0 / 1920, options: o)
        let canvas = CGRect(origin: .zero, size: portrait.size)
        check(portrait.pixelWidth == 1080 && portrait.pixelHeight <= 2342 && portrait.pixelHeight % 2 == 0 && portrait.framed,
              "portrait report \(portrait.pixelWidth)×\(portrait.pixelHeight) fits a phone screen")
        check(abs(Double(portrait.video.width / portrait.video.height) - 0.5625) < 0.01 && canvas.contains(portrait.video)
              && portrait.header.map { $0.maxY <= portrait.video.minY } == true, "video keeps its shape, below the header")
        let panel = portrait.panel!
        check(portrait.rowRects.count == 5 && portrait.rowRects.allSatisfy { panel.contains($0) } && panel.minY >= portrait.video.maxY
              && canvas.contains(panel) && portrait.axis!.minY >= portrait.rowRects.last!.maxY && panel.contains(portrait.footer!),
              "charts in the panel under the video")
        check(zip(portrait.rowRects, portrait.rowRects.dropFirst()).allSatisfy { $0.maxY <= $1.minY }, "charts don't overlap")
        check(abs(portrait.x(0, start: 0, end: 30) - portrait.chartMinX) < 1e-9
              && abs(portrait.x(30, start: 0, end: 30) - (portrait.chartMinX + portrait.chartWidth)) < 1e-9
              && abs(portrait.x(99, start: 0, end: 30) - (portrait.chartMinX + portrait.chartWidth)) < 1e-9, "time → x, clamped")
        let land = ExportLayout.make(aspect: 16.0 / 9, options: o)
        check(land.pixelWidth == 1920 && abs(Double(land.video.width) - 616) < 0.01, "landscape report 1920 wide (\(land.pixelWidth)×\(land.pixelHeight))")
        var plain = o; plain.caption = false; plain.charts = false
        let bare = ExportLayout.make(aspect: 1080.0 / 1920, options: plain)
        check(!bare.framed && bare.pixelWidth == 1080 && bare.pixelHeight == 1920 && bare.video == CGRect(origin: .zero, size: bare.size),
              "video only: plain 1080×1920")
        plain.quality = .standard
        let small = ExportLayout.make(aspect: 1080.0 / 1920, options: plain)
        check(small.pixelWidth == 720 && small.pixelHeight == 1280 && small.videoPixelWidth == 720, "standard quality 720×1280")
        var noRows = o; noRows.rows = []; noRows.caption = false
        check(!ExportLayout.make(aspect: 0.5625, options: noRows).framed, "charts with no parameters chosen = plain video")
        var captionOnly = o; captionOnly.charts = false
        let cap = ExportLayout.make(aspect: 0.5625, options: captionOnly)
        check(cap.framed && cap.panel == nil && cap.header != nil && cap.rowRects.isEmpty, "date & age only: header over the video")
        var tall = o; tall.rows = ExportRow.allCases
        let t = ExportLayout.make(aspect: 0.5625, options: tall)
        check(t.pixelHeight <= 2342 && t.rowRects.count == 7 && t.video.height > 300, "all seven charts still fit (\(t.pixelWidth)×\(t.pixelHeight), video \(Int(t.video.width))×\(Int(t.video.height)) pt)")

        // Timing, size, names.
        check(ExportTiming.fps(source: 59.94, quality: .high) == 60 && ExportTiming.fps(source: 59.94, quality: .standard) == 30
              && ExportTiming.fps(source: 24, quality: .high) == 24 && ExportTiming.fps(source: .nan, quality: .high) == 30
              && ExportTiming.fps(source: 240, quality: .high) == 60, "frame rate: the video's own, capped")
        let mb = ExportTiming.estimatedBytes(layout: portrait, fps: 30, seconds: 60, sound: true) / 1e6
        check(mb > 10 && mb < 120, "size estimate for a minute ≈ \(Int(mb)) MB")
        let name = ExportNaming.filename(babyName: "Mia/Ö", age: "1 mo · 14 days", date: day(2026, 2, 24), calendar: cal)
        check(name == "MoveGrow Mia Ö 1 mo 14 days 2026-02-24.mp4", "file name: \(name)")
        check(ExportNaming.filename(babyName: nil, age: nil, date: day(2026, 2, 24), calendar: cal) == "MoveGrow 2026-02-24.mp4", "file name without a baby")
        check(ExportNaming.filename(babyName: "Mia", age: nil, date: nil, calendar: cal) == "MoveGrow Mia.mp4", "no date in the name when it isn't known")

        // Values beside the charts.
        let n = 40
        func series(_ f: (Int) -> Float) -> PackedSeries { PackedSeries((0..<n).map(f)) }
        let g = ReviewDigest(start: 0, bin: 0.25, count: n, analysisFPS: 30, coverage: series { _ in 1 },
                             speed: ["L_arm": series { _ in 0.4 }, "R_arm": series { _ in 0.2 }, "L_leg": series { _ in .nan }, "R_leg": series { _ in 0.1 }],
                             active: ["L_arm": series { $0 < 20 ? 1 : 0 }, "R_arm": series { _ in 0 }],
                             angle: ["elbow_L": series { _ in 151.6 }, "elbow_R": series { _ in .nan }],
                             headYaw: series { _ in 0.42 }, motion: series { _ in 0.3 },
                             armBalanceSeries: series { _ in 0.33 }, legBalanceSeries: series { _ in -0.2 },
                             activeFraction: [:], angleRange: [:], armBalance: 0.3, legBalance: nil, trackedFraction: 1,
                             headTurn: [1, 0, 0], speedScale: 0.5)
        func texts(_ row: ExportRow, _ i: Int?) -> [String] { ExportData.values(row, ExportData.lines(row, g), bin: i).map(\.text) }
        check(texts(.arms, 10) == ["L 0.40", "R 0.20"] && texts(.legs, 10) == ["L –", "R 0.10"], "speed values L / R")
        check(texts(.elbows, 10) == ["L 152°", "R –"], "angle values")
        check(texts(.balance, 10) == ["arms +0.33", "legs −0.20"] && texts(.head, 10) == ["left 0.4"] && texts(.motion, 10) == ["0.30"], "balance, head, motion")
        check(texts(.arms, nil) == ["L –", "R –"] && texts(.head, nil) == ["–"], "no data outside the analysed part")
        let mv = ExportData.moving(g, bin: 5)
        check(mv["L_arm"] == true && mv["R_arm"] == false && mv["L_leg"] == nil && ExportData.moving(g, bin: 30)["L_arm"] == false,
              "which limbs are moving")
        // Languages.
        check(L10n.format("%1$lld of %2$lld", [3, 5]) == "3 of 5" && L10n.format("%2$lld 次中有 %1$lld 次", [3, 5]) == "5 次中有 3 次",
              "numbered placeholders can be reordered by a translation")
        check(L10n.format("%@ · %lld videos", ["Mia", 4]) == "Mia · 4 videos" && L10n.format("100% sure", []) == "100% sure"
              && L10n.format("%d%% done", [40]) == "40% done" && L10n.format("%@ and %@", ["a"]) == "a and ", "placeholders, %% and missing arguments")
        check(tr("%lld days old", 45) == "45 days old" && tr("Around %@", "Mar 2026") == "Around Mar 2026", "tr without a table falls back to English")
        check(AppLanguage.match(["zh-Hant-TW", "en"]) == .chinese && AppLanguage.match(["es-MX"]) == .spanish
              && AppLanguage.match(["fr-FR", "es-ES"]) == .spanish && AppLanguage.match(["fr", "de"]) == .english
              && AppLanguage.match(["en-GB", "zh-Hans"]) == .english, "following the phone picks the first language MoveGrow has")
        let lt = LocalizedText(zh: "中", en: "en", es: "es")
        check(lt.resolved("zh-Hans") == "中" && lt.resolved("es") == "es" && lt.resolved("en") == "en"
              && LocalizedText(zh: "中", en: "en").resolved("es") == "en", "rule texts per language, English when there is no Spanish")
        check(RuleTemplate.render("{hz:.1f} Hz, {n} veces, índice {pi:+.2f}", ["hz": 8.25, "n": 3, "pi": 0.5], decimalComma: true) == "8,2 Hz, 3 veces, índice +0,50"
              || RuleTemplate.render("{hz:.1f} Hz, {n} veces, índice {pi:+.2f}", ["hz": 8.25, "n": 3, "pi": 0.5], decimalComma: true) == "8,3 Hz, 3 veces, índice +0,50",
              "Spanish rule messages use a decimal comma")
        let b2 = Baby(name: "x", birthday: day(2026, 1, 1))
        check(b2.age(on: day(2026, 2, 15)) == "1 month, 14 days" && b2.age(on: day(2026, 1, 2)) == "1 day old"
              && b2.age(on: day(2026, 3, 2)) == "2 months, 1 day", "ages: \(b2.age(on: day(2026, 2, 15)))")
        print("dates & export OK")
    }
}
