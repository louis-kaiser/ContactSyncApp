//
//  contactSyncApp.swift
//  contactSync
//
//  Created by Louis Kaiser on 21.10.25.
//

// MARK: - App.swift
import SwiftUI
import Contacts

@main
struct ContactSyncApp: App {
    @StateObject private var viewModel = ContactSyncViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onAppear {
                    viewModel.checkAuthStatus()
                    if viewModel.authorizationStatus == .authorized {
                        viewModel.fetchAccounts()
                    }
                }
        }
    }
}
