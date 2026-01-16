import SwiftUI
import AppKit
import Combine

@main
struct AlfredMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var viewModel: MainMenuViewModel?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 Alfred GUI app starting...")

        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Alfred")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 340, height: 380)
        popover?.behavior = .transient

        // Initialize ViewModel on MainActor and observe size changes
        Task { @MainActor in
            let vm = MainMenuViewModel()
            self.viewModel = vm
            popover?.contentViewController = NSHostingController(rootView: MainMenuView())

            vm.$shouldExpandPopover
                .sink { [weak self] shouldExpand in
                    Task { @MainActor in
                        self?.updatePopoverSize(expanded: shouldExpand)
                    }
                }
                .store(in: &cancellables)
        }
    }

    private func updatePopoverSize(expanded: Bool) {
        let newSize = expanded
            ? NSSize(width: 680, height: 760)
            : NSSize(width: 340, height: 380)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            popover?.contentSize = newSize
        })
    }

    @objc func togglePopover() {
        if let button = statusItem?.button {
            if let popover = popover {
                if popover.isShown {
                    popover.performClose(nil)
                } else {
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                }
            }
        }
    }
}
