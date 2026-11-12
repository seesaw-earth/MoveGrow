// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

@main struct MoveGrowApp: App {
    @StateObject private var store = LocalStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Background-task handlers must be registered before launch finishes.
        BackgroundWork.register()
        AppLanguage.adoptSystemSetting()
        Theme.applyAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(Color.mgSage)
                .alert(tr("Couldn’t complete that action"),isPresented:Binding(get:{store.error != nil},set:{if !$0 {store.error = nil}})) {
                    Button(tr("OK"),role:.cancel) { store.error = nil }
                } message: { Text(store.error ?? "") }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: store.appDidBecomeActive()
            case .background: store.appDidEnterBackground()
            default: break
            }
        }
    }
}
