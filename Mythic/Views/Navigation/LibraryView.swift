//
//  LibraryView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 12/9/2023.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import SwiftyJSON
import SwordRPC

/// A view displaying the user's library of games.
/// - Note: ContentView keeps this view alive in a ZStack across page switches
///   (to preserve the game list's scroll position); `isActive` suppresses the
///   toolbar items, searchable field and title on the hidden copy.
struct LibraryView: View {
    var isActive: Bool = true

    @Bindable var gameDataStore: GameDataStore = .shared
    @ObservedObject private var variables: VariableManager = .shared

    @State private var isGameImportSheetPresented = false
    @Bindable var gameListViewModel: GameListViewModel = .shared
    @CodableAppStorage("gameListLayout") var gameListLayout: GameListViewModel.Layout = .grid

    var body: some View {
        GameListView()
            .navigationTitle(isActive ? "Library" : "")
            .safeAreaInset(edge: .top, spacing: 0) {
                if gameDataStore.epicSyncState != .idle {
                    syncStateBar
                }
            }

            .toolbar {
                if isActive {
                ToolbarItem(placement: .status) {
                    if gameListViewModel.isUpdatingLibrary {
                        ProgressView()
                            .controlSize(.small)
                            .help("Mythic is updating your library.")
                            .padding(10)
                    }
                }

                ToolbarItem(placement: .automatic) {
                    Button {
                        isGameImportSheetPresented = true
                    } label: {
                        Label("Import Game", systemImage: "plus.app")
                    }
                    .help("Import a game")
                }

                ToolbarItem(placement: .automatic) {
                    Button("Force-refresh", systemImage: "arrow.clockwise") {
                        // Full network sync (falls back to the user's shell proxy on
                        // direct-connection failure); also serves as the retry
                        // entry point for a failed sync shown in the status bar.
                        Task(priority: .userInitiated, operation: { await Legendary.updateMetadata(forced: true) })
                    }
                    .help("Force a re-evaluation of your library contents.")
                }
                
                // MARK: GameListView filter views
                if !gameListViewModel.sortedLibrary.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Picker("Layout", systemImage: "macwindow", selection: $gameListLayout) {
                            Label("List", systemImage: "rectangle.grid.1x3")
                                .tag(GameListViewModel.Layout.list)
                            
                            Label("Grid", systemImage: "square.grid.3x3")
                                .tag(GameListViewModel.Layout.grid)
                        }
                        .animation(.easeInOut, value: $gameListLayout.wrappedValue)
                    }
                    
                    ToolbarItem(placement: .automatic) {
                        Menu("Filters", systemImage: "line.3.horizontal.decrease") {
                            Section("Platform") {
                                ForEach(Game.Platform.allCases, id: \.self) { platform in
                                    Toggle(platform.description,
                                           isOn: searchTokenBinding(for: .platform(platform)))
                                }
                            }
                            
                            Section("Storefront") {
                                ForEach(Game.Storefront.allCases, id: \.self) { storefront in
                                    Toggle(storefront.description,
                                           isOn: searchTokenBinding(for: .storefront(storefront)))
                                }
                            }
                            
                            Section("Installation") {
                                Toggle("Installed",
                                       isOn: searchTokenBinding(for: .installed))
                                Toggle("Not Installed",
                                       isOn: searchTokenBinding(for: .notInstalled))
                            }
                            
                            Section {
                                Toggle("Favourited", isOn: searchTokenBinding(for: .favourited))
                            }
                        }
                        .menuIndicator(.hidden)
                    }
                }
                }
            }
        
            .task(priority: .background) {
                discordRPC.setPresence({
                    var presence: RichPresence = .init()
                    presence.details = "Looking through their game library"
                    presence.state = "Viewing Library"
                    presence.timestamps.start = .now
                    presence.assets.largeImage = "macos_512x512_2x"
                    
                    return presence
                }())
            }
        
            .sheet(isPresented: $isGameImportSheetPresented) {
                GameImportView(isPresented: $isGameImportSheetPresented)
                    .fixedSize()
            }
    }
    
    private func searchTokenBinding(for token: GameListViewModel.SearchToken) -> Binding<Bool> {
        .init(
            get: { gameListViewModel.searchTokens.contains(token) },
            set: { isOn in
                if isOn {
                    gameListViewModel.searchTokens.append(token)
                } else {
                    gameListViewModel.searchTokens.removeAll { $0 == token }
                }
            }
        )
    }
}

private extension LibraryView {
    /// Status bar for the Epic games-list sync. Visible for the whole duration
    /// of a sync; `success`/`failed` auto-dismiss back to `idle` after 5 seconds
    /// (handled by `GameDataStore.setSyncState`).
    @ViewBuilder
    var syncStateBar: some View {
        HStack(spacing: 6) {
            switch gameDataStore.epicSyncState {
            case .idle:
                EmptyView()
            case .syncing:
                ProgressView()
                    .controlSize(.small)
                Text("Updating Epic games list…")
                    .foregroundStyle(.secondary)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Epic games list updated.")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Failed to update Epic games list — use the toolbar refresh button to retry.")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.quinary)
    }
}

#Preview {
    LibraryView()
        .environmentObject(NetworkMonitor.shared)
        .frame(minHeight: 300)
}
