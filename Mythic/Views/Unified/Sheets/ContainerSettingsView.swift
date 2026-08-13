//
//  ContainerSettings.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 7/2/2024.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI

struct ContainerSettingsView: View {
    @Binding var selectedContainerURL: URL?
    var withPicker: Bool

    @ObservedObject private var variables: VariableManager = .shared

    @State private var containerScope: Wine.Container.Scope = .individual

    @State private var retinaMode: Bool = Wine.Container.Settings().retinaMode
    @State private var modifyingRetinaMode: Bool = true // keep progressview displayed until async fetching is complete
    @State private var retinaModeSuccess: Bool?

    // Translation layer toggle state (D3DMetal / DXMT / DXVK are mutually exclusive)
    @State private var modifyingTranslationLayer: Bool = false

    // Graphics component version selection state
    @State private var dxvkReleases: [GraphicsComponent.Release] = []
    @State private var dxmtReleases: [GraphicsComponent.Release] = []
    @State private var isFetchingReleases: Bool = false
    @State private var installingComponent: GraphicsComponent.Component?
    @State private var componentInstallProgress: Double = 0
    @State private var componentInstallError: String?
    @State private var isComponentInstallErrorPresented: Bool = false

    @State private var windowsVersion: Wine.WindowsVersion = Wine.Container.Settings().windowsVersion
    @State private var modifyingWindowsVersion: Bool = true // keep progressview displayed until async fetching is complete
    @State private var windowsVersionSuccess: Bool?

    private func fetchRetinaModeStatus() async {
        guard let selectedContainerURL else { return }
        
        do {
            let fetchedRetinaMode = try await Wine.getRetinaMode(containerURL: selectedContainerURL)
            
            await MainActor.run(body: { retinaMode = fetchedRetinaMode })
            // intentionally separated, to prevent both variable updates from occuring during the same render cycle
            await MainActor.run {
                withAnimation {
                    modifyingRetinaMode = false
                }
            }
        } catch {
            retinaModeSuccess = false
        }
    }

    private func fetchWindowsVersion() async {
        guard let selectedContainerURL else { return }

        do {
            if let fetchedWindowsVersion = try await Wine.getWindowsVersion(containerURL: selectedContainerURL) {
                await MainActor.run(body: { windowsVersion = fetchedWindowsVersion })
                // intentionally separated, to prevent both variable updates from occuring during the same render cycle
                await MainActor.run {
                    withAnimation {
                        modifyingWindowsVersion = false
                    }
                }
            }
        } catch {
            windowsVersionSuccess = false
        }
    }

    // MARK: - Translation layer switching

    private enum TranslationLayer { case gptk, dxvk, dxmt }

    /// Switches the DirectX translation layer for the current container.
    /// D3DMetal (GPTK), DXVK, and DXMT are mutually exclusive — enabling one
    /// disables the others. When toggled off, falls back to GPTK (D3DMetal).
    private func switchTranslationLayer(to layer: TranslationLayer, enabled: Bool) {
        guard let selectedContainerURL,
              let container = try? Wine.getContainerObject(at: selectedContainerURL) else { return }

        Task(priority: .userInitiated) {
            await MainActor.run { modifyingTranslationLayer = true }
            defer { Task { @MainActor in modifyingTranslationLayer = false } }

            do {
                if !enabled {
                    // Turning off the current layer → revert to GPTK (D3DMetal).
                    // wineboot --update restores Wine's builtin DLLs.
                    try await Wine.boot(at: container.url, parameters: .update)
                    await MainActor.run {
                        container.settings.d3dmetal = true
                        container.settings.dxvk = false
                        container.settings.dxmt = false
                    }
                } else {
                    // Enable the selected layer, install its DLLs.
                    try await Wine.killAll(at: container.url)
                    switch layer {
                    case .gptk:
                        try await Wine.boot(at: container.url, parameters: .update)
                        await MainActor.run {
                            container.settings.d3dmetal = true
                            container.settings.dxvk = false
                            container.settings.dxmt = false
                        }
                    case .dxvk:
                        try await Wine.DXVK.install(toContainerAtURL: container.url)
                        await MainActor.run {
                            container.settings.d3dmetal = false
                            container.settings.dxvk = true
                            container.settings.dxmt = false
                        }
                    case .dxmt:
                        try await Wine.DXVK.installDXMT(toContainerAtURL: container.url)
                        await MainActor.run {
                            container.settings.d3dmetal = false
                            container.settings.dxvk = false
                            container.settings.dxmt = true
                        }
                    }
                }
            } catch {
                // On failure, leave settings unchanged.
            }
        }
    }

    var body: some View {
        if withPicker {
            if variables.getVariable("booting") != true {
                Picker("Current Container", selection: $selectedContainerURL) {
                    ForEach(Wine.containerObjects) { container in
                        Text(container.name)
                            .tag(container.url)
                    }
                }
            } else {
                HStack {
                    Text("Current Container")
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }

        if let selectedContainerURL,
           let container = try? Wine.getContainerObject(at: selectedContainerURL) {
            Group {
                Toggle("Performance HUD", isOn: Binding(
                    get: { container.settings.metalHUD },
                    set: { container.settings.metalHUD = $0 }
                ))
                .disabled(variables.getVariable("booting") == true)

                Toggle("Retina Mode", isOn: $retinaMode)
                    .disabled(variables.getVariable("booting") == true)
                    .task(priority: .high) {
                        // asynchronously fetch retina mode status upon view presentation
                        await fetchRetinaModeStatus()
                    }
                    .withOperationStatus(
                        operating: $modifyingRetinaMode,
                        successful: $retinaModeSuccess,
                        observing: $retinaMode,
                        placement: .leading
                    ) {
                        try? await Wine.toggleRetinaMode(containerURL: container.url, toggle: retinaMode)
                        container.settings.retinaMode = retinaMode
                        retinaModeSuccess = true
                    }

                Toggle("Enhanced Sync (MSync)", isOn: Binding(
                    get: { container.settings.msync },
                    set: { container.settings.msync = $0 }
                ))
                .disabled(variables.getVariable("booting") == true)

                Toggle("Advanced Vector Extensions (AVX2)", isOn: Binding(
                    get: { container.settings.avx2 },
                    set: { container.settings.avx2 = $0 }
                ))
                .disabled({
                    if #available(macOS 15.0, *) {
                        return false
                    }
                    return true
                }())
                .help({
                    guard #unavailable(macOS 15.0) else { return "" }
                    return "AVX2 is only supported on macOS Sequoia (15) or later."
                }())

                // MARK: - DirectX translation layer (D3DMetal / DXMT / DXVK, mutually exclusive)
                Toggle("GPTK (D3DMetal)", isOn: Binding(
                    get: { container.settings.d3dmetal },
                    set: { newValue in switchTranslationLayer(to: .gptk, enabled: newValue) }
                ))
                .disabled(modifyingTranslationLayer)

                Toggle("DXMT", isOn: Binding(
                    get: { container.settings.dxmt },
                    set: { newValue in switchTranslationLayer(to: .dxmt, enabled: newValue) }
                ))
                .disabled(modifyingTranslationLayer)

                Toggle("DXVK", isOn: Binding(
                    get: { container.settings.dxvk },
                    set: { newValue in switchTranslationLayer(to: .dxvk, enabled: newValue) }
                ))
                .disabled(modifyingTranslationLayer)

                Toggle("Asynchronous DXVK", isOn: Binding(
                    get: { container.settings.dxvkAsync },
                    set: { container.settings.dxvkAsync = $0 }
                ))
                .disabled(!container.settings.dxvk || modifyingTranslationLayer)

                // MARK: - Graphics component version selection
                GraphicsComponentSection(container: container,
                                         dxvkReleases: $dxvkReleases,
                                         dxmtReleases: $dxmtReleases,
                                         isFetchingReleases: $isFetchingReleases,
                                         installingComponent: $installingComponent,
                                         componentInstallProgress: $componentInstallProgress,
                                         isComponentInstallErrorPresented: $isComponentInstallErrorPresented,
                                         componentInstallError: $componentInstallError)

                Picker("Windows Version", selection: $windowsVersion) {
                    ForEach(Wine.WindowsVersion.allCases, id: \.self) { version in
                        Text("Windows® \(version.rawValue)").tag(version)
                    }
                }
                .task(priority: .high) {
                    // asynchronously fetch windows version upon view presentation
                    await fetchWindowsVersion()
                }
                .withOperationStatus(
                    operating: $modifyingWindowsVersion,
                    successful: $windowsVersionSuccess,
                    observing: $windowsVersion,
                    placement: .leading
                ) {
                    try await Wine.setWindowsVersion(containerURL: container.url, version: windowsVersion)
                    container.settings.windowsVersion = windowsVersion
                    windowsVersionSuccess = true
                }
            }
            .disabled(!Engine.isInstalled)
            .id(selectedContainerURL)
        } else if let selectedContainerURL,
                  Wine.containerExists(at: selectedContainerURL) {
            ContentUnavailableView(
                "Unable to retrieve container settings.",
                systemImage: "folder.badge.questionmark",
                description: Text("""
                This container (\(selectedContainerURL.prettyPath)) exists on disk,
                but the settings are inaccessible or corrupted.
                If this persists, please delete this container and create a new one.
                """)
            )
        } else {
            ContentUnavailableView(
                "Unable to locate container.",
                systemImage: "questionmark.folder",
                description: Text("""
                The container URL provided is invalid.
                If this container is not stored on an external device,
                Please remove it from Mythic.
                """)
            )
        }
    }
}

// MARK: - Graphics Component Version Selection

/// A collapsible section that lets the user download and install specific DXVK/DXMT versions
/// from GitHub. Version selection is global (replaces the Engine's bundled DLLs), but this
/// section lives in container settings alongside the DXVK/DXMT toggles.
private struct GraphicsComponentSection: View {
    @ObservedObject var container: Wine.Container

    @Binding var dxvkReleases: [GraphicsComponent.Release]
    @Binding var dxmtReleases: [GraphicsComponent.Release]
    @Binding var isFetchingReleases: Bool
    @Binding var installingComponent: GraphicsComponent.Component?
    @Binding var componentInstallProgress: Double
    @Binding var isComponentInstallErrorPresented: Bool
    @Binding var componentInstallError: String?

    @State private var isExpanded: Bool = false
    @State private var hasFetchedReleases: Bool = false
    @State private var installedDXVKVersion: String?
    @State private var installedDXMTVersion: String?

    var body: some View {
        Section("Downloadable Versions", isExpanded: $isExpanded) {
            // DXVK version selector
            versionRow(for: .dxvk,
                       releases: dxvkReleases,
                       installedVersion: installedDXVKVersion,
                       isEnabled: container.settings.dxvk)

            // DXMT version selector
            versionRow(for: .dxmt,
                       releases: dxmtReleases,
                       installedVersion: installedDXMTVersion,
                       isEnabled: container.settings.dxmt)
        }
        .onChange(of: isExpanded) { _, expanded in
            // Fetch releases once when first expanded.
            guard expanded, !hasFetchedReleases else { return }
            hasFetchedReleases = true
            Task { await fetchReleases() }
        }
        .task { await refreshInstalledVersions() }
        .alert("Installation failed", isPresented: $isComponentInstallErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(componentInstallError ?? "An unknown error occurred.")
        }
    }

    /// A single component's version picker row.
    @ViewBuilder
    private func versionRow(for component: GraphicsComponent.Component,
                            releases: [GraphicsComponent.Release],
                            installedVersion: String?,
                            isEnabled: Bool) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text("\(component.displayName) version")
                    .font(.body)
                if let installedVersion {
                    Text("Installed: \(installedVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if GraphicsComponent.isInstalled(component) {
                    Text("Bundled with engine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Bundled with engine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isFetchingReleases {
                ProgressView().controlSize(.small)
            } else if installingComponent == component {
                ProgressView(value: componentInstallProgress)
                    .frame(width: 80)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            } else if !releases.isEmpty {
                Menu {
                    ForEach(releases) { release in
                        Button(release.tagName) {
                            Task { await installRelease(release, for: component) }
                        }
                    }
                } label: {
                    Label("Choose version", systemImage: "arrow.down.circle")
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.borderlessButton)
                .disabled(!Engine.isInstalled)
            } else {
                Button("Retry") {
                    Task { await fetchReleases() }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Actions

    private func fetchReleases() async {
        await MainActor.run { isFetchingReleases = true }

        async let dxvk = try? GraphicsComponent.fetchReleases(for: .dxvk)
        async let dxmt = try? GraphicsComponent.fetchReleases(for: .dxmt)

        let (dxvkResult, dxmtResult) = await (dxvk, dxmt)

        await MainActor.run {
            dxvkReleases = dxvkResult ?? []
            dxmtReleases = dxmtResult ?? []
            isFetchingReleases = false
        }
    }

    private func refreshInstalledVersions() async {
        let dxvkVer = GraphicsComponent.installedVersion(for: .dxvk)
        let dxmtVer = GraphicsComponent.installedVersion(for: .dxmt)
        await MainActor.run {
            installedDXVKVersion = dxvkVer
            installedDXMTVersion = dxmtVer
        }
    }

    private func installRelease(_ release: GraphicsComponent.Release,
                                for component: GraphicsComponent.Component) async {
        await MainActor.run {
            installingComponent = component
            componentInstallProgress = 0
        }

        do {
            for try await progress in GraphicsComponent.install(release, for: component) {
                let fraction = progress.progress.fractionCompleted
                await MainActor.run {
                    switch progress.stage {
                    case .downloading:
                        componentInstallProgress = fraction * 0.8 // download is ~80% of total
                    case .installing:
                        componentInstallProgress = 0.8 + (fraction * 0.2)
                    }
                }
            }

            await MainActor.run {
                installingComponent = nil
                componentInstallProgress = 0
            }

            // Refresh the displayed installed version
            await refreshInstalledVersions()
        } catch {
            await MainActor.run {
                installingComponent = nil
                componentInstallError = error.localizedDescription
                isComponentInstallErrorPresented = true
            }
        }
    }
}

#Preview {
    Form {
        ContainerSettingsView(
            selectedContainerURL: Binding(
                get: { Wine.containerURLs.first },
                set: { _ in }
            ),
            withPicker: true
        )
    }
    .formStyle(.grouped)
}
