import SwiftUI

/// The frequency response of an equalizer profile on a log-frequency axis, 20 Hz to 20 kHz.
struct EQPlot: View {
    var profile: EQProfile
    /// Draw dB and Hz labels and the filter centres (the editor); the rack shows the bare curve.
    var detailed = true
    var accent = Color(red: 1, green: 0.66, blue: 0.3)
    var grid = Color.white.opacity(0.14)
    var label = Color.white.opacity(0.55)

    private static let lowHz = 20.0, highHz = 20_000.0

    var body: some View {
        Canvas { ctx, size in
            let inset = EdgeInsets(top: 8, leading: detailed ? 30 : 6, bottom: detailed ? 20 : 6, trailing: 8)
            let plot = CGRect(x: inset.leading, y: inset.top, width: size.width - inset.leading - inset.trailing,
                              height: size.height - inset.top - inset.bottom)
            let net = profile.headroomDB()
            // Scale to what the curve needs, in 3 dB steps, never less than ±6 dB.
            let samples = (0...300).map { i -> Double in profile.responseDB(at: Self.frequency(at: Double(i) / 300)) + net }
            let span = max(6, ceil(max(abs(samples.max() ?? 0), abs(samples.min() ?? 0)) / 3) * 3)

            func x(_ hz: Double) -> CGFloat { plot.minX + plot.width * CGFloat(log10(hz / Self.lowHz) / log10(Self.highHz / Self.lowHz)) }
            func y(_ db: Double) -> CGFloat { plot.midY - plot.height / 2 * CGFloat(db / span) }

            // Grid: octave decades and dB steps.
            for hz in [50.0, 100, 200, 500, 1000, 2000, 5000, 10_000] {
                var line = Path(); line.move(to: CGPoint(x: x(hz), y: plot.minY)); line.addLine(to: CGPoint(x: x(hz), y: plot.maxY))
                ctx.stroke(line, with: .color(grid), lineWidth: [100.0, 1000, 10_000].contains(hz) ? 1 : 0.5)
                if detailed, [100.0, 1000, 10_000].contains(hz) {
                    ctx.draw(Text(hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))").font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(label), at: CGPoint(x: x(hz), y: plot.maxY + 10))
                }
            }
            let step = span > 12 ? 6.0 : 3.0
            for db in stride(from: -span, through: span, by: step) {
                var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y(db))); line.addLine(to: CGPoint(x: plot.maxX, y: y(db)))
                ctx.stroke(line, with: .color(db == 0 ? grid.opacity(2.2) : grid), lineWidth: db == 0 ? 1 : 0.5)
                if detailed {
                    ctx.draw(Text(String(format: "%+.0f", db)).font(.system(size: 9, design: .monospaced)).foregroundStyle(label),
                             at: CGPoint(x: plot.minX - 14, y: y(db)))
                }
            }

            // The response.
            var curve = Path()
            for (i, db) in samples.enumerated() {
                let p = CGPoint(x: x(Self.frequency(at: Double(i) / 300)), y: y(min(max(db, -span), span)))
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            var fill = curve
            fill.addLine(to: CGPoint(x: plot.maxX, y: y(0))); fill.addLine(to: CGPoint(x: plot.minX, y: y(0))); fill.closeSubpath()
            ctx.fill(fill, with: .color(accent.opacity(0.14)))
            ctx.stroke(curve, with: .color(accent), style: StrokeStyle(lineWidth: detailed ? 2 : 1.6, lineJoin: .round))

            if detailed {
                for band in profile.bands where !band.isNeutral {
                    let db = profile.responseDB(at: band.frequency) + net
                    let c = CGPoint(x: x(band.frequency), y: y(min(max(db, -span), span)))
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.white.opacity(0.85)), lineWidth: 1.2)
                }
            }
        }
    }

    private static func frequency(at t: Double) -> Double { lowHz * pow(highHz / lowHz, t) }
}
