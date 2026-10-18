import CoreAudio
import SwiftUI

@main
struct IdiophileOneApp: App {
    @State private var amp = AmpModel()
    @State private var library = LibraryModel()

    private var rackSize: CGSize {
        RoomView.designSize(streamer: amp.showStreamer, amplifier: amp.showAmplifier, equalizer: amp.showEqualizer)
    }

    var body: some Scene {
        WindowGroup("Idiophile One") {
            RoomView()
                .environment(amp)
                .frame(minWidth: 420, minHeight: 160)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 880)
        .commands {
            WindowCommands(amp: amp)
            CommandGroup(after: .toolbar) {
                Button("Full Rack") { amp.showRack(streamer: true, equalizer: true) }
                    .keyboardShortcut("1")
                Button("Amplifier Only") { amp.showRack(streamer: false, equalizer: false) }
                    .keyboardShortcut("2")
                Toggle("Compact Player", isOn: Binding(get: { amp.compactMode }, set: { amp.compactMode = $0 }))
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Toggle("Network Player", isOn: Binding(get: { amp.showStreamer }, set: { amp.showStreamer = $0 }))
                    .keyboardShortcut("3")
                Toggle("Equalizer", isOn: Binding(get: { amp.showEqualizer }, set: { amp.showEqualizer = $0 }))
                    .keyboardShortcut("4")
                Toggle("Amplifier", isOn: Binding(get: { amp.showAmplifier }, set: { amp.showAmplifier = $0 }))
                    .keyboardShortcut("5")
                Divider()
                Toggle("Animate VU Meters", isOn: Binding(get: { amp.metersLive }, set: { amp.metersLive = $0 }))
                Toggle("Animate Spectrum Analyzer", isOn: Binding(get: { amp.spectrumLive }, set: { amp.spectrumLive = $0 }))
                Divider()
                Button("Small") { RackWindow.shared.zoom(0.5, aspect: rackSize) }
                    .keyboardShortcut("-")
                Button("Medium") { RackWindow.shared.zoom(0.75, aspect: rackSize) }
                    .keyboardShortcut("0")
                Button("Large") { RackWindow.shared.zoom(1, aspect: rackSize) }
                    .keyboardShortcut("=")
                Button("Fit Screen") { RackWindow.shared.fitScreen(aspect: rackSize) }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                Divider()
                Picker("Finish", selection: Binding(get: { amp.finish }, set: { amp.finish = $0 })) {
                    ForEach(Finish.allCases) { Text($0.name).tag($0) }
                }
                Divider()
            }
            CommandMenu("Output") {
                Picker("Output Device", selection: Binding(
                    get: { amp.player.chosenDevice?.id ?? 0 },
                    set: { id in amp.player.chooseDevice(amp.player.outputDevices.first { $0.id == id }) })) {
                    Text("System Default").tag(AudioDeviceID(0))
                    ForEach(amp.player.outputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .pickerStyle(.inline)
                if let missing = amp.player.missingOutputName {
                    Button("Stop Waiting for \(missing): Use the System Output") { amp.player.chooseDevice(nil) }
                }
                Toggle("Lock Output", isOn: Binding(get: { amp.player.lockOutput }, set: { amp.player.lockOutput = $0 }))
                    .help("Never fall back to another output (such as the speakers) if the DAC disappears")
                Divider()
                Picker("Rate Change Delay", selection: Binding(get: { amp.player.rateSettleDelay },
                                                               set: { amp.player.rateSettleDelay = $0 })) {
                    Text("Off").tag(0.0)
                    Text("0.3 s").tag(0.3)
                    Text("0.6 s").tag(0.6)
                    Text("1 s").tag(1.0)
                }
                Picker("Volume Limit", selection: Binding(get: { amp.player.volumeLimitDB },
                                                          set: { amp.player.volumeLimitDB = $0 })) {
                    Text("None").tag(Float(0))
                    ForEach([-6, -10, -15, -20, -30] as [Float], id: \.self) { Text("\(Int($0)) dB").tag($0) }
                }
                Divider()
                Toggle("Invert Polarity of This Track", isOn: Binding(get: { amp.player.isCurrentTrackInverted },
                                                                      set: { _ in amp.player.toggleTrackPolarity() }))
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .disabled(amp.player.currentURL == nil)
                Toggle("Invert Polarity of All Tracks", isOn: Binding(get: { amp.player.polarityGlobal },
                                                                      set: { amp.player.polarityGlobal = $0 }))
                Button("Measure Library Loudness") { library.analyzeLoudness() }
                    .disabled(library.isAnalyzing || library.isScanning)
                Picker("ReplayGain", selection: Binding(get: { amp.player.replayGainMode },
                                                        set: { amp.player.replayGainMode = $0 })) {
                    ForEach(ReplayGainMode.allCases) { Text($0.name).tag($0) }
                }
                Divider()
                Button("Equalizer Editor…") { amp.eqEditorRequested = true }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                Button("Audio Path…") { amp.audioPathRequested = true }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                Button("Scan True Resolution…") { amp.scanResolution() }
                    .disabled(amp.player.currentURL == nil || amp.player.isRadio)
                Button("Verify Bit-Perfect Path…") { amp.verifyBitPerfect() }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                    .disabled(amp.player.currentURL == nil)
                Toggle("Direct (Bit-Perfect Path)", isOn: Binding(get: { amp.player.isDirect }, set: { _ in amp.toggleDirect() }))
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandMenu("Playback") {
                Button("Source: Library") { amp.select(.library) }.keyboardShortcut("1", modifiers: .control)
                Button("Source: Internet Radio") { amp.select(.radio) }.keyboardShortcut("2", modifiers: .control)
                Button("Source: Network") { amp.select(.network) }.keyboardShortcut("3", modifiers: .control)
                Divider()
                Button("Play / Pause") { amp.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Next Track") { amp.player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous Track") { amp.player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button(amp.player.isMuted ? "Unmute" : "Mute") { amp.player.setMuted(!amp.player.isMuted) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])   // ⌥⌘M is the compact player
                Divider()
                Button("Power Off") { amp.togglePower() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Dimmer") { amp.cycleDimmer() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        Window("Compact Player", id: "compact") {
            CompactView()
                .environment(amp)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("Library", id: "library") {
            LibraryView()
                .environment(amp)
                .environment(library)
        }
        .defaultSize(width: 1120, height: 740)

        Window("Equalizer", id: "eqeditor") {
            EQEditorView()
                .environment(amp)
        }
        .windowResizability(.contentSize)

        Window("Audio Path", id: "audiopath") {
            AudioPathView()
                .environment(amp)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        Window("Idiophile One Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 900, height: 640)
        .commandsRemoved()
    }
}

/// File › Open / Library (⌘L) and Help › Idiophile One Help (⌘?).
private struct WindowCommands: Commands {
    let amp: AmpModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { amp.openFiles() }
                .keyboardShortcut("o")
            Button("Library") { openWindow(id: "library") }
                .keyboardShortcut("l")
        }
        CommandGroup(replacing: .help) {
            Button("Idiophile One Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}
