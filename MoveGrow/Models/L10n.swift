// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// The app's language: English, Simplified Chinese or Spanish, or the same as the phone. It can be
// changed inside the app (Settings → Language) and takes effect at once. Every visible text goes
// through `tr`, which looks its English wording up in the chosen language's table
// (Localizable.xcstrings, compiled into <language>.lproj). Dates and numbers follow the same
// language. Without a table (e.g. the Linux checks) the English wording is used as is.

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case chinese = "zh-Hans"
    case spanish = "es"

    var id: String { rawValue }
    static let storageKey = "appLanguage"

    /// The choice saved in Settings.
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    /// The language actually shown: "same as iPhone" becomes the first of the phone's preferred
    /// languages that MoveGrow has (any Chinese → Simplified Chinese), otherwise English.
    var resolved: AppLanguage {
        guard self == .system else { return self }
        return Self.match(Locale.preferredLanguages)
    }

    static func match(_ preferred: [String]) -> AppLanguage {
        for code in preferred {
            let c = code.lowercased()
            if c.hasPrefix("zh") { return .chinese }
            if c.hasPrefix("es") { return .spanish }
            if c.hasPrefix("en") { return .english }
        }
        return .english
    }

    /// Each language's name in itself, as language lists show them.
    var nativeName: String {
        switch self {
        case .system: return tr("Same as iPhone")
        case .english: return "English"
        case .chinese: return "简体中文"
        case .spanish: return "Español"
        }
    }

    /// At launch: if the language was changed in iOS Settings → MoveGrow → Language (which
    /// relaunches the app), adopt it.
    static func adoptSystemSetting() {
        let d = UserDefaults.standard
        guard let id = Bundle.main.bundleIdentifier else { return }
        let perApp = d.persistentDomain(forName: id)?["AppleLanguages"] as? [String]
        if let first = perApp?.first {
            let lang = match([first])
            if lang != current { d.set(lang.rawValue, forKey: storageKey) }
        } else if current != .system {
            d.set(AppLanguage.system.rawValue, forKey: storageKey)
        }
        L10n.reset()
    }

    /// Saves the choice. The phone's own per-app language follows, so system screens (camera and
    /// photo permission prompts) match from the next launch.
    static func set(_ language: AppLanguage) {
        let d = UserDefaults.standard
        d.set(language.rawValue, forKey: storageKey)
        if language == .system { d.removeObject(forKey: "AppleLanguages") } else { d.set([language.rawValue], forKey: "AppleLanguages") }
        L10n.reset()
    }
}

enum L10n {
    private static let lock = NSLock()
    private static var tables: [String: Bundle] = [:]
    private static var missing: Set<String> = []

    static var language: AppLanguage { AppLanguage.current.resolved }

    /// Locale for dates: the app's language with the phone's own region and settings (24-hour
    /// clock, first weekday …), so dates always match the text around them.
    static var locale: Locale {
        var c = Locale.Components(locale: .autoupdatingCurrent)
        c.languageComponents = Locale.Language.Components(identifier: language.rawValue)
        return Locale(components: c)
    }

    /// Locale for numbers: the language's own conventions (Spanish always writes 0,42), so numbers
    /// in charts and in observation texts agree.
    static var numberLocale: Locale { Locale(identifier: language.rawValue) }

    static func reset() {
        lock.lock(); tables = [:]; missing = []; lock.unlock()
    }

    private static func table(_ code: String) -> Bundle? {
        lock.lock(); defer { lock.unlock() }
        if let b = tables[code] { return b }
        if missing.contains(code) { return nil }
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) else {
            missing.insert(code)
            return nil
        }
        tables[code] = b
        return b
    }

    /// `key` (the English wording) in the app's language.
    static func string(_ key: String) -> String {
        guard let b = table(language.rawValue) else { return key }
        return b.localizedString(forKey: key, value: key, table: nil)
    }

    /// Fills %@, %d / %ld / %lld and their numbered forms (%1$@, %2$lld) with `args`, and %% with %.
    /// Translations may reorder numbered arguments.
    static func format(_ pattern: String, _ args: [Any]) -> String {
        guard pattern.contains("%") else { return pattern }
        var out = ""
        var next = 0
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let ch = pattern[i]
            guard ch == "%" else { out.append(ch); i = pattern.index(after: i); continue }
            var j = pattern.index(after: i)
            guard j < pattern.endIndex else { out.append("%"); break }
            if pattern[j] == "%" { out.append("%"); i = pattern.index(after: j); continue }
            // Optional "n$".
            var digits = ""
            var k = j
            while k < pattern.endIndex, pattern[k].isNumber { digits.append(pattern[k]); k = pattern.index(after: k) }
            var position: Int?
            if !digits.isEmpty, k < pattern.endIndex, pattern[k] == "$" { position = Int(digits).map { $0 - 1 }; j = pattern.index(after: k) }
            // Length modifiers, then the conversion.
            while j < pattern.endIndex, pattern[j] == "l" || pattern[j] == "h" || pattern[j] == "q" { j = pattern.index(after: j) }
            guard j < pattern.endIndex, "@dDiuU".contains(pattern[j]) else { out.append(contentsOf: pattern[i..<min(j, pattern.endIndex)]); i = j; continue }
            let index = position ?? next
            if position == nil { next += 1 }
            out.append(index >= 0 && index < args.count ? "\(args[index])" : "")
            i = pattern.index(after: j)
        }
        return out
    }

    // MARK: dates and numbers in the app's language

    static func date(_ d: Date, _ date: Date.FormatStyle.DateStyle = .abbreviated, time: Date.FormatStyle.TimeStyle = .omitted) -> String {
        d.formatted(Date.FormatStyle(date: date, time: time).locale(locale))
    }

    /// "March 2026" / "2026年3月" / "marzo de 2026".
    static func monthYear(_ d: Date, wide: Bool = true) -> String {
        d.formatted(Date.FormatStyle().month(wide ? .wide : .abbreviated).year().locale(locale))
    }

    /// "Mar 3" / "3月3日" / "3 mar".
    static func monthDay(_ d: Date) -> String {
        d.formatted(Date.FormatStyle().month(.abbreviated).day().locale(locale))
    }

    /// Month names for pickers, in the app's language (stand-alone forms).
    static var monthNames: [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        return cal.standaloneMonthSymbols
    }

    /// A decimal with a fixed number of digits ("0.42", "0,42" in Spanish).
    static func number(_ x: Double, digits: Int = 2) -> String {
        x.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(numberLocale))
    }

    /// A share as a percentage ("42%", "42 %" in Spanish).
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(numberLocale))
    }
}

/// The text for `key` — its English wording — in the app's language, with %@ / %lld (or %1$@,
/// %2$lld …) filled from `args`.
func tr(_ key: String, _ args: Any...) -> String {
    L10n.format(L10n.string(key), args)
}

extension LocalizedText {
    /// The rule book's text in the app's language (English when it has none).
    var text: String { resolved(L10n.language.rawValue) }
}
