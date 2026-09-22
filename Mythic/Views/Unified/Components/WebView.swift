//
//  WebView.swift
//  Mythic
//
// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import WebKit
import OSLog

struct WebView: NSViewRepresentable {
    /// Loading target. `nil` (or a URL equal to the web view's current page or
    /// the coordinator's last reported page) means "leave the web view alone" —
    /// user navigation inside the page must not be reset by SwiftUI re-renders.
    var url: URL?
    var datastore: WKWebsiteDataStore = .default()

    @Binding var error: Error?
    var canGoBack: Binding<Bool>?
    var canGoForward: Binding<Bool>?

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
            return retained
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = datastore

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        if let url {
            webView.load(URLRequest(url: url))
        }

        Self.retainedWebView = webView
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Load only when an external caller explicitly targets a different page.
        // `lastReportedURL` distinguishes those requests from SwiftUI body
        // re-evaluations that carry a stale `url` while the user has already
        // navigated elsewhere inside the page.
        if let url, url != nsView.url, url != context.coordinator.lastReportedURL {
            nsView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        var lastReportedURL: URL?

        init(_ parent: WebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation, withError error: Error) {
            parent.log.error("\(error.localizedDescription)")
            parent.error = error
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation) {
            lastReportedURL = webView.url
            parent.canGoBack?.wrappedValue = webView.canGoBack
            parent.canGoForward?.wrappedValue = webView.canGoForward
        }
    }
}

#Preview {
    WebView(url: .init(string: "https://example.com")!, error: .constant(nil))
}
