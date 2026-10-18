import AppKit
import SwiftUI

/// The hi-fi rack floating on the desktop, scaled to fit the window.
struct RoomView: View {
    @Environment(AmpModel.self) private var amp
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    static let unitGap: CGFloat = 8
    static let margin: CGFloat = 30

    /// Unscaled size of the visible rack, including margins for shadows.
    static func designSize(streamer: Bool, amplifier: Bool = true, equalizer: Bool) -> CGSize {
        let feet = FacadeView.feetHeight
        var height: CGFloat = 0
        var units = 0
        if streamer { height += StreamerView.height + feet; units += 1 }
        if amplifier { height += FacadeView.panelHeight + feet; units += 1 }
        if equalizer { height += EqualizerView.height + feet; units += 1 }
        height += CGFloat(max(units - 1, 0)) * unitGap
        return CGSize(width: 1200 + 2 * margin, height: height + 2 * margin)
    }

    private var designSize: CGSize {
        Self.designSize(streamer: amp.showStreamer, amplifier: amp.showAmplifier, equalizer: amp.showEqualizer)
    }

    var body: some View {
        GeometryReader { geo in
            let design = designSize
            let scale = min(geo.size.width / design.width, geo.size.height / design.height)
            ZStack {
                VStack(spacing: Self.unitGap) {
                    if amp.showStreamer { StreamerView() }
                    if amp.showAmplifier { FacadeView() }
                    if amp.showEqualizer { EqualizerView() }
                }
                .frame(width: 1200, height: design.height - 2 * Self.margin)
                .scaleEffect(scale)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .contextMenu { InterfaceMenu() }
        .environment(\.palette, amp.finish.palette)
        .background(TransparentWindow(aspect: designSize))
        .onChange(of: amp.compactMode, initial: true) { _, compact in
            if compact {
                openWindow(id: "compact")
                // The rack stops all drawing once it is out of sight.
                DispatchQueue.main.async { RackWindow.shared.window?.orderOut(nil) }
            } else {
                dismissWindow(id: "compact")
                RackWindow.shared.window?.makeKeyAndOrderFront(nil)
            }
        }
        .onChange(of: amp.eqEditorRequested) { _, requested in
            guard requested else { return }
            amp.eqEditorRequested = false
            openWindow(id: "eqeditor")
        }
        .onChange(of: amp.audioPathRequested) { _, requested in
            guard requested else { return }
            amp.audioPathRequested = false
            openWindow(id: "audiopath")
        }
        .onChange(of: amp.libraryRequested) { _, requested in
            guard requested else { return }
            amp.libraryRequested = false
            openWindow(id: "library")
        }
        .onChange(of: amp.showEqualizer && amp.isVisible && amp.spectrumLive, initial: true) { _, on in
            amp.player.levels.setSpectrumEnabled(on)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let window = note.object as? NSWindow, window === RackWindow.shared.window else { return }
            amp.isVisible = window.occlusionState.contains(.visible)
        }
        .dropDestination(for: URL.self) { urls, _ in
            amp.load(urls)
            return true
        }
        .onAppear {
            // Development hook: `open --env IDIOPHILE_OPEN=/path/to/music -a "Idiophile One"`.
            if let path = ProcessInfo.processInfo.environment["IDIOPHILE_OPEN"] {
                amp.load([URL(fileURLWithPath: path)])
            }
        }
    }
}

/// Makes the hosting window transparent so only the components (and their shadows) show,
/// and keeps the window shaped like the rack so it can be sized to any screen.
/// The rack can be dragged by any bare part of a front panel.
struct TransparentWindow: NSViewRepresentable {
    var aspect: CGSize

    func makeNSView(context: Context) -> NSView { WindowConfigurator() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? WindowConfigurator)?.apply(aspect: aspect)
    }

    private final class WindowConfigurator: NSView {
        private var aspect: CGSize?

        override func viewDidMoveToWindow() {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            // The rack is the window: no traffic lights, the POWER button closes it.
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = true
            }
            RackWindow.shared.window = window
            if let aspect { apply(aspect: aspect, force: true) }
            // macOS restores the previous frame after this point: check again once settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let aspect = self.aspect else { return }
                self.apply(aspect: aspect, force: true)
            }
        }

        func apply(aspect: CGSize, force: Bool = false) {
            guard force || aspect != self.aspect else { return }
            self.aspect = aspect
            guard let window else { return }
            window.contentAspectRatio = aspect
            // Keep the width, follow the rack's new height (units shown or hidden). Before the
            // first layout the width is not meaningful: start at three quarters of design size.
            let content = window.contentLayoutRect.size
            let shaped = content.height > 0 && abs(content.width / content.height - aspect.width / aspect.height) < 0.02
            if force && shaped && content.width >= 560 { return }
            RackWindow.shared.resize(toWidth: content.width >= 560 ? content.width : aspect.width * 0.75, aspect: aspect)
        }
    }
}

/// Sizes the rack window: presets relative to the design size, or fitted to the screen.
@MainActor
final class RackWindow {
    static let shared = RackWindow()
    weak var window: NSWindow?

    func zoom(_ scale: CGFloat, aspect: CGSize) {
        resize(toWidth: aspect.width * scale, aspect: aspect)
    }

    func fitScreen(aspect: CGSize) {
        guard let screen = window?.screen?.visibleFrame else { return }
        let scale = min(screen.width / aspect.width, screen.height / aspect.height)
        resize(toWidth: aspect.width * scale, aspect: aspect)
        window?.center()
    }

    func resize(toWidth width: CGFloat, aspect: CGSize) {
        guard let window else { return }
        var size = CGSize(width: width, height: width * aspect.height / aspect.width)
        if let screen = window.screen?.visibleFrame, size.height > screen.height || size.width > screen.width {
            let k = min(screen.width / size.width, screen.height / size.height)
            size = CGSize(width: size.width * k, height: size.height * k)
        }
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        // Grow or shrink from the top-left corner.
        frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }
}

/// Brushed aluminium front plate shared by every unit of the rack.
struct UnitPanel: View {
    var height: CGFloat
    var showFeet = false
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack(alignment: .top) {
            if showFeet {
                HStack {
                    foot
                    Spacer()
                    foot
                }
                .padding(.horizontal, 60)
                .frame(height: height + FacadeView.feetHeight, alignment: .bottom)
            }
            FrontPlate()
                .overlay(
                    // Dim, warm room light falling from above.
                    LinearGradient(colors: [Color(red: 1, green: 0.8, blue: 0.55).opacity(palette.roomLight), .clear, .black.opacity(0.22)],
                                   startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(palette.glossy ? 0.35 : 0.6)).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.35)).frame(height: 2) }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .frame(width: 1200, height: height)
                .shadow(color: .black.opacity(0.6), radius: 18, y: 12)
        }
        .frame(width: 1200, height: height + (showFeet ? FacadeView.feetHeight : 0), alignment: .top)
        // Static chrome: rasterise once (shadow included) instead of re-compositing the
        // shadow every time a needle moves.
        .padding(40)
        .drawingGroup()
        .padding(-40)
        // Outside the flattened group: AppKit views cannot live inside drawingGroup.
        .overlay(WindowDragArea())
    }

    /// Machined aluminium foot with a dark damping ring, as on high-end components.
    private var foot: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(white: 0.08))
                .frame(width: 70, height: 3)
            Rectangle()
                .fill(LinearGradient(colors: [Color(white: 0.45), Color(white: 0.92), Color(white: 0.6),
                                              Color(white: 0.85), Color(white: 0.4)],
                                     startPoint: .leading, endPoint: .trailing))
                .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.35)).frame(height: 1) }
                .frame(width: 70, height: FacadeView.feetHeight - 3)
        }
        .shadow(color: .black.opacity(0.7), radius: 4, y: 3)
    }
}

/// Dark smoked-glass window used by displays and the spectrum analyser.
struct GlassWindow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color(red: 0.05, green: 0.035, blue: 0.025))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                LinearGradient(colors: [.black.opacity(0.7), .white.opacity(0.55)], startPoint: .top, endPoint: .bottom),
                lineWidth: 2))
    }
}

/// Reflection layered over a glass window.
struct GlassSheen: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.02), .clear],
                                 startPoint: .topLeading, endPoint: .center))
            .allowsHitTesting(false)
    }
}

/// Front panel of the amplifier, laid out on a fixed 1200 × 400 design grid.
struct FacadeView: View {
    @Environment(AmpModel.self) private var amp
    static let panelHeight: CGFloat = 400
    static let feetHeight: CGFloat = 20

    var body: some View {
        @Bindable var amp = amp

        ZStack(alignment: .topLeading) {
            UnitPanel(height: Self.panelHeight, showFeet: true)

            MeterWindow()
                .position(x: 600, y: 160)

            // Input selector.
            VStack(spacing: 6) {
                HStack(spacing: 14) {
                    ForEach(AmpModel.Input.allCases, id: \.self) { input in
                        Text(input.label)
                            .font(PanelFont.label(11))
                            .tracking(1)
                            .engraved()
                            .opacity(amp.input == input ? 1 : 0.6)
                    }
                }
                Knob(diameter: 84, value: inputBinding, detents: AmpModel.Input.allCases.count, sweep: 90,
                     accessibilityName: "Input selector")
                Text("INPUT").font(PanelFont.label(10)).tracking(2.5).engraved()
            }
            .position(x: 105, y: 140)

            PowerButton(isOn: amp.isOn) { amp.togglePower() }
                .position(x: 105, y: 315)

            // Volume.
            VStack(spacing: 8) {
                Knob(diameter: 136, value: $amp.volume, accessibilityName: "Volume")
                Text("VOLUME").font(PanelFont.label(10)).tracking(2.5).engraved()
                Text(volumeText).font(PanelFont.label(10)).tracking(1).engraved().opacity(0.75)
                HStack(spacing: 7) {
                    IndicatorLED(lit: amp.isOn && amp.player.isBitPerfect)
                    Text("BIT-PERFECT").font(PanelFont.label(10)).tracking(1.5).engraved()
                }
                .padding(.top, 4)
            }
            .position(x: 1090, y: 182)

            // Lower row: transport, display, dimmer.
            HStack(spacing: 10) {
                Button { amp.openFiles() } label: { Image(systemName: "eject.fill") }
                Button { amp.player.previous() } label: { Image(systemName: "backward.end.fill") }
                Button { amp.togglePlay() } label: { Image(systemName: "playpause.fill") }
                Button { amp.player.next() } label: { Image(systemName: "forward.end.fill") }
            }
            .buttonStyle(PanelKeyStyle())
            .position(x: 340, y: 352)

            FluorescentDisplay()
                .frame(width: 300, height: 46)
                .position(x: 640, y: 352)

            HStack(spacing: 10) {
                Button("DIRECT") { amp.toggleDirect() }
                    .buttonStyle(PanelKeyStyle(lit: amp.isOn && amp.player.isDirect))
                    .accessibilityHint("Bypass all processing: no EQ, unity digital gain, DAC volume, exclusive access")
                Button("METER") { amp.cycleMeterMode() }
                    .buttonStyle(PanelKeyStyle(lit: amp.isOn && amp.meterMode == .peak))
                    .accessibilityHint("VU (300 ms, IEC 60268-17) or PEAK (fast attack, slow fall)")
                Button("DIMMER") { amp.cycleDimmer() }
                    .buttonStyle(PanelKeyStyle(lit: amp.isOn))
            }
            .position(x: 905, y: 352)

            Text("IDIOPHILE ONE")
                .font(.custom("Futura-Medium", size: 12))
                .tracking(3.5)
                .engraved()
                .position(x: 1100, y: 352)
        }
        .frame(width: 1200, height: Self.panelHeight + Self.feetHeight, alignment: .topLeading)
    }

    private var inputBinding: Binding<Double> {
        Binding(
            get: { Double(amp.input.rawValue) / Double(AmpModel.Input.allCases.count - 1) },
            set: { amp.select(AmpModel.Input(rawValue: Int(($0 * Double(AmpModel.Input.allCases.count - 1)).rounded())) ?? .library) }
        )
    }

    private var volumeText: String {
        let db = amp.volumeDB
        guard db.isFinite, !amp.player.isMuted else { return "MUTE" }
        return String(format: amp.isHardwareVolume ? "DAC %.1f dB" : "%.1f dB", db)
    }
}
