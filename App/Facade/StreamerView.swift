import SwiftUI

/// Network player unit: a large smoked-glass screen with the album jacket and track details.
struct StreamerView: View {
    @Environment(AmpModel.self) private var amp
    @Environment(\.openWindow) private var openWindow

    static let height: CGFloat = 250
    private static let display = CGRect(x: 40, y: 24, width: 840, height: 202)

    var body: some View {
        ZStack(alignment: .topLeading) {
            UnitPanel(height: Self.height, showFeet: true)

            ZStack {
                GlassWindow()
                if amp.isOn {
                    NowPlayingScreen()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(2)
                        .opacity(0.5 + 0.5 * amp.dimmer)
                        .transition(.opacity)
                }
                GlassSheen()
            }
            .frame(width: Self.display.width, height: Self.display.height)
            .position(x: Self.display.midX, y: Self.display.midY)
            .animation(.easeOut(duration: 0.8), value: amp.isOn)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("IDIOPHILE").font(.custom("Futura-Medium", size: 15)).tracking(5).engraved()
                    Text("NETWORK PLAYER").font(PanelFont.label(10)).tracking(3).engraved().opacity(0.8)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AmpModel.Input.allCases, id: \.self) { input in
                        HStack(spacing: 8) {
                            IndicatorLED(lit: amp.isOn && amp.input == input)
                            Text(input.longLabel).font(PanelFont.label(10)).tracking(1.5).engraved()
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button("LIBRARY") { openWindow(id: "library") }
                        .buttonStyle(PanelKeyStyle())
                    Button("SOURCE") { amp.cycleInput() }
                        .buttonStyle(PanelKeyStyle())
                }
            }
            .frame(width: 260, alignment: .leading)
            .position(x: 1040, y: Self.height / 2)
        }
        .frame(width: 1200, height: Self.height + FacadeView.feetHeight, alignment: .topLeading)
    }
}

/// Contents of the streamer screen.
private struct NowPlayingScreen: View {
    @Environment(AmpModel.self) private var amp

    @Environment(\.palette) private var palette

    private static let warmWhite = Color(red: 0.98, green: 0.92, blue: 0.82)
    private var amber: Color { palette.accent }

    var body: some View {
        let player = amp.player
        let info = player.nowPlaying

        ZStack(alignment: .leading) {
            HStack(alignment: .center, spacing: 22) {
                jacket(info?.artwork)

                VStack(alignment: .leading, spacing: 6) {
                    Text(sourceCaption(player))
                        .font(PanelFont.label(10)).tracking(2.5)
                        .foregroundStyle(amber)
                    Text(info?.title ?? "Drop music on the rack")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Self.warmWhite)
                        .lineLimit(1)
                    Text(info?.artist ?? (info == nil ? "or press ⏏ to choose files" : (player.isRadio ? "Live broadcast" : "Unknown artist")))
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Self.warmWhite.opacity(0.85))
                        .lineLimit(1)
                    if let album = info?.album {
                        Text(album)
                            .font(.system(size: 13, weight: .regular))
                            .italic()
                            .foregroundStyle(Self.warmWhite.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let info {
                        signalPath(info, player)
                        if player.isRadio {
                            HStack(spacing: 6) {
                                Circle().fill(Color.red).frame(width: 7, height: 7)
                                Text("LIVE").font(PanelFont.label(11)).tracking(2)
                            }
                            .foregroundStyle(Self.warmWhite.opacity(0.8))
                        } else {
                            ProgressLine(player: player, duration: info.duration, tint: amber, text: Self.warmWhite)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                upNext(player)
                    .frame(width: 170, alignment: .topLeading)
            }
            .padding(16)
        }
        .background {
            // Jacket colours bleeding softly into the screen, kept inside the display bounds.
            if let art = info?.artwork {
                Color.clear
                    .overlay(Image(nsImage: art).resizable().aspectRatio(contentMode: .fill).blur(radius: 40))
                    .clipped()
                    .opacity(0.45)
                    .overlay(LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.75)],
                                            startPoint: .leading, endPoint: .trailing))
            }
        }
    }

    /// Source format → output device and clock, with the bit-perfect verdict.
    private func signalPath(_ info: TrackInfo, _ player: PlayerEngine) -> some View {
        HStack(spacing: 8) {
            badge(info.formatLabel.uppercased(), lit: true)
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(amber.opacity(0.7))
            let device = player.outputDevice?.name ?? player.missingOutputName.map { "\($0) — missing" } ?? "No output"
            let bits = player.deviceBits.map { " · \($0)-BIT" } ?? ""
            let rate = player.deviceRate > 0 ? String(format: " · %g kHz", player.deviceRate / 1000) + bits : ""
            badge((device + rate).uppercased(), lit: true)
            if player.isPolarityInverted {
                badge("Ø INVERTED", lit: true)
            }
            if let rg = player.replayGainDB {
                badge(String(format: "RG %+.1f dB", rg), lit: true)
            }
            if player.isBitPerfect {
                badge("BIT-PERFECT", lit: true, filled: true)
            } else if player.deviceRate > 0 && info.sampleRate > 0 && player.deviceRate != info.sampleRate {
                badge("RESAMPLED", lit: false)
            }
        }
        .lineLimit(1)
        .contentShape(Rectangle())
        .onTapGesture { amp.audioPathRequested = true }
        .accessibilityHint("Show the audio path")
    }

    private func badge(_ text: String, lit: Bool, filled: Bool = false) -> some View {
        Text(text)
            .font(PanelFont.label(11)).tracking(1.2)
            .foregroundStyle(filled ? Color.black.opacity(0.85) : amber.opacity(lit ? 1 : 0.55))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(filled ? amber : .clear))
            .overlay(Capsule().strokeBorder(amber.opacity(lit ? 0.7 : 0.35), lineWidth: 1))
    }

    private func jacket(_ art: NSImage?) -> some View {
        Group {
            if let art {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(white: 0.09)
                    Image(systemName: "music.note")
                        .font(.system(size: 54, weight: .ultraLight))
                        .foregroundStyle(amber.opacity(0.5))
                }
            }
        }
        .frame(width: 168, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.6), radius: 8, y: 4)
    }

    private func upNext(_ player: PlayerEngine) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("UP NEXT").font(PanelFont.label(10)).tracking(2.5).foregroundStyle(amber)
            let next = player.upcoming(4)
            if next.isEmpty {
                Text("End of queue").font(.system(size: 12)).foregroundStyle(Self.warmWhite.opacity(0.4))
            }
            ForEach(Array(next.enumerated()), id: \.offset) { i, name in
                Text("\(player.index + i + 2)  \(name)")
                    .font(.system(size: 12))
                    .foregroundStyle(Self.warmWhite.opacity(0.75 - Double(i) * 0.12))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    private func sourceCaption(_ player: PlayerEngine) -> String {
        let state = player.nowPlaying == nil ? "STANDBY" : (player.isPlaying ? "NOW PLAYING" : "PAUSED")
        return "\(amp.input.longLabel)  ·  \(state)"
    }
}

/// Thin elapsed-time bar with clock readouts.
private struct ProgressLine: View {
    let player: PlayerEngine
    let duration: TimeInterval
    let tint: Color
    let text: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: player.isPlaying ? 1 : 3600)) { _ in
            let t = player.currentTime()
            HStack(spacing: 10) {
                Text(Self.clock(t))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(text.opacity(0.15))
                        Capsule().fill(tint)
                            .frame(width: geo.size.width * CGFloat(duration > 0 ? min(t / duration, 1) : 0))
                            .shadow(color: tint.opacity(0.6), radius: 3)
                    }
                }
                .frame(height: 3)
                Text(Self.clock(duration))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(text.opacity(0.7))
        }
    }

    private static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
