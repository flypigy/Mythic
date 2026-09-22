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

    /// Resolves the pending game lookup (set when a library card was tapped)
    /// to the game's exact product page:
    ///
    /// 1. Primary: Epic's own GraphQL — autocomplete the title to an offer,
    ///    then fetch the offer's catalog namespace slug. Both are persisted
    ///    queries fetched from inside the retained store web view's page
    ///    context (bare URLSession requests hit Cloudflare).
    /// 2. Fallback: scrape the rendered browse page's DOM for the first
    ///    product link (preferring a title match).
    ///
    /// Any failure leaves the browse/search page visible.
    @MainActor
    private func resolvePendingGameLookup() async {
        guard let title = ViewRouter.shared.pendingGameLookup,
              let webView = WebView.retainedWebView,
              webView.url?.path.contains("/browse") == true else { return }
        defer { ViewRouter.shared.pendingGameLookup = nil }

        if let slug = await StoreSlugResolver.productSlug(for: title, in: webView),
           let target = URL(string: "https://store.epicgames.com/p/\(slug)") {
            url = target
            return
        }

        if let href = await StoreSlugResolver.scrapeFirstProductLink(matching: title, in: webView),
           let target = URL(string: "https://store.epicgames.com" + href) {
            url = target
        }
    }
}

/// Slug resolution helpers, run inside the store page's JS context (inheriting
/// its Cloudflare clearance — bare URLSession requests are blocked).
enum StoreSlugResolver {
    /// Two-step persisted GraphQL lookup: autocomplete the title to an offer,
    /// then read that offer's catalog namespace page slug.
    static func productSlug(for title: String, in webView: WKWebView) async -> String? {
        let searchVariables: [String: Any] = [
            "allowCountries": "CN",
            "category": "games/edition/base|bundles/games|games/edition|editors|addons|games/demo|software/edition/base|games/experience|subscription",
            "count": 5,
            "country": "CN",
            "keywords": title,
            "locale": "en-US",
            "sortBy": NSNull(),
            "sortDir": "DESC",
        ]
        guard let search = await runPersistedQuery(
            operationName: "primarySearchAutocomplete",
            variables: searchVariables,
            sha256Hash: "be4fe909f9a35f9704db7fed06fc4a47fc798ec0a6cbfa24d737aec2465904fa",
            in: webView
        ) else { return nil }

        // Prefer the element whose title matches exactly; else the top hit.
        guard
            let elements = json(search, path: ["data", "Catalog", "searchStore", "elements"]) as? [[String: Any]],
            !elements.isEmpty
        else { return nil }

        let lowered = title.lowercased()
        let offer = elements.first { ($0["title"] as? String)?.lowercased() == lowered }
            ?? elements.first

        guard
            let offerID = offer?["offerId"] as? String,
            let sandboxID = offer?["sandboxId"] as? String
        else { return nil }

        let offerVariables: [String: Any] = [
            "locale": "en-US",
            "country": "CN",
            "offerId": offerID,
            "sandboxId": sandboxID,
        ]
        guard let offerDetails = await runPersistedQuery(
            operationName: "getCatalogOffer",
            variables: offerVariables,
            sha256Hash: "0bd79d7aaf89de3693abb813eec8b664321fab84037cbb968730631c8afe9a9d",
            in: webView
        ) else { return nil }

        guard
            let pageSlug = json(offerDetails, path: ["data", "Catalog", "catalogOffer", "catalogNs", "pageSlug"]) as? String,
            !pageSlug.isEmpty
        else { return nil }

        return pageSlug
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

    static func runPersistedQuery(operationName: String, variables: [String: Any], sha256Hash: String, in webView: WKWebView) async -> Any? {
        let script: String = {
            let variablesJSON = toJSON(variables)
            let extensionsJSON = toJSON(["persistedQuery": ["version": 1, "sha256Hash": sha256Hash]])
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

    private static func javaScriptString(_ value: String) -> String {
        // JSONEncoder output is a properly quoted, escaped JS string literal.
        (try? JSONEncoder().encode(value))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
#Preview {
    StoreView()
}
