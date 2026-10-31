import AppIntents
import OpenScreensUI

struct OpenScreensShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectIntent(),
            phrases: [
                "Connect to a VNC server in \(.applicationName)",
                "在 \(.applicationName) 中连接 VNC 服务器"
            ],
            shortTitle: "Connect to VNC Server",
            systemImageName: "display"
        )
    }
}
