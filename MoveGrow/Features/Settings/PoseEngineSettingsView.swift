// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Settings → Pose engine: InstantHMR (3D, the default) or YOLO (2D), InstantHMR's options (kinematic fit,
// frame rate; the model is always Medium), and analysing again the videos made with another engine or
// other settings.

import SwiftUI

struct PoseEngineSettingsView: View {
    @EnvironmentObject private var store: LocalStore
    @AppStorage(PoseEngine.storageKey) private var engineRaw = PoseEngine.instantHMR.rawValue
    @AppStorage(HMRConfig.fitKey) private var fitCrops = HMRConfig.current.fitCrops
    @AppStorage(HMRConfig.fpsKey) private var maxFPS = HMRConfig.defaultFPS
    @State private var confirmAll = false
    @State private var queued: Int?

    private var engine: Binding<PoseEngine> {
        Binding(get: { PoseEngine(rawValue: engineRaw) ?? .instantHMR }, set: { engineRaw = $0.rawValue })
    }

    var body: some View {
        List {
            Section {
                Picker(tr("Pose engine"), selection: engine) {
                    ForEach(PoseEngine.allCases) { e in
                        Text(e.title).tag(e)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(!HMRModels.isAvailable)
            } footer: {
                if HMRModels.isAvailable {
                    Text(tr("InstantHMR fits a 3D body model to every frame: steady keypoints, true 3D angles and how far hands and feet are lifted. YOLO finds keypoints in 2D. New videos use the engine chosen here."))
                } else {
                    Text(tr("The InstantHMR models are not in this build, so videos are analysed with YOLO (2D)."))
                }
            }

            if HMRModels.isAvailable && engine.wrappedValue == .instantHMR {
                Section(tr("InstantHMR")) {
                    Picker(tr("Kinematic fit"), selection: $fitCrops) {
                        ForEach(HMRModels.availableFits, id: \.self) { n in
                            Text(fitLabel(n)).tag(n)
                        }
                    }
                    LabeledContent(tr("Frames per second")) {
                        Picker(tr("Frames per second"), selection: $maxFPS) {
                            ForEach(HMRConfig.fpsChoices, id: \.self) { f in
                                Text(verbatim: "\(f)").tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 170)
                    }
                }
            }

            Section {
                let ids = store.memoriesNeedingReanalysis()
                LabeledContent(tr("Analysed with another engine or settings"), value: "\(ids.count)")
                Button(tr("Analyse them again")) { confirmAll = true }
                    .disabled(ids.isEmpty)
                if let queued {
                    Text(tr("Queued: %lld", queued))
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(tr("Videos analysed earlier with YOLO are treated as new and analysed again with InstantHMR automatically. Videos made with other InstantHMR settings keep their results until you analyse them again. Notes, dates and milestones are kept."))
            }
        }
        .navigationTitle(tr("Pose engine"))
        .onChange(of: engineRaw) { _, _ in store.resumePending() }   // older videos follow the new choice
        .confirmationDialog(tr("Analyse these videos again with %@? Their current analysis is replaced.", PoseEngine.current.title),
                            isPresented: $confirmAll, titleVisibility: .visible) {
            Button(tr("Analyse again")) { queued = store.reanalyzeAll() }
        }
    }

    private func fitLabel(_ n: Int) -> String { HMRModels.fitLabel(n, long: true) }
}
