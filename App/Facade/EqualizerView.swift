import SwiftUI

/// Ten-band graphic equalizer unit with an LED spectrum analyser, 80s style.
struct EqualizerView: View {
    @Environment(AmpModel.self) private var amp
    @Environment(\.openWindow) private var openWindow
    @Environment(\.palette) private var palette

    static let height: CGFloat = 230
    private static let sliderTop: CGFloat = 38
    private static let sliderHeight: CGFloat = 150

    var body: some View {
        let player = amp.player

        ZStack(alignment: .topLeading) {
            UnitPanel(height: Self.height, showFeet: true)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.eqSetup.useParametric ? "PARAMETRIC" : "GRAPHIC")
                        .font(.custom("Futura-Medium", size: 13)).tracking(4).engraved()
                    Text("EQUALIZER").font(.custom("Futura-Medium", size: 13)).tracking(4).engraved()
                }
                HStack(spacing: 8) {
                    Button("BYPASS") {
                        if player.isDirect {
                            // DIRECT keeps the EQ out of the path; asking for it brings it back.
                            amp.toggleDirect()
                            player.eqBypassed = false
                        } else {
                            player.eqBypassed.toggle()
                        }
                    }
                    .buttonStyle(PanelKeyStyle(lit: amp.isOn && (player.eqBypassed || player.isDirect)))
                    Button("FLAT") { player.eqGains = Array(repeating: 0, count: Equalizer.frequencies.count) }
                        .buttonStyle(PanelKeyStyle())
                }
                HStack(spacing: 8) {
                    Button("EDIT") { openWindow(id: "eqeditor") }
                        .buttonStyle(PanelKeyStyle())
                    Button("PARAM") {
                        // Switch between the faders and the saved parametric profile; with none yet, open the editor.
                        if player.eqSetup.parametric == nil { openWindow(id: "eqeditor") } else { player.eqSetup.useParametric.toggle() }
                    }
                    .buttonStyle(PanelKeyStyle(lit: amp.isOn && player.eqSetup.useParametric))
                }
                if player.isDirect {
                    HStack(spacing: 7) {
                        IndicatorLED(lit: amp.isOn)
                        Text("EQ OUT · DIRECT").font(PanelFont.label(10)).tracking(1.5).engraved()
                    }
                } else {
                    Text(player.eqBypassed ? "EQ OUT · BYPASS"
                         : (player.eqSetup.useParametric ? player.eqSetup.profile.name.uppercased() + String(format: "  %+.1f dB", player.eqHeadroomDB)
                            : String(format: "PRE-GAIN %+.1f dB", player.eqHeadroomDB)))
                        .font(PanelFont.label(10)).tracking(1.5).engraved().opacity(0.75).lineLimit(1)
                }
            }
            .frame(width: 160, alignment: .leading)
            .position(x: 125, y: Self.height / 2)

            Group {
                if player.eqSetup.useParametric {
                    // The curve the filters draw, instead of the faders; a click opens the editor.
                    EQPlot(profile: player.eqSetup.profile, detailed: false, accent: palette.accent,
                           grid: palette.lettering.opacity(0.18), label: palette.lettering)
                        .frame(width: 520, height: 170)
                        .opacity(player.eqBypassed || player.isDirect ? 0.4 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture { openWindow(id: "eqeditor") }
                        .accessibilityLabel("Equalizer response")
                } else {
                    sliders(player)
                }
            }
            .position(x: 470, y: Self.height / 2 + 4)

            ZStack {
                GlassWindow()
                SpectrumDisplay(live: amp.isOn && amp.isVisible
                                    && (amp.spectrumLive ? (player.isPlaying || player.needlesSettling) : !amp.spectrumFrozen),
                                lit: amp.isOn, brightness: amp.dimmer, tap: player.levels,
                                playing: amp.isOn && player.isPlaying && amp.spectrumLive)
                    .padding(10)
                GlassSheen()
            }
            .frame(width: 380, height: 186)
            .position(x: 965, y: Self.height / 2)
        }
        .frame(width: 1200, height: Self.height + FacadeView.feetHeight, alignment: .topLeading)
    }

    private func sliders(_ player: PlayerEngine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // dB scale engraved beside the faders.
            VStack(alignment: .trailing) {
                Text("+12"); Spacer(); Text("0"); Spacer(); Text("−12")
            }
            .font(PanelFont.label(10)).engraved()
            .frame(width: 30, height: Self.sliderHeight)
            .padding(.trailing, 8)

            ForEach(Equalizer.frequencies.indices, id: \.self) { i in
                VStack(spacing: 8) {
                    EQFader(value: Binding(get: { player.eqGains[i] }, set: { gain in
                        if player.isDirect { amp.toggleDirect() }
                        player.eqBypassed = false
                        player.eqGains[i] = gain
                    }),
                            height: Self.sliderHeight, label: "\(Equalizer.labels[i]) Hz")
                    Text(Equalizer.labels[i]).font(PanelFont.label(10)).engraved()
                }
                .frame(width: 50)
            }
        }
        .opacity(player.eqBypassed || player.isDirect ? 0.45 : 1)
    }
}

/// Vertical fader: drag the cap, double-click to centre, scroll to fine-tune.
private struct EQFader: View {
    @Binding var value: Float
    var height: CGFloat
    var label: String

    @State private var hovering = false

    private var range: ClosedRange<Float> { Equalizer.range }

    var body: some View {
        let travel = height - 14
        let y = CGFloat((range.upperBound - value) / (range.upperBound - range.lowerBound)) * travel

        ZStack(alignment: .top) {
            // Scale ticks.
            VStack(spacing: 0) {
                ForEach(0..<9) { i in
                    Rectangle().fill(.black.opacity(i == 4 ? 0.45 : 0.22)).frame(width: i == 4 ? 26 : 16, height: 1)
                    if i < 8 { Spacer() }
                }
            }
            .padding(.vertical, 7)
            .frame(height: height)

            // Slot.
            Capsule()
                .fill(Color(red: 0.1, green: 0.09, blue: 0.08))
                .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 0.5).offset(y: 1))
                .frame(width: 5, height: height)

            // Cap.
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.1), Color(white: 0.18)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Rectangle().fill(.white.opacity(0.85)).frame(height: 1.5))
                .frame(width: 30, height: 14)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 2)
                .offset(y: y)
        }
        .frame(width: 40, height: height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let t = Float(min(max((g.location.y - 7) / travel, 0), 1))
            set(range.upperBound - t * (range.upperBound - range.lowerBound))
        })
        .onTapGesture(count: 2) { value = 0 }
        .onHover { hovering = $0 }
        .background(ScrollWheelMonitor(active: hovering) { delta in set(value + Float(delta) / 40) })
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%+.1f dB", value))
        .accessibilityAdjustableAction { set(value + ($0 == .increment ? 0.5 : -0.5)) }
    }

    private func set(_ raw: Float) {
        value = (min(max(raw, range.lowerBound), range.upperBound) * 2).rounded() / 2
    }
}

/// LED bar-graph spectrum with fast attack, slow release and peak-hold dots.
private struct SpectrumDisplay: View {
    var live: Bool
    var lit: Bool
    var brightness: Double
    var tap: LevelTap
    var playing: Bool

    @State private var state = SpectrumState()
    @Environment(\.palette) private var palette

    static let segments = 14
    static let floorDB: Float = -70
    static let stepDB: Float = 5

    static let labelHeight: CGFloat = 14
    static let gap: CGFloat = 6

    var body: some View {
        let state = state
        let palette = palette
        let glow = 0.45 + 0.55 * brightness
        ZStack {
            // Unlit segments and labels: drawn once, not per frame.
            Canvas { ctx, size in drawStatic(ctx, size: size, palette: palette, glow: glow) }
            // Lit segments: a handful of merged paths per frame.
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !live)) { timeline in
                Canvas { ctx, size in
                    state.advance(to: timeline.date, bands: playing ? tap.read(from: LevelTap.now() - 0.05, to: LevelTap.now()).spectrum : nil)
                    if lit { drawLit(ctx, size: size, state: state, palette: palette, glow: glow) }
                }
            }
        }
    }

    private static func segmentRect(column c: Int, segment s: Int, size: CGSize) -> CGRect {
        let columns = CGFloat(Equalizer.frequencies.count)
        let colWidth = (size.width - gap * (columns - 1)) / columns
        let segHeight = (size.height - labelHeight) / CGFloat(segments)
        return CGRect(x: CGFloat(c) * (colWidth + gap), y: size.height - labelHeight - CGFloat(s + 1) * segHeight + 1.5,
                      width: colWidth, height: segHeight - 3)
    }

    private func drawStatic(_ ctx: GraphicsContext, size: CGSize, palette: Palette, glow: Double) {
        for c in Equalizer.frequencies.indices {
            for s in 0..<Self.segments {
                ctx.fill(Path(roundedRect: Self.segmentRect(column: c, segment: s, size: size), cornerRadius: 1),
                         with: .color(Self.color(segment: s, palette: palette).opacity(0.07)))
            }
            let rect = Self.segmentRect(column: c, segment: 0, size: size)
            ctx.draw(Text(Equalizer.labels[c]).font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.accent.opacity(lit ? 0.6 * glow : 0.15)),
                     at: CGPoint(x: rect.midX, y: size.height - Self.labelHeight / 2 + 2))
        }
    }

    private func drawLit(_ ctx: GraphicsContext, size: CGSize, state: SpectrumState, palette: Palette, glow: Double) {
        // One path per colour zone.
        var zones = [Path](repeating: Path(), count: 3)
        for c in Equalizer.frequencies.indices {
            let level = state.display[c]
            let peak = state.peaks[c]
            for s in 0..<Self.segments {
                let threshold = Self.floorDB + Float(s + 1) * Self.stepDB
                let isPeak = abs(peak - threshold) < Self.stepDB / 2 && peak > Self.floorDB + Self.stepDB
                guard level >= threshold || isPeak else { continue }
                zones[Self.zone(segment: s)].addRoundedRect(in: Self.segmentRect(column: c, segment: s, size: size),
                                                            cornerSize: CGSize(width: 1, height: 1))
            }
        }
        for (z, path) in zones.enumerated() where !path.isEmpty {
            ctx.fill(path, with: .color(Self.zoneColor(z, palette: palette).opacity(glow)))
        }
    }

    private static func zone(segment s: Int) -> Int {
        s >= segments - 2 ? 2 : (s >= segments - 4 ? 1 : 0)
    }

    private static func zoneColor(_ z: Int, palette: Palette) -> Color {
        [palette.spectrumLow, palette.spectrumHigh, Color(red: 1, green: 0.25, blue: 0.15)][z]
    }

    private static func color(segment s: Int, palette: Palette) -> Color {
        zoneColor(zone(segment: s), palette: palette)
    }
}

private final class SpectrumState {
    var display = [Float](repeating: -120, count: Equalizer.frequencies.count)
    var peaks = [Float](repeating: -120, count: Equalizer.frequencies.count)
    private var peakTime = [Date](repeating: .distantPast, count: Equalizer.frequencies.count)
    private var last: Date?

    func advance(to now: Date, bands: [Float]?) {
        let dt = Float(last.map { now.timeIntervalSince($0) } ?? 0)
        last = now
        for i in display.indices {
            let target = bands?[i] ?? -120
            // Instant attack, 30 dB/s release.
            display[i] = target > display[i] ? target : max(target, display[i] - 30 * dt)
            if display[i] >= peaks[i] {
                peaks[i] = display[i]
                peakTime[i] = now
            } else if now.timeIntervalSince(peakTime[i]) > 0.9 {
                peaks[i] -= 20 * dt
            }
        }
    }
}
