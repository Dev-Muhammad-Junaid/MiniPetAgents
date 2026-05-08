import AppKit
import SwiftUI

/// Lets the user fan a single prompt out to every spawned pet at once. Each
/// pet keeps its own session/popover and answers in its own terminal.
final class BroadcastComposerController {
    static let shared = BroadcastComposerController()

    private var window: NSWindow?
    weak var controller: PetAgentsController?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }

        let view = BroadcastComposerView(send: { [weak self] message, openPopovers in
            guard let controller = self?.controller else { return }
            if openPopovers {
                for char in controller.characters where !char.isIdleForPopover {
                    char.openPopover()
                }
            }
            controller.broadcast(message: message)
        }, dismiss: { [weak self] in
            self?.window?.orderOut(nil)
        })

        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Ask all pets…"
        win.setContentSize(NSSize(width: 480, height: 280))
        win.styleMask = [.titled, .closable, .resizable]
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct BroadcastComposerView: View {
    let send: (String, Bool) -> Void
    let dismiss: () -> Void

    @State private var message: String = ""
    @State private var openPopovers: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Broadcast a prompt")
                .font(.headline)
            Text("Every spawned pet receives this message in its own session. Pair with per-pet provider overrides to compare Claude vs Codex vs Copilot side-by-side.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $message)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            Toggle("Open each pet's popover", isOn: $openPopovers)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Broadcast") {
                    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    send(trimmed, openPopovers)
                    message = ""
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 260)
    }
}
