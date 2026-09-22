//
//  StoreView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 10/9/2023.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import SwordRPC
import WebKit

struct StoreView: View {
    /// Whether this is the currently-visible page. ContentView keeps this view
    /// alive in a ZStack (preserving the web view's page); the hidden copy
    /// suppresses its toolbar items and title.
    var isActive: Bool = true

    @State private var canGoBack = false
    @State private var canGoForward = false
    // Initial value: the retained web view's live URL (mirrored by
    // ViewRouter.lastKnownStoreURL, covering SPA pushState navigation), or the
    // store landing page. Read-only here — a pending deep link is consumed in
    // onAppear, never in init (NavigationLink eagerly evaluates this init on
    // every ContentView body pass, which would race its delivery).
    @State private var url: URL = ViewRouter.lastKnownStoreURL
        ?? .init(string: "https://store.epicgames.com/")!

    @State private var refreshIconRotation: Angle = .degrees(0)

    @CodableAppStorage("epicGamesWebDataStore") var epicGamesWebDataStore: UUID = .init()

    var body: some View {
        WebView(
            url: url,
            datastore: .init(forIdentifier: epicGamesWebDataStore),
            error: .constant(nil),
            canGoBack: $canGoBack,
            canGoForward: $canGoForward,
            onPageLoaded: { _ in
                // Resolve only after the (deep-linked) page has actually
                // rendered — running the lookup earlier races the load, and
                // the fetch would run in a nonexistent page context.
                Task { @MainActor in await resolvePendingGameLookup() }
            }
        )

        .navigationTitle(isActive ? "Store" : "")

        // Deep links: consume (and clear) the pending link when this view
        // appears; onReceive covers links arriving while already alive.
        // Loading is delegated to WebView.updateNSView, which fires when the
        // changed url state flows through.
        .onAppear {
            if let pending = ViewRouter.shared.consumePendingStoreURL() {
                url = pending
            }
        }
        .onReceive(ViewRouter.shared.$pendingStoreURL) { pending in
            guard let pending else { return }
            ViewRouter.shared.pendingStoreURL = nil
            url = pending
        }



        .task(priority: .background) {
            discordRPC.setPresence({
                var presence: RichPresence = .init()
                presence.details = "Currently browsing \(url)"
                presence.state = "Looking for games to purchase"
                presence.timestamps.start = .now
                presence.assets.largeImage = "macos_512x512_2x"

                return presence
            }())
        }

        .toolbar {
            if isActive {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    WebView.retainedWebView?.goBack()
                } label: {
                    Image(systemName: "arrow.left")
                        .symbolVariant(.circle)
                }
                .disabled(!canGoBack)
            }
            
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    WebView.retainedWebView?.goForward()
                } label: {
                    Image(systemName: "arrow.right")
                        .symbolVariant(.circle)
                }
                .disabled(!canGoForward)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    WebView.retainedWebView?.reload()
                    withAnimation(.default) {
                        refreshIconRotation = .degrees(360)
                    } completion: {
                        refreshIconRotation = .degrees(0)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolVariant(.circle)
                        .rotationEffect(refreshIconRotation)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    url = .init(string: "https://store.epicgames.com/")!
                } label: {
                    Image(systemName: "arrow.up.forward")
                }
                .help("Open the store's front page")
            }
            }
        }
    }

    // MARK: - Exact game page resolution

    /// Resolves the pending game lookup (set when a library card was tapped):
    /// once the browse/search results page has rendered, poll its DOM for the
    /// first product link — the exact game page slug can't be guessed (modern
    /// slugs carry a random suffix) and bare API calls hit Cloudflare.
    /// Failure leaves the browse page visible as a fallback.
    @MainActor
    private func resolvePendingGameLookup() async {
        guard let title = ViewRouter.shared.pendingGameLookup?.lowercased(),
              let webView = WebView.retainedWebView,
              webView.url?.path.contains("/browse") == true else { return }
        defer { ViewRouter.shared.pendingGameLookup = nil }

        // Wait for the SPA to render results (up to ~8s), then take the first
        // product link, preferring one whose text matches the title.
        let script = """
        (function () {
            const title = \(Self.javaScriptString(title));
            const links = [...document.querySelectorAll('a[href*="/p/"]')];
            if (!links.length) return null;
            const match = links.find(a => a.textContent.toLowerCase().includes(title));
            return (match ?? links[0]).getAttribute('href');
        })()
        """

        var href: String?
        for _ in 0..<16 {
            if let result = try? await webView.evaluateJavaScript(script), let found = result as? String {
                href = found
                break
            }
            try? await Task.sleep(for: .seconds(0.5))
        }

        guard let href, href.hasPrefix("/p/"),
              let target = URL(string: "https://store.epicgames.com" + href) else { return }

        url = target
    }

    private static func javaScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}

/// Calls Epic's persisted GraphQL queries from the store page's JS context,
/// inheriting its Cloudflare clearance (bare URLSession requests are blocked).
enum StoreSlugResolver {
    static func runPersistedQuery(operationName: String, variables: [String: Any], sha256Hash: String, in webView: WKWebView) async -> Any? {
        let script: String = {
            let variablesJSON = Self.toJSON(variables)
            let extensionsJSON = Self.toJSON(["persistedQuery": ["version": 1, "sha256Hash": sha256Hash]])
            let url = "https://store.epicgames.com/graphql?operationName=\(operationName)&variables=\(variablesJSON)&extensions=\(extensionsJSON)"
            return """
            fetch("\(url)").then(function (response) { return response.json(); })
            """
        }()

        do {
            return try await webView.evaluateJavaScript(script)
        } catch {
            return nil
        }
    }

    /// Walks a nested dictionary with the given key path.
    static func json(_ value: Any, path: [String]) -> Any? {
        var current = value
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    private static func toJSON(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? string
    }
}
#Preview {
    StoreView()
}
