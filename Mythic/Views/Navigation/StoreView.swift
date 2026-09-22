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

        // After the (deep-linked) page renders, resolve the pending game title
        // to its exact product page and navigate there; failure leaves the
        // search/browse page visible as a fallback.
        .onChange(of: url) {
            guard ViewRouter.shared.pendingGameLookup != nil else { return }
            Task { @MainActor in await resolvePendingGameLookup() }
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

    /// Resolves the pending game lookup (set when a library card was tapped):
    /// queries Epic's own search APIs from inside the web view's page context
    /// (bare URLSession requests hit Cloudflare) for the game's product page
    /// slug, then navigates to it. On any failure the initial page (the
    /// browse/search results) remains as a fallback.
    @MainActor
    private func resolvePendingGameLookup() async {
        guard let title = ViewRouter.shared.pendingGameLookup,
              let webView = WebView.retainedWebView else { return }
        defer { ViewRouter.shared.pendingGameLookup = nil }

        // 1. Autocomplete search for the title → first offer's ids.
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
        guard let search = await StoreSlugResolver.runPersistedQuery(
            operationName: "primarySearchAutocomplete",
            variables: searchVariables,
            sha256Hash: "be4fe909f9a35f9704db7fed06fc4a47fc798ec0a6cbfa24d737aec2465904fa",
            in: webView
        ) else { return }

        guard
            let elements = StoreSlugResolver.json(search, path: ["data", "Catalog", "searchStore", "elements"]) as? [[String: Any]],
            let firstOffer = elements.first,
            let offerID = firstOffer["offerId"] as? String,
            let sandboxID = firstOffer["sandboxId"] as? String
        else { return }

        // 2. Offer details → the product page slug.
        let offerVariables: [String: Any] = [
            "locale": "en-US",
            "country": "CN",
            "offerId": offerID,
            "sandboxId": sandboxID,
        ]
        guard let offer = await StoreSlugResolver.runPersistedQuery(
            operationName: "getCatalogOffer",
            variables: offerVariables,
            sha256Hash: "0bd79d7aaf89de3693abb813eec8b664321fab84037cbb968730631c8afe9a9d",
            in: webView
        ) else { return }

        guard
            let pageSlug = StoreSlugResolver.json(offer, path: ["data", "Catalog", "catalogOffer", "catalogNs", "pageSlug"]) as? String,
            !pageSlug.isEmpty,
            let target = URL(string: "https://store.epicgames.com/p/\(pageSlug)")
        else { return }

        url = target
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
