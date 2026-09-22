//
//  GameListView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 6/3/2024.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI

struct GameListView: View {
    @Bindable var viewModel: GameListViewModel = .shared
    @Bindable var gameDataStore: GameDataStore = .shared
    
    @CodableAppStorage("gameListLayout") var layout: GameListViewModel.Layout = .grid
    @AppStorage("gameCardSize") private var gameCardSize: Double = 200.0
    
    @State private var isGameImportViewPresented: Bool = false

    /// Top-of-viewport game id while scrolling. Persisted on disappearance and
    /// restored on reappearance, so switching pages keeps the list where the
    /// user left it (the view itself is torn down by page switches).
    @State private var scrollPosition: String?
    @State private var lastReportedScrollAnchor: String?
    @AppStorage("gameListScrollAnchor") private var storedScrollAnchor: String = ""

    var body: some View {
        VStack {
            if gameDataStore.library.isEmpty {
                ContentUnavailableView(
                    "No games found. 😢",
                    systemImage: "folder.badge.questionmark",
                    description: Text("""
                        Games in your library will appear here.
                        If there are games in your library and they're not appearing, try restarting Mythic.
                        """)
                )
                .task {
                    try? await gameDataStore.refreshFromStorefronts()
                }

                Button {
                    isGameImportViewPresented = true
                } label: {
                    Label("Import Game", systemImage: "plus.app")
                        .padding(5)
                }
                .buttonStyle(.borderedProminent)
                .sheet(isPresented: $isGameImportViewPresented) {
                    GameImportView(isPresented: $isGameImportViewPresented)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        // FIXME: sortedLibrary should not be appended to or it'll cause overwrites.
                        // FIXME: a dirtyfix is to directly set to the underlying library
                        switch layout {
                        case .grid:
                            LazyVGrid(columns: [.init(.adaptive(minimum: gameCardSize))]) {
                                ForEach(viewModel.sortedLibrary) { game in
                                    GameCard(game: .constant(game))
                                        .id(game.id)
                                }
                            }
                            .padding()
                        case .list:
                            LazyVStack {
                                ForEach(viewModel.sortedLibrary) { game in
                                    ListGameCard(game: .constant(game))
                                        .id(game.id)
                                }
                            }
                            .padding()
                        }
                    }
                    .scrollPosition(id: $scrollPosition, anchor: .top)
                    .onDisappear {
                        if let scrollPosition {
                            storedScrollAnchor = scrollPosition
                        } else {
                            // scrollPosition can lag on quick page switches —
                            // fall back to the last value it reported.
                            if let last = lastReportedScrollAnchor {
                                storedScrollAnchor = last
                            }
                        }
                    }
                    .onChange(of: scrollPosition) {
                        if let scrollPosition {
                            lastReportedScrollAnchor = scrollPosition
                        }
                    }
                    .task {
                        // Restore the last scroll position after the (re)created
                        // view has laid out its content. scrollTo (rather than
                        // writing the scrollPosition binding) reliably reaches
                        // not-yet-instantiated lazy items.
                        guard !storedScrollAnchor.isEmpty else { return }
                        try? await Task.sleep(for: .seconds(0.15))
                        if scrollPosition == nil,
                           viewModel.sortedLibrary.contains(where: { $0.id == storedScrollAnchor }) {
                            proxy.scrollTo(storedScrollAnchor, anchor: .top)
                        }
                    }
                }
                .searchable(text: $viewModel.searchString,
                            tokens: $viewModel.searchTokens,
                            suggestedTokens: .constant(viewModel.suggestedTokens),
                            placement: .toolbar) { token in
                    switch token {
                    case .platform(let platform):
                        Text(platform.description)
                    case .storefront(let storefront):
                        Text(storefront.description)
                    case .installed:
                        Text("Installed")
                    case .notInstalled:
                        Text("Not Installed")
                    case .favourited:
                        Text("Favourited")
                    }
                }
            }
        }
        .animation(.easeInOut, value: layout)
        .animation(.default, value: viewModel.sortedLibrary)
    }
}
    
#Preview {
    GameListView()
        .environmentObject(NetworkMonitor.shared)
}
