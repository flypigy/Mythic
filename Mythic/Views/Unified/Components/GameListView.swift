//
//  GameListView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 6/3/2024.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog
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
                .savingScrollOffset()
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
/// Places the NSScrollView restore probe. Must be attached to content INSIDE
/// the scroll view — the probe lives within the document view so walking
/// superviews reaches the backing NSScrollView.
@available(macOS 15.0, *)
private struct ScrollOffsetPersistence: ViewModifier {
    @AppStorage("gameListScrollOffset") private var storedScrollOffset: Double = 0

    func body(content: Content) -> some View {
        content
            .background(
                ScrollViewRestorer(targetOffset: storedScrollOffset)
                    .frame(width: 0, height: 0)
            )
    }
}

/// Saves the scroll offset. Must be attached to the ScrollView itself — an
/// observer placed inside the (lazy) scroll content never fired (verified by
/// the absence of any save log lines during user scrolling).
///
/// The observer only tracks the latest offset in memory; persistence happens
/// once, on disappear. Writing to storage directly from the observer caused a
/// clobbering race: on view recreation the ScrollView briefly sits at 0, the
/// observer fires with 0 and overwrote the user's real position, so the next
/// restore went to the top.
@available(macOS 15.0, *)
private struct ScrollOffsetSaver: ViewModifier {
    @AppStorage("gameListScrollOffset") private var storedScrollOffset: Double = 0
    /// -1 = no trustworthy emission yet (only the creation instant, whose
    /// pre-restore offset of 0 must not clobber the stored position).
    @State private var latestOffset: CGFloat = -1
    @State private var hasIgnoredCreationEmission = false
    private let log = Logger.custom(category: "ScrollRestore")

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, newOffset in
                // The first emission after (re)creation is the pre-restore
                // offset (0) — ignore its value; every later emission (the
                // restore latching, or the user scrolling, including back to
                // the very top) reflects a real position.
                guard hasIgnoredCreationEmission else {
                    hasIgnoredCreationEmission = true
                    return
                }
                latestOffset = newOffset
            }
            .onDisappear {
                guard latestOffset >= 0 else { return }
                log.notice("scroll: save \(latestOffset, privacy: .public) (was \(storedScrollOffset, privacy: .public))")
                storedScrollOffset = Double(latestOffset)
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
            } else {
                Logger.custom(category: "ScrollRestore")
                    .notice("probe: no NSScrollView found in superview chain")
            }
        }
    }

    final class Coordinator {
        private var restoreTask: Task<Void, Never>?

        func restore(_ scrollView: NSScrollView, to target: Double) {
            restoreTask?.cancel()
            guard target > 1 else { return }
            let targetPoint = CGPoint(x: 0, y: target)
            let log = Logger.custom(category: "ScrollRestore")

            restoreTask = Task { @MainActor in
                // Give the (re)created scroll view a beat to lay out.
                try? await Task.sleep(for: .milliseconds(150))

                // Tracks what WE last applied, to distinguish SwiftUI resets
                // (back to 0 → retry) from the user scrolling (→ abort).
                var lastApplied: Double = 0

                for _ in 0..<20 {
                    guard !Task.isCancelled else { return }

                    let current = Double(scrollView.contentView.bounds.origin.y)
                    let documentHeight = Double(scrollView.documentView?.frame.height ?? 0)
                    log.notice("restore: target=\(target, privacy: .public) current=\(current, privacy: .public) docHeight=\(documentHeight, privacy: .public)")

                    if abs(current - target) < 6 { return }                    // latched
                    if current > 6, abs(current - lastApplied) > 6 { return }  // user moved it — never fight
                    guard documentHeight >= target else {                      // content not laid out yet
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }

                    scrollView.contentView.scroll(to: targetPoint)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    lastApplied = target
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }
}

private extension View {
    /// Restore probe; attach to content INSIDE the scroll view.
    @ViewBuilder
    func preservingScrollOffset() -> some View {
        if #available(macOS 15.0, *) {
            modifier(ScrollOffsetPersistence())
        } else {
            self
        }
    }

    /// Offset saving; attach to the ScrollView itself.
    @ViewBuilder
    func savingScrollOffset() -> some View {
        if #available(macOS 15.0, *) {
            modifier(ScrollOffsetSaver())
        } else {
            self
        }
    }
}

#Preview {
    GameListView()
        .environmentObject(NetworkMonitor.shared)
}
