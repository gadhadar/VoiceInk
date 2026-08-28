#if LOCAL_BUILD

import AppKit
import SwiftUI

struct LocalUpdateProgressView: View {
    @ObservedObject var service: LocalUpdateService
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let errorMessage = service.lastError {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if service.phase == .installing || service.phase == .relaunching {
                Label(
                    "VoiceInk will quit and reopen on its own. Accessibility and Microphone permissions are reset by the rebuild and need re-granting.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Build log", isExpanded: $showLog) {
                ScrollView {
                    Text(service.logTail.isEmpty ? "Waiting for output…" : service.logTail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 200)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 320)
    }

    private var header: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                Text(service.phase.describes)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch service.phase {
        case .done, .uptodate:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 28))
                .foregroundStyle(.red)
        default:
            ProgressView().controlSize(.small)
        }
    }

    private var subtitle: String {
        switch service.phase {
        case .done:
            return "Rebuilt from your fork and installed to /Applications."
        case .uptodate:
            return "Your fork already matches upstream. Use Rebuild anyway to force a build."
        case .failed:
            return "See the build log below for the failure."
        default:
            return "Building from your own repository instead of downloading an upstream release."
        }
    }

    private var footer: some View {
        HStack {
            if service.isRunning {
                Text("Safe to close this window — the build keeps running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button("Reveal Log") {
                NSWorkspace.shared.selectFile(
                    nil,
                    inFileViewerRootedAtPath: NSHomeDirectory() + "/Library/Logs/VoiceInk"
                )
            }

            if !service.isRunning {
                Button("Rebuild Anyway") { start(force: true) }
                Button("Check Again") { start(force: false) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func start(force: Bool) {
        service.start(force: force)
    }
}

/// Standalone window so the menu bar, Settings and Dashboard entry points all
/// work even when the main window is closed.
@MainActor
final class LocalUpdateWindowController: NSObject, NSWindowDelegate {
    static let shared = LocalUpdateWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: LocalUpdateProgressView(service: .shared)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Update VoiceInk"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 380))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

#endif
