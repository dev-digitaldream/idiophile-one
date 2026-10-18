import Foundation

/// Coefficients of one biquad section, normalised so that a0 = 1.
struct BiquadCoefficients: Equatable, Sendable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    /// |H(e^jω)| in dB at `frequency`.
    func responseDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * .pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let numRe = b0 + b1 * c1 + b2 * c2, numIm = -(b1 * s1 + b2 * s2)
        let denRe = 1 + a1 * c1 + a2 * c2, denIm = -(a1 * s1 + a2 * s2)
        let num = numRe * numRe + numIm * numIm, den = denRe * denRe + denIm * denIm
        return 10 * log10(max(num / max(den, 1e-30), 1e-30))
    }
}

/// One filter of a parametric equalizer.
struct EQBand: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case peak, lowShelf, highShelf, lowPass, highPass, notch

        var label: String {
            switch self {
            case .peak: "Peak"
            case .lowShelf: "Low shelf"
            case .highShelf: "High shelf"
            case .lowPass: "Low-pass"
            case .highPass: "High-pass"
            case .notch: "Notch"
            }
        }

        /// Code used by Equalizer APO / AutoEq text files.
        var code: String {
            switch self {
            case .peak: "PK"
            case .lowShelf: "LSC"
            case .highShelf: "HSC"
            case .lowPass: "LP"
            case .highPass: "HP"
            case .notch: "NO"
            }
        }

        /// Whether the gain parameter means anything for this filter.
        var hasGain: Bool { self == .peak || self == .lowShelf || self == .highShelf }

        static func from(code: String) -> Kind? {
            switch code.uppercased() {
            case "PK", "PEQ", "PEAK": .peak
            case "LS", "LSC", "LSQ": .lowShelf
            case "HS", "HSC", "HSQ": .highShelf
            case "LP", "LPQ": .lowPass
            case "HP", "HPQ": .highPass
            case "NO", "NOTCH": .notch
            default: nil
            }
        }
    }

    var id = UUID()
    var enabled = true
    var kind: Kind = .peak
    var frequency: Double = 1000
    var gainDB: Double = 0
    var q: Double = 1

    /// A filter that leaves the signal alone (a shelf or peak with no gain).
    var isNeutral: Bool { !enabled || (kind.hasGain && abs(gainDB) < 0.005) }

    /// Biquad from the RBJ audio-EQ cookbook.
    func coefficients(sampleRate fs: Double) -> BiquadCoefficients {
        let f = min(max(frequency, 10), fs * 0.45)
        let q = min(max(q, 0.1), 30)
        let w0 = 2 * .pi * f / fs
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)
        let a = pow(10, gainDB / 40)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch kind {
        case .peak:
            b0 = 1 + alpha * a; b1 = -2 * cosw; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosw; a2 = 1 - alpha / a
        case .lowShelf:
            let r = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) - (a - 1) * cosw + r)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
            b2 = a * ((a + 1) - (a - 1) * cosw - r)
            a0 = (a + 1) + (a - 1) * cosw + r
            a1 = -2 * ((a - 1) + (a + 1) * cosw)
            a2 = (a + 1) + (a - 1) * cosw - r
        case .highShelf:
            let r = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) + (a - 1) * cosw + r)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
            b2 = a * ((a + 1) + (a - 1) * cosw - r)
            a0 = (a + 1) - (a - 1) * cosw + r
            a1 = 2 * ((a - 1) - (a + 1) * cosw)
            a2 = (a + 1) - (a - 1) * cosw - r
        case .lowPass:
            b0 = (1 - cosw) / 2; b1 = 1 - cosw; b2 = (1 - cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosw) / 2; b1 = -(1 + cosw); b2 = (1 + cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cosw; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

/// A named set of filters and a preamp.
struct EQProfile: Codable, Equatable, Sendable {
    var name = "Custom"
    var preampDB = 0.0
    var bands: [EQBand] = []

    static let maxBands = 20

    /// The ten-band graphic equalizer expressed as peaking filters (one octave wide).
    static func graphic(gains: [Float]) -> EQProfile {
        EQProfile(name: "Graphic", preampDB: 0, bands: zip(Equalizer.frequencies, gains).map {
            EQBand(kind: .peak, frequency: Double($0), gainDB: Double($1), q: 1.41)
        })
    }

    /// Filters that actually change the signal.
    func activeSections(sampleRate: Double) -> [BiquadCoefficients] {
        bands.filter { !$0.isNeutral }.prefix(Self.maxBands).map { $0.coefficients(sampleRate: sampleRate) }
    }

    /// Frequency response in dB, preamp included.
    func responseDB(at frequency: Double, sampleRate: Double = 48_000) -> Double {
        activeSections(sampleRate: sampleRate).reduce(preampDB) { $0 + $1.responseDB(at: frequency, sampleRate: sampleRate) }
    }

    /// Loudest point of the response over the audible range (preamp included).
    func peakResponseDB(sampleRate: Double = 48_000) -> Double {
        let sections = activeSections(sampleRate: sampleRate)
        guard !sections.isEmpty || preampDB != 0 else { return 0 }
        return stride(from: 0.0, through: 1.0, by: 1.0 / 240).map { t -> Double in
            let f = 20 * pow(1000, t)   // 20 Hz … 20 kHz, log spaced
            return sections.reduce(preampDB) { $0 + $1.responseDB(at: f, sampleRate: sampleRate) }
        }.max() ?? 0
    }

    /// Average level of the response over the core of the music band (100 Hz – 10 kHz, power mean
    /// on a log scale), preamp and headroom included. Used to compare two profiles at equal loudness.
    func levelDB(sampleRate: Double = 48_000) -> Double {
        let sections = activeSections(sampleRate: sampleRate)
        guard !sections.isEmpty else { return preampDB + headroomDB(sampleRate: sampleRate) }
        let points = 64
        let power = (0..<points).reduce(0.0) { sum, i in
            let f = 100 * pow(100, Double(i) / Double(points - 1))   // 100 Hz … 10 kHz
            let db = sections.reduce(0.0) { $0 + $1.responseDB(at: f, sampleRate: sampleRate) }
            return sum + pow(10, db / 10)
        } / Double(points)
        return 10 * log10(max(power, 1e-12)) + preampDB + headroomDB(sampleRate: sampleRate)
    }

    /// Extra attenuation so that the loudest point of the response never exceeds 0 dB.
    func headroomDB(sampleRate: Double = 48_000) -> Double { min(0, -peakResponseDB(sampleRate: sampleRate)) }

    /// True when the profile changes nothing at all.
    var isFlat: Bool { preampDB == 0 && bands.allSatisfy(\.isNeutral) }

    // MARK: Text format (Equalizer APO / AutoEq "ParametricEQ.txt")

    /// Parses the text format used by AutoEq and Equalizer APO:
    /// `Preamp: -6.2 dB` and `Filter 1: ON PK Fc 100 Hz Gain -3.2 dB Q 0.70`.
    static func parse(_ text: String, name: String) -> EQProfile? {
        var profile = EQProfile(name: name)
        let preamp = try? NSRegularExpression(pattern: #"^\s*Preamp\s*:\s*(-?[\d.]+)\s*dB"#, options: .caseInsensitive)
        let filter = try? NSRegularExpression(
            pattern: #"^\s*Filter\s*\d*\s*:\s*(ON|OFF)\s+(\w+)\s+Fc\s+([\d.]+)\s*Hz(?:\s+Gain\s+(-?[\d.]+)\s*dB)?(?:\s+Q\s+([\d.]+))?(?:\s+BW\s+Oct\s+([\d.]+))?"#,
            options: .caseInsensitive)
        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
                Range(m.range(at: i), in: line).map { String(line[$0]) }
            }
            if let m = preamp?.firstMatch(in: line, range: range), let value = group(m, 1).flatMap(Double.init) {
                profile.preampDB = value
            } else if let m = filter?.firstMatch(in: line, range: range),
                      let code = group(m, 2), let kind = EQBand.Kind.from(code: code),
                      let fc = group(m, 3).flatMap(Double.init) {
                var band = EQBand(enabled: group(m, 1)?.uppercased() == "ON", kind: kind, frequency: fc)
                band.gainDB = group(m, 4).flatMap(Double.init) ?? 0
                if let q = group(m, 5).flatMap(Double.init) {
                    band.q = q
                } else if let octaves = group(m, 6).flatMap(Double.init), octaves > 0 {
                    band.q = 1 / (2 * sinh(log(2) / 2 * octaves))      // bandwidth in octaves → Q
                } else {
                    band.q = kind == .peak ? 1 : 0.707
                }
                profile.bands.append(band)
            }
        }
        return profile.bands.isEmpty && profile.preampDB == 0 ? nil : profile
    }

    /// The same text format, for export.
    var text: String {
        var lines = [String(format: "Preamp: %.1f dB", preampDB)]
        for (i, band) in bands.enumerated() {
            lines.append(String(format: "Filter %d: %@ %@ Fc %g Hz%@ Q %.2f", i + 1, band.enabled ? "ON" : "OFF", band.kind.code,
                                band.frequency, band.kind.hasGain ? String(format: " Gain %.1f dB", band.gainDB) : "", band.q))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// What the equalizer is set to for one output device.
struct EQSetup: Codable, Equatable, Sendable {
    /// Ten graphic faders, in dB.
    var graphic = [Float](repeating: 0, count: Equalizer.frequencies.count)
    /// A parametric profile kept even while the faders are in use.
    var parametric: EQProfile?
    var useParametric = false

    /// The filters currently in the signal path.
    var profile: EQProfile {
        if useParametric, let parametric { return parametric }
        return .graphic(gains: graphic)
    }
}

/// User presets, kept as one JSON file in Application Support.
enum EQPresetStore {
    /// Profiles shipped with the app: AutoEq results (MIT licence) computed from oratory1990's
    /// measurements, for headphones this project is tested with. See CREDITS.md.
    static let builtIn: [EQProfile] = [
        EQProfile.parse("""
        Preamp: -6.1 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.2 dB Q 0.70
        Filter 2: ON PK Fc 84 Hz Gain -4.5 dB Q 0.92
        Filter 3: ON PK Fc 4513 Hz Gain 4.9 dB Q 2.16
        Filter 4: ON PK Fc 5665 Hz Gain -8.5 dB Q 4.02
        Filter 5: ON PK Fc 41 Hz Gain 1.4 dB Q 1.57
        Filter 6: ON HSC Fc 10000 Hz Gain -0.3 dB Q 0.70
        Filter 7: ON PK Fc 573 Hz Gain 1.2 dB Q 1.98
        Filter 8: ON PK Fc 1417 Hz Gain 1.5 dB Q 2.41
        Filter 9: ON PK Fc 2114 Hz Gain -0.9 dB Q 2.68
        Filter 10: ON PK Fc 7753 Hz Gain -1.2 dB Q 4.40
        """, name: "Superlux HD 668B (oratory1990)"),
        EQProfile.parse("""
        Preamp: -6.3 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.4 dB Q 0.70
        Filter 2: ON PK Fc 495 Hz Gain 3.7 dB Q 1.07
        Filter 3: ON PK Fc 2283 Hz Gain -3.5 dB Q 2.43
        Filter 4: ON PK Fc 89 Hz Gain -3.8 dB Q 1.59
        Filter 5: ON PK Fc 5974 Hz Gain -7.6 dB Q 3.14
        Filter 6: ON HSC Fc 10000 Hz Gain -5.1 dB Q 0.70
        Filter 7: ON PK Fc 4094 Hz Gain 4.2 dB Q 4.42
        Filter 8: ON PK Fc 3106 Hz Gain -1.2 dB Q 3.46
        Filter 9: ON PK Fc 8235 Hz Gain -1.0 dB Q 4.05
        Filter 10: ON PK Fc 1030 Hz Gain -0.8 dB Q 3.66
        """, name: "Superlux HD 668B velour pads (oratory1990)"),
    ].compactMap { $0 }

    /// Reads AutoEq / Equalizer APO files, adds them to the saved presets and returns them.
    /// A name ending in "ParametricEQ" (the AutoEq file naming) is shortened.
    static func importFiles(_ urls: [URL]) -> [EQProfile] {
        var imported: [EQProfile] = []
        for url in urls {
            var name = url.deletingPathExtension().lastPathComponent
            if name.hasSuffix(" ParametricEQ") { name.removeLast(" ParametricEQ".count) }
            guard let text = try? String(contentsOf: url, encoding: .utf8), let profile = EQProfile.parse(text, name: name) else { continue }
            save(profile)
            imported.append(profile)
        }
        return imported
    }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Idiophile One", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("EQPresets.json")
    }

    static func load() -> [EQProfile] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([EQProfile].self, from: $0) } ?? []
    }

    /// Saves a profile under its name, replacing a preset of the same name.
    static func save(_ profile: EQProfile) {
        var presets = load().filter { $0.name != profile.name }
        presets.append(profile)
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try? JSONEncoder().encode(presets).write(to: url, options: .atomic)
    }

    static func delete(named name: String) {
        let presets = load().filter { $0.name != name }
        try? JSONEncoder().encode(presets).write(to: url, options: .atomic)
    }
}
