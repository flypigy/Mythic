//
//  WebView.swift
//  Mythic
//
// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import WebKit
import OSLog

struct WebView: NSViewRepresentable {
    /// External navigation target. Only *changing* this value triggers a load —
    /// user navigation inside the page (including SPA pushState) is never reset
    /// by SwiftUI re-renders.
    var url: URL?
    var datastore: WKWebsiteDataStore = .default()

    @Binding var error: Error?
    var canGoBack: Binding<Bool>?
    var canGoForward: Binding<Bool>?
    /// Called after the web view finishes loading a page.
    var onPageLoaded: ((WKWebView) -> Void)? = nil

    let log = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "WebView"
    )

    /// Retained WKWebView. NavigationLink destinations are destroyed when
    /// popped, so without this, switching Library ↔ Store recreated the web
    /// view and reset the store page back to its landing URL every time.
    static var retainedWebView: WKWebView?

    func makeNSView(context: Context) -> WKWebView {
        if let retained = Self.retainedWebView {
            retained.navigationDelegate = context.coordinator
            context.coordinator.sync(to: retained)
            return retained
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = datastore

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        if let url {
            context.coordinator.lastAssignedURL = url
            webView.load(URLRequest(url: url))
        }

        Self.retainedWebView = webView
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onPageLoaded = onPageLoaded

        // Mirror the live URL out (covers SPA pushState navigation, which never
        // hits the navigation delegate), so page switches can restore it.
        ViewRouter.lastKnownStoreURL = nsView.url

        // Load only when the caller explicitly targets a different page.
        if let url, url != context.coordinator.lastAssignedURL {
            context.coordinator.lastAssignedURL = url
            if nsView.url != url {
                nsView.load(URLRequest(url: url))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        var lastAssignedURL: URL?
        var onPageLoaded: ((WKWebView) -> Void)?

        init(_ parent: WebView) {
            self.parent = parent
        }

        /// Adopt the current state of a reused web view into a fresh
        /// coordinator (new coordinator instances are created whenever the
        /// SwiftUI view identity is recreated).
        func sync(to webView: WKWebView) {
            lastAssignedURL = webView.url
            parent.error = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation, withError error: Error) {
            parent.log.error("\(error.localizedDescription)")
            parent.error = error
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation) {
            parent.canGoBack?.wrappedValue = webView.canGoBack
            parent.canGoForward?.wrappedValue = webView.canGoForward
            ViewRouter.lastKnownStoreURL = webView.url
            onPageLoaded?(webView)
        }
    }
}

#Preview {
    WebView(url: .init(string: "https://example.com")!, error: .constant(nil))
}
