import CoreAudio
import SwiftUI

/// The right-click menu of the rack and the compact player: the controls that otherwise live
/// in the menu bar, grouped by what they act on.
struct InterfaceMenu: View {
    @Environment(AmpModel.self) private var amp
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let player = amp.player

        // Playback
        Button(player.isPlaying ? "Pause" : "Play") { amp.togglePlay() }
        Button("Previous") { player.previous() }.disabled(player.isRadio)
        Button("Next") { player.next() }.disabled(player.isRadio)
        Toggle("Mute", isOn: Binding(get: { player.isMuted }, set: { player.setMuted($0) }))

        Divider()

        // What to listen to
        Picker("Source", selection: Binding(get: { amp.input }, set: { amp.select($0) })) {
            ForEach(AmpModel.Input.allCases, id: \.self) { Text($0.longLabel.capitalized).tag($0) }
        }
        Button("Library…") { openWindow(id: "library") }
        Button("Open Files…") { amp.openFiles() }

        Divider()

        Menu("Output") {
            Picker("Output Device", selection: Binding(
                get: { player.chosenDevice?.id ?? 0 },
                set: { id in player.chooseDevice(player.outputDevices.first { $0.id == id }) })) {
                Text("System Default").tag(AudioDeviceID(0))
                ForEach(player.outputDevices) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
            if let missing = player.missingOutputName {
                Button("Stop Waiting for \(missing): Use the System Output") { player.chooseDevice(nil) }
            }
            Toggle("Lock Output", isOn: Binding(get: { player.lockOutput }, set: { player.lockOutput = $0 }))
            Divider()
            Toggle("Direct (no processing)", isOn: Binding(get: { player.isDirect }, set: { _ in amp.toggleDirect() }))
            Picker("Rate Change Delay", selection: Binding(get: { player.rateSettleDelay }, set: { player.rateSettleDelay = $0 })) {
                Text("Off").tag(0.0)
                Text("0.3 s").tag(0.3)
                Text("0.6 s").tag(0.6)
                Text("1 s").tag(1.0)
            }
            Picker("Volume Limit", selection: Binding(get: { player.volumeLimitDB }, set: { player.volumeLimitDB = $0 })) {
                Text("None").tag(Float(0))
                ForEach([-6, -10, -15, -20, -30] as [Float], id: \.self) { Text("\(Int($0)) dB").tag($0) }
            }
        }

        Menu("Sound") {
            Toggle("Equalizer Bypass", isOn: Binding(get: { player.eqBypassed }, set: { player.eqBypassed = $0 }))
                .disabled(player.isDirect)
            Button("Equalizer Editor…") { openWindow(id: "eqeditor") }
            Button("Flatten Equalizer") { player.eqGains = Array(repeating: 0, count: Equalizer.frequencies.count) }
            Picker("ReplayGain", selection: Binding(get: { player.replayGainMode }, set: { player.replayGainMode = $0 })) {
                ForEach(ReplayGainMode.allCases) { Text($0.name).tag($0) }
            }
            Toggle("Invert Polarity of This Track", isOn: Binding(get: { player.isCurrentTrackInverted }, set: { _ in player.toggleTrackPolarity() }))
                .disabled(player.currentURL == nil)
            Toggle("Invert Polarity of All Tracks", isOn: Binding(get: { player.polarityGlobal }, set: { player.polarityGlobal = $0 }))
            Picker("Meters", selection: Binding(get: { amp.meterMode }, set: { amp.meterMode = $0 })) {
                Text("VU").tag(MeterMode.vu)
                Text("Peak").tag(MeterMode.peak)
            }
        }

        Menu("Appearance") {
            Picker("Finish", selection: Binding(get: { amp.finish }, set: { amp.finish = $0 })) {
                ForEach(Finish.allCases) { Text($0.name).tag($0) }
            }
            Button("Backlight: \(["Full", "Warm", "Dim"][amp.dimmerIndex])") { amp.cycleDimmer() }
            Divider()
            Button("Full Rack") { amp.compactMode = false; amp.showRack(streamer: true, equalizer: true) }
            Button("Amplifier Only") { amp.compactMode = false; amp.showRack(streamer: false, equalizer: false) }
            Toggle("Compact Player", isOn: Binding(get: { amp.compactMode }, set: { amp.compactMode = $0 }))
            Toggle("Network Player", isOn: Binding(get: { amp.showStreamer }, set: { amp.showStreamer = $0 }))
            Toggle("Amplifier", isOn: Binding(get: { amp.showAmplifier }, set: { amp.showAmplifier = $0 }))
            Toggle("Equalizer", isOn: Binding(get: { amp.showEqualizer }, set: { amp.showEqualizer = $0 }))
            Divider()
            Toggle("Animate VU Meters", isOn: Binding(get: { amp.metersLive }, set: { amp.metersLive = $0 }))
            Toggle("Animate Spectrum Analyzer", isOn: Binding(get: { amp.spectrumLive }, set: { amp.spectrumLive = $0 }))
            Divider()
            let size = RoomView.designSize(streamer: amp.showStreamer, amplifier: amp.showAmplifier, equalizer: amp.showEqualizer)
            Button("Small") { RackWindow.shared.zoom(0.5, aspect: size) }
            Button("Medium") { RackWindow.shared.zoom(0.75, aspect: size) }
            Button("Large") { RackWindow.shared.zoom(1, aspect: size) }
            Button("Fit Screen") { RackWindow.shared.fitScreen(aspect: size) }
        }

        Menu("Analysis") {
            Button("Audio Path…") { openWindow(id: "audiopath") }
            Button("Verify Bit-Perfect Path…") { amp.verifyBitPerfect() }
                .disabled(player.currentURL == nil || player.isRadio)
            Button("Scan True Resolution…") { amp.scanResolution() }
                .disabled(player.currentURL == nil || player.isRadio)
        }

        Divider()

        Button("Help") { openWindow(id: "help") }
        Button("Power Off") { amp.togglePower() }
    }
}
