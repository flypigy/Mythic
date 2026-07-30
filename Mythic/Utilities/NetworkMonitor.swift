//
//  NetworkMonitor.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 8/2/2024.
//

// Reference: https://arc.net/l/quote/ivjknjyv

// Copyright © 2023-2025 vapidinfinity

import Foundation
import Network
import OSLog
import SwiftUI

final class NetworkMonitor: ObservableObject, @unchecked Sendable {
    static let shared: NetworkMonitor = .init()

    static let log: Logger = .network

    private let monitor: NWPathMonitor = .init()
    private let queue: DispatchQueue = .init(label: "NetworkMonitor", qos: .background)

    @MainActor @Published private(set) var isConnected: Bool = false

    @MainActor @Published private(set) var epicAccessibilityState: NetworkAccessibility?
    enum NetworkAccessibility {
        case accessible
        case checking
        case inaccessible
    }

     private init() {
         monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }

            Task { @MainActor in
                self.isConnected = (path.status == .satisfied)

                if self.isConnected {
                    try? await self.checkEpicAccessibility()
                }
            }
        }

         monitor.start(queue: queue)
    }

    /// Per-request timeout for an Epic probe. Short, so a dead host fails fast and we move on to
    /// the next fallback within a reasonable total budget. Bump this if probes time out on slow links.
    private static let epicProbeTimeout: TimeInterval = 5

    /// Hosts that legendary actually talks to, probed in priority order (first reachable wins).
    ///
    /// The Cloudflare-fronted `epicgames.com` marketing site is deliberately avoided — its aggressive
    /// bot protection routinely returns HTTP 403 to non-browser clients, which previously marked Epic
    /// as unreachable and forced every legendary call into `--offline`.
    ///
    /// These are the same account/catalog hosts that `legendary.api.egs` authenticates against;
    /// a 404 from their root path is expected and proves the network path to Epic is up.
    ///
    /// To add/remove a probe target: just edit this list. Order matters — entries earlier in the
    /// array are tried first and short-circuit the rest on success. Prefer API hosts
    /// (`*.ol.epicgames.com`, `graphql.epicgames.com`) over the Cloudflare-fronted marketing site.
    private static let epicProbeURLStrings: [String] = [
        "https://account-public-service-prod03.ol.epicgames.com", // primary: account/OAuth host
        "https://graphql.epicgames.com"                           // fallback: catalog/graphql host
    ]

    private func checkEpicAccessibility() async throws {
        await MainActor.run {
            self.epicAccessibilityState = .checking
        }

        var lastError: Error?
        var anyReachable = false

        nextProbe: for urlstring in Self.epicProbeURLStrings {
            // Only a genuine network-layer failure (timeout, DNS, connection refused, etc.) indicates
            // the host is unreachable. Any HTTP response — including 403/404 from Cloudflare or the API
            // host — means we *can* reach Epic's infrastructure, so we must not degrade to `--offline`.
            switch await probe(urlString: urlstring) {
            case .reachable:
                anyReachable = true
                break nextProbe // first reachable host is enough; no need to try fallbacks
            case .unreachable(let error):
                lastError = error
                continue nextProbe // try the next probe host
            case .cancelled:
                // Cancellation isn't a reachability signal — bail out and leave the previous state intact.
                return
            }
        }

        await MainActor.run {
            self.epicAccessibilityState = anyReachable ? .accessible : .inaccessible
        }

        if !anyReachable, let lastError {
            Self.log.error("All Epic probe hosts unreachable; marking Epic inaccessible. Last error: \(String(describing: lastError))")
        }
    }

    /// Probe a single URL. Returns `.reachable` for any HTTP response, `.unreachable` for a
    /// genuine network-layer failure, and `.cancelled` if the request was cancelled.
    private func probe(urlString: String) async -> ProbeResult {
        guard let url = URL(string: urlString) else { return .unreachable(URLError(.badURL)) }

        let request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: epicProbeTimeout
        )

        do {
            _ = try await URLSession.shared.data(for: request)
            return .reachable
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                return .cancelled
            }
            return .unreachable(error)
        }
    }

    private enum ProbeResult {
        case reachable
        case unreachable(Error)
        case cancelled
    }
}

#Preview {
    ContentView()
        .environmentObject(NetworkMonitor.shared)
}
