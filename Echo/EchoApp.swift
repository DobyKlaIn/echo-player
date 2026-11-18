import SwiftUI

@main
struct EchoApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var library: Library
    @StateObject private var player: PlayerController
    @StateObject private var radio = RadioStore()
    @StateObject private var online = OnlineStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let s = AppSettings()
        let l = Library()
        _settings = StateObject(wrappedValue: s)
        _library = StateObject(wrappedValue: l)
        _player = StateObject(wrappedValue: PlayerController(library: l, settings: s, online: OnlineStore.shared))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(radio)
                .environmentObject(online)
                .preferredColorScheme(.dark)
                .tint(settings.accent.color)
                .onOpenURL { url in
                    // «Поделиться → Эхо» из Telegram, «Файлов», браузера
                    Task { await library.importFiles([url]) }
                }
                .task {
                    await library.rescan()
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        Task { await library.rescan() }
                    case .inactive, .background:
                        player.appWillResignActive()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
