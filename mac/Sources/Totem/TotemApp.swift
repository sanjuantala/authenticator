import AppKit
import SwiftUI

@main
struct TotemApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(nsImage: MenuBarIcon.image(locked: model.locked))
        }
        .menuBarExtraStyle(.window)

        Window("Totem Settings", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        Task { @MainActor in
            AppModel.shared.bootstrap()
            // keep the browser bridge manifest pointing at this copy of the app
            if !BrowserBridge.installedIn.isEmpty { try? BrowserBridge.install() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}
