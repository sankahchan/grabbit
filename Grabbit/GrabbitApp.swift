import SwiftUI
import Sparkle
import Observation

// TODO(code-signing): ad-hoc / Developer ID signing is intentionally disabled
// for local scaffolding (see project.yml). Before public distribution, enable
// signing and run Sparkle's `generate_keys` tool, then paste the public key
// into project.yml's SUPublicEDKey.

@main
struct GrabbitApp: App {
    @State private var downloadEngine = DownloadEngine()
    @State private var torrentEngine = TorrentEngine()
    @State private var settings = SettingsStore()
    @State private var updater: SPUStandardUpdaterController?
    @State private var nativeMessagingHost: NativeMessagingHost?

    init() {
        // Sparkle's updater can't start in an unsigned dev build (it needs a
        // signed app + real SUPublicEDKey), and the failure pops an error
        // dialog. Only create it when it's actually usable.
        if Self.isUpdaterConfigured {
            _updater = State(initialValue: SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            ))
        }
    }

    /// True for signed Release builds with a real Sparkle Ed25519 key.
    /// Dev builds (and Release builds before `generate_keys` is run) skip
    /// the updater entirely instead of showing "Unable to Check For Updates".
    static var isUpdaterConfigured: Bool {
        #if DEBUG
        return false
        #else
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty,
              !key.hasPrefix("TODO") else { return false }
        return true
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // MainView is owned by another workstream; it reads the engines and
            // settings from the environment.
            MainView()
                .environment(downloadEngine)
                .environment(torrentEngine)
                .environment(settings)
                .onAppear {
                    // Browser-extension mode: stdin/stdout are the
                    // native-messaging channel, not a normal launch.
                    if CommandLine.arguments.contains("--native-messaging") {
                        let host = NativeMessagingHost()
                        host.onMessage = { message in
                            // NativeMessagingHost invokes this on its reader
                            // thread; hop to the main actor for the engine.
                            Task { @MainActor in
                                await downloadEngine.add(url: message.url)
                            }
                        }
                        host.start()
                        nativeMessagingHost = host
                    }
                }
        }
    }
}
