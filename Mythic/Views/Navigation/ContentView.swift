//
//  ContentView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 8/9/2023.
//
//  Reference
//  https://github.com/1998code/SwiftUI2-MacSidebar
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI
import SemanticVersion

/// Top-level pages of the sidebar. Drives the NavigationSplitView selection.
enum AppPage: Hashable {
    case home, library, store, containers, accounts, operations
}

/// Cross-page navigation coordinator. Lets non-sidebar views (e.g. a library
/// game card) programmatically switch pages and hand the Store a target URL.
final class ViewRouter: ObservableObject {
    static let shared = ViewRouter()

    @Published var selectedPage: AppPage?
    @Published var pendingStoreURL: URL?

    /// The game title awaiting a precise slug lookup once the store page has
    /// loaded; consumed by StoreView after its web view finishes rendering.
    @Published var pendingGameLookup: String?

    /// Last known URL of the retained store web view. Static (not published)
    /// so it survives page switches — SPA in-page navigation never triggers
    /// the web view's navigation delegate, so it's written on every web view
    /// update and read when the Store view is recreated.
    static var lastKnownStoreURL: URL?

    /// Atomically take (and clear) a pending store deep link.
    func consumePendingStoreURL() -> URL? {
        defer { pendingStoreURL = nil }
        return pendingStoreURL
    }

    /// Point the Store web view at `url` and switch to the Store page.
    /// - Parameter gameTitle: when set, StoreView tries to resolve the game's
    ///   exact product page from the title (via Epic's search APIs) after the
    ///   initial page loads; failure falls back to `url` (the search page).
    func openStore(url: URL, gameTitle: String? = nil) {
        pendingStoreURL = url
        pendingGameLookup = gameTitle
        selectedPage = .store
    }
}

struct ContentView: View {
    @EnvironmentObject var networkMonitor: NetworkMonitor

    @ObservedObject private var updateController: SparkleUpdateController = .shared
    @Bindable private var operationManager: GameOperationManager = .shared
    @ObservedObject private var router: ViewRouter = .shared

    @State private var appVersion: String = .init()
    @State private var buildNumber: Int = 0

    @State private var engineVersion: SemanticVersion?

    /// Sidebar visibility, toggled by our own transparent toolbar button
    /// (the system sidebar-toggle button renders with a glassy background).
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            sidebar: {
                // selection-driven navigation: deprecated isActive-based
                // NavigationLinks proved unreliable when triggered
                // programmatically on recent macOS releases (they'd land on
                // the wrong page), and page state needs to survive switches.
                List(selection: Binding(
                    get: { router.selectedPage },
                    set: { router.selectedPage = $0 }
                )) {
                    Section {
                        sidebarItem(.home, "Home", systemImage: "house",
                                    help: "Everything in one place")
                        sidebarItem(.library, "Library", systemImage: "books.vertical",
                                    help: "View your games")
                        sidebarItem(.store, "Store", systemImage: "bag",
                                    help: "Purchase new games from Epic")
                    }

                    Section {
                        sidebarItem(.containers, "Containers", systemImage: "cube",
                                    help: "Manage containers for Windows® applications")

                        Button("Support", systemImage: "questionmark.bubble") {
                            SupportWindowController.show()
                        }
                        .help("Get support")
                        .buttonStyle(.plain)

                        sidebarItem(.accounts, "Accounts", systemImage: "person.2",
                                    help: "View all currently signed in accounts")
                    } header: {
                        Text("Management")
                    }
                }

                // separate downloads view from main list because alignment doesn't work within the main list
                if !operationManager.queue.isEmpty {
                    List { // must wrap in a list to have the same styling as the other links
                        sidebarItem(.operations, "Operations", systemImage: "progress.indicator",
                                    help: "View all active game operations")
                    }
                    .frame(maxHeight: 40)
                    .scrollDisabled(true)
                    .scrollIndicators(.hidden)
                }
                
#if DEBUG
                VStack {
                    if let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                       let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                       let mythicVersion: SemanticVersion = .init("\(shortVersion)+\(bundleVersion)") {
                        Text("Mythic \(mythicVersion.prettyString)")
                    }
                    
                    if let engineVersion {
                        Text("Mythic Engine \(engineVersion.prettyString)")
                    }
                }
                .task { @MainActor in
                    engineVersion = await Engine.installedVersion
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom)
#endif // DEBUG

                switch updateController.state {
                case .updateAvailable:
                    updateBlock("Update Available", buttonText: "Show More") {
                        updateController.checkForUpdates(userInitiated: true)
                    }
                case .readyToRelaunch(let acknowledgement):
                    updateBlock("Update Ready", buttonText: "Relaunch") {
                        acknowledgement(.update)
                    }
                default:
                    EmptyView()
                }
            }, detail: {
                switch router.selectedPage {
                case .library: LibraryView()
                case .store: StoreView()
                case .containers: ContainersView()
                case .accounts: AccountsView()
                case .operations: OperationsView()
                case .home, .none: HomeView()
                }
            }
        )
        // The system sidebar-toggle button is replaced with our own plain
        // (background-free) button below.
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .buttonStyle(.plain)
                .help("Hide or show the sidebar")
            }

            ToolbarItem(placement: .status) {
                if !networkMonitor.isConnected {
                    Image(systemName: "network")
                        .symbolVariant(.slash)
                        .help("Mythic is not connected to the internet.")
                }
            }
        }
    }

    @ViewBuilder
    private func sidebarItem(_ page: AppPage, _ title: String, systemImage: String, help: String) -> some View {
        Label(title, systemImage: systemImage)
            .help(help)
            .tag(page)
    }

    @ViewBuilder
    private func updateBlock(_ title: String, buttonText: String, action: @escaping () -> Void) -> some View {
        VStack {
            Label(title, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(action: action, label: {
                Text(buttonText)
                    .frame(maxWidth: .infinity)
            })
            .buttonStyle(.borderedProminent)
            .clipShape(.capsule)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    ContentView()
        .environmentObject(NetworkMonitor.shared)
}
