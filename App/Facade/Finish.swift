import SwiftUI

/// Linear RGB triple, used where colours are interpolated (backlight warm-up).
struct RGB {
    var r, g, b: Double

    func mix(_ o: RGB, _ t: Double) -> RGB {
        let t = min(max(t, 0), 1)
        return RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
    }

    func scaled(_ k: Double) -> RGB { RGB(r: r * k, g: g * k, b: b * k) }

    var color: Color { Color(red: r, green: g, blue: b) }
}

/// Cosmetic finish of the whole rack.
enum Finish: String, CaseIterable, Identifiable {
    /// Satin champagne aluminium, amber meters.
    case champagne
    /// Black anodised aluminium, amber meters, as on 80s Japanese separates.
    case black
    /// Black glass front with blue-lit meters and green lettering, in the American high-end tradition.
    case blueGlass

    var id: String { rawValue }

    var name: String {
        switch self {
        case .champagne: "Champagne"
        case .black: "Black"
        case .blueGlass: "Blue Glass"
        }
    }

    var palette: Palette {
        switch self {
        case .champagne: .champagne
        case .black: .black
        case .blueGlass: .blueGlass
        }
    }
}

struct Palette {
    // Front plate.
    var plate: [Color]
    /// Opacity range of the brushing streaks; nil for a polished surface.
    var brushing: ClosedRange<Double>?
    var glossy = false
    /// Brushed aluminium end cheeks on each side of the plate.
    var endCaps = false
    var roomLight: Double

    // Lettering.
    var lettering: Color
    var letteringShadow: Color
    var letteringShadowY: CGFloat
    /// Lettering lit from behind (glows) rather than engraved.
    var letteringLit = false

    // Lamps, displays and screens.
    var accent: Color
    var accentOff: Color

    // Meter window.
    var meterHotFull: RGB
    var meterEdgeFull: RGB
    var meterHotDim: RGB
    var meterEdgeDim: RGB
    var meterInk: Color
    var meterNeedle: Color

    // Controls.
    var knob: [Color]
    var knobPointer: Color
    var keyTop: Color
    var keyBottom: Color
    var keyLettering: Color
    var spectrumLow: Color
    var spectrumHigh: Color

    private static let amber = Color(red: 1, green: 0.62, blue: 0.22)
    private static let chrome = [0.62, 0.96, 0.55, 0.88, 0.48, 0.97, 0.58, 0.84, 0.62].map { Color(white: $0) }
    private static let amberMeter = (hotFull: RGB(r: 1.00, g: 0.84, b: 0.53), edgeFull: RGB(r: 0.95, g: 0.57, b: 0.20),
                                     hotDim: RGB(r: 0.90, g: 0.50, b: 0.17), edgeDim: RGB(r: 0.52, g: 0.22, b: 0.05))

    static let champagne = Palette(
        plate: [Color(red: 0.86, green: 0.85, blue: 0.82), Color(red: 0.80, green: 0.79, blue: 0.76),
                Color(red: 0.74, green: 0.73, blue: 0.70)],
        brushing: 0.015...0.06,
        roomLight: 0.10,
        lettering: Color(red: 0.25, green: 0.24, blue: 0.23),
        letteringShadow: .white.opacity(0.7),
        letteringShadowY: 1,
        accent: amber,
        accentOff: Color(red: 0.32, green: 0.25, blue: 0.2),
        meterHotFull: amberMeter.hotFull, meterEdgeFull: amberMeter.edgeFull,
        meterHotDim: amberMeter.hotDim, meterEdgeDim: amberMeter.edgeDim,
        meterInk: Color(red: 0.21, green: 0.12, blue: 0.05).opacity(0.9),
        meterNeedle: Color(red: 0.23, green: 0.10, blue: 0.05),
        knob: chrome,
        knobPointer: Color(red: 0.16, green: 0.14, blue: 0.13),
        keyTop: Color(white: 0.92), keyBottom: Color(white: 0.76),
        keyLettering: Color(red: 0.25, green: 0.24, blue: 0.23),
        spectrumLow: Color(red: 1, green: 0.6, blue: 0.2),
        spectrumHigh: Color(red: 1, green: 0.78, blue: 0.35)
    )

    static let black = Palette(
        plate: [Color(red: 0.17, green: 0.165, blue: 0.16), Color(red: 0.12, green: 0.115, blue: 0.11),
                Color(red: 0.08, green: 0.075, blue: 0.07)],
        brushing: 0.02...0.07,
        roomLight: 0.07,
        lettering: Color(red: 0.80, green: 0.78, blue: 0.74),
        letteringShadow: .black.opacity(0.8),
        letteringShadowY: -1,
        accent: amber,
        accentOff: Color(red: 0.25, green: 0.18, blue: 0.14),
        meterHotFull: amberMeter.hotFull, meterEdgeFull: amberMeter.edgeFull,
        meterHotDim: amberMeter.hotDim, meterEdgeDim: amberMeter.edgeDim,
        meterInk: Color(red: 0.21, green: 0.12, blue: 0.05).opacity(0.9),
        meterNeedle: Color(red: 0.23, green: 0.10, blue: 0.05),
        knob: [0.10, 0.30, 0.08, 0.22, 0.06, 0.34, 0.10, 0.24, 0.10].map { Color(white: $0) },
        knobPointer: Color(white: 0.85),
        keyTop: Color(white: 0.22), keyBottom: Color(white: 0.11),
        keyLettering: Color(white: 0.82),
        spectrumLow: Color(red: 1, green: 0.6, blue: 0.2),
        spectrumHigh: Color(red: 1, green: 0.78, blue: 0.35)
    )

    static let blueGlass = Palette(
        plate: [Color(red: 0.07, green: 0.075, blue: 0.08), Color(red: 0.025, green: 0.027, blue: 0.03),
                Color(red: 0.01, green: 0.01, blue: 0.012)],
        brushing: nil,
        glossy: true,
        endCaps: true,
        roomLight: 0.04,
        lettering: Color(red: 0.45, green: 0.98, blue: 0.62),
        letteringShadow: Color(red: 0.2, green: 1, blue: 0.5).opacity(0.7),
        letteringShadowY: 0,
        letteringLit: true,
        accent: Color(red: 0.42, green: 0.98, blue: 0.6),
        accentOff: Color(red: 0.08, green: 0.2, blue: 0.12),
        meterHotFull: RGB(r: 0.55, g: 0.82, b: 1.00), meterEdgeFull: RGB(r: 0.10, g: 0.35, b: 0.85),
        meterHotDim: RGB(r: 0.30, g: 0.58, b: 0.98), meterEdgeDim: RGB(r: 0.03, g: 0.15, b: 0.50),
        meterInk: Color(red: 0.02, green: 0.04, blue: 0.12).opacity(0.92),
        meterNeedle: Color(red: 0.02, green: 0.03, blue: 0.08),
        knob: chrome,
        knobPointer: Color(red: 0.05, green: 0.06, blue: 0.08),
        keyTop: Color(white: 0.16), keyBottom: Color(white: 0.05),
        keyLettering: Color(red: 0.45, green: 0.98, blue: 0.62),
        spectrumLow: Color(red: 0.25, green: 0.6, blue: 1),
        spectrumHigh: Color(red: 0.6, green: 0.88, blue: 1)
    )
}

extension EnvironmentValues {
    @Entry var palette: Palette = .champagne
}
