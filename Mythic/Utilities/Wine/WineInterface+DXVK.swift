//
//  WineInterface+DXVK.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 11/11/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation

extension Wine {
    /// Replaces the Engine’s DirectX DLLs in the specified Wine container with their
    /// DXVK (Vulkan-based) or DXMT (Metal-based) equivalents.
    ///
    /// Both DXVK and DXMT override the same set of DLLs (`d3d10core`, `d3d11`, `dxgi`),
    /// so they are mutually exclusive — a container should use one or the other.
    final class DXVK {
        /// The DLLs that DXVK/DXMT override, copied for both x64 and x32.
        private static let overrideDLLs = ["d3d10core.dll", "d3d11.dll", "dxgi.dll"]

        /// Replaces the Engine’s DirectX DLLs in the specified Wine container with their DXVK equivalents.
        static func install(toContainerAtURL containerURL: URL) async throws {
            try install(from: Engine.directory.appending(path: "dxvk"), toContainerAtURL: containerURL)
        }

        /// Replaces the Engine’s DirectX DLLs in the specified Wine container with their DXMT equivalents.
        static func installDXMT(toContainerAtURL containerURL: URL) async throws {
            try install(from: Engine.directory.appending(path: "dxmt"), toContainerAtURL: containerURL)
        }

        /// Shared install logic: copies override DLLs from a component directory
        /// (`Engine/dxvk` or `Engine/dxmt`) into the container's Windows system directories.
        ///
        /// - Parameters:
        ///   - componentDirectory: The directory containing `x64/` and `x32/` subdirs with override DLLs.
        ///   - containerURL: The Wine container (prefix) root URL.
        private static func install(from componentDirectory: URL, toContainerAtURL containerURL: URL) async throws {
            try Wine.killAll(at: containerURL)

            // remove existing d3d/dxgi dlls (both x64 and x32) so the override takes effect cleanly
            // x64 — drive_c/windows/system32/
            for dll in overrideDLLs {
                try FileManager.default.removeItemIfExists(at: containerURL.appending(path: "drive_c/windows/system32/\(dll)"))
            }
            // x32 — drive_c/windows/syswow64/
            for dll in overrideDLLs {
                try FileManager.default.removeItemIfExists(at: containerURL.appending(path: "drive_c/windows/syswow64/\(dll)"))
            }

            // copy override dlls from the component directory
            // x64
            for dll in overrideDLLs {
                try FileManager.default.forceCopyItem(
                    at: componentDirectory.appending(path: "x64/\(dll)"),
                    to: containerURL.appending(path: "drive_c/windows/system32")
                )
            }
            // x32
            for dll in overrideDLLs {
                try FileManager.default.forceCopyItem(
                    at: componentDirectory.appending(path: "x32/\(dll)"),
                    to: containerURL.appending(path: "drive_c/windows/syswow64")
                )
            }
        }

        // to remove DXVK/DXMT, you must run wineboot in update mode
    }
}
