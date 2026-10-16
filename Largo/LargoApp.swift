import SwiftUI

@main
struct LargoApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @StateObject private var player = AudioPlayer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        #if os(macOS)
        Window("Largo", id: "main") {
            ContentView(player: player)
                .tint(.brand)
                .onAppear(perform: openInitialSong)
        }
        .commands { commands }
        #else
        WindowGroup {
            ContentView(player: player)
                .tint(.brand)
                .onAppear(perform: openInitialSong)
        }
        .commands { commands } // iPad with a hardware keyboard
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player.saveSongSettings() } // the app may be closed in the background
        }
        #endif
    }

    /// Reopens the last song. Debug builds: `-open /path/to/song.mp3` opens that file instead.
    private func openInitialSong() {
        SongLibrary.cleanUpCaches()
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-open"), args.indices.contains(i + 1) {
            player.load(url: URL(fileURLWithPath: args[i + 1]))
            return
        }
        #endif
        player.restoreLastSong()
        // Very first launch: start with the demo song instead of an empty screen.
        if player.fileURL == nil && SongLibrary.lastSongID == nil {
            player.openDemoSong()
        }
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { player.isImporterPresented = true }
                .keyboardShortcut("o")
        }
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Return to Start") { player.returnToStart() }
                .keyboardShortcut(.return, modifiers: [])
            Button("Back 5 Seconds") { player.skip(by: -5) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Forward 5 Seconds") { player.skip(by: 5) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Divider()
            Button("Slower") { player.rate = max(0.25, player.rate - 0.05) }
                .keyboardShortcut("-", modifiers: [])
            Button("Faster") { player.rate = min(2.0, player.rate + 0.05) }
                .keyboardShortcut("=", modifiers: [])
            Button("Transpose Up") { player.semitones = min(12, player.semitones + 1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Transpose Down") { player.semitones = max(-12, player.semitones - 1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Reset Speed & Pitch") { player.resetPitchAndSpeed() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Zoom In") { player.zoom(by: 1.5) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { player.zoom(by: 1 / 1.5) }
                .keyboardShortcut("-", modifiers: .command)
            Divider()
            Button("Set Loop Start") { player.setLoopStartHere() }
                .keyboardShortcut("[", modifiers: [])
            Button("Set Loop End") { player.setLoopEndHere() }
                .keyboardShortcut("]", modifiers: [])
            Button(player.loopEnabled ? "Disable Loop" : "Enable Loop") { player.loopEnabled.toggle() }
                .keyboardShortcut("l", modifiers: [])
                .disabled(!player.hasValidLoop)
            Button("Clear Loop") { player.clearLoop() }
                .keyboardShortcut("l", modifiers: .shift)
        }
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
