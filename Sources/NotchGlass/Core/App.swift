import SwiftUI

@main
struct NotchGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI lives in a borderless panel managed by AppDelegate.
        // We keep an empty Settings scene so SwiftUI has a valid App body.
        Settings {
            EmptyView()
        }
    }
}
