import Foundation

/// Geometry of the ten-band octave graphic equalizer (ISO centre frequencies); also the
/// bands of the spectrum analyser.
enum Equalizer {
    static let frequencies: [Float] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let range: ClosedRange<Float> = -12...12
}
