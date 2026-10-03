import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The live sources: the microphone with its input device and, on macOS, system audio (all audio or one app).
struct LiveSourcesView: View {
    @Bindable var viewModel: TranscriptionViewModel
    #if os(macOS)
    @State private var catalog = AudioSourceCatalog()
    #endif

    var body: some View {
        #if os(macOS)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Toggle("Microphone", isOn: $viewModel.micEnabled)
                microphonePicker
                    .disabled(!viewModel.micEnabled)
            }
            GridRow {
                Toggle("System audio", isOn: $viewModel.systemAudioEnabled)
                systemAudioPicker
                    .disabled(!viewModel.systemAudioEnabled)
            }
        }
        .onAppear { catalog.startObserving() }
        #else
        Label("Microphone", systemImage: "mic")
            .foregroundStyle(.secondary)
        #endif
    }

    #if os(macOS)
    private var microphonePicker: some View {
        Picker("Microphone", selection: $viewModel.selectedMicUID) {
            Text(catalog.defaultInputName.map { "System Default (\($0))" } ?? "System Default")
                .tag(String?.none)
            Divider()
            ForEach(catalog.inputDevices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
            if let uid = viewModel.selectedMicUID, !catalog.inputDevices.contains(where: { $0.uid == uid }) {
                Text("Disconnected device").tag(Optional(uid))
            }
        }
        .labelsHidden()
    }

    private var systemAudioPicker: some View {
        Picker("System audio", selection: $viewModel.systemAudioTarget) {
            Text("All system audio").tag(SystemAudioTarget.allAudio)
            Divider()
            ForEach(catalog.apps) { app in
                Label { Text(app.name) } icon: { appIcon(bundleID: app.id) }
                    .tag(SystemAudioTarget.app(bundleID: app.id, name: app.name))
            }
            if case .app(let bundleID, let name) = viewModel.systemAudioTarget,
               !catalog.apps.contains(where: { $0.id == bundleID }) {
                Text("\(name) (not running)").tag(viewModel.systemAudioTarget)
            }
        }
        .labelsHidden()
    }

    private func appIcon(bundleID: String) -> Image {
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            ?? NSImage()
        icon.size = NSSize(width: 16, height: 16)
        return Image(nsImage: icon)
    }
    #endif
}
