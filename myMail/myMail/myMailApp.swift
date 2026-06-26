//
//  myMailApp.swift
//  myMail
//
//  Created by Nelle Rtcai on 6/22/26.
//

import SwiftUI

@main
struct myMailApp: App {
    @StateObject private var viewModel: MailAppViewModel

    init() {
        let stack = CoreDataStack()
        _viewModel = StateObject(wrappedValue: MailAppViewModel(mailStore: CoreDataMailStore(stack: stack)))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onOpenURL { url in
                    Task {
                        await viewModel.handleOAuthCallback(url)
                    }
                }
        }

        Window("Compose Mail", id: "compose") {
            ComposeWindowView()
                .environmentObject(viewModel)
        }
        .defaultSize(width: 760, height: 560)

        Settings {
            SettingsView()
                .environmentObject(viewModel)
        }
    }
}
