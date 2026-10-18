import SwiftUI

/// Per-frame physical state of the two needles and the peak lamps.
final class MeterAnimator {
    var left = NeedleBallistics()
    var right = NeedleBallistics()
    var peakUntil: (left: Date, right: Date) = (.distantPast, .distantPast)
    /// PEAK-mode detector envelopes, linear.
    private var envelope: (left: Float, right: Float) = (0, 0)
    private var last: Date?
    private var lastHost: Double?

    /// Sample peak that lights the PEAK lamp (−1 dBFS).
    static let peakThreshold: Float = 0.891
    /// PEAK fall-back: 20 dB in 1.7 s, as on broadcast peak programme meters.
    static let peakFallPerSecond = Float(pow(10.0, -1.0 / 1.7))

    func advance(to date: Date, tap: LevelTap?, mode: MeterMode) {
        let dt = last.map { date.timeIntervalSince($0) } ?? 0
        last = date
        let host = LevelTap.now()
        let levels = tap?.read(from: lastHost ?? host - dt, to: host)
        lastHost = host

        switch mode {
        case .vu:
            let l = levels.map { VUScale.position(forLinear: $0.average.left) } ?? 0
            let r = levels.map { VUScale.position(forLinear: $0.average.right) } ?? 0
            left.step(toward: l, dt: dt)
            right.step(toward: r, dt: dt)
        case .peak:
            let fall = pow(Self.peakFallPerSecond, Float(dt))
            envelope.left = max(levels?.peak.left ?? 0, envelope.left * fall)
            envelope.right = max(levels?.peak.right ?? 0, envelope.right * fall)
            left.step(toward: VUScale.position(forPeak: envelope.left), dt: dt, naturalFrequency: 45, damping: 0.7)
            right.step(toward: VUScale.position(forPeak: envelope.right), dt: dt, naturalFrequency: 45, damping: 0.7)
        }

        if let levels {
            if levels.peak.left >= Self.peakThreshold { peakUntil.left = date + 0.5 }
            if levels.peak.right >= Self.peakThreshold { peakUntil.right = date + 0.5 }
        }
    }
}

/// The backlit window holding both VU meters, as on vintage amplifiers.
///
/// Three layers keep the per-frame cost low: the backlit face is redrawn only while the
/// lamp changes, the needles are the only thing animated, and the glass sits on top.
struct MeterWindow: View {
    @Environment(AmpModel.self) private var amp
    @Environment(\.palette) private var palette

    static let face = CGSize(width: 760, height: 250)
    /// Room around the window for the backlight spilling onto the panel.
    static let glow: CGFloat = 60
    static let window = CGRect(origin: CGPoint(x: glow, y: glow), size: face)

    var body: some View {
        let lamp = amp.isOn ? amp.dimmer : 0
        let player = amp.player
        let playing = amp.isOn && player.isPlaying && amp.metersLive
        // With the animation cut, the needles still get a moment to fall to rest, then stop.
        let live = amp.isOn && amp.isVisible
            && (amp.metersLive ? (player.isPlaying || player.needlesSettling) : !amp.metersFrozen)
        let tap = player.levels
        let mode = amp.meterMode
        let palette = palette

        ZStack {
            MeterFace(lamp: lamp, format: amp.isOn ? player.nowPlaying?.formatLabel : nil, mode: mode, palette: palette)
                // Incandescent lamp: quick to glow, slow to reach full warmth; fades with an afterglow.
                .animation(lamp > 0 ? .timingCurve(0.2, 0.7, 0.3, 1, duration: 1.6)
                                    : .timingCurve(0.1, 0.6, 0.4, 1, duration: 0.9),
                           value: lamp)

            // Needles live in Core Animation layers: two transforms per frame, no redraw.
            NeedleLayers(tap: tap, mode: mode, playing: playing, live: live, color: palette.meterNeedle)
                .frame(width: Self.face.width, height: Self.face.height)

            Canvas { ctx, _ in MeterRenderer(window: Self.window, palette: palette).drawGlass(ctx) }
                .id(amp.finish)
        }
        .frame(width: Self.face.width + 2 * Self.glow, height: Self.face.height + 2 * Self.glow)
        .accessibilityElement()
        .accessibilityLabel("VU meters")
    }
}

/// Backlit scale plate, interpolated by SwiftUI while the lamp warms up or fades.
private struct MeterFace: View, Animatable {
    var lamp: Double
    var format: String?
    var mode: MeterMode
    var palette: Palette

    var animatableData: Double {
        get { lamp }
        set { lamp = newValue }
    }

    var body: some View {
        Canvas { ctx, _ in
            MeterRenderer(window: MeterWindow.window, palette: palette).drawFace(ctx, lamp: lamp, format: format, mode: mode)
        }
    }
}

// MARK: - Rendering

struct MeterRenderer {
    let window: CGRect
    let palette: Palette

    private var ink: Color { palette.meterInk }

    // Meter face palette: incandescent lamp behind an amber diffuser.
    static let unlit = RGB(r: 0.29, g: 0.25, b: 0.20)
    static let red = Color(red: 0.76, green: 0.14, blue: 0.08)

    static let radius: CGFloat = 228
    static let halfSweep = 45.0
    static let majorMarks: [Double] = [-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3]
    static let minorMarks: [Double] = [-15, -8.5, -6, -4, -2.5, -1.5, -0.5, 0.5, 1.5, 2.5]

    func drawFace(_ ctx: GraphicsContext, lamp b: Double, format: String?, mode: MeterMode) {
        let visibility = min(b / 0.35, 1)
        let warmth = min(max((b - 0.3) / 0.7, 0), 1)
        let hot = Self.unlit.mix(palette.meterHotDim.mix(palette.meterHotFull, warmth), visibility)
        let edge = Self.unlit.scaled(0.8).mix(palette.meterEdgeDim.mix(palette.meterEdgeFull, warmth), visibility)
        let windowPath = Path(window)

        // Warm light spilling onto the panel around the window.
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: edge.color.opacity(0.7 * visibility * b), radius: 38))
            layer.fill(windowPath, with: .color(edge.color))
        }

        ctx.drawLayer { face in
            face.clip(to: windowPath)
            face.fill(windowPath, with: .color(edge.color))
            // One lamp behind each meter.
            for cx in Self.meterCenters(window) {
                face.fill(windowPath, with: .radialGradient(
                    Gradient(colors: [hot.color, hot.color.opacity(0)]),
                    center: CGPoint(x: cx, y: window.minY + 120), startRadius: 0, endRadius: 300))
            }
            drawScale(face, centerX: Self.meterCenters(window)[0], caption: "LEFT CHANNEL", mode: mode)
            drawScale(face, centerX: Self.meterCenters(window)[1], caption: "RIGHT CHANNEL", mode: mode)

            face.draw(Text("IDIOPHILE").font(.custom("Futura-Medium", size: 17)).tracking(6)
                        .foregroundStyle(ink.opacity(0.8)),
                      at: CGPoint(x: window.midX, y: window.minY + 28))
            if let format {
                face.draw(Text(format).font(.custom("AvenirNextCondensed-DemiBold", size: 12)).tracking(1.5)
                            .foregroundStyle(ink.opacity(0.85)),
                          at: CGPoint(x: window.midX, y: window.maxY - 16))
            }
        }
    }

    func drawGlass(_ ctx: GraphicsContext) {
        let windowPath = Path(window)
        ctx.drawLayer { glass in
            glass.clip(to: windowPath)
            // Recessed window: inner shadow along the edges.
            glass.drawLayer { shade in
                shade.addFilter(.blur(radius: 9))
                shade.stroke(Path(window.insetBy(dx: -6, dy: -6)), with: .color(.black.opacity(0.6)), lineWidth: 24)
            }
            glass.fill(windowPath, with: .linearGradient(
                Gradient(colors: [.white.opacity(0.16), .white.opacity(0.03), .clear]),
                startPoint: CGPoint(x: window.minX, y: window.minY),
                endPoint: CGPoint(x: window.minX + 120, y: window.midY + 40)))
            var sheen = Path()
            sheen.move(to: CGPoint(x: window.minX + 420, y: window.minY))
            sheen.addLine(to: CGPoint(x: window.minX + 520, y: window.minY))
            sheen.addLine(to: CGPoint(x: window.minX + 400, y: window.maxY))
            sheen.addLine(to: CGPoint(x: window.minX + 330, y: window.maxY))
            sheen.closeSubpath()
            glass.fill(sheen, with: .color(.white.opacity(0.045)))
        }

        // Bezel and chamfer.
        ctx.stroke(Path(window.insetBy(dx: -1.5, dy: -1.5)),
                   with: .color(Color(red: 0.12, green: 0.10, blue: 0.09)), lineWidth: 3)
        ctx.stroke(Path(window.insetBy(dx: -4, dy: -4)),
                   with: .linearGradient(Gradient(colors: [.black.opacity(0.25), .white.opacity(0.55)]),
                                         startPoint: CGPoint(x: 0, y: window.minY),
                                         endPoint: CGPoint(x: 0, y: window.maxY)),
                   lineWidth: 1)
    }

    static func meterCenters(_ window: CGRect) -> [CGFloat] {
        [window.minX + window.width / 4, window.minX + window.width * 3 / 4]
    }

    static func peakLampCenter(_ window: CGRect, centerX: CGFloat) -> CGPoint {
        CGPoint(x: centerX + 128, y: window.maxY - 58)
    }

    private func drawScale(_ ctx: GraphicsContext, centerX: CGFloat, caption: String, mode: MeterMode) {
        let geometry = ScaleGeometry(window: window, centerX: centerX)
        let r = Self.radius

        let zero = VUScale.position(forDB: 0)
        let labelFont = Font.custom("AvenirNextCondensed-DemiBold", size: 16)

        // dB scale.
        ctx.stroke(geometry.arc(r, from: VUScale.position(forDB: -20), to: zero), with: .color(ink), lineWidth: 1.6)
        ctx.stroke(geometry.arc(r + 3, from: zero, to: 1), with: .color(Self.red), lineWidth: 6)
        for db in Self.majorMarks {
            let p = VUScale.position(forDB: db)
            let color = db > 0 ? Self.red : ink
            ctx.stroke(geometry.tick(p, from: r, to: r + 12), with: .color(color), lineWidth: 1.7)
            let label = db == 0 ? "0" : String(Int(abs(db)))
            ctx.draw(Text(label).font(labelFont).foregroundStyle(color), at: geometry.point(r + 26, p))
        }
        for db in Self.minorMarks {
            let p = VUScale.position(forDB: db)
            ctx.stroke(geometry.tick(p, from: r, to: r + 6), with: .color(db > 0 ? Self.red : ink), lineWidth: 1)
        }

        // Percentage scale (100 % = 0 VU).
        let inner = r - 20
        ctx.stroke(geometry.arc(inner, from: 0, to: zero), with: .color(ink.opacity(0.8)), lineWidth: 1)
        for pct in stride(from: 0, through: 100, by: 10) {
            let p = Double(pct) / 100 * zero
            ctx.stroke(geometry.tick(p, from: inner, to: inner - (pct % 20 == 0 ? 7 : 4)), with: .color(ink.opacity(0.8)), lineWidth: 1)
            if pct % 20 == 0 {
                ctx.draw(Text("\(pct)").font(.custom("AvenirNextCondensed-Medium", size: 10)).foregroundStyle(ink.opacity(0.8)),
                         at: geometry.point(inner - 16, p))
            }
        }

        ctx.draw(Text(mode.label).font(.custom("Futura-Medium", size: mode == .vu ? 26 : 22)).foregroundStyle(ink),
                 at: CGPoint(x: centerX, y: window.maxY - 62))
        ctx.draw(Text(caption).font(.custom("AvenirNextCondensed-Medium", size: 9)).tracking(2)
                    .foregroundStyle(ink.opacity(0.8)),
                 at: CGPoint(x: centerX, y: window.maxY - 40))

        // Peak lamp, unlit (the lit state is drawn with the needles).
        let lampCenter = Self.peakLampCenter(window, centerX: centerX)
        let lampRect = CGRect(x: lampCenter.x - 4.5, y: lampCenter.y - 4.5, width: 9, height: 9)
        ctx.fill(Path(ellipseIn: lampRect), with: .color(Color(red: 0.35, green: 0.08, blue: 0.05)))
        ctx.draw(Text("PEAK").font(.custom("AvenirNextCondensed-Medium", size: 8)).tracking(1.5)
                    .foregroundStyle(ink.opacity(0.8)),
                 at: CGPoint(x: lampCenter.x, y: lampCenter.y + 13))
    }
}

/// Polar geometry of one meter: the pivot sits below the window, hidden like a real movement.
struct ScaleGeometry {
    let pivot: CGPoint

    init(window: CGRect, centerX: CGFloat) {
        pivot = CGPoint(x: centerX, y: window.maxY + 62)
    }

    func point(_ radius: CGFloat, _ p: Double) -> CGPoint {
        let half = MeterRenderer.halfSweep
        let a = (-half + 2 * half * p) * .pi / 180
        return CGPoint(x: pivot.x + radius * sin(a), y: pivot.y - radius * cos(a))
    }

    func arc(_ radius: CGFloat, from p0: Double, to p1: Double) -> Path {
        Path { path in
            let steps = 64
            for i in 0...steps {
                let pt = point(radius, p0 + (p1 - p0) * Double(i) / Double(steps))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
        }
    }

    func tick(_ p: Double, from r0: CGFloat, to r1: CGFloat) -> Path {
        Path { $0.move(to: point(r0, p)); $0.addLine(to: point(r1, p)) }
    }
}
