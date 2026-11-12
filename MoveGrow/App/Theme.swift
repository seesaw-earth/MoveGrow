// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import UIKit

/// "Baby in bloom" palette: sage, blush, cream and a little champagne gold.
/// Every colour adapts to dark mode. Text-bearing colours meet WCAG AA on the
/// backgrounds they're used on (sage ≥ 4.6:1 on paper, card and sage-soft).
extension Color {
    /// Accent, buttons, links and selected states.
    static let mgSage = Color(light: 0x4F6B4C, dark: 0x76936F)
    /// Quiet fills: selected chips, soft badges.
    static let mgSageSoft = Color(light: 0xDCE6D3, dark: 0x2F3B2C)
    /// Decorative warmth: skeleton lines, cheeks, highlights. Not for small text.
    static let mgBlush = Color(light: 0xE59C98, dark: 0xE9A9A6)
    static let mgBlushSoft = Color(light: 0xF8E1DE, dark: 0x3A2A29)
    /// "Waiting" marks and small ornaments. Icons only, never body text.
    static let mgGold = Color(light: 0xA8843E, dark: 0xD4B26A)
    /// Screen background and card surface.
    static let mgPaper = Color(light: 0xFBF8F4, dark: 0x161513)
    static let mgCard = Color(light: 0xF3ECE2, dark: 0x24221F)
    /// Skeleton bones drawn over video: pale sage-mint stays visible on skin tones.
    static let mgSkeleton = Color(light: 0xBFE0AE, dark: 0xBFE0AE)
    /// Data series (left arm, right arm, left leg, right leg). Brand colours are too
    /// muted to tell apart in charts, so data uses this validated categorical set:
    /// CVD ΔE ≥ 8 between neighbours in light and dark; right-side limbs are also
    /// dashed so identity never depends on colour alone.
    static let mgSeries1 = Color(light: 0x2A78D6, dark: 0x3987E5)
    static let mgSeries2 = Color(light: 0xEB6834, dark: 0xD95926)
    static let mgSeries3 = Color(light: 0x1BAF7A, dark: 0x199E70)
    static let mgSeries4 = Color(light: 0xEDA100, dark: 0xC98500)
    /// Warm near-black for display titles.
    static let mgInk = Color(light: 0x3B332D, dark: 0xF3EDE6)

    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension ShapeStyle where Self == Color {
    static var mgSage: Color { Color.mgSage }
    static var mgSageSoft: Color { Color.mgSageSoft }
    static var mgBlush: Color { Color.mgBlush }
    static var mgBlushSoft: Color { Color.mgBlushSoft }
    static var mgGold: Color { Color.mgGold }
    static var mgPaper: Color { Color.mgPaper }
    static var mgCard: Color { Color.mgCard }
    static var mgInk: Color { Color.mgInk }
    static var mgSkeleton: Color { Color.mgSkeleton }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// Type scale. Display and section titles use the serif (New York) for a soft,
/// keepsake feel; everything you read or tap stays in SF for legibility.
/// All styles are text-style based, so Dynamic Type keeps working.
///   display   — first-run title                  (Large Title, serif)
///   title     — sheet and card questions         (Title 2, serif)
///   section   — "Movement summary", "Not decided yet" (Title 3, serif)
///   headline  — card titles, buttons             (Headline)
///   body/sub  — explanations                     (Body / Subheadline)
///   note      — secondary help text (≥ 13 pt)    (Footnote)
///   tag       — counters, durations, badges      (Caption)
///   number    — big counts and stats             (Title 2, rounded)
extension Font {
    static let mgDisplay = Font.system(.largeTitle, design: .serif).weight(.semibold)
    static let mgTitle = Font.system(.title2, design: .serif).weight(.semibold)
    static let mgSection = Font.system(.title3, design: .serif).weight(.semibold)
    static let mgNumber = Font.system(.title2, design: .rounded).weight(.semibold)
}

enum Theme {
    /// Serif navigation titles in warm ink; call once at launch.
    static func applyAppearance() {
        func serif(_ style: UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont(descriptor: descriptor, size: size))
        }
        let ink = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xF3EDE6) : UIColor(hex: 0x3B332D) }
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: serif(.largeTitle, size: 34, weight: .semibold), .foregroundColor: ink]
        bar.titleTextAttributes = [.font: serif(.headline, size: 17, weight: .semibold), .foregroundColor: ink]
    }
}

extension View {
    /// Warm paper background behind a List or Form instead of system grey.
    func mgListBackground() -> some View {
        scrollContentBackground(.hidden).background(Color.mgPaper)
    }

    /// Cream rounded card used for grouped content outside Lists.
    func mgCard(padding: CGFloat = 14, radius: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.mgCard))
    }
}
