//
//  GameDataStore.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 2/12/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import Combine
import OSLog

// TODO: eventually, migrate to SwiftData.
@Observable @MainActor final class GameDataStore {
    static let shared: GameDataStore = .init()
    let log: Logger = .custom(category: "GameDataStore")
    
    private let gamesObserver: CodableUserDefaultsObserver<[AnyGame]>
    private var isUpdatingFromObserver = false
    
    var library: Set<Game> = .init() {
        didSet {
            guard !isUpdatingFromObserver else { return }
            try? UserDefaults.standard.encodeAndSet(library.map({ AnyGame($0) }), forKey: "games")
        }
    }

    @MainActor private init() {
        // initialise observer
        gamesObserver = .init(key: "games",
                              defaultValue: [])
        
        // load library on initialisation
        library = Set(gamesObserver.value.map({ $0.base }))
        
        // observe external changes
        gamesObserver.$value
            .sink { [weak self] newGames in
                guard let self else { return }
                let newLibrary = Set(newGames.map({ $0.base }))
                
                guard newLibrary != self.library else { return }
                self.log.debug("Games key changed in UserDefaults, updating library")
                
                self.isUpdatingFromObserver = true
                defer { self.isUpdatingFromObserver = false }
                self.library = newLibrary
            }
            .store(in: &cancellables)
    }
    
    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = .init()

    /// Re-entrancy guard: several Migrator tasks and the launch sequence each call
    /// refreshFromStorefronts(); collapsing concurrent calls avoids doing the same
    /// heavy metadata decode (758+ files) multiple times in parallel.
    @ObservationIgnored
    private var isRefreshingStorefronts = false

    var recent: Game? {
        guard !library.allSatisfy({ $0.lastLaunched == nil }) else { return nil }

        return library.max {
            $0.lastLaunched ?? .distantPast < $1.lastLaunched ?? .distantPast
        }
    }

    func refreshFromStorefronts(_ storefronts: Game.Storefront...) async throws {
        // Re-entrancy guard: drop concurrent calls (e.g. from multiple Migrator tasks
        // firing during launch) so the heavy metadata decode runs once at a time.
        guard !isRefreshingStorefronts else { return }
        isRefreshingStorefronts = true
        defer {
            isRefreshingStorefronts = false
        }

        GameListViewModel.shared.isUpdatingLibrary = true
        defer {
            GameListViewModel.shared.isUpdatingLibrary = false
        }

        // if variadics are empty, default to all cases
        let storefronts = storefronts.isEmpty ? Game.Storefront.allCases : storefronts as [Game.Storefront]
        
        // legendary (epic games)
        if storefronts.contains(.epicGames) {
            do {
                // Decode metadata (758+ JSON files) off the main actor to avoid freezing
                // the UI during launch/refresh. These Legendary helpers are nonisolated.
                async let installablesTask = Task.detached(priority: .userInitiated) {
                    try Legendary.getInstallableGames()
                }.value
                async let installedTask = Task.detached(priority: .userInitiated) {
                    try Legendary.getInstalledGames()
                }.value

                let installables = try await installablesTask
                let installed = try await installedTask

                // add installables that aren't installed.
                // Merge with any existing entry instead of replacing it, otherwise per-game state
                // (isFavourited, lastLaunched, containerURL, ...) on the stored game would be wiped by
                // the freshly-constructed EpicGamesGame from getInstallableGames() (all defaults).
                for game in installables where !installed.contains(where: { $0 == game }) {
                    if let existing = library.first(where: { $0 == game }) {
                        try existing.merge(with: game, requiring: .identicalIgnoredKeys)
                        library.update(with: existing)
                    } else {
                        library.update(with: game)
                    }
                }

                // installed: merge instead of overwrite
                for fetchedGame in installed {
                    if let existing = library.first(where: { $0 == fetchedGame }) {
                        try existing.merge(with: fetchedGame, requiring: .identicalIgnoredKeys)
                        library.update(with: existing)
                    } else {
                        library.update(with: fetchedGame)
                    }
                }

                // remove Epic entries that are neither real games (per metadata categories,
                // which getInstallableGames now filters) nor currently installed.
                // This prunes previously-synced non-game items (UE marketplace assets/plugins/DLC)
                // and uninstalled titles no longer entitled to the account, while leaving local
                // games and installed Epic games untouched.
                let installableIDs = Set(installables.map(\.id))
                let installedIDs = Set(installed.map(\.id))
                library = library.filter { game in
                    guard case .epicGames = game.storefront else { return true } // keep non-Epic games
                    // keep installed Epic games and Epic games still in the (game-filtered) installables
                    return installedIDs.contains(game.id) || installableIDs.contains(game.id)
                }
            } catch {
                log.error("Unable to refresh game data from Epic Games: \(error.localizedDescription)")
                throw error
            }
        }
        
        // TODO: others
        // if storefronts.contains(...) { ... }
    }
}
