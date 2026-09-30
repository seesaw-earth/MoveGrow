// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

@main struct MoveGrowApp: App {
    @StateObject private var store = LocalStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(.teal)
                .alert("Couldn’t complete that action",isPresented:Binding(get:{store.error != nil},set:{if !$0 {store.error = nil}})) {
                    Button("OK",role:.cancel) { store.error = nil }
                } message: { Text(store.error ?? "") }
        }
    }
}
