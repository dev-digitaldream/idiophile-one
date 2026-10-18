import SwiftUI
import UniformTypeIdentifiers

/// Parametric equalizer editor: bands, response curve, presets, import and export. The setting
/// belongs to the current output device and is remembered for it.
struct EQEditorView: View {
    @Environment(AmpModel.self) private var amp
    @State private var presets = EQPresetStore.load()
    @State private var naming = false
    @State private var presetName = ""
    @State private var message: String?
    @State private var dropTargeted = false

    private var player: PlayerEngine { amp.player }

    /// The profile being edited; writing to it switches the device to parametric mode.
    private var profile: Binding<EQProfile> {
        Binding(
            get: { player.eqSetup.parametric ?? EQProfile(name: "Custom") },
            set: { player.useParametricProfile($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            compareBar
            EQPlot(profile: profile.wrappedValue)
                .frame(height: 210)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
                .opacity(player.eqSetup.useParametric ? 1 : 0.45)
            preamp
            bandList
            footer
        }
        .padding(22)
        .frame(width: 780, height: 700)
        .preferredColorScheme(.dark)
        .tint(Color(red: 1, green: 0.66, blue: 0.3))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.black.opacity(0.4))
                    .overlay(Text("Drop AutoEq / Equalizer APO .txt files to import").font(.title3.weight(.semibold)))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .onDisappear { player.endAudition() }
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $presetName)
            Button("Save") { savePreset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved presets are available for every output device.")
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Parametric Equalizer").font(.title2.weight(.semibold))
                Text("Saved for \(player.outputDevice?.name ?? "this output"): each device keeps its own setting")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Use parametric", isOn: Binding(
                get: { player.eqSetup.useParametric },
                set: { on in
                    if on, player.eqSetup.parametric == nil { player.useParametricProfile(EQProfile(name: "Custom")) }
                    player.eqSetup.useParametric = on
                }))
                .toggleStyle(.switch)
            presetMenu
        }
    }

    private var presetMenu: some View {
        Menu {
            Menu("Headphones (built-in)") {
                ForEach(EQPresetStore.builtIn, id: \.name) { preset in
                    Button(preset.name) { player.useParametricProfile(preset) }
                }
            }
            if presets.isEmpty {
                Text("No saved presets").foregroundStyle(.secondary)
            } else {
                ForEach(presets, id: \.name) { preset in
                    Button(preset.name) { player.useParametricProfile(preset) }
                }
            }
            Divider()
            Button("Save Current as Preset…") { presetName = profile.wrappedValue.name; naming = true }
                .disabled(profile.wrappedValue.bands.isEmpty)
            Menu("Delete Preset") {
                ForEach(presets, id: \.name) { preset in
                    Button(preset.name, role: .destructive) { EQPresetStore.delete(named: preset.name); presets = EQPresetStore.load() }
                }
            }
            .disabled(presets.isEmpty)
            Divider()
            Button("Import AutoEq / Equalizer APO Files…") { importFile() }
            Button("Paste Filters from Clipboard") { pasteProfile() }
            Button("Export Current…") { exportFile() }.disabled(profile.wrappedValue.bands.isEmpty)
        } label: {
            Label("Presets", systemImage: "slider.horizontal.below.rectangle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// A/B comparison: two profiles and "off", switched while the music plays.
    private var compareBar: some View {
        let slot = player.auditionSlot
        return HStack(spacing: 10) {
            Text("Compare").font(.callout.weight(.medium)).frame(width: 58, alignment: .leading)
            slotButton("A", slot: .a, loaded: player.auditionA)
            slotButton("B", slot: .b, loaded: player.auditionB)
            Button { player.listen(to: .off) } label: {
                Text("Off").frame(minWidth: 44)
            }
            .buttonStyle(.borderedProminent).tint(slot == .off ? .accentColor : .gray.opacity(0.35))
            .keyboardShortcut("3", modifiers: [])
            Toggle("Same loudness", isOn: Binding(get: { player.auditionLevelMatch }, set: { player.auditionLevelMatch = $0 }))
                .toggleStyle(.checkbox)
            Spacer()
            Text(compareStatus).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var compareStatus: String {
        guard player.auditionSlot != nil else { return "Pick a profile for A and B, then switch while listening" }
        let dB = player.signalPath.levelMatchDB
        return dB == 0 ? "keys 1 · 2 · 3" : String(format: "level match %+.1f dB · keys 1 · 2 · 3", dB)
    }

    private func slotButton(_ title: String, slot: PlayerEngine.AuditionSlot, loaded: EQProfile?) -> some View {
        HStack(spacing: 0) {
            Button { player.listen(to: slot) } label: {
                Text(title).frame(minWidth: 26)
            }
            .buttonStyle(.borderedProminent).tint(player.auditionSlot == slot ? .accentColor : .gray.opacity(0.35))
            .disabled(loaded == nil)
            .keyboardShortcut(slot == .a ? "1" : "2", modifiers: [])
            Menu {
                Button("Current profile") { player.setAudition(slot, profile: self.profile.wrappedValue) }
                Divider()
                ForEach(EQPresetStore.builtIn + presets, id: \.name) { preset in
                    Button(preset.name) { player.setAudition(slot, profile: preset) }
                }
            } label: {
                Text(loaded?.name ?? "Choose…").lineLimit(1).frame(maxWidth: 190, alignment: .leading)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private var preamp: some View {
        let p = profile.wrappedValue
        let headroom = p.headroomDB()
        return HStack(spacing: 14) {
            Text("Preamp").font(.callout.weight(.medium)).frame(width: 58, alignment: .leading)
            Slider(value: profile.preampDB, in: -24...6, step: 0.1)
            Text(String(format: "%+.1f dB", p.preampDB)).font(.callout.monospacedDigit()).frame(width: 64, alignment: .trailing)
            Text(headroom < -0.05 ? String(format: "auto −%.1f dB headroom", -headroom) : "no clipping risk")
                .font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
        }
    }

    private var bandList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("").frame(width: 30)
                Text("Type").frame(width: 116, alignment: .leading)
                Text("Frequency").frame(width: 100, alignment: .leading)
                Text("Gain").frame(width: 84, alignment: .leading)
                Text("Q").frame(width: 70, alignment: .leading)
                Spacer()
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 6)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(profile.bands) { $band in
                        BandRow(band: $band) {
                            profile.wrappedValue.bands.removeAll { $0.id == band.id }
                        }
                        Divider().opacity(0.5)
                    }
                    if profile.wrappedValue.bands.isEmpty {
                        Text("No filters yet. Add one, or import a profile for your headphones.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                }
            }
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button {
                guard profile.wrappedValue.bands.count < EQProfile.maxBands else { return }
                profile.wrappedValue.bands.append(EQBand(kind: .peak, frequency: 1000, gainDB: 0, q: 1))
            } label: { Label("Add Filter", systemImage: "plus") }
                .disabled(profile.wrappedValue.bands.count >= EQProfile.maxBands)
            Button("Flatten") {
                for i in profile.wrappedValue.bands.indices { profile.wrappedValue.bands[i].gainDB = 0 }
                profile.wrappedValue.preampDB = 0
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            Spacer()
            Text("\(profile.wrappedValue.bands.count) of \(EQProfile.maxBands) filters").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Files and presets

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var saved = profile.wrappedValue
        saved.name = name
        EQPresetStore.save(saved)
        presets = EQPresetStore.load()
        player.useParametricProfile(saved)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = true
        panel.message = "Choose AutoEq or Equalizer APO parametric profiles (.txt)"
        guard panel.runModal() == .OK else { return }
        importProfiles(from: panel.urls)
    }

    /// Adds the files to the saved presets and applies the last one.
    private func importProfiles(from urls: [URL]) {
        let imported = EQPresetStore.importFiles(urls)
        presets = EQPresetStore.load()
        guard let last = imported.last else {
            message = "No recognisable filters in that file."
            return
        }
        player.useParametricProfile(last)
        message = imported.count == 1 ? "Imported “\(last.name)”." : "Imported \(imported.count) presets; applied “\(last.name)”."
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let found = NSMutableArray()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { found.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { importProfiles(from: found.compactMap { $0 as? URL }) }
        return true
    }

    private func pasteProfile() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let pasted = EQProfile.parse(text, name: "Pasted profile") else {
            message = "The clipboard has no filter list (Preamp: … / Filter 1: ON PK Fc …)."
            return
        }
        player.useParametricProfile(pasted)
        message = "Pasted \(pasted.bands.count) filters. Use Save Current as Preset to keep them."
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = profile.wrappedValue.name + ".txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? profile.wrappedValue.text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct BandRow: View {
    @Binding var band: EQBand
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $band.enabled).labelsHidden().toggleStyle(.checkbox).frame(width: 30)
            Picker("", selection: $band.kind) {
                ForEach(EQBand.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 116)
            HStack(spacing: 3) {
                TextField("", value: $band.frequency, format: .number.precision(.fractionLength(0...1)))
                    .multilineTextAlignment(.trailing).frame(width: 64)
                Text("Hz").foregroundStyle(.secondary).font(.caption)
            }
            .frame(width: 100, alignment: .leading)
            HStack(spacing: 3) {
                TextField("", value: $band.gainDB, format: .number.precision(.fractionLength(0...1)))
                    .multilineTextAlignment(.trailing).frame(width: 52).disabled(!band.kind.hasGain)
                Text("dB").foregroundStyle(.secondary).font(.caption)
            }
            .frame(width: 84, alignment: .leading)
            TextField("", value: $band.q, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing).frame(width: 56)
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .opacity(band.enabled ? 1 : 0.45)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}
