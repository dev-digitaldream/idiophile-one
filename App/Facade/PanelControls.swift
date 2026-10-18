import AppKit
import SwiftUI

// MARK: - Materials

/// Small deterministic RNG so the brushed texture is identical on every draw.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Front plate material of the current finish: brushed metal or polished black glass.
struct FrontPlate: View {
    @Environment(\.palette) private var palette

    var body: some View {
        let palette = palette
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(rect), with: .linearGradient(
                Gradient(colors: palette.plate), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            if let brushing = palette.brushing {
                var rng = SplitMix64(state: 0x1D10_F11E)
                var y: CGFloat = 0
                while y < size.height {
                    for _ in 0..<3 {
                        let x = CGFloat.random(in: -200...size.width, using: &rng)
                        let length = CGFloat.random(in: 80...size.width * 0.8, using: &rng)
                        let light = Bool.random(using: &rng)
                        let alpha = Double.random(in: brushing, using: &rng)
                        let line = Path { $0.move(to: CGPoint(x: x, y: y)); $0.addLine(to: CGPoint(x: x + length, y: y)) }
                        ctx.stroke(line, with: .color((light ? Color.white : Color.black).opacity(alpha)), lineWidth: 0.7)
                    }
                    y += 0.8
                }
            }

            if palette.glossy {
                // Polished glass: a soft reflection of the room across the upper third.
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.42)),
                         with: .linearGradient(Gradient(colors: [.white.opacity(0.13), .white.opacity(0.04), .clear]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.42)))
                ctx.fill(Path(CGRect(x: 0, y: 2, width: size.width, height: 1)), with: .color(.white.opacity(0.25)))
            }

            if palette.endCaps {
                for x in [0, size.width - 22] {
                    let cap = CGRect(x: x, y: 0, width: 22, height: size.height)
                    ctx.fill(Path(cap), with: .linearGradient(
                        Gradient(colors: [Color(white: 0.55), Color(white: 0.9), Color(white: 0.7), Color(white: 0.5)]),
                        startPoint: CGPoint(x: cap.minX, y: 0), endPoint: CGPoint(x: cap.maxX, y: 0)))
                    var rng = SplitMix64(state: UInt64(x) &+ 7)
                    var y: CGFloat = 0
                    while y < size.height {
                        let line = Path { $0.move(to: CGPoint(x: cap.minX, y: y)); $0.addLine(to: CGPoint(x: cap.maxX, y: y)) }
                        ctx.stroke(line, with: .color(.black.opacity(Double.random(in: 0.01...0.06, using: &rng))), lineWidth: 0.6)
                        y += 1.2
                    }
                }
            }
        }
    }
}

/// Lettering on the front plate: engraved into metal, or lit from behind on glass.
private struct Lettering: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .foregroundStyle(palette.lettering)
            .shadow(color: palette.letteringShadow, radius: palette.letteringLit ? 3 : 0, x: 0, y: palette.letteringShadowY)
    }
}

extension View {
    /// Text and symbols on the front panel, styled by the current finish.
    func engraved() -> some View { modifier(Lettering()) }
}

enum PanelFont {
    static func label(_ size: CGFloat) -> Font { .custom("AvenirNextCondensed-DemiBold", size: size) }
}

// MARK: - Knob

/// Machined rotary knob with a fixed chrome reflection and a rotating pointer.
/// Drag vertically, scroll, or (when `detents` is set) click to step.
struct Knob: View {
    var diameter: CGFloat
    @Binding var value: Double
    var detents: Int? = nil
    var sweep: Double = 280
    var accessibilityName: String

    /// Continuous value accumulated during a drag (detents snap only what is shown).
    @State private var dragValue: Double?
    @State private var lastAngle: Double?
    @State private var hovering = false
    @Environment(\.palette) private var palette

    private var angle: Double { -sweep / 2 + value * sweep }

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.45))
                .frame(width: diameter + 6, height: diameter + 6)
                .blur(radius: 7)
                .offset(y: 6)
            Circle()
                .fill(Color(red: 0.18, green: 0.17, blue: 0.16))
                .frame(width: diameter + 10, height: diameter + 10)
            Circle()
                .fill(AngularGradient(colors: palette.knob, center: .center, angle: .degrees(-20)))
                .overlay(
                    Circle().fill(RadialGradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.12)],
                                                 center: .center, startRadius: 0, endRadius: diameter / 2)))
                .overlay(
                    Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.9), .black.opacity(0.4)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
                .frame(width: diameter, height: diameter)
            Circle()
                .fill(palette.knobPointer)
                .frame(width: diameter * 0.075, height: diameter * 0.075)
                .shadow(color: .white.opacity(0.4), radius: 0, y: 1)
                .offset(y: -diameter * 0.36)
                .rotationEffect(.degrees(angle))
        }
        .frame(width: diameter + 16, height: diameter + 16)
        .padding(12)
        .drawingGroup()
        .padding(-12)
        .contentShape(Circle())
        .gesture(
            // Turn it like a real knob: follow the pointer around the centre.
            DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let size = diameter + 16
                    let dx = g.location.x - size / 2
                    let dy = g.location.y - size / 2
                    guard dx * dx + dy * dy > pow(diameter * 0.12, 2) else { return }
                    let pointer = atan2(dx, -dy) * 180 / .pi   // 0° at the top, clockwise
                    if let last = lastAngle {
                        var delta = pointer - last
                        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                        let raw = min(max((dragValue ?? value) + delta / sweep, 0), 1)
                        dragValue = raw
                        set(raw)
                    }
                    lastAngle = pointer
                }
                .onEnded { _ in
                    dragValue = nil
                    lastAngle = nil
                }
        )
        .simultaneousGesture(TapGesture().onEnded {
            guard let n = detents, n > 1 else { return }
            let step = 1 / Double(n - 1)
            value = value >= 1 - step / 2 ? 0 : value + step
        })
        .onHover { hovering = $0 }
        .background(ScrollWheelMonitor(active: hovering) { delta in set(value + Double(delta) / 600) })
        .animation(detents == nil ? nil : .spring(duration: 0.18), value: value)
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue("\(Int(value * 100)) %")
        .accessibilityAdjustableAction { direction in
            let step = detents.map { 1 / Double(max($0 - 1, 1)) } ?? 0.02
            set(value + (direction == .increment ? step : -step))
        }
    }

    private func set(_ raw: Double) {
        let clamped = min(max(raw, 0), 1)
        if let n = detents, n > 1 {
            value = (clamped * Double(n - 1)).rounded() / Double(n - 1)
        } else {
            value = clamped
        }
    }
}

/// Delivers scroll-wheel deltas while `active`, without intercepting clicks or drags.
/// Event monitoring avoids hosting an AppKit view inside the scaled SwiftUI facade.
struct ScrollWheelMonitor: NSViewRepresentable {
    var active: Bool
    var handler: (CGFloat) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.active = active
        view.handler = handler
    }

    final class MonitorView: NSView {
        var active = false
        var handler: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.active, event.window == self.window else { return event }
                // Physical direction: wheel or fingers up always means more, whatever the
                // "natural scrolling" setting.
                var delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
                if event.isDirectionInvertedFromDevice { delta = -delta }
                self.handler?(delta)
                return nil
            }
        }
    }
}

// MARK: - Buttons

/// Small status lamp in the finish's accent colour.
struct IndicatorLED: View {
    var lit: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Circle()
            .fill(lit ? palette.accent : palette.accentOff)
            .frame(width: 6, height: 6)
            .shadow(color: lit ? palette.accent : .clear, radius: 4)
            .animation(.easeInOut(duration: 0.2), value: lit)
    }
}

/// Round chrome push button with a power LED.
struct PowerButton: View {
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "power").font(.system(size: 13, weight: .semibold)).engraved()
                IndicatorLED(lit: isOn)
            }
            Button(action: action) { EmptyView() }
                .buttonStyle(ChromeRoundStyle())
                .accessibilityLabel(isOn ? "Power off" : "Power on")
        }
        .animation(.easeInOut(duration: 0.25), value: isOn)
    }
}

private struct ChromeRoundStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle().fill(.black.opacity(0.4)).frame(width: 56, height: 56).blur(radius: 4).offset(y: 3)
            Circle().fill(Color(red: 0.2, green: 0.19, blue: 0.18)).frame(width: 54, height: 54)
            Circle()
                .fill(AngularGradient(colors: [Color(white: 0.7), Color(white: 0.98), Color(white: 0.6), Color(white: 0.92), Color(white: 0.7)],
                                      center: .center))
                .frame(width: 48, height: 48)
            Circle()
                .fill(RadialGradient(colors: [Color(white: configuration.isPressed ? 0.8 : 0.97), Color(white: 0.82)],
                                     center: .center, startRadius: 2, endRadius: 18))
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.25), radius: 1, y: configuration.isPressed ? 0 : 1)
        }
        .padding(8)
        .drawingGroup()
        .padding(-8)
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// Small rectangular key, as on the lower row of an amplifier.
struct PanelKeyStyle: ButtonStyle {
    var lit = false

    func makeBody(configuration: Configuration) -> some View {
        PanelKey(label: configuration.label, pressed: configuration.isPressed, lit: lit)
    }
}

private struct PanelKey<Label: View>: View {
    let label: Label
    let pressed: Bool
    let lit: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        label
            .font(PanelFont.label(11))
            .tracking(1)
            .foregroundStyle(palette.keyLettering)
            .shadow(color: palette.letteringLit ? palette.letteringShadow : .clear, radius: 2)
            .frame(width: 58, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [pressed ? palette.keyBottom : palette.keyTop, palette.keyBottom],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(pressed ? 0.15 : 0.35), radius: pressed ? 0.5 : 1.5, y: pressed ? 0.5 : 1.5)
            )
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.12), lineWidth: 0.5).padding(0.5))
            .overlay(alignment: .top) {
                if lit {
                    Capsule().fill(palette.accent).frame(width: 14, height: 2)
                        .shadow(color: palette.accent, radius: 3).offset(y: -7)
                }
            }
            .offset(y: pressed ? 1 : 0)
    }
}

// MARK: - Display

/// Fluorescent display behind smoked glass: title and elapsed time.
struct FluorescentDisplay: View {
    @Environment(AmpModel.self) private var amp
    @Environment(\.palette) private var palette

    var body: some View {
        let player = amp.player
        let glow = palette.accent
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.07, green: 0.045, blue: 0.03))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(
                    LinearGradient(colors: [.black.opacity(0.6), .white.opacity(0.5)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.5))
            if amp.isOn {
                // The clock shows whole seconds: one refresh per second is enough, and each refresh makes
                // SwiftUI walk the whole display list (about 1 % of a core per Hz measured).
                TimelineView(.periodic(from: .now, by: player.isPlaying && amp.isVisible ? 1 : 3600)) { _ in
                    VStack(spacing: 3) {
                        Text(primaryLine(player))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(secondaryLine(player))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .opacity(0.8)
                    }
                    .padding(.horizontal, 14)
                    .foregroundStyle(glow)
                    .shadow(color: glow.opacity(0.8), radius: 3)
                    .opacity(0.45 + 0.55 * amp.dimmer)
                }
            }
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .top, endPoint: .center))
                .allowsHitTesting(false)
        }
    }

    private func primaryLine(_ p: PlayerEngine) -> String {
        if let error = p.lastError { return "ERROR  \(error)".uppercased() }
        guard let info = p.nowPlaying else { return amp.input == .library ? "DROP MUSIC HERE" : "\(amp.input.label)  —  SOON" }
        return [info.artist, info.title].compactMap { $0 }.joined(separator: " — ").uppercased()
    }

    private func secondaryLine(_ p: PlayerEngine) -> String {
        guard let info = p.nowPlaying else { return "\(String(format: "%+.1f", amp.volumeDB.isFinite ? amp.volumeDB : -99)) dB" }
        let state = p.isMuted ? "MUTE" : (p.isPlaying ? "▶" : "❚❚")
        if p.isRadio { return "\(state)  LIVE  ·  \(info.codec)" }
        return "\(state)  \(Self.clock(p.currentTime()))  /  \(Self.clock(info.duration))   \(p.index + 1)/\(p.queue.count)"
    }

    private static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
