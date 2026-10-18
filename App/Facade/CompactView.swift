import AppKit
import SwiftUI

/// Small always-available player for when you work: cover, title, transport, progress and
/// volume on one slim plate. No meters and no analysis run here.
struct CompactView: View {
    @Environment(AmpModel.self) private var amp
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("compactOnTop") private var onTop = false

    static let size = CGSize(width: 520, height: 104)

    var body: some View {
        @Bindable var amp = amp
        let player = amp.player
        let info = player.nowPlaying
        let palette = amp.finish.palette

        ZStack {
            FrontPlate()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(palette.glossy ? 0.12 : 0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 12, y: 8)

            WindowDragArea()

            HStack(spacing: 14) {
                cover(info?.artwork)

                VStack(alignment: .leading, spacing: 5) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info?.title ?? "Idiophile One")
                            .font(.custom("AvenirNextCondensed-DemiBold", size: 15)).lineLimit(1).engraved()
                        Text(subtitle(player, info))
                            .font(PanelFont.label(11)).lineLimit(1).engraved().opacity(0.75)
                    }
                    CompactProgress(player: player, duration: info?.duration ?? 0, isRadio: player.isRadio)
                    HStack(spacing: 8) {
                        Button { player.previous() } label: { Image(systemName: "backward.end.fill") }
                        Button { amp.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                        Button { player.next() } label: { Image(systemName: "forward.end.fill") }
                        Spacer(minLength: 4)
                        HStack(spacing: 5) {
                            IndicatorLED(lit: amp.isOn && player.isBitPerfect)
                            Text("BIT-PERFECT").font(PanelFont.label(9)).tracking(1).engraved()
                        }
                        .opacity(player.isBitPerfect ? 1 : 0.55)
                        Button { onTop.toggle(); applyLevel() } label: { Image(systemName: onTop ? "pin.fill" : "pin") }
                            .accessibilityHint("Keep on top")
                        Button { showRack() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .accessibilityHint("Show the full rack")
                    }
                    .buttonStyle(CompactKeyStyle())
                }

                Knob(diameter: 46, value: $amp.volume, accessibilityName: "Volume")
                    .frame(width: 58, height: 58)
            }
            .padding(.horizontal, 14)
        }
        .padding(14)
        .frame(width: Self.size.width + 28, height: Self.size.height + 28)
        .contextMenu { InterfaceMenu() }
        .environment(\.palette, palette)
        .background(CompactWindowSetup(onTop: onTop))
        .opacity(amp.isOn ? 1 : 0.5)
    }

    private func cover(_ image: NSImage?) -> some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(white: 0.1)
                    Image(systemName: "music.note").font(.system(size: 26, weight: .ultraLight)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }

    private func subtitle(_ player: PlayerEngine, _ info: TrackInfo?) -> String {
        if let missing = player.missingOutputName { return "\(missing) is not connected" }
        guard let info else { return "Drop music or open the library" }
        if player.isRadio { return info.artist ?? "Live radio" }
        return [info.artist, info.album].compactMap { $0 }.joined(separator: " — ")
    }

    private func showRack() {
        amp.compactMode = false
        RackWindow.shared.window?.makeKeyAndOrderFront(nil)
        dismissWindow(id: "compact")
    }

    private func applyLevel() {
        for window in NSApp.windows where window.identifier?.rawValue.contains("compact") == true {
            window.level = onTop ? .floating : .normal
        }
    }
}

private struct CompactProgress: View {
    let player: PlayerEngine
    let duration: TimeInterval
    let isRadio: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        TimelineView(.periodic(from: .now, by: player.isPlaying ? 1 : 3600)) { _ in
            let t = player.currentTime()
            HStack(spacing: 8) {
                Text(isRadio ? "LIVE" : Self.clock(t)).frame(width: 34, alignment: .trailing)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.lettering.opacity(0.18))
                        if !isRadio, duration > 0 {
                            Capsule().fill(palette.accent).frame(width: geo.size.width * CGFloat(min(t / duration, 1)))
                        } else if isRadio {
                            Capsule().fill(palette.accent.opacity(0.5))
                        }
                    }
                }
                .frame(height: 3)
                Text(isRadio ? "" : Self.clock(duration)).frame(width: 34, alignment: .leading)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(palette.lettering.opacity(0.8))
        }
    }

    private static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct CompactKeyStyle: ButtonStyle {
    @Environment(\.palette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.keyLettering)
            .frame(width: 30, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [configuration.isPressed ? palette.keyBottom : palette.keyTop, palette.keyBottom],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
            .offset(y: configuration.isPressed ? 1 : 0)
    }
}

/// Invisible layer that moves the window when dragged. Placed above the plate and below the
/// controls, so buttons and knobs still get their own clicks.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// Transparent, borderless window like the rack, with no rack bookkeeping.
private struct CompactWindowSetup: NSViewRepresentable {
    var onTop: Bool

    func makeNSView(context: Context) -> NSView { View() }

    func updateNSView(_ view: NSView, context: Context) {
        view.window?.level = onTop ? .floating : .normal
    }

    private final class View: NSView {
        override func viewDidMoveToWindow() {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.identifier = NSUserInterfaceItemIdentifier("compact")
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = true
            }
            window.level = UserDefaults.standard.bool(forKey: "compactOnTop") ? .floating : .normal
        }
    }
}
