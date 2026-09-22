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

    /// The Epic catalog namespace of the game awaiting a slug lookup (from
    /// legendary's local metadata). Primary resolution path: one POST to the
    /// launcher GraphQL endpoint maps namespace → product-home page slug.
    @Published var pendingStoreNamespace: String?

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

    /// Monotonic navigation token. Tapped cards call beginNavigation() before
    /// their async slug resolution; anything finishing later for an older
    /// token must not navigate — this is what made an earlier click's slow
    /// resolution "win" over the user's latest click (wrong-game jumps).
    private(set) var navigationGeneration = 0

    @discardableResult
    func beginNavigation() -> Int {
        navigationGeneration += 1
        return navigationGeneration
    }

    /// Open the game's exact Epic store page (Heroic-style menu entry).
    /// Resolves namespace → slug up front (with shell-proxy fallback), so the
    /// Store opens straight on the product page; the browse search page is
    /// the fallback when resolution fails.
    func openStorePage(for game: Game) {
        guard case .epicGames = game.storefront else { return }
        let title = game.title
        let gameID = game.id

        Task(priority: .userInitiated) { @MainActor in
            let generation = beginNavigation()
            let namespace = (try? Legendary.getGameMetadata(gameID: gameID))?.storeMetadata.namespace

            if let namespace,
               let slug = await StoreSlugResolver.productSlug(namespace: namespace),
               let target = URL(string: "https://store.epicgames.com/p/\(slug)") {
                guard generation == navigationGeneration else { return }
                openStore(url: target)
                return
            }

            guard generation == navigationGeneration else { return }
            let query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
            openStore(
                url: .init(string: "https://store.epicgames.com/browse?q=\(query)&sortBy=relevancy&sortDir=DESC")!,
                namespace: namespace,
                gameTitle: title
            )
        }
    }

    /// Point the Store web view at `url` and switch to the Store page.
    /// - Parameter namespace: the game's Epic catalog namespace (from legendary
    ///   metadata). When set, StoreView resolves the exact product page with
    ///   one launcher-GraphQL query; failure falls back to `url` (the search
    ///   page) and the `gameTitle`-based DOM scrape.
    func openStore(url: URL, namespace: String? = nil, gameTitle: String? = nil) {
        pendingStoreURL = url
        pendingStoreNamespace = namespace
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

    var body: some View {
        NavigationSplitView(
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
                // Library and Store stay alive in the ZStack across page
                // switches: Library keeps its scroll position, Store keeps its
                // web view's page. Inactive copies render at opacity 0 with
                // hit-testing disabled and suppress their own chrome.
                ZStack {
                    LibraryView(isActive: router.selectedPage == .library)
                        .opacity(router.selectedPage == .library ? 1 : 0)
                        .allowsHitTesting(router.selectedPage == .library)
                    StoreView(isActive: router.selectedPage == .store)
                        .opacity(router.selectedPage == .store ? 1 : 0)
                        .allowsHitTesting(router.selectedPage == .store)

                    switch router.selectedPage {
                    case .home, .none: HomeView()
                    case .containers: ContainersView()
                    case .accounts: AccountsView()
                    case .operations: OperationsView()
                    case .library, .store: EmptyView()
                    }
                }
            }
        )
        .toolbar {
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
