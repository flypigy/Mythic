//
//  StoreView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 10/9/2023.
//

// Copyright © 2023-2025 vapidinfinity

import CFNetwork
import SwiftUI
import SwordRPC
import WebKit

struct StoreView: View {
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

        .navigationTitle("Store")

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

    // MARK: - Exact game page resolution

    /// Resolves the pending game lookup (set when a library card was tapped)
    /// to the game's exact product page:
    ///
    /// 1. Primary: one POST to the launcher GraphQL endpoint (no Cloudflare)
    ///    mapping the game's catalog namespace to its product-home slug.
    ///    The namespace comes from legendary's local metadata.
    /// 2. Fallback: scrape the rendered browse page's DOM for the first
    ///    product link (preferring a title match).
    ///
    /// Any failure leaves the browse/search page visible.
    @MainActor
    private func resolvePendingGameLookup() async {
        // Always clear the pending state, whichever way this resolves, so it
        // can never leak into a later page load.
        defer {
            ViewRouter.shared.pendingStoreNamespace = nil
            ViewRouter.shared.pendingGameLookup = nil
        }

        guard ViewRouter.shared.pendingGameLookup != nil
                || ViewRouter.shared.pendingStoreNamespace != nil,
              let webView = WebView.retainedWebView,
              webView.url?.path.contains("/browse") == true else { return }

        // A newer card tap (beginNavigation) supersedes whatever this
        // resolution would navigate to.
        let generation = ViewRouter.shared.navigationGeneration

        if let namespace = ViewRouter.shared.pendingStoreNamespace,
           let slug = await StoreSlugResolver.productSlug(namespace: namespace),
           let target = URL(string: "https://store.epicgames.com/p/\(slug)") {
            guard generation == ViewRouter.shared.navigationGeneration else { return }
            url = target
            return
        }

        if let title = ViewRouter.shared.pendingGameLookup,
           let href = await StoreSlugResolver.scrapeFirstProductLink(matching: title, in: webView),
           href.hasPrefix("/p/"),
           let target = URL(string: "https://store.epicgames.com" + href) {
            guard generation == ViewRouter.shared.navigationGeneration else { return }
            url = target
        }
    }
}

/// Slug resolution helpers.
enum StoreSlugResolver {
    /// Maps an Epic catalog namespace to its product-home page slug via the
    /// launcher GraphQL endpoint (Heroic's approach — no Cloudflare).
    /// Direct connections to Epic endpoints are intermittently reset (same
    /// interference the library sync works around), so on failure the query
    /// retries through the user's shell proxy (e.g. Clash on :7890).
    static func productSlug(namespace: String) async -> String? {
        if let slug = await query(namespace: namespace, proxy: nil) { return slug }

        let proxyEnvironment = await Legendary.shellProxyEnvironment()
        if let proxy = proxyEnvironment["HTTPS_PROXY"] {
            return await query(namespace: namespace, proxy: proxy)
        }
        return nil
    }

    private static func query(namespace: String, proxy: String?) async -> String? {
        var request = URLRequest(url: URL(string: "https://launcher.store.epicgames.com/graphql")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) EpicGamesLauncher",
            forHTTPHeaderField: "User-Agent"
        )
        let query = "{ Catalog { catalogNs(namespace: \"\(namespace)\") { mappings(pageType: \"productHome\") { pageSlug pageType } } } }"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])

        let session: URLSession = {
            guard let proxy,
                  let proxyURL = URL(string: proxy),
                  let host = proxyURL.host,
                  let port = proxyURL.port
            else { return .shared }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: host,
                kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: host,
                kCFNetworkProxiesHTTPSPort: port,
            ]
            return URLSession(configuration: configuration)
        }()

        guard
            let (data, _) = try? await session.data(for: request),
            let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let mappings = json(response, path: ["data", "Catalog", "catalogNs", "mappings"]) as? [[String: Any]]
        else { return nil }

        return mappings
            .first(where: { $0["pageType"] as? String == "productHome" })?["pageSlug"] as? String
    }

    /// Fallback: poll the rendered browse page's DOM for the first product
    /// link, preferring one whose text matches the title.
    static func scrapeFirstProductLink(matching title: String, in webView: WKWebView) async -> String? {
        let lowered = title.lowercased()
        let script = """
        (function () {
            const title = \(javaScriptString(lowered));
            const links = [...document.querySelectorAll('a[href*="/p/"]')];
            if (!links.length) return null;
            const match = links.find(a => a.textContent.toLowerCase().includes(title));
            return (match ?? links[0]).getAttribute('href');
        })()
        """

        for _ in 0..<16 {
            if let result = try? await webView.evaluateJavaScript(script), let href = result as? String {
                return href
            }
            try? await Task.sleep(for: .seconds(0.5))
        }
        return nil
    }

    private static func javaScriptString(_ value: String) -> String {
        // JSONEncoder output is a properly quoted, escaped JS string literal.
        (try? JSONEncoder().encode(value))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
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
}
#Preview {
    StoreView()
}
