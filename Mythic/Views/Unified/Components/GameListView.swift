//
//  GameListView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 6/3/2024.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog
import QuartzCore
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
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        scrollToTop()
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .padding(10)
                    .background(.regularMaterial, in: .circle)
                    .padding(24)
                    .help("Back to top")
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

    /// Smoothly scrolls the library list back to the top, driving the backing
    /// NSScrollView the probe captured.
    private func scrollToTop() {
        guard let scrollView = LibraryScrollMemory.scrollView else { return }
        let top = CGPoint(x: 0, y: -scrollView.contentInsets.top)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrollView.contentView.animator().scroll(to: top)
        }
    }
}

/// Persists a ScrollView's content offset (via onScrollGeometryChange) and
/// restores it by driving the underlying AppKit NSScrollView directly —
/// SwiftUI-level restores (id bindings, ScrollPosition(point:)) proved
/// ineffective with lazy grid content on macOS, while the offset itself saves
/// fine (verified in UserDefaults).
/// Session-scoped scroll position for the library list: survives page
/// switches, resets on app relaunch (in-memory by design — a fresh launch
/// always starts at the top).
enum LibraryScrollMemory {
    static var offset: CGFloat?

    /// The backing scroll view, held by the probe so the back-to-top button
    /// (SwiftUI layer) can drive it directly.
    static weak var scrollView: NSScrollView?
}

/// Places the NSScrollView memory probe. Attach to content INSIDE the scroll
/// view — the probe must live within the document view so walking superviews
/// reaches the backing NSScrollView. Both saving (NSClipView bounds-change
/// notifications) and restoring (scroll(to:)) operate in the SAME clip-view
/// coordinate space; mixing SwiftUI geometry (which adds content insets) with
/// clip-view coordinates drifted the position by one inset per round trip.
private struct ScrollOffsetPersistence: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                ScrollViewRestorer()
                    .frame(width: 0, height: 0)
            )
    }
}

/// Observes and restores the enclosing NSScrollView's offset.
private struct ScrollViewRestorer: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.attachHandler = { scrollView in
            context.coordinator.attach(to: scrollView)
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class ProbeView: NSView {
        var attachHandler: ((NSScrollView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let attachHandler else { return }

            var ancestor: NSView? = superview
            while let current = ancestor, !(current is NSScrollView) {
                ancestor = current.superview
            }

            if let scrollView = ancestor as? NSScrollView {
                attachHandler(scrollView)
            } else {
                Logger.custom(category: "ScrollRestore")
                    .notice("probe: no NSScrollView found in superview chain")
            }
        }
    }

    final class Coordinator {
        private var restoreTask: Task<Void, Never>?
        private var boundsObserver: NSObjectProtocol?
        private let log = Logger.custom(category: "ScrollRestore")

        func attach(to scrollView: NSScrollView) {
            LibraryScrollMemory.scrollView = scrollView

            // Save on every scroll (user or programmatic) — same space as the
            // restore, so no conversion, no drift.
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSClipView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { _ in
                LibraryScrollMemory.offset = scrollView.contentView.bounds.origin.y
            }

            // Restore the in-session position (nil on a fresh launch → top).
            restoreTask?.cancel()
            guard let target = LibraryScrollMemory.offset else { return }
            let targetPoint = CGPoint(x: 0, y: target)

            restoreTask = Task { @MainActor in
                // No visible bounce: apply immediately (scroll(to:) is not
                // animated), then re-apply only while the position hasn't
                // latched. Abort if the user scrolled past the target.
                var applied = false

                for _ in 0..<30 {
                    guard !Task.isCancelled else { return }

                    let current = scrollView.contentView.bounds.origin.y
                    let documentHeight = scrollView.documentView?.frame.height ?? 0

                    if abs(current - target) < 2 { return }   // latched
                    if applied, current > target { return }   // user scrolled past — never fight
                    guard documentHeight >= target else {
                        try? await Task.sleep(for: .milliseconds(30))
                        continue
                    }

                    scrollView.contentView.scroll(to: targetPoint)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    applied = true
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }
    }
}

private extension View {
    /// Session-scoped scroll-position memory; attach to content INSIDE the
    /// scroll view.
    func preservingScrollOffset() -> some View {
        modifier(ScrollOffsetPersistence())
    }
}

#Preview {
    GameListView()
        .environmentObject(NetworkMonitor.shared)
}
