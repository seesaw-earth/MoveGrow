// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Getting started, in three layers:
//
// 1. WelcomeFlow — up to three short pages before the baby profile on first launch (skippable, and
//    kept in Settings → How MoveGrow works): two ways to add a video; the one thing that matters
//    (the whole baby, in the middle, hands and feet in view); and, with the InstantHMR engine, why
//    no perfect angle is needed. Only what the screens cannot say for themselves.
// 2. In place — FirstVideoCard on the empty album (the two ways as two buttons), RecordingTips once
//    in the recorder before the first recording (before the camera prompt) and once before the first import,
//    and FramingChecklist on the camera picture, which turns sage word by word as each thing falls
//    into place. This is where framing is actually learned.
// 3. Always there — Recording tips from the recorder's toolbar and from Settings.
//
// Why so little up front: card tutorials read at launch do not make later tasks easier (Nielsen Norman
// Group, 2020), a short filming guide worked as well as a long one for parents filming at home (Kwong
// et al., J Paediatr Child Health 2022), and what the camera says while framing is what gets followed.

import SwiftUI

enum Onboarding {
    /// The welcome pages have been read or skipped.
    static let welcomeSeenKey = "onboardingWelcomeSeen"
    /// The recording tips have been shown before a first recording / a first import.
    static let recordTipsSeenKey = "onboardingRecordTipsSeen"
    static let importTipsSeenKey = "onboardingImportTipsSeen"

    /// Movement is measured in 3D on the baby's own body (InstantHMR), so the camera's angle matters
    /// less. With the 2D engine the pages and tips ask for a picture from straight above instead.
    static var measuresIn3D: Bool { PoseEngine.current == .instantHMR }
}

// MARK: - Welcome pages

enum WelcomePage: Hashable {
    case ways, framing, angles

    var title: String {
        switch self {
        case .ways: return tr("Two ways to add a video")
        case .framing: return tr("The whole baby, in the middle")
        case .angles: return tr("Analysed in 3D — no perfect angle needed")
        }
    }

    var message: String {
        switch self {
        case .ways:
            return tr("Record here in MoveGrow, or choose videos you already have in Photos. Either way, they are analysed on this iPhone and stay on it.")
        case .framing:
            return tr("This matters most. Keep the head, both hands and both feet inside the picture the whole time, with a little room around them. What the camera can’t see can’t be measured.")
        case .angles:
            return tr("MoveGrow rebuilds each movement as a 3D figure and measures it on your baby’s own body, not on the flat picture. Straight above or a little to the side both work, as long as all four limbs stay in view.")
        }
    }

    var note: String? {
        self == .angles ? tr("The 3D figure is an estimate from a single camera. MoveGrow describes movement; it is not a test or a diagnosis.") : nil
    }
}

struct WelcomeFlow: View {
    /// First launch: a language menu and Skip on top, and the last button leads on to the baby profile
    /// (`finish`). From Settings: the last button says Done and goes back.
    var firstRun = false
    var finish: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    /// Redraws the pages in place when the language changes.
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @State private var page = 0

    private var pages: [WelcomePage] {
        Onboarding.measuresIn3D ? [.ways, .framing, .angles] : [.ways, .framing]
    }

    var body: some View {
        let items = pages
        VStack(spacing: 0) {
            if firstRun { topBar }
            TabView(selection: $page) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    WelcomePageView(page: item, active: page == index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .id(language)
            bottomBar(count: items.count)
        }
        .background(Color.mgPaper.ignoresSafeArea())
        .navigationTitle(firstRun ? "" : tr("How MoveGrow works"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var topBar: some View {
        HStack {
            Menu {
                Picker(tr("Language"), selection: Binding(get: { AppLanguage(rawValue: language) ?? .system },
                                                          set: { AppLanguage.set($0) })) {
                    ForEach(AppLanguage.allCases) { l in Text(l.nativeName).tag(l) }
                }
            } label: {
                Label {
                    Text(verbatim: (AppLanguage(rawValue: language) ?? .system).resolved.nativeName)
                } icon: {
                    Image(systemName: "globe")
                }
                .font(.subheadline)
                .frame(minHeight: 44)
            }
            .accessibilityLabel(tr("Language"))
            Spacer()
            Button(tr("Skip")) { finish() }
                .font(.subheadline)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 20)
    }

    private func bottomBar(count: Int) -> some View {
        let last = page >= count - 1
        return VStack(spacing: 16) {
            HStack(spacing: 7) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Color.mgSage : Color.mgSage.opacity(0.22))
                        .frame(width: i == page ? 20 : 7, height: 7)
                }
            }
            .animation(.easeOut(duration: 0.2), value: page)
            .accessibilityElement()
            .accessibilityLabel(tr("Page %1$lld of %2$lld", page + 1, count))
            Button {
                if !last {
                    withAnimation(.easeInOut(duration: 0.3)) { page += 1 }
                } else if firstRun {
                    finish()
                } else {
                    dismiss()
                }
            } label: {
                Text(last ? (firstRun ? tr("Get started") : tr("Done")) : tr("Continue"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.mgSage)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }
}

/// One welcome page: the picture, a serif title, two or three sentences. Scrolls when the text is large.
struct WelcomePageView: View {
    let page: WelcomePage
    /// The page on screen; the others hold still.
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            let width = max(200, min(geo.size.width - 48, 360))
            ScrollView {
                VStack(spacing: 24) {
                    art(width)
                    VStack(spacing: 10) {
                        Text(page.title)
                            .font(.mgTitle)
                            .foregroundStyle(Color.mgInk)
                            .accessibilityAddTraits(.isHeader)
                        Text(page.message)
                            .font(.body)
                            .foregroundStyle(.secondary)
                        if let note = page.note {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
    }

    @ViewBuilder private func art(_ width: CGFloat) -> some View {
        switch page {
        case .ways: TwoWaysArt(width: width, active: active)
        case .framing: FramingArt(width: width, active: active)
        case .angles: AnglesArt(width: width, active: active)
        }
    }
}

// MARK: - Empty album

/// The empty album: the two ways to add a first video as two buttons, and the recording tips.
struct FirstVideoCard: View {
    var record: () -> Void
    var choose: () -> Void
    var choosing = false
    @State private var tips = false

    var body: some View {
        VStack(spacing: 14) {
            BabyScene(time: nil, fill: 0.42, offset: CGSize(width: 0, height: -0.02), camera: true)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(tr("Your story starts here"))
                    .font(.mgSection)
                    .foregroundStyle(Color.mgInk)
                Text(tr("Record a new video, or choose ones you already have."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                Button(action: record) {
                    Text(tr("Record")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                Button(action: choose) {
                    Text(tr("Choose from Photos")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .disabled(choosing)
            }
            .tint(Color.mgSage)
            Button(tr("Recording tips")) { tips = true }
                .font(.subheadline)
                .frame(minHeight: 44)
        }
        .mgCard(padding: 16, radius: 20)
        .sheet(isPresented: $tips) {
            NavigationStack { RecordingTipsView(purpose: .reference) }
        }
    }
}

// MARK: - Recording tips

/// What makes a video measurable, on one screen: the two camera pictures, then a few lines. Shown once
/// in the recorder before the first recording (so the camera prompt comes with its reason) and once
/// before the first import; later from the recorder's toolbar, the empty album and Settings.
struct RecordingTips: View {
    enum Purpose {
        /// Before the first recording: "Got it" opens the camera.
        case record
        /// Before the first import: "Choose videos" opens Photos.
        case choose
        /// Looked up later: no button of its own.
        case reference
    }

    var purpose: Purpose = .reference
    /// The main button was tapped.
    var proceed: () -> Void = {}

    private struct Tip: Identifiable {
        let title: String
        let detail: String
        var id: String { title }
    }

    private var tips: [Tip] {
        var list = [
            Tip(title: tr("The whole baby, in the middle"), detail: tr("Head to toes inside the picture, with a little room around.")),
            Tip(title: tr("Both hands and both feet in view"), detail: tr("What the camera can’t see can’t be measured.")),
            Tip(title: tr("Just your baby"), detail: tr("MoveGrow follows the largest person in the picture, so keep everyone else out of it.")),
            Tip(title: tr("Steady, in soft light"), detail: tr("Hold the phone still or prop it up, and avoid strong light from behind.")),
        ]
        if Onboarding.measuresIn3D {
            list.append(Tip(title: tr("No perfect angle needed"),
                            detail: tr("Straight above or a little to the side both work: movement is measured in 3D, on your baby’s own body.")))
        } else {
            list.append(Tip(title: tr("From straight above"),
                            detail: tr("Angles are measured in the picture, so hold the phone directly over your baby.")))
        }
        list.append(Tip(title: tr("A safe, flat spot"), detail: tr("A mat on the floor works well. Stay within reach of your baby.")))
        return list
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FramingArt(width: max(200, min(geo.size.width - 40, 280)))
                        .frame(maxWidth: .infinity)
                    if purpose == .choose {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("Choose videos that show your baby’s whole body."))
                                .font(.headline)
                                .foregroundStyle(Color.mgInk)
                            Text(tr("Up to %1$lld videos and %2$lld minutes per import.", BatchImporter.maxVideos, Int(BatchImporter.maxTotalSeconds / 60)))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(tips) { tip in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tip.title).font(.headline).foregroundStyle(Color.mgInk)
                                Text(tip.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .mgCard(padding: 16)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .background(Color.mgPaper)
        .safeAreaInset(edge: .bottom) {
            if purpose != .reference {
                Button(action: proceed) {
                    Text(purpose == .choose ? tr("Choose videos") : tr("Got it"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.mgSage)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }
}

/// The recording tips with a title bar: in a sheet of their own (Close, or Done when only looked up),
/// or pushed in Settings (`modal` false).
struct RecordingTipsView: View {
    var purpose: RecordingTips.Purpose = .reference
    /// The main button was tapped (not called for Close or a swipe down); the sheet then closes.
    var proceed: () -> Void = {}
    var modal = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RecordingTips(purpose: purpose, proceed: { proceed(); dismiss() })
            .navigationTitle(tr("Recording tips"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if modal {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(purpose == .reference ? tr("Done") : tr("Close")) { dismiss() }
                    }
                }
            }
    }
}

// MARK: - On the camera picture

/// The three things the live check looks for, as words along the bottom of the camera picture (in the
/// band under the dashed guide): each turns sage with a tick as it falls into place. The line of guidance
/// under the picture says what to do next; these show what is already right.
struct FramingChecklist: View {
    let checks: EnvironmentChecks

    private struct Item: Identifiable {
        let title: String
        let ok: Bool
        var id: String { title }
    }

    private var items: [Item] {
        [Item(title: tr("Whole body"), ok: checks.bodyOK && !checks.missingCriticalJoints.contains(.nose)),
         Item(title: tr("Hands & feet"), ok: checks.bodyOK && checks.limbsOK),
         Item(title: tr("Centred"), ok: checks.bodyOK && checks.framingOK)]
    }

    var body: some View {
        let list = items
        HStack(spacing: 6) {
            ForEach(list) { chip($0.title, $0.ok) }
        }
        .animation(.easeOut(duration: 0.2), value: list.map(\.ok))
    }

    private func chip(_ title: String, _ ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .imageScale(.small)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(ok ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            if ok { Capsule().fill(Color.mgSage) } else { Capsule().fill(.ultraThinMaterial) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(ok ? tr("In place") : tr("Not yet"))
    }
}
