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
                .preservingScrollOffset(itemCount: viewModel.sortedLibrary.count)
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

/// Persists a ScrollView's content offset (Apple's geometry save/restore
/// recipe) so the list returns to where the user left it after the view is
/// torn down by page switches. Geometry-based rather than item-id-based: the
/// id-binding variant never reported scrolling in this view hierarchy, so
/// nothing was ever saved (verified via the persisted key staying unset).
@available(macOS 15.0, *)
private struct ScrollOffsetPersistence: ViewModifier {
    /// Library item count; the restore re-runs when the (async-loaded) data
    /// populates, restoring earlier would silently no-op against an empty list.
    var itemCount: Int

    @State private var scrollPos = ScrollPosition()
    @AppStorage("gameListScrollOffset") private var storedScrollOffset: Double = 0

    func body(content: Content) -> some View {
        content
            .scrollPosition($scrollPos)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, newOffset in
                // Throttle: geometry ticks fire continuously while scrolling.
                if abs(newOffset - storedScrollOffset) > 2 {
                    storedScrollOffset = newOffset
                }
            }
            .task(id: itemCount) {
                // Restore the persisted offset after the view is recreated.
                // Retried briefly until it latches (within 6pt); stops once
                // positioned so it never fights the user's own scrolling.
                guard storedScrollOffset > 1 else { return }
                try? await Task.sleep(for: .milliseconds(150))

                for _ in 0..<8 {
                    if abs((scrollPos.point?.y ?? 0) - storedScrollOffset) < 6 { break }
                    scrollPos = ScrollPosition(point: CGPoint(x: 0, y: storedScrollOffset))
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
    }
}

private extension View {
    /// Scroll-offset persistence where supported; no-ops on macOS 14.
    @ViewBuilder
    func preservingScrollOffset(itemCount: Int) -> some View {
        if #available(macOS 15.0, *) {
            modifier(ScrollOffsetPersistence(itemCount: itemCount))
        } else {
            self
        }
    }
}

#Preview {
    GameListView()
        .environmentObject(NetworkMonitor.shared)
}
