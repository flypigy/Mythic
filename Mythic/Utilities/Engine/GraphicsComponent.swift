//
//  GraphicsComponent.swift
//  Mythic
//
//  Created by ZCode on 13/8/2026.
//

// Copyright © 2023-2025 vapidinfinity. All rights reserved.

import Foundation
import OSLog

/// Manages downloadable graphics translation layers (DXVK, DXMT) that can replace
/// the Engine's bundled DirectX DLLs. Each component is versioned independently and
/// downloaded from its upstream GitHub releases.
final class GraphicsComponent {
    static let log: Logger = .custom(category: "GraphicsComponent")

    /// Which translation layer to manage.
    enum Component: String, CaseIterable {
        case dxvk
        case dxmt

        /// The GitHub repository that publishes releases for this component.
        var repository: (owner: String, repo: String) {
            switch self {
            case .dxvk: ("doitsujin", "dxvk")
            case .dxmt: ("3Shain", "dxmt")
            }
        }

        /// The on-disk subdirectory (under `Engine.directory`) where this component's
        /// DLLs are stored. Lower-case to match the existing engine layout.
        var directoryName: String { rawValue }

        /// The directory URL where this component's downloaded DLLs live.
        var directoryURL: URL { Engine.directory.appending(path: directoryName) }

        /// A human-readable display name.
        var displayName: String {
            switch self {
            case .dxvk: "DXVK"
            case .dxmt: "DXMT"
            }
        }
    }

    /// A single downloadable release of a component, parsed from the GitHub releases API.
    struct Release: Codable, Identifiable, Equatable {
        /// The release tag (e.g. "v3.0.2"). Used as the stable identifier.
        let tagName: String
        let publishedAt: Date?
        /// The downloadable tarball (.tar.gz) URL. DXVK and DXMT both ship a single asset.
        let downloadURL: URL
        /// Human-readable tarball filename (for logging).
        let fileName: String

        var id: String { tagName }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case publishedAt = "published_at"
            case assets
        }

        /// A minimal representation of a GitHub release asset.
        private struct Asset: Codable {
            let name: String
            let browserDownloadURL: String
            let size: Int

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
                case size
            }
        }

        init(tagName: String, downloadURL: URL, fileName: String, publishedAt: Date? = nil) {
            self.tagName = tagName
            self.downloadURL = downloadURL
            self.fileName = fileName
            self.publishedAt = publishedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try container.decode(String.self, forKey: .tagName)
            publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)

            // Pick the right asset: prefer the non-native tarball for DXVK (dxvk-X.tar.gz,
            // not dxvk-native-...), and the builtin tarball for DXMT (dxmt-X-builtin.tar.gz).
            let assets = try container.decode([Asset].self, forKey: .assets)

            // Heuristic: choose the first .tar.gz asset. DXVK's primary asset sorts
            // before the native variant; DXMT has a single builtin asset.
            let chosen = assets.first { $0.name.hasSuffix(".tar.gz") }
            guard let chosen else {
                throw DecodingError.dataCorruptedError(forKey: .assets, in: container,
                                                       debugDescription: "No .tar.gz asset found")
            }

            guard let url = URL(string: chosen.browserDownloadURL) else {
                throw DecodingError.dataCorruptedError(forKey: .assets, in: container,
                                                       debugDescription: "Invalid download URL")
            }
            downloadURL = url
            fileName = chosen.name
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(tagName, forKey: .tagName)
            try container.encodeIfPresent(publishedAt, forKey: .publishedAt)
            // Note: assets are not re-encoded; this struct is read-mostly.
        }
    }

    // MARK: - Fetching releases

    /// Fetches the list of available releases for a component from GitHub.
    /// Results are limited to recent releases to stay within API rate limits.
    /// - Parameter component: Which component to query.
    /// - Parameter maxCount: Maximum number of releases to return (default 15).
    /// - Returns: Releases sorted newest-first.
    static func fetchReleases(for component: Component, maxCount: Int = 15) async throws -> [Release] {
        let repo = component.repository
        let urlString = "https://api.github.com/repos/\(repo.owner)/\(repo.repo)/releases?per_page=\(maxCount)"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        // GitHub asks for an Accept header; this returns stable JSON.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            log.error("GitHub releases API for \(component.displayName) returned \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }

        // Decode raw JSON and build releases manually, skipping any release that
        // has no downloadable .tar.gz asset (e.g. prereleases without assets).
        // This avoids a single bad release aborting the entire decode.
        struct RawRelease: Codable {
            let tagName: String
            let publishedAt: Date?
            let assets: [Asset]
        }
        struct Asset: Codable {
            let name: String
            let browserDownloadURL: String
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let rawReleases = try decoder.decode([RawRelease].self, from: data)

        return rawReleases.compactMap { raw in
            // Find the first .tar.gz asset (DXVK has multiple, DXMT typically one).
            guard let asset = raw.assets.first(where: { $0.name.hasSuffix(".tar.gz") }),
                  let url = URL(string: asset.browserDownloadURL) else {
                return nil // skip releases without a downloadable tarball
            }
            return Release(tagName: raw.tagName, downloadURL: url, fileName: asset.name, publishedAt: raw.publishedAt)
        }
    }

    // MARK: - Installation

    /// Downloads and installs a specific release, replacing the component's DLLs in the
    /// Engine directory. Streams download/install progress like `Engine.install()`.
    /// - Parameters:
    ///   - release: The release to install.
    ///   - component: Which component this release belongs to.
    /// - Returns: An async throwing stream of install progress updates.
    static func install(_ release: Release, for component: Component) -> AsyncThrowingStream<Engine.InstallProgress, Error> {
        AsyncThrowingStream { continuation in
            Task(priority: .high) {
                let task = URLSession.shared.downloadTask(with: release.downloadURL) { file, response, error in
                    guard error == nil else { continuation.finish(throwing: error!); return }
                    if let httpResponse = response as? HTTPURLResponse,
                       !(200...299).contains(httpResponse.statusCode) {
                        continuation.finish(throwing: URLError(.badServerResponse)); return
                    }
                    guard let file else {
                        continuation.finish(throwing: CocoaError(.fileNoSuchFile)); return
                    }

                    Task(priority: .userInitiated) {
                        let installationProgress: Progress = .init(totalUnitCount: 100)

                        do {
                            continuation.yield(.init(stage: .installing, progress: installationProgress))

                            try extractAndInstall(tarball: file, for: component, version: release.tagName)

                            installationProgress.completedUnitCount = 100
                            continuation.yield(.init(stage: .installing, progress: installationProgress))

                            log.notice("Installed \(component.displayName) \(release.tagName)")
                            continuation.finish()
                        } catch {
                            log.error("Failed to install \(component.displayName) \(release.tagName): \(error.localizedDescription)")
                            try? FileManager.default.removeItem(atPath: file.path)
                            continuation.finish(throwing: error)
                        }
                    }
                }

                Task(priority: .utility) {
                    while case .running = task.state {
                        continuation.yield(Engine.InstallProgress(stage: .downloading, progress: task.progress))
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    continuation.yield(Engine.InstallProgress(stage: .downloading, progress: task.progress))
                }

                task.resume()
            }
        }
    }

    /// Extracts a downloaded tarball and installs the component's DLLs into the Engine directory.
    ///
    /// DXVK/DXMT tarballs contain a top-level folder (e.g. `dxvk-3.0.2/`) with `x32/` and `x64/`
    /// subdirectories. This function extracts to a temp directory, locates those subdirectories,
    /// and copies them into the component's Engine directory.
    private static func extractAndInstall(tarball: URL, for component: Component, version: String) throws {
        let tempDir = try FileManager.default.createUniqueTemporaryDirectory()

        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Extract the tarball (gzip, not xz — DXVK/DXMT ship .tar.gz).
        let process = Process()
        process.executableURL = .init(filePath: "/usr/bin/tar")
        process.arguments = ["-xzf", tarball.path, "-C", tempDir.path]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "N/A"
            log.error("tar extraction failed for \(component.displayName): \(stderr)")
            throw CocoaError(.fileWriteUnknown)
        }

        // Locate the x32/ and x64/ directories inside the extracted archive.
        // They may be nested inside a version-named top-level folder.
        guard let (x32URL, x64URL) = findArchDirectories(in: tempDir) else {
            log.error("Could not find x32/ and x64/ directories in \(component.displayName) archive")
            throw CocoaError(.fileNoSuchFile)
        }

        // Prepare the component directory: remove old contents, recreate clean.
        let dest = component.directoryURL
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        // Copy x32/ and x64/ into the component directory.
        try FileManager.default.copyItem(at: x32URL, to: dest.appending(path: "x32"))
        try FileManager.default.copyItem(at: x64URL, to: dest.appending(path: "x64"))

        // Record the installed version for display.
        let versionFile = dest.appending(path: ".version")
        try version.data(using: .utf8)?.write(to: versionFile)

        // Clean up the downloaded tarball.
        try? FileManager.default.removeItem(at: tarball)
    }

    /// Recursively searches a directory for sibling `x32/` and `x64/` folders (the DXVK/DXMT
    /// layout). Returns their URLs if both are found.
    private static func findArchDirectories(in directory: URL) -> (x32: URL, x64: URL)? {
        let fm = FileManager.default

        // Check direct children first (common case: archive top-level has x32/x64).
        let directX32 = directory.appending(path: "x32")
        let directX64 = directory.appending(path: "x64")
        if fm.fileExists(atPath: directX32.path) && fm.fileExists(atPath: directX64.path) {
            return (directX32, directX64)
        }

        // Search one level deeper (when there's a version-named wrapper folder).
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }

        for subdirectory in contents where (try? subdirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let nestedX32 = subdirectory.appending(path: "x32")
            let nestedX64 = subdirectory.appending(path: "x64")
            if fm.fileExists(atPath: nestedX32.path) && fm.fileExists(atPath: nestedX64.path) {
                return (nestedX32, nestedX64)
            }
        }

        return nil
    }

    // MARK: - Querying installed state

    /// Returns the currently installed version tag for a component, if a custom version
    /// was downloaded via this manager. Returns `nil` if only the engine's bundled version
    /// is present (or the component isn't installed).
    static func installedVersion(for component: Component) -> String? {
        let versionFile = component.directoryURL.appending(path: ".version")
        return try? String(contentsOf: versionFile, encoding: .utf8)
    }

    /// Whether a component's DLLs are present in the Engine directory (either the bundled
    /// version or a custom-downloaded one).
    static func isInstalled(_ component: Component) -> Bool {
        let x32 = component.directoryURL.appending(path: "x32")
        return FileManager.default.fileExists(atPath: x32.path)
    }
}
