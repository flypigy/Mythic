//
//  CachedAsyncImage.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 1/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import CryptoKit

enum CachedAsyncImagePhase {
    case empty
    case success(Image)
    case failure(Error)
}

/// `AsyncImage` replacement with memory and disk caching.
///
/// AsyncImage in lazy containers (LazyVGrid) has two problems: a download task
/// cancelled by view recycling latches the view into a "cancelled" failure
/// state with no retry, and every re-appearance re-downloads the image.
/// This view uses `.task(id:)` semantics instead — a cancelled load is simply
/// restarted when the view reappears, and completed downloads are served from
/// (memory or disk) cache instantly.
struct CachedAsyncImage<Content: View>: View {
    var url: URL
    @ViewBuilder var content: (CachedAsyncImagePhase) -> Content

    @State private var phase: CachedAsyncImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) {
                guard !Task.isCancelled else { return }
                if case .success = phase { return }

                do {
                    let image = try await RemoteImageCache.shared.image(for: url)
                    guard !Task.isCancelled else { return }
                    phase = .success(image)
                } catch is CancellationError {
                    // view disappeared mid-download; .task restarts on reappear
                } catch URLError.cancelled {
                    // same, URLSession surfaces recycling as URLError
                } catch {
                    guard !Task.isCancelled else { return }
                    phase = .failure(error)
                }
            }
    }
}

/// Process-wide image cache: NSCache in front of a per-URL file in
/// ~/Library/Caches/Mythic/GameImages (keyed by SHA-256 of the URL string).
actor RemoteImageCache {
    static let shared = RemoteImageCache()

    private let memoryCache = NSCache<NSURL, NSImage>()
    private let directory: URL

    private init() {
        memoryCache.countLimit = 300

        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        directory = cachesURL.appending(path: "Mythic/GameImages")

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for url: URL) async throws -> Image {
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return Image(nsImage: cached)
        }

        let fileURL = Self.cacheFileURL(for: url, in: directory)

        if let data = try? Data(contentsOf: fileURL), let image = NSImage(data: data) {
            memoryCache.setObject(image, forKey: url as NSURL)
            return Image(nsImage: image)
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        guard let image = NSImage(data: data) else {
            throw CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "Received invalid image data."])
        }

        memoryCache.setObject(image, forKey: url as NSURL)
        try? data.write(to: fileURL, options: .atomic)

        return Image(nsImage: image)
    }

    private static func cacheFileURL(for url: URL, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: hex).appendingPathExtension("img")
    }
}
