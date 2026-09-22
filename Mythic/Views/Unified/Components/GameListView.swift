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
                    // The offset-persistence modifier attaches to the content
                    // INSIDE the scroll view: the NSScrollView probe must sit
                    // within the document view so walking superviews reaches
                    // it (a background on the ScrollView itself is a sibling
                    // branch and never does).
                    Group {
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
                    .preservingScrollOffset()
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

/// Persists a ScrollView's content offset (via onScrollGeometryChange) and
/// restores it by driving the underlying AppKit NSScrollView directly —
/// SwiftUI-level restores (id bindings, ScrollPosition(point:)) proved
/// ineffective with lazy grid content on macOS, while the offset itself saves
/// fine (verified in UserDefaults).
@available(macOS 15.0, *)
private struct ScrollOffsetPersistence: ViewModifier {
    @AppStorage("gameListScrollOffset") private var storedScrollOffset: Double = 0

    func body(content: Content) -> some View {
        content
            .background(
                ScrollViewRestorer(targetOffset: storedScrollOffset)
                    .frame(width: 0, height: 0)
            )
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, newOffset in
                // Throttle: geometry ticks fire continuously while scrolling.
                if abs(newOffset - storedScrollOffset) > 2 {
                    storedScrollOffset = newOffset
                }
            }
    }
}

/// Locates the enclosing AppKit NSScrollView (the SwiftUI ScrollView's
/// backing view) and scrolls it to the persisted offset.
private struct ScrollViewRestorer: NSViewRepresentable {
    var targetOffset: Double

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.restoreHandler = { scrollView in
            context.coordinator.restore(scrollView, to: targetOffset)
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.restoreHandler = { scrollView in
            context.coordinator.restore(scrollView, to: targetOffset)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class ProbeView: NSView {
        var restoreHandler: ((NSScrollView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let restoreHandler else { return }

            var ancestor: NSView? = superview
            while let current = ancestor, !(current is NSScrollView) {
                ancestor = current.superview
            }

            if let scrollView = ancestor as? NSScrollView {
                restoreHandler(scrollView)
            }
        }
    }

    final class Coordinator {
        private var restoreTask: Task<Void, Never>?

        func restore(_ scrollView: NSScrollView, to target: Double) {
            restoreTask?.cancel()
            guard target > 1 else { return }
            let targetPoint = CGPoint(x: 0, y: target)

            restoreTask = Task { @MainActor in
                // Give the (re)created scroll view a beat to lay out.
                try? await Task.sleep(for: .milliseconds(150))

                for _ in 0..<20 {
                    guard !Task.isCancelled else { return }

                    let current = scrollView.contentView.bounds.origin
                    if abs(current.y - target) < 6 { return }   // latched
                    if current.y > 6 { return }                 // user/system already moved it — never fight
                    // documentView height is the scrollable content height;
                    // NSScrollView.contentSize is just the viewport.
                    guard let documentHeight = scrollView.documentView?.frame.height,
                          documentHeight >= target
                    else { continue }                           // content not laid out yet

                    scrollView.contentView.scroll(to: targetPoint)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }
}

private extension View {
    /// Scroll-offset persistence where supported; no-ops on macOS 14.
    /// Attach to content INSIDE the scroll view (the probe must live within
    /// the document view to find the backing NSScrollView).
    @ViewBuilder
    func preservingScrollOffset() -> some View {
        if #available(macOS 15.0, *) {
            modifier(ScrollOffsetPersistence())
        } else {
            self
        }
    }
}

#Preview {
    GameListView()
        .environmentObject(NetworkMonitor.shared)
}
